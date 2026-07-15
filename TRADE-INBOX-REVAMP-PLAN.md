# Trade Inbox / Trade History Revamp — Staged Implementation Plan

**Status:** DRAFT — awaiting go-ahead per stage.
**Author:** engineering (with Claude in Xcode)
**Date:** 2026-07-14
**Branch:** work on `build4-blackout-cards-sync` (or a fresh `trade-inbox-revamp` branch off it).

---

## 0. Goals (from the user)

1. **Move "Trade Status"** off the top bar into the `•••` menu, renamed **"Trade History."**
2. **Trade History = DONE only.** A trade lands in History exactly when the **master schedule** flips to match it (existing B6-autocomplete). Everything not-yet-reflected — pending, negotiating, **and accepted-but-schedule-not-yet-changed** — stays **active in the Trade Inbox.**
3. **Inbox entry badge** = count of **active trades** (all still-live trades needing attention / awaiting the schedule).
4. **Per-tab count badges** on Intents / Search / ECB / Misc (today only ECB shows `(n)` as text).
5. **3-way (circular loop) shows once, in Search** — not twice in Misc. Deduped to **one card → one merged conversation thread** (all participants' counters + messages in one place).
6. **Fix the empty counter-offer + missing messages** in the conversation thread.
7. **Rich counter-offers** (calendar re-pick → a new package card in the thread you can accept/counter back). *(Bigger; last stage.)*
8. **(Optional) Retire the Min-Cost/N-Way engine toggle** — vestigial post-U-OBJ; keep "I'm Feeling Lucky."

### Invariant this plan relies on (confirmed 2026-07-14)
All **swap** matches (2-way + N-way + min-cost) are **circular reciprocal loops** — everyone gives and receives, net-zero. A 2-way is just a 2-person loop, so it uses the SAME unified model. **Exceptions, unchanged:** **ECB** (one-way; `isECB`, empty `takeDayIDs`) and **qual-swap bridges** (bridge moves desks, no reciprocal leg; carried in the `qualSwap` field). The dedup/merge logic below applies ONLY to circular-loop requests; ECB and qual-swap requests keep their existing single-request rendering.

---

## Global rules (apply to EVERY stage)

- **Failsafe order per stage:** (a) read the touched code fresh, (b) make the change, (c) `XcodeRefreshCodeIssuesInFile` on each edited file → 0 errors, (d) `BuildProject` → success, (e) run `TradeEngineTests.runAll()` via RunCodeSnippet → **0 failures**, (f) the stage's own **manual/behavioral check**, (g) **commit** with a `TRADE-INBOX:` prefix, (h) **STOP** and report before the next stage.
- **Never proceed on red.** A failed build, a harness failure, or a failed stage check = fix or roll back that stage; do not start the next stage.
- **Data-model safety:** any new field on a synced Codable model (`TradeRequest`/`TradeResponse`) MUST be an **optional with a default** and set via post-construction assignment (matches the existing frozen-init pattern at `Messaging.swift:203-212`), so old CloudKit records decode. Note any CloudKit Console schema deploy needed (queryable fields only).
- **Rollback unit:** one commit per stage → `git revert <stage-commit>` cleanly backs out a single stage.
- **No scope creep:** each stage changes only what it lists.

---

## Stage 0 — Baseline & safety net

**Purpose:** known-good starting point + capture current behavior so regressions are visible.

**Steps**
1. Confirm working tree clean (the four engine-fix files already committed as `47161f1`). `git status` → clean.
2. `BuildProject` → success. `TradeEngineTests.runAll()` → 0 failures. Record this.
3. Write down the CURRENT inbox behavior as the regression baseline:
   - tab source of truth: `InboxView.tabIndex(for:)` (`MessagingViews.swift:199-209`)
   - list build: `requestList` (`:258-276`) — sections Needs-your-reply / Incoming / Sent / Archived
   - dock buttons + badges: `DXMessagingDock.swift:40-93`
   - dashboard sheet: `ContentView.swift:120`, `TradesView.swift:138-176`
   - conversation: `MessagingViews.swift:727-758`; counter/respond/message: `Messaging.swift:951-1054`

**Failsafe check:** build green + harness green + notes captured.
**Commit:** none (checkpoint only). **STOP.**

---

## Stage 1 — Loop identity foundation (data)

**Purpose:** give every circular-loop send a shared `loopID` so (a) the N cards dedup to one and (b) the merged thread can gather responses across all the loop's request records. This is the backbone for Stages 5 & 6; no visible UI change yet.

**Changes**
1. `Messaging.swift` `TradeRequest`: add `var loopID: String? = nil` (optional, default nil → old records safe). Do NOT add it to the frozen `init` — assign after construction (per the existing pattern comment at `:200-202`).
2. `sendRequest(to:...chain:...)` (`Messaging.swift:826-853`): when `chain != nil` (a loop send), stamp the SAME freshly-generated `loopID` on every per-participant request created in that batch. The batch loop that fans out per participant is in the CALLER — `TradeIntentsFeed.swift:1652-1655`. So: generate one `loopID` in the caller before the `for pid in route.participants` loop and pass it into `sendRequest` (new optional param `loopID: String? = nil`), which assigns `req.loopID`.
3. For 2-way sends (`chain == nil`): leave `loopID == nil`. A 2-way is already ONE request — its own id serves as the group key. Add a computed helper `var groupKey: String { loopID ?? id }` on `TradeRequest` so downstream code has one grouping key for both cases.
4. Verify `loopID` survives CloudKit: check `CloudKitMessagingService` request encode/decode path. If it serializes the whole `TradeRequest` Codable into `payload`, `loopID` rides along automatically — CONFIRM by reading the encode. **If** there's a hand-rolled field map, add `loopID` to it. (This same check also settles the Stage 4 `origin`-persistence question — do both here.)

**Failsafe checks**
- Build + harness green.
- **Persistence probe:** add a temporary harness assertion (or RunCodeSnippet) that round-trips a `TradeRequest` with `loopID`/`origin` set through the SAME JSON encoder/decoder the CloudKit layer uses, and asserts both survive. Keep a permanent version of this as an `INBOX-CODEC` test in EngineTests.
- No behavioral/UI change yet — inbox looks identical.

**Rollback:** revert commit; `loopID` is additive/optional, nothing else depends on it yet.
**Commit:** `TRADE-INBOX: add loopID group key to TradeRequest (+ codec test)`. **STOP.**

---

## Stage 2 — Recategorize: correct tabs + new **Qual Swap** tab + rename Misc→Other

**Purpose:** proposals file where they were created; qual swaps get their own tab; the 3-way loop lands in **Search**.

**Confirmed source→origin mapping (2026-07-14):**
| Source | Sets | Belongs in |
|---|---|---|
| Intents feed swap/loop (`TradeIntentsFeed.swift:392,1653`) | `origin: .intents` | **Intents** |
| Solutions swap/loop (`AvailabilityView.swift:577,1554`) | `origin: .search` | **Search** |
| ECB (`AvailabilityView.swift:874`) | `ecb:…, origin: .ecb` | **ECB** |
| Qual-swap taker/giver (`AvailabilityView.swift:177,206`; `TradeIntentsFeed.swift:203`) | `qualSwap:…` + origin | **Qual Swap** (new) |
| Qual-swap **bridge blast** (I'm a candidate, not core party) | — | **Qual Swap** (new) |
| Counter reply (`Messaging.swift:959`) | `origin: request.inboxOrigin` | inherits |
| Legacy / `.manual` (old records, no origin) | nil | **Other** (renamed Misc) |

**Bug today:** `tabIndex` checks `if r.qualSwap != nil { return 3 }` (Misc) BEFORE the origin switch, so every qual-swap is dumped in Misc despite carrying a real `.intents`/`.search` origin. And loops lost `origin` on sync (Stage 1 fix).

**What's in Misc today = exactly:** (1) qual-swap requests, (2) qual-swap bridge blasts, (3) legacy `.manual`. NO live path produces a non-qual-swap `.manual`. So after splitting out Qual Swap, "Other" is empty for all new trades — a pure legacy catch-all.

**Tabs after this stage:** `Intents · Search · ECB · Qual Swap` (4). Tab 3 is simply **renamed** from "Misc" → "Qual Swap." Its existing contents (qual-swaps + bridge blasts + legacy `.manual`) stay put; legacy `.manual` records harmlessly sit under Qual Swap (no live path produces a non-qual-swap `.manual`).

**Key realization:** `tabIndex(for:)` is ALREADY correct once `origin` persists (Stage 1) — qual swaps → 3, bridges → 3, `.manual` → 3, and a circular loop (`qualSwap == nil`, `isECB == false`, `origin == .search`) → 1 (Search). So the only *structural* fix needed was Stage 1's origin persistence; this stage is mostly the rename.

**Changes**
1. `MessagingViews.swift:215-218` `DXSegmented`: rename the tab-3 label `"Misc"` → `"Qual Swap"`. Keep 4 tabs. (Optionally give tab 3 a more fitting AppColor.)
2. Update `emptyTitle`/`emptyMessage` (`:278-287`) tab-3 copy from "Nothing Here / Qual-swap bridge requests and other messages" → a Qual-Swap-specific title/message.
3. Confirm `tabIndex` unchanged logic still sends qual swaps + bridges + `.manual` → 3, and loops → Search (via Stage 1).

**Failsafe checks**
- Build + harness green.
- `INBOX-ORIGIN` test: synced Intents swap→Intents; Solutions swap→Search; loop→Search; ECB→ECB; qual-swap (`.search` origin)→**Qual Swap (3)**; bridge blast→3; nil-origin→3.
- **Behavioral:** tab 3 reads "Qual Swap" and holds the qual swaps; the 3-way now shows under Search.

**Rollback:** revert commit (label back to "Misc").
**Commit:** `TRADE-INBOX: rename Misc→Qual Swap; loops file under Search`. **STOP.**

---

## Stage 3 — Dedup circular-loop cards to ONE per loop

**Purpose:** the loop shows as a **single** card in each inbox section (Bug 1, visible half).

**Changes**
1. In `InboxView.requestList` (`MessagingViews.swift:258-276`), before rendering each section (`pending`/`handledIncoming`/`sent`/`archived`), collapse requests that share a `groupKey` (Stage 1) down to ONE representative per loop.
   - Representative choice: deterministic (e.g. lowest `toID`, or earliest `createdAt`) so it's stable across refreshes.
   - Keep the underlying per-participant requests available to the detail view (pass the whole group, or re-fetch by `groupKey`).
2. The dedup must be a pure helper (e.g. `MessagingStore.dedupeLoops(_ requests:) -> [TradeRequest]` or a view-local function) so it's **harness-testable**.
3. Card label for a loop: show it as the loop (e.g. "3-Person Swap" with participant count), not one counterparty's name. The existing card already renders "3-Person Swap · tap to view" — ensure the deduped card keeps that and shows an **aggregate status** (see Stage 4 status rule).
4. ECB and qual-swap requests: NOT deduped (they have no `loopID`; `groupKey == id`), so they render exactly as today.

**Failsafe checks**
- Build + harness green.
- New `INBOX-DEDUPE` test: given 2 requests with the same `loopID`, the deduper returns 1; given 2 unrelated requests, returns 2; given ECB/qual-swap (nil loopID), returns them untouched.
- **Behavioral:** the 3-way now shows **once** in Search Sent (was twice in Misc).

**Rollback:** revert commit (list reverts to per-request rows).
**Commit:** `TRADE-INBOX: dedupe circular-loop requests to one card per loop`. **STOP.**

---

## Stage 4 — Aggregate loop status + "active vs done" rule

**Purpose:** define the single status shown on the deduped loop card, and the active/done split that Stages 6–7 (History/Inbox) depend on.

**Changes**
1. Add a pure helper `TradeStatus.loopStatus(for group: [TradeRequest], responses:) -> StagingState` (or extend `DashboardCounts`/`StagingState` logic at `TradeEngineModels.swift:270-302`). Rule:
   - **Done** iff the master schedule proves it (existing B6-autocomplete: `Messaging.swift:256`+). Reuse that predicate — do NOT invent a parallel one.
   - Otherwise **active**, with a sub-label = the "weakest" leg (e.g. if any leg still pending → "Pending"; if all accepted but schedule not yet flipped → "Accepted").
2. The deduped card's badge (Pending/Replied/Accepted) reflects this aggregate, not one leg.

**Failsafe checks**
- Build + harness green.
- New `INBOX-LOOPSTATUS` test covering: all-pending→Pending; one-replied→Replied/active; all-accepted-not-reflected→Accepted/active; schedule-proven→Done.

**Rollback:** revert commit.
**Commit:** `TRADE-INBOX: aggregate loop status + active/done rule`. **STOP.**

---

## Stage 5 — Trade Status → "Trade History" (menu move + done-only) + Pending→Inbox

**Purpose:** Goal 1 & 2. History board shows DONE only; all active lives in the Inbox.

**Changes**
1. `DXMessagingDock.swift`: remove the `checklist` "Trade status" icon button (`:56-57`). Add a menu item to the `•••` menu (`:58-65`): `Button { showDashboard = true } label: { Label("Trade History", systemImage: "clock.arrow.circlepath") }`. Keep the `showDashboard` binding + `ContentView.swift:120` sheet.
2. Rename the sheet's view/title to **Trade History** (`TradesView.swift:138-176` `TradeDashboardSheet`). Filter its content to **Done only** (schedule-proven / marked-official). Remove the "Pending" section/tab from it.
3. Ensure every formerly-"pending"/"accepted-active" trade is reachable in the **Trade Inbox** (it already lists incoming/sent; confirm accepted-but-not-done trades appear as active there — they should, since they're not archived and not done).
4. Update any copy that referenced "Trade Status."

**Failsafe checks**
- Build + harness green.
- **Behavioral:** `•••` menu shows "Trade History"; opening it shows only DONE trades; no Pending section; active trades are visible in the Inbox.
- No orphaned references to the removed button (grep `Trade status`, `showDashboard`).

**Rollback:** revert commit (button returns, board unfiltered).
**Commit:** `TRADE-INBOX: Trade Status → Trade History (menu, done-only); pending routes to Inbox`. **STOP.**

---

## Stage 6 — Badges: per-tab counts + Inbox active-trades badge + unread tracking

**Purpose:** Goals 3 & 4, and the "notify on loop change" ask.

**Changes**
1. **Per-tab count badges** — `InboxView` `DXSegmented` (`MessagingViews.swift:215-218`). Compute a count per tab from the deduped, in-tab request groups for ALL 5 tabs (Intents/Search/ECB/Qual Swap/Other, per Stage 2). Render as a **badge**, not text. If `DXSegmented` can't show a trailing badge, either (a) extend `DXSegmented`/`DXType` to accept an optional per-option badge count, or (b) overlay the existing badge pattern (`DXMessagingDock.swift:77-93`) on the segment. Prefer extending `DXSegmented` cleanly. Remove the `ECB (n)` text.
2. **Inbox entry badge = active trades** — `DXMessagingDock.swift` inbox button currently badges `pendingIncoming + ECB pending`. Repoint to the **active-trades** count from Stage 4 (all live loops needing attention/awaiting schedule), still deduped per loop so a 3-way counts once.
3. **Unread tracking** — mirror the channel last-seen pattern (`Messaging.swift:544-560`): add per-trade (per `groupKey`) last-seen timestamps; a new response (counter/message/accept) after last-seen marks that loop "new." Opening the loop detail marks it seen. Surface as a dot on the card + inclusion in the tab/inbox badges. Persist last-seen in `UserDefaults` (and sync via the existing appPrefs blob if cross-device parity is wanted — optional).

**Failsafe checks**
- Build + harness green.
- New `INBOX-COUNTS` test: per-tab counts equal the number of deduped in-tab groups; ECB counts incoming ECB offers; active-trades count excludes Done and counts a loop once.
- New `INBOX-UNREAD` test: a response after last-seen → unread; opening → seen → not unread.
- **Behavioral:** all four tabs show number badges; inbox icon badge = active-trade count; a new counter bumps the badges and shows a dot.

**Rollback:** revert commit.
**Commit:** `TRADE-INBOX: per-tab + inbox active-trade badges + unread tracking`. **STOP.**

---

## Stage 7 — Merged conversation thread (fix empty counter + missing messages)

**Purpose:** Goal 5 (merged thread) + Goal 6 (bug). For a circular loop, ONE thread shows every participant's proposal, counters, and messages, in order, labeled by who.

**Changes**
1. **Gather across the loop:** in the detail view, collect responses for ALL requests sharing the `groupKey` (Stage 1), not just one request id. New store helper `responses(forLoop groupKey:) -> [TradeResponse]` (harness-testable), sorted by `createdAt`.
2. **Render** (`MessagingViews.swift:727-758`): keep bubbles for `.message`, `auditRow` for status changes — but tag each entry with the participant name and (for a loop) which leg. The top of the thread shows the original proposal per the loop.
3. **Empty-counter bug:** trace WHY the counter's `note` is empty. Two suspects found:
   - `respondCard`'s **"Message" button** (`MessagingViews.swift:676`) creates a `.countered` (not a `.message`) — often with an empty note, rendering as a bare "counter-offer" row. **Fix:** make that button post an actual `.message` (chat), OR require/carry a note; do not create note-less `.countered` rows.
   - The subset counter `counterWithSubset` (`Messaging.swift:951-961`) DOES set a note — confirm it renders. If the counter came in on a DIFFERENT loop request than the one being viewed, Stage-1 grouping fixes visibility.
   Add a guard so a `.countered`/`.message` with empty note+no image is never created.
4. **Missing messages bug:** confirm `postMessage` (`Messaging.swift:1051`) attaches to the viewed request and that the merged fetch (step 1) now surfaces messages sent on any leg of the loop. Add coverage.

**Failsafe checks**
- Build + harness green.
- New `INBOX-THREAD` test: responses across two loop requests merge into one chronological thread; a `.countered` with a note renders that note; an empty-note counter is never produced.
- **Behavioral:** open the 3-way → see Cary's counter-offer WITH its content and any messages either party sent, all in one thread.

**Rollback:** revert commit (thread reverts to single-request rendering).
**Commit:** `TRADE-INBOX: merged loop conversation thread + counter/message fixes`. **STOP.**

---

## Stage 8 — Rich calendar-repick counter-offers (new feature)

**Purpose:** Goal 7. A counterparty can open the calendar/package picker, propose a NEW package (different days), and send it back as a counter that renders as a **package card** in the thread; the original sender can Accept / Counter-again / Decline.

**Changes**
1. **Model:** counters carry a package, not just text. Add optional structured fields to `TradeResponse` (e.g. `counterGiveDayIDs: [String]?`, `counterTakeDayIDs: [String]?`, or a small embedded `CounterPackage` Codable) — optional/defaulted for back-compat. Assign post-construction.
2. **UI to compose a counter:** extend `respondCard` so "Counter" opens the day/package picker (reuse `PackageDetailView` / `ShiftSelectCalendar`), producing a `CounterPackage`. Replace the confusing "Message"→`.countered` button.
3. **Render counters as package cards** in the thread (Stage 7), chronologically below the original; the LATEST live counter is highlighted with Accept / Counter-again / Decline; older ones dim to history.
4. **Accept a counter:** accepting the latest counter finalizes THAT package (updates the trade's effective days), then flows into the existing accept → schedule-autocomplete → Done pipeline.
5. **Loop nuance:** for a 3+ loop, a counter re-picks that participant's leg; the loop re-balances or is flagged if it breaks reciprocity. (Define: a counter that unbalances the loop is rejected with a clear message. Keep the circular invariant.)

**Failsafe checks**
- Build + harness green.
- New `INBOX-COUNTER-PKG` tests: a counter package round-trips (codec); accepting a counter updates effective days; a counter that breaks loop reciprocity is rejected.
- **Behavioral:** counter with re-picked days → shows as a package card → sender accepts → trade proceeds → lands in History when the schedule flips.

**Rollback:** revert commit (counters revert to subset-trim text).
**Commit:** `TRADE-INBOX: rich calendar-repick counter-offers`. **STOP.**

---

## Stage 9 (optional) — Retire the Min-Cost/N-Way engine toggle

**Purpose:** post-U-OBJ, the engine picker (`TradeIntentsFeed.swift:457-467`) is vestigial and its "N-Way = circular loops" label is misleading (Min-Cost results are also circular). Simplify.

**Changes**
1. Remove the "Search engine" `DXSegmented` (Min-Cost/N-Way/Both); always run "Both" (the widest set) and let the U-OBJ objective rank.
2. Keep the **"Max people in a trade"** slider (`:468`) as the real control, and **keep "I'm Feeling Lucky"** untouched (separate speculative tier).
3. Remove now-dead `SearchFilter.Engine` plumbing only if nothing else reads it; otherwise default it to `.both` and hide the UI.

**Failsafe checks**
- Build + harness green (engine tests already cover routing).
- **Behavioral:** advanced search still generates 3+/loops; results match the old "Both" mode; Lucky still works.

**Rollback:** revert commit (toggle returns).
**Commit:** `TRADE-INBOX: retire Min-Cost/N-Way engine toggle (keep Lucky + max-people)`. **STOP.**

---

## Test ledger (all live in `EngineTests.runAll()`, [] = pass)

| Tag | Stage | Asserts |
|---|---|---|
| `INBOX-CODEC` | 1 | `loopID` + `origin` survive the CloudKit JSON round-trip |
| `INBOX-ORIGIN` | 2 | a synced circular loop decodes with `origin == .search` → Search tab |
| `INBOX-DEDUPE` | 3 | same-`loopID` requests collapse to 1; unrelated stay separate; ECB/qual-swap untouched |
| `INBOX-LOOPSTATUS` | 4 | aggregate status: pending / replied / accepted-active / done |
| `INBOX-COUNTS` | 6 | per-tab counts = deduped in-tab groups; active-trade count excludes Done, counts a loop once |
| `INBOX-UNREAD` | 6 | response after last-seen = unread; open = seen |
| `INBOX-THREAD` | 7 | responses across loop legs merge chronologically; no empty-note counters |
| `INBOX-COUNTER-PKG` | 8 | counter package round-trips; accept updates days; loop-breaking counter rejected |

---

## Open risks / watch-list

- **Legacy records** (`origin == nil`, `loopID == nil`) stay in Misc / render per-request. Acceptable; document. Consider a one-time backfill only if it matters.
- **CloudKit schema:** new fields ride the JSON `payload` (no queryable index needed) → NO console deploy required, UNLESS a field must be queried. Confirm before shipping.
- **Cross-device unread:** per-trade last-seen is per-device unless folded into the `appPrefs` sync blob — decide in Stage 6.
- **Qual-swap + ECB** are deliberately OUT of the loop-merge path — verify they never accidentally get a `loopID`.
- **Push notifications:** if a "new counter/message" push exists, make sure the badge/unread logic and the push agree.
