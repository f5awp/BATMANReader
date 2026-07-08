# BATMAN Watcher — Build 4 / Build 5 Specification & Build Contract

> **This is the single source of truth for Build 4 (and the spec for the deferred Build 5 features).**
> Read §0 and §1 **before every build session** and re-run §1's checks after **every** sub-step.
> Nothing here is "done" until its **Definition of Done** (§1.3) is fully green.

---

## 0. How to use this document
1. Pick one **sub-step** (never a whole theme at once).
2. Follow the **per-item lifecycle** (§1.3): RED test → prove teeth → implement → GREEN → all gates → docs → commit.
3. Honor every **global invariant** (§1.2) — these must never regress, regardless of what you're building.
4. Update the **status** column (§2/§3) and the trackers (`ARCHITECTURE_MAP.md`, `ASSUMED_PRESENT.md`, `USER_TEST_LIST.md`).

---

## 1. Build contract — failsafes & checks (reference every time)

### 1.1 Process gates (run per sub-step, in order)
| # | Gate | How | Pass condition |
|---|------|-----|----------------|
| G1 | **Fail-test-FIRST** | Write the RED test for the exact behavior; run harness | Test is RED for the right reason |
| G2 | **Prove teeth** | Temporarily break impl → confirm RED → revert | Test flips RED↔GREEN with the impl |
| G3 | **Build green** | `BuildProject` (iPhone sim destination) | 0 errors |
| G4 | **Harness green** | `TradeEngineTests.runAll()` via `RunCodeSnippet` on `EngineTests.swift` | ✅ ALL GREEN |
| G5 | **Arch-guard green** | `bash scripts/check_arch_map.sh` | passed |
| G6 | **Docs updated** | ARCHITECTURE_MAP + ASSUMED_PRESENT + USER_TEST_LIST | entry added/updated |
| G7 | **Living references updated** | **`ARCHITECTURE_MAP.md`** (code map) + **ASSUMED_PRESENT** (§1.5) | map + assumptions current |
| G8 | **Commit** | branch off `main`; message ends `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` | committed (push only when asked) |

### 1.5 Living references — update EVERY session (do not skip)
- **Code Map = `ARCHITECTURE_MAP.md`** (the existing "WHERE index"; domain file map in
  `PROJECT_BLUEPRINT.md` §5). Before hunting through code, **consult it first** so you jump straight to
  the file → symbol instead of re-reading the whole codebase. **Whenever you locate, add, move, or
  rename a symbol, update its row there in the SAME pass** — do not create a second map. Its guard,
  `scripts/check_arch_map.sh`, fails on stale references.
- **Assumptions (ASSUMED_PRESENT.md).** **Every assumption you make while building MUST be recorded**
  there (what you assumed → why suspect → how to discharge → status). Never rely on an unrecorded
  assumption. When an assumption is proven/disproven, update its status the same session.

### 1.2 Global invariants (must hold after EVERY sub-step — regression failsafes)
- **INV-1 Hard gates immutable.** Qualification, 8-hour rest, weekly-hour cap, Blackout (keep/must-be-off),
  relief horizon, and bookend/no-split are enforced ONLY via `TradeEligibility.canCover`. No item may
  duplicate, weaken, or bypass them. (Guarded by U1-regression + T5/T6.)
- **INV-2 Result-neutral unless intended.** A change labeled "refactor/perf/UI" must NOT change which
  trades appear or their order. Proof = full harness stays GREEN + a before/after feed spot-check.
- **INV-3 Decode-back-compat.** Every new persisted/synced field is **optional with a default**; old
  records must still decode. Add a round-trip decode test for any model change.
- **INV-4 Empty-fetch never wipes.** Any new CloudKit fetch path routes through
  `FetchMerge.keepCacheOnEmpty` (an errored/empty fetch must never clobber a non-empty cache).
- **INV-5 No `.pbxproj` edits / new files.** New code goes in existing compiled files (rule #13).
- **INV-6 iOS/iPadOS only.** Build/run on an iPhone simulator, never My Mac.
- **INV-7 No speculative UI.** Build only what a spec item authorizes; no extra layers/toggles.
- **INV-8 Arch-guard literals.** No `[0-9]-person (swap|trade)` literals — spell out ("two-person").
- **INV-9 Sync-vs-edit safety.** A background sync write must never clobber the user's unsaved
  editing session (respect Save-or-Discard, TR3-C1.2) — merge by LWW, don't overwrite dirty local state.
- **INV-10 Notification consent.** No push is sent to a user who hasn't opted in where an opt-in exists.

### 1.3 Definition of Done (per item)
An item is DONE only when: G1–G7 pass · every acceptance criterion is met · every item-level
**Failsafe/check** is implemented & verified · INV-1…INV-10 still hold · the device-verify note (if any)
is added to `USER_TEST_LIST.md`.

### 1.4 Ordering guardrail
Do the **quick wins** first (§2 order). Do NOT start a High-risk item (B5) until its "pre-reqs" and
open questions (§4) are answered and it's explicitly greenlit.

---

## 2. BUILD 4 — build now

Effort: **S** ≤½d · **M** 1–2d · **L** 3–5d. Status: ☐ todo · ◐ in progress · ✅ done.

### Theme A — Terminology & intent sync

#### B4-1 — Rename "Want to Keep" + "Must Be Off" → "Blackout"  · S · ✅
**Decision applied:** keep the two intents **separate in the backend** (work-day keep vs off-day
must-be-off); both **display** as "Blackout". Tally bar shows **two chips, both titled "Blackout"**,
distinguished only by their existing colors/positions.

**Scope.** Display strings only in `TradeEngineModels.swift`
(`WorkingIntentState.mustWork.label`, `OffIntentState.mustBeOff.label` → `"Blackout"`), plus a UI sweep:
brushes, `IntentTallyBar`, two-way sheet legend, `IntentColorKey`, Help/Welcome copy. Enum cases + gates
**unchanged** (no data migration).

**Acceptance.** Every prior "Want to Keep"/"Must Be Off" now reads "Blackout"; both chips still show
independent counts; the keep-gate and must-be-off-gate behaviors are unchanged.

**Failsafes & checks.**
- RED test: `WorkingIntentState.mustWork.label == "Blackout"` && `OffIntentState.mustBeOff.label == "Blackout"`.
- INV-1: re-run T5/T6 gate tests — blacked-out working day never given away; blacked-out off day never offered.
- Grep guard: no remaining user-facing "Want to Keep" / "Must Be Off" strings (add to arch-guard if easy).
- No enum raw-value / persistence key changes (would break saved intents) — assert keys unchanged.

#### B4-2 — Intents follow the account across devices (full fidelity)  · M · ✅ (code; ⚠️ needs 1 deploy)
**Decision applied:** sync **day intents AND `DayNote`s (message/reason/topology)** via the
already-deployed `PrivateState` **private-DB** record (extend its JSON payload with an `intents` blob).
**No new CloudKit deploy.**

**Current state / root cause.** `DayIntentStore` persists to **UserDefaults only** — no CloudKit path.

**Design.**
- Extend `PrivateStateStore` payload with an `intents` blob (all intent sets + `DayNote`s) + an
  `intentsUpdatedAt` LWW clock.
- Publish on save (respecting the Save-or-Discard session — publish on Save, not per keystroke).
- On launch, `syncOnLaunch()` merges via `LWW.pick` into `DayIntentStore`.

**Acceptance.** Mark intents + a note on Device A → relaunch Device B (same Apple ID) → identical marks
+ notes; latest edit wins; never visible to other users.

**Failsafes & checks.**
- INV-3: round-trip encode/decode test incl. a legacy payload with **no** `intents` key (must decode → nil).
- INV-9: a sync arriving mid-edit must NOT overwrite unsaved local marks — test the merge respects the
  dirty flag; LWW only applies to saved state.
- INV-4: the fetch uses the private DB by fixed record name (no query) — confirm no empty-wipe path.
- Idempotency: syncing twice with no change is a no-op (no phantom "updated" bumps).
- Privacy: assert the intents blob is only ever written to `privateCloudDatabase`.

### Theme B — Blackout automation & availability

#### B4-3 — Blacklist choices mass-update the calendar (Blackout painting)  · M · ✅ (Home; pickers excluded by design)
> Consolidates raw items 2 + 12.

**Design.** Pure SSOT predicate `Blackout.isBlacklisted(shift:settings:) -> Bool` (in
`TradeEngineModels.swift`) true when a shift's desk/type/region/weekday ∈ the corresponding
`SettingsManager` blacklist set. Render a Blackout tint/glyph on matching days in `HomeCalendar`,
`ShiftSelectCalendar`, `AvailabilityView`, respecting existing intent precedence. Verify the matcher
already excludes blacklisted shifts (`wouldPickUp`) — this item adds the **visual** + a consistency check.

**Acceptance.** Add desk 82 / "PM" / Saturday → matching days show Blackout immediately (live, no
relaunch) and are never offered.

**Failsafes & checks.**
- RED unit tests for each dimension (desk/type/region/weekday) + a negative (non-blacklisted) case.
- INV-2: painting is display-only — confirm it does NOT alter match results (harness GREEN).
- Precedence test: a day that is both blacklisted AND has an explicit intent shows the correct
  (documented) precedence, deterministically.
- Live-update: changing a blacklist set updates the calendar without relaunch (`@Observable` path).

#### B4-4 — One-tap "Blackout weekends"  · S · ✅
**Design.** Trade Settings toggle adds/removes {1 Sun, 7 Sat} to `SettingsManager.blacklistedWeekdays`;
reflects via B4-3; publishes to profile.

**Acceptance.** On → Sat/Sun show Blackout + never offered; Off → restored; persists + publishes.

**Failsafes & checks.**
- RED test: toggle on → `blacklistedWeekdays ⊇ {1,7}`; off → those removed (without nuking other weekdays
  the user set manually — test it only touches 1 & 7).
- Depends on B4-3 (do B4-3 first).

#### B4-5 — Profileless users: infer accept-prefs from last 60 days worked  · M · ✅
**Decision applied:** **60-day** lookback, **soft** default (a real published profile always wins;
empty/short history → fall back to A8 bookends).

**Design.** Pure `InferredPrefs.from(entries:asOf:lookbackDays:60) -> (shiftTypes, regions)` scanning the
worker's actual recent shifts; extend `TradeProfile.defaultForUnpublished` so a profileless peer accepts
only shift types/regions they've worked in the window (blacklist the complement).

**Acceptance.** A profileless dispatcher who only worked AM/domestic in 60 days is only offered
AM/domestic-like pickups; empty history → today's A8 bookends behavior.

**Failsafes & checks.**
- RED tests: only-AM history → shiftTypes == {"AM"}; empty history → returns nil → A8 fallback (no over-restriction).
- INV-2: a peer WITH a published profile is unaffected (inference only applies to the A8 default path).
- Determinism: same history → same inference (no date-now nondeterminism; pass `asOf` in).
- Guard against a single-shift fluke over-narrowing (require a minimum sample, else fall back).

### Theme D — Trade UX & correctness

#### B4-8 — Calendar trade view shows name, not employee #  · S · ☐
**Design.** Route the offending calendar-trade label through `TradeNames.resolved(displayName:rosterName:workerID:)`
(SSOT, R3-G2a). Locate the call-site still printing `workerID` (in `HomeCalendar`/`AvailabilityView` trade overlay).

**Acceptance.** All names in the calendar trade view are real names; number only when no name exists anywhere.

**Failsafes & checks.**
- `TradeNames` already tested; add an assertion for the specific surface if a helper is introduced.
- Edge: all-digits/blank/`==id` display names must NOT be shown (already in `TradeNames` — verify the
  call-site passes the raw values, not a pre-resolved string). Device-verify.

#### B4-9 — Legend/key at the bottom of the calendar trade view  · S · ☐
**Design.** Pin a compact `IntentColorKey` (Trade-away · Want-to-work · **Blackout** · 📖 bookend ·
🔥 mutual · per-trader colors) at the bottom of the calendar trade view.

**Acceptance.** The trade calendar shows a readable key for every color/glyph it uses.

**Failsafes & checks.**
- Completeness: the key enumerates against the intent enums (`CaseIterable`), not a hand-list, so a new
  intent can't silently be missing from the key.
- Consistency: reuses the same hues as `DispatchPalette`/`brickColor` (no divergent color source).

#### B4-14 — Compact ECB-style card for 2-person swaps  · M · ✅
> Added 2026-07-07 (was omitted from the original 12). Testers prefer the ECB card's thinness — more
> results visible while scrolling.

**Decision applied:** 2-**person** trades render as a **custom, ECB-style compact card** (not the tall
`PackageCard`). It must be **thin**, show **"You get" and "They get" exactly once each** (no duplication
like `PackageCard`), show the counterparty's **name + status snapshot** (ECB-card style), let you **open
their schedule**, and keep **Propose**. 3+-person and circular trades keep `PackageCard`.

**Current state.** All feed results (2-way/multi/circular) use `PackageCard` (`TradeIntentsFeed.swift`).
ECB compact style lives in `ECBOfferRow` (`MessagingViews.swift`). The two-way schedule snapshot exists as
`MiniScheduleGrid` / the `TwoWaySheet` (`AvailabilityView.swift`).

**Design.**
- New `CompactSwapCard` (in `TradeIntentsFeed.swift`, near `PackageCard`) used **only** when
  `package.peopleCount == 2 && !package.isCircular`. `PackageCard` remains for everything else.
- Layout (thin): counterparty **name** (`TradeNames.resolved`, per-trader color) + **status snapshot**
  (their `statusBroadcast`, ECB-style) · one line **"You get: <days>"** · one line **"They get: <days>"**
  · badges (🔥 mutual / 📖 bookend / purple **Q** qual-swap) · trailing **Propose**. Tap → opens the
  two-way schedule view (their calendar) exactly as today.
- Feed routing (`TradeIntentsFeed` + `AvailabilityView`): choose `CompactSwapCard` vs `PackageCard` by the
  gate above. Single source for the choice (a small `@ViewBuilder` switch) so both feeds stay consistent.

**Acceptance.**
- A 2-person result shows a thin card: name + snapshot, "You get"/"They get" once each, Propose, badges.
- More cards fit on screen than before (visibly thinner than `PackageCard`).
- Tapping opens the counterparty's schedule; Propose behaves identically.
- 3+-person and circular trades are unchanged (still `PackageCard`).

**Failsafes & checks.**
- **INV-2 (headline):** this is a **presentation swap only** — the exact SAME 2-way packages appear, in
  the SAME order; only the card view differs. Harness stays GREEN; feed spot-check before/after.
- Pure gate test: `CompactSwapCard` is chosen iff `peopleCount == 2 && !isCircular` (and `PackageCard`
  otherwise) — add a tiny pure predicate `usesCompactCard(_:)` and test it (2-person→true; 3-person→false;
  2-cycle-circular→false; qual-swap 2-way→true).
- **No info loss:** every datum `PackageCard` shows for a 2-way is present on the compact card exactly once
  — give-days, take-days, name, badges (🔥/📖/Q), Propose, and the dev-only TradeScore line.
- **Qual-swap parity:** a 2-way qual-swap keeps its **Q badge** and **Propose→blast picker** path.
- **A11y:** Dynamic Type up to accessibility sizes — the thin card must not truncate "You get"/"They get"
  or the name; it may grow vertically at large sizes (thin is the default, not a hard clip).
- Reuse, don't fork: the name resolver, trader colors, snapshot, and Propose/open-detail actions are the
  **same** components `PackageCard`/`TwoWaySheet` use (no divergent second implementation).

### Theme E — Performance

#### B4-10 — Speed up trade search (engine refactor phase 2, SAFE ONLY)  · L · ☐
**Decision applied:** behavior-preserving optimizations only (no off-main-actor DFS).

**Design (measure first, apply incrementally).**
1. **Debounce** feed re-runs (SAVE / whatIf / normalMaxPeople) to the last within ~150ms.
2. **Precompute `givePromise` per entry** in the N-way DFS sort (stop recomputing in the comparator).
3. **Prune the candidate universe early** (skip peers with zero window overlap before two-way exploration).
4. **Cache day-maps** across a feed session when the roster is unchanged.

**Acceptance.** Measurable SAVE/Find latency reduction (dev timing log before/after); zero change to
results/order.

**Failsafes & checks.**
- INV-2 is the headline failsafe: **full harness must stay GREEN after each change** (proves result-neutrality).
- Add a before/after micro-benchmark snippet; record numbers in the commit.
- Debounce must not drop the FINAL search (test: rapid changes still end with the correct result).
- Cancellation still supersedes-not-races (existing `Task.isCancelled` path intact).

### Theme F — Bug fixes

#### B4-11 — Images can't be expanded  · S · ✅
**Design.** Shared tap-to-open full-screen zoom/pan viewer for inline images across posts, replies, and
1:1 chat (single render path so all three get it).

**Acceptance.** Tapping any image opens a full-screen pinch-to-zoom viewer with a close control.

**Failsafes & checks.**
- Nil-safe: a decode failure (`PostImage.decode` → nil) shows a graceful placeholder, never crashes.
- Reuse one component (no three divergent viewers).

#### B4-12 — Dev mode crashes while typing messages  · M · ☐
**Design.** Reproduce (dev unlocked → thread/channel → type). Pull the crash log (`GetCrashIssueLogs`),
find root cause (suspects: per-keystroke `@Observable` write, a force-unwrap in a `dev.unlocked` overlay,
formatter re-entrancy), fix, guard.

**Acceptance.** Typing with dev mode unlocked never crashes; fast typing / paste / emoji stable.

**Failsafes & checks.**
- Get the ACTUAL crash log before "fixing" (no guess-fixes).
- If root cause is pure (formatter/parse on input) → RED unit test on the crashing input.
- Regression: verify non-dev mode was and stays stable (isolate the dev-only path).

#### B4-13 — Tapping a thread opens the photo picker (should expand/minimize)  · S · ☐
**Design.** Separate the row's expand/collapse tap target from the composer `PhotosPicker`
(distinct `contentShape`/regions) so a row tap toggles expand/minimize; the picker opens only from the photo button.

**Acceptance.** Row tap expands/minimizes; picker opens only from the photo button.

**Failsafes & checks.**
- Hit-target test on device across sizes (Dynamic Type large — targets don't overlap).
- Regression: photo attach still works from its button (don't fix one by breaking the other).

---

## 3. BUILD 5 — fully spec'd, deferred (do NOT build until greenlit)

### B5-1 (was B4-6) — Conditional "open to trade" + passive auto-match notifications  · XL · High
**Decisions applied:** want-window is **flexible** (single date OR whole month OR custom day-set);
passive notifications are **OFF by default** (opt-in via `SettingsManager.tradeNotificationsEnabled`).

**Design.**
- Model `StandingTradeOffer { id, ownerID, giveDayID, wantSpec (enum: .date(String) | .month(String) |
  .days([String])), createdAt, active }`.
- **Public** CloudKit type `StandingTradeOffer` (JSON payload + flat **Queryable** `ownerID`, `giveDayID`,
  coarse `wantMonth`) → **schema deploy required** (see CLOUDKIT_DEPLOY.md).
- Client matcher on launch/refresh: pure `StandingMatch.candidates(offer:roster:profiles:) -> [TradePackage]`
  reusing `TradeEligibility.canCover` + two-way exploration (off on give-day AND working in want-window).
- Push a "Possible trade for you" via a new `CKQuerySubscription`, **gated by opt-in**; tap → pre-built trade.

**Failsafes & checks (pre-build gate + build-time).**
- INV-10: never notify a user with `tradeNotificationsEnabled == false`. Test the gate.
- INV-1: matches must pass all hard gates + the candidate's blacklist/Blackout (no unwanted matches fire).
- **De-dup:** never notify the same (offer, candidate) pair twice; per-user daily cap (`log()` when capped).
- Pure matcher tested with fixtures (valid reciprocal; blacklisted excluded; out-of-window excluded) BEFORE any sync/push wiring.
- Staged rollout behind a feature flag: (1) pure matcher → (2) storage+sync → (3) push. Each stage its own DoD.
- INV-3/INV-4 on the new record type; deploy schema + verify queries before Production relies on it.

### B5-2 (was B4-7) — Assisted / Simple mode (on-device AI intake)  · L · High
**Decisions applied:** **on-device** parsing (no network/key); **always confirm** (never auto-submit).

**Design.**
- Outlook-style free-text intake → on-device parser → structured `(giveDays, wantSpec)` → **preview** →
  user one-tap confirm → creates a `TradeRequest`/`StandingTradeOffer`.
- `TradeProfile.assistedMode: Bool` (rides JSON payload → **no deploy**); peers see an
  "Assisted mode — contact off-app" banner on that user's cards/threads.

**Failsafes & checks.**
- **Fail-safe parse:** low-confidence or ambiguous parse → route to manual edit, NEVER auto-fill-and-send.
- Confirmation is mandatory (no path sends without the preview confirm) — test it.
- Pure parser tests: several phrasings → correct `(giveDays, wantSpec)`; a garbage/empty input → no request created.
- INV-3: `assistedMode` optional-defaulted; old profiles decode.
- Banner renders for peers wherever that user appears (device-verify), and the app never fabricates an
  in-app accept handshake for an assisted-mode user.

---

## 4. Decision log (answers captured 2026-07-07)
| Q | Decision |
|---|---|
| Build 4 scope | Ship all except passive marketplace + assisted mode; those spec'd → **Build 5** |
| Blackout tally | Two chips, both titled "Blackout"; backend tracks work vs off separately |
| Intents sync | Full fidelity (marks + notes/reasons/topology) via `PrivateState` payload; no new deploy |
| Passive want-window | Flexible: single date / month / custom set |
| Passive notifications | **Off** by default (opt-in) |
| Assisted AI | **On-device** parse; always confirm (no auto-submit) |
| Inferred prefs | **60-day** soft default; profile overrides; empty → A8 bookends |
| Engine speed | Safe only (debounce + micro-opts); no off-main-actor DFS |
| 2-way card (B4-14) | 2-person swaps → custom **ECB-style compact card** (thin; "You get"/"They get" once; name+snapshot; open schedule; Propose). 3+/circular keep `PackageCard`. Presentation-only |

## 5. Suggested build order (Build 4)
1. **Quick wins:** B4-1 ✅ → B4-4 (after B4-3) → B4-8 → B4-9 → B4-11 → B4-13.
2. **Correctness/UX:** B4-3 (before B4-4) → B4-14 (compact 2-way card) → B4-12 (needs crash log) → B4-2.
3. **Smarts/perf:** B4-5 → B4-10.
Then Build 5 (B5-1, B5-2) once greenlit.

## 6. Remaining open questions (answer before the relevant item)
- **B4-12:** need the real crash log to pinpoint — capture on device with dev mode unlocked.
- **B5-1:** per-user daily notification cap value? Match on launch only, or also via background refresh?
  How long do standing offers live before auto-expiring?
- **B5-2:** which on-device parsing approach (NLTagger / heuristic grammar / small on-device model)?
  Acceptable accuracy bar before it ships?
- **B4-3:** exact precedence when a day is BOTH blacklisted and has an explicit intent — confirm the order.

---

## 7. Code Map → use `ARCHITECTURE_MAP.md` (do NOT duplicate here)
The project's code map is **`Documentation/ARCHITECTURE_MAP.md`** ("the WHERE index"), with a
domain file map in **`PROJECT_BLUEPRINT.md` §5**. Per §1.5 (gate G7), **consult ARCHITECTURE_MAP.md
before searching, and update it** (add/refresh the file → symbol row) whenever you locate, add, move,
or rename a symbol — same pass as the change. Its own guard (`scripts/check_arch_map.sh`) fails if a
referenced file/spec-ID/SOT symbol no longer resolves. This spec does not keep a second map.
