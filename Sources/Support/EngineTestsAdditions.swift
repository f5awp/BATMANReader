// EngineTestsAdditions.swift — new adversarial blocks for the U-OBJ redesign.
// Static funcs on TradeEngineTests; wired into runAll() before `return fails`.
// (Blocks are added stage-by-stage as their symbols come online.)

import Foundation

#if DEBUG

extension TradeEngineTests {

    // Shared fixture legs (timeValue 0.5 ≈ "soon-ish", no qual friction, no prior).
    private static func fleg(_ take: Bool, _ trade: Bool, bookend: Bool, qual: Bool = false) -> LegFeatures {
        LegFeatures(wantToTake: take, wantToTrade: trade, bookend: bookend,
                    timeValue: 0.5, needsQualBridge: qual)
    }
    private static var mutualBook:   LegFeatures { fleg(true, true,  bookend: true) }
    private static var mutualSplit:  LegFeatures { fleg(true, true,  bookend: false) }
    private static var oneSidedBook: LegFeatures { fleg(true, false, bookend: true) }
    private static var noneBook:     LegFeatures { fleg(false, false, bookend: true) }
    private static var noneSplit:    LegFeatures { fleg(false, false, bookend: false) }

    // MARK: - U-N2: the intent-aware people penalty (the owner's N-penalty requirement)

    static func runNPenaltyTests() -> [String] {
        var fails: [String] = []
        func check(_ cond: Bool, _ msg: String) { if !cond { fails.append("❌ \(msg)") } }

        // ❶ All-mutual growth: a unanimous 4-way ranks ALMOST as high as a 2-way…
        let s2 = TradeScore.packageScore(Array(repeating: mutualBook, count: 2), people: 2)
        let s3 = TradeScore.packageScore(Array(repeating: mutualBook, count: 3), people: 3)
        let s4 = TradeScore.packageScore(Array(repeating: mutualBook, count: 4), people: 4)
        check(s4 / s2 > 0.97, "U-N2: all-mutual 4-way must score within 3% of the all-mutual 2-way")
        // …but the SMALLER all-mutual trade still edges it (peopleEdge, strict order).
        check(s2 > s3 && s3 > s4, "U-N2: among all-mutual trades, fewer people must still edge ahead")

        // ❷ One non-mutual leg at N=4 falls below a clean 3-way — even when that leg is
        //    a bookend (best case for the dirty 4-way)…
        let dirty4 = TradeScore.packageScore([mutualBook, mutualBook, mutualBook, oneSidedBook], people: 4)
        check(dirty4 < s3, "U-N2: a 4-way with only 3 mutual legs must sort under a clean 3-way")
        // …and even below a WEAK clean 3-way (all-mutual but every leg a split).
        let weak3 = TradeScore.packageScore(Array(repeating: mutualSplit, count: 3), people: 3)
        check(dirty4 < weak3, "U-N2: a 4-way with a non-mutual leg must sort under an all-split clean 3-way")

        // ❸ Monotone decline as non-mutual legs grow (fixed structure: all bookends).
        var prev = Double.infinity
        for m in stride(from: 4, through: 0, by: -1) {
            let legs = Array(repeating: mutualBook, count: m)
                     + Array(repeating: oneSidedBook, count: 4 - m)
            let s = TradeScore.packageScore(legs, people: 4)
            check(s < prev, "U-N2: score must fall strictly as mutual legs drop (mutual=\(m))")
            prev = s
        }

        // ❹ The penalty is per PERSON, not per leg: a 2-person multi-day cover pays nothing.
        let multiDay = Array(repeating: mutualBook, count: 4)
        check(TradeScore.packageScore(multiDay, people: 2) == TradeScore.meanLegQuality(multiDay),
              "U-N2: two-person multi-day trades carry NO people penalty")

        // ❺ peoplePenalty edge cases: empty legs → 1; N ≤ 2 → 1; all-mutual → peopleEdge only.
        check(TradeScore.peoplePenalty(people: 4, mutualLegs: 0, legCount: 0) == 1,
              "U-N2: zero-leg penalty must be neutral (guard, no NaN)")
        check(TradeScore.peoplePenalty(people: 2, mutualLegs: 0, legCount: 2) == 1,
              "U-N2: N=2 must never be penalized regardless of intent")
        check(abs(TradeScore.peoplePenalty(people: 4, mutualLegs: 4, legCount: 4)
                  - TradeScore.peopleEdge * TradeScore.peopleEdge) < 1e-12,
              "U-N2: all-mutual penalty must be exactly peopleEdge^(N−2)")

        // ❻ The ported "#3" outcome under the new rule: an all-mutual 3-loop OUTRANKS a
        //    no-intent 2-way (the old absolute inverts by design), while an equal-quality
        //    2-way still edges the loop.
        let loop3 = TradeScore.packageScore(Array(repeating: mutualBook, count: 3), people: 3)
        let weakTwo = TradeScore.packageScore(Array(repeating: noneBook, count: 2), people: 2)
        check(loop3 > weakTwo, "U-N2: an all-mutual 3-loop now outranks a no-intent 2-way (supersedes old #3)")
        check(s2 > loop3, "U-N2: an equally-clean 2-way still edges the all-mutual loop")
        return fails
    }

    // MARK: - U-OBJ: unified score, coverage term, floor semantics, dirty receives

    static func runObjectiveTests() -> [String] {
        var fails: [String] = []
        func check(_ cond: Bool, _ msg: String) { if !cond { fails.append("❌ \(msg)") } }

        // ❶ Coverage is a strong weight, not a tier: an EXCELLENT half-cover sorts under a
        //    merely FAIR full cover…
        let excellentHalf = TradeScore.packageScore([mutualBook, mutualBook], people: 2, coverageFrac: 0.5)
        let fairFull      = TradeScore.packageScore([noneBook, noneBook],     people: 2, coverageFrac: 1.0)
        check(excellentHalf < fairFull, "U-OBJ: an excellent half-cover must sort under a fair full cover")
        // ❷ …but coverage can no longer bury quality absolutely: a JUNK full cover (no-intent
        //    splits, Q≈0.11 — below the floor anyway) loses to the excellent half-cover.
        let junkFull = TradeScore.packageScore([noneSplit, noneSplit], people: 2, coverageFrac: 1.0)
        check(junkFull < excellentHalf, "U-OBJ: coverage must not resurrect junk-quality full covers")

        // ❸ Floor gates Q = meanLegQuality (pre-penalty, pre-coverage): the single-leg anchors
        //    that placed 0.32 still hold.
        check(TradeScore.meanLegQuality([fleg(true, false, bookend: false)]) >= 0.32,
              "U-OBJ: one-sided split leg must still clear the normal floor")
        check(TradeScore.meanLegQuality([noneSplit]) < 0.32,
              "U-OBJ: no-intent split leg must still fall under the normal floor")
        check(TradeScore.meanLegQuality(Array(repeating: mutualBook, count: 6)) >= 0.32,
              "U-OBJ: a clean 6-leg full cover must clear the floor (geometric mean, not product)")

        // ❹ Qual-bridge friction still drags the score (bridge NOT counted in people — invariant).
        let bridged = TradeScore.packageScore([fleg(true, true, bookend: true, qual: true), mutualBook], people: 2)
        let clean   = TradeScore.packageScore([mutualBook, mutualBook], people: 2)
        check(bridged < clean, "U-OBJ: a qual-bridge leg must score under the same trade without one")

        // ❺ Dirty receives (rewrite of the retired U-RECV absolute): at EQUAL coverage, a
        //    package handing me an unmarked island sorts far below an all-clean one — the split
        //    penalty inside the score is the mechanism now, not a hard tier.
        let cleanFull = TradeScore.packageScore([mutualBook, mutualBook], people: 2, coverageFrac: 1.0)
        let dirtyFull = TradeScore.packageScore([mutualBook, noneSplit], people: 2, coverageFrac: 1.0)
        check(dirtyFull < cleanFull * 0.5,
              "U-OBJ: an unmarked-island receive must roughly halve the score at equal coverage")
        // Owner-approved trade-off, pinned so it can't regress silently: a stellar dirty FULL
        // cover MAY beat a clean HALF cover under the pure score.
        check(dirtyFull > excellentHalf,
              "U-OBJ: pure score — a strong dirty full-cover may outrank a clean half-cover (accepted)")
        return fails
    }

    // MARK: - DFS pruning bound: admissibility (deterministic seeded sweep)

    static func runPruningBoundTests() -> [String] {
        var fails: [String] = []
        func check(_ cond: Bool, _ msg: String) { if !cond { fails.append("❌ \(msg)") } }

        // Deterministic LCG — Date()/random are banned in pure cores (§4 invariant).
        var state: UInt64 = 0x5DEECE66D
        func nextUnit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 11) % 1_000_000) / 1_000_000.0
        }
        let maxLegs = 4
        for _ in 0..<5000 {
            let total = 1 + Int(nextUnit() * Double(maxLegs - 1))     // 1…4 legs
            let cut = 1 + Int(nextUnit() * Double(total - 1))          // partial length ≤ total
            let probs = (0..<total).map { _ in 0.05 + nextUnit() * 0.945 }
            let partialSum = probs.prefix(cut).map { log($0) }.reduce(0, +)
            let finalMean = probs.map { log($0) }.reduce(0, +) / Double(total)
            let bound = TradeScore.upperBoundMeanLog(partialLegLogSum: partialSum, maxLegs: maxLegs)
            if bound < finalMean - 1e-12 {
                check(false, "PRUNE: bound must dominate every completion (admissibility)")
                break
            }
        }
        // If the bound is already below the Lucky floor, NO completion can clear it —
        // pruning can never drop a route the (wider) Lucky floor would have kept.
        let hopeless = 4.0 * log(0.05)   // four terrible legs
        check(TradeScore.upperBoundMeanLog(partialLegLogSum: hopeless, maxLegs: maxLegs)
                < log(TradeRouter.floorLuckyProb),
              "PRUNE: a hopeless partial must be prunable against the Lucky floor")
        // A promising partial is NEVER prunable (bound ≥ its own final mean by construction).
        let promising = 2.0 * log(0.9)
        check(TradeScore.upperBoundMeanLog(partialLegLogSum: promising, maxLegs: maxLegs)
                >= log(TradeRouter.floorLuckyProb),
              "PRUNE: a promising partial must survive the prune")
        return fails
    }
}

#endif
