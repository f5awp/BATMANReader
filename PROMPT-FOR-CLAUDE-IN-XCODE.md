# Prompt for Claude (Xcode / Claude Code) — paste everything below the line

You will need these four files available to the session (drag them into the chat, or
drop them in a `_dropins/` folder at the repo root before starting):

- `TradeScore.swift`            (replacement region for TradeEngineModels.swift)
- `MinCostFlow.swift`           (full-file drop-in)
- `OptimalMatcher.swift`        (full-file drop-in)
- `EngineTestsAdditions.swift`  (test rewrites Part 1 + new test blocks Part 2)
- `DX-Engine-Redesign.md`       (the design doc — contains the TradeRouter patches P1–P8)

---

You are working in the DX Trader iOS repo (Swift 6, strict concurrency). Implement the
unified-objective redesign of the matching/scoring/ranking engine, exactly as specified
in the provided files. Work in SEVEN STAGES, in order. After EVERY stage: build, then run
the regression harness (`TradeEngineTests.runAll()` — invoke it the way the dev-tools
"Run engine tests" action does, or a quick REPL/snippet call) and confirm it returns an
EMPTY array before committing that stage. One commit per stage, message prefixed `U-OBJ:`.

## Non-negotiable invariants (do not touch, do not "improve")

- `TradeEligibility.canCover` and everything it calls (rest/qual/keep/must-be-off/relief/
  bookend/dispatch-shift gates) — byte-identical.
- Balanced reciprocity; ECB path; qual-swap flows; the qual bridge stays OUT of `peopleCount`.
- Circular loops close only at ≥3 participants.
- Floors 0.32/0.07, `emptyFallbackCount = 5`, `intentResultCap = 60` — values unchanged.
- No `Date()`/`random()` in pure cores; deterministic id tiebreaks; heavy cores stay
  `nonisolated` over `Sendable` snapshots; keep every `Task.isCancelled` check.
- Do NOT reintroduce a weekly-hour cap.

## Stage 1 — MinCostFlow forward tag (zero behavior change)

Replace `MinCostFlow.swift` with the provided drop-in. It adds a structural `forward`
flag to edges and rewrites `saturatedTargets` to filter on it instead of `cost >= 0`.
Harness must stay green with NO test edits.

## Stage 2 — TradeScore (new objective functions + shim)

In `TradeEngineModels.swift`, replace the entire `enum TradeScore { … }` with the
provided `TradeScore.swift` content. `LegFeatures` and `PersonPrior` above it stay as-is.
New API: `meanLegQuality`, `mutualLegCount`, `peoplePenalty(people:mutualLegs:legCount:)`,
`packageScore(_:people:coverageFrac:)`, `upperBoundMeanLog`, `matchStrength`,
`strengthTier`; `packageQuality`/`packageProb`/`packageLogProb`/`routeDesirability` keep
their signatures but the people penalty is now intent-aware.

Then update the harness per `EngineTestsAdditions.swift` PART 1:
- Rewrite `"H1/N-penalty: all-dual+book(3) < all-dual+split(2)"` → the `>` version given.
- Strengthen `"packageQuality: more PEOPLE lowers quality"` as given.
- Wire in `runNPenaltyTests()`, `runObjectiveTests()`, `runPruningBoundTests()` from
  PART 2 (append to `fails` in `runAll()` before `return fails`).
Harness green.

## Stage 3 — Router objective + the single ranker (the visible change)

Apply patches P1–P5 and P6(e)/P7(d) from `DX-Engine-Redesign.md` §5 to `TradeRouter.swift`:
- P1: add `rankScore`, `coverageFrac`, `mutualLegCount`, `legCount` to `TradePackage`
  (post-init defaults; the explicit init signature must NOT change).
- P2: replace `rankLess` (nonisolated, score-first: rankScore ↓ → fireCount ↓ →
  earliestDayID ↑ → id ↑).
- P3: replace `finalize` (floor on `acceptanceScore` = per-leg quality; qual-swap exempt;
  fallback and final sort both via `rankLess`).
- P4: DELETE `rankPackages` and `rankIntentPackages`. Delete `packageTier` too if the
  compiler shows no other references.
- P5: replace `packageQuality(for:…)` with `applyObjective` + `coverageFraction` +
  `modelRankedLegs` exactly as given (note `modelRankedLegs` must be `private` — it uses
  the file-private `DayMap` typealias).
- P6(e): in `packages(…)`, hoist `qualsDict`/`priors` (P6(a)) and replace the `rescored`
  block with the `applyObjective` version (urgency-weighted coverage).
- P7(a)+(d): in `intentSolutions(…)`, hoist `qualsDict` above the detached block and
  replace the `scored` block with `applyObjective(…, coverageFrac: 1)`.

Harness edits (PART 1): rewrite the three "pass-by-accident" tests
(`"U-RECV: an all-clean package ranks above a dirtier one…"`,
`"finalize: coverage-first — a 3-day full-cover beats a higher-scored 1-day"`,
`"finalize: empty-feed fallback shows the top few by quality…"`) as specified; delete the
listed `A5:`/`U4:`/`D5:`/`#3:`/`Q1 band-cap`/`rankIntentPackages` tests (they reference
deleted symbols) and add their ports; wire in `runRankerTests()` and `runFinalizeTests()`.
Harness green.

## Stage 4 — Model-ranked leg selection

Apply P6(b) (model-ranked `canTake`/`givesBack` in the peer loop; same wrap for the
step-1b qual-tier `givesBack`) and P7(b) (model-ranked `myTakeable`/`theirTakeable` in
the intents loop — order-preserving w.r.t. marked-first splitting). No test changes
expected. Harness green.

## Stage 5 — Costed OptimalMatcher (both-direction flow)

Replace `OptimalMatcher.swift` with the provided drop-in, then apply P6(c) (costed
`Cand`s via `legCost(prob:)` + the `reciprocalOptions` loop with the duplicate-alternate
guard and `optimal-alt-` ids). Wire in `runOptimalMatcherTests()`. The existing
`"Optimal: …"` goldens must pass UNCHANGED — if any fails, the port is wrong; stop and
re-check rather than editing the golden. Harness green.

## Stage 6 — DFS upgrades

Apply P8 to `nWayRoutes`: signature gains `myWantToWork:` and `priors:` (both call sites
already hold these snapshots — pass them through the `Task.detached` captures);
intent-aware `givePromise`; `seedScore` gains `wantsGive: Bool = true` (existing call
sites and tests unchanged); `legLog` + `pathLogSum` threading; mutual-first `nextIDs`
ordering in BOTH the seed loop and `extend`; the admissible prune against
`log(TradeRouter.floorLuckyProb)` on expansion legs ONLY (never prune a closing leg);
`route.score` = path log-desirability (+ topology weight); return routes sorted by score
desc, id asc. Harness green (the A1 seed tests must still pass).

## Stage 7 — Display

Where the UI currently surfaces `acceptanceScore` as a number or percent, present
`TradeScore.matchStrength(pkg.acceptanceScore)` labeled "Match strength" with
`strengthTier` badges (Excellent/Good/Fair/Long shot). Never render it as "% likely" or
"acceptance probability". UI-only; no engine or harness changes.

## Final acceptance checklist

1. `TradeEngineTests.runAll()` returns `[]` (also run `rosterAtomicityFailures()` — must
   be untouched and green).
2. All-mutual sanity: a unanimous 3-way scores within ~1% of a clean 2-way
   (`packageScore` check ❶ in `runNPenaltyTests` passes).
3. Grep: no remaining references to `rankPackages`, `rankIntentPackages`.
4. `git diff` on `TradeMatcher.swift` and `TradeProfile.swift` is EMPTY except (if
   applicable) nothing at all — these files must not change.
5. Every `Task.isCancelled` present before the change is still present.

If any instruction conflicts with what you find in the repo (a symbol moved, a call site
I didn't list), STOP and report the discrepancy instead of improvising around it.
