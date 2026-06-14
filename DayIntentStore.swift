// DayIntentStore.swift
// The single source of truth for per-day trade intent in v2 ("Build 2").
//
// ⚠️ v2 BRANCH WORK. Replaces the role of `TradeIntentStore` (a flat set of days
// to give away) with a richer per-day model: a `WorkingIntentState` for worked
// days, an `OffIntentState` for off days, plus topology + notes.
//
// `seekingDayIDs` is preserved as a COMPUTED projection so every existing reader
// (TradeProfile publish, WidgetData, App Intents) keeps working unchanged — there
// is exactly one stored representation, so the two can never drift.

import Foundation
import Observation

@MainActor
@Observable
final class DayIntentStore {

    static let shared = DayIntentStore()

    // MARK: Stored state (the single source of truth)

    /// ISO day → intent for a day the user works.
    private(set) var workingIntents: [String: WorkingIntentState] {
        didSet { persist(workingIntents, Keys.working) }
    }
    /// ISO day → intent for a day the user is off.
    private(set) var offIntents: [String: OffIntentState] {
        didSet { persist(offIntents, Keys.off) }
    }
    /// ISO day → topology (high-demand / personal milestone).
    private(set) var topologies: [String: DayTopology] {
        didSet { persist(topologies, Keys.topology) }
    }
    /// ISO day → short note.
    private(set) var notes: [String: DayNote] {
        didSet { persist(notes, Keys.notes) }
    }
    /// ISO off-day → which shift types the user would pick up (AM/PM/MID pills).
    private(set) var offAvailability: [String: Set<ShiftAvailabilityType>] {
        didSet { persist(offAvailability, Keys.availability) }
    }

    // MARK: Derived (drop-in replacement for TradeIntentStore.seekingDayIDs)

    /// Working days the user wants to trade away. Computed from the one stored
    /// map, so it can never disagree with the intent UI.
    var seekingDayIDs: Set<String> {
        Set(workingIntents.filter { $0.value == .dontWantToWork }.keys)
    }

    // MARK: Init + one-time migration

    private init() {
        workingIntents  = Self.load(Keys.working) ?? [:]
        offIntents      = Self.load(Keys.off) ?? [:]
        topologies      = Self.load(Keys.topology) ?? [:]
        notes           = Self.load(Keys.notes) ?? [:]
        offAvailability = Self.load(Keys.availability) ?? [:]
        migrateFromTradeIntentStoreIfNeeded()
    }

    /// Seed `workingIntents` from the legacy `TradeIntentStore.seekingDayIDs` once,
    /// so a user upgrading to v2 keeps their existing "trade away" marks.
    private func migrateFromTradeIntentStoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Keys.migrated) else { return }
        for day in TradeIntentStore.shared.seekingDayIDs where workingIntents[day] == nil {
            workingIntents[day] = .dontWantToWork
        }
        defaults.set(true, forKey: Keys.migrated)
    }

    // MARK: Mutations

    func setWorkingIntent(_ state: WorkingIntentState?, forDay dayID: String) {
        if let state { workingIntents[dayID] = state } else { workingIntents[dayID] = nil }
    }

    func setOffIntent(_ state: OffIntentState?, forDay dayID: String) {
        if let state { offIntents[dayID] = state } else { offIntents[dayID] = nil }
    }

    func setTopology(_ topology: DayTopology?, forDay dayID: String) {
        if let topology, topology != .standard { topologies[dayID] = topology }
        else { topologies[dayID] = nil }
    }

    func setNote(_ note: DayNote?, forDay dayID: String) {
        if let note, !note.message.isEmpty { notes[dayID] = note } else { notes[dayID] = nil }
    }

    /// Toggle one shift type in an off-day's availability. Sets/clears the day's
    /// `.wantToWork` intent to stay consistent with whether any type is selected.
    func toggleAvailability(_ type: ShiftAvailabilityType, forDay dayID: String) {
        var set = offAvailability[dayID] ?? []
        if set.contains(type) { set.remove(type) } else { set.insert(type) }
        if set.isEmpty {
            // Deselecting every shift type marks the day unavailable (red ⊗).
            offAvailability[dayID] = nil
            offIntents[dayID] = .mustBeOff
        } else {
            offAvailability[dayID] = set
            offIntents[dayID] = .wantToWork
        }
    }

    /// Removes the worked/off intent for a date (keeps topology + note).
    func clearIntent(forDay dayID: String) {
        workingIntents[dayID] = nil
        offIntents[dayID] = nil
        offAvailability[dayID] = nil
    }

    // MARK: Reads

    func workingIntent(forDay dayID: String) -> WorkingIntentState? { workingIntents[dayID] }
    func offIntent(forDay dayID: String) -> OffIntentState? { offIntents[dayID] }
    func topology(forDay dayID: String) -> DayTopology { topologies[dayID] ?? .standard }
    func note(forDay dayID: String) -> DayNote? { notes[dayID] }
    func availability(forDay dayID: String) -> Set<ShiftAvailabilityType> { offAvailability[dayID] ?? [] }

    // MARK: Snapshot-cleanse

    /// When a new master snapshot flips a date between worked and off, the old
    /// intent for that date no longer makes sense — clear it. Pass the user's
    /// current shifts. Returns the day IDs whose intent was wiped (so the UI can
    /// flag them for re-marking).
    @discardableResult
    func reconcile(withShifts shifts: [Shift]) -> Set<String> {
        var isOffByDay: [String: Bool] = [:]
        for s in shifts { isOffByDay[s.id] = s.isOff }

        var wiped = Set<String>()
        // A working intent on a day that's now OFF (or no longer in the schedule).
        for day in workingIntents.keys where (isOffByDay[day] ?? true) {
            workingIntents[day] = nil
            wiped.insert(day)
        }
        // An off intent on a day that's now WORKED.
        for day in offIntents.keys where isOffByDay[day] == false {
            offIntents[day] = nil
            wiped.insert(day)
        }
        for day in offAvailability.keys where isOffByDay[day] == false {
            offAvailability[day] = nil
            wiped.insert(day)
        }
        return wiped
    }

    // MARK: Persistence

    private enum Keys {
        static let working  = "batman.v2.workingIntents"
        static let off      = "batman.v2.offIntents"
        static let topology = "batman.v2.topologies"
        static let notes    = "batman.v2.dayNotes"
        static let availability = "batman.v2.offAvailability"
        static let migrated = "batman.v2.intentMigrated"
    }

    private func persist<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
