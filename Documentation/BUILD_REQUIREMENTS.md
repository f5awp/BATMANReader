# BUILD REQUIREMENTS — the six-sigma adherence gate (self-audit reference)

> **Read this before and after every build sub-step.** Every item is mandatory; a sub-step is
> NOT "done" until all gates are green. "Six sigma" here = no sub-step ships unless its behavior
> is *proven* by a test that can fail, the change is *centralized* (one source of truth), and the
> project still *builds + passes the whole harness*. No batching, no "already there" claims, no
> silent scope creep.

## A. Navigation (efficiency)
1. **Use `ARCHITECTURE_MAP.md` to find WHERE to go** — locate the symbol/file before reading code.
2. Then **targeted reads only**: `Grep`/`XcodeGlob` for the symbol, `Read` a small range. Never read a
   whole large file to "look around." The map + grep are the index.
3. `SPEC_ROUND3.md` is the source of WHAT to build (scope, fail-tests, safeguards, assumptions).

## B. The per-sub-step gate (in order — do not skip or reorder)
1. **Fail-test FIRST.** Write the test(s) referencing the not-yet-existing API. Run the harness →
   **confirm RED** (compile-fail like "cannot find X in scope", or an assertion failure).
2. **Prove teeth** for behavioral tests whose red was *not* a clean compile-fail: temporarily break
   the impl, run → the specific assertion must go red, then revert. A test that can't fail is void.
3. **Implement minimally** — only what the failing test demands.
4. Run harness → **GREEN (0 fails)**.
5. **Safeguards:**
   - The rule lives in **ONE pure function** (single source of truth) reused by every call site.
   - Any new `enum` gets a **`CaseIterable` universe guard** test (a new case can't be silently unhandled).
   - **Never** claim a behavior "already exists" without a green test proving it.
   - No speculative UI / scope the user didn't request (see `no-speculative-ui`).
6. **Build green** (`BuildProject`) — compiles the harness + all surfaces.
7. **`scripts/check_arch_map.sh` green.**
8. **Update `ARCHITECTURE_MAP.md` AND `ASSUMED_PRESENT.md`** for the sub-step (symbol, what, test, status).
9. **USER STEPS** — add to `USER_TEST_LIST.md` the exact on-device steps the user takes to *use and
   verify* this feature (tap-by-tap: where to go, what to do, what they should see). Plain language.
10. **EXACTING BUILD DETAIL** — record a precise technical note (in `ASSUMED_PRESENT.md` or a build-log
    section) at the depth I actually understand it: the symbol(s), every file/call-site touched, the
    behavior + precedence + edge cases, the data flow, and *why* it's correct. Auditable by a stranger.
11. **Commit + push** with a message stating the change, the tests, and red→green.

## C. Honesty / reporting
- State build-verified vs harness-proven explicitly. If a step was skipped or a test is device-only,
  say so. Report failures with the actual output. Never soften.
- If the gate was deviated from (e.g., impl + test together), **self-flag it and remediate** before moving on.

## D. Self-audit (run mentally at the end of each sub-step)
> Did I: prove RED → implement → GREEN → prove teeth (if behavioral) → centralize to one SSOT →
> guard new enums → build green → arch-guard green → update MAP + ASSUMED_PRESENT → commit?
> If any answer is "no" → not done; fix it now.

## E. Standing project rules (carry across all builds)
- iOS/iPadOS only; build for iPhone sim, never My Mac. `@Observable`, not Combine.
- Trade-timing: only 05:00/13:00/21:00 shifts are tradeable.
- Never edit `*.pbxproj` directly (harness-blocked); ask the user / use Xcode.
- New `.swift` files now auto-compile (Sources/ is a synchronized Xcode folder group).
- Harness: `TradeEngineTests.runAll()` via `RunCodeSnippet` on
  `BATMANReader/Sources/Support/EngineTests.swift`; build via `BuildProject`.

## F. Round-3 build order (from SPEC_ROUND3.md — tick as shipped)
- [x] **A8** no-profile → Bookends Only
- [~] **D1** unified calendar — sub-steps:
  - [x] D1/F1 stable per-worker color (`TradeColors.forWorker`)
  - [ ] G2a peer-name resolution (`TradeNames.resolved`)  ← in progress
  - [ ] D3 selected-day chips (all surfaces)
  - [ ] D4 Just-2 "Propose to {Name}" when count==1
  - [ ] G2b intent-color legend on two-way; G2c full peer-intent palette
  - [ ] the unified `TradeCalendar` component
- [ ] **C1** staged-commit save-flow
- [ ] **A1/A2/A3/G3/H1** Lucky button + Master Filter + desirability score
- [ ] **G4** import-success audit
- [ ] **B1** qual-swap international flow · **A6** qual-in-n-way · **B2** package merge
- [ ] **E1/E2/E3** channel thread + statuses + settings colors
- [ ] **Deferred:** H2 person-prior (θ=0), H3 recognition badges
