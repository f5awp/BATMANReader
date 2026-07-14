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
