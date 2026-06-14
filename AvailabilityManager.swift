// AvailabilityManager.swift
// Owns all interaction with the shared "AA Dispatch" calendar.
//
// Responsibilities:
//   • Build initial availability from the fetched schedule (off days)
//   • Infer default shift type from the dispatcher's own pattern
//   • Allow per-day manual overrides (AM / PM / MID / Not Available)
//   • Write and remove entries on the shared iCloud calendar
//   • Read other dispatchers' entries from the same shared calendar
//
// EventKitManager owns the PERSONAL "AA Schedule" calendar.
// AvailabilityManager owns the SHARED "AA Dispatch" calendar.
// They each hold their own EKEventStore instance — this is safe on iOS.

import EventKit
import Foundation
import Observation

@MainActor
@Observable
final class AvailabilityManager {

    static let shared = AvailabilityManager()

    // Your availability entries for upcoming off days, sorted ascending.
    private(set) var myAvailability: [DayAvailability] = []

    private let ekStore  = EKEventStore()
    private let encoder  = JSONEncoder()
    private let decoder  = JSONDecoder()

    private enum Keys {
        static let myAvailability = "batman.myAvailability"
        static let eventIDs       = "batman.availabilityEventIDs"
        static let perDayRemoved  = "batman.perDayRemovedTypes"
    }

    // shift ISO date → EKEvent.eventIdentifiers on the shared calendar (one per offered type)
    private var eventIDMap: [String: [String]] {
        get { (UserDefaults.standard.dictionary(forKey: Keys.eventIDs) as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.eventIDs) }
    }

    // day ISO → shift-type rawValues the user manually removed for that specific day.
    // The granular, date-specific blacklist, composed on top of openness + global blacklist.
    private var perDayRemovedTypes: [String: [String]] {
        get { (UserDefaults.standard.dictionary(forKey: Keys.perDayRemoved) as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.perDayRemoved) }
    }

    private init() { load() }

    // MARK: - Build / rebuild from schedule

    /// Called after every schedule fetch.
    /// Adds availability entries for new off days, removes entries for days
    /// that are no longer off days, preserves existing manual overrides.
    func buildFromSchedule() {
        let today     = Calendar.current.startOfDay(for: Date())
        let allShifts = ShiftStore.shared.shifts
        let offDays   = allShifts.filter { $0.isOff && $0.date >= today }
        let worked    = allShifts.filter { !$0.isOff }
        let workedDays = Set(worked.map { $0.id })

        let settings = SettingsManager.shared
        let openness = TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends
        let blacklistedWeekdays = settings.blacklistedWeekdays
        let blacklistedTypes = Set(settings.blacklistedShiftTypes.compactMap { ShiftAvailabilityType(rawValue: $0) })
        let removals = perDayRemovedTypes
        let calendar = Calendar.current
        let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd"
        let offDayIDs = Set(offDays.map { $0.id })

        // Recompute fresh every time (idempotent — switching openness can't lose data).
        // Effective availability = openness-filtered eligible days
        //   − global blacklisted types − per-day removals,
        //   empty on blacklisted weekdays or when not accepting trades.
        var rebuilt: [DayAvailability] = []
        for offDay in offDays {
            let weekday = calendar.component(.weekday, from: offDay.date)
            let bookend = Self.isBookendDay(offDay.date, workedDays: workedDays, iso: iso)

            var types: Set<ShiftAvailabilityType> = []
            if openness != .none, !blacklistedWeekdays.contains(weekday),
               openness == .all || bookend {
                types = Self.eligibleTypes(forOffDay: offDay.date, workedShifts: worked)
                types.subtract(blacklistedTypes)
                if let removed = removals[offDay.id] {
                    types.subtract(removed.compactMap { ShiftAvailabilityType(rawValue: $0) })
                }
            }
            rebuilt.append(DayAvailability(id: offDay.id, date: offDay.date, availableTypes: types))
        }

        // Remove shared-calendar events for days that are no longer off days.
        let goneDays = myAvailability.filter { !offDayIDs.contains($0.id) }
        if !goneDays.isEmpty { removeFromSharedCalendar(goneDays) }

        myAvailability = rebuilt.sorted { $0.date < $1.date }
        save()
        syncAll()
    }

    // MARK: - Per-day manual override (the granular, date-specific blacklist)

    /// Toggle whether `type` is offered on `dayID`.
    func toggleType(_ type: ShiftAvailabilityType, on dayID: String) {
        var removals = perDayRemovedTypes
        var set = Set(removals[dayID] ?? [])
        if set.contains(type.rawValue) { set.remove(type.rawValue) } else { set.insert(type.rawValue) }
        removals[dayID] = set.isEmpty ? nil : Array(set)
        perDayRemovedTypes = removals
        buildFromSchedule()
    }

    /// Mark a specific day fully Not Available (removes all types for that day).
    func disableDay(_ dayID: String) {
        var removals = perDayRemovedTypes
        removals[dayID] = ShiftAvailabilityType.allCases.map { $0.rawValue }
        perDayRemovedTypes = removals
        buildFromSchedule()
    }

    /// Clear a day's manual override, restoring the computed default.
    func resetDay(_ dayID: String) {
        var removals = perDayRemovedTypes
        removals[dayID] = nil
        perDayRemovedTypes = removals
        buildFromSchedule()
    }

    /// An off day is a "bookend" if exactly one adjacent day is worked — the edge
    /// of a 2+-day off stretch (not the middle of a long weekend, not isolated).
    private static func isBookendDay(_ date: Date, workedDays: Set<String>, iso: DateFormatter) -> Bool {
        let cal = Calendar.current
        let worksPrev = cal.date(byAdding: .day, value: -1, to: date).map { workedDays.contains(iso.string(from: $0)) } ?? false
        let worksNext = cal.date(byAdding: .day, value:  1, to: date).map { workedDays.contains(iso.string(from: $0)) } ?? false
        return worksPrev != worksNext
    }

    // MARK: - Read other dispatchers

    /// Queries the shared calendar for a specific date and returns every
    /// dispatcher who posted availability there.
    /// Excludes your own entries (matched by display name).
    /// Optionally filters by shift type.
    func otherDispatchersAvailable(
        on date: Date,
        filterBy type: ShiftAvailabilityType? = nil
    ) -> [DispatcherAvailabilityEntry] {
        guard let cal = sharedCalendar() else { return [] }

        let calendar = Calendar.current
        let start    = calendar.startOfDay(for: date)
        let end      = calendar.date(byAdding: .day, value: 1, to: start)!
        let pred     = ekStore.predicateForEvents(withStart: start, end: end, calendars: [cal])
        let events   = ekStore.events(matching: pred)

        let myName = displayName()

        return events.compactMap { event -> DispatcherAvailabilityEntry? in
            guard let title = event.title,
                  let entry = DispatcherAvailabilityEntry.parse(title: title, date: date)
            else { return nil }

            // Exclude your own entries
            if entry.name.lowercased() == myName.lowercased() { return nil }

            // Apply shift type filter
            if let filter = type, entry.availability != filter { return nil }

            return entry
        }
        .sorted { $0.name < $1.name }
    }

    /// Convenience overload returning ALL available dispatchers without filter.
    func allOtherDispatchersAvailable(on date: Date) -> [DispatcherAvailabilityEntry] {
        otherDispatchersAvailable(on: date, filterBy: nil)
    }

    // MARK: - Shared calendar write/remove

    private func syncAll() {
        for entry in myAvailability {
            if entry.isAvailable {
                writeToSharedCalendar(entry)
            } else {
                removeFromSharedCalendar([entry])
            }
        }
    }

    private func writeToSharedCalendar(_ day: DayAvailability) {
        guard let cal = sharedCalendar() else { return }

        var map  = eventIDMap
        let name = displayName()

        // Remove any previously-written events for this day (handles changes).
        for oldID in map[day.id] ?? [] {
            if let old = ekStore.event(withIdentifier: oldID) {
                try? ekStore.remove(old, span: .thisEvent, commit: false)
            }
        }

        // Write one all-day event per offered shift type.
        var newIDs: [String] = []
        for type in day.sortedTypes {
            let event        = EKEvent(eventStore: ekStore)
            event.calendar   = cal
            event.title      = day.calendarTitle(displayName: name, type: type)
            event.isAllDay   = true
            event.startDate  = day.date
            event.endDate    = day.date
            event.notes      = "Posted by BATMANReader"
            do {
                try ekStore.save(event, span: .thisEvent, commit: false)
                if let id = event.eventIdentifier { newIDs.append(id) }
            } catch {
                print("⚠️ AvailabilityManager: write failed for \(day.id) \(type.rawValue): \(error)")
            }
        }
        try? ekStore.commit()
        map[day.id] = newIDs
        eventIDMap = map
    }

    private func removeFromSharedCalendar(_ days: [DayAvailability]) {
        var map = eventIDMap
        for day in days {
            for eid in map[day.id] ?? [] {
                if let event = ekStore.event(withIdentifier: eid) {
                    try? ekStore.remove(event, span: .thisEvent, commit: false)
                }
            }
            map.removeValue(forKey: day.id)
        }
        try? ekStore.commit()
        eventIDMap = map
    }

    // MARK: - Helpers

    private func sharedCalendar() -> EKCalendar? {
        let settings = SettingsManager.shared
        guard settings.sharedCalendarEnabled,
              !settings.sharedCalendarIdentifier.isEmpty else { return nil }
        return ekStore.calendar(withIdentifier: settings.sharedCalendarIdentifier)
    }

    private func displayName() -> String {
        let s = SettingsManager.shared
        return s.displayName.isEmpty ? s.username : s.displayName
    }

    /// Returns the shift types a dispatcher could LEGALLY work on an off day,
    /// honoring the mandatory 8-hour rest between shifts (and no overlap) against
    /// their actual worked shifts. e.g. after a 1300 shift (ends 2200), a 0500
    /// shift the next day is blocked (only 7h rest).
    nonisolated static func eligibleTypes(forOffDay date: Date, workedShifts: [Shift]) -> Set<ShiftAvailabilityType> {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let minRest: TimeInterval = 8 * 3600
        let shiftLength: TimeInterval = 9 * 3600

        var eligible: Set<ShiftAvailabilityType> = []
        for type in ShiftAvailabilityType.allCases {
            guard let cStart = calendar.date(byAdding: .hour, value: type.startHour, to: dayStart) else { continue }
            let cEnd = cStart.addingTimeInterval(shiftLength)

            var ok = true
            for s in workedShifts {
                let sStart = s.startDate
                let sEnd   = s.endDate
                if sStart < cEnd && sEnd > cStart { ok = false; break }                              // overlap
                if sEnd <= cStart && cStart.timeIntervalSince(sEnd) < minRest { ok = false; break }   // rest before
                if sStart >= cEnd && sStart.timeIntervalSince(cEnd) < minRest { ok = false; break }   // rest after
            }
            if ok { eligible.insert(type) }
        }
        return eligible
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? encoder.encode(myAvailability) {
            UserDefaults.standard.set(data, forKey: Keys.myAvailability)
        }
    }

    private func load() {
        guard let data    = UserDefaults.standard.data(forKey: Keys.myAvailability),
              let decoded = try? decoder.decode([DayAvailability].self, from: data) else { return }
        myAvailability = decoded
    }

    /// Called when the user clears their stored schedule.
    func clearAll() {
        removeFromSharedCalendar(myAvailability)
        myAvailability = []
        UserDefaults.standard.removeObject(forKey: Keys.myAvailability)
        eventIDMap = [:]
    }
}
