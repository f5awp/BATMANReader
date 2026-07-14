// TradeRouter.swift
// v2 matchmaking on top of the existing TradeMatcher. Adds:
//   • packages          — reciprocal "fewest people" covers (optimal + greedy)
//   • tieredSolutions   — segments swaps into the 4 SolutionTiers for the feed
//   • nWayRoutes        — bounded 3–4-person circular trade loops
// Reuses TradeMatcher's hard gates (qualified / rested / anchored) verbatim; never
// duplicates that logic. All roster reads go through RosterStore.

import Foundation

// MARK: - Constraints (soft prefs are bypassable; hard gates always apply)

/// Soft-preference switches. Hard gates (qualification, 8h rest, weekly-hour caps,
/// `.mustBeOff`) are ALWAYS enforced and are not represented here.
struct MatchConstraints: Sendable {
    var enforceChaining: Bool          // bookend / "no floating island" screening
    var enforceTopology: Bool          // protect high-demand / milestone dates
    var enforceShiftTimeBlacklist: Bool

    static let standard = MatchConstraints(enforceChaining: true,
                                           enforceTopology: true,
                                           enforceShiftTimeBlacklist: true)

    /// "What If?" mode flips every soft preference off, widening the result set.
    static func make(isWhatIfModeActive: Bool) -> MatchConstraints {
        isWhatIfModeActive
            ? MatchConstraints(enforceChaining: false, enforceTopology: false,
                               enforceShiftTimeBlacklist: false)
            : .standard
    }
}


// MARK: - Packaged solution (one card per deal)

enum TradeMethodology: String, Sendable {
    case greedy   = "Fewest people"
    case circular = "Circular swap"
}

/// One counterparty in a reciprocal package: your shifts they take, and their
/// shifts you take back (balanced for a true day-for-day swap).
struct PackageAssignment: Sendable, Hashable, Identifiable {
    let workerID: String
    let name: String
    let giveDayIDs: [String]   // YOUR shifts this person covers (you → them)
    let takeDayIDs: [String]   // THEIR shifts you cover (them → you) — the DEFAULT (top-ranked) give-back
    /// All eligible give-back days from this peer, ranked (bookend-first, then soonest) — a superset of
    /// `takeDayIDs`. Lets the UI offer the alternatives (e.g. Jul 15 under Sep) instead of only the top pick.
    /// Empty = no alternatives surfaced (multi-day/circular/qual-swap packages).
    var takeOptions: [String] = []
    var id: String { workerID }
    var dayIDs: [String] { giveDayIDs }   // back-compat for simple displays
}

/// A complete, proposable deal: either a greedy give-away (you → coverers) or a
/// circular swap loop. Rendered as a single card with one action button.
struct TradePackage: Sendable, Hashable, Identifiable {
    let id: String
    let methodology: TradeMethodology
    let assignments: [PackageAssignment]
    let route: NWayRoute?               // present for circular (drives Execute)
    var urgency: Int = 0                // max reason-urgency over the days covered
    var isOptimal: Bool = false         // true = provably fewest people; false = fast heuristic
    // U4 sort signals. fireCount = mutual-intent (🔥) matches in the package; bookendTotal =
    // total bookends delivered across ALL sides (more = more optimal, even when open-to-all).
    var fireCount: Int = 0
    var bookendTotal: Int = 0
    // Q1: a qual-swap leg this package depends on (a give-day blocked only by qualification, with
    // a bridge available). nil = no qual swap needed. Drives the card indicator + send-time blast.
    var qualSwap: QualSwapLegData? = nil
    // H2: avg of the counterparties' learned acceptance priors (logit). A late ranking tiebreaker so,
    // all else equal, partners who historically accept float up. 0 = neutral / no history.
    var partnerPrior: Double = 0
    // TradeScore: the model's average per-leg acceptance QUALITY (0…1). Ranking tiebreak + floor signal.
    var acceptanceScore: Double = 0
    // How many of YOUR requested give-days this package covers — the PRIMARY ranking key (most coverage
    // first, so one person covering all your days floats to the top). Set at generation.
    var coverageCount: Int = 0
    // How many days YOU receive that are NOT a clean bookend for you (a random mid-week island you didn't
    // mark want-to-work). When you're open-to-all these aren't excluded, but a package with any of them
    // ranks BELOW every all-clean package (bookends ranked higher). Set at generation.
    var dirtyReceives: Int = 0
    // U-OBJ: the unified ranking number = acceptanceScore (per-leg quality) × intent-aware
    // people penalty × coverage^wCover. THE primary sort key (rankLess). Set at scoring.
    var rankScore: Double = 0
    // Urgency-weighted fraction of my SELECTED give-days covered (1 for the Intents feed).
    var coverageFrac: Double = 1
    // Mutual (intentLevel == 2) legs / total legs — drive the people penalty; kept for tests/UI.
    var mutualLegCount: Int = 0
    var legCount: Int = 0

    // EXPLICIT init — freezes the construction signature so adding the fields above doesn't
    // churn the memberwise-init symbol (stale-incremental-link fix). New fields are defaulted.
    init(id: String, methodology: TradeMethodology, assignments: [PackageAssignment],
         route: NWayRoute?, urgency: Int = 0, isOptimal: Bool = false,
         fireCount: Int = 0, bookendTotal: Int = 0, qualSwap: QualSwapLegData? = nil,
         partnerPrior: Double = 0, acceptanceScore: Double = 0, coverageCount: Int = 0) {
        self.id = id; self.methodology = methodology; self.assignments = assignments
        self.route = route; self.urgency = urgency; self.isOptimal = isOptimal
        self.fireCount = fireCount; self.bookendTotal = bookendTotal; self.qualSwap = qualSwap
        self.partnerPrior = partnerPrior; self.acceptanceScore = acceptanceScore
        self.coverageCount = coverageCount
    }

    // TOTAL distinct people INCLUDING you (SPEC S-ENG-5): You↔Cary ⇒ 2. The route
    // lists each participant once (incl. self); assignments list only the others, so + you.
    var peopleCount: Int {
        if let route { return Set(route.participants).count }
        return Set(assignments.map(\.workerID)).count + 1
    }
    var allDayIDs: [String] { assignments.flatMap(\.dayIDs) }
    /// D5: a package needing a qual-swap bridge sorts UNDER clean ones of the same N.
    var needsQualSwap: Bool { qualSwap != nil }
    /// A package is CIRCULAR only with **≥3 participants** (#4) — a 2-cycle is just a 2-way swap.
    var isCircular: Bool { methodology == .circular && peopleCount >= 3 }
    /// B4-14: two-person swaps (you + one, incl. a 2-way qual-swap) render as the compact ECB-style card;
    /// 3+-person and circular keep the full `PackageCard`. Presentation routing only.
    var usesCompactCard: Bool { peopleCount == 2 }
    /// Earliest ISO day anything moves in this package (give/take + route legs) — the global sort
    /// tiebreak (#4b: closer trades first). ISO "yyyy-MM-dd" strings sort chronologically.
    var earliestDayID: String? {
        var days = assignments.flatMap { $0.giveDayIDs + $0.takeDayIDs }
        if let legs = route?.legs { days += legs.map(\.dayID) }
        return days.min()
    }
}

// MARK: - Router

@MainActor
enum TradeRouter {

    private typealias DayMap = [String: RosterEntry]   // ISO day → entry

    /// Horizon shared with the two-way badge logic.
    private static var horizon: (start: Date, end: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .month, value: TradeMatcher.twoWayHorizonMonths, to: today) ?? today
        return (today, end)
    }

    // MARK: - Shared search context (built once per pass)

    /// The derived world for ONE matching pass — built once and reused across packaging, intent
    /// assembly, and the N-way DFS instead of each re-fetching the roster, rebuilding the day-maps,
    /// re-deriving the candidate universe, and re-scanning all responses for acceptance priors.
    /// Behavior-identical to building these inline (same rows, same formulas); just not repeated.
    /// (U-PERF — collapses the previously 4×-duplicated load/build block.)
    // NOT main-actor isolated + Sendable: everything here is a value snapshot, so the heavy candidate
    // loops that consume it can run off the main thread.
    private struct MatchContext: Sendable {
        let start: Date
        let end: Date
        let selfID: String
        let maps: [String: DayMap]                                 // worker → (ISO day → entry)
        let rosterMeta: [String: (name: String, quals: [String])]
        let profilesByID: [String: TradeProfile]
        let universe: [MatchCandidate]
        let priors: [String: Double]                               // worker → acceptance log-odds
        let inferred: [String: InferredPrefs.Result]               // B4-5: profileless peers' recent behavior

        /// My own schedule entries in the window (the preload `twoWayExplore` reuses).
        var mineEntries: [RosterEntry] { Array((maps[selfID] ?? [:]).values) }
        /// worker → quals, for the per-leg qual-bridge feature.
        var qualsDict: [String: [String]] { rosterMeta.mapValues { $0.quals } }

        /// A roster peer with no published profile is included (never invisible). B4-5: if they've worked
        /// enough recently, hard-restrict their default to that behavior — region + shift type + weekends
        /// (weekend blacklist only if they worked none). A real published profile always wins.
        nonisolated func profile(for id: String, name: String) -> TradeProfile {
            if let p = profilesByID[id] { return p }
            guard let inf = inferred[id] else {
                return TradeProfile.defaultForUnpublished(workerID: id, name: name)
            }
            return TradeProfile.defaultForUnpublished(workerID: id, name: name,
                                                      inferredShiftTypes: inf.shiftTypes,
                                                      inferredRegions: inf.regions,
                                                      blacklistWeekends: !inf.worksWeekend)
        }

        static func build(selfID: String) async -> MatchContext {
            let (start, end) = horizon
            // The store reads stay on the main actor (RosterModelActor hop + @Observable reads); the heavy
            // CPU — building the per-worker day-maps, the candidate universe, and the 60-day inferred-prefs
            // — is pure over these Sendable snapshots, so it runs OFF the main thread (no UI freeze).
            let allEntries = await RosterStore.shared.entries(from: start, to: end)
            let lookbackStart = start.addingTimeInterval(-60 * 86_400)
            let recentEntries = await RosterStore.shared.entries(from: lookbackStart, to: start)
            let profilesByID = TradeProfileStore.shared.others
            let priors = MessagingStore.shared.acceptancePriorMap()
            let d = await derive(allEntries: allEntries, recentEntries: recentEntries,
                                 profilesByID: profilesByID, selfID: selfID, asOf: start)
            return MatchContext(start: start, end: end, selfID: selfID, maps: d.maps,
                                rosterMeta: d.rosterMeta, profilesByID: profilesByID,
                                universe: d.universe, priors: priors, inferred: d.inferred)
        }

        /// The pure, CPU-heavy derivation, run on a background thread (`Task.detached`). Everything in and
        /// out is `Sendable`; it reads NO shared/main-actor state — so it's identical to the old inline code,
        /// just off the main run loop.
        nonisolated private static func derive(
            allEntries: [RosterEntry], recentEntries: [RosterEntry],
            profilesByID: [String: TradeProfile], selfID: String, asOf: Date
        ) async -> (maps: [String: DayMap], rosterMeta: [String: (name: String, quals: [String])],
                    universe: [MatchCandidate], inferred: [String: InferredPrefs.Result]) {
            await Task.detached(priority: .userInitiated) {
                var maps: [String: DayMap] = [:]
                var rosterMeta: [String: (name: String, quals: [String])] = [:]
                for e in allEntries {
                    maps[e.workerID, default: [:]][e.day] = e
                    if rosterMeta[e.workerID] == nil { rosterMeta[e.workerID] = (e.workerName, e.quals) }
                }
                // People permanently on TRN / irregular shifts are "not a dispatch shift" → not tradeable.
                // Keep only workers whose in-window schedule holds at least one genuine dispatch shift; a
                // real dispatcher with a stray training day is retained (canCover still blocks that one leg).
                let dispatchWorkers = Set(maps.compactMap { (wid, map) in
                    map.values.contains { TradeTiming.isDispatchShift(desk: $0.desk, startHour: $0.startHour, isOff: $0.isOff) } ? wid : nil
                })
                let universe = MatchUniverse.candidates(
                    roster: rosterMeta.map { (id: $0.key, name: $0.value.name, quals: $0.value.quals) },
                    profiles: profilesByID, selfID: selfID)
                    .filter { dispatchWorkers.contains($0.workerID) }
                // B4-5: infer each PROFILELESS peer's recent (60d) behavior to hard-restrict their default.
                var recentByWorker: [String: [RosterEntry]] = [:]
                for e in recentEntries { recentByWorker[e.workerID, default: []].append(e) }
                var inferred: [String: InferredPrefs.Result] = [:]
                for (wid, entries) in recentByWorker where profilesByID[wid] == nil {
                    if let inf = InferredPrefs.from(entries: entries, asOf: asOf) { inferred[wid] = inf }
                }
                return (maps, rosterMeta, universe, inferred)
            }.value
        }
    }

    // MARK: Greedy recipient minimization


    // MARK: Packaged solutions (greedy first, circular as a >2-person alternative)

    /// Build proposable packages for the user's give-away days. Greedy "fewest
    /// people" covers come first; if the best greedy needs >2 coverers, circular
    /// swap loops are offered alongside (not instead). Sorted fewest-people first.
    /// `generation` bounds how hard the search works. The DEFAULT (`.fast`) finds only 2-person
    /// trades — cheap enough to auto-run in the background. The expensive 3+ multi-person covers and
    /// N-Way circular DFS run ONLY when the caller widens the scope (the "I'm Feeling Lucky" Generate),
    /// so they never burn cycles in the background. (Speed: U-PERF.)
    static func packages(excluding selfID: String, generation: SearchFilter = .fast,
                         lucky: Bool = false) async -> [TradePackage] {
        let (start, end) = horizon
        let giveShifts = await selfSeekingShifts(myID: selfID, start: start, end: end)
        return await packages(forGiveShifts: giveShifts, excluding: selfID, generation: generation, lucky: lucky)
    }

    /// RECIPROCAL packaging for an explicit set of give-away shifts. Every package
    /// is balanced — you give N and receive N back, all passing your criteria. A
    /// pairwise greedy (fewest counterparties) comes first; N-way circular loops
    /// are offered when pairwise can't fully reciprocate. Used by both feeds.
    static func packages(forGiveShifts giveShifts: [Shift], excluding selfID: String,
                         generation: SearchFilter = .fast, lucky: Bool = false) async -> [TradePackage] {
        let giveDayIDs = Set(giveShifts.filter { !$0.isOff }.map(\.id))
        guard !giveDayIDs.isEmpty else { return [] }

        // A day's urgency blends the AI-categorized reason with the day's topology,
        // so personal milestones and high-demand holidays raise a day's priority too
        // — not just the free-text reason. Used to rank/tie-break trade solutions.
        func dayUrgency(_ dayID: String) -> Int {
            let reason = DayIntentStore.shared.note(forDay: dayID)?.reason?.urgency ?? 0
            let topo: Int
            switch DayIntentStore.shared.topology(forDay: dayID) {
            case .personalMilestone: topo = 3   // your protected personal date
            case .highDemand:        topo = 2   // holiday / known high-demand
            case .standard:          topo = 0
            }
            return reason + topo
        }
        func urgency(of dayIDs: [String]) -> Int { dayIDs.map(dayUrgency).max() ?? 0 }
        func urgencyWeight(_ dayIDs: [String]) -> Int { dayIDs.map(dayUrgency).reduce(0, +) }

        let ctx = await MatchContext.build(selfID: selfID)
        let (start, end) = (ctx.start, ctx.end)
        let mySeeking = DayIntentStore.shared.seekingDayIDs
        let myWantToWork = DayIntentStore.shared.wantToWorkDayIDs   // non-bookend days I'll still accept receiving
        // Lucky one-time openness override: search with my openness set to the chosen level (else my saved
        // one). The effective profile carries the level through wouldPickUp / bookend gating naturally.
        let myProfile = generation.myOpennessOverride.map { TradeProfileStore.shared.myProfile().withOpenness($0) }
            ?? TradeProfileStore.shared.myProfile()
        let myBookendsOnly = myProfile.opennessLevel == .bookends

        // The date range is the RECEIVE window (days you want to trade INTO). When set, the give-back the
        // package offers you must fall inside it — otherwise the bookend-first ranking would keep handing
        // you the "best" (bookend) day instead of the specific day you're targeting (e.g. Jul 15).
        let winLo = generation.dateStart.map(SearchFilter.iso)
        let winHi = generation.dateEnd.map(SearchFilter.iso)
        func inReceiveWindow(_ dayID: String) -> Bool {
            (winLo.map { dayID >= $0 } ?? true) && (winHi.map { dayID <= $0 } ?? true)
        }

        // Whether `prof` would actually pick up a leg — honors their availability
        // pills, openness, bookend (no-split) rule, blacklist, and mercenary mode.
        func wouldTake(_ prof: TradeProfile, _ leg: TwoWayLeg) -> Bool {
            let cal = Calendar.current
            let weekday = cal.component(.weekday, from: leg.date)
            let region  = DeskRules.region(forDesk: leg.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: leg.startHour).rawValue
            return prof.wouldPickUp(onDay: leg.dayID, weekday: weekday, desk: leg.desk,
                                    shiftType: type, region: region, isBookend: leg.bookend)
        }

        // R-A: the candidate UNIVERSE is the whole roster, not just opted-in profiles. The shared
        // `ctx` already loaded every worker's window schedule ONCE, built the day-maps, and derived
        // the universe (unknown-profile peers included); twoWayExplore reuses those (no per-peer re-fetch).
        let maps = ctx.maps
        let universe = ctx.universe
        let profileFor: @Sendable (String, String) -> TradeProfile = { id, name in ctx.profile(for: id, name: name) }
        let mineEntries = ctx.mineEntries
        let qualsDict = ctx.qualsDict          // U-OBJ/P6(a): hoisted so the peer loop + scoring share one copy
        let priors = ctx.priors                // U-PERF: built once in ctx (one responses scan, not per-leg)

        // Per-peer reciprocal capacity via two-way exploration, gated by BOTH parties' real rules.
        struct PeerSwap { let id: String; let name: String; let canTake: [String]; let givesBack: [String] }
        var peerSwaps: [PeerSwap] = []
        var plansByPeer: [String: TwoWayPlan] = [:]   // retained for U4 fire/bookend scoring
        for cand in universe.sorted(by: { $0.workerID < $1.workerID }) {
            if Task.isCancelled { return [] }   // U-PERF: cancellable mid-scan (Cancel button / supersede)
            await Task.yield()                  // hand the main run loop a turn so the UI never freezes
            let profile = profileFor(cand.workerID, cand.name)
            let plan = TradeMatcher.twoWayExploreCore(
                withWorker: cand.workerID, name: cand.name,
                windowStart: start, windowEnd: end,
                mySeeking: mySeeking, theirSeeking: profile.seekingDayIDs,
                myProfile: myProfile, theirProfile: profile,
                ignoreOwnBlacklist: false,
                myEntries: mineEntries, peerEntries: Array((maps[cand.workerID] ?? [:]).values))
            plansByPeer[cand.workerID] = plan
            let canTake   = plan.iGive.filter { giveDayIDs.contains($0.dayID) && wouldTake(profile, $0) }.map(\.dayID)
            // The days I'll RECEIVE back, bookends-first. If I'm Bookends Only, non-bookend islands are
            // dropped; if I'm open-to-all they're kept (but sorted last, and demote the package in ranking).
            let givesBack = TradeRouter.cleanReceiveLegs(plan.iTake.filter { wouldTake(myProfile, $0) },
                                                         wantToWork: myWantToWork,
                                                         bookendsOnly: myBookendsOnly).map(\.dayID)
                                                         .filter(inReceiveWindow)   // honor the receive window
            if !canTake.isEmpty, !givesBack.isEmpty {
                peerSwaps.append(PeerSwap(id: cand.workerID, name: cand.name, canTake: canTake, givesBack: givesBack))
            }
        }

        var result: [TradePackage] = []
        func anchoredSet(_ ids: [String], in map: [String: RosterEntry]) -> Bool {
            let plan = Set(ids)
            return ids.allSatisfy { d in
                guard let day = TradeMatcher.dayDate(fromISO: d) else { return false }
                return TradeMatcher.isAnchored(day: day, map: map, plan: plan)
            }
        }
        // Only people whose rule is "bookends" must keep contiguous breaks. My side uses my EFFECTIVE
        // openness (the one-time override, if set), so an "open to all" search skips my contiguity naturally.
        func contiguityOK(_ assignments: [OptimalMatcher.Assignment]) -> Bool {
            for a in assignments {
                if TradeProfileStore.shared.profile(forWorker: a.id)?.opennessLevel == .bookends,
                   !anchoredSet(a.giveDayIDs, in: maps[a.id] ?? [:]) { return false }
            }
            if myProfile.opennessLevel == .bookends,
               !anchoredSet(assignments.flatMap(\.takeDayIDs), in: maps[selfID] ?? [:]) { return false }
            return true
        }

        // We aim to surface a fuller SET of real options (target ~5) — but only
        // FEASIBLE ones; an empty pool can't be padded with fake trades.
        let targetCount = 5
        let giveAll = Array(giveDayIDs)
        func asOpt(_ a: [PackageAssignment]) -> [OptimalMatcher.Assignment] {
            a.map { OptimalMatcher.Assignment(id: $0.workerID, name: $0.name,
                                              giveDayIDs: $0.giveDayIDs, takeDayIDs: $0.takeDayIDs) }
        }

        // 1) #3: a SEPARATE two-person trade per peer for the days THEY can reciprocally cover —
        //    full OR partial. The user proposes these individually instead of one bundled N-person
        //    package; the unified rankScore (people penalty) tends to float 2-person over larger loops.
        //    (one peer takes everything) is flagged optimal so it floats to the top of the 2-person band.
        for ps in peerSwaps {
            let canTakeSet = Set(ps.canTake)
            let cover = giveAll.filter { canTakeSet.contains($0) }
            guard !cover.isEmpty, ps.givesBack.count >= cover.count else { continue }
            let a = [PackageAssignment(workerID: ps.id, name: ps.name,
                                       giveDayIDs: cover, takeDayIDs: Array(ps.givesBack.prefix(cover.count)),
                                       // Single give-day → surface every eligible give-back (ranked) so the
                                       // card can offer alternatives (e.g. Jul 15 under the top pick).
                                       takeOptions: cover.count == 1 ? ps.givesBack : [])]
            guard contiguityOK(asOpt(a)) else { continue }
            let fullCover = Set(cover).isSuperset(of: giveDayIDs)
            result.append(TradePackage(id: "two-\(ps.id)", methodology: .greedy, assignments: a,
                                       route: nil, urgency: urgency(of: cover), isOptimal: fullCover))
        }

        // 1b) QUAL-SWAP TIER (D5): a peer who'd take one of my INTERNATIONAL give-days but LACKS the desk
        //     qual is normally dropped by `twoWayExplore`'s eligibility gate. If a working bridge can slide
        //     onto that desk, surface a reciprocal package FLAGGED with the qual-swap leg (bridge candidates
        //     ride along; the user picks the bridge via the Q button in the package view). These carry a
        //     `qualSwap` leg; the needsQualBridge friction inside the score sorts them below clean trades. (This
        //     is the feed's inline offering; the green button's one-way finder + `TradeMerge` is a SEPARATE,
        //     complementary path for pre-arranging a swap.)
        let tierCal = Calendar.current
        let intlGives = giveShifts.filter { !$0.isOff && DeskRules.hasQualGatedSelection(desks: [$0.desk]) }
        for s in intlGives where giveDayIDs.contains(s.id) {
            let region  = DeskRules.region(forDesk: s.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: s.startHour).rawValue
            let weekday = tierCal.component(.weekday, from: s.date)
            for cand in universe.sorted(by: { $0.workerID < $1.workerID }) {
                if Task.isCancelled { return [] }
                await Task.yield()
                let pMap = maps[cand.workerID] ?? [:]
                guard let pe = pMap[s.id], pe.isOff else { continue }                              // peer OFF that day
                let peerQuals = pMap.values.first?.quals ?? []
                guard !DeskRules.qualified(quals: peerQuals, forDesk: s.desk) else { continue }    // qualified → normal path
                guard TradeMatcher.isRested(map: pMap, day: s.date, startHour: s.startHour, cal: tierCal) else { continue }
                let profile = profileFor(cand.workerID, cand.name)
                let isBookend = TradeMatcher.anchored(day: s.date, map: pMap, plan: [s.id], cal: tierCal)
                guard profile.wouldPickUp(onDay: s.id, weekday: weekday, desk: s.desk,
                                          shiftType: type, region: region, isBookend: isBookend) else { continue }
                // Reciprocal give-back (their days I'd take), clean/bookend-first, inside the receive window.
                let givesBack = TradeRouter.cleanReceiveLegs((plansByPeer[cand.workerID]?.iTake ?? []).filter { wouldTake(myProfile, $0) },
                                                             wantToWork: myWantToWork, bookendsOnly: myBookendsOnly)
                                                             .map(\.dayID).filter(inReceiveWindow)
                guard !givesBack.isEmpty else { continue }
                // A bridge must exist, else it's a true dead end — don't surface it. (buildQualSwapLeg = nil.)
                guard let leg = await TradeMatcher.buildQualSwapLeg(
                    giveDayID: s.id, giveDesk: s.desk, giveStartHour: s.startHour,
                    giverID: selfID, takerID: cand.workerID, takerName: cand.name, takerQuals: peerQuals) else { continue }
                let a = [PackageAssignment(workerID: cand.workerID, name: cand.name,
                                           giveDayIDs: [s.id], takeDayIDs: Array(givesBack.prefix(1)),
                                           takeOptions: givesBack)]
                guard contiguityOK(asOpt(a)) else { continue }
                result.append(TradePackage(id: "qualtrade-\(s.id)-\(cand.workerID)", methodology: .greedy,
                                           assignments: a, route: nil, urgency: urgency(of: [s.id]), qualSwap: leg))
            }
        }

        // 2) Also offer a fewest-people MULTI-person cover of your days (optimal, else a greedy balanced
        //    cover) — ALWAYS when 3+ is allowed, not only when no 2-person exists. Coverage-first ranking
        //    then floats a full multi-person cover above 2-person partials. (Was gated on `result.isEmpty`,
        //    which hid multi-person covers whenever any 2-person partial existed.)
        if generation.maxPeople >= 3 {
            let cands = peerSwaps.map {
                OptimalMatcher.Cand(id: $0.id, name: $0.name, canTake: Set($0.canTake), givesBack: $0.givesBack)
            }
            var addedMulti = false
            // ≥2 peers only: a single-peer "cover" is already emitted as a `two-` card in step 1 (both are
            // peopleCount==2 → both render as compact cards → the SAME peer shows twice). Step 2 exists for
            // genuine MULTI-person covers, so skip the degenerate 1-peer case here. (B6-DEDUP.)
            if let opt = OptimalMatcher.minPeopleReciprocal(giveDayIDs: giveAll, peers: cands, contiguous: contiguityOK),
               opt.count >= 2 {
                let a = opt.map { PackageAssignment(workerID: $0.id, name: $0.name,
                                                    giveDayIDs: $0.giveDayIDs, takeDayIDs: $0.takeDayIDs) }
                result.append(TradePackage(
                    id: "optimal-" + a.map(\.workerID).sorted().joined(separator: ","),
                    methodology: .greedy, assignments: a, route: nil,
                    urgency: urgency(of: a.flatMap(\.giveDayIDs)), isOptimal: true))
                addedMulti = true
            }
            // Greedy balanced cover — only as a fallback when the optimal one didn't produce a cover.
            if !addedMulti {
                var uncovered = giveDayIDs
                var usedBack = Set<String>()
                var assigns: [PackageAssignment] = []
                var pool = peerSwaps
                while !uncovered.isEmpty {
                    let best = pool.compactMap { ps -> (PeerSwap, [String], [String])? in
                        let gives = ps.canTake.filter { uncovered.contains($0) }
                        let backs = ps.givesBack.filter { !usedBack.contains($0) }
                        let k = min(gives.count, backs.count)
                        guard k > 0 else { return nil }
                        return (ps, Array(gives.prefix(k)), Array(backs.prefix(k)))
                    }.max { l, r in
                        if l.1.count != r.1.count { return l.1.count < r.1.count }
                        let lu = urgencyWeight(l.1), ru = urgencyWeight(r.1)
                        if lu != ru { return lu < ru }
                        return l.0.id > r.0.id
                    }
                    guard let (ps, gives, takes) = best else { break }
                    assigns.append(PackageAssignment(workerID: ps.id, name: ps.name,
                                                     giveDayIDs: gives, takeDayIDs: takes))
                    uncovered.subtract(gives)
                    usedBack.formUnion(takes)
                    pool.removeAll { $0.id == ps.id }
                }
                // Same ≥2-peer rule as the optimal branch: a lone-peer greedy cover duplicates its step-1
                // `two-` card, so only surface genuine multi-person covers here. (B6-DEDUP.)
                if uncovered.isEmpty, assigns.count >= 2, contiguityOK(asOpt(assigns)) {
                    result.append(TradePackage(
                        id: "recip-" + assigns.map(\.workerID).sorted().joined(separator: ","),
                        methodology: .greedy, assignments: assigns, route: nil,
                        urgency: urgency(of: assigns.flatMap(\.giveDayIDs))))
                }
            }
        }

        // 3) Circular loops — GATED: the N-Way DFS is the most expensive step, so it runs ONLY when
        //    the caller widened the scope (Lucky/Generate with N-Way/Both and ≥3 people), never in the
        //    fast background pass. `maxDepth` is bounded to the requested people cap.
        if generation.maxPeople >= 3, generation.engine != .minCost {
            // OFF-MAIN (Step 3): snapshot the main-actor state the DFS reads, then run it detached — same
            // pattern as intentSolutions so the Generate tap can't freeze the UI either.
            let notesByDay = DayIntentStore.shared.notes
            let topologyByDay = DayIntentStore.shared.topologies
            let myKeepDays = DayIntentStore.shared.keepDayIDs
            let myReliefThrough = SettingsManager.shared.effectiveReliefThrough
            let profilesByID = ctx.profilesByID
            let loops: [NWayRoute] = await Task.detached(priority: .utility) {
                nWayRoutes(seedShifts: giveShifts, maxDepth: generation.maxPeople,
                           excluding: selfID, maxRoutes: 500,   // high safety backstop; the floor curates
                           windowStart: start, maps: maps,      // U-PERF: reuse the loaded window
                           myProfile: myProfile, profilesByID: profilesByID,
                           myKeepDays: myKeepDays, mySeeking: mySeeking,
                           myReliefThrough: myReliefThrough,
                           notesByDay: notesByDay, topologyByDay: topologyByDay)
            }.value
            if Task.isCancelled { return [] }
            for loop in loops.prefix(targetCount * 2) {
                var gv: [String: [String]] = [:]   // peer → my days they cover
                var tk: [String: [String]] = [:]   // peer → their days I cover
                for leg in loop.legs {
                    if leg.fromID == selfID { gv[leg.toID, default: []].append(leg.dayID) }
                    if leg.toID == selfID   { tk[leg.fromID, default: []].append(leg.dayID) }
                }
                let participants = Set(gv.keys).union(tk.keys)
                let a = participants.map { pid in
                    PackageAssignment(workerID: pid, name: participantName(pid),
                                      giveDayIDs: gv[pid] ?? [], takeDayIDs: tk[pid] ?? [])
                }
                result.append(TradePackage(id: "circular-" + loop.id, methodology: .circular,
                                           assignments: a, route: loop,
                                           urgency: urgency(of: a.flatMap(\.giveDayIDs))))
            }
        }

        // Q1: give-days blocked PURELY by qualification (no off peer that day is qualified for the
        // desk) → assemble 3-party qual-swap packages (bridge C takes my desk; off-taker B takes C's
        // freed desk). The bridge is NOT counted in N. Reuses the loaded `maps` (no extra fetches).
        func openProfile(_ id: String, _ name: String) -> TradeProfile {
            TradeProfileStore.shared.profile(forWorker: id)
                ?? TradeProfile.defaultForUnpublished(workerID: id, name: name)   // A8: missing → Bookends Only
        }
        for giveDay in giveDayIDs.sorted() {
            guard let myEntry = (maps[selfID] ?? [:])[giveDay],
                  let dayDate = TradeMatcher.dayDate(fromISO: giveDay) else { continue }
            var workingPairs: [(QualSwapShift, TradeProfile)] = []
            var offEntries: [RosterEntry] = []
            for (wid, m) in maps {
                guard wid != selfID, let e = m[giveDay] else { continue }
                if e.isOff { offEntries.append(e) }
                else {
                    workingPairs.append((QualSwapShift(workerID: wid, name: e.workerName, desk: e.desk,
                                                       startHour: e.startHour, quals: e.quals),
                                         openProfile(wid, e.workerName)))
                }
            }
            guard DeskRules.isQualBlocked(forDesk: myEntry.desk, candidateTakerQuals: offEntries.map(\.quals)) else { continue }
            let offTakers = offEntries.map { (id: $0.workerID, name: $0.workerName, quals: $0.quals) }
            let sols = QualSwap.solutions(giveDesk: myEntry.desk, giveStartHour: myEntry.startHour,
                                          giverID: selfID, workers: workingPairs, offTakers: offTakers)
            guard !sols.isEmpty else { continue }
            let giveQual = DeskRules.requiredQual(forDesk: myEntry.desk) ?? "D"
            // One package per off-taker B; blast candidates = bridges whose freed desk B will take.
            for (takerID, group) in Dictionary(grouping: sols, by: { $0.takerID }).sorted(by: { $0.key < $1.key }) {
                guard let bMap = maps[takerID], let bEntry = bMap[giveDay] else { continue }
                let bProfile = openProfile(takerID, bEntry.workerName)
                let willing = group.filter { sol in
                    TradeEligibility.canCover(coverDayID: giveDay, coverDay: dayDate, desk: sol.bridgeDesk,
                                              startHour: myEntry.startHour, coverMap: bMap, coverQuals: bEntry.quals,
                                              coverProfile: bProfile, options: .full).eligible
                }
                guard !willing.isEmpty else { continue }
                let candidates = willing.map {
                    QualSwapCandidate(workerID: $0.bridgeID, name: $0.bridgeName, desk: $0.bridgeDesk, qual: $0.bridgeQual)
                }
                let leg = QualSwapLegData(giveShiftDayID: giveDay, giveDesk: myEntry.desk, giveQual: giveQual,
                                          takerID: takerID, takerName: bEntry.workerName, candidates: candidates)
                let assignment = PackageAssignment(workerID: takerID, name: bEntry.workerName,
                                                   giveDayIDs: [giveDay], takeDayIDs: [])
                result.append(TradePackage(id: "qualswap-\(giveDay)-\(takerID)", methodology: .greedy,
                                           assignments: [assignment], route: nil,
                                           urgency: urgency(of: [giveDay]), qualSwap: leg))
            }
        }

        // U4 scoring: total bookends + 🔥 (mutual-intent) across BOTH sides of each package.
        // Greedy packages read the retained per-peer plans; circular approximate from route
        // metadata (exact per-leg flag is threaded in a later UI step).
        let scored = result.map { pkg -> TradePackage in
            var p = pkg
            if let route = pkg.route {
                p.fireCount    = route.tier == .matchingIntents ? route.legs.count : 0
                p.bookendTotal = route.bookendCount   // G3: real per-leg bookend count (split legs don't count)
                // Circular loop: count the days I RECEIVE that aren't a clean bookend for me.
                p.dirtyReceives = TradeRouter.routeDirtyReceives(route, selfID: selfID,
                                                                 myMap: maps[selfID] ?? [:], wantToWork: myWantToWork)
            } else {
                var fire = 0, book = 0, dirty = 0
                for a in pkg.assignments {
                    let plan = plansByPeer[a.workerID]
                    let giveByDay = Dictionary((plan?.iGive ?? []).map { ($0.dayID, $0) }, uniquingKeysWith: { x, _ in x })
                    let takeByDay = Dictionary((plan?.iTake ?? []).map { ($0.dayID, $0) }, uniquingKeysWith: { x, _ in x })
                    for d in a.giveDayIDs { if let l = giveByDay[d] { if l.bookend { book += 1 }; if l.wanted { fire += 1 } } }
                    for d in a.takeDayIDs { if let l = takeByDay[d] {
                        if l.bookend { book += 1 } else if !myWantToWork.contains(d) { dirty += 1 }   // a non-bookend island I receive
                        if l.wanted { fire += 1 }
                    } }
                }
                p.fireCount = fire; p.bookendTotal = book; p.dirtyReceives = dirty
            }
            return p
        }
        // U-OBJ: one objective end-to-end. acceptanceScore = per-leg quality (floor/display);
        // rankScore = quality × intent-aware people penalty × urgency-weighted coverage.
        let urgencyByDay = Dictionary(uniqueKeysWithValues: giveAll.map { ($0, dayUrgency($0)) })
        let rescored = scored.map { p in
            applyObjective(p, selfID: selfID, maps: maps, quals: qualsDict, priors: priors,
                           start: start, mySeeking: mySeeking, myWantToWork: myWantToWork,
                           profilesByID: ctx.profilesByID,
                           coverageFrac: coverageFraction(p, selfID: selfID,
                                                          selectedDayIDs: giveDayIDs,
                                                          urgencyByDay: urgencyByDay))
        }
        // Bookends Only (my setting): hard-exclude any package that would hand me a non-bookend island —
        // across 2-way, multi-person, AND circular. Open-to-all keeps them (ranked below clean via rankLess).
        let gated = myBookendsOnly ? rescored.filter { $0.dirtyReceives == 0 } : rescored
        return finalize(gated, lucky: lucky)
    }

    // MARK: - Intents marketplace (DISTINCT from packages — intent-for-intent, intent-first ranking)

    /// One side's give-days for an intent pairing, split into MARKED (a real trade-away intent) and
    /// PREF-ONLY (a day they'd merely accept covering). Used to assemble marketplace deals.
    struct IntentPairing: Equatable, Sendable {
        var myGiveMarked: [String]      // my marked trade-away days this peer would take
        var myGivePref: [String]        // my other days this peer would take (pref, not marked)
        var theirGiveMarked: [String]   // their marked trade-away days I would take
        var theirGivePref: [String]     // their other days I would take (pref, not marked)
    }

    /// PURE core of the Intents marketplace. Assembles the best balanced TWO-person deal that fulfils
    /// the most MARKED intents. Marketplace rule (distinct from `packages`): surface the deal if
    /// EITHER side marked ≥1 day — so a peer's marked day I'd happily take seeds a deal even when I
    /// marked no give. Marked legs are placed first so a balanced k-for-k swap maximises mutual intent.
    /// Returns the chosen give/take day IDs + the mutual-marked leg count (the intent score). nil if
    /// nothing marked on either side, or it can't balance.
    nonisolated static func assembleIntentDeal(_ p: IntentPairing) -> (gives: [String], takes: [String], mutualMarked: Int)? {
        guard !p.myGiveMarked.isEmpty || !p.theirGiveMarked.isEmpty else { return nil }   // marketplace seed
        let giveOrdered = p.myGiveMarked + p.myGivePref       // marked first → kept when we trim to balance
        let takeOrdered = p.theirGiveMarked + p.theirGivePref
        let k = min(giveOrdered.count, takeOrdered.count)
        guard k >= 1 else { return nil }
        let gives = Array(giveOrdered.prefix(k))
        let takes = Array(takeOrdered.prefix(k))
        let myMarked = Set(p.myGiveMarked), theirMarked = Set(p.theirGiveMarked)
        let mutual = gives.filter(myMarked.contains).count + takes.filter(theirMarked.contains).count
        return (gives, takes, mutual)
    }

    /// The Intents feed's engine — a MARKETPLACE of intent-for-intent deals involving you, ranked
    /// intent-first. DISTINCT from `packages` (Trade Solutions): it seeds from BOTH your marked
    /// trade-away days AND peers' marked trade-away days you'd take (so a peer's marked day seeds a
    /// deal even when you marked no give), and ranks by most mutual intent. `generation` gates the
    /// heavy 3+/circular work to Lucky → Generate, exactly like `packages` (U-PERF).
    /// `mutualOnly` (default): a deal shows only when BOTH sides marked a day in it (true mutual intent).
    /// When false, one-sided deals (your marked days a peer would cover) also show.
    ///
    /// **Robot gate (B6-INTENTS):** the active-account filter (real signed-in profile) is applied ONLY in
    /// Mutual mode — there, 🔥 means both-sides-marked, so unclaimed/robot records are meaningless clutter.
    /// In **All** mode every peer is eligible (an unclaimed peer can still be a valid bookend counterparty),
    /// so All keeps showing matches even before anyone has claimed an account. See `peerEligibleForIntents`.
    nonisolated static func peerEligibleForIntents(isActiveAccount: Bool, mutualOnly: Bool) -> Bool {
        !mutualOnly || isActiveAccount
    }

    static func intentSolutions(excluding selfID: String, generation: SearchFilter = .fast,
                                lucky: Bool = false, mutualOnly: Bool = true) async -> [TradePackage] {
        let ctx = await MatchContext.build(selfID: selfID)
        let (start, end) = (ctx.start, ctx.end)
        let mySeeking = DayIntentStore.shared.seekingDayIDs
        let myWantToWork = DayIntentStore.shared.wantToWorkDayIDs   // non-bookend days I'll still accept receiving
        // Lucky one-time openness override for my side (else my saved openness).
        let myProfile = generation.myOpennessOverride.map { TradeProfileStore.shared.myProfile().withOpenness($0) }
            ?? TradeProfileStore.shared.myProfile()
        let myBookendsOnly = myProfile.opennessLevel == .bookends

        // STEP-1 snapshots: MY per-day intent sources, captured ONCE on the main actor so `dayUrgency`
        // is a pure lookup with no main-actor read inside the candidate loop (prereq for going off-main).
        let notesSnapshot = DayIntentStore.shared.notes
        let topologySnapshot = DayIntentStore.shared.topologies
        // STEP-3 snapshots: my Keep days + my relief horizon, captured on the main actor so the N-way
        // DFS (which runs off-main) reads them as pure lookups instead of `.shared`.
        let myKeepDays = DayIntentStore.shared.keepDayIDs
        let myReliefThrough = SettingsManager.shared.effectiveReliefThrough

        // These are @Sendable closures (not local funcs) so they can run inside the off-main Task.detached
        // as well as on-main — they touch only nonisolated helpers + the Sendable snapshots captured above.
        let wouldTake: @Sendable (TradeProfile, TwoWayLeg) -> Bool = { prof, leg in
            let cal = Calendar.current
            let weekday = cal.component(.weekday, from: leg.date)
            let region  = DeskRules.region(forDesk: leg.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: leg.startHour).rawValue
            return prof.wouldPickUp(onDay: leg.dayID, weekday: weekday, desk: leg.desk,
                                    shiftType: type, region: region, isBookend: leg.bookend)
        }
        let dayUrgency: @Sendable (String) -> Int = { dayID in
            let reason = notesSnapshot[dayID]?.reason?.urgency ?? 0
            switch topologySnapshot[dayID] ?? .standard {
            case .personalMilestone: return reason + 3
            case .highDemand:        return reason + 2
            case .standard:          return reason
            }
        }
        let urgency: @Sendable ([String]) -> Int = { dayIDs in dayIDs.map(dayUrgency).max() ?? 0 }

        // Candidate universe = the whole roster (unknown-profile peers included). Sourced from the
        // shared `ctx` (roster loaded once, maps + universe + priors built once).
        let maps = ctx.maps
        let rosterMeta = ctx.rosterMeta
        let profilesByID = ctx.profilesByID
        let universe = ctx.universe
        let profileFor: @Sendable (String, String) -> TradeProfile = { id, name in ctx.profile(for: id, name: name) }
        let mineEntries = ctx.mineEntries
        let priors = ctx.priors   // U-PERF: one responses scan for all prior lookups
        let qualsDict = rosterMeta.mapValues { $0.quals }   // U-OBJ/P7(a): hoisted for the detached loop + scoring
        // STEP-1 snapshot: per-peer active-account flags (isActiveAccount reads the main-actor profile
        // store). Captured for the whole window roster so the loop's eligibility check is a pure lookup.
        let activeByID: [String: Bool] = maps.reduce(into: [:]) { $0[$1.key] = TradeProfileStore.shared.isActiveAccount($1.key) }

        // Set-contiguity: a `.bookends` party must keep CONTIGUOUS breaks across the WHOLE set of days
        // they pick up — not just each leg in isolation. @Sendable so the off-main loop can call it.
        let anchoredSet: @Sendable ([String], [String: RosterEntry]) -> Bool = { ids, map in
            let plan = Set(ids)
            return ids.allSatisfy { d in
                guard let day = TradeMatcher.dayDate(fromISO: d) else { return false }
                return TradeMatcher.isAnchored(day: day, map: map, plan: plan)
            }
        }

        var result: [TradePackage] = []

        // PERF BOUND (B6-INTENTS-CAP): "All" mode explores the WHOLE roster (Mutual skips inactive accounts
        // up front, so it's already small). Two guards keep it fast:
        //  1) Result-neutral OVERLAP PRUNE — a peer can only form a deal if our schedules cross: they're OFF
        //     on a day I work (they could take it) OR I'm OFF on a day they work (I could take theirs). With
        //     no overlap, `twoWayExplore` yields an empty plan and the deal is dropped anyway — so skipping
        //     them changes nothing but the runtime.
        //  2) A best-first HARD CAP so a pathological roster can't run unbounded. Ordered by acceptance prior
        //     (then workerID for determinism); anything past the cap is the least likely to matter, and we
        //     log the drop (no silent truncation).
        let myWorkDays = Set(mineEntries.filter { !$0.isOff }.map(\.day))
        let myOffDays  = Set(mineEntries.filter {  $0.isOff }.map(\.day))
        func schedulesCross(_ id: String) -> Bool {
            let m = maps[id] ?? [:]
            return myWorkDays.contains { m[$0]?.isOff == true }
                || myOffDays.contains  { m[$0].map { !$0.isOff } ?? false }
        }
        let relevant = universe
            .filter { schedulesCross($0.workerID) }
            .sorted {   // acceptance prior desc, then workerID asc (deterministic tiebreak)
                let a = priors[$0.workerID] ?? 0, b = priors[$1.workerID] ?? 0
                return a != b ? a > b : $0.workerID < $1.workerID
            }
        let candidates = Array(relevant.prefix(Self.intentCandidateCap))
        #if DEBUG
        if relevant.count > candidates.count {
            print("⚠️ intentSolutions: capped candidates \(relevant.count) → \(candidates.count) (intentCandidateCap)")
        }
        #endif

        // The WHOLE roster is eligible as a counterparty. The INTENT side must be someone who actually
        // marked a day (enforced by `assembleIntentDeal`'s marketplace seed) — but the OTHER side may be
        // an unprofiled peer joining via PREFERENCES (bookend-only by default, A8). Low-intent deals
        // simply score lower and fall off the top-20 cap.
        // The heavy 2-way exploration runs OFF the main actor (Task.detached over the Sendable snapshots),
        // so it never blocks the UI. Everything inside touches only pure `nonisolated` helpers + immutable
        // snapshots — no `.shared` access (the compiler proves it). (N-way still runs on main — Step 3.)
        let twoWayPkgs: [TradePackage] = await Task.detached(priority: .utility) {
            var out: [TradePackage] = []
            for cand in candidates {
                if Task.isCancelled { break }   // U-PERF: cancellable mid-scan (Cancel button / supersede)
                await Task.yield()
                // Robot gate is Mutual-only (B6-INTENTS): All shows every peer; Mutual = real accounts only.
                guard peerEligibleForIntents(isActiveAccount: activeByID[cand.workerID] ?? false,
                                             mutualOnly: mutualOnly) else { continue }
                let profile = profileFor(cand.workerID, cand.name)
                let plan = TradeMatcher.twoWayExploreCore(
                    withWorker: cand.workerID, name: cand.name,
                    windowStart: start, windowEnd: end,
                    mySeeking: mySeeking, theirSeeking: profile.seekingDayIDs,
                    myProfile: myProfile, theirProfile: profile,
                    ignoreOwnBlacklist: false,
                    myEntries: mineEntries, peerEntries: Array((maps[cand.workerID] ?? [:]).values))

                // Days each side can actually cover, split MARKED (wanted) vs PREF-only.
                let myTakeable    = plan.iGive.filter { wouldTake(profile, $0) }      // my days the peer takes
                let theirTakeable = plan.iTake.filter { wouldTake(myProfile, $0) }    // their days I take
                let pairing = IntentPairing(
                    myGiveMarked:    myTakeable.filter { $0.wanted }.map(\.dayID),
                    myGivePref:      myTakeable.filter { !$0.wanted }.map(\.dayID),
                    theirGiveMarked: theirTakeable.filter { $0.wanted }.map(\.dayID),
                    theirGivePref:   theirTakeable.filter { !$0.wanted }.map(\.dayID))
                guard let deal = assembleIntentDeal(pairing) else { continue }
                // Mutual mode (default): require a real TWO-SIDED intent — ≥1 day I marked AND ≥1 the peer did.
                if mutualOnly {
                    let iMarked    = deal.gives.contains { mySeeking.contains($0) }
                    let theyMarked = deal.takes.contains { profile.seekingDayIDs.contains($0) }
                    guard iMarked && theyMarked else { continue }
                }
                // Set-contiguity for bookend parties.
                if profile.opennessLevel == .bookends, !anchoredSet(deal.gives, maps[cand.workerID] ?? [:]) { continue }
                if myProfile.opennessLevel == .bookends, !anchoredSet(deal.takes, maps[selfID] ?? [:]) { continue }
                let takeOpts = deal.gives.count == 1 ? theirTakeable.map(\.dayID) : []
                let a = [PackageAssignment(workerID: cand.workerID, name: cand.name,
                                           giveDayIDs: deal.gives, takeDayIDs: deal.takes, takeOptions: takeOpts)]
                var pkg = TradePackage(id: "intent-\(cand.workerID)", methodology: .greedy, assignments: a,
                                       route: nil, urgency: urgency(deal.gives + deal.takes),
                                       isOptimal: deal.mutualMarked == deal.gives.count + deal.takes.count)
                pkg.fireCount = deal.mutualMarked
                pkg.partnerPrior = priors[cand.workerID] ?? 0
                let takeBookend = Dictionary(theirTakeable.map { ($0.dayID, $0.bookend) }, uniquingKeysWith: { x, _ in x })
                pkg.dirtyReceives = deal.takes.filter { !(takeBookend[$0] ?? false) && !myWantToWork.contains($0) }.count
                out.append(pkg)
            }
            return out
        }.value
        if Task.isCancelled { return [] }
        result.append(contentsOf: twoWayPkgs)

        // Lucky (gated): circular loops that need only ≥1 marked-intent leg (the marked seed
        // guarantees it). Other participants join via PREFERENCES (`allowPrefMiddles`). fireCount =
        // the REAL marked-leg count, so all-intent loops rank highest without hard-coding it.
        if generation.maxPeople >= 3, generation.engine != .minCost {
            let giveShifts = await selfSeekingShifts(myID: selfID, start: start, end: end)
            // OFF-MAIN (Step 3): the circular DFS is the launch-freeze culprit (maxRoutes:500, recursive).
            // Run it detached over the Sendable snapshots; the ≤10-package build below stays on main (cheap).
            let loops: [NWayRoute] = await Task.detached(priority: .utility) {
                nWayRoutes(seedShifts: giveShifts, maxDepth: generation.maxPeople,
                           excluding: selfID, allowPrefMiddles: true,
                           maxRoutes: 500,        // high safety backstop; the floor curates
                           windowStart: start, maps: maps,   // U-PERF: reuse ctx's window
                           myProfile: myProfile, profilesByID: profilesByID,
                           myKeepDays: myKeepDays, mySeeking: mySeeking,
                           myReliefThrough: myReliefThrough,
                           notesByDay: notesSnapshot, topologyByDay: topologySnapshot)
            }.value
            if Task.isCancelled { return [] }
            func legMarked(_ leg: NWayLeg) -> Bool {
                leg.fromID == selfID ? mySeeking.contains(leg.dayID)
                    : (profilesByID[leg.fromID]?.seekingDayIDs.contains(leg.dayID) ?? false)
            }
            for loop in loops.prefix(10) where loop.legs.contains(where: legMarked) {
                var gv: [String: [String]] = [:]; var tk: [String: [String]] = [:]
                for leg in loop.legs {
                    if leg.fromID == selfID { gv[leg.toID, default: []].append(leg.dayID) }
                    if leg.toID == selfID   { tk[leg.fromID, default: []].append(leg.dayID) }
                }
                let participants = Set(gv.keys).union(tk.keys)
                // Robot gate is Mutual-only (B6-INTENTS): in All mode unclaimed peers may join a loop.
                guard participants.allSatisfy({
                    peerEligibleForIntents(isActiveAccount: activeByID[$0] ?? false,
                                           mutualOnly: mutualOnly)
                }) else { continue }
                let a = participants.map { pid in
                    PackageAssignment(workerID: pid, name: participantName(pid),
                                      giveDayIDs: gv[pid] ?? [], takeDayIDs: tk[pid] ?? [])
                }
                var pkg = TradePackage(id: "intent-circular-\(loop.id)", methodology: .circular,
                                       assignments: a, route: loop, urgency: urgency(a.flatMap(\.giveDayIDs)))
                pkg.fireCount = loop.legs.filter(legMarked).count   // real mutual-intent legs (not assumed)
                pkg.bookendTotal = loop.bookendCount
                pkg.dirtyReceives = TradeRouter.routeDirtyReceives(loop, selfID: selfID,
                                                                   myMap: maps[selfID] ?? [:], wantToWork: myWantToWork)
                // H2: average the other participants' acceptance priors.
                let others = participants
                if !others.isEmpty {
                    pkg.partnerPrior = others.map { priors[$0] ?? 0 }.reduce(0, +) / Double(others.count)
                }
                result.append(pkg)
            }
        }

        // U-OBJ: unified objective (no coverage target in the marketplace → coverageFrac 1).
        // acceptanceScore = per-leg quality (floor/display); rankScore = quality × people penalty.
        let scored = result.map { p in
            applyObjective(p, selfID: selfID, maps: maps, quals: qualsDict, priors: priors,
                           start: start, mySeeking: mySeeking, myWantToWork: myWantToWork,
                           profilesByID: profilesByID, coverageFrac: 1)
        }
        // Bookends Only: hard-exclude any deal/loop that hands me a non-bookend island (open-to-all keeps
        // them but rankLess demotes them below all-clean). Consistent with Trade Solutions.
        let gated = myBookendsOnly ? scored.filter { $0.dirtyReceives == 0 } : scored
        return finalize(gated, lucky: lucky)
    }
    /// Safety ceiling — neither feed ever shows more than this, even if the floor passes a huge set.
    static let intentResultCap = 60
    /// Worst-case bound on how many peers `intentSolutions` explores (after the result-neutral overlap
    /// prune), best-first by acceptance prior. Well above a typical relevant set, so it only bites huge
    /// rosters. (B6-INTENTS-CAP.)
    static let intentCandidateCap = 300

    // MARK: - Real per-leg scoring (Step 2: packageLogProb from live data)

    /// Grade one leg from live data. The RECEIVER picks up `day` (on the giver's `desk`). Pulls the
    /// real intent (want-to-take / want-to-trade), bookend (anchored for the receiver), soonness, qual
    /// friction, and the receiver's tiny acceptance prior. Pure-ish (reads the shared stores).
    nonisolated private static func legFeatures(giverID: String, receiverID: String, day: String, desk: String,
                            receiverQuals: [String], maps: [String: DayMap], priors: [String: Double],
                            selfID: String, start: Date,
                            mySeeking: Set<String>, myWantToWork: Set<String>,
                            profilesByID: [String: TradeProfile]) -> LegFeatures {
        // Snapshots instead of `.shared` reads → pure, runs off-main.
        func seeking(_ id: String) -> Set<String> {
            id == selfID ? mySeeking : (profilesByID[id]?.seekingDayIDs ?? [])
        }
        func wantWork(_ id: String) -> Set<String> {
            id == selfID ? myWantToWork : (profilesByID[id]?.wantToWorkDayIDs ?? [])
        }
        let bookend: Bool = {
            guard let d = TradeMatcher.dayDate(fromISO: day), let m = maps[receiverID] else { return false }
            return TradeMatcher.isAnchored(day: d, map: m, plan: [day])
        }()
        let daysUntil = max(0, Int((TradeMatcher.dayDate(fromISO: day)?.timeIntervalSince(start) ?? 0) / 86400))
        return LegFeatures(
            wantToTake: wantWork(receiverID).contains(day),       // receiver wants to work it
            wantToTrade: seeking(giverID).contains(day),          // giver marked it trade-away
            bookend: bookend,
            timeValue: exp(-0.05 * Double(daysUntil)),
            needsQualBridge: !DeskRules.qualified(quals: receiverQuals, forDesk: desk),
            personPrior: priors[receiverID] ?? 0)   // O(1) lookup; absent → neutral (U-PERF)
    }

    /// U-OBJ: build per-leg features ONCE and derive both numbers —
    ///   acceptanceScore = meanLegQuality (floor + "match strength" display), and
    ///   rankScore       = packageScore (quality × intent-aware people penalty × coverage).
    /// Circular reads `route.legs`; a reciprocal package synthesizes legs (you→them gives,
    /// them→you takes). `coverageFrac` is 1 for the Intents feed.
    nonisolated private static func applyObjective(_ pkg: TradePackage, selfID: String,
                               maps: [String: DayMap], quals: [String: [String]],
                               priors: [String: Double], start: Date,
                               mySeeking: Set<String>, myWantToWork: Set<String>,
                               profilesByID: [String: TradeProfile],
                               coverageFrac: Double) -> TradePackage {
        var q = pkg
        var legs: [(g: String, r: String, day: String, desk: String)] = []
        if let route = pkg.route {
            for l in route.legs { legs.append((l.fromID, l.toID, l.dayID, l.desk)) }
        } else {
            for a in pkg.assignments {
                for d in a.giveDayIDs { if let e = maps[selfID]?[d] { legs.append((selfID, a.workerID, d, e.desk)) } }
                for d in a.takeDayIDs { if let e = maps[a.workerID]?[d] { legs.append((a.workerID, selfID, d, e.desk)) } }
            }
        }
        guard !legs.isEmpty else { q.acceptanceScore = 0; q.rankScore = 0; return q }
        let feats = legs.map { legFeatures(giverID: $0.g, receiverID: $0.r, day: $0.day, desk: $0.desk,
                                           receiverQuals: quals[$0.r] ?? [], maps: maps, priors: priors,
                                           selfID: selfID, start: start,
                                           mySeeking: mySeeking, myWantToWork: myWantToWork,
                                           profilesByID: profilesByID) }
        q.legCount = feats.count
        q.mutualLegCount = TradeScore.mutualLegCount(feats)
        q.coverageFrac = coverageFrac
        q.acceptanceScore = TradeScore.meanLegQuality(feats)
        q.rankScore = TradeScore.packageScore(feats, people: pkg.peopleCount, coverageFrac: coverageFrac)
        q.coverageCount = myGiveCoverage(pkg, selfID: selfID)   // kept: UI badge + SearchFilter
        return q
    }

    /// Urgency-weighted coverage of MY selected give-days: each day weighs 1 + its urgency,
    /// so covering the urgent day outranks covering a casual one at equal count.
    nonisolated private static func coverageFraction(_ pkg: TradePackage, selfID: String,
                                                     selectedDayIDs: Set<String>,
                                                     urgencyByDay: [String: Int]) -> Double {
        guard !selectedDayIDs.isEmpty else { return 1 }
        let handedOff: Set<String> = pkg.route.map { Set($0.legs.filter { $0.fromID == selfID }.map(\.dayID)) }
            ?? Set(pkg.assignments.flatMap(\.giveDayIDs))
        let covered = handedOff.intersection(selectedDayIDs)
        func mass(_ s: Set<String>) -> Double { s.reduce(0) { $0 + 1 + Double(urgencyByDay[$1] ?? 0) } }
        let total = mass(selectedDayIDs)
        return total > 0 ? mass(covered) / total : 1
    }

    /// Model-ranked leg order (U-OBJ): sort candidate legs by the SAME per-leg model the
    /// score uses, best first; dayID tiebreak keeps it deterministic. Replaces the coarse
    /// bookend-first/soonest orderings so the DEFAULT give-back / deal composition is what
    /// the objective itself would pick.
    // `private`: the signature uses the file-private `DayMap` typealias, so it cannot be
    // internal (Swift access rule); it's only called from inside TradeRouter anyway.
    nonisolated private static func modelRankedLegs(_ legs: [TwoWayLeg], giverID: String, receiverID: String,
                                            maps: [String: DayMap], quals: [String: [String]],
                                            priors: [String: Double], start: Date, selfID: String,
                                            mySeeking: Set<String>, myWantToWork: Set<String>,
                                            profilesByID: [String: TradeProfile]) -> [TwoWayLeg] {
        legs.map { leg -> (leg: TwoWayLeg, p: Double) in
            let f = legFeatures(giverID: giverID, receiverID: receiverID, day: leg.dayID, desk: leg.desk,
                                receiverQuals: quals[receiverID] ?? [], maps: maps, priors: priors,
                                selfID: selfID, start: start,
                                mySeeking: mySeeking, myWantToWork: myWantToWork, profilesByID: profilesByID)
            return (leg, TradeScore.legProb(f))
        }
        .sorted { $0.p != $1.p ? $0.p > $1.p : $0.leg.dayID < $1.leg.dayID }
        .map(\.leg)
    }

    /// How many of YOUR give-days this package covers (distinct days you hand off) — the PRIMARY ranking key.
    nonisolated private static func myGiveCoverage(_ pkg: TradePackage, selfID: String) -> Int {
        if let route = pkg.route { return Set(route.legs.filter { $0.fromID == selfID }.map(\.dayID)).count }
        return Set(pkg.assignments.flatMap(\.giveDayIDs)).count
    }

    // MARK: - Unified gate (per-leg quality floor + coverage-first ranking)
    static let floorNormalProb = 0.32   // normal feed: keep packages whose AVERAGE leg quality ≥ 0.32
    static let floorLuckyProb  = 0.07   // Lucky: wider, allow weaker matches
    static let emptyFallbackCount = 5   // if nothing clears the floor, still show the top few by quality

    /// Coverage-first ranking (what the user asked for): most of YOUR days covered → fewest people →
    /// bookends → acceptance quality → soonest → id. `acceptanceScore` is the AVERAGE leg quality (0…1),
    /// so a clean full-cover isn't buried for having many legs.
    /// PURE, testable: the reciprocal days I'll RECEIVE from a peer, in preference order (bookends — days
    /// that attach to my existing work — first, then soonest). A "clean" receive is a bookend or a day I
    /// explicitly marked want-to-work. When `bookendsOnly` (my openness = Bookends Only) the random
    /// mid-week islands are DROPPED entirely; otherwise (open-to-all) they're kept but sorted last, and a
    /// package built from them is ranked below all-clean ones (see `dirtyReceives`).
    static func cleanReceiveLegs(_ legs: [TwoWayLeg], wantToWork: Set<String>, bookendsOnly: Bool) -> [TwoWayLeg] {
        let base = bookendsOnly ? legs.filter { $0.bookend || wantToWork.contains($0.dayID) } : legs
        return base.sorted { ($0.bookend ? 0 : 1, $0.date) < ($1.bookend ? 0 : 1, $1.date) }
    }

    /// Is a received day "clean" for me — a bookend, or one I explicitly marked want-to-work?
    static func isCleanReceive(_ leg: TwoWayLeg, wantToWork: Set<String>) -> Bool {
        leg.bookend || wantToWork.contains(leg.dayID)
    }

    /// How many days a circular ROUTE hands ME that aren't clean — i.e. I receive them (leg points to me),
    /// I didn't mark want-to-work, and the day doesn't anchor to my existing work (not a bookend for me).
    /// `NWayLeg` carries no bookend flag, so it's derived from my own schedule via `isAnchored`.
    static func routeDirtyReceives(_ route: NWayRoute, selfID: String,
                                   myMap: [String: RosterEntry], wantToWork: Set<String>) -> Int {
        let myReceived = Set(route.legs.filter { $0.toID == selfID }.map(\.dayID))
        return route.legs.filter { leg in
            guard leg.toID == selfID, !wantToWork.contains(leg.dayID),
                  let d = TradeMatcher.dayDate(fromISO: leg.dayID) else { return false }
            return !TradeMatcher.isAnchored(day: d, map: myMap, plan: myReceived)
        }.count
    }

    /// THE single ranker (both feeds): unified score first, then deterministic tiebreaks.
    /// Exact Double equality is deliberate — an epsilon comparator breaks strict weak
    /// ordering (UB in sort); genuinely tied structures produce bit-identical scores and
    /// fall through to fireCount → date → id.
    nonisolated static func rankLess(_ a: TradePackage, _ b: TradePackage) -> Bool {
        if a.rankScore != b.rankScore { return a.rankScore > b.rankScore }
        if a.fireCount != b.fireCount { return a.fireCount > b.fireCount }   // bigger all-mutual deals first on ties
        let e0 = a.earliestDayID ?? "9999-12-31", e1 = b.earliestDayID ?? "9999-12-31"
        if e0 != e1 { return e0 < e1 }
        return a.id < b.id
    }

    /// Drop trades whose AVERAGE leg quality is below the floor (never a full-cover just for having many
    /// legs), keep a top-N fallback if the floor empties it, rank coverage-first, then a safety ceiling.
    /// Floor on the per-leg quality (never punishes a full cover for having many legs),
    /// qual-swap exempt (D6), top-N fallback if the floor empties the feed, one ranker,
    /// safety ceiling.
    nonisolated static func finalize(_ pkgs: [TradePackage], lucky: Bool) -> [TradePackage] {
        let floor = lucky ? floorLuckyProb : floorNormalProb
        let passed = pkgs.filter { $0.acceptanceScore >= floor || $0.needsQualSwap }
        let base = passed.isEmpty
            ? Array(pkgs.sorted(by: rankLess).prefix(emptyFallbackCount))
            : passed
        return Array(base.sorted(by: rankLess).prefix(intentResultCap))
    }

    /// B1: the BRIDGE-FIRST qual-swap finder (the green double-arrow button). For each selected international
    /// give-day it lists the **C bridges** — dispatchers WORKING that day who can slide onto my give-desk
    /// (any desk, not just domestic), favorability-ranked (their qual-swap preference), unfavorable ones
    /// flagged not dropped. One package per day carrying the bridges as `candidates`; there's no taker yet.
    /// Selecting + broadcasting sends a standing bridge request that LINKS into a normal A→B trade later
    /// (same give-day) via `TradeMerge`. (D6.)
    static func qualSwapOptions(forGiveShifts giveShifts: [Shift], excluding selfID: String) async -> [TradePackage] {
        let intlDays = giveShifts.filter { !$0.isOff && DeskRules.hasQualGatedSelection(desks: [$0.desk]) }
        guard !intlDays.isEmpty else { return [] }
        var result: [TradePackage] = []
        for shift in intlDays {
            let bridges = await TradeMatcher.qualSwapBridges(
                giveDayID: shift.id, giveDesk: shift.desk, giveStartHour: shift.startHour,
                excludeIDs: [selfID])   // bridge-first: no taker → lists every working bridge, favorability-ranked
            guard !bridges.isEmpty else { continue }
            let giveQual = DeskRules.requiredQual(forDesk: shift.desk) ?? "D"
            // takerID empty = unbound; the taker is supplied when this links into an A→B trade.
            let leg = QualSwapLegData(giveShiftDayID: shift.id, giveDesk: shift.desk, giveQual: giveQual,
                                      takerID: "", takerName: "", candidates: bridges)
            result.append(TradePackage(id: "qualbridge-\(shift.id)", methodology: .greedy,
                                       assignments: [], route: nil, urgency: 0, qualSwap: leg))
        }
        return result
    }

    // MARK: N-way circular routing

    /// A1 best-first: order the give-day seeds so the most promising are explored FIRST — under the
    /// route cap, the best loops surface instead of whatever the dictionary happened to yield first.
    /// `score` folds urgency + the TradeScore acceptance estimate (see `seedScore`); higher seeds
    /// first, ties broken by sooner ISO day (give-day IDs are "yyyy-MM-dd" → chronological). PURE.
    nonisolated static func bestFirstSeeds(_ seeds: [(dayID: String, score: Double)]) -> [String] {
        seeds.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.dayID < b.dayID
        }.map(\.dayID)
    }

    /// A1: a give-day's seed promise = urgency (dominant) + the TradeScore acceptance estimate of a
    /// representative leg (so soonness + qual-bridge friction refine within an urgency tier). The
    /// receiver is unknown at seed time, so only the giver-side/day-level features are used.
    nonisolated static func seedScore(urgency: Int, daysUntil: Int, qualGatedDesk: Bool) -> Double {
        let timeValue = exp(-0.05 * Double(max(0, daysUntil)))   // sooner → higher, in (0,1]
        let f = LegFeatures(wantToTake: false, wantToTrade: true, bookend: false,
                            timeValue: timeValue, needsQualBridge: qualGatedDesk)
        return Double(urgency) + TradeScore.legProb(f)   // urgency dominates; legProb refines ties
    }

    /// Resolves 3- and 4-person circular swap loops seeded from the user's
    /// give-away days. A→B→C→A: each person gives one shift and receives one, so
    /// everyone nets the same hours. Bounded by `maxDepth` participants.
    /// `allowPrefMiddles` (used by the Intents marketplace) lets non-seed participants join a loop on
    /// their PREFERENCES (availability/bookend) rather than requiring each to have marked the day. The
    /// loop still starts from a marked seed (≥1 intent leg); ranking by the real marked-leg count then
    /// floats all-intent loops to the top — without hard-coding an all-marked requirement.
    /// `maxRoutes` is the hard mid-search cap: the BASELINE search stops at 60; "I'm Feeling Lucky"
    /// raises it to 100 (the user opted in + narrowed the criteria, so it may take its time). With
    /// best-first seeding, the routes kept under the cap are the most promising ones. (A1.)
    // PURE / `nonisolated`: runs off the main actor over preloaded maps + Sendable snapshots (no `.shared`
    // access). Callers snapshot the main-actor state (`myProfile`, peer profiles, my keep/seeking days,
    // relief horizon, day notes/topologies) on the main actor and pass them in.
    nonisolated private static func nWayRoutes(seedShifts: [Shift], maxDepth: Int = 4,
                           excluding selfID: String,
                           constraints: MatchConstraints = .standard,
                           allowPrefMiddles: Bool = false,
                           maxRoutes: Int = 60,
                           windowStart: Date,
                           maps: [String: DayMap],
                           myProfile: TradeProfile,
                           profilesByID: [String: TradeProfile],
                           myKeepDays: Set<String>,
                           mySeeking: Set<String>,
                           myReliefThrough: Date?,
                           notesByDay: [String: DayNote],
                           topologyByDay: [String: DayTopology]) -> [NWayRoute] {
        let giveDays = seedShifts.filter { !$0.isOff }
        guard !giveDays.isEmpty else { return [] }
        let start = windowStart
        guard let selfMap = maps[selfID] else { return [] }

        var routes: [NWayRoute] = []
        var seen = Set<String>()

        // Whether `coverer` can legally cover `giver`'s shift on `dayID`. Delegates to the
        // unified predicate (U1): hard physical gates + weekly cap + the coverer's own rules
        // (`.full`). Bookend (no-split) stays a per-person preference owned by `wouldPickUp`.
        func canCover(covererID: String, covererMap: DayMap, giver entry: RosterEntry) -> Bool {
            guard let cover = covererMap[entry.day],
                  let day = TradeMatcher.dayDate(fromISO: entry.day) else { return false }
            let profile: TradeProfile? = covererID == selfID ? myProfile : profilesByID[covererID]
            guard let profile else { return false }
            return TradeEligibility.canCover(
                coverDayID: entry.day, coverDay: day, desk: entry.desk, startHour: entry.startHour,
                coverMap: covererMap, coverQuals: cover.quals, coverProfile: profile, options: .full).eligible
        }

        // A giver never gives away a day they marked KEEP (mustWork) — hard
        // disqualifier on the give side (SPEC S-ENG-9/10).
        func keepDays(_ workerID: String) -> Set<String> {
            workerID == selfID ? myKeepDays
                               : (profilesByID[workerID]?.keepDayIDs ?? [])
        }

        // A relief dispatcher's shift past their horizon isn't real → never give it.
        func reliefThrough(_ workerID: String) -> Date? {
            workerID == selfID ? myReliefThrough
                               : profilesByID[workerID]?.reliefThrough
        }
        func giveBlocked(_ workerID: String, _ entry: RosterEntry) -> Bool {
            guard let day = TradeMatcher.dayDate(fromISO: entry.day) else { return true }
            return TradeProfile.isPastRelief(day: day, reliefThrough: reliefThrough(workerID))
        }
        // A1 seed/expansion promise (hoisted so the DFS can order EVERY node best-first, not just seeds).
        func seedUrgency(_ dayID: String) -> Int {
            let reason = notesByDay[dayID]?.reason?.urgency ?? 0
            switch topologyByDay[dayID] ?? .standard {
            case .personalMilestone: return reason + 3
            case .highDemand:        return reason + 2
            case .standard:          return reason
            }
        }
        func daysUntil(_ dayID: String) -> Int {
            guard let d = TradeMatcher.dayDate(fromISO: dayID) else { return 0 }
            return max(0, Int(d.timeIntervalSince(start) / 86400))
        }
        /// Promise of `current` giving `entry` next — soonness + qual friction (+ urgency for self's
        /// own days). Used to order the DFS expansion so the cap keeps the best COMPLETE paths.
        func givePromise(_ entry: RosterEntry, by giverID: String) -> Double {
            seedScore(urgency: giverID == selfID ? seedUrgency(entry.day) : 0,
                      daysUntil: daysUntil(entry.day),
                      qualGatedDesk: DeskRules.hasQualGatedSelection(desks: [entry.desk]))
        }
        // U-PERF (B4-10): the giver's working days, best-first. `givePromise` is computed ONCE per entry
        // here instead of ~O(n log n) times inside a sort comparator at every DFS node. Result-neutral —
        // same entries, same keys, same deterministic sort → identical order (see B4-10 reasoning).
        func promiseSorted(_ map: DayMap, by giverID: String) -> [RosterEntry] {
            map.values.filter { !$0.isOff }
                .map { (entry: $0, p: givePromise($0, by: giverID)) }
                .sorted { $0.p > $1.p }
                .map(\.entry)
        }

        // DFS: path of leg tuples. Each step, the current node gives one of THEIR
        // working days to a next node who can cover it. Close when the last node's
        // gift is covered by SELF. A1: at EVERY node, the give-day candidates are tried best-first.
        func extend(path: [NWayLeg], visited: Set<String>, current: String, currentMap: DayMap) {
            if Task.isCancelled { return }                   // A1: cooperatively cancellable (Lucky re-filter)
            if routes.count > maxRoutes { return }           // hard mid-search cap (60 baseline / 100 Lucky)
            let depth = visited.count

            // Try to close the loop back to self — needs ≥3 participants total (#4). `depth` is
            // visited.count (self + others), so `>= 3` = self + ≥2 others; a 2-cycle is a 2-way swap,
            // handled by twoWayExplore/packages, never emitted here as a fake "circular."
            if depth >= 3 {
                for entry in promiseSorted(currentMap, by: current) {   // A1: best-first (B4-10: precomputed)
                    guard entry.day >= TradeMatcher.isoDay(start) else { continue }
                    guard !keepDays(current).contains(entry.day) else { continue }   // never give a Keep day
                    guard !giveBlocked(current, entry) else { continue }             // relief: not a real shift
                    // current gives `entry`; self must cover it.
                    if canCover(covererID: selfID, covererMap: selfMap, giver: entry) {
                        let closing = NWayLeg(fromID: current, toID: selfID, dayID: entry.day,
                                              desk: entry.desk, startHour: entry.startHour)
                        let legs = path + [closing]
                        let participants = [selfID] + legs.dropLast().map(\.toID)
                        // G3: count legs that are a bookend for their RECEIVER (no split). Drives the
                        // package's bookendTotal so split-heavy loops rank below clean ones.
                        let bookendCount = legs.filter { leg in
                            guard let d = TradeMatcher.dayDate(fromISO: leg.dayID), let m = maps[leg.toID] else { return false }
                            return TradeMatcher.isAnchored(day: d, map: m, plan: [leg.dayID])
                        }.count
                        let route = NWayRoute(
                            participants: participants, legs: legs,
                            tier: .matchingIntents,
                            score: Double(participants.count) + topologyWeight(of: legs, selfID: selfID, topologyByDay: topologyByDay),
                            usesBookends: constraints.enforceChaining,
                            bookendCount: bookendCount)
                        if seen.insert(route.id).inserted { routes.append(route) }
                        break
                    }
                }
            }
            guard depth < maxDepth else { return }

            // Otherwise, current gives one of their working days to a fresh node — A1: best-first.
            for entry in promiseSorted(currentMap, by: current) {   // B4-10: givePromise precomputed once/entry
                if keepDays(current).contains(entry.day) { continue }   // never give a Keep day
                if giveBlocked(current, entry) { continue }             // relief: not a real shift
                // Prefer days the current giver actually wants to give (intent). The Intents engine
                // (`allowPrefMiddles`) lets non-seed participants join via preferences instead — the
                // marked seed still guarantees ≥1 intent leg, and ranking rewards more marked legs.
                let wantsGive: Bool = current == selfID
                    ? mySeeking.contains(entry.day)
                    : (profilesByID[current]?.seekingDayIDs.contains(entry.day) ?? false)
                if constraints.enforceChaining && !allowPrefMiddles && !wantsGive { continue }

                for (nextID, nextMap) in maps.sorted(by: { $0.key < $1.key }) where !visited.contains(nextID) && nextID != selfID {
                    guard canCover(covererID: nextID, covererMap: nextMap, giver: entry) else { continue }
                    let leg = NWayLeg(fromID: current, toID: nextID, dayID: entry.day,
                                      desk: entry.desk, startHour: entry.startHour)
                    extend(path: path + [leg], visited: visited.union([nextID]),
                           current: nextID, currentMap: nextMap)
                }
            }
        }

        // Seed: self gives each seeking day to a first coverer. High-value dates
        // (high-demand / personal milestone) are protected from auto give-away
        // unless What If? mode is on. A1: explore the most URGENT/soonest seeds FIRST so the best
        // loops are found before the route cap bites. (seedUrgency/daysUntil hoisted above extend.)
        let seedOrder = bestFirstSeeds(giveDays.map { s in
            (dayID: s.id, score: seedScore(urgency: seedUrgency(s.id), daysUntil: daysUntil(s.id),
                                           qualGatedDesk: DeskRules.hasQualGatedSelection(desks: [s.desk])))
        })
        let orderedGiveDays = seedOrder.compactMap { id in giveDays.first { $0.id == id } }
        for s in orderedGiveDays {
            if Task.isCancelled { break }   // A1: bail the seed loop too when cancelled
            if constraints.enforceTopology, (topologyByDay[s.id] ?? .standard) != .standard { continue }
            guard let myEntry = selfMap[s.id] else { continue }
            if giveBlocked(selfID, myEntry) { continue }   // relief: my own post-horizon shift isn't real
            for (nextID, nextMap) in maps.sorted(by: { $0.key < $1.key }) where nextID != selfID {
                guard canCover(covererID: nextID, covererMap: nextMap, giver: myEntry) else { continue }
                let leg = NWayLeg(fromID: selfID, toID: nextID, dayID: myEntry.day,
                                  desk: myEntry.desk, startHour: myEntry.startHour)
                extend(path: [leg], visited: [selfID, nextID], current: nextID, currentMap: nextMap)
            }
        }
        return routes
    }

    // MARK: Helpers

    /// Score bonus for resolving higher-gravity dates (weight − 1 per self give-leg;
    /// standard days add nothing).
    nonisolated private static func topologyWeight(of legs: [NWayLeg], selfID: String,
                                                   topologyByDay: [String: DayTopology]) -> Double {
        legs.filter { $0.fromID == selfID }
            .reduce(0) { $0 + (topologyByDay[$1.dayID] ?? .standard).weight - 1 }
    }

    /// The user's working days they're actively seeking to give away, as `Shift`s.
    private static func selfSeekingShifts(myID: String, start: Date, end: Date) async -> [Shift] {
        let seeking = DayIntentStore.shared.seekingDayIDs
        guard !seeking.isEmpty else { return [] }
        let mine = await RosterStore.shared.schedule(forWorker: myID)
        return mine.compactMap { e in
            guard !e.isOff, seeking.contains(e.day), let date = TradeMatcher.dayDate(fromISO: e.day) else { return nil }
            return Shift(id: e.day, date: date,
                         startHour: e.startHour, endHour: (e.startHour + 9) % 24,
                         role: .dispatcher, desk: e.desk, leaveCode: nil, isOff: false)
        }
    }

}
