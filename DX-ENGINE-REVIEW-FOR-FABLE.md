# DX Trader — Matching & Ranking Engine: Design Review Brief (for Fable / Claude)

> **How to use this file:** paste §0 as your prompt to Fable (or hand it the whole file — it's
> self-contained, including the verbatim source in the Appendices). Everything Fable needs to reason about
> the problem is here; it does **not** need repo access.

---

## §0 — THE ASK (prompt to Fable)

You are a **senior algorithms engineer**. Below is the complete matching / scoring / ranking subsystem of an
iOS shift-trading app for airline dispatchers (**DX Trader**), including the verbatim Swift source in the
Appendices, the domain context (§1), the current architecture (§2), a working engineer's analysis and a
draft proposal (§3), the invariants you must preserve (§4), and a list of edge cases (§5).

**Your task:** evaluate the *entire* system end-to-end **for the purpose of this app**, and design the best
solution. Specifically:

1. **Judge the objective, not just the code.** The app has two distinct feeds (see §1): **Trade Solutions**
   (cover the specific give-days I selected) and **Intents** with **Mutual** and **All** sub-modes (a
   marketplace of intent-for-intent deals). Decide what "best trade" *should* mean for each, and whether they
   should share one scoring function and one ranker or differ — and if they differ, exactly where.
2. **Fix the core misalignment.** Today, construction (min-cost flow / greedy / N-way DFS) optimizes
   structural proxies (fewest people, most coverage, urgency); the acceptance score is computed *post-hoc*
   and used only as a floor gate + a late tiebreak; and the live ranker (`rankLess`) sorts by hard
   lexicographic keys with score in 5th place. Two other rankers (`rankPackages`, `rankIntentPackages`) are
   **dead code**. Propose a coherent objective used *consistently* across construction, curation, and
   ranking.
3. **Get the N-penalty right.** The owner's requirement: an **all-mutual N-person trade** (everyone marked
   the day) should rank **highly** — a 4-way where all four mutually match should rank *almost as high as* a
   2-way all-mutual match. But as N grows **with non-mutual legs**, it should be penalized progressively and
   fall **below** a clean smaller trade (e.g. a 4-way with only 3 mutuals should sort under a clean 3-way).
   The current flat `0.85^(N−2)` penalty is intent-blind — fix it.
4. **Use the min-cost machinery for real.** `MinCostFlow` is currently invoked with `cost: 0` on every edge
   (Appendix: `OptimalMatcher`), so it's pure feasibility/b-matching — it never optimizes acceptance, and the
   return-leg (give-back) assignment is arbitrary prefix order. Decide whether/how to make the flow optimize
   the acceptance objective (edge costs), and whether both directions of the swap should be in the flow.
5. **Calibration.** Weights are hand-tuned (not fit to data). Decide whether the surfaced number should be a
   calibrated probability (fit from the app's stored accept/decline history — `partnerPrior`) or presented as
   a relative "match strength." Note any place the current absolute number could mislead.

**Be meticulous.** Reason about correctness and edge cases explicitly (§5): empty results, single give-day
vs multi-day, partial vs full cover, ties, floating-point equality in comparators, qual-swap packages
(bridge not counted in `peopleCount`), circular loops (close only at N≥3), profile-less peers, bookends-only
openness, mercenary mode, relief-dispatcher horizon, cancellation mid-search, and the admissibility of any
DFS pruning bound if you change the scoring. Call out anything that would change behavior the owner didn't
ask to change.

**Deliverables:**
- A crisp statement of the **objective function** (per feed), with the exact weighted terms and the
  intent-aware people penalty, in math.
- **Per-engine changes**: two-way, min-cost/optimal (+ MinCostFlow edge costs & readback), greedy fallback,
  N-way DFS (seed/expansion ordering + pruning bound), and the single ranker.
- **Swift code** (drop-in for the files in the Appendices), matching the existing style (Swift 6 strict
  concurrency: pure `nonisolated` cores, `Sendable` snapshots, no `Combine`).
- A **test plan**: which existing `EngineTests` assertions change and why, plus new adversarial tests for the
  edge cases and the N-penalty requirement.
- A short **migration order** (smallest safe step first).

**Hard constraints:** iOS/iPadOS, on-device, no server round-trips in the hot path; the roster window is
small (optimal tier bounded to ≤16 peers / ≤10 days); legality gates (§4) are contractual and must stay in
the single shared eligibility predicate; the pure scoring/ranking cores must remain unit-testable; keep the
regression harness (`EngineTests.runAll()` returns only failures — empty == pass) green.

---

## §1 — App & domain context

**Who/what:** airline **dispatchers** trade shifts against a master schedule. Hard realities: each desk needs
a **qualification** (Domestic D = universal, European E, Latin L, Pacific P, coordinator roles A/O/R/S);
only shifts starting at **0500 / 1300 / 2100** are tradeable; an **8-hour rest** gap between shifts is
mandatory; training desks never trade. A **bookend** is a pickup that attaches to the edge of your existing
days off (good); a **split** breaks up a block (bad). Reciprocity is **balanced** day-for-day (give N, get N).

**Per-day intents** a user marks: **Trade-away** (working day I'd give), **Want-to-work** (off day I'd pick
up), **Keep** (never give this working day — hard), **Must-be-off** (never take this off day — hard). A leg
is **mutual (🔥)** when BOTH sides marked it (giver marked trade-away AND receiver marked want-to-work) →
`intentLevel == 2`. One side = `intentLevel 1`. Neither = `0`.

**The two feeds (this is central to the review):**
- **Trade Solutions** (`TradeRouter.packages`): you pick specific **give-days**; the engine finds balanced
  covers — two-person swaps, fewest-people multi-person covers (min-cost/greedy), and circular loops (N-way).
  Goal: *cover the days I selected*, best options first.
- **Intents** (`TradeRouter.intentSolutions`), two sub-modes:
  - **Mutual**: only deals where BOTH sides marked a day (true 🔥 overlap). Seeds from your marked days AND
    peers' marked days.
  - **All**: also one-sided deals / peers without a published profile (a wider pool).
  Goal: *surface where people's wishes overlap*, most-mutual first (in principle).

**Also present:** ECB one-way give-aways (no swap back; fair first-come queue), and 3-party **qual-swaps**
(a qualified "bridge" C slides onto A's desk so an unqualified taker B can cover; C is an *enabling* leg and
is **not** counted in the trade's `peopleCount`).

---

## §2 — Current architecture (as built)

**Pipeline:** `construct candidate packages → score each post-hoc → curate (floor) → rank`.

1. **Construct** (`packages` / `intentSolutions`):
   - Two-person reciprocal swaps (`TradeMatcher.twoWayExploreCore`).
   - Fewest-people multi-person cover: `OptimalMatcher.minPeopleReciprocal` — branch-and-bound over subset
     **size** k=1…5; feasibility per subset via `MinCostFlow` (**all edge costs = 0** → pure max-flow
     b-matching); give-back assigned by `prefix`. Greedy balanced cover is the fallback.
   - Circular loops: `nWayRoutes` — bounded best-first DFS, loops close only at depth ≥3, cancellable,
     `maxRoutes` backstop. Seed/expansion ordering uses `seedScore` / `givePromise` (urgency + a
     representative `legProb`).
   - Qual-swap tiers.
2. **Score** (uniform, post-hoc): every package gets `acceptanceScore = TradeScore.packageQuality(legs,
   people)` = geometric mean of per-leg `σ(legLogit)`, times `0.85^(N−2)` (flat, intent-blind).
3. **Curate**: `finalize` drops `acceptanceScore < floor` (0.32 normal / 0.07 Lucky), with an empty-feed
   fallback (top few) and a safety ceiling (60).
4. **Rank**: `finalize` sorts by **`rankLess`** for BOTH feeds. `rankLess` keys (tiered/lexicographic):
   `dirtyReceives ↑ → coverageCount ↓ → peopleCount ↑ → bookendTotal ↓ → acceptanceScore ↓ → date ↑ → id`.

**Dead code to resolve:** `rankPackages` (fewest-people-first + 🔥/bookend tiers) and `rankIntentPackages`
(most-🔥-first, and the ONLY user of the learned `partnerPrior`) are defined and unit-tested but **never
called** — both feeds actually run `rankLess`. So the intended "intent-first Intents feed" and the
"individual partner-history tiebreak" are **not live**.

---

## §3 — Working engineer's analysis & draft proposal (for Fable to critique/improve)

### What each engine does re: the acceptance score
- **Min-cost/optimal:** finds the *fewest people* that can feasibly cover; **acceptance score never enters**
  (edge costs are 0; give-back is arbitrary prefix). Scored only afterward.
- **Greedy:** picks the peer covering the most uncovered days (ties → urgency → id); acceptance-blind;
  scored afterward.
- **N-way DFS:** *partially* score-aware — seeds/branches ordered by `legProb`-based promise — but the final
  set is curated by the floor on `packageQuality`.
- **Uniform post-hoc:** all packages then get `packageQuality`; `rankLess` uses it only as key #5.

### What `acceptanceScore` computes, and why numbers sit where they do
`packageQuality` = geometric mean of per-leg `legProb`, × `0.85^(N−2)`. `legProb = σ(1.5·intentLevel +
(bookend ? +0.8 : −(2.5 − 1.1·intentLevel)) + 0.8·soonness − 1.2·qualBridge + 1.5·ecb + 0.2·personPrior)`.
Representative single-leg values (soon trade): mutual+bookend ≈ 0.99, one-sided+bookend ≈ 0.96,
no-intent+bookend ≈ 0.83, one-sided+split ≈ 0.71, no-intent+split ≈ 0.15. So the ceiling is ~0.99 (not
"low"); a 3-way's 0.84 was the flat headcount penalty (0.99 × 0.85). The 0.32 floor sits between
one-sided-split (kept) and no-intent-split (dropped). **Caveat:** weights are hand-tuned → treat the number
as ordinal, not a calibrated probability.

### Identified problems (the review should confirm/expand)
1. **Three rankers, two dead, comments that contradict the wiring.** Consolidate to one.
2. **A rich score barely drives order** — it's a floor gate + a 5th-place tiebreak. The model's nuance is
   wasted on ranking.
3. **Lexicographic ranking is brittle** — a one-unit edge in a high key overrides everything below (e.g.
   coverage 3 vs 2 beats a vastly better 2-day trade). Real preference is a blend.
4. **N-penalty is intent-blind** — punishes a unanimous 4-way as hard as a coerced one (the owner's fix).
5. **`partnerPrior` (learned individual history) is dead** in the live path.
6. **`MinCostFlow` runs at cost 0** — the optimizer never optimizes acceptance; give-back assignment is
   arbitrary.

### Draft proposal (improve or replace)
- **Unify the objective:** fold coverage, people (**intent-aware** penalty), bookend/split, soonness, mutual
  intent, and partner history into ONE `packageQuality`, then **rank primarily by it**; keep at most one or
  two genuine hard gates outside it.
- **Intent-aware N-penalty:** scale the per-extra-person discount by the fraction of non-mutual legs, e.g.
  `0.85^((N−2) · nonMutualFraction)`, where `nonMutualFraction = (# legs with intentLevel < 2) / legCount`.
  All-mutual ⇒ ~no penalty (4-way ≈ 2-way, 2-way edges it on a fewest-people tiebreak); a non-mutual leg at
  larger N ⇒ falls below a clean smaller trade.
- **Real min-cost:** set `day→peer` (and return-leg) edge costs to `−round(K · legLogProb)` so the flow
  returns the max-acceptance cover *within* a fixed people-count k; keep branch-and-bound over k for
  fewest-people. (Fix `saturatedTargets`, which currently identifies forward edges by `cost >= 0`.)
- **One ranker;** delete the dead ones. Decide feed differences by *what is built/seeded*, not by a separate
  sort (or justify a separate sort).
- **Calibration:** optionally fit the logistic weights from stored accept/decline history.

**Owner's stated intent for ordering:** "rank by score, don't overweight fewest-people"; keep coverage-of-my-
days as a top concern; an all-mutual group should be near the top regardless of N.

---

## §4 — Invariants you must NOT break

- **Legality gates** (single shared predicate `TradeEligibility.canCover`, Appendix `TradeMatcher`): off on
  cover day, desk qualification, 8-hour rest, Must-Be-Off, Keep, relief-dispatcher horizon, bookend anchoring
  for bookends-only openness, dispatch-shift timing (0500/1300/2100, no training desks). *(Note: a weekly-hour
  cap was previously removed — do not reintroduce.)*
- **Balanced reciprocity:** give N ↔ receive N; one-way giveaways are the separate ECB path.
- **Qual-swap bridge is NOT counted in `peopleCount`** (it's an enabling leg).
- **Circular loops close only at ≥3 participants** (a 2-cycle is a two-way swap).
- **Concurrency:** heavy cores are `nonisolated` and run in `Task.detached` over `Sendable` snapshots;
  searches are cooperatively cancellable (`Task.isCancelled`) so a re-search supersedes a stale one. Any
  scoring change used as a DFS pruning bound must stay **admissible** (never prune a route that could clear
  the floor).
- **Determinism:** stable tiebreak by `id`; no `Date.now()`/`Math.random()` in pure cores.
- **The regression harness must stay green:** `EngineTests.runAll()` returns only failure strings.

---

## §5 — Edge cases to reason about explicitly

- Empty candidate set; nothing clears the floor (empty-feed fallback); single give-day vs many.
- Partial cover vs full cover of the selected give-days (coverage term).
- Exact ties and **floating-point equality** in comparators (`a.score != b.score` on Doubles).
- All-mutual N-way (must rank high); N-way with 1 non-mutual leg (must fall below clean N−1); monotonicity as
  non-mutual count grows.
- Qual-swap packages (floor-exempt today; bridge excluded from `peopleCount`); do they still surface and sort
  sensibly under the new objective?
- Bookends-only openness (islands hard-excluded) vs open-to-all (islands kept but demoted).
- Mercenary mode; profile-less peers (treated conservatively / bookends-only default).
- Relief-dispatcher horizon (post-horizon days invisible).
- Min-cost give-back assignment when a peer's `givesBack` count barely covers; balance failures → nil.
- DFS `maxRoutes`/`maxDepth` bounds; cancellation mid-search; N-way pruning-bound admissibility.
- Intents **Mutual** excludes no-intent pairings *by construction*; **All** includes unclaimed peers — make
  sure the new ranking doesn't resurrect excluded pairings.

---

## §6 — Source code (verbatim)

The complete algorithm source follows. Files: `TradeScore`/`LegFeatures` and `SearchFilter` from
`TradeEngineModels.swift`; `MinCostFlow.swift`; `OptimalMatcher.swift`; `TradeRouter.swift` (packaging,
scoring, ranking, finalize, N-way DFS); `TradeMatcher.swift` (eligibility, desk rules, timing, two-way
exploration, qual-swap); `TradeProfile.swift` (openness, blacklists, `wouldPickUp`). Line numbers are from
the live repo for cross-reference.

