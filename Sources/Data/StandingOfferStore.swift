// StandingOfferStore.swift
// Build 6 MUST-have — STANDING CONDITIONAL OFFERS ("trade X to get Y"). Persistent offers the engine
// re-checks every recompute; when a peer can satisfy both sides it alerts (and the user can propose in one
// tap). Local persistence + cross-device sync via the PrivateState blob (LWW). The matching itself is
// `TradeRouter.evaluateStandingOffers`, which reuses the cached MatchContext + the radar's eligibility core.

import Foundation
import Observation

@MainActor
@Observable
final class StandingOfferStore {
    static let shared = StandingOfferStore()

    private(set) var offers: [StandingOffer] = []
    /// Current satisfying peers per offer (from the last evaluate).
    private(set) var matchesByOffer: [String: [StandingMatch]] = [:]
    /// LWW clock for cross-device sync — advanced on every user edit (create/update/delete/toggle).
    private(set) var updatedAt: Date = .distantPast

    /// Offers already known to be satisfiable — a "notify once" baseline (mirrors MatchStore's).
    private var seenSatisfiedOfferIDs: Set<String> = []
    private var hasBaselined: Bool

    private init() {
        offers = Self.decode(UserDefaults.standard.data(forKey: Keys.offers)) ?? []
        seenSatisfiedOfferIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.seen) ?? [])
        hasBaselined = UserDefaults.standard.bool(forKey: Keys.baselined)
        updatedAt = (UserDefaults.standard.object(forKey: Keys.updatedAt) as? Date) ?? .distantPast
    }

    func matches(for offerID: String) -> [StandingMatch] { matchesByOffer[offerID] ?? [] }
    func isSatisfiable(_ offerID: String) -> Bool { !(matchesByOffer[offerID]?.isEmpty ?? true) }

    // MARK: Mutations (each bumps the LWW clock, persists, and pushes)

    @discardableResult
    func add(giveDayIDs: [String], getDayIDs: [String], kind: TradeKind, note: String) -> StandingOffer {
        let offer = StandingOffer(id: UUID().uuidString, giveDayIDs: giveDayIDs, getDayIDs: getDayIDs,
                                  kind: kind, note: note, active: true, createdAt: Date())
        offers.append(offer); commit()
        return offer
    }
    func update(_ offer: StandingOffer) {
        guard let i = offers.firstIndex(where: { $0.id == offer.id }) else { return }
        offers[i] = offer; commit()
    }
    func remove(_ id: String) { offers.removeAll { $0.id == id }; matchesByOffer[id] = nil; commit() }
    func setActive(_ id: String, _ on: Bool) {
        guard let i = offers.firstIndex(where: { $0.id == id }) else { return }
        offers[i].active = on; commit()
    }

    private func commit() {
        updatedAt = Date()
        persistLocal()
        Task { await PrivateStateStore.shared.publishLocalStandingOffers() }
    }

    private func persistLocal() {
        UserDefaults.standard.set(Self.encode(offers), forKey: Keys.offers)
        UserDefaults.standard.set(updatedAt, forKey: Keys.updatedAt)
    }

    // MARK: Evaluate (called on launch / refresh) — matches + notify-once for newly satisfiable offers.

    func evaluate() async {
        let me = SettingsManager.shared.username
        guard !me.isEmpty else { return }
        let result = await TradeRouter.evaluateStandingOffers(offers, excluding: me)
        matchesByOffer = result
        let satisfied = Set(result.compactMap { $0.value.isEmpty ? nil : $0.key })
        let newly = hasBaselined ? satisfied.subtracting(seenSatisfiedOfferIDs) : []
        if !newly.isEmpty {
            // AUTO-MATCH (toggle ON): when a newly-fillable offer has exactly ONE fitting peer, auto-send the
            // trade to them (a real 1:1 request — they get the incoming-request push; the dedup guard stops a
            // double-send). Multiple peers, or toggle OFF → just notify the owner to pick manually.
            let auto = SettingsManager.shared.standingOfferAutoMatch
            var alerts: [NotificationManager.StandingAlert] = []
            for id in newly {
                guard let offer = offers.first(where: { $0.id == id }), let peers = result[id], !peers.isEmpty else { continue }
                let m = peers[0]
                let give = m.giveDayIDs.first ?? offer.giveDayIDs.first ?? ""
                let get  = m.getDayIDs.first ?? offer.getDayIDs.first ?? ""
                if auto, peers.count == 1 {
                    await MessagingStore.shared.sendRequest(
                        to: m.peerID, toName: m.peerName,
                        note: "Standing offer: give \(StandingFmt.list(m.giveDayIDs)), get \(StandingFmt.list(m.getDayIDs)).",
                        take: m.getDayIDs, give: m.giveDayIDs, origin: .intents)
                    alerts.append(.init(getDayID: get, giveDayID: give, peer: m.peerName, autoSent: true))
                } else {
                    alerts.append(.init(getDayID: get, giveDayID: give, peer: m.peerName, autoSent: false))
                }
            }
            await NotificationManager.shared.notifyStanding(alerts)
        }
        seenSatisfiedOfferIDs = satisfied
        UserDefaults.standard.set(Array(satisfied), forKey: Keys.seen)
        if !hasBaselined { hasBaselined = true; UserDefaults.standard.set(true, forKey: Keys.baselined) }
    }

    // MARK: Cross-device sync (rides the PrivateState blob, LWW by `updatedAt`)

    func exportJSON() -> String? { Self.encode(offers).flatMap { String(data: $0, encoding: .utf8) } }
    func applyRemote(_ json: String, at date: Date) {
        guard let data = json.data(using: .utf8), let decoded = Self.decode(data) else { return }
        offers = decoded; updatedAt = date; persistLocal()
    }

    private static func encode(_ o: [StandingOffer]) -> Data? { try? JSONEncoder().encode(o) }
    private static func decode(_ d: Data?) -> [StandingOffer]? { d.flatMap { try? JSONDecoder().decode([StandingOffer].self, from: $0) } }

    private enum Keys {
        static let offers    = "batman.standing.offers"
        static let seen      = "batman.standing.seenSatisfied"
        static let baselined = "batman.standing.baselined"
        static let updatedAt = "batman.standing.updatedAt"
    }
}
