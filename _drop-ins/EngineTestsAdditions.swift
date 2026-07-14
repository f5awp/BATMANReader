// EngineTestsAdditions.swift — changes + new blocks for EngineTests.swift
// (`TradeEngineTests`, Appendix G). Verified against the REAL harness source.
//
// WIRING: the new blocks below are static funcs on the same enum; append inside
// runAll() just before `return fails`:
//
//     fails += runNPenaltyTests() + runObjectiveTests() + runRankerTests()
//            + runFinalizeTests() + runPruningBoundTests() + runOptimalMatcherTests()
//
// ═════════════════════════════════════════════════════════════════════════════
// PART 1 — EXISTING ASSERTIONS, by exact message string
// ═════════════════════════════════════════════════════════════════════════════
//
// ── FLIPS BY DESIGN (rewrite, don't delete) ─────────────────────────────────
//
// ① "H1/N-penalty: all-dual+book(3) < all-dual+split(2)"
//    INVERTS — this is the owner's N-penalty requirement itself. An all-mutual
//    3-way pays only peopleEdge (ln≈−0.005), so it now OUTRANKS the 2-person
//    split (−0.0715 vs −0.1301 in log space). Replace with:
//
//        check(TradeScore.packageLogProb(Array(repeating: dualBook, count: 3))
//              > TradeScore.packageLogProb(Array(repeating: dualSplit, count: 2)),
//              "U-N2: a unanimous 3-way now outranks a 2-person split (intent-aware penalty)")
//
// ② "packageQuality: more PEOPLE lowers quality"
//    STILL PASSES (peopleEdge keeps it strictly lower) but is now a ~0.5%/person
//    whisper for the fully-mutual cleanLeg it uses — the assertion no longer
//    tests what its name says. Strengthen to pin BOTH halves of the new rule:
//
//        let q4p3 = TradeScore.packageQuality(Array(repeating: cleanLeg, count: 4), people: 3)
//        check(q4p3 < q2legs, "packageQuality: more people still strictly lowers (peopleEdge)")
//        check(q4p3 / q2legs > 0.99, "packageQuality: an ALL-MUTUAL package is ~people-invariant (U-N2)")
//        let noneLeg = LegFeatures(wantToTake: false, wantToTrade: false, bookend: true,
//                                  timeValue: 1, needsQualBridge: false)
//        check(TradeScore.packageQuality(Array(repeating: noneLeg, count: 4), people: 3)
//              < 0.9 * TradeScore.packageQuality(Array(repeating: noneLeg, count: 2), people: 2),
//              "packageQuality: NON-mutual legs still pay the real people penalty")
//
// ③ "#3: a two-person trade outranks a three-person loop even when the loop has more 🔥"
//    RETIRED BY DESIGN — it contradicts the owner's newer rule (an all-mutual loop
//    must rank nearly as high as a 2-way, i.e. ABOVE weaker 2-ways), and it tested
//    the deleted rankPackages. Ported outcome (runNPenaltyTests ❻ below): an
//    all-mutual loop beats a no-intent 2-way; an equal-quality 2-way still edges
//    the loop. ⚠️ If "pairwise always first" must survive as an absolute, this is
//    a design conflict to resolve with the owner — do not silently keep both.
//
// ── PASS TODAY, BUT BY ACCIDENT (rewrite so they test the mechanism) ────────
//    These construct packages with rankScore defaulted to 0, so under the new
//    score-first rankLess they tie and resolve by id — which happens to match
//    the expected order. Rewrite each to set rankScore from real leg features.
//
// ④ "U-RECV: an all-clean package ranks above a dirtier one even with less coverage"
//    The ABSOLUTE guarantee is retired (owner: pure score). The mechanism is now
//    the split penalty inside the score. Replace with runObjectiveTests ❺ below:
//    at EQUAL coverage a dirty-receive package sorts far below a clean one
//    (Q 0.33 vs 0.99); a stellar dirty FULL cover may legitimately beat a clean
//    HALF cover — that's the accepted trade-off, now asserted explicitly.
//
// ⑤ "finalize: coverage-first — a 3-day full-cover beats a higher-scored 1-day"
//    Coverage moved from a hard sort key into rankScore (κ = coverageFrac²).
//    Rewrite by scoring both sides:
//        fullCover.rankScore = 0.80 * pow(1.0, 2)      // = 0.80
//        oneDay.rankScore    = 0.95 * pow(1.0/3, 2)    // ≈ 0.106
//        check(TradeRouter.finalize([oneDay, fullCover], lucky: false).first?.id == "full",
//              "U-OBJ: coverage-weighted score — the 3-day full-cover still beats the 1-day")
//
// ⑥ "finalize: empty-feed fallback shows the top few by quality when nothing clears the floor"
//    Passes by id-tie accident; set w1.rankScore = 0.01, w2.rankScore = 0.005 so
//    the expected ["w1","w2"] order is produced by the ranker, not the id tail.
//
// ── DELETED WITH THE DEAD RANKERS (port the live property, drop the rest) ───
//    rankPackages is deleted → these no longer compile:
//      "A5: single-person full-cover sorts to the very top"
//      "A5: fewest people first (solo=2, others=3)"
//      "A5: greedy before circular at equal people"
//      "U4: 🔥+bookends first, then 🔥-only"
//      "U4: bookends-only top two bands (3 and 2) are kept"
//      "U4: bookends-only below max-1 (band 1) is filtered out"
//      "U4: fewest-people (N) grouping dominates the tier priority"
//      "#4b: earlier-dated trade sorts first (beats alphabetical id)"   → PORT (see ⑦)
//      "Q1: a qual-swap package survives the bookends-only cap (exempt)" → superseded by
//            the floor-exemption test (runFinalizeTests); the band cap no longer exists
//      "D5: clean 2-way sorts above a qual-swap 2-way even with more 🔥"      → retired absolute;
//      "D5: within the qual group, more 🔥 sorts first (usual priorities)"     the qual drag now
//      "D5: people-count dominates — a qual 2-way precedes a clean 3-way"      lives IN the score
//            (runObjectiveTests asserts bridged < clean at equal structure)
//    rankIntentPackages is deleted → these no longer compile:
//      "Intents: MOST mutual intent ranks first, even with more people (…)"   → emerges from the
//            score (runNPenaltyTests ❻); delete the lexicographic version
//      "H2: all else equal, the likelier-to-accept partner ranks first"       → PORT (see ⑧)
//      "Intents: safety ceiling caps the list at 60"                          → covered by the
//            finalize ceiling test (runFinalizeTests); "Intents: safety ceiling is 60" KEEPS
//
// ⑦ PORT of "#4b" to the live ranker (date tiebreak survives in rankLess):
//        // earlyPkg (id "zzz", Jul days) vs latePkg (id "aaa", Dec days), both rankScore 0:
//        check([latePkg, earlyPkg].sorted(by: TradeRouter.rankLess).first?.id == "zzz",
//              "#4b: equal score → the earlier-dated trade sorts first (beats alphabetical id)")
//
// ⑧ PORT of the H2 tiebreak — the prior now works INSIDE the score, not as a key:
//        var fHi2 = LegFeatures(wantToTake: true, wantToTrade: true, bookend: true,
//                               timeValue: 0.5, needsQualBridge: false)
//        var fLo2 = fHi2; fHi2.personPrior = 1.5; fLo2.personPrior = -1.5
//        var pHi = pkg("high", people: 2, fire: 2); pHi.rankScore = TradeScore.packageScore([fHi2, fHi2], people: 2)
//        var pLo = pkg("low",  people: 2, fire: 2); pLo.rankScore = TradeScore.packageScore([fLo2, fLo2], people: 2)
//        check([pLo, pHi].sorted(by: TradeRouter.rankLess).first?.id == "high",
//              "H2: the partner prior lifts rankScore — likelier-to-accept partners rank first")
//
// ── UNCHANGED AND MUST STAY GREEN (spot-verified against the new code) ──────
//    • Both MCF blocks ("MCF basic…", "MCF two-path…") — the forward tag doesn't touch run().
//    • All OptimalMatcher goldens: "Optimal: 1-person cover preferred over 2",
//      "Optimal: balanced give==take", "Optimal: 2-person split when no single covers both",
//      "Optimal: infeasible (d2 uncoverable) → nil", "Optimal: give 2 / back 1 with one peer
//      is unbalanced → nil" (flow conservation reproduces it), "Optimal: deterministic across
//      peer order" (usable is id-sorted; min-cost ties keep the first, combination order is
//      id-deterministic), both Contiguity checks.
//    • "finalize: normal floor (0.32) keeps only ≥0.32 avg-quality" and
//      "finalize: Lucky floor (0.07) admits more" — acceptanceScore stays a 0…1 per-leg quality.
//    • "packageQuality: more days (legs) with one person → same quality".
//    • The whole H1 leg-ordering block ("H1: dual want > single want" … "H1: more ECB offered →
//      higher acceptance"), including "H1: partial-route log-prob is an admissible upper bound" —
//      the intent-aware π is still monotone non-increasing in leg count (adding a leg grows
//      (N−2) faster than f can shrink the exponent; verified algebraically and numerically).
//    • All three G3 routeDesirability checks (2-leg fires case: π is 1 on both sides; the
//      split case compares equal-π 3-leg routes).
//    • All A1 seedScore/bestFirstSeeds checks — the added `wantsGive:` parameter defaults to
//      true, which is exactly the old hard-coded behavior.
//    • Everything else in runAll() (eligibility, qual-swap, ECB, parser, intents assembler,
//      PersonPrior, SearchFilter, cleanReceiveLegs U-RECV filter checks, etc.) — untouched paths.
//
// ═════════════════════════════════════════════════════════════════════════════
// PART 2 — NEW TEST BLOCKS (match runAll()'s check style: "❌ " prefix on failures)
// ═════════════════════════════════════════════════════════════════════════════

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

    // MARK: - Ranker: determinism, floating-point ties, strict weak ordering

    static func runRankerTests() -> [String] {
        var fails: [String] = []
        func check(_ cond: Bool, _ msg: String) { if !cond { fails.append("❌ \(msg)") } }

        func pkg(_ id: String, rank: Double, fire: Int = 0, day: String? = "2026-08-01") -> TradePackage {
            var p = TradePackage(id: id, methodology: .greedy,
                                 assignments: [PackageAssignment(workerID: "w-\(id)", name: id,
                                                                 giveDayIDs: day.map { [$0] } ?? [],
                                                                 takeDayIDs: [])],
                                 route: nil)
            p.rankScore = rank; p.fireCount = fire
            return p
        }

        let a = pkg("a", rank: 0.9), b = pkg("b", rank: 0.8)
        check(TradeRouter.rankLess(a, b) && !TradeRouter.rankLess(b, a),
              "RANK: higher rankScore must sort first (and the comparator must be asymmetric)")
        let t1 = pkg("t1", rank: 0.7, fire: 2), t2 = pkg("t2", rank: 0.7, fire: 1)
        check(TradeRouter.rankLess(t1, t2), "RANK: exact score tie must fall to more mutual (fireCount)")
        let u1 = pkg("u1", rank: 0.7), u2 = pkg("u2", rank: 0.7)
        check(TradeRouter.rankLess(u1, u2) && !TradeRouter.rankLess(u2, u1),
              "RANK: full tie must resolve by id, exactly one direction")
        check(!TradeRouter.rankLess(u1, u1), "RANK: comparator must be irreflexive (strict weak ordering)")
        // Exact-Double cascade: near-ties stay transitive (an epsilon comparator wouldn't).
        let n1 = pkg("n1", rank: 0.700000000000001)
        let n2 = pkg("n2", rank: 0.7000000000000005)
        let n3 = pkg("n3", rank: 0.7)
        if TradeRouter.rankLess(n1, n2) && TradeRouter.rankLess(n2, n3) {
            check(TradeRouter.rankLess(n1, n3), "RANK: comparator must be transitive across near-ties")
        }
        // ⑦ port — date tiebreak survives (was "#4b" under rankPackages).
        let early = pkg("zzz", rank: 0.5, day: "2026-07-01")
        let late  = pkg("aaa", rank: 0.5, day: "2026-12-01")
        check([late, early].sorted(by: TradeRouter.rankLess).first?.id == "zzz",
              "#4b: equal score → the earlier-dated trade sorts first (beats alphabetical id)")
        return fails
    }

    // MARK: - finalize: empty feed, fallback, qual-swap exemption, ceiling

    static func runFinalizeTests() -> [String] {
        var fails: [String] = []
        func check(_ cond: Bool, _ msg: String) { if !cond { fails.append("❌ \(msg)") } }

        func pkg(_ id: String, q: Double, rank: Double, qualSwap: Bool = false) -> TradePackage {
            var p = TradePackage(id: id, methodology: .greedy,
                                 assignments: [PackageAssignment(workerID: "w-\(id)", name: id,
                                                                 giveDayIDs: ["2026-08-01"], takeDayIDs: [])],
                                 route: nil,
                                 qualSwap: qualSwap ? QualSwapLegData(giveShiftDayID: "2026-08-01",
                                                                      giveDesk: "50", giveQual: "E",
                                                                      takerID: "t", takerName: "t",
                                                                      candidates: []) : nil)
            p.acceptanceScore = q; p.rankScore = rank
            return p
        }

        check(TradeRouter.finalize([], lucky: false).isEmpty, "FIN: empty in must be empty out")

        // Nothing clears the floor → fallback shows the top few BY RANK, never zero. (⑥ rewrite.)
        let weak = (0..<8).map { pkg("w\($0)", q: 0.10 + Double($0) * 0.01, rank: 0.10 + Double($0) * 0.01) }
        let fb = TradeRouter.finalize(weak, lucky: false)
        check(!fb.isEmpty && fb.count <= TradeRouter.emptyFallbackCount,
              "FIN: below-floor set must fall back to at most emptyFallbackCount, not empty")
        check(fb.first?.id == "w7", "FIN: the fallback must surface the BEST below-floor package first (by rankScore)")

        // Qual-swap packages are floor-EXEMPT (D6) and must still surface, sorted by their score.
        let mixed = [pkg("clean", q: 0.9, rank: 0.9), pkg("qs", q: 0.05, rank: 0.05, qualSwap: true)]
        let out = TradeRouter.finalize(mixed, lucky: false)
        check(out.contains { $0.id == "qs" }, "FIN: a below-floor qual-swap package must stay floor-exempt")
        check(out.first?.id == "clean", "FIN: the exempt qual-swap still sorts by its (low) score")

        // Safety ceiling holds (absorbs the deleted rankIntentPackages ceiling test).
        let flood = (0..<80).map { pkg("f\($0)", q: 0.9, rank: 0.9) }
        check(TradeRouter.finalize(flood, lucky: false).count <= TradeRouter.intentResultCap,
              "FIN: the safety ceiling (intentResultCap) must cap the feed")

        // ⑤ rewrite — coverage now works through rankScore, same intended outcome.
        var fullCover = pkg("full", q: 0.80, rank: 0.80)                 // κ = 1²
        var oneDay    = pkg("one",  q: 0.95, rank: 0.95 * pow(1.0 / 3, 2))  // κ = (1/3)²
        fullCover.coverageFrac = 1; oneDay.coverageFrac = 1.0 / 3
        check(TradeRouter.finalize([oneDay, fullCover], lucky: false).first?.id == "full",
              "U-OBJ: coverage-weighted score — the 3-day full-cover still beats the 1-day")
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

    // MARK: - OptimalMatcher: costed flow, balance-as-conservation, k*+1 alternate

    static func runOptimalMatcherTests() -> [String] {
        var fails: [String] = []
        func check(_ cond: Bool, _ msg: String) { if !cond { fails.append("❌ \(msg)") } }
        typealias Cand = OptimalMatcher.Cand

        // ❶ Acceptance-optimal WITHIN k: two single-day peers, one much likelier — the flow
        //    must route the day to the cheap (likely) one, not the first-feasible/first-listed.
        let cheap = Cand(id: "a-cheap", name: "A", canTake: ["d1"], givesBack: ["b1"],
                         takeCost: ["d1": 10], backCost: ["b1": 10])
        let dear  = Cand(id: "b-dear", name: "B", canTake: ["d1"], givesBack: ["b2"],
                         takeCost: ["d1": 900], backCost: ["b2": 900])
        let best = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1"], peers: [dear, cheap])
        check(best?.first?.id == "a-cheap",
              "OPT: the flow must pick the max-acceptance peer, not the first feasible")

        // ❷ Give-back readback is model-chosen, not prefix order: one peer, two possible
        //    give-backs, the SECOND-listed one far cheaper → the assignment must take it.
        let backy = Cand(id: "p", name: "P", canTake: ["d1"], givesBack: ["bBad", "bGood"],
                         takeCost: ["d1": 10], backCost: ["bBad": 900, "bGood": 10])
        let picked = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1"], peers: [backy])
        check(picked?.first?.takeDayIDs == ["bGood"],
              "OPT: the return leg must be the max-acceptance give-back, not arbitrary prefix")

        // ❸ Global back-day uniqueness: two peers offering the SAME calendar back-day can't
        //    both hand it to me — 2 gives needing 2 returns on one date is infeasible.
        let q1 = Cand(id: "q1", name: "Q1", canTake: ["d1"], givesBack: ["same"])
        let q2 = Cand(id: "q2", name: "Q2", canTake: ["d2"], givesBack: ["same"])
        check(OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [q1, q2]) == nil,
              "OPT: one received shift per calendar date — a shared back-day must be infeasible")

        // ❹ The k*+1 alternate rides along when feasible; k* stays first (isOptimal).
        let r1 = Cand(id: "r1", name: "R1", canTake: ["d1", "d2"], givesBack: ["b1", "b2"],
                      takeCost: ["d1": 500, "d2": 500])
        let r2 = Cand(id: "r2", name: "R2", canTake: ["d1"], givesBack: ["b3"], takeCost: ["d1": 5])
        let r3 = Cand(id: "r3", name: "R3", canTake: ["d2"], givesBack: ["b4"], takeCost: ["d2": 5])
        let opts = OptimalMatcher.reciprocalOptions(giveDayIDs: ["d1", "d2"], peers: [r1, r2, r3])
        check(opts.count == 2, "OPT: a feasible k*+1 alternative must be offered alongside k*")
        check(opts.first?.count == 1 && (opts.last?.count ?? 0) == 2,
              "OPT: option order must be fewest-people first, alternate second")

        // ❺ Cost-less Cands reproduce the legacy behavior exactly (the Appendix-G goldens
        //    "Optimal: …" already assert this; here we pin that defaults mean cost 0).
        let plain = Cand(id: "z", name: "Z", canTake: ["d1"], givesBack: ["b9"])
        check(plain.takeCost.isEmpty && plain.backCost.isEmpty,
              "OPT: default Cand carries no costs (legacy zero-cost behavior preserved)")
        return fails
    }
}

#endif
