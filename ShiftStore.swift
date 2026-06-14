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

    private(set) var shifts:        [Shift] = []
    private(set) var lastFetchDate: Date?
    private(set) var lastDiff:      ScheduleDiff?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let shifts    = "batman.shifts"
        static let fetchDate = "batman.lastFetchDate"
    }

    private init() { load() }

    // MARK: - Write

    /// Saves a freshly-fetched shift list.
    /// Diffs against the current store, syncs EventKit, and returns the diff.
    @discardableResult
    func save(_ incoming: [Shift]) -> ScheduleDiff {
        let sorted = incoming.sorted { $0.date < $1.date }
        let diff   = ScheduleDiff.compute(old: self.shifts, new: sorted)

        self.shifts        = sorted
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
        self.shifts        = []
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
            self.shifts = decoded
        }
        self.lastFetchDate = UserDefaults.standard.object(forKey: Keys.fetchDate) as? Date
    }
}
