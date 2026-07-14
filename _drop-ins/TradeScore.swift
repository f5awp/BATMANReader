// TradeScore.swift — DROP-IN REGION for TradeEngineModels.swift
// Replaces `enum TradeScore { … }` verbatim (LegFeatures and PersonPrior above it
// are UNCHANGED). Everything here is pure + nonisolated-by-construction (an enum of
// static funcs over value types) — harness-testable with no stores.
//
// U-OBJ: ONE objective, used consistently by construction (flow edge costs, DFS
// ordering/pruning), curation (floor), and ranking (rankLess). Three factors:
//
//   Q  = meanLegQuality  — geometric mean of per-leg σ(logit). Size- and people-
//        neutral, in (0,1]. THE floor signal (0.32/0.07 keep their single-leg
//        meaning) and the displayed "match strength" basis.
//   π  = peoplePenalty   — INTENT-AWARE: nPenalty^((N−2)·nonMutualFraction) ·
//        peopleEdge^(N−2). All-mutual ⇒ only the tiny peopleEdge applies, so a
//        unanimous 4-way ranks ~as high as a 2-way (and the 2-way still edges it);
//        every non-mutual leg raises the fraction, so growth-by-coercion falls
//        below a clean smaller trade. (Owner requirement; replaces flat 0.85^(N−2).)
//   κ  = coverage        — (urgency-weighted covered fraction)^coverageWeight.
//        Trade Solutions only; the Intents marketplace has no selected-days target
//        and passes 1.
//
//   rankScore = Q · π · κ    (packageScore below)

enum TradeScore {
    // Weights = the DESIGNED match priorities. WANTS dominate (want-to-take + want-to-trade, 1.5
    // each → dual = 3.0). Bookend is a flat +0.8. The SPLIT penalty SHRINKS as intent grows
    // (`splitBase − splitRelief·intentLevel` → none 2.5, single 1.4, dual 0.3) so a split barely dents
    // a dual trade but wrecks a no-intent one. `qual` friction −1.2; `personPrior` tiny (0.2).
    static let wWant = 1.5, wBook = 0.8, wTime = 0.8, wQual = 1.2, wEcb = 1.5, wPerson = 0.2
    static let splitBase = 2.5, splitRelief = 1.1

    /// Per-extra-person multiplier, applied only to the NON-MUTUAL fraction of the package
    /// (U-N2). An all-mutual trade of any size pays none of this.
    static let nPenalty = 0.85
    /// Tiny unconditional per-extra-person edge, so between two otherwise-equal all-mutual
    /// trades the SMALLER one still sorts first (2-way edges a unanimous 4-way by ~1%).
    static let peopleEdge = 0.995
    /// Coverage exponent (Trade Solutions): rankScore ×= coverageFrac^coverageWeight. At 2.0,
    /// an excellent half-cover (Q≈0.99 → 0.25) sorts under even a fair full cover (Q≈0.77) —
    /// coverage stays a top concern without being an absolute tier.
    static let coverageWeight = 2.0

    static func legLogit(_ f: LegFeatures) -> Double {
        let want = wWant * Double(f.intentLevel)
        let splitPen = splitBase - splitRelief * Double(f.intentLevel)   // intent shrinks the split hit
        let structural = f.bookend ? wBook : -splitPen
        return want + structural
             + wTime * f.timeValue
             - wQual * (f.needsQualBridge ? 1 : 0)
             + wEcb * f.ecbValue
             + wPerson * f.personPrior
    }
    /// Probability-shaped acceptance signal for one leg, in (0,1). Presented to users only as
    /// RELATIVE match strength (weights are hand-tuned, not fit) — see `matchStrength`.
    static func legProb(_ f: LegFeatures) -> Double { 1.0 / (1.0 + exp(-legLogit(f))) }

    /// Q — geometric mean of per-leg quality, in (0,1]. Size/people-neutral by design: this is
    /// the FLOOR + DISPLAY signal, so a clean full-cover reads like a clean single-day and the
    /// floor constants keep their single-leg calibration. Empty → 0.
    static func meanLegQuality(_ legs: [LegFeatures]) -> Double {
        guard !legs.isEmpty else { return 0 }
        return exp(legs.map { log(legProb($0)) }.reduce(0.0, +) / Double(legs.count))
    }

    /// Mutual legs = both sides marked the day (giver trade-away AND receiver want-to-work).
    static func mutualLegCount(_ legs: [LegFeatures]) -> Int {
        legs.filter { $0.intentLevel == 2 }.count
    }

    /// π — the intent-aware people penalty. `people` counts every participant including you and
    /// EXCLUDES a qual-swap bridge (an enabling leg, invariant). Monotone: non-increasing in
    /// `people`, non-increasing as mutual legs are lost.
    static func peoplePenalty(people: Int, mutualLegs: Int, legCount: Int) -> Double {
        guard legCount > 0 else { return 1 }
        let extra = Double(max(0, people - 2))
        guard extra > 0 else { return 1 }
        let f = Double(legCount - min(max(0, mutualLegs), legCount)) / Double(legCount)
        return exp(extra * (f * log(nPenalty) + log(peopleEdge)))
    }

    /// THE ranking objective (both feeds): rankScore = Q · π · κ. `coverageFrac` is the
    /// urgency-weighted share of the user's SELECTED give-days this package covers — pass 1
    /// for the Intents marketplace (no selected-days target there).
    static func packageScore(_ legs: [LegFeatures], people: Int, coverageFrac: Double = 1) -> Double {
        guard !legs.isEmpty else { return 0 }
        let q = meanLegQuality(legs)
        let pi = peoplePenalty(people: people, mutualLegs: mutualLegCount(legs), legCount: legs.count)
        let kappa = pow(min(1, max(0, coverageFrac)), coverageWeight)
        return q * pi * kappa
    }

    /// Joint probability the whole package executes (all parties accept) = ∏ legProb, with the
    /// intent-aware people penalty folded in (legs ≈ participants for a loop).
    static func packageProb(_ legs: [LegFeatures]) -> Double { exp(packageLogProb(legs)) }
    /// log of the joint probability + intent-aware penalty. NOTE (U-N2): an all-mutual loop now
    /// pays only the tiny peopleEdge — a unanimous 3-way SORTS ABOVE a 2-person split, which is
    /// the owner's intended flip of the old flat-penalty property.
    static func packageLogProb(_ legs: [LegFeatures]) -> Double {
        let joint = legs.map { log(legProb($0)) }.reduce(0.0, +)
        let pi = peoplePenalty(people: legs.count, mutualLegs: mutualLegCount(legs), legCount: legs.count)
        return joint + log(pi)
    }

    /// COMPAT (existing tests + any UI reading `acceptanceScore` semantics): per-leg quality ×
    /// the intent-aware people penalty. Under U-N2 an ALL-MUTUAL package is ~people-invariant
    /// (only peopleEdge, −0.5%/person); a package with non-mutual legs still drops with people.
    static func packageQuality(_ legs: [LegFeatures], people: Int) -> Double {
        meanLegQuality(legs) * peoplePenalty(people: people,
                                             mutualLegs: mutualLegCount(legs), legCount: legs.count)
    }

    /// ADMISSIBLE DFS pruning bound: the highest FINAL mean-log-quality any completion of a
    /// partial route can reach. Each remaining leg contributes log p ≤ 0 and the final leg count
    /// is at most `maxLegs`, so partialSum/maxLegs (partialSum ≤ 0) over-estimates every
    /// completion. The floor gates Q (pre-penalty) — the penalty is deliberately ABSENT here:
    /// with the intent-aware π, adding mutual legs can SHRINK the penalty, so folding π into the
    /// bound would not be admissible. Prune when this < log(floor) — never drops a valid route.
    static func upperBoundMeanLog(partialLegLogSum: Double, maxLegs: Int) -> Double {
        guard maxLegs > 0 else { return 0 }
        return min(0, partialLegLogSum) / Double(maxLegs)
    }

    /// G3: desirability (log-joint-acceptance) of a circular route from its per-leg bookend/🔥
    /// flags. A non-bookend leg is a SPLIT, and a 🔥 leg is treated as DUAL intent (both want it).
    /// Empty route → 0 (log 1).
    static func routeDesirability(legBookends: [Bool], legFires: [Bool]) -> Double {
        let feats = zip(legBookends, legFires).map { b, f in
            LegFeatures(wantToTake: f, wantToTrade: f, bookend: b, timeValue: 0.5, needsQualBridge: false)
        }
        return packageLogProb(feats)
    }

    // MARK: - Displayed number (calibration decision: RELATIVE strength, not a probability)

    /// The surfaced number: a 0–100 RELATIVE match strength from the per-leg quality Q.
    /// Deliberately NOT labeled a probability — weights are hand-tuned and per-partner history
    /// is thin. When enough accept/decline rows exist, a logistic re-fit can upgrade this in
    /// place without touching the ranking machinery.
    static func matchStrength(_ meanLegQuality: Double) -> Int {
        Int((min(1, max(0, meanLegQuality)) * 100).rounded())
    }
    /// Card tier label. Thresholds align with the floor: below `floorNormalProb` only surfaces
    /// via Lucky / the empty-feed fallback → "Long shot".
    static func strengthTier(_ meanLegQuality: Double) -> String {
        if meanLegQuality >= 0.80 { return "Excellent" }
        if meanLegQuality >= 0.55 { return "Good" }
        if meanLegQuality >= 0.32 { return "Fair" }
        return "Long shot"
    }
}
