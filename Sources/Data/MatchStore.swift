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
    /// Baseline of mutual-match keys already alerted (a match key = peerID + its sorted days). A mutual match
    /// alerts BOTH parties (each device detects it), regardless of watch.
    private var seenMatchKeys: Set<String> = []
    /// Give-days already auto-sent (so each auto-matches once; re-arms if it stops matching then matches again).
    private var autoSentGiveDays: Set<String> = []
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
        seenMatchKeys  = Set(UserDefaults.standard.stringArray(forKey: Keys.seenMatch) ?? [])
        autoSentGiveDays = Set(UserDefaults.standard.stringArray(forKey: Keys.autoSent) ?? [])
        hasBaselined   = UserDefaults.standard.bool(forKey: Keys.baselined)
        radarStateUpdatedAt = (UserDefaults.standard.object(forKey: Keys.stateUpdatedAt) as? Date) ?? .distantPast
        loadCachedIndex()   // show last session's Trade List instantly on cold launch; recompute refreshes it
    }

    // MARK: Disk cache of the computed index (so the Trade List renders instantly on a cold launch)

    private struct RadarCache: Codable {
        var owner: String
        var pickupDays: [String]; var takerDays: [String]
        var matchesByDay: [String: [TradeRouter.RadarMatch]]
        var dayIndex: [String: TradeRouter.DayRadar]
        var lastRefreshed: Date
    }
    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dx-radar-index.json")
    }
    private func loadCachedIndex() {
        guard let url = Self.cacheURL, let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(RadarCache.self, from: data),
              c.owner == SettingsManager.shared.username else { return }
        pickupAvailableDays = Set(c.pickupDays); takerAvailableDays = Set(c.takerDays)
        matchesByDay = c.matchesByDay; dayIndex = c.dayIndex; lastRefreshed = c.lastRefreshed
    }
    private func saveCachedIndex() {
        guard let url = Self.cacheURL, let refreshed = lastRefreshed else { return }
        let c = RadarCache(owner: SettingsManager.shared.username,
                           pickupDays: Array(pickupAvailableDays), takerDays: Array(takerAvailableDays),
                           matchesByDay: matchesByDay, dayIndex: dayIndex, lastRefreshed: refreshed)
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: url, options: .atomic) }
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
        let firstRun = !hasBaselined
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
        // Mutual matches alert BOTH parties (each device detects it), watched or not — once per match.
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let out = DateFormatter(); out.dateFormat = "EEE, MMM d"
        var matchKeys = Set<String>(); var newMutual: [(peer: String, dayID: String, dayLabel: String)] = []
        for m in r.matches {
            let days = (m.giveDayIDs + m.takeDayIDs).sorted()
            let key = m.peerID + "|" + days.joined(separator: ",")
            matchKeys.insert(key)
            if hasBaselined, !seenMatchKeys.contains(key), let first = days.first {
                let label = df.date(from: first).map { out.string(from: $0) } ?? first
                newMutual.append((peer: m.peerName, dayID: first, dayLabel: label))
            }
        }
        if !newMutual.isEmpty { await NotificationManager.shared.notifyMutualMatch(newMutual) }
        await autoMatchFromMatches(r.matches, firstRun: firstRun)   // unified auto-send off marked intents
        seenMatchKeys = matchKeys
        UserDefaults.standard.set(Array(matchKeys), forKey: Keys.seenMatch)
        // Record the CURRENT opportunities as the baselines (persisted) so each notifies at most once.
        seenPickupDays = r.pickupDays; seenTakerDays = r.takerDays
        UserDefaults.standard.set(Array(r.pickupDays), forKey: Keys.seen)
        UserDefaults.standard.set(Array(r.takerDays), forKey: Keys.seenTaker)
        if !hasBaselined { hasBaselined = true; UserDefaults.standard.set(true, forKey: Keys.baselined) }
        saveCachedIndex()   // persist so the next cold launch shows this instantly
        return (r.pickupDays, r.takerDays)
    }

    /// Count of current opportunities (both directions) the user hasn't WATCHED yet — folded into the daily
    /// digest so unwatched matches still surface without per-day spam (delivery is on-open until push lands).
    var unwatchedOpportunityCount: Int {
        pickupAvailableDays.union(takerAvailableDays).subtracting(watchedDays).count
    }

    /// UNIFIED AUTO-MATCH: your marked intents ARE the standing offers. For each of your want-to-trade days
    /// that a mutual match exists for, auto-send the swap to the top few complementary peers (claimed
    /// accounts only), sharing one offerID per give-day for first-accept-wins. Gated by the Trade Settings
    /// toggle; the FIRST run only records a baseline so it never mass-sends pre-existing matches; sends once
    /// per give-day (re-arms if the day stops matching then matches again). Auto-sent trades show in
    /// Auto-Matches / Requests like any proposal.
    static let autoMatchCap = 3
    private func autoMatchFromMatches(_ matches: [TradeRouter.RadarMatch], firstRun: Bool) async {
        var byGive: [String: [(peer: TradeRouter.RadarMatch, take: String)]] = [:]
        for m in matches where TradeProfileStore.shared.isActiveAccount(m.peerID) {
            guard let take = m.takeDayIDs.first else { continue }
            for give in m.giveDayIDs { byGive[give, default: []].append((peer: m, take: take)) }
        }
        let matchable = Set(byGive.keys)
        // First run, or toggle off → just record the baseline; never blast pre-existing matches.
        guard !firstRun, SettingsManager.shared.standingOfferAutoMatch else {
            autoSentGiveDays = matchable
            UserDefaults.standard.set(Array(autoSentGiveDays), forKey: Keys.autoSent)
            return
        }
        let priors = MessagingStore.shared.acceptancePriorMap()
        var alerts: [NotificationManager.StandingAlert] = []
        for (give, cands) in byGive where !autoSentGiveDays.contains(give) {
            let ranked = cands.sorted { (priors[$0.peer.peerID] ?? 0) > (priors[$1.peer.peerID] ?? 0) }.prefix(Self.autoMatchCap)
            guard let lead = ranked.first else { continue }
            let offerID = UUID().uuidString
            for c in ranked {
                await MessagingStore.shared.sendRequest(
                    to: c.peer.peerID, toName: c.peer.peerName, note: "Auto-match trade.",
                    take: [c.take], give: [give],
                    offerID: ranked.count > 1 ? offerID : nil, origin: .intents)
            }
            autoSentGiveDays.insert(give)
            alerts.append(.init(getDayID: lead.take, giveDayID: give, peer: lead.peer.peerName, sentCount: ranked.count))
        }
        autoSentGiveDays.formIntersection(matchable)   // forget days that stopped matching, so they can re-arm
        UserDefaults.standard.set(Array(autoSentGiveDays), forKey: Keys.autoSent)
        if !alerts.isEmpty { await NotificationManager.shared.notifyStanding(alerts) }
    }

    /// A day has a star — the SAME marker for both directions: an off-day pickup you can work, OR a working
    /// day someone wants to work (a taker for your shift).
    func hasStar(_ dayID: String) -> Bool { pickupAvailableDays.contains(dayID) || takerAvailableDays.contains(dayID) }
    func matches(on dayID: String) -> [TradeRouter.RadarMatch] { matchesByDay[dayID] ?? [] }

    /// O(1) day-detail rows from the precomputed index, sorted for display.
    func rows(forDay dayID: String) -> (pickups: [TradeRouter.DayTradeRow], wantToWork: [TradeRouter.DayTradeRow]) {
        let d = dayIndex[dayID] ?? TradeRouter.DayRadar()
        return (TradeRouter.sortDayRows(d.pickups), d.wantToWork.sorted { $0.peerName < $1.peerName })
    }

    func setWatched(_ dayID: String, _ on: Bool) {
        if on { watchedDays.insert(dayID) } else { watchedDays.remove(dayID) }
        UserDefaults.standard.set(Array(watchedDays), forKey: Keys.watched)
        // Watch is a USER action → advance the LWW clock and push. (Seen changes on recompute don't advance
        // the clock, so a background recompute can't clobber another device's watch toggle.)
        radarStateUpdatedAt = Date()
        UserDefaults.standard.set(radarStateUpdatedAt, forKey: Keys.stateUpdatedAt)
        Task { await PrivateStateStore.shared.publishLocalRadar() }
    }
    func isWatched(_ dayID: String) -> Bool { watchedDays.contains(dayID) }

    // MARK: Cross-device sync (rides the PrivateState blob, LWW by `radarStateUpdatedAt`)

    private(set) var radarStateUpdatedAt: Date = .distantPast

    private struct RadarSnapshot: Codable { var watched: [String]; var seenPickup: [String]; var seenTaker: [String] }

    /// JSON of the syncable radar state (watch + notify baselines) for the private-DB blob.
    func exportRadarJSON() -> String? {
        let snap = RadarSnapshot(watched: Array(watchedDays), seenPickup: Array(seenPickupDays),
                                 seenTaker: Array(seenTakerDays))
        guard let data = try? JSONEncoder().encode(snap) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Adopt a remote radar snapshot (LWW winner). Overwrites local watch + baselines.
    func applyRemoteRadar(_ json: String, at date: Date) {
        guard let data = json.data(using: .utf8),
              let snap = try? JSONDecoder().decode(RadarSnapshot.self, from: data) else { return }
        watchedDays = Set(snap.watched); seenPickupDays = Set(snap.seenPickup); seenTakerDays = Set(snap.seenTaker)
        radarStateUpdatedAt = date
        UserDefaults.standard.set(Array(watchedDays), forKey: Keys.watched)
        UserDefaults.standard.set(Array(seenPickupDays), forKey: Keys.seen)
        UserDefaults.standard.set(Array(seenTakerDays), forKey: Keys.seenTaker)
        UserDefaults.standard.set(date, forKey: Keys.stateUpdatedAt)
    }

    private enum Keys {
        static let watched        = "batman.radar.watchedDays"
        static let seen           = "batman.radar.seenPickupDays"
        static let seenTaker      = "batman.radar.seenTakerDays"
        static let seenMatch      = "batman.radar.seenMatchKeys"
        static let autoSent       = "batman.radar.autoSentGiveDays"
        static let baselined      = "batman.radar.baselined"
        static let stateUpdatedAt = "batman.radar.stateUpdatedAt"
    }
}
