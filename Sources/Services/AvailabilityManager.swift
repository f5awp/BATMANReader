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
        static let perDayRemoved  = "batman.perDayRemovedTypes"
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

        myAvailability = rebuilt.sorted { $0.date < $1.date }
        save()
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

    // MARK: - Helpers

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

    /// #1: is ANY legal shift coverable on this off day (after 8h-rest vs adjacent worked shifts)?
    /// When false the day gets an auto-X and can't be marked Want-to-Work (no shift exists to pick up).
    nonisolated static func hasAnyLegalShift(forOffDay date: Date, workedShifts: [Shift]) -> Bool {
        !eligibleTypes(forOffDay: date, workedShifts: workedShifts).isEmpty
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
        myAvailability = []
        UserDefaults.standard.removeObject(forKey: Keys.myAvailability)
    }
}
