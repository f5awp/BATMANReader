# DX Trader — Matching & Ranking Engine: Design Review + Redesign

**Scope:** the complete matching/scoring/ranking subsystem per the brief (§0–§6). Decisions locked with the owner mid-review: (1) **pure blended score, no hard lexicographic tiers**, provided the score genuinely encompasses dirty receives, coverage, and every other factor; (2) **one unified score for both feeds**, with the Mutual/All difference living in construction (Mutual = both-sides-marked deals only; All admits one-sided); (3) the surfaced number is a **relative match strength**, not a probability.

**Companion files:** `MinCostFlow.swift`, `OptimalMatcher.swift` (full drop-ins), `TradeScore.swift` (drop-in region for `TradeEngineModels.swift`), `EngineTestsAdditions.swift` (new harness blocks + rewrites of flipped assertions).

**Outstanding input:** Appendix G (`EngineTests.swift`) was announced but never arrived — the uploaded file is unchanged and contains no test source. The test plan below names the two assertion flips you cited plus every behavior-level flip; once you paste the file I will map them onto exact `check(...)` message strings, per your instruction not to work from paraphrase.

---

## 1. What "best trade" should mean — per feed

The two feeds answer different questions and deserve **one scoring language but different objectives** — the difference is exactly one term.

**Trade Solutions** answers: *"I need these specific days covered — which proposable deals get me there, best first?"* The objective is the **expected usefulness of a proposal**: how much of my selected need it covers, weighted by how likely everyone involved is to say yes, discounted for organizational drag (extra people who have no stake in the deal).

**Intents (Mutual / All)** answers: *"Where do people's wishes already overlap?"* There is no selected-days target, so coverage is meaningless there. The objective is pure **deal quality**: how strongly the legs are wanted, how clean they are for every receiver, how soon, how few uninvested people.

So: identical per-leg model, identical people penalty, identical ranker and floor. Trade Solutions multiplies in one extra factor (coverage); Intents passes 1. Mutual vs All differ **only in construction** (the existing `mutualOnly` guard and robot gate) — ranking cannot resurrect what construction excluded, because it only reorders what construction built.

### The objective, in math

Per leg ℓ, unchanged from today's hand-tuned model:

```
p_ℓ = σ( 1.5·intent_ℓ + [bookend_ℓ ? +0.8 : −(2.5 − 1.1·intent_ℓ)]
        + 0.8·time_ℓ − 1.2·qualBridge_ℓ + 1.5·ecb_ℓ + 0.2·prior_ℓ )
```

For a package with legs L, participants N (bridge **excluded**, §4 invariant), mutual legs M = |{ℓ : intent_ℓ = 2}|, and non-mutual fraction **f = (|L| − M) / |L|**:

```
Q  = ( ∏_ℓ p_ℓ )^(1/|L|)                       per-leg quality (geometric mean), ∈ (0,1]
π  = 0.85^((N−2)·f) · 0.995^(N−2)              intent-aware people penalty
κ  = ( Σ_{d∈covered}(1+u_d) / Σ_{d∈selected}(1+u_d) )^2    urgency-weighted coverage
                                                (Trade Solutions; κ ≡ 1 for Intents)

rankScore = Q · π · κ
```

**Role separation, deliberately:**

- **Q** is the *floor* signal and the *displayed* number. It is size- and people-neutral, so the existing floor constants (0.32 normal / 0.07 Lucky) keep their calibrated single-leg meaning: one-sided-split (p≈0.62 at time 0.5) stays above the floor, no-intent-split (p≈0.11) stays below, and a clean 6-leg full cover is never floored for having many legs.
- **π** encodes the owner's N-rule (§3 below).
- **κ** makes coverage a *top concern* without being an absolute tier: with exponent 2, an excellent half-cover (0.99·0.25 = 0.246) sorts under even a fair full cover (0.77), yet a junk full cover (Q≈0.11, below floor anyway) can no longer bury a superb partial. Days weigh 1+urgency, so covering the medical-reason day outranks covering the casual one at equal count — this activates the documented-but-dormant promise that `IntentReason.urgency` "directly influences match ranking."

**One number drives everything.** Construction optimizes it (flow edge costs = −1000·ln p; DFS orders and prunes by it), curation floors on Q, and the single ranker sorts by it. The misalignment — structural proxies in construction, score as a 5th-place tiebreak, two dead rankers — is gone because there is nothing else left to disagree.

---

## 2. The intent-aware people penalty (owner requirement §0.3)

`π = 0.85^((N−2)·f) · 0.995^(N−2)`

- **All-mutual (f = 0):** only the tiny 0.995 edge applies. A unanimous 4-way scores 0.99× the 2-way — "almost as high," and the 2-way still strictly edges it (your stated tiebreak preference, now expressed *inside* the score since there are no hard tiers).
- **Non-mutual legs:** each raises f linearly, and the same leg also drags Q (a one-sided leg has a lower p than a mutual one). Both effects push the same direction, so the decline is strictly monotone in non-mutual count.
- Validated numerically (exact port of the leg model, time 0.5):

| package | Q·π |
|---|---|
| all-mutual 2-way | 0.985 |
| all-mutual 3-way | 0.980 |
| all-mutual 4-way | 0.975 (= 0.99 × the 2-way ✓) |
| 4-way, 3 mutual + 1 one-sided **bookend** (best case) | **0.888** |
| clean 3-way, all legs mutual **splits** (worst clean case) | 0.952 |
| 4-way mutual = 2 / 1 / 0 | 0.809 / 0.736 / 0.670 (strictly monotone ✓) |

The dirty 4-way falls below even the *weakest* clean 3-way, and the property holds at time-value extremes 0.0 and 1.0. The penalty stays per-**person** (never per-leg, preserving the "multi-day with one clean person isn't punished" fix), and `people` continues to exclude the qual-swap bridge.

Why a multiplicative-exponent form rather than, say, a per-non-mutual-leg factor: f normalizes by leg count, so a 4-way with one lukewarm leg out of four isn't punished as hard as a 3-way where one of three is lukewarm — the *proportion* of the loop that's coerced is what predicts collapse, and it composes cleanly with the (N−2) scale you already calibrated 0.85 against.

---

## 3. Using the min-cost machinery for real (owner requirement §0.4)

Today `MinCostFlow` runs with every cost 0 (pure b-matching feasibility) and the give-back is an arbitrary global-prefix grab. Two changes:

**Both directions of the swap enter one flow.**

```
source →(1,0)→ giveDay_i →(1, takeCost_ij)→ peer_j →(1, backCost_jd)→ backDay_d →(1,0)→ sink
```

- Peer nodes have **no** source/sink edge, so conservation forces *days-taken = days-given-back*: balanced reciprocity becomes a graph invariant instead of a post-hoc prefix check that could spuriously fail (the old code allocated give-backs in id order against a shared `usedBack` set, so a feasible instance could return nil because an earlier peer grabbed the day a later peer needed — the flow reroutes instead).
- Back-days are **global unit nodes keyed by calendar date** — you can only receive one shift per date, even from different peers. (The old global `usedBack` enforced this; the flow keeps it.)
- Edge costs: `cost = round(−1000·ln p_leg)`, computed from the *same* `legFeatures` the ranker uses. Feasible iff maxflow = give-day count; min cost then = **max Σ ln p over forward and return legs jointly** — the flow finally optimizes the acceptance objective, including choosing which give-back each peer hands you.
- All costs are **non-negative** (σ bounds p < 1; the max non-ECB logit ≈ 5.0 ⇒ p ≤ 0.9933 ⇒ cost ≥ 7), so SPFA never sees a negative forward edge and the classic ambiguity in `saturatedTargets` can't trigger. I fixed it structurally anyway: forward edges are now **tagged at insertion** (`forward: Bool`) and the readback filters on the tag, never on cost sign. That's correct for any future cost regime.

**Branch-and-bound keeps fewest-people, adds an alternative.** The k = 1…5 subset-size sweep survives, but a size class is now scanned *exhaustively* for its min-cost member (the old first-feasible early exit was acceptance-blind). The fewest feasible size k\* returns first (still flagged `isOptimal` — "provably fewest" preserved), and the best (k\*+1)-subset rides along as `optimal-alt-…` — a bigger-but-cleaner cover the unified score may legitimately prefer, per your "don't overweight fewest-people." Cost bound: ≤ C(16,5)·2 ≈ 8.7k tiny flows worst case, Lucky-gated, cooperatively cancellable (`Task.isCancelled` checked per subset).

---

## 4. Per-engine changes

### 4.1 Two-way (construction unchanged, selection model-ranked)

`twoWayExploreCore` and the whole eligibility SSOT (`TradeEligibility.canCover`, `wouldPickUp`, rest/qual/keep/must-be-off/relief/bookend gates) are **untouched** — §4 contract. What changes is which eligible legs get *picked*:

- `givesBack` (the take-backs offered to you) is re-ranked by `legProb` of the actual leg (intent + bookend + soonness + prior) instead of the coarse bookend-first/soonest sort. `cleanReceiveLegs` is retained as the bookends-only **filter**; its sort is superseded. The default take-day on a card is now the one the objective itself would pick; `takeOptions` still carries the alternatives.
- `canTake` is likewise model-ranked, so the greedy fallback's `prefix(k)` takes the likeliest legs.

### 4.2 Optimal / min-cost — §3 above. 4.3 Greedy fallback

Unchanged shape (most-uncovered-days first — it's a set-cover heuristic and count must dominate), but it now inherits model-ranked `canTake`/`givesBack` orders, so its `prefix(k)` selections are acceptance-optimal within each peer. Urgency tiebreak retained.

### 4.4 N-way DFS

- **Seeds:** unchanged mechanism, but `seedScore` gains `wantsGive:` — the representative leg no longer *assumes* `wantToTrade = true`. For your own seeds (selected give-days) the caller passes the real `mySeeking` membership; for middles it passes their published seeking. Marked days now genuinely outrank unmarked ones in expansion order.
- **Expansion:** at every node, candidate next-takers are ordered **mutual-first** (peers whose published `wantToWorkDayIDs` contains the day), then id. Combined with best-first give-days, all-mutual loops are discovered *first*, so the `maxRoutes` cap keeps the right routes.
- **Pruning (admissible):** the DFS threads the running Σ ln p of the path, computed with the *same* `legFeatures` inputs final scoring uses (including `personPrior` — priors are now passed in; omitting them would make the bound inadmissible when a positive prior could lift a route over the floor). Bound: `upperBoundMeanLog(partialSum, maxLegs) = min(0, Σ)/maxLegs` — every remaining leg contributes ln p ≤ 0 and the final leg count ≤ maxDepth, so this over-estimates every completion's geometric mean. The people penalty is deliberately **absent** from the bound: under the intent-aware π, adding mutual legs can *shrink* the penalty, so folding π in would not be admissible. Pruning tests against the **Lucky** floor (0.07) regardless of mode — conservative for the normal floor, and it keeps the empty-feed fallback pool nearly intact (only sub-0.07 garbage is pruned; see §6, "nothing clears the floor").
- **Route ordering:** `route.score` becomes the route's log-desirability (Σ ln p, + the existing topology bonus in What-If mode) and `nWayRoutes` returns routes **sorted by it**, so the callers' `prefix(…)` cuts keep the best loops instead of dictionary-discovery order.
- Loop-closes-only-at-≥3, `maxRoutes`, `maxDepth`, Keep-day and relief gates, cancellation: all unchanged.

### 4.5 The single ranker

`rankPackages` and `rankIntentPackages` are **deleted**. One comparator remains:

```swift
rankScore ↓  →  fireCount ↓  →  earliestDayID ↑  →  id ↑
```

`fireCount` as the first tiebreak gives the Intents marketplace its "bigger all-mutual deal first" instinct on exact ties without a brittle hard key. Floating-point: the cascade uses **exact** Double comparison on purpose — an epsilon comparator breaks strict weak ordering (non-transitive `<` is UB in `sort`), while genuinely tied structures produce bit-identical scores and fall through deterministically to id.

`finalize` keeps: floor on `acceptanceScore` (now = Q), qual-swap floor exemption, empty-feed fallback (now ranked by `rankLess` rather than raw score — same set, consistent order), safety ceiling 60.

---

## 5. TradeRouter.swift — anchored patches

> `TradeScore.swift`, `MinCostFlow.swift`, `OptimalMatcher.swift` are full drop-ins in the companion files. Below are the surgical regions for `TradeRouter.swift`. Everything is Swift-6-strict: new helpers are `nonisolated` and pure over the `Sendable` snapshots already threaded through; no new `.shared` reads inside detached work.

### P1 — `TradePackage`: add fields (after `dirtyReceives`; init unchanged, set post-init)

```swift
    // U-OBJ: the unified ranking number = acceptanceScore (per-leg quality) × intent-aware
    // people penalty × coverage^wCover. THE primary sort key (rankLess). Set at scoring.
    var rankScore: Double = 0
    // Urgency-weighted fraction of my SELECTED give-days covered (1 for the Intents feed).
    var coverageFrac: Double = 1
    // Mutual (intentLevel == 2) legs / total legs — drive the people penalty; kept for tests/UI.
    var mutualLegCount: Int = 0
    var legCount: Int = 0
```

`dirtyReceives`, `fireCount`, `bookendTotal`, `coverageCount`, `partnerPrior` are all **kept**: the bookends-only hard exclusion still filters on `dirtyReceives == 0`, the UI badges read the others, and `SearchFilter` reads `coverageCount`. They just no longer sort.

### P2 — replace `rankLess`

```swift
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
```

### P3 — replace `finalize`

```swift
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
```

### P4 — DELETE `rankPackages` and `rankIntentPackages` (both dead in the live path). If nothing else references `packageTier`, delete it too — the compiler will tell you.

### P5 — replace `packageQuality(for:…)` with `applyObjective` + two helpers (same MARK section; `legFeatures` and `myGiveCoverage` stay as-is)

```swift
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
```

### P6 — `packages(forGiveShifts:…)` edits, in order

**(a)** Right after `let mineEntries = ctx.mineEntries`, hoist (and delete the later duplicates just above the old `rescored`):

```swift
        let qualsDict = ctx.qualsDict
        let priors = ctx.priors   // U-PERF: built once in ctx
```

**(b)** In the per-peer loop, model-rank both directions (replaces the `canTake` / `givesBack` lines):

```swift
            let canTake = TradeRouter.modelRankedLegs(
                plan.iGive.filter { giveDayIDs.contains($0.dayID) && wouldTake(profile, $0) },
                giverID: selfID, receiverID: cand.workerID,
                maps: maps, quals: qualsDict, priors: priors, start: start, selfID: selfID,
                mySeeking: mySeeking, myWantToWork: myWantToWork, profilesByID: ctx.profilesByID)
                .map(\.dayID)
            let givesBack = TradeRouter.modelRankedLegs(
                TradeRouter.cleanReceiveLegs(plan.iTake.filter { wouldTake(myProfile, $0) },
                                             wantToWork: myWantToWork, bookendsOnly: myBookendsOnly),
                giverID: cand.workerID, receiverID: selfID,
                maps: maps, quals: qualsDict, priors: priors, start: start, selfID: selfID,
                mySeeking: mySeeking, myWantToWork: myWantToWork, profilesByID: ctx.profilesByID)
                .map(\.dayID).filter(inReceiveWindow)
```

Apply the same `modelRankedLegs(cleanReceiveLegs(…))` wrap to the step-1b qual-tier `givesBack`.

**(c)** Step 2 — costed candidates and the two-option flow (replaces the `cands` build and the `if let opt = OptimalMatcher.minPeopleReciprocal…` block; the greedy fallback below it is unchanged):

```swift
            // U-OBJ: real edge costs — the flow optimizes the same objective the ranker sorts by.
            let legProbFor: (String, String, String, String) -> Double = { g, r, day, desk in
                TradeScore.legProb(legFeatures(giverID: g, receiverID: r, day: day, desk: desk,
                                               receiverQuals: qualsDict[r] ?? [], maps: maps, priors: priors,
                                               selfID: selfID, start: start, mySeeking: mySeeking,
                                               myWantToWork: myWantToWork, profilesByID: ctx.profilesByID))
            }
            let cands = peerSwaps.map { ps -> OptimalMatcher.Cand in
                var take: [String: Int] = [:], back: [String: Int] = [:]
                for d in ps.canTake { if let e = (maps[selfID] ?? [:])[d] {
                    take[d] = OptimalMatcher.legCost(prob: legProbFor(selfID, ps.id, d, e.desk)) } }
                for d in ps.givesBack { if let e = (maps[ps.id] ?? [:])[d] {
                    back[d] = OptimalMatcher.legCost(prob: legProbFor(ps.id, selfID, d, e.desk)) } }
                return OptimalMatcher.Cand(id: ps.id, name: ps.name, canTake: Set(ps.canTake),
                                           givesBack: ps.givesBack, takeCost: take, backCost: back)
            }
            var addedMulti = false
            // ≥2 peers only (B6-DEDUP unchanged). [0] = fewest people (isOptimal), [1] = the
            // k*+1 alternative — the unified score decides between them. The alternate is
            // skipped when the flow left a subset member unused and it collapsed to the same
            // peer set as the k* option (a duplicate card with a different id).
            let mpOptions = OptimalMatcher.reciprocalOptions(giveDayIDs: giveAll, peers: cands,
                                                             contiguous: contiguityOK)
            let firstSet = Set(mpOptions.first?.map(\.id) ?? [])
            for (idx, opt) in mpOptions.enumerated()
                where opt.count >= 2 && (idx == 0 || Set(opt.map(\.id)) != firstSet) {
                let a = opt.map { PackageAssignment(workerID: $0.id, name: $0.name,
                                                    giveDayIDs: $0.giveDayIDs, takeDayIDs: $0.takeDayIDs) }
                result.append(TradePackage(
                    id: (idx == 0 ? "optimal-" : "optimal-alt-")
                        + a.map(\.workerID).sorted().joined(separator: ","),
                    methodology: .greedy, assignments: a, route: nil,
                    urgency: urgency(of: a.flatMap(\.giveDayIDs)), isOptimal: idx == 0))
                if idx == 0 { addedMulti = true }
            }
```

**(d)** The `nWayRoutes` call gains the two new snapshots: `myWantToWork: myWantToWork, priors: priors` (capture both in the detached closure alongside the existing ones).

**(e)** Replace the `rescored` block:

```swift
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
```

The bookends-only hard gate (`myBookendsOnly ? … dirtyReceives == 0 …`) and `finalize` call are unchanged.

### P7 — `intentSolutions` edits

**(a)** Hoist `let qualsDict = rosterMeta.mapValues { $0.quals }` **above** the `Task.detached` two-way loop (delete the later duplicate) so the detached closure can capture it.

**(b)** Inside the detached loop, model-rank the pairing inputs (marked-first splitting in `assembleIntentDeal` is order-preserving, so marked legs still lead — this only orders *within* the marked and pref groups):

```swift
                let myTakeable = modelRankedLegs(plan.iGive.filter { wouldTake(profile, $0) },
                    giverID: selfID, receiverID: cand.workerID,
                    maps: maps, quals: qualsDict, priors: priors, start: start, selfID: selfID,
                    mySeeking: mySeeking, myWantToWork: myWantToWork, profilesByID: profilesByID)
                let theirTakeable = modelRankedLegs(plan.iTake.filter { wouldTake(myProfile, $0) },
                    giverID: cand.workerID, receiverID: selfID,
                    maps: maps, quals: qualsDict, priors: priors, start: start, selfID: selfID,
                    mySeeking: mySeeking, myWantToWork: myWantToWork, profilesByID: profilesByID)
```

**(c)** The `nWayRoutes` call gains `myWantToWork: myWantToWork, priors: priors`.

**(d)** Replace the `scored` block with the `applyObjective(…, coverageFrac: 1)` equivalent of P6(e) — no coverage term in the marketplace. The bookends-only gate and `finalize` are unchanged.

### P8 — `nWayRoutes`: signature + DFS body

Signature gains two snapshots (both callers already hold them):

```swift
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
                           myWantToWork: Set<String>,          // U-OBJ: receiver-side intent for legs to me
                           myReliefThrough: Date?,
                           priors: [String: Double],           // U-OBJ: same priors final scoring uses
                           notesByDay: [String: DayNote],
                           topologyByDay: [String: DayTopology]) -> [NWayRoute] {
```

Inside, after `promiseSorted` (which now calls the intent-aware `givePromise` below), add:

```swift
        // U-OBJ: the DFS optimizes and prunes on the SAME leg model final scoring uses, so the
        // partial sums are exact prefixes of the final score — the bound is truly admissible.
        let maxLegs = maxDepth
        let pruneLog = log(TradeRouter.floorLuckyProb)   // conservative for BOTH floors
        func wantsToTake(_ id: String, _ day: String) -> Bool {
            id == selfID ? myWantToWork.contains(day)
                         : (profilesByID[id]?.wantToWorkDayIDs?.contains(day) ?? false)
        }
        func legLog(giver: String, receiver: String, receiverMap: DayMap, entry: RosterEntry) -> Double {
            let give = giver == selfID ? mySeeking.contains(entry.day)
                : (profilesByID[giver]?.seekingDayIDs.contains(entry.day) ?? false)
            let bookend = TradeMatcher.dayDate(fromISO: entry.day).map {
                TradeMatcher.isAnchored(day: $0, map: receiverMap, plan: [entry.day])
            } ?? false
            let quals = receiverMap.values.first?.quals ?? []
            let f = LegFeatures(wantToTake: wantsToTake(receiver, entry.day), wantToTrade: give,
                                bookend: bookend,
                                timeValue: exp(-0.05 * Double(daysUntil(entry.day))),
                                needsQualBridge: !DeskRules.qualified(quals: quals, forDesk: entry.desk),
                                personPrior: priors[receiver] ?? 0)
            return log(TradeScore.legProb(f))
        }
```

`givePromise` becomes intent-aware (and `seedScore` in the pure helpers gains `wantsGive: Bool = true` — its `LegFeatures(wantToTake: false, wantToTrade: wantsGive, …)`):

```swift
        func givePromise(_ entry: RosterEntry, by giverID: String) -> Double {
            let wants: Bool = giverID == selfID ? mySeeking.contains(entry.day)
                : (profilesByID[giverID]?.seekingDayIDs.contains(entry.day) ?? false)
            return seedScore(urgency: giverID == selfID ? seedUrgency(entry.day) : 0,
                             daysUntil: daysUntil(entry.day),
                             qualGatedDesk: DeskRules.hasQualGatedSelection(desks: [entry.desk]),
                             wantsGive: wants)
        }
```

`extend` gains `pathLogSum: Double`. The **close** branch computes the closing leg's contribution and stores the route with

```swift
                        let closingLL = legLog(giver: current, receiver: selfID,
                                               receiverMap: selfMap, entry: entry)
                        let route = NWayRoute(
                            participants: participants, legs: legs,
                            tier: .matchingIntents,
                            score: pathLogSum + closingLL
                                 + topologyWeight(of: legs, selfID: selfID, topologyByDay: topologyByDay),
                            usesBookends: constraints.enforceChaining,
                            bookendCount: bookendCount)
```

(closing legs are never pruned — a completed route is the floor's decision, which protects the empty-feed fallback). The **expansion** branch replaces the raw `maps.sorted(by:)` walk with mutual-first ordering + the admissible prune:

```swift
                let nextIDs = maps.keys
                    .filter { !visited.contains($0) && $0 != selfID }
                    .sorted { a, b in
                        let am = wantsToTake(a, entry.day), bm = wantsToTake(b, entry.day)
                        if am != bm { return am }        // mutual receivers explored first
                        return a < b
                    }
                for nextID in nextIDs {
                    guard let nextMap = maps[nextID],
                          canCover(covererID: nextID, covererMap: nextMap, giver: entry) else { continue }
                    let newSum = pathLogSum + legLog(giver: current, receiver: nextID,
                                                     receiverMap: nextMap, entry: entry)
                    // Admissible prune: even a perfect completion can't clear the Lucky floor.
                    if TradeScore.upperBoundMeanLog(partialLegLogSum: newSum, maxLegs: maxLegs) < pruneLog { continue }
                    let leg = NWayLeg(fromID: current, toID: nextID, dayID: entry.day,
                                      desk: entry.desk, startHour: entry.startHour)
                    extend(path: path + [leg], visited: visited.union([nextID]),
                           current: nextID, currentMap: nextMap, pathLogSum: newSum)
                }
```

Seed loop: same mutual-first ordering for the first coverer; the initial call passes `pathLogSum: legLog(giver: selfID, receiver: nextID, receiverMap: nextMap, entry: myEntry)`. Finally:

```swift
        return routes.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
```

so the callers' `prefix(…)` keeps the most desirable loops. All other gates (Keep, relief, topology-seed protection, `maxRoutes`, cancellation) are byte-identical.

---

## 6. Edge-case audit (§5, item by item)

- **Empty candidate set** — engines return `[]`; `finalize([])` → `[]` (fallback of an empty set is empty). Tested.
- **Nothing clears the floor** — fallback shows the top `emptyFallbackCount` by `rankLess` (was: raw score sort; same set, consistent order). Interaction with the new DFS prune: only paths that *cannot* reach Q ≥ 0.07 even with perfect completions are pruned, and completed routes are never pruned — so the fallback pool for anything remotely showable is intact. A feed consisting *only* of sub-0.07 loops could shrink; that feed was noise by construction. Called out in §7.
- **Single vs multi give-day** — with one selected day every surfaced package covers it, κ ≡ 1, ordering reduces to Q·π; `takeOptions` still populated for single-day cards (now model-ranked).
- **Partial vs full cover** — κ with exponent 2 (numbers in §1); floor never kills a partial for being partial (floor is on Q).
- **Ties / floating-point equality** — exact-equality cascade is intentional; strict-weak-ordering (irreflexive, asymmetric, transitive) asserted in new tests, including a crafted near-tie triple. Deterministic id tail preserved.
- **All-mutual N-way / one non-mutual leg / monotonicity** — §2, all three validated and pinned by `runNPenaltyTests`.
- **Qual-swap packages** — floor exemption preserved verbatim; the bridge stays out of `peopleCount`; `needsQualBridge` still drags Q by −1.2 logit so they sort low naturally (the old `rankPackages` same-N demotion was dead code; live behavior is *more* consistent now, not less). Bridge-first `qualSwapOptions` path untouched.
- **Bookends-only vs open-to-all** — bookends-only hard exclusion (`dirtyReceives == 0` pre-finalize) unchanged in both feeds. Open-to-all: islands are now demoted by the split penalty *inside* the score (a no-intent island leg ≈ 0.11–0.15 wrecks the geometric mean) instead of an absolute tier — your explicit choice. A dirty package can therefore outrank a clean one only by being overwhelmingly better elsewhere.
- **Mercenary mode** — eligibility unchanged (`wouldPickUp` short-circuits true). The score still treats a mercenary's unmarked island pickup as split-heavy — i.e. we *under-rate* their true acceptance odds. Conservative, not wrong; a `isMercenary` leg feature would fix it but is an unrequested behavior change, so it's listed in §7 as a follow-on, not done.
- **Profile-less peers** — conservative fabricated defaults unchanged; their legs are never mutual (no published seeking), so the N-penalty correctly counts them as non-mutual. Existing quirk, flagged not changed: `nWayRoutes.canCover` requires a *published* profile, so profile-less peers can join two-way deals but never loops — if you want loop parity, thread `MatchContext.profile(for:)` in (one-line change, behavior widens).
- **Relief horizon** — `giveBlocked` (give side) and `scheduleUnknown` (cover side, inside `canCover`) untouched.
- **Min-cost give-back barely covers / balance failures** — now *stronger*: conservation makes balance structural, the global back-day nodes keep the one-shift-per-date rule, and the flow reroutes allocations the old prefix grab would have spuriously failed (§3). Infeasible ⇒ nil ⇒ greedy fallback, as before.
- **DFS bounds, cancellation, admissibility** — §4.4; bound proven (algebraically: remaining legs contribute ln p ≤ 0, leg count ≤ maxLegs, penalty excluded) and swept with a seeded deterministic LCG in tests (no `Date()`/`random` in cores, §4 invariant).
- **Intents Mutual excludes no-intent pairings by construction** — the `mutualOnly` guard and robot gate are untouched and live *before* scoring; the ranker only permutes the constructed set, so nothing excluded can resurface. All mode still admits one-sided deals and unclaimed peers, which now sort by the same score (their missing intent and conservative defaults price them down automatically).

---

## 7. Behavior changes you did NOT explicitly ask for (each intentional, each reversible)

1. **Urgency enters live ranking** via urgency-weighted κ. Previously urgency influenced construction order and dead-ranker tiebreaks only; `rankLess` ignored it. The `IntentReason.urgency` doc comment always promised this; now it's true. Revert: weigh all days 1.
2. **The k\*+1 optimal alternative** (`optimal-alt-…`) is a new card that can appear. Revert: take only `options.first`.
3. **Default give-back / canTake selection is model-ranked** (includes wanted/soonness/prior, not just bookend/date) — cards may show a different default take-day than before; `takeOptions` still lists alternatives.
4. **`nWayRoutes` returns desirability-sorted routes**, so `prefix(…)` keeps different (better) loops than dictionary order did; `route.score` semantics changed from `participants + topology` to log-desirability (+ topology in What-If). Nothing user-facing read the old value.
5. **Flow-based give-back can fix old false-negative balance failures** — some multi-person covers that silently returned nil now succeed.
6. **Sub-Lucky-floor DFS paths are pruned mid-search** — a feed whose only content was Q < 0.07 loops could show fewer fallback rows.
7. **Fallback ordering** now uses `rankLess` (was raw `acceptanceScore` sort) — same membership, consistent order.
8. **`acceptanceScore` semantics**: was Q·0.85^(N−2); is now pure Q (penalties live in `rankScore`). Any UI copy printing it should say "match strength," not "acceptance" (§8).
9. **Deleted symbols**: `rankPackages`, `rankIntentPackages` (and possibly `packageTier` if unreferenced). Their tests are ported per the test plan. Three *documented-but-dead* absolutes disappear with them (none were live behavior, but their tests recorded intent): "a 2-person trade always beats a 3-person loop even with more 🔥" (directly superseded by your N-penalty rule), "people-count dominates qual-swap demotion at any intent level" (the qual drag now lives inside the score), and the bookends-only "top two bands" visibility cap (which existed only inside `rankPackages`).
10. *Not* changed, explicitly: mercenary under-rating (§6), profile-less peers excluded from loops (§6), the eligibility predicate, ECB path, qual-swap flows, floor constants, caps (60/500/300), and the removed weekly-hour cap stays removed.

---

## 8. Calibration and the surfaced number

**Decision (yours, confirmed): relative match strength.** `TradeScore.matchStrength(Q)` → 0–100, `strengthTier` → Excellent ≥ 0.80 / Good ≥ 0.55 / Fair ≥ 0.32 / Long shot below (aligned with the floor so "Fair" is exactly "survives the normal feed"). Never render "% likely."

Where the current absolute number could mislead — all fixed by the re-labeling:

- It's a **geometric mean of hand-tuned sigmoids**, ordinal by design. σ(hand weights) ≠ frequency. Calling it "acceptance score" implies a claim the data can't back yet.
- **Mean vs product**: a 6-leg package showing 0.90 does *not* mean 90% the deal closes — the joint product is 0.53. The mean is the right *ranking* signal (it doesn't punish size), but as a probability statement it overstates multi-leg deals, progressively with leg count.
- The **N-penalty and coverage terms are preferences, not physics** — they must never appear inside a number labeled as probability, which is exactly why `rankScore` is internal and Q is what's displayed.
- **`partnerPrior`** is Laplace-smoothed and clamped ±2, fine as a nudge, meaningless as a calibrated per-person rate at current sample sizes. Note its status was subtler than "dead": it already flowed into `acceptanceScore` via `legFeatures.personPrior`, but since the score was a 5th-place tiebreak it was *effectively* dead in ranking; the dead `rankIntentPackages` sort key is deleted. Under `rankScore` the prior finally does its job, at weight 0.2 where it can nudge, not dominate.

**Path to real calibration (later, additive):** at propose time, persist the leg feature vector snapshot with the request id; on accept/decline, emit `(features, outcome)` rows. Once a few hundred rows exist, fit the logistic weights offline (plain gradient descent — six weights, no dependency needed), ship as updated constants, and only then consider surfacing a probability. Nothing in the ranking machinery changes shape.

---

## 9. Test plan (verified against the real Appendix G — `TradeEngineTests.runAll()`)

Full rewrites with exact code live in `EngineTestsAdditions.swift` Part 1; the summary by **exact message string**:

**Flips by design (rewrite, never delete):**

- `"H1/N-penalty: all-dual+book(3) < all-dual+split(2)"` — **inverts**: the all-mutual 3-way now pays only `peopleEdge` (log −0.005 vs the split pair's −0.130), so `<` becomes `>`. This inversion *is* requirement §0.3.
- `"packageQuality: more PEOPLE lowers quality"` — still passes (strictly lower via `peopleEdge`) but no longer tests what it says: for its fully-mutual `cleanLeg` the drop is ~0.5%/person. Strengthened to assert both the strict edge and `q3/q2 > 0.99` near-invariance, plus a non-mutual counterpart that still drops `< 0.9×`.
- `"#3: a two-person trade outranks a three-person loop even when the loop has more 🔥"` — **retired absolute**: it contradicts your newer N-rule (an all-mutual loop must rank above weaker 2-ways) and tests deleted `rankPackages`. Ported outcome in `runNPenaltyTests ❻`: all-mutual 3-loop > no-intent 2-way, and an equally-clean 2-way still edges the loop. Flag: if "pairwise always first" must survive absolutely, that's a design conflict to resolve, not a test edit.

**Pass today only by accident (they build packages with `rankScore` defaulted to 0, tie, and happen to resolve correctly by the id tail) — rewritten to test the mechanism:**

- `"U-RECV: an all-clean package ranks above a dirtier one even with less coverage"` — the absolute is retired (your pure-score decision). Replaced by `runObjectiveTests ❺`: at equal coverage a dirty receive roughly halves the score; and the accepted trade-off (a stellar dirty full-cover may beat a clean half-cover) is pinned explicitly so it can't regress silently.
- `"finalize: coverage-first — a 3-day full-cover beats a higher-scored 1-day"` — coverage now acts through `rankScore` (κ = coverageFrac²); rewritten with real scores (0.80·1² vs 0.95·(⅓)² ≈ 0.106), same intended outcome.
- `"finalize: empty-feed fallback shows the top few by quality when nothing clears the floor"` — rewritten with rankScores set so the expected order comes from the ranker, not id luck.

**Deleted with the dead rankers (compile errors otherwise), live property ported:** the three `"A5: …"` checks, four `"U4: …"` checks, `"Q1: a qual-swap package survives the bookends-only cap (exempt)"` (the band cap no longer exists; floor exemption covered in `runFinalizeTests`), the three `"D5: …"` checks (the qual drag now lives *inside* the score — `runObjectiveTests ❹`), `"Intents: MOST mutual intent ranks first, even with more people (…)"` (emerges from the score), `"H2: all else equal, the likelier-to-accept partner ranks first"` (ported: the prior now lifts `rankScore` through `legProb`), and `"Intents: safety ceiling caps the list at 60"` (absorbed by the finalize ceiling test). `"#4b: earlier-dated trade sorts first (beats alphabetical id)"` is ported verbatim to `rankLess` (`runRankerTests`), which keeps the date tiebreak.

**Verified unchanged and staying green:** both `"MCF …"` blocks; every `"Optimal: …"` golden (fewest-people, balance, infeasible→nil, give-2/back-1 unbalance — flow conservation reproduces it — determinism across peer order, both contiguity checks); `"finalize: normal floor (0.32) …"` and `"finalize: Lucky floor (0.07) …"` (acceptanceScore stays a 0…1 per-leg quality); `"packageQuality: more days (legs) with one person → same quality"`; the entire H1 leg-ordering block including `"H1: partial-route log-prob is an admissible upper bound"` (the intent-aware π is still monotone non-increasing in leg count — (N−2) grows faster than f can shrink); all three `"G3: …"` desirability checks; all `"A1: …"` seed checks (`seedScore`'s new `wantsGive:` defaults to the old hard-coded `true`); and everything else in `runAll()` — eligibility, qual-swap, ECB, parser, intents assembler, `PersonPrior`, `SearchFilter`, the `cleanReceiveLegs` U-RECV *filter* checks, `rosterAtomicityFailures()`.

**New adversarial blocks** (Part 2 of the additions file, `❌`-style, wired by appending to `fails` in `runAll()`): `runNPenaltyTests` (the three owner requirements, per-person-not-per-leg, penalty edge cases, the ported #3 outcome), `runObjectiveTests` (coverage both directions, floor anchors, multi-leg floor immunity, qual-bridge drag, dirty-receive mechanics), `runRankerTests` (strict weak ordering, FP near-tie transitivity, id tail, the ported #4b), `runFinalizeTests` (empty in/out, ranked fallback, qual-swap exemption, ceiling, coverage-through-score), `runPruningBoundTests` (5k-case seeded admissibility sweep — deterministic LCG, no `random()` — plus hopeless-prunable and promising-survives), `runOptimalMatcherTests` (acceptance-optimal peer choice, model-chosen give-back, global back-day uniqueness, k\*+1 alternate ordering, zero-cost legacy defaults).

---

## 10. Migration order (smallest safe step first; harness green after every step)

1. **MinCostFlow forward tag** — pure refactor, zero behavior change at cost 0. Ship alone.
2. **TradeScore drop-in** — new functions + intent-aware `packageQuality` shim. Rewrite flips ①②⑤; add `runNPenaltyTests`, `runObjectiveTests`, `runPruningBoundTests`.
3. **Router objective + single ranker** — `applyObjective`, new `rankLess`/`finalize`, delete dead rankers, port flips ③④. This is the visible reordering step; everything before it was inert.
4. **Model-ranked selection** — givesBack/canTake ordering + greedy inheritance (flip ⑥ partially; construction quality only, ranker already live).
5. **Costed OptimalMatcher** — both-direction flow + k\*+1 alternate; add `runOptimalMatcherTests`.
6. **DFS upgrades** — intent-aware promise, mutual-first expansion, admissible prune, sorted routes.
7. **Display + calibration groundwork** — match-strength tiers in the UI; start logging `(features, outcome)` rows for the future logistic fit.

Steps 4–6 are independent of each other and can land in any order after 3. Cancellation, Sendable snapshot discipline, and the eligibility SSOT are untouched throughout.
