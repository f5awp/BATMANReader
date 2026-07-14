# DX Match Radar — Implementation Spec (v2)

Surface mutual-intent matches directly on the Home calendar so a dispatcher can see — per day —
that an exact mutual match exists, drill in to the matched people, propose, flag days to watch, and
see when a day gains a new match.

Design-locked from the 2026-07-12 design + skeptical-review conversation. v2 supersedes v1: the data
source is a **dedicated deterministic query** (not the optimizer's `mutualPackages`), the "unseen"
state is a **local read-marker** (no CloudKit), refresh is an **explicit control**, matches live
behind a **layer toggle**, proposals **re-validate**, and **pinning is cut**.

---

## 0. Core principle & data source (THE critical decision)

A "match" for a day = a **2-way mutual deal exists** between me and a specific peer that involves that
day — real, eligibility-checked (qual/desk/timing + both blacklists), and directly proposable.

**Do NOT reuse `TradeRouter.intentSolutions` / `mutualPackages`.** That is a curated optimizer output:
it applies an acceptance-score **floor** (`finalize`, drops real matches), a **rank + cap at 60**,
**one bundled deal per peer**, and **3-way circular loops** (default `normalMaxPeople = 3`). Feeding
it to a per-day radar makes the count under-report and shift between refreshes with no intent change —
which would make the "new match" badge cry wolf.

### The dedicated radar query
Add a sibling to `intentSolutions`, e.g. `TradeRouter.radarMatches(excluding selfID:) async -> [RadarMatch]`:

- Iterate the **same candidate universe** the mutual path uses — active accounts, schedule-crossing,
  sorted by `workerID` (deterministic). Keep the `Task.yield()` per candidate so it never freezes.
- For each peer: reuse the existing **`twoWayExplore` + `assembleIntentDeal` + the `mutualOnly` gate**
  (≥1 day I marked AND ≥1 day they marked, both in the deal).
- **Omit** everything that curates: no circular-loop block, no `finalize`, no score-floor, no
  `intentResultCap`, no `intentCandidateCap` truncation (the mutual set is already pruned to active +
  schedule-crossing peers — the engine notes it's "already small"; confirm perf, keep the 300 safety
  bound only as a runaway backstop, and `log()` if it ever bites).
- Return one `RadarMatch` per surviving peer-deal: `{ peer(id,name), giveDayIDs, takeDayIDs }`.

Deterministic (sorted peers, deal built the same way each run), complete (no floor/cap), people-centric.

### Indexing
`MatchStore` builds `matchesByDay: [DayID: [RadarMatch]]` — for each deal, add it under every dayID in
`giveDayIDs ∪ takeDayIDs`. **Per-day count = distinct peers.**

| User combination | Where the day appears |
|---|---|
| I work a shift I marked **want-to-trade**, someone **wants to work** it | dayID ∈ a deal's `giveDayIDs` |
| I'm **off** a day I marked **want-to-work**, someone **wants to trade** it | dayID ∈ a deal's `takeDayIDs` |

---

## 1. Calendar cell markers

Behind a **"Matches" layer toggle** (see §6). Two orthogonal, colorblind-safe channels; all colors via
`AppColor` (no raw/neon).

### 1a. Match count badge (ambient — every match day)
- **Position:** top-trailing (the §10 slot). When present, the note/event dot moves to **top-leading**.
- **Color:** `AppColor.heat` (the Intents/trade hue — consistent, distinct from every tile color).
- **States:**
  | State | Appearance |
  |---|---|
  | N matches, all seen | **outline** heat circle, number `N` |
  | N matches, ≥1 new since last seen | **filled** heat circle, number `N` |
  | ≥1 match already has an in-flight request | see §3b — badge de-emphasized / marked "in motion" |
- Count = distinct peers. Fill = an **unseen** change (see §3). Cap label at `9+`. Self-contained chip
  (own background) so it's legible on any tile.

### 1b. Flag ring (user watchlist)
- Reuses the removed §10 decorative disc as a **user action**: a ring around the cell, `AppColor.heat`.
- Present only on flagged days. Independent of the badge (a flagged day still shows its count/fill).

### 1c. Layering
Outer→inner: flag ring (if flagged) · today blue inset ring (§10, if today) · tile glaze · number ·
count badge (top-trailing) · note/event dot (top-leading). All coexist.

### "What counts as a change"
A day's **distinct-peer set grows** (a peer appears that wasn't in the last-seen set). Reordering or
score changes do **not** count. Fill clears when the user opens that day's Matches tab.

---

## 2. Day detail — Matches tab

Tapping a day opens the existing day editor with a `DXSegmented`:
- **[ Info ]** — current day editor (intent / reason / note / vacation), unchanged.
- **[ Matches ]** — a list of **mini deal cards** (reuse the ECB card / `CompactSwapCard` + its
  `onPropose`). Each card = one counterparty + the swap summary + a **Propose** button.
  - **Default sort** by a sensible signal (acceptance likelihood / prior trade partners) so the best
    options are on top. **No manual pinning** (cut — a day realistically has 1–5 matches; nothing to
    scroll).
  - Cards reflect **request status** (§3b): a peer with an outstanding request shows **"Pending"**
    (Propose disabled), not a fresh Propose button.
  - Opening this tab calls `markSeen(dayID)` → clears unseen, re-saves the day's peer-set baseline.

---

## 3. MatchStore + correctness rules

`@MainActor @Observable final class MatchStore` (`MatchStore.shared`) — single source of truth;
calendar, stats bar, and Home list observe it → auto re-render on mutation.

### State
```
matchesByDay:   [DayID: [RadarMatch]]   // from radarMatches(), indexed per day
seenPeerSet:    [DayID: Set<WorkerID>]  // baseline "what I've seen"  — LOCAL ONLY
unseenDays:     Set<DayID>              // peer-set grew since last seen — LOCAL ONLY
flaggedDays:    Set<DayID>              // user watchlist — persisted LOCAL (v1; sync later if wanted)
lastRefreshed:  Date?                   // drives the "as of HH:MM" label
```
**No CloudKit schema changes in v1.** `unseen`/baseline are a local read-marker (see review #2);
flags persist locally. (Cross-device flag sync is a deliberate later add, not v1.)

### recompute(scope)
1. `.full` (new master) and `.intentsOnly` (manual refresh): `await TradeProfileStore.shared.refreshOthers()`
   (+ my-intent sync). `.full` piggybacks the existing master-import path; `.intentsOnly` pulls **only**
   intents — no messaging/ECB/history/schedule probe. `.local` (my own edit): pull nothing.
2. `let matches = await TradeRouter.radarMatches(excluding: me)`.
3. Index → `newMatchesByDay`.
4. Per day: if its distinct-peer set **grew** vs `seenPeerSet[day]` **and** the day isn't open → add to
   `unseenDays`.
5. Assign `matchesByDay`, recompute stats, stamp `lastRefreshed`.
- **`.local` touch-up:** on my own intent edit, adjust only the affected day(s) — drop a day whose
  underpinning intent was cleared; re-scan peers for a single newly-marked day. No network, no full pass.

### markSeen(dayID)
Remove from `unseenDays`; set `seenPeerSet[day]` = current peer set. Persist (local).

### 3b. Propose-time correctness
- **Re-validate on Propose tap:** `fetchProfile(forWorker:)` for that one peer, rebuild the 2-way deal;
  still valid → `sendRequest`; no longer valid → block, toast "This match just changed," refresh that
  day's cards. One fetch, no stall.
- **Request-status reflection:** cross-reference `MessagingStore.requests`. A (day, peer) with an
  active request → card shows **Pending**; the day's badge is de-emphasized/marked so in-flight trades
  don't read like fresh, un-actioned matches (prevents duplicate proposals; keeps radar consistent
  with the Trades › Intents feed).

---

## 4. Refresh model

| Trigger | Scope | Recompute | Notes |
|---|---|---|---|
| App launch | seed | ✅ | reuse the launch precompute slot; run `radarMatches` under the existing loader |
| Foreground (no new master) | — | ❌ **never** | foreground stays as fast as today |
| **Refresh control** (visible button by the calendar header) | `.intentsOnly` | ✅ | spinner + updates the **"as of HH:MM"** label; intents only |
| Home **matches list** pull-to-refresh (optional) | `.intentsOnly` | ✅ | a list IS a feed — no gesture conflict there |
| **New master imported** (`rosterRows > 0` / `diff.hasChanges` in the existing launch + `foregroundRefresh` probe) | `.full` | ✅ | automatic, ~3×/day; hooks next to `autoCompleteProvenTrades` |
| My own intent edit | `.local` | local touch-up | no network, no stall |

**No pull-to-refresh on the calendar itself** — it's a scrolling month/week stream, so a pull-down
collides with scroll-to-earlier-months, and calendars aren't a pull-to-refresh idiom. Use the explicit
button; it also carries the freshness label (matches are intentionally stale between manual refreshes).

---

## 5. Stats

- **Global stats bar:** exactly **one** new counter = total **match-days** on the calendar.
- **Home page:** three tappable stat chips — **matched / unchecked (unseen) / flagged** — quiet dot-led
  style (month-header / IntentTallyBar treatment). Tapping opens a **matches list** filtered to that set
  (All / Unseen / Flagged). Consider hiding the chips at zero rather than showing "0 matched" noise.
- **Matches list → tap a date → calendar scrolls/pages to that day/month** (selected-month binding /
  ScrollViewReader on the calendar).

---

## 6. Layer toggle

Add **"Matches"** to `LayerVisibility` (alongside `notes` / `intentOverlays`). When off, the calendar is
clean (badges + flag rings hidden). Default **on** (prominent), but toggleable so users can calm the
cell and so the radar reads as a deliberate, manually-refreshed mode rather than a live overlay.

---

## 7. Reuse map

| Need | Existing asset |
|---|---|
| Per-peer 2-way deal build | `TradeMatcher.twoWayExplore` + `assembleIntentDeal` + `mutualOnly` gate (inside `intentSolutions`) |
| Single-peer profile fetch (propose re-validate) | `TradeProfileStore.fetchProfile(forWorker:)` (AvailabilityView.swift:1415) |
| Propose | `MessagingStore.sendRequest` (via the feed's `propose`) |
| Request status | `MessagingStore.requests` |
| Mini card | ECB card / `CompactSwapCard` (`onPropose`) |
| Peer intents pull | `TradeProfileStore.refreshOthers()` |
| My per-day intents | `DayIntentStore` |
| Segmented control | `DXSegmented` |
| Corner marker language | §10 `NoteMarker` / `EventMarker` |
| Layer gating | `LayerVisibility` |
| Master-import hook | `foregroundRefresh` `rosterRows > 0` branch + ContentView:186 |

---

## 8. Build order (suggested)
1. `TradeRouter.radarMatches` + a unit test (determinism: same inputs → same set; completeness: a
   floored-out `intentSolutions` match still appears here).
2. `MatchStore` (index, unseen read-marker, recompute scopes, `.local` touch-up) + persistence (local).
3. Calendar markers behind the Matches layer (badge + flag ring + layering with §10).
4. Day-detail Matches tab (cards, default sort, status reflection, `markSeen`).
5. Propose re-validation.
6. Explicit refresh control + "as of HH:MM"; new-master `.full` hook.
7. Stats: global counter + Home chips + matches list + tap-to-scroll.

## 9. Non-goals (v1)
- No push notifications for new matches (revisit later; needs client recompute — see review #2).
- No card pinning.
- No CloudKit schema changes / cross-device sync of flags or unseen state.
- No circular / N-way trades on the calendar (they stay in Trades › Intents).

---

## 10. Verified code map (anchors — **verified 2026-07-12**, re-grep before use)

Every symbol this feature builds on, confirmed present at the line noted. These are load-bearing; if a
re-grep before a step shows a signature has drifted, STOP and update this map — do not code to memory.

| Symbol | Location | Signature / shape (as verified) |
|---|---|---|
| `TradeRouter.intentSolutions` | TradeRouter.swift:623 | `(excluding:generation:lucky:mutualOnly:) async -> [TradePackage]` — the OPTIMIZER (do not reuse for radar) |
| `TradeRouter.assembleIntentDeal` | TradeRouter.swift:575 | `(_ p: IntentPairing) -> (gives:[String], takes:[String], mutualMarked:Int)?` |
| `TradeRouter.IntentPairing` | TradeRouter.swift:562 | struct: `myGiveMarked/myGivePref/theirGiveMarked/theirGivePref: [String]` |
| `TradeMatcher.twoWayExplore` | TradeMatcher.swift:476 | `(withWorker:name:windowStart:windowEnd:mySeeking:theirSeeking:myProfile:theirProfile:myID:ignoreOwnBlacklist:preloadedMine:preloadedPeer:) async -> TwoWayPlan` |
| `MatchContext.build` | called TradeRouter.swift:625 | `(selfID:) async` → `ctx.{maps, rosterMeta, profilesByID, universe, mineEntries, priors, start, end, profile(for:name:)}` |
| **Local closures in `intentSolutions`** | TradeRouter.swift:634–670 | `wouldTake`, `schedulesCross`, `anchoredSet`, `dayUrgency`, `urgency` — **NOT reusable** (see §11 step 1 decision) |
| `TradeProfileStore.refreshOthers` | TradeProfile.swift:427 | `() async` — pulls all peer profiles (CloudKit `fetchAll`) |
| `TradeProfileStore.fetchProfile(forWorker:)` | TradeProfile.swift:549 | `async -> TradeProfile?` — single-peer network fetch (propose re-validate) |
| `TradeProfileStore.profile(forWorker:)` | TradeProfile.swift:510 | `-> TradeProfile?` — sync, from local `others` |
| `TradeProfile.seekingDayIDs / wantToWorkDayIDs / opennessLevel` | TradeProfile.swift ~79/102 | `Set<String>` / `Set<String>?` / enum |
| `DayIntentStore.seekingDayIDs / wantToWorkDayIDs / intentsRevision` | DayIntentStore.swift | derived `Set<String>` / revision Int |
| `MessagingStore.sendRequest` | Messaging.swift:823 | `(to:toName:note:take:give:origin:) async` |
| `MessagingStore.requests` / `status(of:)` | Messaging.swift:530 / :1001 | `[TradeRequest]` / `-> TradeRequestStatus` |
| `propose(_ pkg:)` | TradeIntentsFeed.swift:378 | fires `sendRequest` per assignment |
| `CompactSwapCard` | TradeIntentsFeed.swift | has `onPropose: (TradePackage)->Void` |
| `TradeFeedCache.intentMatchCount` | TradeIntentsFeed.swift:36 | drives the Intents badge |
| Global stats bar `TradeStatsBar` | ContentView.swift:287 (rendered :80) | where the ONE new counter goes |
| `LayerVisibility` | HomeView.swift:29 | fields: `notes, intentOverlays, availability, shiftType, deskAssignments` → **ADD `matches`** |
| Home cell markers (§10) | HomeCalendar.swift | `noteDot`, `NoteMarker`, `EventMarker`, `numberColor`, `borderColor` |
| Calendar tap | HomeView.swift:266–299 | `onTap(dayID,isOff)` → `handleTap` → `DayEditTarget` sheet |
| New-master hook | ContentView.swift:186 + `foregroundRefresh` `rosterRows > 0` | where `.full` recompute attaches |
| Launch precompute slot | ContentView.swift:192–203 | where the radar seed runs under the loader |
| Existing engine tests | EngineTests.swift | **must stay green after any engine touch** |

### Assumptions ledger (each must hold; re-check if a step fails)
1. The mutual candidate set is small enough to run **uncapped** (engine comment says active+schedule-crossing is "already small"). — *Risk if wrong:* refresh latency. *Mitigation:* keep the 300 safety backstop; `log()` if it bites; measure in step 1.
2. `twoWayExplore` + `assembleIntentDeal` are **deterministic** for fixed inputs. — *Risk:* flapping unseen. *Mitigation:* step-1 determinism test (run 2× → identical).
3. `TwoWayPlan` exposes `iGive`/`iTake` legs with `.dayID`/`.wanted`/`.bookend` (as used at TradeRouter.swift:723–729). — *Verify by reading the block before mirroring it.*
4. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` still holds → matcher is main-actor; radar recompute needs the same `Task.yield()` cadence to avoid freezes.

---

## 11. Per-step fail-safes

Each step: **Preconditions** (re-grep/read before touching) → **Guardrails** (constraints while editing)
→ **Gate** (must pass to proceed) → **Rollback**. A step is not "done" until its Gate passes.

**Step 1 — `TradeRouter.radarMatches` + tests**
- *Precondition:* re-read `intentSolutions` lines 623–758 and `TwoWayPlan` leg fields; confirm §10 anchors.
- *Decision (document in code):* the helper closures are local. Choose **duplicate the minimal 2-way body
  into `radarMatches`** (lower blast radius) over refactoring `intentSolutions` (touches a tested hot path).
  If duplication would drift, extract a `private static` helper used by *both* — but only if EngineTests
  stay green.
- *Guardrails:* additive only — **do not edit `intentSolutions`, `finalize`, or `TradePackage`**. New type
  `RadarMatch` is new, `Sendable`, no engine mutation.
- *Gate:* `BuildProject` clean **AND** the **existing EngineTests pass unchanged** **AND** two new tests
  pass: (a) *determinism* — `radarMatches` twice → identical; (b) *completeness* — a fixture where a real
  mutual match sits below `floorNormalProb` is **absent from `intentSolutions` but present in `radarMatches`**.
- *Rollback:* delete the new function + tests; nothing else references it yet.

**Step 2 — `MatchStore`**
- *Precondition:* confirm `@Observable`/`@MainActor` store pattern from `DayIntentStore` / `TradeFeedCache`.
- *Guardrails:* new file only; local persistence via the same mechanism `DayIntentStore` uses; **no CloudKit**.
  Pure indexing; the unseen rule is "distinct-peer set grew," nothing else.
- *Gate:* build clean; a store unit test — seed A→{p1}; recompute A→{p1,p2} ⇒ A ∈ unseen; `markSeen(A)` ⇒
  A ∉ unseen; recompute A→{p1,p2} again (no growth) ⇒ A stays seen.
- *Rollback:* delete file; not yet referenced by any view.

**Step 3 — Calendar markers behind the `matches` layer**
- *Precondition:* re-read the §10 cell body (badge slot, `noteDot`, `numberColor`, `borderColor`).
- *Guardrails:* **gated by `layers.matches` (default on)**; when off, cell renders exactly as today. Do not
  touch tile color / number legibility rules / today ring / §10 dots except to move the note dot to
  top-leading *only when a badge is present*. §8 floating magnifier: DO NOT TOUCH.
- *Gate:* build clean; visual check **light + dark**; with `matches` OFF the cell is pixel-identical to
  pre-change; badge legible on navy / gold / teal / graphite tiles.
- *Rollback:* the layer flag makes this instantly reversible (toggle default off / remove overlay).

**Step 4 — Day-detail Matches tab**
- *Precondition:* read `handleTap`/`DayEditTarget` + `CompactSwapCard`/ECB card `onPropose`.
- *Guardrails:* add a `DXSegmented` [Info | Matches]; **Info tab must be the untouched existing editor**.
  Reuse the existing card; no new proposal path yet (Propose wired in step 5).
- *Gate:* build clean; opening Info shows the identical current editor; Matches lists the store's cards;
  `markSeen` fires on Matches appear (store test hook).
- *Rollback:* remove the segmented wrapper → editor returns to its current single view.

**Step 5 — Propose re-validation + status**
- *Precondition:* confirm `fetchProfile(forWorker:)` (:549), `sendRequest` (:823), `status(of:)` (:1001).
- *Guardrails:* on Propose, re-fetch that ONE peer, rebuild the 2-way deal, send only if still valid; else
  block + toast. Cross-ref `MessagingStore.requests` → show Pending. **No change to `sendRequest` itself.**
- *Gate:* build clean; manual: propose a valid match sends; a day with an existing request shows Pending
  (no duplicate send path reachable).
- *Rollback:* revert the card's action closure; matching/markers unaffected.

**Step 6 — Explicit refresh control + new-master `.full`**
- *Precondition:* read `foregroundRefresh` + ContentView:186/192–203.
- *Guardrails:* **do NOT add recompute to the plain foreground path** (locked). Button → `.intentsOnly`;
  new-master branch → `.full`. Show spinner + "as of HH:MM". Keep `Task.yield()` cadence.
- *Gate:* build clean; foreground with no new master triggers NO recompute (add a debug counter / log to
  prove it); button and new-master both recompute; UI never blocks (spinner shows).
- *Rollback:* remove the button + the one `.full` call; auto behavior returns to today's.

**Step 7 — Stats (global counter + Home chips + list + tap-to-scroll)**
- *Precondition:* read `TradeStatsBar` (:287) + `IntentTallyBar` style + calendar scroll/anchor model.
- *Guardrails:* ONE global counter; three Home chips read from the store (derived, no new state); list
  reuses cards; tap-to-scroll uses the existing month-anchor mechanism.
- *Gate:* build clean; counts equal `matchesByDay` cardinality; tapping a date scrolls the calendar to it.
- *Rollback:* additive views; remove to revert.

---

## 12. Systemic anti-hallucination / anti-regression protocol

Applies to **every** step, in addition to its own Gate.

1. **Grep-before-use.** Never write a call to an API from memory. Before referencing any symbol, confirm
   it via grep/read against §10; if it moved or changed, update §10 first. New APIs I "expect" to exist →
   verify with `DocumentationSearch` (esp. any SwiftUI/Liquid Glass/Observation surface), never assume.
2. **Build gate.** `BuildProject` must return clean after each step; run `XcodeRefreshCodeIssuesInFile` on
   every touched file before declaring the step done. No "should compile."
3. **Regression gate.** After any change under `Sources/Domain/TradeEngine/`, the **existing EngineTests
   run unchanged and stay green**. If a test needs editing to pass, that's a red flag — stop and explain,
   don't "fix" the test to match new behavior.
4. **Blast-radius control.** Each step edits only its declared files (§11). No opportunistic refactors, no
   drive-by reformatting, no touching §8 magnifier or §9-ECB. If a step tempts an out-of-scope edit, note
   it and defer.
5. **Dark-by-default.** The feature is inert until wired: the engine query has no callers until step 2;
   the UI is behind `layers.matches`. At every step the app with the layer OFF must behave exactly as it
   does today — that's the guarantee nothing pre-existing regresses.
6. **Determinism as a test, not a hope.** Anything feeding the unseen badge is covered by a
   run-twice-identical assertion (step 1 + step 2 gates).
7. **No silent truncation.** Any cap/prune the radar applies (e.g. the 300 backstop) must `log()` when it
   bites — a silently-capped list reads as "complete" when it isn't.
8. **Honest reporting.** Compile-verified ≠ runtime-verified. Each step states exactly what was checked
   (built / unit-tested / seen light+dark on sim) and what wasn't. No claiming a visual/behavioral result
   that hasn't been observed running.
9. **One step, one pause.** Implement a step, pass its Gate, STOP for review before the next — matching the
   PARITY workflow. No batching steps.
10. **Spec is the contract.** If implementation forces a deviation from this doc, update the doc first and
    surface the change; the doc never silently diverges from the code.
