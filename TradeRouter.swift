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
    var peopleCount: Int { Set(assignments.map(\.workerID)).count }
    var allDayIDs: [String] { assignments.flatMap(\.dayIDs) }
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

        // Per-peer reciprocal capacity via two-way exploration, then gated by BOTH
        // parties' real rules: they only take my days they'd accept; I only take
        // theirs I'd accept.
        struct PeerSwap { let id: String; let name: String; let canTake: [String]; let givesBack: [String] }
        var peerSwaps: [PeerSwap] = []
        // Deterministic order (by employee ID) so results don't flicker between refreshes.
        for (peerID, profile) in TradeProfileStore.shared.others.sorted(by: { $0.key < $1.key }) {
            let plan = await TradeMatcher.twoWayExplore(
                withWorker: peerID, name: profile.displayName,
                windowStart: start, windowEnd: end,
                mySeeking: mySeeking, theirSeeking: profile.seekingDayIDs,
                myProfile: myProfile, theirProfile: profile, myID: selfID)
            let canTake   = plan.iGive.filter { giveDayIDs.contains($0.dayID) && wouldTake(profile, $0) }.map(\.dayID)
            let givesBack = plan.iTake.filter { wouldTake(myProfile, $0) }.map(\.dayID)
            if !canTake.isEmpty, !givesBack.isEmpty {
                peerSwaps.append(PeerSwap(id: peerID, name: profile.displayName, canTake: canTake, givesBack: givesBack))
            }
        }

        var result: [TradePackage] = []

        // Schedules for per-person SET contiguity (the bookend no-split rule across
        // ALL of someone's assigned days, not per leg).
        let allEntries = await RosterStore.shared.entries(from: start, to: end)
        var maps: [String: [String: RosterEntry]] = [:]
        for e in allEntries { maps[e.workerID, default: [:]][e.day] = e }
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

        // OPTIMAL tier: provably fewest counterparties (branch-and-bound + min-cost
        // flow), rejecting break-fragmenting assignments. nil → greedy fallback.
        let cands = peerSwaps.map {
            OptimalMatcher.Cand(id: $0.id, name: $0.name, canTake: Set($0.canTake), givesBack: $0.givesBack)
        }
        if let opt = OptimalMatcher.minPeopleReciprocal(giveDayIDs: Array(giveDayIDs), peers: cands, contiguous: contiguityOK) {
            let a = opt.map { PackageAssignment(workerID: $0.id, name: $0.name,
                                                giveDayIDs: $0.giveDayIDs, takeDayIDs: $0.takeDayIDs) }
            result.append(TradePackage(
                id: "optimal-" + a.map(\.workerID).sorted().joined(separator: ","),
                methodology: .greedy, assignments: a, route: nil,
                urgency: urgency(of: a.flatMap(\.giveDayIDs)), isOptimal: true))
        }

        // Greedy balanced cover (fallback / alternative): repeatedly take the peer
        // who reciprocally clears the most remaining give-days, until fully covered.
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
                // 1) clears the most give-days, then 2) clears the most-urgent days
                // (milestones / high-demand / reasons), then 3) seniority — lower
                // employee number = more senior (AA numbers are seniority-ordered).
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
        // Emit the greedy package ONLY if it passes the same no-split contiguity
        // check the optimal path uses — so a break-fragmenting assignment is never
        // proposed even on instances too large for the optimizer. Better to offer
        // nothing than a package that splits someone's break.
        if result.isEmpty, uncovered.isEmpty, !assigns.isEmpty {
            let asOpt = assigns.map { OptimalMatcher.Assignment(
                id: $0.workerID, name: $0.name,
                giveDayIDs: $0.giveDayIDs, takeDayIDs: $0.takeDayIDs) }
            if contiguityOK(asOpt) {
                result.append(TradePackage(
                    id: "recip-" + assigns.map(\.workerID).sorted().joined(separator: ","),
                    methodology: .greedy, assignments: assigns, route: nil,
                    urgency: urgency(of: assigns.flatMap(\.giveDayIDs))))
            }
        }

        // N-way circular fallback when pairwise can't fully reciprocate (or to
        // offer a smaller-headcount loop). The loop is inherently balanced.
        if result.first?.peopleCount ?? Int.max > 1 || result.isEmpty {
            let loops = await nWayRoutes(seedShifts: giveShifts, excluding: selfID)
            for loop in loops.prefix(6) {
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

        // Dedupe + rank: fewest people, then urgency, greedy ahead of circular.
        var seen = Set<String>()
        return result
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.peopleCount != $1.peopleCount { return $0.peopleCount < $1.peopleCount }
                if $0.urgency != $1.urgency { return $0.urgency > $1.urgency }
                return $0.methodology == .greedy && $1.methodology == .circular
            }
    }

    // MARK: Tiered two-way solutions (the "Trade by Intents" feed)

    /// Segments feasible two-way swaps with each peer into the four SolutionTiers.
    /// Peers come from published profiles (`TradeProfileStore.others`). Each swap is
    /// returned as a 2-participant `NWayRoute` so the feed renders uniformly; the
    /// UI can reopen the rich `TwoWaySheet` from `participants[1]`.
    static func tieredSolutions(isWhatIfModeActive: Bool = false)
        async -> [(tier: SolutionTier, routes: [NWayRoute])] {

        let constraints = MatchConstraints.make(isWhatIfModeActive: isWhatIfModeActive)
        let myID = SettingsManager.shared.username
        guard !myID.isEmpty else { return SolutionTier.allCases.map { ($0, []) } }

        let myProfile = TradeProfileStore.shared.myProfile()
        let mySeeking = DayIntentStore.shared.seekingDayIDs
        let (start, end) = horizon

        var byTier: [SolutionTier: [NWayRoute]] = [:]
        for t in SolutionTier.allCases { byTier[t] = [] }

        for (peerID, profile) in TradeProfileStore.shared.others.sorted(by: { $0.key < $1.key }) {
            let plan = await TradeMatcher.twoWayExplore(
                withWorker: peerID, name: profile.displayName,
                windowStart: start, windowEnd: end,
                mySeeking: mySeeking, theirSeeking: profile.seekingDayIDs,
                myProfile: myProfile, theirProfile: profile, myID: myID)
            guard plan.isViable else { continue }

            // Protect high-value dates: if the only days I'd give are high-demand /
            // milestone, don't surface the swap unless What If? is on.
            if constraints.enforceTopology, !plan.iGive.isEmpty,
               plan.iGive.allSatisfy({ DayIntentStore.shared.topology(forDay: $0.dayID) != .standard }) {
                continue
            }

            let iWant = plan.iGive.contains { $0.wanted }      // I actively seek a give-day
            let theyWant = plan.iTake.contains { $0.wanted }   // they actively seek a give-day
            let bookended = plan.iGive.allSatisfy(\.bookend) && plan.iTake.allSatisfy(\.bookend)

            let tier: SolutionTier
            if iWant && theyWant {
                tier = (constraints.enforceChaining && bookended) ? .intentsAndBookends : .matchingIntents
            } else if iWant || theyWant {
                tier = .neutralOptimization
            } else if profile.opennessLevel != .none {
                tier = constraints.enforceChaining ? .neutralOptimization : .globalPool
            } else {
                continue
            }

            byTier[tier, default: []].append(route(from: plan, myID: myID))
        }

        // Fold in circular routes seeded from my seeking days.
        let myShifts = await selfSeekingShifts(myID: myID, start: start, end: end)
        let loops = await nWayRoutes(seedShifts: myShifts, excluding: myID, constraints: constraints)
        for loop in loops {
            let everyGiverSeeks = loop.legs.allSatisfy { leg in
                if leg.fromID == myID { return mySeeking.contains(leg.dayID) }
                return TradeProfileStore.shared.profile(forWorker: leg.fromID)?
                    .seekingDayIDs.contains(leg.dayID) ?? false
            }
            byTier[everyGiverSeeks ? .matchingIntents : .neutralOptimization, default: []].append(loop)
        }

        return SolutionTier.allCases
            .sorted { $0.order < $1.order }
            .map { ($0, byTier[$0] ?? []) }
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

        // Whether `coverer` can legally cover `giver`'s shift on `dayID` (hard gates).
        func canCover(covererID: String, covererMap: DayMap, giver entry: RosterEntry) -> Bool {
            guard let cover = covererMap[entry.day], cover.isOff else { return false }
            guard let day = TradeMatcher.dayDate(fromISO: entry.day) else { return false }
            guard DeskRules.qualified(quals: cover.quals, forDesk: entry.desk) else { return false }
            guard TradeMatcher.isRested(map: covererMap, day: day, startHour: entry.startHour) else { return false }
            // Hard: weekly-hour cap (always enforced, even in What If?).
            if let cap = weeklyCap(forWorker: covererID),
               weeklyWorkedHours(map: covererMap, around: day) + 9 > cap { return false }
            // Bookend (no-split) is NOT forced globally here — it's a per-person
            // preference owned entirely by `wouldPickUp` below: a `.bookends` peer
            // rejects non-anchored pickups, an `.all` peer accepts them. (This is
            // why "open to everything" truly ignores chaining.)
            // Pill-based availability gate (published per-day pills, else openness),
            // via published profile (others) / my profile (self).
            let weekday = Calendar.current.component(.weekday, from: day)
            let region  = DeskRules.region(forDesk: entry.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: entry.startHour).rawValue
            let bookend = TradeMatcher.isAnchored(day: day, map: covererMap, plan: [entry.day])
            let profile = covererID == selfID ? myProfile : TradeProfileStore.shared.profile(forWorker: covererID)
            guard let profile else { return false }
            return profile.wouldPickUp(onDay: entry.day, weekday: weekday, desk: entry.desk,
                                       shiftType: type, region: region, isBookend: bookend)
        }

        // DFS: path of leg tuples. Each step, the current node gives one of THEIR
        // working days to a next node who can cover it. Close when the last node's
        // gift is covered by SELF.
        func extend(path: [NWayLeg], visited: Set<String>, current: String, currentMap: DayMap) {
            if routes.count > 60 { return }                 // global safety cap
            let depth = visited.count

            // Try to close the loop back to self (needs ≥3 participants total).
            if depth >= 2 {
                for entry in currentMap.values where !entry.isOff {
                    guard entry.day >= TradeMatcher.isoDay(start) else { continue }
                    // current gives `entry`; self must cover it.
                    if canCover(covererID: selfID, covererMap: selfMap, giver: entry) {
                        let closing = NWayLeg(fromID: current, toID: selfID, dayID: entry.day,
                                              desk: entry.desk, startHour: entry.startHour)
                        let legs = path + [closing]
                        let participants = [selfID] + legs.dropLast().map(\.toID)
                        let route = NWayRoute(
                            participants: participants, legs: legs,
                            tier: .matchingIntents,
                            score: Double(participants.count) + topologyWeight(of: legs, selfID: selfID),
                            usesBookends: constraints.enforceChaining)
                        if seen.insert(route.id).inserted { routes.append(route) }
                        break
                    }
                }
            }
            guard depth < maxDepth else { return }

            // Otherwise, current gives one of their working days to a fresh node.
            for entry in currentMap.values where !entry.isOff {
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

    /// Represent a viable two-way plan as a 2-participant route for the feed.
    private static func route(from plan: TwoWayPlan, myID: String) -> NWayRoute {
        let give = plan.iGive.first { $0.wanted } ?? plan.iGive.first
        let take = plan.iTake.first { $0.wanted } ?? plan.iTake.first
        var legs: [NWayLeg] = []
        if let g = give {
            legs.append(NWayLeg(fromID: myID, toID: plan.workerID, dayID: g.dayID,
                                desk: g.desk, startHour: g.startHour))
        }
        if let t = take {
            legs.append(NWayLeg(fromID: plan.workerID, toID: myID, dayID: t.dayID,
                                desk: t.desk, startHour: t.startHour))
        }
        let mutual = plan.mutualWanted
        return NWayRoute(participants: [myID, plan.workerID], legs: legs,
                         tier: mutual > 0 ? .matchingIntents : .neutralOptimization,
                         score: Double(mutual) + 1, usesBookends: true)
    }
}
