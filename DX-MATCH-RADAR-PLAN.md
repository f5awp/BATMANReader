# DX Match Radar — Staged Implementation Plan

**Companion to `DX-MATCH-RADAR-SPEC.md` (v3.1).** The spec is the *contract* (what/why); this is the *execution plan* (how/order/safety). If the two ever disagree, the spec wins — update it first (§ protocol).

**Status:** DRAFT — awaiting go-ahead per stage.
**Branch:** cut `match-radar` off the current branch (`build4-blackout-cards-sync`).
**Commit prefix:** `MATCH-RADAR Stage N: …` — one commit per stage, pathspec-scoped (never sweep unrelated files).

---

## Global rules (EVERY stage)

**Failsafe order per stage:** (a) re-grep the anchors this stage touches against the Code Map and update the map if any drifted; (b) make the change (only the declared files); (c) `XcodeRefreshCodeIssuesInFile` on each edited file → 0 errors; (d) `BuildProject` → success; (e) `TradeEngineTests.runAll()` via RunCodeSnippet → **0 failures**; (f) the stage's own **behavioral/gate check**; (g) **commit**; (h) **STOP** and report before the next stage.

- **Never proceed on red.** Failed build / harness failure / failed gate = fix or roll back that stage; do not start the next.
- **Dark-behind-the-layer-toggle.** The feature is inert until wired: the engine queries have no callers until the store lands; all UI sits behind `LayerVisibility.matches` (default on, but with it OFF the app must be pixel-identical to today). This is the master regression guarantee.
- **Data-model safety.** Every new field on a synced Codable (`TradeProfile`, `TradeRequest`) is **optional + defaulted**, set post-construction (frozen-init pattern). Old CloudKit records must decode. Everything rides the JSON `payload` — **no CloudKit schema/index change** in v1 (call it out explicitly if that ever stops being true).
- **Determinism is a test, not a hope.** Anything feeding a badge/notification has a run-twice-identical assertion.
- **No silent truncation.** Any cap the radar applies (e.g. the 300 candidate backstop) must `log()` when it bites.
- **EngineTests are the gate.** After ANY change under `Sources/Domain/TradeEngine/`, the existing tests run **unchanged** and stay green. If a test needs editing to pass, STOP and explain — do not "fix" a test to match new behavior.
- **Honest reporting.** Compile-verified ≠ runtime-verified. Each stage states what was checked (built / unit-tested / seen light+dark on sim) and what wasn't.

---

## Code map (anchors — re-verified 2026-07-15; RE-GREP before each stage that uses them)

Mirrors `DX-MATCH-RADAR-SPEC.md` §10. Load-bearing; on drift, STOP and fix the map first.

| Symbol | Location | Notes |
|---|---|---|
| `TradeRouter.intentSolutions` | TradeRouter.swift:711 | `(excluding:generation:lucky:mutualOnly:) async -> [TradePackage]` — OPTIMIZER, do NOT reuse for radar |
| `TradeRouter.assembleIntentDeal` | TradeRouter.swift:682 | `nonisolated (_ IntentPairing) -> (gives,takes,mutualMarked)?` |
| `TradeRouter.IntentPairing` | TradeRouter.swift:669 | struct |
| `TradeRouter.finalize` | TradeRouter.swift:1108 | floors `acceptanceScore >= floorNormalProb`, caps `intentResultCap` — **omit in radar/day-list** |
| `TradeRouter.rankLess` | TradeRouter.swift (finalize:1113) | the normal ranking — reuse for `dayTradeList` sort |
| `intentResultCap`/`intentCandidateCap` | TradeRouter.swift:940 / :944 | 60 / 300 (300 = backstop; `log()` if it bites) |
| `TradeMatcher.twoWayExplore` | TradeMatcher.swift:502 | main-actor wrapper |
| `TradeMatcher.twoWayExploreCore` | TradeMatcher.swift:523 | `nonisolated` PURE — add kind + accept-scope prune here; use for off-main recompute |
| `TwoWayPlan` / `TwoWayLeg` | TradeMatcher.swift:361 / :348 | leg: `dayID,date,desk,startHour,bookend,wanted` |
| `TradeEligibility.canCover` | TradeMatcher.swift | the "legal to work" gate (star + section A) |
| `MatchContext.build` | TradeRouter.swift:281 & :713 | `(selfID:) async` → ctx.{maps,universe,profilesByID,priors,start,end,…} |
| `TradeProfileStore.refreshOthers` / `.fetchProfile(forWorker:)` / `.profile(forWorker:)` | TradeProfile.swift:427 / :549 / :510 | all-peer / single-peer net / sync-local |
| `TradeProfile.seekingDayIDs / wantToWorkDayIDs / opennessLevel` | TradeProfile.swift:79 / :102 / :195 | **ADD** `tradeKindByDay`, `acceptScopeByDay` |
| `DayIntentStore` (seekingDayIDs :117 / wantToWorkDayIDs :127 / intentsRevision :24 / workingIntents :78 / offIntents :82) | DayIntentStore.swift | **ADD** `tradeKindByDay`, `acceptScopeByDay` |
| `WorkingIntentState.dontWantToWork` / `OffIntentState.wantToWork` | TradeEngineModels.swift:86 / :106 | marks the kind/scope attach to |
| `MessagingStore.sendRequest` | Messaging.swift:903 | `(…:origin:loopID:)` — radar proposes via `propose`; **ADD** optional `candidateDayIDs` |
| `MessagingStore.requests` / `status(of:)` | Messaging.swift:557 / :1120 | 2-way = single request |
| `propose(_ pkg:)` | TradeIntentsFeed.swift:389 | route proposes here (`origin: .intents`) |
| `CompactSwapCard` | TradeIntentsFeed.swift:741 | `onPropose:` — reuse for match/list cards |
| `ShiftSelectCalendar` | Sources/UI/Shared/ShiftSelectCalendar.swift | reuse for accept-scope date/range picker |
| `TradeStatsBar` | ContentView.swift:335 (rendered :83) | ONE new global counter |
| `LayerVisibility` | HomeView.swift:29 (fields :30–34) | **ADD `matches`** |
| Home cell markers | HomeCalendar.swift (`EventMarker` :61, `noteDot`, `numberColor`, `borderColor`) | disc/star/ring |
| Calendar tap | HomeView.swift:106 (`onTap: handleTap`) → :266 `handleTap` → :543 `DayEditTarget` | 2-tab day sheet |
| New-master hook | ContentView.swift:272 `foregroundRefresh` → :283 `rosterRows>0 && diff.hasChanges` | `.full` recompute |
| Launch precompute slot | ContentView.swift:183–193 | radar seed under the loader |
| `NotificationManager` | Sources/Services/NotificationManager.swift | watch/batched scheduling |
| `MessagingStore.broadcastsLastSeen` pattern | Messaging.swift:568–584 | mirror for the seen/watch read-markers |
| Existing engine tests | EngineTests.swift | stay green (incl. 8 `INBOX-*` + `OPS-QUAL`) |

---

## Assumptions ledger (each MUST hold; re-check if a stage's gate fails)

1. **Mutual candidate set is small enough to run uncapped** (engine comment: active + schedule-crossing is "already small"). *Risk:* refresh latency. *Mitigation:* keep the 300 backstop, `log()` if it bites, measure in Stage 3.
2. **`twoWayExploreCore` + `assembleIntentDeal` are deterministic** for fixed inputs. *Risk:* flapping star/badge. *Mitigation:* run-twice test (Stages 3–4).
3. **`TwoWayLeg` exposes `dayID/desk/startHour/bookend/wanted`** as listed. *Verify by reading the struct before mirroring it.*
4. **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** → the matcher is main-actor; radar recompute must keep the `Task.yield()` cadence (use `twoWayExploreCore` in `Task.detached`) to avoid UI freezes.
5. **Everything fits the JSON `payload`** (no queryable field needed) → no CloudKit Console deploy. *If any new field must be queried, that assumption breaks — STOP and flag.*
6. **`propose(_:)` sets `origin: .intents`** and produces a single 2-way request (no `loopID`) → consistent with the Trade-Inbox dedup/threading.
7. **Accept-scope prune only removes candidates** (never adds) → it shrinks work; sorting stays correct on a smaller set (Stage 2 gate proves shrink-only).

---

## Stage 0 — Baseline & branch
- `git status` clean; `BuildProject` green; `TradeEngineTests.runAll()` = 0. Cut `match-radar` branch. Record the baseline test count. **No commit** (checkpoint). **STOP.**

## Stage 1 — Model: `TradeKind` + `AcceptScope`
- **Files:** DayIntentStore.swift, TradeProfile.swift (+ a small `Sources/Domain/Intents` type file if cleaner).
- **Change:** `enum TradeKind { day, ecb, both }`; `struct AcceptScope { dates: Set<String>?; shiftTypes: Set<ShiftAvailabilityType>; quals: Set<String>; desks: Set<String>? }` (all optional/empty = open). Add `tradeKindByDay: [String: TradeKind]` and `acceptScopeByDay: [String: AcceptScope]` to `DayIntentStore` (persisted like existing intents) and to `TradeProfile` (post-construction, JSON payload).
- **Guardrail:** additive; unset/`nil` = **exactly today's behavior**. Do not touch the matcher yet.
- **Gate:** build + harness green; **`MATCH-MODEL` test** — a `TradeProfile` with kind+scope round-trips through the same `JSONEncoder`/`Decoder` the CloudKit layer uses; a profile with neither decodes (old-record back-compat).
- **Rollback:** revert; fields are additive/optional.
- **Commit:** `MATCH-RADAR Stage 1: TradeKind + AcceptScope model (+ codec test)`. **STOP.**

## Stage 2 — Engine: kind-compat + accept-scope prune
- **Files:** TradeMatcher.swift (`twoWayExploreCore`), TradeEngineModels/TradeRouter as needed for the kind-intersection helper.
- **Change:** in the taker path of `twoWayExploreCore`, add (i) **kind-compat** (giver-kind ∩ taker-kind ≠ ∅; drop the leg if disjoint) and (ii) **accept-scope prune** (O(1) set checks: shift type / qual / desk / date membership). Pure `TradeKind.resolve(give:take:) -> TradeKind?` helper.
- **Guardrail:** prune **removes** candidates only; no new search dimension. Do NOT edit `intentSolutions`/`finalize`/`TradePackage`. Keep `Task.yield()` cadence.
- **Gate:** build + harness green **unchanged**; **`MATCH-KIND` test** — disjoint kinds → no deal; intersect → deal with resolved kind; **`MATCH-SCOPE` test** — narrowing a scope yields a **subset** of the unscoped result (shrink-only), never a superset.
- **Rollback:** revert; matcher returns to today's behavior.
- **Commit:** `MATCH-RADAR Stage 2: kind-compat + accept-scope prune`. **STOP.**

## Stage 3 — Engine: `pickupsForMe` (star) + `radarMatches` (mutual)
- **Files:** TradeRouter.swift (new funcs + `RadarMatch` type), EngineTests.swift.
- **Change:** `pickupAvailableDays(excluding:) async -> Set<String>` (per-day existence: ≥1 other's Want-to-Trade shift legal for me, kind+scope compatible). `radarMatches(excluding:) async -> [RadarMatch]` (mutual, typed by kind; omit `finalize`/floor/cap/loops). Duplicate the minimal 2-way body rather than editing `intentSolutions` (blast-radius); extract a shared `private static` helper only if EngineTests stay green.
- **Guardrail:** additive; do NOT edit `intentSolutions`/`finalize`. `log()` if the 300 backstop bites.
- **Gate:** build + harness green; **`MATCH-DETERMINISM`** (both funcs twice → identical); **`MATCH-COMPLETE`** (a fixture match with `acceptanceScore < floorNormalProb` is absent from `intentSolutions` but present in `radarMatches`); **`MATCH-STAR`** (a hand-built fixture with one legal pickup → that day ∈ `pickupAvailableDays`; make it illegal → day drops out). Measure runtime (Assumption 1).
- **Rollback:** delete the funcs + tests; no callers yet.
- **Commit:** `MATCH-RADAR Stage 3: pickupsForMe + radarMatches (+ tests)`. **STOP.**

## Stage 4 — Engine: `dayTradeList(dayID:)` (sections A + B)
- **Files:** TradeRouter.swift, EngineTests.swift.
- **Change:** `dayTradeList(dayID:excluding:) async -> DayTradeList` — Section A (others' Want-to-Trade legal for me, `rankLess`-sorted) + Section B (others' Want-to-Work for that day). Single-day scope.
- **Gate:** build + harness green; **`MATCH-DAYLIST`** — determinism; a floored match still appears; section B lists want-to-work peers; A is `rankLess`-ordered (mutual→bookend→split).
- **Rollback:** delete func + test.
- **Commit:** `MATCH-RADAR Stage 4: dayTradeList sections A+B`. **STOP.**

## Stage 5 — `MatchStore` (state, recompute, seen/watch, persistence)
- **Files:** new `Sources/Data/MatchStore.swift`; EngineTests.swift for pure bits.
- **Change:** `@MainActor @Observable MatchStore.shared` with `pickupAvailableDays`, `matchesByDay`, `seenPickupDays`, `watchedDays`, `lastRefreshed`; `recompute(scope:)` (.full/.intentsOnly/.local), `markSeen(dayID)`, `setWatched(dayID:_)`. Local persistence mirroring `broadcastsLastSeen`. Pure helper `newlyGainedDays(old:new:) -> Set` for tests.
- **Guardrail:** new file; no CloudKit; not yet referenced by any view.
- **Gate:** build + harness green; **`MATCH-SEEN`** — seed day A empty → gains a pickup ⇒ A ∈ newly-gained; `markSeen(A)` ⇒ not new; recompute with no growth ⇒ stays seen. Watch set persists.
- **Rollback:** delete file.
- **Commit:** `MATCH-RADAR Stage 5: MatchStore`. **STOP.**

## Stage 6 — Calendar markers behind the `matches` layer
- **Files:** HomeView.swift (`LayerVisibility` + toolbar toggle), HomeCalendar.swift (markers).
- **Change:** add `matches` to `LayerVisibility` (default on). Significant day → **orange disc**; pickup-available → **star** (binary); watched → **ring around the star**. Layer per spec §1 (watch-ring · today-ring · significant-disc · number · star · note-dot).
- **Guardrail:** gated by `layers.matches`; with it OFF the cell is **pixel-identical to today**. Don't touch tile color/number legibility/today-ring/§10 dots except to reposition the note dot only when the star is present. **Do NOT touch the floating magnifier.**
- **Gate:** build clean; `XcodeRefreshCodeIssuesInFile` on both files; **visual check light + dark**; layer OFF = identical to pre-change; star/disc/ring legible on navy/gold/teal/graphite.
- **Rollback:** the layer flag makes it instantly reversible.
- **Commit:** `MATCH-RADAR Stage 6: calendar markers (disc/star/watch-ring)`. **STOP.**

## Stage 7 — Day 2-tab sheet (Trade List default + Info + scope calendar)
- **Files:** HomeView.swift (`DayEditTarget` presentation), a new day-detail view, reuse `CompactSwapCard`/`ShiftSelectCalendar`.
- **Change:** wrap the day editor in a `DXSegmented` **[Trade List | Info]**, Trade List default. Trade List = Section A cards (Propose per kind; Pending reflection) + Section B list + **Watch Day toggle**. Info = the untouched editor + the **accept-scope calendar** (dates/range + quals/shift pills).
- **Guardrail:** **Info tab is the byte-for-byte current editor** plus the scope control; no new proposal path yet (wired Stage 9).
- **Gate:** build clean; Info identical to today; Trade List renders the store's rows; `markSeen` fires on Trade List appear; scope edits persist (Stage 1 model).
- **Rollback:** remove the segmented wrapper → editor returns to single view.
- **Commit:** `MATCH-RADAR Stage 7: day 2-tab (Trade List + Info + scope calendar)`. **STOP.**

## Stage 8 — Mark Intents kind pills (both intents)
- **Files:** the Mark-Intents UI (HomeView / intent editor), DayIntentStore wiring.
- **Change:** Day · ECB · Both pill on Want-to-Trade AND Want-to-Work; writes `tradeKindByDay`; publishes via the profile.
- **Gate:** build + harness green; kind persists + publishes; default `.both`; **`MATCH-KIND-PUBLISH`** round-trip (a marked day's kind survives profile encode/decode).
- **Rollback:** revert the pill UI; model stays (harmless).
- **Commit:** `MATCH-RADAR Stage 8: kind pills on both intents`. **STOP.**

## Stage 9 — Propose (carries alternates) + inbox `Matches | Requests` split
- **Files:** MessagingViews.swift (inbox split + Matches lane + match detail §4c), Messaging.swift (`candidateDayIDs` on `TradeRequest`; seed the counter picker from it), TradeIntentsFeed `propose`.
- **Change:** top-level `Matches | Requests` segment; Matches lane (soonest-first) + tap-in match detail (their offer + sorted takeable days). **Propose from calendar/list/match carries `candidateDayIDs` (picked + alternates)**; recipient sees selection highlighted + alternates (counter via Trade-Inbox Stage 8). Proposing promotes a match → Intents request; re-validate the peer first.
- **Guardrail:** Requests sub-tabs unchanged; `candidateDayIDs` optional/defaulted; reuse the existing counter/package path.
- **Gate:** build + harness green; **`MATCH-ALT` test** — `candidateDayIDs` round-trips and the recipient counter picker is seeded from it; manual: propose a valid match sends + shows alternates; a day with an in-flight request shows Pending (no duplicate path).
- **Rollback:** revert inbox split + propose closure; markers/store unaffected.
- **Commit:** `MATCH-RADAR Stage 9: propose-with-alternates + Matches/Requests split`. **STOP.**

## Stage 10 — Notifications (watch per-match / batched)
- **Files:** MatchStore + NotificationManager.
- **Change:** watched day → a notification per newly-gained match/pickup; unwatched → one **batched, deduped** notification via the seen baseline. Fires only on `recompute` growth. Respect existing settings + lead time.
- **Guardrail:** do NOT recompute on the plain foreground path (locked). No server fan-out.
- **Gate:** build green; **prove** (debug counter/log) that foreground with no new master fires nothing; unwatched never one-push-per-item; watched fires per gain.
- **Rollback:** remove the notify calls; radar stays silent.
- **Commit:** `MATCH-RADAR Stage 10: watch vs batched notifications`. **STOP.**

## Stage 11 — Refresh control + new-master hook + stats
- **Files:** HomeView/ContentView (refresh button + `.full` hook + launch seed), TradeStatsBar, Home chips.
- **Change:** explicit **Refresh** button by the calendar header (`.intentsOnly` + "as of HH:MM"); launch seed under the loader; new-master `.full` hook next to `autoCompleteProvenTrades`. ONE global counter + Home chips (pickups / matches / watched) + tap-a-date-scrolls-calendar.
- **Guardrail:** NO recompute on plain foreground. Keep `Task.yield()` cadence.
- **Gate:** build green; foreground w/o new master → NO recompute (prove with a log); button + new-master both recompute; UI never blocks (spinner). Counts equal store cardinality; tap-to-scroll works.
- **Rollback:** remove button + `.full` call + stats; auto behavior returns to today's.
- **Commit:** `MATCH-RADAR Stage 11: refresh control + new-master hook + stats`. **STOP.**

---

## Test ledger (all in `TradeEngineTests.runAll()`, [] = pass)

| Tag | Stage | Asserts |
|---|---|---|
| `MATCH-MODEL` | 1 | TradeKind + AcceptScope round-trip; empty profile still decodes |
| `MATCH-KIND` | 2 | disjoint kinds → no deal; intersect → resolved kind |
| `MATCH-SCOPE` | 2 | narrowing scope → subset of unscoped (shrink-only) |
| `MATCH-DETERMINISM` | 3 | `pickupsForMe` + `radarMatches` twice → identical |
| `MATCH-COMPLETE` | 3 | a floored (`acceptanceScore < floorNormalProb`) match absent from `intentSolutions`, present in `radarMatches` |
| `MATCH-STAR` | 3 | one legal pickup ⇒ day ∈ `pickupAvailableDays`; make illegal ⇒ drops |
| `MATCH-DAYLIST` | 4 | section A `rankLess`-ordered; floored match present; section B lists want-to-work peers |
| `MATCH-SEEN` | 5 | gain ⇒ newly-gained; markSeen clears; no-growth stays seen |
| `MATCH-KIND-PUBLISH` | 8 | marked-day kind survives profile encode/decode |
| `MATCH-ALT` | 9 | `candidateDayIDs` round-trips; recipient counter picker seeded from it |

---

## Watch-list / risks
- **Assumption 1 (perf):** if uncapped mutual scan is slow, `log()` the backstop and consider a per-day short-circuit for the star (existence check, not full deal). Measure at Stage 3 before building UI on it.
- **Notification spam:** the ONLY safe default is batched+deduped; per-match is opt-in via Watch (Stage 10 gate proves it).
- **Over-constrained accept-scope:** default open; explicit empty-state copy ("No matches — your accept filters are narrow").
- **Cross-device:** star/watch/seen are local v1 (§9). Watch-sync via the `appPrefs` blob is a later add — do NOT bolt CloudKit on mid-build.
- **CloudKit:** v1 needs **no** schema deploy (all payload). Re-confirm before ship; if `candidateDayIDs` or kind ever needs a *query*, that changes (Assumption 5).
