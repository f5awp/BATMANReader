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
    let takeDayIDs: [String]   // THEIR shifts you cover (them → you)
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

    // EXPLICIT init — freezes the construction signature so adding the fields above doesn't
    // churn the memberwise-init symbol (stale-incremental-link fix). New fields are defaulted.
    init(id: String, methodology: TradeMethodology, assignments: [PackageAssignment],
         route: NWayRoute?, urgency: Int = 0, isOptimal: Bool = false,
         fireCount: Int = 0, bookendTotal: Int = 0, qualSwap: QualSwapLegData? = nil) {
        self.id = id; self.methodology = methodology; self.assignments = assignments
        self.route = route; self.urgency = urgency; self.isOptimal = isOptimal
        self.fireCount = fireCount; self.bookendTotal = bookendTotal; self.qualSwap = qualSwap
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

    // MARK: Greedy recipient minimization


    // MARK: Packaged solutions (greedy first, circular as a >2-person alternative)

    /// Build proposable packages for the user's give-away days. Greedy "fewest
    /// people" covers come first; if the best greedy needs >2 coverers, circular
    /// swap loops are offered alongside (not instead). Sorted fewest-people first.
    static func packages(excluding selfID: String) async -> [TradePackage] {
        let (start, end) = horizon
        let giveShifts = await selfSeekingShifts(myID: selfID, start: start, end: end)
        return await packages(forGiveShifts: giveShifts, excluding: selfID)
    }

    /// RECIPROCAL packaging for an explicit set of give-away shifts. Every package
    /// is balanced — you give N and receive N back, all passing your criteria. A
    /// pairwise greedy (fewest counterparties) comes first; N-way circular loops
    /// are offered when pairwise can't fully reciprocate. Used by both feeds.
    static func packages(forGiveShifts giveShifts: [Shift], excluding selfID: String) async -> [TradePackage] {
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

        let (start, end) = horizon
        let mySeeking = DayIntentStore.shared.seekingDayIDs
        let myProfile = TradeProfileStore.shared.myProfile()

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

        // R-A: the candidate UNIVERSE is the whole roster, not just opted-in profiles. Load every
        // worker's schedule in the window ONCE, derive the universe (unknown-profile peers included),
        // and reuse the loaded schedules in twoWayExplore (no per-peer re-fetch).
        let allEntries = await RosterStore.shared.entries(from: start, to: end)
        var maps: [String: [String: RosterEntry]] = [:]
        var rosterMeta: [String: (name: String, quals: [String])] = [:]
        for e in allEntries {
            maps[e.workerID, default: [:]][e.day] = e
            if rosterMeta[e.workerID] == nil { rosterMeta[e.workerID] = (e.workerName, e.quals) }
        }
        let profilesByID = TradeProfileStore.shared.others
        let universe = MatchUniverse.candidates(
            roster: rosterMeta.map { (id: $0.key, name: $0.value.name, quals: $0.value.quals) },
            profiles: profilesByID, selfID: selfID)
        func profileFor(_ id: String, _ name: String) -> TradeProfile {
            profilesByID[id] ?? TradeProfile.defaultForUnpublished(workerID: id, name: name)   // A8: missing → Bookends Only
        }
        let mineEntries = Array((maps[selfID] ?? [:]).values)

        // Per-peer reciprocal capacity via two-way exploration, gated by BOTH parties' real rules.
        struct PeerSwap { let id: String; let name: String; let canTake: [String]; let givesBack: [String] }
        var peerSwaps: [PeerSwap] = []
        var plansByPeer: [String: TwoWayPlan] = [:]   // retained for U4 fire/bookend scoring
        for cand in universe.sorted(by: { $0.workerID < $1.workerID }) {
            let profile = profileFor(cand.workerID, cand.name)
            let plan = await TradeMatcher.twoWayExplore(
                withWorker: cand.workerID, name: cand.name,
                windowStart: start, windowEnd: end,
                mySeeking: mySeeking, theirSeeking: profile.seekingDayIDs,
                myProfile: myProfile, theirProfile: profile, myID: selfID,
                preloadedMine: mineEntries, preloadedPeer: Array((maps[cand.workerID] ?? [:]).values))
            plansByPeer[cand.workerID] = plan
            let canTake   = plan.iGive.filter { giveDayIDs.contains($0.dayID) && wouldTake(profile, $0) }.map(\.dayID)
            let givesBack = plan.iTake.filter { wouldTake(myProfile, $0) }.map(\.dayID)
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
        // Only people whose rule is "bookends" must keep contiguous breaks.
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

        // 1) Single-person full swaps — EVERY peer who can reciprocally cover all
        //    your give-days alone is its own clean 1-person option. This is the main
        //    source of variety (you often have several people who could each do it).
        for ps in peerSwaps where Set(ps.canTake).isSuperset(of: giveDayIDs) && ps.givesBack.count >= giveAll.count {
            let a = [PackageAssignment(workerID: ps.id, name: ps.name,
                                       giveDayIDs: giveAll, takeDayIDs: Array(ps.givesBack.prefix(giveAll.count)))]
            if contiguityOK(asOpt(a)) {
                result.append(TradePackage(id: "solo-" + ps.id, methodology: .greedy, assignments: a,
                                           route: nil, urgency: urgency(of: giveAll), isOptimal: true))
            }
        }

        // 2) If nobody can do it alone, find the fewest-people multi-person cover
        //    (optimal), else a greedy balanced cover.
        if result.isEmpty {
            let cands = peerSwaps.map {
                OptimalMatcher.Cand(id: $0.id, name: $0.name, canTake: Set($0.canTake), givesBack: $0.givesBack)
            }
            if let opt = OptimalMatcher.minPeopleReciprocal(giveDayIDs: giveAll, peers: cands, contiguous: contiguityOK) {
                let a = opt.map { PackageAssignment(workerID: $0.id, name: $0.name,
                                                    giveDayIDs: $0.giveDayIDs, takeDayIDs: $0.takeDayIDs) }
                result.append(TradePackage(
                    id: "optimal-" + a.map(\.workerID).sorted().joined(separator: ","),
                    methodology: .greedy, assignments: a, route: nil,
                    urgency: urgency(of: a.flatMap(\.giveDayIDs)), isOptimal: true))
            }
            var uncovered = giveDayIDs
            var usedBack = Set<String>()
            var assigns: [PackageAssignment] = []
            var pool = peerSwaps
            while result.isEmpty, !uncovered.isEmpty {
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
            if result.isEmpty, uncovered.isEmpty, !assigns.isEmpty, contiguityOK(asOpt(assigns)) {
                result.append(TradePackage(
                    id: "recip-" + assigns.map(\.workerID).sorted().joined(separator: ","),
                    methodology: .greedy, assignments: assigns, route: nil,
                    urgency: urgency(of: assigns.flatMap(\.giveDayIDs))))
            }
        }

        // 3) Circular loops — ALWAYS surfaced (not only when solos are scarce) so the N+1 group
        //    appears alongside the N=2 solos (U3 "N=2 then N+1"). `rankPackages` orders N=2 first.
        do {
            let loops = await nWayRoutes(seedShifts: giveShifts, excluding: selfID)
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
            } else {
                var fire = 0, book = 0
                for a in pkg.assignments {
                    let plan = plansByPeer[a.workerID]
                    let giveByDay = Dictionary((plan?.iGive ?? []).map { ($0.dayID, $0) }, uniquingKeysWith: { x, _ in x })
                    let takeByDay = Dictionary((plan?.iTake ?? []).map { ($0.dayID, $0) }, uniquingKeysWith: { x, _ in x })
                    for d in a.giveDayIDs { if let l = giveByDay[d] { if l.bookend { book += 1 }; if l.wanted { fire += 1 } } }
                    for d in a.takeDayIDs { if let l = takeByDay[d] { if l.bookend { book += 1 }; if l.wanted { fire += 1 } } }
                }
                p.fireCount = fire; p.bookendTotal = book
            }
            return p
        }
        return Self.rankPackages(scored)
    }

    /// U4 priority tier (lower = higher priority): 0 = 🔥+bookends, 1 = 🔥-only, 2 = bookends-only.
    static func packageTier(_ p: TradePackage) -> Int {
        if p.fireCount > 0 { return p.bookendTotal > 0 ? 0 : 1 }
        return 2
    }

    /// PURE, testable (A5 + U4): dedupe by id; drop bookends-only packages below the **top two
    /// bands** (keep `max` and `max−1`, hide the clutter); then sort **fewest people first**
    /// (the N groups), then by tier (🔥+bookends → 🔥 → bookends-only), then 🔥 count, then total
    /// bookends (more is more optimal even when open-to-all), then urgency, then greedy ahead of circular.
    static func rankPackages(_ packages: [TradePackage]) -> [TradePackage] {
        var seen = Set<String>()
        let deduped = packages.filter { seen.insert($0.id).inserted }
        // Bookends-only tier (no 🔥) is capped to the top two bands. 🔥 packages AND qual-swap
        // packages are EXEMPT — a qual-swap solution must never be hidden by a low bookend count.
        let capped = deduped.filter { $0.fireCount == 0 && $0.qualSwap == nil }
        let exempt = deduped.filter { $0.fireCount > 0 || $0.qualSwap != nil }
        let keptCapped: [TradePackage]
        if let maxBO = capped.map(\.bookendTotal).max() {
            keptCapped = capped.filter { $0.bookendTotal >= maxBO - 1 }
        } else {
            keptCapped = capped
        }
        return (exempt + keptCapped).sorted {
            if $0.peopleCount != $1.peopleCount { return $0.peopleCount < $1.peopleCount }   // N groups
            if $0.needsQualSwap != $1.needsQualSwap { return !$0.needsQualSwap }             // D5: clean before qual, same N
            let t0 = packageTier($0), t1 = packageTier($1)
            if t0 != t1 { return t0 < t1 }
            if $0.fireCount != $1.fireCount { return $0.fireCount > $1.fireCount }
            if $0.bookendTotal != $1.bookendTotal { return $0.bookendTotal > $1.bookendTotal }
            // #4b: all else equal, the CLOSER (earlier) trade date sorts first.
            let e0 = $0.earliestDayID ?? "9999-12-31", e1 = $1.earliestDayID ?? "9999-12-31"
            if e0 != e1 { return e0 < e1 }
            if $0.urgency != $1.urgency { return $0.urgency > $1.urgency }
            if ($0.methodology == .greedy) != ($1.methodology == .greedy) { return $0.methodology == .greedy }
            return $0.id < $1.id
        }
    }

    // MARK: N-way circular routing

    /// Resolves 3- and 4-person circular swap loops seeded from the user's
    /// give-away days. A→B→C→A: each person gives one shift and receives one, so
    /// everyone nets the same hours. Bounded by `maxDepth` participants.
    static func nWayRoutes(seedShifts: [Shift], maxDepth: Int = 4,
                           excluding selfID: String,
                           constraints: MatchConstraints = .standard) async -> [NWayRoute] {
        let giveDays = seedShifts.filter { !$0.isOff }
        guard !giveDays.isEmpty else { return [] }

        let (start, end) = horizon
        let entries = await RosterStore.shared.entries(from: start, to: end)
        var maps: [String: DayMap] = [:]
        var names: [String: String] = [:]
        for e in entries {
            maps[e.workerID, default: [:]][e.day] = e
            names[e.workerID] = e.workerName
        }
        guard let selfMap = maps[selfID] else { return [] }
        let myProfile = TradeProfileStore.shared.myProfile()

        var routes: [NWayRoute] = []
        var seen = Set<String>()

        // Whether `coverer` can legally cover `giver`'s shift on `dayID`. Delegates to the
        // unified predicate (U1): hard physical gates + weekly cap + the coverer's own rules
        // (`.full`). Bookend (no-split) stays a per-person preference owned by `wouldPickUp`.
        func canCover(covererID: String, covererMap: DayMap, giver entry: RosterEntry) -> Bool {
            guard let cover = covererMap[entry.day],
                  let day = TradeMatcher.dayDate(fromISO: entry.day) else { return false }
            let profile = covererID == selfID ? myProfile : TradeProfileStore.shared.profile(forWorker: covererID)
            guard let profile else { return false }
            return TradeEligibility.canCover(
                coverDayID: entry.day, coverDay: day, desk: entry.desk, startHour: entry.startHour,
                coverMap: covererMap, coverQuals: cover.quals, coverProfile: profile, options: .full).eligible
        }

        // A giver never gives away a day they marked KEEP (mustWork) — hard
        // disqualifier on the give side (SPEC S-ENG-9/10).
        func keepDays(_ workerID: String) -> Set<String> {
            workerID == selfID ? DayIntentStore.shared.keepDayIDs
                               : (TradeProfileStore.shared.profile(forWorker: workerID)?.keepDayIDs ?? [])
        }

        // A relief dispatcher's shift past their horizon isn't real → never give it.
        func reliefThrough(_ workerID: String) -> Date? {
            workerID == selfID ? SettingsManager.shared.effectiveReliefThrough
                               : TradeProfileStore.shared.profile(forWorker: workerID)?.reliefThrough
        }
        func giveBlocked(_ workerID: String, _ entry: RosterEntry) -> Bool {
            guard let day = TradeMatcher.dayDate(fromISO: entry.day) else { return true }
            return TradeProfile.isPastRelief(day: day, reliefThrough: reliefThrough(workerID))
        }

        // DFS: path of leg tuples. Each step, the current node gives one of THEIR
        // working days to a next node who can cover it. Close when the last node's
        // gift is covered by SELF.
        func extend(path: [NWayLeg], visited: Set<String>, current: String, currentMap: DayMap) {
            if routes.count > 60 { return }                 // global safety cap
            let depth = visited.count

            // Try to close the loop back to self — needs ≥3 participants total (#4). `depth` is
            // visited.count (self + others), so `>= 3` = self + ≥2 others; a 2-cycle is a 2-way swap,
            // handled by twoWayExplore/packages, never emitted here as a fake "circular."
            if depth >= 3 {
                for entry in currentMap.values where !entry.isOff {
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
                            score: Double(participants.count) + topologyWeight(of: legs, selfID: selfID),
                            usesBookends: constraints.enforceChaining,
                            bookendCount: bookendCount)
                        if seen.insert(route.id).inserted { routes.append(route) }
                        break
                    }
                }
            }
            guard depth < maxDepth else { return }

            // Otherwise, current gives one of their working days to a fresh node.
            for entry in currentMap.values where !entry.isOff {
                if keepDays(current).contains(entry.day) { continue }   // never give a Keep day
                if giveBlocked(current, entry) { continue }             // relief: not a real shift
                // Prefer days the current giver actually wants to give (intent).
                let wantsGive: Bool = current == selfID
                    ? DayIntentStore.shared.seekingDayIDs.contains(entry.day)
                    : (TradeProfileStore.shared.profile(forWorker: current)?.seekingDayIDs.contains(entry.day) ?? false)
                if constraints.enforceChaining && !wantsGive { continue }

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
        // unless What If? mode is on.
        for s in giveDays {
            if constraints.enforceTopology, DayIntentStore.shared.topology(forDay: s.id) != .standard { continue }
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

    /// The weekly-hour cap for a worker, if any (self from Settings, peers from
    /// their published profile).
    private static func weeklyCap(forWorker id: String) -> Int? {
        if id == SettingsManager.shared.username { return SettingsManager.shared.maxWeeklyHours }
        return TradeProfileStore.shared.profile(forWorker: id)?.maxWeeklyHours
    }

    /// Worked hours in the Sun–Sat week containing `day` (each shift = 9h).
    private static func weeklyWorkedHours(map: DayMap, around day: Date) -> Int {
        let cal = Calendar.current
        guard let week = cal.dateInterval(of: .weekOfYear, for: day) else { return 0 }
        var hours = 0
        for entry in map.values where !entry.isOff {
            if let d = TradeMatcher.dayDate(fromISO: entry.day), week.contains(d) { hours += 9 }
        }
        return hours
    }

    /// Score bonus for resolving higher-gravity dates (weight − 1 per self give-leg;
    /// standard days add nothing).
    private static func topologyWeight(of legs: [NWayLeg], selfID: String) -> Double {
        legs.filter { $0.fromID == selfID }
            .reduce(0) { $0 + DayIntentStore.shared.topology(forDay: $1.dayID).weight - 1 }
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
