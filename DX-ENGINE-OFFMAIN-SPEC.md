# DX Engine Off-Main Refactor — Spec

Move the heavy trade-matching loop (`TradeRouter.intentSolutions`) off the **main actor** so it stops
freezing the UI at launch (and in the Trade Solutions / Intents / Lucky flows). The launch precompute
currently runs the whole matcher on `@MainActor`; its N-way circular search barely yields, pinning the
UI. Deferring it didn't help (a `Task` in a `@MainActor` context still runs on main).

Design-locked from the 2026-07-13 investigation. Incremental + compiler-checked; the trade engine is
core, so every step is gated by the existing `EngineTests` and Swift's actor-isolation checking.

---

## 0. Strategy

`TradeRouter` and `TradeMatcher` are `@MainActor` **enums** — so their methods are main-actor-isolated.
Removing `@MainActor` from the whole enum has a huge blast radius (every method + call site). Instead:

- **Mark the individual PURE methods `nonisolated`** (they already operate only on passed-in args). The
  compiler *proves* purity — a `nonisolated` method that touches `.shared` state won't compile. That's
  the core safety net.
- **Snapshot** every main-actor read into `Sendable` values on the main actor, then run the loop in
  `Task.detached` — mirroring the existing `MatchContext.derive` pattern (TradeRouter.swift:195).
- The `@MainActor` entry `intentSolutions` stays (call sites unchanged); it snapshots, then `await`s the
  `nonisolated` core.

`MatchContext` is already `Sendable` and already built off-main — half the plumbing exists.

---

## 1. Verified code map (**verified 2026-07-13**; re-grep before each step)

### Isolation of callees (TradeMatcher.swift / TradeRouter.swift)
| Symbol | Loc | Isolation | Body pure? | Action |
|---|---|---|---|---|
| `TradeRouter` enum | TradeRouter.swift:123 | `@MainActor` | — | keep; mark members `nonisolated` selectively |
| `TradeMatcher` enum | TradeMatcher.swift:348 | `@MainActor` | — | keep; mark members `nonisolated` selectively |
| `intentSolutions` | TradeRouter.swift:623 | @MainActor | no (snapshots) | entry: snapshot → call core |
| `assembleIntentDeal` | :575 | @MainActor (member) | ✅ pure | `nonisolated` |
| `packageQuality` / `legFeatures` | :859 / :~830 | member | reads `DayIntentStore`/`TradeProfileStore` for `selfID`+peers | `nonisolated` + pass snapshots |
| `myGiveCoverage` / `finalize` | :879 / :936 | member | ✅ pure | `nonisolated` |
| `selfSeekingShifts` | :1257 | member | reads `seekingDayIDs` + `RosterStore` | pass `mySeeking` snapshot + preloaded mine |
| `nWayRoutes` | :1073 | @MainActor | ❌ reads `.shared` DEEP in DFS (myProfile, profilesByID, keepDayIDs, reliefThrough, seekingDayIDs, topology, notes — lines 1096,1107,1117–1124,1132,1209,1210,1234,1253) | Step 3: snapshot all per-node state → `nonisolated` |
| `twoWayExplore` | TradeMatcher.swift:476 | @MainActor | ✅ pure WHEN preloaded (always is at TradeRouter.swift:719) | `nonisolated` |
| `TradeEligibility.canCover` | TradeMatcher.swift:867 | @MainActor | ✅ pure body | `nonisolated` |
| `QualSwap.solutions/bridges` | TradeMatcher.swift:243/209 | member | ✅ pure | `nonisolated` (or already) |
| `DeskRules.*` | TradeMatcher.swift:58–160 | member | ✅ pure | `nonisolated` |
| `TradeTiming.*` | TradeMatcher.swift:166–183 | member | ✅ pure | `nonisolated` |
| `MatchContext.build` / `derive` | TradeRouter.swift:175 / 195 | build @MainActor; **derive `nonisolated` + `Task.detached`** | pattern to mirror | reuse |

### Main-actor reads inside `intentSolutions` (must be snapshotted)
| Loc | Read | When | Snapshot |
|---|---|---|---|
| :627 `DayIntentStore.shared.seekingDayIDs` | up-front | `mySeeking` (already local) |
| :628 `.wantToWorkDayIDs` | up-front | `myWantToWork` (already local) |
| :630 `TradeProfileStore.shared.myProfile()` | up-front | `myProfile` (already local) |
| :643–644 `DayIntentStore.shared.note/topology` (in `dayUrgency`) | **in loop, per day** | **precompute `[DayID: Int]` urgency map up-front** |
| :711,:782 `TradeProfileStore.shared.isActiveAccount(id)` | **in loop, per peer** | **precompute `[WorkerID: Bool]` active map up-front** |
| ctx.* (maps, profilesByID, universe, priors, rosterMeta, mineEntries) | up-front | already `Sendable` in `MatchContext` |

### Sendability of boundary types (audit)
✅ Already `Sendable`: `TradePackage`, `PackageAssignment`, `TradeProfile`, `RosterEntry`, `SearchFilter`,
`TwoWayPlan`, `QualSwapLegData`, `DayTopology`, `DayNote`, `NWayLeg`, `NWayRoute`, `MatchCandidate`,
`IntentPairing`, `MatchContext`.
⚠️ `Shift` (Shift.swift:27) is `Codable, Identifiable, Hashable` — **Sendable only implicitly**. Used as
`nWayRoutes(seedShifts:)`. *Fail-safe:* if the compiler complains at the boundary, add explicit `Sendable`.

### Call sites (signature must stay `async -> [TradePackage]`)
- `TradeIntentsFeed.swift:334` (mutual) & `:343` (all) — `@MainActor` feed refresh.
- `ContentView.swift:~206` — `Task(priority:.utility)` launch precompute.
All just `await` the `[TradePackage]` result → return type unchanged; safe.

### Assumptions ledger
1. `nonisolated` on a member of a `@MainActor` enum is allowed and, if the body touches main-actor state,
   **fails to compile** — this is our correctness proof. *If wrong:* the whole approach changes; STOP.
2. Preloaded schedules are ALWAYS passed in the `intentSolutions` loop (`twoWayExplore` :719 preloaded;
   `nWayRoutes` :765 `preloadedMaps`) so no `.shared` roster fetch fires mid-loop. — verified in the map.
3. The matcher is deterministic for fixed inputs (needed so off-main results == on-main results). — the
   determinism test (Step 2 gate) proves it.
4. `SWIFT_APPROACHABLE_CONCURRENCY = YES` + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` hold (pbxproj:511)
   — enables `nonisolated` inference and flags races at compile time.

---

## 2. Phased plan + per-step fail-safes

Each step: **Precondition** (re-grep §1) → **Guardrails** → **Gate** (must pass) → **Rollback**. A step is
done only when its Gate passes. One step, one pause.

**Step 0 — Sendability + mark the already-pure helpers `nonisolated`.**
- *Do:* mark `assembleIntentDeal`, `myGiveCoverage`, `finalize`, `QualSwap.*`, `DeskRules.*`,
  `TradeTiming.*` (and any other verified-pure helper) `nonisolated`. Add `Sendable` to `Shift` only if
  the compiler needs it.
- *Guardrails:* NO behavioral change — only isolation annotations. Touch nothing inside the bodies.
- *Gate:* `BuildProject` clean **AND** existing `EngineTests` pass unchanged. (If a `nonisolated` mark
  fails to compile, that method wasn't pure — revert that one mark, note it.)
- *Rollback:* remove the annotations.

**Step 1 — Snapshot the two per-loop touchpoints (still on main).**
- *Do:* before the candidate loop in `intentSolutions`, precompute `activeByID: [String: Bool]` (from
  `TradeProfileStore.shared.isActiveAccount`) and `urgencyByDay: [String: Int]` (from the day set the loop
  touches); use those in the loop instead of `.shared`. Still runs on main.
- *Gate:* build clean; EngineTests pass; the badge count is unchanged for a fixture (behavior identical).
- *Rollback:* inline the `.shared` reads again.

**Step 2 — Move the 2-way loop + scoring off-main.**
- *Precondition:* `twoWayExplore`, `canCover`, `packageQuality`/`legFeatures` marked `nonisolated`
  (packageQuality/legFeatures take snapshots).
- *Do:* build a `Sendable` input bundle (ctx + mySeeking + myWantToWork + myProfile + activeByID +
  urgencyByDay + generation). Add `nonisolated static func intentSolutionsCore(_ input) async -> [TradePackage]`
  that runs the 2-way loop + scoring via `Task.detached(priority:.utility)`, mirroring `derive`. For now,
  the **N-way block stays on main** (guard it out of the detached core — see Step 3), or call it via a
  main hop; the 2-way bulk is off-main.
- *Guardrails:* `intentSolutions` signature unchanged; it snapshots then `await intentSolutionsCore`.
- *Gate:* build clean; EngineTests pass; **determinism test** (run core twice → identical); **parity
  test** (off-main core result == the pre-refactor on-main result for a fixture roster); manual: launch no
  longer freezes for the 2-way portion.
- *Rollback:* `intentSolutions` calls the old inline loop (keep it behind a flag until Step 3 lands).

**Step 3 — Move `nWayRoutes` off-main (the hard one).**
- *Precondition:* enumerate every `.shared` read in `nWayRoutes` (§1 lists them).
- *Do:* snapshot per-node state into a `Sendable` bundle — `myProfile`, `profilesByID`,
  `keepByID: [String: Set<String>]`, `reliefByID: [String: Date?]`, `seekingByID`, `topologyByDay`,
  `noteUrgencyByDay` — pass it in; make `nWayRoutes` (+ `selfSeekingShifts`) `nonisolated`; run inside the
  detached core.
- *Guardrails:* the snapshots must cover ALL peers the DFS can reach (universe), not just marked ones.
- *Gate:* build clean; EngineTests pass; determinism + parity tests **including circular** (a fixture with
  a known 3-way loop yields the same route on- and off-main); manual: no freeze with `maxPeople = 3`.
- *Rollback:* keep Step-2 state (2-way off-main, N-way on-main behind the flag) — still a big improvement.

**Step 4 — Remove the fallback flag + verify on device.**
- *Gate:* device run — launch is interactive immediately; Trades/Intents/Lucky don't hang; Instruments
  shows the matcher off the main thread.

---

## 3. Systemic anti-hallucination / anti-regression protocol

1. **Grep-before-use / no memory APIs.** Confirm every symbol against §1 before editing; re-grep if a step
   fails. New concurrency APIs → confirm via `DocumentationSearch`, never assume.
2. **Build gate + issues check** after each step (`BuildProject` + `XcodeRefreshCodeIssuesInFile` on
   touched files). No "should compile."
3. **Regression gate = EngineTests unchanged & green** after every step. If a test needs editing to pass,
   STOP and explain — do not "fix" the test to match new behavior.
4. **Compiler-proved purity.** The `nonisolated` marks are the safety net: the compiler rejects any
   accidental main-actor access off-main. Never silence it with `@unchecked`/`nonisolated(unsafe)` to make
   it build — that defeats the proof.
5. **Parity + determinism tests** guard the off-main results against the on-main baseline (Steps 2–3).
6. **Fallback flag** (`useOffMainMatcher`) keeps the old on-main path callable until Step 4, so any
   regression is one flag flip away from reverting at runtime.
7. **Blast-radius control.** Only the declared files per step; no drive-by refactors of unrelated matcher
   logic. Engine behavior (scoring, gating, caps) is UNCHANGED — this is a *threading* refactor only.
8. **Honest reporting.** Compile-verified ≠ runtime-verified; state exactly what was checked each step.
9. **One step, one pause** — stop at each Gate for review.
10. **Spec is the contract** — deviations update this doc first.

---

## 4. Files touched
- `Sources/Domain/TradeEngine/TradeRouter.swift` (core; `intentSolutions`, new `intentSolutionsCore`, marks)
- `Sources/Domain/TradeEngine/TradeMatcher.swift` (`nonisolated` marks on pure helpers)
- `Sources/Domain/Schedule/Shift.swift` (only if explicit `Sendable` needed)
- `Sources/Support/EngineTests.swift` (ADD determinism + parity tests; never weaken existing)
- No UI/call-site changes (signature preserved).
