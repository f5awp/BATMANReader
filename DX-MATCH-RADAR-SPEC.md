# DX Match Radar — Implementation Spec (v3.1)

Surface trade opportunities on the Home calendar. **Three** signals, deliberately distinct:

1. **Star (opportunity)** — a shift *someone else marked Want-to-Trade* on a day is **legal for you to pick up** (you're off + qualified + rested). Binary marker (no count), shows **even if you never marked anything**. Direction A only.
2. **Passive Matches lane + notifications (mutual)** — your intent and a peer's intent line up (both marked, compatible kinds). This is the "you have a matching intent in your inbox" signal — higher-signal than the star, and the only thing that notifies.
3. **Per-day Trade List (tap-in)** — every **legal** trade for a tapped day, ranked by the normal U-OBJ order, in two sections: **(A) shifts you can pick up** and **(B) people who want to work this day**.

**v3.1 supersedes v3.** Changes from the design conversation: star is **binary, direction-A** (was mutual-count); **Kind (Day/ECB/Both) on BOTH** want-to-trade and want-to-work (match kind = intersection); a unified **acceptance scope** (dates/range + quals + shifts) on both intents, set via an in-day-detail **calendar**; day detail gains a **Want-to-Work section** + a **Watch Day** toggle. Engine core, determinism discipline, and the §10 anchor map carry over.

---

## 0. Data sources

### 0a. `pickupsForMe` — drives the STAR + Trade-List section A
Days where **≥1 shift another dispatcher marked Want-to-Trade** is **legal for me** (`TradeEligibility.canCover`: I'm off that day, qualified for the desk, 8h-rested) **and** kind-compatible (§2) **and** passes both sides' acceptance scope (§8). My own intents are NOT required.
- **Star = a boolean per day** (`pickupAvailableDays: Set<DayID>`), cheaper than a ranked list — a per-day existence check, not the full list.
- **Trade-List section A** = the ranked pickups for the tapped day (computed on tap, see 0c).

### 0b. `radarMatches` — MUTUAL matches (drives the passive inbox lane + notifications, §4b/§7)
A **2-way mutual** deal (≥1 day I marked AND ≥1 day the peer marked, both in the deal), eligibility-checked, kind-compatible, directly proposable. **Do NOT reuse `intentSolutions`** (it floors on `acceptanceScore >= floorNormalProb`, caps `intentResultCap (60)`, bundles per peer, includes 3-way loops — a passive feed built on it under-counts and flickers). `radarMatches(excluding:) -> [RadarMatch]` reuses `twoWayExploreCore` + `assembleIntentDeal` + `mutualOnly`, **omits** finalize/floor/cap/loops. `RadarMatch = { peer, giveDayIDs, takeDayIDs, kind }`.

### 0c. `dayTradeList(dayID:)` — the tap-in Trade List (ALL legal trades for one day)
On tap, a **single-day** search (bounded, never all-days-at-once): every legal 2-way trade for that day, `rankLess`-ranked (mutual-intent → bookend → split; `acceptanceScore` within tier; tie-break shift time A→P→M). Returns two groups:
- **Section A — shifts you can pick up:** others' Want-to-Trade shifts legal for you. Row = `{ peer, shift(desk,startHour,type), kind(day/ecb/both), note?, tier }`.
- **Section B — people who want to work this day:** others who marked Want-to-Work for that day (they could take *your* shift). Row = `{ peer, their pickup kind, their accept-scope summary, note? }`. (Actionable when you work that day.)

**Star vs mutual (D1, resolved):** star = **0a** (opportunity, one-directional, binary). Passive Matches lane + notifications = **0b** (mutual). They are different on purpose.

---

## 1. Calendar cell markers

Colors via `AppColor` (colorblind-safe). Match markers behind the **"Matches" layer** (§6, default on); the significant-day disc is NOT gated by that layer.

| Marker | Meaning | Shape |
|---|---|---|
| **Orange disc** behind the date number | **Significant day** (holiday/special) — moved off the star | filled orange disc |
| **Star** (cell corner) | **≥1 legal pickup for me** exists (0a) — **binary, no count** | star glyph, trade hue |
| **Ring around the star** | **You're watching** this day (per-match notifications, §7) | thin circle around the star |
| note/event dot | existing §10 markers | opposite corner |

### Layering (outer→inner)
watch-ring (around star) · today blue inset ring · **significant orange disc** (behind number) · tile glaze · number · **star** (corner) · note/event dot (opposite corner). Distinct radii/positions so watch-ring, today-ring, and significant-disc never collide. Verify light + dark on every tile color.

### Unseen
The star has no count, so "new" is per-day binary: a day **gains** a pickup it didn't have at last-seen → eligible for the batched notification (§7) and (optional) a subtle "new" emphasis until the Trade List opens (`markSeen`).

---

## 2. Trade-kind: Day / ECB / Both — on BOTH sides

- **Want-to-Trade** (give away): kind pill **Day · ECB · Both** in Mark Intents (default `.both`).
- **Want-to-Work** (pick up): kind pill **Day · ECB · Both** — how you'll take a shift (day-for-day swap, for ECB points, or either).
- **Match-kind rule:** a pairing is valid iff the giver's kind ∩ taker's kind ≠ ∅. The resulting kind = that intersection (e.g. give `.both` + work `.ecb` → **ECB**; give `.day` + work `.ecb` → **no match**). This gates 0a/0b/0c and is a cheap set check.
- **Model:** `tradeKindByDay: [DayID: TradeKind]` on `DayIntentStore`, published on `TradeProfile` (JSON payload, no index). Both `seekingDayIDs` and `wantToWorkDayIDs` days carry a kind.
- **Cards** show the kind badge(s); a **Both** card offers two propose buttons (Propose Day / Propose ECB). ECB proposes set the ECB fields; all proposes route through the feed's `propose` (`origin: .intents`).

---

## 3. Day detail — 2 tabs (Trade List default)

Tapping a day → the day editor with a `DXSegmented`, **Trade List selected by default**:

### [ Trade List ] (default)
Two sections from `dayTradeList`:
- **A · Shifts you can pick up** — ranked; **dispatcher · shift · kind · desk · note**; each a mini card with Propose (per kind); in-flight → **Pending** (§5).
- **B · Wants to work this day** — dispatchers who marked Want-to-Work for this day (+ their kind + accept-scope summary); actionable when you work the day (offer them your shift).
- **Watch Day toggle** lives here (top of the tab) — on = per-match notifications for this day (§7), and draws the ring around the star.
- Opening this tab calls `markSeen(dayID)`.

### [ Info ]
The current day editor — intent, **kind pill**, reason, note, vacation — **unchanged**, PLUS the **acceptance-scope calendar** (§8): tap to open a calendar to select dates or a **date range** + quals/shift-types that scope this intent; unset = open (global prefs).

No date column (you're in the date). Cross-day soonest-first ordering lives in the inbox Matches lane (§4b).

---

## 4. Inbox — passive **Matches** vs active **Requests**

Top-level segmented **`Matches | Requests`** (D2). **Requests** keeps its 4 sub-tabs (Intents / Search / ECB / Qual Swap) — actual sent/received trades. **Matches** = passive mutual matches (`radarMatches`), **soonest-first**, each card with kind badges.

### 4c. Passive match detail (tap a Matches card)
Tapping a match opens a **calendar/detail view** (reuse `PackageDetailView.fromChain` / the day-select calendar, read-only for their side):
- **Their trade to you** — the shift(s) the peer is offering (their Want-to-Trade day(s): desk · time · kind).
- **Days they can take from you** — a **sorted list** (U-OBJ `rankLess`: bookend → soonest → quality) of *your* working days this peer could legally cover and has signalled Want-to-Work for. For a multi-day/day-for-day deal you pick which of these to give (same pattern as the existing multi-day give-back picker).
- **Propose from here** — per kind (Day / ECB / Both → two buttons). Proposing promotes the match → a real request in Intents (`sendRequest` via `propose`, `origin: .intents`, no `loopID` — a 2-way is a single request, consistent with the Trade-Inbox revamp), and re-validates the peer first (§5).

---

## 5. MatchStore + correctness

`@MainActor @Observable final class MatchStore` (`.shared`):
```
pickupAvailableDays: Set<DayID>        // 0a — drives the star (binary) — LOCAL derived
matchesByDay:        [DayID:[RadarMatch]] // 0b — mutual, for the Matches lane/notifications
seenPickupDays:      Set<DayID>         // baseline for "gained a pickup" — LOCAL
watchedDays:         Set<DayID>         // = the Watch toggle — LOCAL (v1)
lastRefreshed:       Date?
```
`recompute(scope)`: `.full`/`.intentsOnly` → `refreshOthers()` then recompute `pickupAvailableDays` + `radarMatches`; `.local` → touch affected day(s). No CloudKit for star/watch (local v1). **Propose-time:** re-validate the one peer (`fetchProfile`), rebuild the deal, send if still valid else toast; cross-ref `MessagingStore.requests` → Pending.

---

## 6. Layer toggle
Add **`matches`** to `LayerVisibility` (default on). Off → star + watch-ring hidden, cell identical to today. Significant orange disc is independent (not gated).

---

## 7. Notifications — Watch (per-match) vs batched
- **Watched day:** a notification for **each new match/pickup** on that day.
- **Unwatched days:** new pickups/matches roll into a **batched, deduped** notification ("You have N new trade opportunities"), via the seen baseline — never one-push-per-item.
- Fires on `recompute` when a day **gains** something (not on reorder). Respects notification settings + lead time. Local `NotificationManager` scheduling; no server fan-out v1 (§9).

---

## 8. Acceptance scope (unified; feasibility MODERATE, does NOT bog down)

Both intents carry an optional scope — what you'll accept:
- **Want-to-Work:** which dates/range + shift-types + quals + desks you'll pick up.
- **Want-to-Trade (day-for-day):** which dates/range + shift-types + quals you'll accept **in return**. (ECB gives have no return, so scope is n/a for the ECB dimension.)
- **Model:** `acceptScopeByDay: [DayID: AcceptScope { dates: Set<DayID>? or range, shiftTypes: Set<A/P/M>, quals: Set<String>, desks: Set<String>? }]` on `DayIntentStore` → `TradeProfile` (JSON payload). **Default nil = open** (= your global trade prefs) → unscoped days behave exactly as today.
- **UI:** set from the Info tab's **calendar** (select dates or a date range) + quals/shift pills.
- **Engine:** an **O(1) set-membership prune per candidate leg** inside `twoWayExploreCore` — it **removes** candidates before scoring, so it **shrinks** work, never expands it. No new search dimension, no combinatorial blowup.
- **Sorting:** unchanged — U-OBJ ranks the surviving (smaller) set with the same comparator. Correct by construction.
- **Perf verdict:** not a bottleneck; reduces candidate volume + improves match quality. Cost is UI + model plumbing, not compute.
- **Risk = over-constraint** (narrow scope → 0 matches). *Mitigations:* default open; explicit empty state ("No matches — your accept filters are narrow").

---

## 9. Non-goals (v1)
No server push fan-out (client recompute drives notifications). No card pinning. No CloudKit for star/watch/seen (local v1; cross-device watch sync later). No 3-way/N-way on the calendar or the per-day Trade List (2-way only; loops stay in Trades › Intents).

---

## 10. Verified code map (anchors — **re-verified 2026-07-15**, re-grep before use)

Load-bearing; on drift, STOP and update this map first. Re-confirmed after U-OBJ + Trade-Inbox. `sendRequest` gained `origin`/`loopID`. `finalize` floors `acceptanceScore >= floorNormalProb`, caps `intentResultCap`. `finalize`, `floorNormalProb`/`floorLuckyProb`, `intentResultCap (60)`, `intentCandidateCap (300)` all exist.

| Symbol | Location | Signature / shape |
|---|---|---|
| `TradeRouter.intentSolutions` | TradeRouter.swift:711 | `(excluding selfID:generation:lucky:mutualOnly:) async -> [TradePackage]` — OPTIMIZER (don't reuse) |
| `TradeRouter.assembleIntentDeal` | TradeRouter.swift:682 | `nonisolated (_ p: IntentPairing) -> (gives:[String],takes:[String],mutualMarked:Int)?` |
| `TradeRouter.IntentPairing` | TradeRouter.swift:669 | `struct IntentPairing: Equatable, Sendable` |
| `TradeRouter.finalize` | TradeRouter.swift:1108 | floors `acceptanceScore >= floorNormalProb` (+`needsQualSwap`), caps `intentResultCap` — **omit in radar/day-list** |
| `TradeRouter.rankLess` | TradeRouter.swift (used at finalize:1113) | the normal ranking — **reuse for `dayTradeList`** |
| `intentResultCap` / `intentCandidateCap` | TradeRouter.swift:940 / :944 | `60` / `300` (300 backstop; `log()` if it bites) |
| `TradeMatcher.twoWayExplore` | TradeMatcher.swift:502 | `(withWorker:name:windowStart:windowEnd:mySeeking:theirSeeking:myProfile:theirProfile:myID:ignoreOwnBlacklist:preloadedMine:preloadedPeer:) async -> TwoWayPlan` |
| `TradeMatcher.twoWayExploreCore` | TradeMatcher.swift:523 | `nonisolated` PURE — **off-main recompute; add kind + accept-scope prune here** |
| `TwoWayPlan` / `TwoWayLeg` | TradeMatcher.swift:361 / :348 | leg fields `dayID,date,desk,startHour,bookend,wanted` |
| `TradeEligibility.canCover` | TradeMatcher.swift | the "legal to work" gate for the star + section A |
| `MatchContext.build` | called TradeRouter.swift:281 & :713 | `(selfID:) async` → `ctx.{maps, universe, profilesByID, priors, start, end, …}` |
| `TradeProfileStore.refreshOthers` / `.fetchProfile(forWorker:)` / `.profile(forWorker:)` | TradeProfile.swift:427 / :549 / :510 | all-peer / single-peer network / sync-local |
| `TradeProfile.seekingDayIDs / wantToWorkDayIDs / opennessLevel` | TradeProfile.swift:79 / :102 / :195 | + **ADD** `tradeKindByDay`, `acceptScopeByDay` |
| `DayIntentStore` (seekingDayIDs :117 / wantToWorkDayIDs :127 / intentsRevision :24) | DayIntentStore.swift | + **ADD** `tradeKindByDay`, `acceptScopeByDay` |
| `WorkingIntentState.dontWantToWork` / `OffIntentState.wantToWork` | TradeEngineModels.swift:86 / :106 | the marks the kind-pill/scope attach to |
| `MessagingStore.sendRequest` | Messaging.swift:903 | `(to:toName:note:take:give:daysValid:ecb:ecbValue:offerID:chain:qualSwap:origin:loopID:) async` |
| `MessagingStore.requests` / `status(of:)` | Messaging.swift:557 / :1120 | 2-way = single request → reads normally |
| `propose(_ pkg:)` | TradeIntentsFeed.swift:389 | fires `sendRequest` (`origin: .intents`) — route proposes here |
| `CompactSwapCard` | TradeIntentsFeed.swift:741 | `onPropose:` — reuse for match/list cards |
| `ShiftSelectCalendar` | Sources/UI/Shared/ShiftSelectCalendar.swift | reuse for the accept-scope date/range picker |
| `TradeStatsBar` | ContentView.swift:335 (rendered :83) | the ONE new global counter |
| `LayerVisibility` | HomeView.swift:29 (fields :30–34) | **ADD `matches`** |
| Home cell markers | HomeCalendar.swift (`EventMarker` :61, `noteDot`, `numberColor`, `borderColor`) | disc/star/ring |
| Calendar tap | HomeView.swift:106 (`onTap: handleTap`) → :266 `handleTap` → :543 `DayEditTarget` | 2-tab day sheet |
| New-master hook | ContentView.swift:272 `foregroundRefresh` → :283 `rosterRows>0 && diff.hasChanges` | `.full` recompute |
| Launch precompute slot | ContentView.swift:183–193 | radar seed under the loader |
| `NotificationManager` | Sources/Services/NotificationManager.swift | watch/batched scheduling |
| Existing engine tests | EngineTests.swift | stay green (incl. 8 `INBOX-*` + `OPS-QUAL`) |

---

## 11. Build order (staged; precondition → guardrail → gate → rollback; STOP after each)

1. **Model:** `TradeKind` + `tradeKindByDay` (both intents); `AcceptScope` + `acceptScopeByDay`; on `DayIntentStore` + `TradeProfile` (optional/defaulted; JSON). *Gate:* build + harness green; codec round-trip; unset = today's behavior.
2. **Engine kind + accept-scope prune** in `twoWayExploreCore` (set checks). *Gate:* determinism; prune shrinks (never grows) the set; disjoint kinds → no match; EngineTests green unchanged.
3. **`pickupsForMe` (star boolean)** + **`radarMatches` (mutual, typed)** + tests (determinism; a floored match present here; star boolean matches a hand-built fixture).
4. **`dayTradeList(dayID:)`** — sections A + B, `rankLess`-sorted. *Gate:* determinism; a floored match still appears; section B lists want-to-work peers.
5. **MatchStore** (star set, mutual index, watch set, seen baseline, recompute scopes, local persistence). *Gate:* seed→gain→notify-eligible; markSeen clears; watch persists.
6. **Calendar markers** behind `matches` layer: significant→orange disc, pickup→star (binary), watch→ring. *Gate:* layer OFF = pixel-identical; legible light+dark.
7. **Day 2-tab sheet:** Trade List (default; A pickups + B want-to-work; Watch toggle; Propose/Pending) + Info (unchanged + accept-scope calendar). *Gate:* Info identical to current + calendar scopes; markSeen on appear.
8. **Mark Intents kind pills** (both intents). *Gate:* kind persists + publishes; default `.both`.
9. **Inbox `Matches | Requests` split** + passive Matches lane + propose-promotes. *Gate:* Requests unchanged; propose moves a match to Intents.
10. **Notifications:** watch→per-match, else batched+deduped. *Gate:* no per-match push when unwatched; watched fires per gain; foreground w/o new master fires none.
11. **Stats:** global opportunity counter + Home chips (pickups / matches / watched) + tap-to-scroll.

## 12. Anti-hallucination / anti-regression protocol (unchanged)
Grep-before-use (verify §10, update first on drift; `DocumentationSearch` for new SwiftUI/Observation API) · Build gate + `XcodeRefreshCodeIssuesInFile` per touched file · **EngineTests stay green** after any `Sources/Domain/TradeEngine/` change (never edit a test to match new behavior without flagging) · blast-radius control (declared files only; don't touch the magnifier or ECB accounting) · dark-behind-the-layer-toggle (layer OFF = today) · determinism as a test not a hope · no silent truncation (`log()` any cap that bites) · honest reporting (compile-verified ≠ runtime-verified) · one step / one pause / STOP for review · spec is the contract (update it first on any forced deviation).

---

## 13. Open interpretation to confirm before Step 1
- **Want-to-Trade acceptance scope** is read as the **day-for-day return window** (which days/quals/shifts you'll take BACK for a give), default open. If instead the calendar is meant to *bulk-mark a range of your working days as Want-to-Trade* (a marking-efficiency tool), say so — it changes §8's model.
