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
    /// Mutual matches indexed per day (give ∪ take) → the passive Matches lane + notifications.
    private(set) var matchesByDay: [String: [TradeRouter.RadarMatch]] = [:]
    /// The Watch toggle (per day). Local v1 (cross-device sync is a later add).
    private(set) var watchedDays: Set<String> = []
    /// Baseline of pickup-days the user has already seen — a day NOT in here but in `pickupAvailableDays`
    /// is "new" (drives the batched notification + a subtle new-emphasis).
    private(set) var seenPickupDays: Set<String> = []
    private(set) var lastRefreshed: Date?
    /// Whether we've established a baseline yet. The FIRST-EVER recompute records the current pickups
    /// silently (so the user isn't spammed with an alert for every pre-existing opportunity); only later
    /// recomputes fire new-pickup notifications.
    private var hasBaselined: Bool

    enum Scope { case full, intentsOnly, local }

    private init() {
        watchedDays    = Set(UserDefaults.standard.stringArray(forKey: Keys.watched) ?? [])
        seenPickupDays = Set(UserDefaults.standard.stringArray(forKey: Keys.seen) ?? [])
        hasBaselined   = UserDefaults.standard.bool(forKey: Keys.baselined)
    }

    /// PURE, testable: pickup-days that appeared since the last-seen baseline (a NEW star).
    static func newlyGainedDays(old: Set<String>, new: Set<String>) -> Set<String> { new.subtracting(old) }

    /// Recompute the radar. `.full`/`.intentsOnly` pull peer intents first; `.local` skips the network.
    /// Returns the days that newly gained a pickup (for the caller to notify — Stage 10).
    @discardableResult
    func recompute(scope: Scope = .intentsOnly) async -> Set<String> {
        let me = SettingsManager.shared.username
        guard !me.isEmpty else { return [] }
        if scope != .local { await TradeProfileStore.shared.refreshOthers() }
        let (pickups, matches) = await TradeRouter.radarScan(excluding: me)
        let gained = Self.newlyGainedDays(old: seenPickupDays.union(pickupAvailableDays), new: pickups)
        pickupAvailableDays = pickups
        var byDay: [String: [TradeRouter.RadarMatch]] = [:]
        for m in matches {
            for d in Set(m.giveDayIDs + m.takeDayIDs) { byDay[d, default: []].append(m) }
        }
        matchesByDay = byDay
        lastRefreshed = Date()
        if hasBaselined {
            await NotificationManager.shared.notifyRadar(gained: gained, watched: watchedDays)
        } else {
            // First-ever run: adopt the current pickups as the seen baseline so we don't alert on
            // opportunities that already existed before the feature was live.
            seenPickupDays.formUnion(pickups)
            UserDefaults.standard.set(Array(seenPickupDays), forKey: Keys.seen)
            hasBaselined = true
            UserDefaults.standard.set(true, forKey: Keys.baselined)
        }
        return gained
    }

    func markSeen(_ dayID: String) {
        guard !seenPickupDays.contains(dayID) else { return }
        seenPickupDays.insert(dayID)
        UserDefaults.standard.set(Array(seenPickupDays), forKey: Keys.seen)
    }
    /// A day has a star (a legal pickup for me exists).
    func hasStar(_ dayID: String) -> Bool { pickupAvailableDays.contains(dayID) }
    /// A star that the user hasn't seen yet (drives the subtle new-emphasis).
    func isUnseenStar(_ dayID: String) -> Bool { pickupAvailableDays.contains(dayID) && !seenPickupDays.contains(dayID) }
    func matches(on dayID: String) -> [TradeRouter.RadarMatch] { matchesByDay[dayID] ?? [] }

    func setWatched(_ dayID: String, _ on: Bool) {
        if on { watchedDays.insert(dayID) } else { watchedDays.remove(dayID) }
        UserDefaults.standard.set(Array(watchedDays), forKey: Keys.watched)
    }
    func isWatched(_ dayID: String) -> Bool { watchedDays.contains(dayID) }

    private enum Keys {
        static let watched   = "batman.radar.watchedDays"
        static let seen      = "batman.radar.seenPickupDays"
        static let baselined = "batman.radar.baselined"
    }
}
