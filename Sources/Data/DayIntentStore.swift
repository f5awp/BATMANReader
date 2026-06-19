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

    /// C1: bumped ONLY by an explicit SAVE (`markIntentsSaved`). The trade feeds recompute when this
    /// changes — so editing intents no longer re-runs the heavy search on every keystroke; you SAVE,
    /// then the search re-runs once.
    private(set) var intentsRevision: Int = 0

    /// C1 phase-2: `true` once the user paints/edits an intent, `false` after Save or Discard.
    /// NOT persisted — a fresh launch's on-disk state IS the saved baseline. Drives the glowing
    /// Save button + the leave-Home guard (Save-or-Discard).
    private(set) var hasUnsavedChanges = false

    /// Baseline captured at launch and at each Save. `discardChanges()` restores it so Discard
    /// truly reverts the session's edits — not just the dirty flag.
    private var savedBaseline = Baseline.empty

    private struct Baseline {
        var working: [String: WorkingIntentState]
        var off: [String: OffIntentState]
        var topologies: [String: DayTopology]
        var notes: [String: DayNote]
        var availability: [String: Set<ShiftAvailabilityType>]
        var manualOff: Set<String>
        static let empty = Baseline(working: [:], off: [:], topologies: [:],
                                    notes: [:], availability: [:], manualOff: [])
    }

    private func captureBaseline() -> Baseline {
        Baseline(working: workingIntents, off: offIntents, topologies: topologies,
                 notes: notes, availability: offAvailability, manualOff: manualOffDays)
    }

    private func markDirty() { hasUnsavedChanges = true }

    /// SAVE: snapshots the current state as the new baseline, clears the dirty flag, and
    /// bumps the revision so the trade feeds recompute once.
    func markIntentsSaved() {
        intentsRevision += 1
        savedBaseline = captureBaseline()
        hasUnsavedChanges = false
    }

    /// DISCARD: reverts every intent map to the last saved baseline and clears the dirty flag.
    func discardChanges() {
        workingIntents  = savedBaseline.working
        offIntents      = savedBaseline.off
        topologies      = savedBaseline.topologies
        notes           = savedBaseline.notes
        offAvailability = savedBaseline.availability
        manualOffDays   = savedBaseline.manualOff
        hasUnsavedChanges = false
    }

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
    /// Off days the user customized by hand — the openness shortcut won't overwrite these.
    private(set) var manualOffDays: Set<String> {
        didSet { UserDefaults.standard.set(Array(manualOffDays), forKey: Keys.manualOff) }
    }

    // MARK: Derived (drop-in replacement for TradeIntentStore.seekingDayIDs)

    /// Working days the user wants to trade away. Computed from the one stored
    /// map, so it can never disagree with the intent UI.
    var seekingDayIDs: Set<String> {
        Set(workingIntents.filter { $0.value == .dontWantToWork }.keys)
    }

    /// Off days the user refuses to be asked to work (Must-Be-Off) and working days
    /// they refuse to trade away (Keep). Published on the profile so the matcher can
    /// hard-exclude them cross-user — without these the engine offers a Must-Be-Off
    /// day (the June-23 bug). SPEC S-ENG-9/10.
    var mustBeOffDayIDs: Set<String> { Set(offIntents.filter { $0.value == .mustBeOff }.keys) }
    var keepDayIDs: Set<String> { Set(workingIntents.filter { $0.value == .mustWork }.keys) }
    var wantToWorkDayIDs: Set<String> { Set(offIntents.filter { $0.value == .wantToWork }.keys) }

    /// Count of days carrying an active (non-neutral) trade intent — drives the
    /// Intents-tab badge so the user can see at a glance they've marked intents. (D2a)
    var activeIntentCount: Int {
        workingIntents.values.filter { $0 != .neutralOpen }.count
            + offIntents.values.filter { $0 != .neutralOpen }.count
    }

    /// The intents that actually DRIVE matching (#3): Want-to-Trade (a working day I'd give away) +
    /// Want-to-Work (an off day I'd pick up). Protective intents (Keep / Must-Be-Off) aren't factors.
    var tradeIntentCount: Int {
        (workingIntentCounts[.dontWantToWork] ?? 0) + (offIntentCounts[.wantToWork] ?? 0)
    }

    /// Per-intent counts for the color-coded tier bubbles (D2a). Keyed by the enum so
    /// the UI maps to `.brickColor`/`.label`. PURE (no view).
    var workingIntentCounts: [WorkingIntentState: Int] {
        Dictionary(grouping: workingIntents.values, by: { $0 }).mapValues(\.count)
    }
    var offIntentCounts: [OffIntentState: Int] {
        Dictionary(grouping: offIntents.values, by: { $0 }).mapValues(\.count)
    }

    // MARK: Init + one-time migration

    private init() {
        workingIntents  = Self.load(Keys.working) ?? [:]
        offIntents      = Self.load(Keys.off) ?? [:]
        topologies      = Self.load(Keys.topology) ?? [:]
        notes           = Self.load(Keys.notes) ?? [:]
        offAvailability = Self.load(Keys.availability) ?? [:]
        manualOffDays   = Set(UserDefaults.standard.stringArray(forKey: Keys.manualOff) ?? [])
        migrateFromTradeIntentStoreIfNeeded()
        savedBaseline = captureBaseline()   // on-disk state is the saved baseline at launch
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
        markDirty()
    }

    func setOffIntent(_ state: OffIntentState?, forDay dayID: String) {
        manualOffDays.insert(dayID)   // hand-edited → preserve from the openness shortcut
        if let state { offIntents[dayID] = state } else { offIntents[dayID] = nil }
        markDirty()
    }

    func setTopology(_ topology: DayTopology?, forDay dayID: String) {
        if let topology, topology != .standard { topologies[dayID] = topology }
        else { topologies[dayID] = nil }
        markDirty()
    }

    func setNote(_ note: DayNote?, forDay dayID: String) {
        if let note, !note.message.isEmpty { notes[dayID] = note } else { notes[dayID] = nil }
        markDirty()
    }

    /// Toggle one shift type in an off-day's availability. Sets/clears the day's
    /// `.wantToWork` intent to stay consistent with whether any type is selected.
    func toggleAvailability(_ type: ShiftAvailabilityType, forDay dayID: String) {
        manualOffDays.insert(dayID)   // hand-edited → preserve from the openness shortcut
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
        markDirty()
    }

    /// Openness is a SHORTCUT that bulk-sets the per-day availability pills (the
    /// pills are what matching uses), preserving any day you've hand-edited. It
    /// NEVER paints "want to work" — openness is about what matching may find, not
    /// an active desire to work, so the calendar stays NEUTRAL either way:
    ///   • .all      → mark every legal pickup type; matching accepts any pickup.
    ///   • .bookends → mark every legal pickup type; matching accepts only pickups
    ///                 that don't split the break (the NO-SPLIT rule is enforced at
    ///                 match time in `wouldPickUp`, not by hiding days here).
    ///   • .none     → every off day unavailable → all matches fail in the engine.
    /// Only manual per-day edits or Mercenary mode paint "want to work".
    func applyOpenness(_ level: TradeOpenness, shifts: [Shift]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let overrides = SettingsManager.shared.opennessOverrides

        for s in shifts where s.isOff && s.date >= today {
            let dayID = s.id
            if manualOffDays.contains(dayID) { continue }   // preserve manual edits
            // A date-range override wins over the base openness for its span.
            let effective = overrides.first { $0.covers(dayID) }?.openness ?? level
            switch effective {
            case .none:
                offAvailability[dayID] = nil
                offIntents[dayID] = .mustBeOff
            case .all, .bookends:
                let legal = Legality.legalTypes(forDayID: dayID, shifts: shifts)
                offAvailability[dayID] = legal.isEmpty ? nil : legal
                offIntents[dayID] = .neutralOpen   // neutral for both .all and .bookends
            }
        }
    }

    /// The future off days whose EFFECTIVE openness (base + range overrides) is
    /// `.bookends` — published so peers' matching can gate those days per-day.
    func bookendGatedDays(base: TradeOpenness, shifts: [Shift]) -> [String] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let overrides = SettingsManager.shared.opennessOverrides
        return shifts.filter { $0.isOff && $0.date >= today }.compactMap { s in
            let eff = overrides.first { $0.covers(s.id) }?.openness ?? base
            return eff == .bookends ? s.id : nil
        }
    }

    /// Mercenary mode is an aggressive override: when ON, paint every future off day
    /// "want to work" with all legal pills (you'll take anything — bookends don't
    /// matter; the match engine bypasses the soft gates entirely). When OFF, revert
    /// to the standard openness shortcut. Hand-edited days are preserved either way.
    func applyMercenary(_ on: Bool, openness level: TradeOpenness, shifts: [Shift]) {
        guard on else { applyOpenness(level, shifts: shifts); return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for s in shifts where s.isOff && s.date >= today {
            let dayID = s.id
            if manualOffDays.contains(dayID) { continue }   // preserve manual edits
            let legal = Legality.legalTypes(forDayID: dayID, shifts: shifts)
            offAvailability[dayID] = legal.isEmpty ? nil : legal
            offIntents[dayID] = legal.isEmpty ? .neutralOpen : .wantToWork
        }
    }

    /// Removes the worked/off intent for a date (keeps topology + note).
    func clearIntent(forDay dayID: String) {
        workingIntents[dayID] = nil
        offIntents[dayID] = nil
        offAvailability[dayID] = nil
        manualOffDays.remove(dayID)   // back under the openness shortcut's control
        markDirty()
    }

    // MARK: Reads

    func workingIntent(forDay dayID: String) -> WorkingIntentState? { workingIntents[dayID] }
    func offIntent(forDay dayID: String) -> OffIntentState? { offIntents[dayID] }
    func topology(forDay dayID: String) -> DayTopology {
        if let t = topologies[dayID] { return t }            // user override wins
        return Holidays.isHighDemand(dayID) ? .highDemand : .standard
    }
    func note(forDay dayID: String) -> DayNote? { notes[dayID] }
    func availability(forDay dayID: String) -> Set<ShiftAvailabilityType> { offAvailability[dayID] ?? [] }

    // MARK: Snapshot-cleanse (DIFF-BASED — see SPEC_STRUCTURAL.md S-PARSE-2)

    /// PURE core (no side effects, no singleton) so it is trivially testable.
    /// Given the schedule diff between the previous and the new master, returns the
    /// day IDs whose intents must be RESET (`reset` = added ∪ removed ∪ changed) and
    /// the subset that are GONE (`gone` = removed — their notes drop too).
    ///
    /// INVARIANT (S-PARSE-2): an UNCHANGED day is never in `reset`. Days outside the
    /// diff entirely (e.g. not in this import window) are never touched. This is the
    /// fix for the "re-upload wiped all my intents" bug — the old code keyed off
    /// "is this day off / missing" instead of "did this day actually change".
    static func reconcileTargets(diff: ScheduleDiff) -> (reset: Set<String>, gone: Set<String>) {
        let gone = Set(diff.removed.map(\.id))
        let reset = Set(diff.added.map(\.id))
            .union(gone)
            .union(diff.changed.map(\.new.id))
        return (reset, gone)
    }

    /// Applies `reconcileTargets` to the stored intents. Resets ONLY the machine
    /// intents (working/off/availability/topology) for days that actually changed;
    /// drops the note only for days that are GONE; leaves every unchanged day's
    /// intents AND notes byte-for-byte. Returns the days whose intent was wiped (so
    /// the UI can flag them for re-marking).
    @discardableResult
    func reconcile(diff: ScheduleDiff) -> Set<String> {
        let (reset, gone) = Self.reconcileTargets(diff: diff)
        // The new schedule facts for changed/added days — used to auto-mark vacation.
        var newByDay: [String: Shift] = [:]
        for s in diff.added { newByDay[s.id] = s }
        for c in diff.changed { newByDay[c.new.id] = c.new }

        var wiped = Set<String>()
        for day in reset {
            let hadIntent = workingIntents[day] != nil || offIntents[day] != nil
                || offAvailability[day] != nil || topologies[day] != nil
            workingIntents[day]  = nil
            offIntents[day]      = nil
            offAvailability[day] = nil
            topologies[day]      = nil
            manualOffDays.remove(day)                 // back under the openness shortcut
            if gone.contains(day) { notes[day] = nil } // removed day → drop its note too

            // Vacation auto-intent (S-PARSE-2): the parser already removed the working
            // shift (day is now OFF + leaveCode "V"). Set a SOFT, user-changeable
            // Must-Be-Off + "vacation" note — never overwriting a note the user wrote.
            if newByDay[day]?.leaveCode == "V" {
                offIntents[day] = .mustBeOff
                manualOffDays.insert(day)             // shield from the openness bulk shortcut
                if notes[day] == nil {
                    notes[day] = DayNote(dayID: day, message: "vacation", reason: .vacation)
                }
            }
            if hadIntent { wiped.insert(day) }
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
        static let manualOff = "batman.v2.manualOffDays"
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
