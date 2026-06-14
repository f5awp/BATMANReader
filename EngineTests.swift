// EngineTests.swift
// A runnable self-test harness for the trade engine. There's no XCTest target, so
// these are plain assertions invokable from Developer Tools (Settings → Developer →
// "Run engine tests"). Returns the list of failures ([] = all pass). Covers the
// risky, pure logic: min-cost flow, the optimal reciprocal matcher (golden cases,
// balance, determinism, infeasibility), holiday math, and the pickup gate.

import Foundation

@MainActor
enum TradeEngineTests {

    static func runAll() -> [String] {
        var fails: [String] = []
        func check(_ cond: Bool, _ msg: String) { if !cond { fails.append("❌ \(msg)") } }

        // MARK: Min-cost flow — a tiny known instance.
        do {
            var mcf = MinCostFlow(nodes: 4)
            mcf.addEdge(0, 1, cap: 1, cost: 0)
            mcf.addEdge(1, 2, cap: 1, cost: 5)
            mcf.addEdge(2, 3, cap: 1, cost: 0)
            let (f, c) = mcf.run(from: 0, to: 3)
            check(f == 1 && c == 5, "MCF basic: expected flow 1 cost 5, got \(f)/\(c)")

            // Two parallel paths, cheaper first.
            var m2 = MinCostFlow(nodes: 4)
            m2.addEdge(0, 1, cap: 2, cost: 0)
            m2.addEdge(1, 3, cap: 1, cost: 1)   // cheap
            m2.addEdge(1, 3, cap: 1, cost: 10)  // expensive
            let (f2, c2) = m2.run(from: 0, to: 3)
            check(f2 == 2 && c2 == 11, "MCF two-path: expected flow 2 cost 11, got \(f2)/\(c2)")
        }

        // MARK: Optimal reciprocal matcher.
        let A = OptimalMatcher.Cand(id: "001", name: "A", canTake: ["d1", "d2"], givesBack: ["x1", "x2"])
        let B = OptimalMatcher.Cand(id: "002", name: "B", canTake: ["d1"], givesBack: ["y1"])
        let C = OptimalMatcher.Cand(id: "003", name: "C", canTake: ["d2"], givesBack: ["z1"])

        let one = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [A, B, C])
        check(one?.count == 1, "Optimal: 1-person cover preferred over 2, got \(String(describing: one?.count))")
        check(balanced(one), "Optimal: balanced give==take")

        let split = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [B, C])
        check(split?.count == 2, "Optimal: 2-person split when no single covers both")

        let infeasible = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [B])
        check(infeasible == nil, "Optimal: infeasible (d2 uncoverable) → nil")

        let unbalanced = OptimalMatcher.Cand(id: "001", name: "A", canTake: ["d1", "d2"], givesBack: ["x1"])
        let ub = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [unbalanced])
        check(ub == nil, "Optimal: give 2 / back 1 with one peer is unbalanced → nil")

        let r1 = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [B, C, A])
        let r2 = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [A, C, B])
        check(r1?.map(\.id).sorted() == r2?.map(\.id).sorted(), "Optimal: deterministic across peer order")

        // Contiguity gate (the no-split rule shared by the optimal AND greedy paths):
        // a validator that rejects every assignment must yield NO solution — a
        // break-fragmenting package is never emitted.
        let blocked = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [A, B, C],
                                                         contiguous: { _ in false })
        check(blocked == nil, "Contiguity: rejecting validator → nil (never split a break)")
        let allowed = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [A, B, C],
                                                         contiguous: { _ in true })
        check(allowed?.count == 1, "Contiguity: permissive validator still returns the 1-person cover")

        // MARK: Holiday math (2026).
        let h = Holidays.map(year: 2026)
        check(h["2026-01-01"] == "New Year's Day", "Holiday: New Year 2026")
        check(h["2026-01-19"] == "Martin Luther King Day", "Holiday: MLK 2026 = 3rd Mon Jan (Jan 19)")
        check(h["2026-02-16"] == "Presidents Day", "Holiday: Presidents 2026 = 3rd Mon Feb")
        check(h["2026-04-03"] == "Good Friday", "Holiday: Good Friday 2026 (Easter Apr 5)")
        check(h["2026-05-25"] == "Memorial Day", "Holiday: Memorial 2026 = last Mon May")
        check(h["2026-09-07"] == "Labor Day", "Holiday: Labor 2026 = 1st Mon Sep")
        check(h["2026-11-26"] == "Thanksgiving Day", "Holiday: Thanksgiving 2026 = 4th Thu Nov")
        check(h["2026-11-27"] == "Day after Thanksgiving", "Holiday: Day-after 2026")
        check(h["2026-12-25"] == "Christmas Day", "Holiday: Christmas 2026")

        // MARK: Pickup gate (wouldPickUp) — bookends + mercenary.
        var prof = TradeProfile(workerID: "001", displayName: "A", openness: "bookends",
                                blacklistedWeekdays: [], blacklistedDesks: [],
                                blacklistedShiftTypes: [], blacklistedRegions: [],
                                seekingDayIDs: [], updatedAt: Date.distantPast)
        check(prof.wouldPickUp(onDay: "2026-07-04", weekday: 7, desk: "29", shiftType: "AM", region: "Domestic", isBookend: false) == false,
              "wouldPickUp: bookends rejects non-bookend")
        check(prof.wouldPickUp(onDay: "2026-07-04", weekday: 7, desk: "29", shiftType: "AM", region: "Domestic", isBookend: true) == true,
              "wouldPickUp: bookends accepts bookend")
        prof.isMercenaryMode = true
        check(prof.wouldPickUp(onDay: "x", weekday: 1, desk: "29", shiftType: "AM", region: "Domestic", isBookend: false) == true,
              "wouldPickUp: mercenary takes any qualifying shift")
        prof.isMercenaryMode = false

        // Blacklist always blocks (even mercenary off).
        var bl = prof
        bl.isMercenaryMode = true
        let blProf = TradeProfile(workerID: "001", displayName: "A", openness: "all",
                                  blacklistedWeekdays: [], blacklistedDesks: ["29"],
                                  blacklistedShiftTypes: [], blacklistedRegions: [],
                                  seekingDayIDs: [], updatedAt: Date.distantPast)
        check(blProf.wouldPickUp(onDay: "x", weekday: 1, desk: "29", shiftType: "AM", region: "Domestic", isBookend: true) == false,
              "wouldPickUp: blacklisted desk blocked")

        return fails
    }

    private static func balanced(_ a: [OptimalMatcher.Assignment]?) -> Bool {
        guard let a else { return false }
        return a.allSatisfy { $0.giveDayIDs.count == $0.takeDayIDs.count }
    }
}
