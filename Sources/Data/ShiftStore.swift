// ShiftStore.swift
// Singleton that owns the in-memory and on-disk shift list.
// On every save it:
//   1. Computes a ScheduleDiff against the previous store
//   2. Syncs the diff to EventKitManager (add/remove calendar events)
//   3. Returns the diff so callers (intents, UI) can report what changed

import Foundation
import Observation

@MainActor
@Observable
final class ShiftStore {

    static let shared = ShiftStore()

    /// Raw parsed shifts (full master). Display reads go through `shifts` (relief-filtered).
    private var rawShifts: [Shift] = []
    private(set) var lastFetchDate: Date?
    private(set) var lastDiff:      ScheduleDiff?

    /// Manual per-day vacation overrides, correcting the parser's home-desk heuristic:
    ///  • `tradedBackDayIDs` — a genuine-vacation day the user says they actually WORKED (traded in).
    ///  • `forcedVacationDayIDs` — a traded-back day the user says is actually vacation (OFF).
    /// Both only apply to vacation-ORIGIN days (`leaveCode == "V"`). Persisted.
    private(set) var tradedBackDayIDs: Set<String> = []
    private(set) var forcedVacationDayIDs: Set<String> = []

    /// The shifts every consumer sees. Relief horizon removes future days; then the per-day vacation
    /// overrides flip a "V" day's worked/off state. (REL1 + manual vacation override)
    var shifts: [Shift] {
        var out = rawShifts
        if let rt = SettingsManager.shared.effectiveReliefThrough {
            out = out.filter { !TradeProfile.isPastRelief(day: $0.date, reliefThrough: rt) }
        }
        guard !tradedBackDayIDs.isEmpty || !forcedVacationDayIDs.isEmpty else { return out }
        return out.map { s in
            guard s.isVacationOrigin else { return s }   // overrides only touch approved-vacation days
            if tradedBackDayIDs.contains(s.id), s.isOff, s.startHour > 0 {   // vacation → worked (traded in)
                return Shift(id: s.id, date: s.date, startHour: s.startHour, endHour: s.endHour,
                             role: s.role, desk: s.desk, leaveCode: "V", isOff: false)
            }
            if forcedVacationDayIDs.contains(s.id), !s.isOff {              // worked → vacation OFF
                return Shift(id: s.id, date: s.date, startHour: s.startHour, endHour: s.endHour,
                             role: s.role, desk: s.desk, leaveCode: "V", isOff: true)
            }
            return s
        }
    }

    /// Toggle a per-day vacation override (worked ⇄ off), persist it, and PUSH it to the Apple calendar
    /// so the calendar matches (adds the shift event when marked worked, removes it when marked off).
    func setVacationOverride(dayID: String, worked: Bool) {
        if worked { tradedBackDayIDs.insert(dayID); forcedVacationDayIDs.remove(dayID) }
        else       { forcedVacationDayIDs.insert(dayID); tradedBackDayIDs.remove(dayID) }
        persistOverrides()
        _ = EventKitManager.shared.resyncPersonalEvents(for: shifts)   // keep Apple Calendar in sync
        WidgetData.update()
    }

    /// Clear any override on a day (revert to the parser's heuristic).
    func clearVacationOverride(dayID: String) {
        guard tradedBackDayIDs.remove(dayID) != nil || forcedVacationDayIDs.remove(dayID) != nil else { return }
        persistOverrides()
        _ = EventKitManager.shared.resyncPersonalEvents(for: shifts)
        WidgetData.update()
    }

    private func persistOverrides() {
        UserDefaults.standard.set(Array(tradedBackDayIDs), forKey: Keys.tradedBack)
        UserDefaults.standard.set(Array(forcedVacationDayIDs), forKey: Keys.forcedVacation)
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let shifts    = "batman.shifts"
        static let fetchDate = "batman.lastFetchDate"
        static let tradedBack = "batman.vacTradedBack"
        static let forcedVacation = "batman.vacForcedOff"
    }

    private init() { load() }

    // MARK: - Write

    /// Saves a freshly-fetched shift list.
    /// Diffs against the current store, syncs EventKit, and returns the diff.
    @discardableResult
    func save(_ incoming: [Shift]) -> ScheduleDiff {
        let sorted = incoming.sorted { $0.date < $1.date }
        // Diff on the RAW list so EventKit sees true changes; calendar-add relief-filters itself.
        let diff   = ScheduleDiff.compute(old: rawShifts, new: sorted)

        self.rawShifts     = sorted
        self.lastFetchDate = Date()
        self.lastDiff      = diff

        // Persist
        if let data = try? encoder.encode(sorted) {
            UserDefaults.standard.set(data, forKey: Keys.shifts)
        }
        UserDefaults.standard.set(lastFetchDate, forKey: Keys.fetchDate)

        // Sync calendar events for exactly what changed
        EventKitManager.shared.sync(diff: diff)

        return diff
    }

    /// Clears all stored shifts, calendar events, and availability data.
    func clear() {
        EventKitManager.shared.removeAllEvents()
        AvailabilityManager.shared.clearAll()
        self.rawShifts     = []
        self.lastFetchDate = nil
        self.lastDiff      = nil
        UserDefaults.standard.removeObject(forKey: Keys.shifts)
        UserDefaults.standard.removeObject(forKey: Keys.fetchDate)
    }

    // MARK: - Read

    /// All working shifts (not OFF) from today onward, up to `days` days out.
    func upcomingWorkingShifts(days: Int = 400) -> [Shift] {
        let calendar = Calendar.current
        let today    = calendar.startOfDay(for: Date())
        let cutoff   = calendar.date(byAdding: .day, value: days, to: today)!
        return shifts.filter { !$0.isOff && $0.date >= today && $0.date <= cutoff }
    }

    /// All shifts (including off days) from today onward.
    func upcomingAllShifts(days: Int = 400) -> [Shift] {
        let calendar = Calendar.current
        let today    = calendar.startOfDay(for: Date())
        let cutoff   = calendar.date(byAdding: .day, value: days, to: today)!
        return shifts.filter { $0.date >= today && $0.date <= cutoff }
    }

    /// The very next working shift after right now.
    var nextShift: Shift? {
        upcomingWorkingShifts(days: 30).first
    }

    /// Returns the shift on a specific calendar date, or nil if off/not found.
    func shift(on date: Date) -> Shift? {
        let calendar = Calendar.current
        return shifts.first {
            calendar.isDate($0.date, inSameDayAs: date) && !$0.isOff
        }
    }

    /// Returns the working shift tomorrow, if any.
    var tomorrowsShift: Shift? {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else {
            return nil
        }
        return shift(on: tomorrow)
    }

    // MARK: - Private

    private func load() {
        if let data    = UserDefaults.standard.data(forKey: Keys.shifts),
           let decoded = try? decoder.decode([Shift].self, from: data) {
            self.rawShifts = decoded
        }
        self.lastFetchDate = UserDefaults.standard.object(forKey: Keys.fetchDate) as? Date
        self.tradedBackDayIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.tradedBack) ?? [])
        self.forcedVacationDayIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.forcedVacation) ?? [])
    }
}
