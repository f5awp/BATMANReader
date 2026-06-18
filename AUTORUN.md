# AUTORUN — autonomous build protocol

> **MODE: OFF** (disabled 2026-06-17 by user). Do **not** auto-resume the queue. Work one item at a
> time when the user asks; confirm direction normally. The queue + per-item loop below are kept as a
> reference checklist, not an instruction to run unattended.

## Per-item loop (Definition of Done — every item)
1. **Fail-test first** where logic exists: write the test/`universe`/`completeness`/`source-scan` guard
   that asserts the *exact* behavior; confirm it's red (or would be) before implementing.
2. **Implement** with the safeguards: model decisions as `CaseIterable` enums + exhaustive switches;
   single-source-of-truth functions; **new code goes in an EXISTING compiled file** (the synced group
   doesn't auto-pick-up new `.swift` files on an MCP build).
3. **Harness green** — run `TradeEngineTests.runAll()` via RunCodeSnippet → 0 failures.
4. **Build green** — `BuildProject` → no errors.
5. **Guard green** — `bash scripts/check_arch_map.sh`.
6. **Docs in the same pass** — update `ARCHITECTURE_MAP.md` (exact, enumerated — not "there is an X"),
   `USER_TEST_LIST.md` (a T# the user runs), and `NEXT_CHANGES`/`SPEC_*` if scope shifted.
7. **Assumptions** — anytime I'd say "already there" or take a shortcut, add a row to
   `ASSUMED_PRESENT.md` and **keep going** (per user) unless it has heavy downline impact on what I'm
   building — then pause that item, log it, and move to the next queue item.
8. Append a one-line entry to the **Autonomy log** and go to the next item.

## PAUSE conditions (stop and surface to the user)
- A genuine **product decision** I can't make at ~6-sigma confidence (ambiguous UX/policy with real
  downline impact). Log it under "Needs decision" and skip to the next buildable item.
- A **destructive / irreversible / outward-facing** action (deleting data, sending email/push to real
  people, deploying CloudKit schema, committing/pushing, changing bundle id/entitlements).
- A **build I can't get green in 3 attempts** → stop and report (do not blindly revert good code).

## Stale-incremental-link prevention (root cause, not self-heal)
The "Undefined symbol: TradeProfile.init(…old signature…)" linker error came from (1) the synthesized
**memberwise-init signature changing** every time a property was added, plus (2) **concurrent builds**
sharing one DerivedData leaving stale object files. Prevention:
- **Frozen init surface:** types that grow often (e.g. `TradeProfile`) now have an **explicit `init`**;
  new optional fields are set post-init and do NOT change the init symbol → callers stay valid.
- **One builder at a time:** the MCP build tools use Xcode's shared DerivedData, so a second
  concurrent agent/builder can corrupt incremental state. Run a single builder against this project.
- **Queue empty** → stop and report.

## Queue (ordered; tackle top-down, skip blocked, never silently drop)
1. **S-ENG-10** — Want-to-Work overrides bookend (one-sided) · Trade-away boost · two-sided bookend scoring.
2. **S-VALID** — invalid-trade detection + urgent alerts (rest of B3).
3. **H1** — top-of-Home metrics header (success% + search counts, month/year/all; admin reset).
4. **A1** — intents calendar parity + show others' intents + openness note.
5. **C4** — person search + pin (unified people dropdown).
6. **C6** — unified legend + tier separators across ranked lists.
7. **B5/B6** — image/GIF posting + emoji reactions.
8. **C2** — Individual Swaps redesign (marked give → bookends → others → more picks).
9. **R6 moderation reason** — admin moderate-with-reason (light italic).
10. **#12** status-line cross-device sync.
11. **I1** — guides + tone pass.
12. **G1–G3** — Outlook plain-text trade-board email + deep link (needs the real DL template → likely PAUSE for copy).
13. **Q1–Q6** — qual swaps (XL; has open sub-decisions → PAUSE points likely).

## Needs decision (parked — user resolves on return)
- **G1–G3 email:** real DL address + final template/copy + confirm Outlook send path.
- **B5/B6:** GIF source — photo-library only vs in-app GIF search (default: photo-library).
- **Q1–Q6 qual swaps:** desk→qual taxonomy beyond D/L/E/P; ranking/edge rules.
- **Leave codes `x`/`S`/`R`:** meaning (ARIS) before acting on them.
- **C6/H1/C2 visual hierarchy:** I ship sensible defaults; user can override the look.

## Deploy / manual (user-only, can't automate — I will NOT do these)
- Deploy CloudKit schema Dev→Prod (incl. new `PrivateState`) before TestFlight relies on it (#14).
- Commit/push git · archive+upload TestFlight · App Store Connect · bundle id/entitlements/signing.
- Send real trade-board email / push to real people.
- 2-device + "your eyes" checks in `USER_TEST_LIST` (T9,T10,T13,T15,T16,T17,T20,T21,T22,T24,T25…).

## Autonomy log (newest last)
- S-ENG-10 (Want-to-Work overrides bookend gate, one-sided; not over blacklist/Must-Be-Off) — `TradeProfile.wantToWorkDayIDs` + `wouldPickUp` + published from `DayIntentStore`. Tested ✅. Trade-away boost + two-sided bookend ranking deferred (ASSUMED_PRESENT #15).
- S-VALID (invalid-trade detection) — `TradeMatcher.staleDaysPure` (tested) + ThreadView URGENT red banner "trade is INVALID — delete/archive". Inbox-wide surfacing + auto-clear-on-reversal deferred (ASSUMED_PRESENT #17).
- H1 (Home metrics header) — `Metrics.successPercent`/`searchCount` (pure, tested) + `TradeHistoryStore.searchLog`/`recordSearch`/`completedCount`/`resetMetrics` + `HomeMetricsHeader` (success% + Month/Year/All search count, admin long-press reset) + search recorded on Find. Tested ✅. **LOCAL** metrics; GLOBAL CloudKit aggregation deferred (ASSUMED_PRESENT #18).
</content>
