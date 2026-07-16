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
    /// v4 SUGGESTED lane (SSOT): per active peer, my 3-/2-mutual give days + the peer's offered return days.
    /// These are NOT auto-sent — the inbox surfaces them for a manual propose. Computed each recompute.
    private(set) var suggestedMatches: [SuggestedMatch] = []

    /// One peer's Suggested entry — a real trade exists but it needs you to pick day(s) (3-/2-mutual).
    struct SuggestedMatch: Sendable, Hashable, Identifiable {
        let peerID: String
        let peerName: String
        let giveDayIDs: [String]   // my want-to-trade days (3/2-mutual with this peer) I'd offer
        let takeDayIDs: [String]   // the peer's offered return days (candidates for the two-way calendar)
        var id: String { peerID }
    }
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
        // GLOBAL FILTER: a day already locked in an accepted trade never surfaces (star/rows/matches/suggested).
        // Keep, Must-Be-Off, past days, and relief-horizon are already excluded in the matcher; carryover
        // vacation is resolved to a plain OFF day at ingest.
        let committed = MessagingStore.shared.committedDayIDs()
        let pickupDays = r.pickupDays.subtracting(committed)
        let takerDays  = r.takerDays.subtracting(committed)
        // gained = opportunities NEW since baseline. First-ever run (no baseline) → none, so we never alert
        // on opportunities that predate the feature going live.
        let gainedPickups = hasBaselined ? Self.newlyGainedDays(old: seenPickupDays, new: pickupDays) : []
        let gainedTakers  = hasBaselined ? Self.newlyGainedDays(old: seenTakerDays,  new: takerDays)  : []
        pickupAvailableDays = pickupDays
        takerAvailableDays  = takerDays
        dayIndex = r.dayIndex.filter { !committed.contains($0.key) }
        // A match only surfaces as a passive "Suggested" card / mutual-match alert when it's an ACTIVE account
        // AND has day-for-day content to render. ECB-only matches (no give/take) still ride `r.matches` for
        // auto-send, but never show as an empty "give 0, get 0" card; inactive/inferred profiles never appear.
        let visibleMatches = r.matches.filter {
            TradeProfileStore.shared.isActiveAccount($0.peerID) && !($0.giveDayIDs.isEmpty && $0.takeDayIDs.isEmpty)
        }
        var byDay: [String: [TradeRouter.RadarMatch]] = [:]
        for m in visibleMatches {
            for d in Set(m.giveDayIDs + m.takeDayIDs) where !committed.contains(d) { byDay[d, default: []].append(m) }
        }
        matchesByDay = byDay
        // v4 SUGGESTED (SSOT): classify each active peer's gives; keep the 3-/2-mutual bucket for manual propose.
        // Computed regardless of the auto-match toggle (Suggested shows even when auto-send is off).
        let wtwNow = DayIntentStore.shared.wantToWorkDayIDs
        var sugg: [SuggestedMatch] = []
        for m in r.matches where TradeProfileStore.shared.isActiveAccount(m.peerID) {
            let gives = Array(Set(m.giveDayIDs + m.ecbGiveDayIDs))
            let kinds = Dictionary(gives.map { ($0, DayIntentStore.shared.tradeKind(forDay: $0)) }, uniquingKeysWith: { a, _ in a })
            let split = TradeRouter.classifyGives(gives, takes: m.takeDayIDs, myWantToWork: wtwNow, kindOfGive: kinds)
            let suggestGives = split.suggested.filter { !committed.contains($0) }   // never suggest a locked day
            if !suggestGives.isEmpty {
                sugg.append(SuggestedMatch(peerID: m.peerID, peerName: m.peerName,
                                           giveDayIDs: suggestGives.sorted(),
                                           takeDayIDs: m.takeDayIDs.filter { !committed.contains($0) }))
            }
        }
        suggestedMatches = sugg.sorted { $0.peerName < $1.peerName }
        lastRefreshed = Date()
        if !gainedPickups.isEmpty || !gainedTakers.isEmpty {
            await NotificationManager.shared.notifyRadar(gainedPickups: gainedPickups, gainedTakers: gainedTakers,
                                                         watched: watchedDays)
        }
        // Mutual matches alert BOTH parties (each device detects it), watched or not — once per match.
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let out = DateFormatter(); out.dateFormat = "EEE, MMM d"
        var matchKeys = Set<String>(); var newMutual: [(peer: String, dayID: String, dayLabel: String)] = []
        for m in visibleMatches {
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
        seenPickupDays = pickupDays; seenTakerDays = takerDays
        UserDefaults.standard.set(Array(pickupDays), forKey: Keys.seen)
        UserDefaults.standard.set(Array(takerDays), forKey: Keys.seenTaker)
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
        // A give day is a day I marked Want to Trade. Its KIND decides how it auto-sends:
        //   • Day  → day-for-day only (needs a peer offering a reciprocal Want-to-Work day I'd take)
        //   • ECB  → a one-way ECB (points) offer to a peer who'd cover it — no reciprocal needed
        //   • Both → day-for-day WITH an ECB fallback the acceptor can choose, or ECB-only if no reciprocal
        let intents = DayIntentStore.shared
        let wantToWork = intents.wantToWorkDayIDs
        let committed = MessagingStore.shared.committedDayIDs()   // never auto-send a day locked in a trade
        // v4: ONLY 4-mutual swaps and ECB-only-kind days auto-send (no day choice needed). The classifier is
        // the single source of truth; 3-/2-mutual go to Suggested (computed for the UI, never auto-sent here).
        var dfd: [String: [(peer: TradeRouter.RadarMatch, take: String)]] = [:]   // give → peers with a 4-mutual (give,take)
        var ecb: [String: [TradeRouter.RadarMatch]] = [:]                          // give → peers for ECB-only auto
        for m in matches where TradeProfileStore.shared.isActiveAccount(m.peerID) {
            let gives = Array(Set(m.giveDayIDs + m.ecbGiveDayIDs))
            let kindOfGive = Dictionary(gives.map { ($0, intents.tradeKind(forDay: $0)) }, uniquingKeysWith: { a, _ in a })
            let split = TradeRouter.classifyGives(gives, takes: m.takeDayIDs, myWantToWork: wantToWork, kindOfGive: kindOfGive)
            for pair in split.autoSwaps where !committed.contains(pair.give) && !committed.contains(pair.take) {
                dfd[pair.give, default: []].append((peer: m, take: pair.take))
            }
            for give in split.autoECB where !committed.contains(give) { ecb[give, default: []].append(m) }
            // split.suggested is intentionally NOT auto-sent — the Suggested lane surfaces it for manual propose.
        }
        let matchable = Set(dfd.keys).union(ecb.keys)
        // First run, or toggle off → just record the baseline; never blast pre-existing matches.
        guard !firstRun, SettingsManager.shared.standingOfferAutoMatch else {
            autoSentGiveDays = matchable
            UserDefaults.standard.set(Array(autoSentGiveDays), forKey: Keys.autoSent)
            return
        }
        let priors = MessagingStore.shared.acceptancePriorMap()
        var alerts: [NotificationManager.StandingAlert] = []
        for give in matchable where !autoSentGiveDays.contains(give) {
            let kind = intents.tradeKind(forDay: give)
            let amount = TradeRequest.clampECB(intents.ecbAmount(forDay: give))
            let available = intents.ecbTerms(forDay: give).availableDate
            let dayForDay = dfd[give] ?? []
            if kind != .ecb, !dayForDay.isEmpty {
                // Day-for-day (Day) or a dual offer (Both) — broadcast to the top reciprocal peers.
                let ranked = dayForDay.sorted { (priors[$0.peer.peerID] ?? 0) > (priors[$1.peer.peerID] ?? 0) }.prefix(Self.autoMatchCap)
                guard let lead = ranked.first else { continue }
                let offerID = UUID().uuidString
                let offerKind: TradeKind = (kind == .both) ? .both : .day   // Both carries the ECB option too
                for c in ranked {
                    await MessagingStore.shared.sendRequest(
                        to: c.peer.peerID, toName: c.peer.peerName,
                        note: offerKind == .both ? "Auto-match trade — swap or ECB." : "Auto-match trade.",
                        take: [c.take], give: [give],
                        ecbValue: offerKind == .both ? amount : nil,
                        offerID: ranked.count > 1 ? offerID : nil, origin: .intents,
                        offerKind: offerKind, ecbAvailableDate: offerKind == .both ? available : nil)
                }
                autoSentGiveDays.insert(give)
                alerts.append(.init(getDayID: lead.take, giveDayID: give, peer: lead.peer.peerName, sentCount: ranked.count))
            } else if kind != .day, let ecbCands = ecb[give], !ecbCands.isEmpty {
                // ECB one-way: give this day for points to the top peers who'd cover it (first-accept-wins queue).
                let ranked = ecbCands.sorted { (priors[$0.peerID] ?? 0) > (priors[$1.peerID] ?? 0) }.prefix(Self.autoMatchCap)
                guard let lead = ranked.first else { continue }
                let offerID = UUID().uuidString   // ECB ALWAYS shares an offerID (even solo) so it groups into one ECB folder
                for c in ranked {
                    await MessagingStore.shared.sendRequest(
                        to: c.peerID, toName: c.peerName, note: "Auto-match ECB trade.",
                        take: [], give: [give], ecbValue: amount,
                        offerID: offerID, origin: .intents,
                        offerKind: .ecb, ecbAvailableDate: available)
                }
                autoSentGiveDays.insert(give)
                alerts.append(.init(getDayID: give, giveDayID: give, peer: lead.peerName, sentCount: ranked.count))
            }
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
