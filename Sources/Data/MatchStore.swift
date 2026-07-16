// MatchStore.swift
// Match Radar (DX-MATCH-RADAR-SPEC v3.1) — the single source of truth for the calendar star, the
// per-day mutual matches, and the local "seen" / "watch" read-markers. Observed by the calendar + Home
// chips, so they re-render on recompute. NO CloudKit in v1: star/watch/seen are LOCAL read-markers; the
// underlying data comes from `TradeRouter.radarScan` (which reads the synced roster + peer profiles).

import Foundation
import Observation

@MainActor
@Observable
final class MatchStore {
    static let shared = MatchStore()

    /// Direction-A opportunity: days where ≥1 peer's want-to-trade shift is legal for me → the STAR.
    private(set) var pickupAvailableDays: Set<String> = []
    /// Direction-B opportunity: MY working days a want-to-work taker exists for (drives on-day notifications).
    private(set) var takerAvailableDays: Set<String> = []
    /// Mutual matches indexed per day (give ∪ take) → the passive Matches lane + notifications.
    private(set) var matchesByDay: [String: [TradeRouter.RadarMatch]] = [:]
    /// Precomputed per-day rows (both directions) so the day-detail Trade List is an O(1) lookup, not a scan.
    private(set) var dayIndex: [String: TradeRouter.DayRadar] = [:]
    /// The Watch toggle (per day). Local v1 (cross-device sync is a later add).
    private(set) var watchedDays: Set<String> = []
    /// Deep-link target: set when the user taps a radar notification; the UI opens that day's Trade List
    /// then clears it. (Observed by ContentView + HomeView.)
    var pendingDayID: String?
    /// Durable baselines = the opportunity-days known as of the last recompute (persisted; the live sets are
    /// NOT). A day not in here is "newly gained" → notifies once, then joins the baseline.
    private(set) var seenPickupDays: Set<String> = []
    private(set) var seenTakerDays: Set<String> = []
    private(set) var lastRefreshed: Date?
    /// True once a computed. The FIRST-EVER recompute records current opportunities silently (no spam for
    /// pre-existing ones); only later recomputes notify. Also gates the day-detail cold-start compute.
    var hasComputed: Bool { lastRefreshed != nil }
    private var hasBaselined: Bool

    enum Scope { case full, intentsOnly, local }

    private init() {
        watchedDays    = Set(UserDefaults.standard.stringArray(forKey: Keys.watched) ?? [])
        seenPickupDays = Set(UserDefaults.standard.stringArray(forKey: Keys.seen) ?? [])
        seenTakerDays  = Set(UserDefaults.standard.stringArray(forKey: Keys.seenTaker) ?? [])
        hasBaselined   = UserDefaults.standard.bool(forKey: Keys.baselined)
    }

    /// PURE, testable: opportunity-days that appeared since the last-seen baseline (a NEW alert).
    static func newlyGainedDays(old: Set<String>, new: Set<String>) -> Set<String> { new.subtracting(old) }

    /// Recompute the radar in ONE off-main pass. `.full`/`.intentsOnly` pull peer intents first; `.local`
    /// skips the network. Populates the star, takers, matches, and the per-day index; fires new-opportunity
    /// notifications (both directions).
    @discardableResult
    func recompute(scope: Scope = .intentsOnly) async -> (pickups: Set<String>, takers: Set<String>) {
        let me = SettingsManager.shared.username
        guard !me.isEmpty else { return ([], []) }
        if scope != .local { await TradeProfileStore.shared.refreshOthers() }
        let r = await TradeRouter.radarScan(excluding: me)
        // gained = opportunities NEW since baseline. First-ever run (no baseline) → none, so we never alert
        // on opportunities that predate the feature going live.
        let gainedPickups = hasBaselined ? Self.newlyGainedDays(old: seenPickupDays, new: r.pickupDays) : []
        let gainedTakers  = hasBaselined ? Self.newlyGainedDays(old: seenTakerDays,  new: r.takerDays)  : []
        pickupAvailableDays = r.pickupDays
        takerAvailableDays  = r.takerDays
        dayIndex = r.dayIndex
        var byDay: [String: [TradeRouter.RadarMatch]] = [:]
        for m in r.matches {
            for d in Set(m.giveDayIDs + m.takeDayIDs) { byDay[d, default: []].append(m) }
        }
        matchesByDay = byDay
        lastRefreshed = Date()
        if !gainedPickups.isEmpty || !gainedTakers.isEmpty {
            await NotificationManager.shared.notifyRadar(gainedPickups: gainedPickups, gainedTakers: gainedTakers,
                                                         watched: watchedDays)
        }
        // Record the CURRENT opportunities as the baselines (persisted) so each notifies at most once.
        seenPickupDays = r.pickupDays; seenTakerDays = r.takerDays
        UserDefaults.standard.set(Array(r.pickupDays), forKey: Keys.seen)
        UserDefaults.standard.set(Array(r.takerDays), forKey: Keys.seenTaker)
        if !hasBaselined { hasBaselined = true; UserDefaults.standard.set(true, forKey: Keys.baselined) }
        return (r.pickupDays, r.takerDays)
    }

    /// A day has a star (a legal pickup for me exists). (Star stays direction-A only, per spec.)
    func hasStar(_ dayID: String) -> Bool { pickupAvailableDays.contains(dayID) }
    func matches(on dayID: String) -> [TradeRouter.RadarMatch] { matchesByDay[dayID] ?? [] }

    /// O(1) day-detail rows from the precomputed index, sorted for display.
    func rows(forDay dayID: String) -> (pickups: [TradeRouter.DayTradeRow], wantToWork: [TradeRouter.DayTradeRow]) {
        let d = dayIndex[dayID] ?? TradeRouter.DayRadar()
        return (TradeRouter.sortDayRows(d.pickups), d.wantToWork.sorted { $0.peerName < $1.peerName })
    }

    func setWatched(_ dayID: String, _ on: Bool) {
        if on { watchedDays.insert(dayID) } else { watchedDays.remove(dayID) }
        UserDefaults.standard.set(Array(watchedDays), forKey: Keys.watched)
    }
    func isWatched(_ dayID: String) -> Bool { watchedDays.contains(dayID) }

    private enum Keys {
        static let watched   = "batman.radar.watchedDays"
        static let seen      = "batman.radar.seenPickupDays"
        static let seenTaker = "batman.radar.seenTakerDays"
        static let baselined = "batman.radar.baselined"
    }
}
