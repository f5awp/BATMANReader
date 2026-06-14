// TradeRouter.swift
// v2 matchmaking on top of the existing TradeMatcher. Adds:
//   • tieredSolutions   — segments swaps into the 4 SolutionTiers for the feed
//   • nWayRoutes        — bounded 3–4-person circular trade loops
//   • minimalCover      — greedy "fewest people" cover of a contiguous block
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

// MARK: - Block-cover result (one-directional give-away, not a swap loop)

/// A way to offload a `ShiftBlock` to one or more coverers. Fewer `assignments`
/// (unique people) is better — it preserves the block as a whole.
struct BlockCover: Sendable, Hashable, Identifiable {
    struct Assignment: Sendable, Hashable {
        let workerID: String
        let name: String
        let dayIDs: [String]
    }
    let assignments: [Assignment]

    var uniquePeople: Int { assignments.count }
    var coveredDayIDs: [String] { assignments.flatMap(\.dayIDs) }
    var id: String {
        assignments.map { $0.workerID + ":" + $0.dayIDs.joined(separator: ",") }
            .joined(separator: "|")
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

    /// Offload a contiguous block to the FEWEST unique people. Returns covers
    /// ranked best-first: full single-person pickups, then the greedy multi-person
    /// split. Empty if no legal coverage exists for any day.
    static func minimalCover(block: ShiftBlock, excluding selfID: String,
                             constraints: MatchConstraints = .standard) async -> [BlockCover] {
        let shifts = block.shifts.filter { !$0.isOff }
        guard !shifts.isEmpty else { return [] }

        // Candidate coverage per worker, reusing the existing one-way matcher.
        let candidates = await TradeMatcher.candidatesForTrades(shifts: shifts, excluding: selfID)
        guard !candidates.isEmpty else { return [] }

        let allDayIDs = Set(shifts.map(\.id))
        let shiftDayID = Dictionary(uniqueKeysWithValues: shifts.map { ($0.id, $0.id) })
        _ = shiftDayID

        // Map each candidate to the set of block day-IDs they can cover.
        var coverable: [(id: String, name: String, days: Set<String>)] = candidates.map {
            ($0.workerID, $0.name, $0.coveredShiftIDs.intersection(allDayIDs))
        }
        .filter { !$0.days.isEmpty }

        var results: [BlockCover] = []

        // 1) Anyone who can cover the WHOLE block alone (ideal — 1 person).
        for c in coverable where c.days == allDayIDs {
            results.append(BlockCover(assignments: [
                .init(workerID: c.id, name: c.name, dayIDs: shifts.map(\.id).filter { c.days.contains($0) })
            ]))
        }

        // 2) Greedy set cover: repeatedly take the worker covering the most
        //    still-uncovered days, until the block is covered or no progress.
        var uncovered = allDayIDs
        var picks: [BlockCover.Assignment] = []
        while !uncovered.isEmpty {
            guard let best = coverable
                .map({ (c) in (c, c.days.intersection(uncovered)) })
                .filter({ !$0.1.isEmpty })
                .max(by: { $0.1.count < $1.1.count }) else { break }
            let (c, gained) = best
            let orderedDays = shifts.map(\.id).filter { gained.contains($0) }
            picks.append(.init(workerID: c.id, name: c.name, dayIDs: orderedDays))
            uncovered.subtract(gained)
            coverable.removeAll { $0.id == c.id }
        }
        if uncovered.isEmpty, picks.count > 1 || results.isEmpty {
            results.append(BlockCover(assignments: picks))
        }

        // Rank: fewest people first, then most days covered.
        return results
            .filter { !$0.assignments.isEmpty }
            .sorted {
                if $0.uniquePeople != $1.uniquePeople { return $0.uniquePeople < $1.uniquePeople }
                return $0.coveredDayIDs.count > $1.coveredDayIDs.count
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

        for (peerID, profile) in TradeProfileStore.shared.others {
            let plan = await TradeMatcher.twoWayExplore(
                withWorker: peerID, name: profile.displayName,
                windowStart: start, windowEnd: end,
                mySeeking: mySeeking, theirSeeking: profile.seekingDayIDs,
                myProfile: myProfile, myID: myID)
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
        let selfQuals = selfMap.values.first?.quals ?? []
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
            // Soft: chaining (bookend) — only when enforced.
            if constraints.enforceChaining,
               !TradeMatcher.isAnchored(day: day, map: covererMap, plan: [entry.day]) { return false }
            // Inbound blacklist gate via published profile (others) / my profile (self).
            let weekday = Calendar.current.component(.weekday, from: day)
            let region  = DeskRules.region(forDesk: entry.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: entry.startHour).rawValue
            if covererID == selfID {
                if DayIntentStore.shared.offIntent(forDay: entry.day) == .mustBeOff { return false }
                return myProfile.acceptsPickup(weekday: weekday, desk: entry.desk, shiftType: type, region: region)
            }
            guard let prof = TradeProfileStore.shared.profile(forWorker: covererID) else { return false }
            return prof.acceptsPickup(weekday: weekday, desk: entry.desk, shiftType: type, region: region)
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

                for (nextID, nextMap) in maps where !visited.contains(nextID) && nextID != selfID {
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
            for (nextID, nextMap) in maps where nextID != selfID {
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
