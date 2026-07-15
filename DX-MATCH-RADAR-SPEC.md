# DX Match Radar — Implementation Spec (v3)

Surface trade opportunities directly on the Home calendar. Two layers of signal:
1. **Passive matches** — a **mutual-intent** match exists on a day (someone wants what you marked, or vice-versa). Shown as a **star** on the cell, auto-surfaced in a passive **Matches** inbox lane, and (optionally) pushed.
2. **Per-day Trade List** — tap any day → a ranked list of **every legal-to-work trade** for that day (not just mutual matches), so you can act even where no one has flagged an intent yet.

**v3 supersedes v2.** v2 was mutual-only, per-day "Matches" tab. v3 adds: the per-day **Trade List = all legal trades** (U-OBJ ranked), a **passive Matches vs active Requests** inbox split, **ECB/Day trade-kind** on want-to-trade, **PickupPrefs** on want-to-work, per-day **watch** (per-match notifications) vs **batched** notifications, and the finalized **disc / star / flag-ring** marker language. The engine core, determinism discipline, and the verified anchor map (§10) carry over from v2.

---

## 0. Two data sources (the critical decisions)

### 0a. `radarMatches` — MUTUAL matches (drives the calendar star + passive inbox lane)
A "match" for a day = a **2-way mutual deal** exists between me and a specific peer involving that day — real, eligibility-checked (qual/desk/timing + both blacklists), directly proposable, and **mutual** (≥1 day I marked AND ≥1 day they marked, both in the deal).

**Do NOT reuse `TradeRouter.intentSolutions`.** It curates: `finalize` floors on `acceptanceScore >= floorNormalProb`, caps at `intentResultCap (60)`, bundles one deal per peer, and includes 3-way loops. A per-day radar fed by it would under-count and flicker → the "new match" badge would cry wolf.

`TradeRouter.radarMatches(excluding selfID:) async -> [RadarMatch]`: same candidate universe (active, schedule-crossing, sorted by `workerID`), reuse `twoWayExploreCore` + `assembleIntentDeal` + the `mutualOnly` gate, **omit** `finalize`/floor/cap/loops. One `RadarMatch` per surviving peer-deal: `{ peer(id,name), giveDayIDs, takeDayIDs, kind }` where `kind ∈ {day, ecb, both}` (see §2). Deterministic, complete, people-centric.

### 0b. Per-day `dayTradeList` — ALL LEGAL trades for one day (drives the tap-in Trade List)
When the user taps a day, list **every trade that would be legal to work on that day**, not just mutual matches — ranked by the **normal U-OBJ order** (intent-marked → bookend → split → …). This is a **single-day, on-tap** search, so its candidate set is bounded (peers off/qualified/rested for that day) and it never runs for all days at once.

`TradeRouter.dayTradeList(dayID:excluding:) async -> [DayTradeRow]` — reuse the intent/twoWay machinery scoped to the one day, rank with the existing `rankLess` comparator (so `acceptanceScore` + the intent/bookend/split tiering apply unchanged). Row = `{ peer(id,name), shift(desk,startHour,type A/P/M), kind(day/ecb/both), note?, tier(mutual/bookend/split), acceptanceScore }`.

**Star vs List (design decision D1):** the **calendar star = mutual matches only** (`radarMatches`) — high-signal. The **tap-in Trade List = all legal trades** (`dayTradeList`) — comprehensive. If the star lit for every legally-workable day it would be meaningless. *(Flag D1 if this should change.)*

### Indexing
`MatchStore.matchesByDay: [DayID: [RadarMatch]]` — each mutual deal filed under every day in `giveDayIDs ∪ takeDayIDs`; **per-day star count = distinct peers**. The Trade List is NOT pre-indexed — it's computed on tap.

---

## 1. Calendar cell markers (finalized language)

All colors via `AppColor` (colorblind-safe, no neon). Behind the **"Matches" layer toggle** (§6), default on.

| Marker | Meaning | Shape |
|---|---|---|
| **Orange disc** behind the date number | **Significant day** (holiday / special) — was the star | filled disc, `AppColor` orange |
| **Star** (cell corner) | **≥1 mutual match** exists for this day | star glyph, trade hue |
| **Ring around the star** | **You're watching** this day (= flagged; drives per-match notifications, §7) | thin circle around the star |
| Count chip on the star | distinct mutual peers (`9+` cap); **filled** = unseen growth, **outline** = all seen | |

### Layering (outer→inner, all coexist)
watch-ring (around star) · today blue inset ring (§10) · **significant orange disc** (behind number) · tile glaze · number · **star + count** (corner) · note/event dot (opposite corner).
- The **significant day** moves from a star to the **orange disc** (frees the star for matches).
- The **star** is the match indicator; its **ring** is the watch flag.
- Never let the watch-ring, today-ring, and significant-disc collide — distinct radii/positions; verify light + dark.

### "What counts as a new match"
A day's **distinct-peer set grew** (a peer appears that wasn't in the last-seen set). Reorder/score changes don't count. Filled star clears when the day's Trade List opens (`markSeen`).

---

## 2. Trade-kind: ECB / Day / Both

Marking a **want-to-trade** (give-away) day gains a **kind pill: Day · ECB · Both** (`Mark Intents` UI). Marking **want-to-work** stays a single mark (+ optional PickupPrefs, §8).

- **Model:** `DayIntentStore.tradeKindByDay: [DayID: TradeKind]` (`.day/.ecb/.both`, default `.both` for a want-to-trade day). Published on `TradeProfile` (rides the JSON payload — no CloudKit index).
- **Match kind resolution:** a deal's `kind` = intersection of the giver's kind and what the taker will do:
  - giver `.day` + reciprocal taker → **Day**; giver `.ecb` + off-taker who takes for points → **ECB**; giver `.both` → whichever the taker supports (possibly **Both**).
- **Surfacing:** the match card and Trade List row show the kind badge(s). A **Both** card offers **two propose buttons** (Propose Day / Propose ECB). Proposing sets `origin: .intents` and (ECB) the ECB fields.

---

## 3. Day detail — 2 tabs (Trade List default)

Tapping a day opens the day editor with a `DXSegmented`, **Trade List selected by default**:
- **[ Trade List ]** (default) — ranked `dayTradeList` rows for THIS day: **dispatcher name · shift · kind (Day/ECB/Both) · desk · note (if any)**, filtered to legal-to-work, sorted by the **normal ranking** (mutual-intent → bookend → split; `acceptanceScore` within tier; tie-break shift time A→P→M). Each row = a mini card with Propose (per kind). Rows with an in-flight request show **Pending** (§5). Opening this tab calls `markSeen(dayID)`.
- **[ Info ]** — the current day editor (intent / kind pill / reason / note / vacation), **unchanged**.

No date column (you're already in the date). The **cross-day, soonest-first** ordering lives in the inbox Matches lane (§4b), not here.

---

## 4. Inbox — passive **Matches** vs active **Requests**

Top-level split so "possible" never reads as "in motion":

### 4a. Requests (active) — unchanged
The existing tabs (Intents / Search / ECB / Qual Swap) — trades actually sent or received.

### 4b. Matches (passive) — NEW lane
Auto-surfaced mutual matches (`radarMatches`), **sorted soonest-first** (dates differ here, unlike §3). Each card: peer · day(s) · **kind badges (Day/ECB/Both)** · Propose (per kind). **Proposing promotes** a match → a real request in the Intents tab (`sendRequest` via the feed's `propose`, `origin: .intents`).

**Structure choice (D2, recommended):** a segmented **`Matches | Requests`** control at the top of the Trade Inbox; Requests keeps its 4 sub-tabs. This gives the user's "2 categories" cleanly without a 5th peer-tab. *(Alt: a 5th "Matches" tab — rejected: mixes passive with active.)*

---

## 5. MatchStore + correctness

`@MainActor @Observable final class MatchStore` (`.shared`). State:
```
matchesByDay:  [DayID: [RadarMatch]]   // from radarMatches(), indexed per day (MUTUAL)
seenPeerSet:   [DayID: Set<WorkerID>]  // baseline for "unseen" — LOCAL
unseenDays:    Set<DayID>              // peer-set grew since last seen — LOCAL
watchedDays:   Set<DayID>              // = flagged; per-match notifications — LOCAL (v1)
lastRefreshed: Date?
```
No CloudKit schema in v1 (unseen/watch are local). `recompute(scope)`, `markSeen(dayID)`, and the `.local` touch-up are unchanged from v2 (§ below). **Propose-time correctness:** re-validate the single peer (`fetchProfile`), rebuild the deal, send only if still valid else toast; cross-ref `MessagingStore.requests` → show **Pending**; route through the feed's `propose` so `origin: .intents` and a 2-way deal has **no `loopID`** (single request — consistent with the Trade-Inbox revamp).

### recompute(scope)
`.full` (new master) / `.intentsOnly` (manual refresh): `refreshOthers()` then `radarMatches`. `.local` (my edit): touch only affected day(s). Index → per-day: if the distinct-peer set **grew** vs `seenPeerSet[day]` and the day isn't open → add to `unseenDays` (and fire notifications per §7). Assign, recompute stats, stamp `lastRefreshed`.

---

## 6. Layer toggle
Add **`matches`** to `LayerVisibility` (default on). Off → star/count/watch-ring hidden, cell renders exactly as today (regression guarantee). The significant-day orange disc is NOT gated by this toggle (it's not a match marker).

---

## 7. Notifications — watch (per-match) vs batched

- **Watched day** (flag ring on): a notification for **each new match** on that day — "New match on Sat Jul 18 — Cary wants your PM."
- **Unwatched days:** new matches roll into a **batched** notification, deduped via the unseen read-marker — "You have 3 new matching intents." Never one-push-per-match for unwatched days.
- Fires only on `recompute` when a day's peer set **grows** (not on reorder). Respects the existing notification settings + lead-time. Local scheduling via `NotificationManager`; no server fan-out in v1 (client recompute drives it — see §9).

---

## 8. PickupPrefs — constrain a want-to-work day (feasibility: MODERATE, does NOT bog down)

Let a want-to-work day carry which shifts/desks/quals the user will accept.
- **Model:** `DayIntentStore.pickupPrefsByDay: [DayID: PickupPrefs { shiftTypes: Set<A/P/M>, quals: Set<String>, desks: Set<String>? }]`, published on the profile (JSON payload). **Default = unconstrained** (= today's behavior) so unmarked days never regress.
- **Engine:** an **O(1) set-membership prune per candidate leg** inside the taker path of `twoWayExploreCore` — it **removes** candidates before the expensive scoring, so it **shrinks** work, never expands it. No new search dimension, no combinatorial blowup.
- **Sorting:** unchanged — the U-OBJ objective ranks the surviving (smaller) set with the same comparator. Correct by construction.
- **Perf verdict:** not a bottleneck; it reduces candidate volume and improves match quality. The cost is UI + model plumbing, not compute.
- **Risk = over-constraint** (narrow filters → 0 matches → "app is broken"). *Mitigations:* default unconstrained; explicit empty-state — "No matches — your pickup filters are narrow."

---

## 9. Non-goals (v1)
- No server-side push fan-out for matches (client recompute drives notifications; server push is a later add).
- No card pinning.
- No CloudKit schema for unseen/watch/flags (all local v1; cross-device watch sync is a deliberate later add).
- No 3-way / N-way loops on the calendar or in the per-day Trade List (they stay in Trades › Intents). The per-day list is 2-way legal trades only.

---

## 10. Verified code map (anchors — **re-verified 2026-07-15**, re-grep before use)

Load-bearing; if a re-grep shows drift, STOP and update this map first.

> **Note (2026-07-15):** re-confirmed after the **U-OBJ redesign** and **Trade-Inbox revamp**. `sendRequest` gained `origin`/`loopID`. Optimizer curation is via `acceptanceScore`: `finalize` floors `acceptanceScore >= floorNormalProb`, caps `intentResultCap`. `finalize`, `floorNormalProb`/`floorLuckyProb`, `intentResultCap (60)`, `intentCandidateCap (300)` all still exist.

| Symbol | Location | Signature / shape |
|---|---|---|
| `TradeRouter.intentSolutions` | TradeRouter.swift:711 | `(excluding selfID:generation:lucky:mutualOnly:) async -> [TradePackage]` — the OPTIMIZER (don't reuse for radar) |
| `TradeRouter.assembleIntentDeal` | TradeRouter.swift:682 | `nonisolated (_ p: IntentPairing) -> (gives:[String],takes:[String],mutualMarked:Int)?` |
| `TradeRouter.IntentPairing` | TradeRouter.swift:669 | `struct IntentPairing: Equatable, Sendable` |
| `TradeRouter.finalize` | TradeRouter.swift:1108 | floors `acceptanceScore >= floorNormalProb` (+`needsQualSwap`), caps `intentResultCap` — **omit in radar/day-list** |
| `TradeRouter.rankLess` | TradeRouter.swift (comparator used by finalize:1113) | the normal ranking — **reuse for `dayTradeList` sort** |
| `intentResultCap` / `intentCandidateCap` | TradeRouter.swift:940 / :944 | `60` / `300` (300 = runaway backstop; `log()` if it bites) |
| `TradeMatcher.twoWayExplore` | TradeMatcher.swift:502 | `(withWorker:name:windowStart:windowEnd:mySeeking:theirSeeking:myProfile:theirProfile:myID:ignoreOwnBlacklist:preloadedMine:preloadedPeer:) async -> TwoWayPlan` |
| `TradeMatcher.twoWayExploreCore` | TradeMatcher.swift:523 | `nonisolated` PURE variant — **use for off-main recompute (Task.detached)**; add the PickupPrefs prune here |
| `TwoWayPlan` / `TwoWayLeg` | TradeMatcher.swift:361 / :348 | leg fields `dayID,date,desk,startHour,bookend,wanted` |
| `MatchContext.build` | called TradeRouter.swift:281 & :713 | `(selfID:) async` → `ctx.{maps, universe, profilesByID, priors, start, end, …}` |
| `TradeEligibility.canCover` | TradeMatcher.swift (SSOT eligibility) | the "legal to work" gate for the day-list |
| `TradeProfileStore.refreshOthers` / `.fetchProfile(forWorker:)` / `.profile(forWorker:)` | TradeProfile.swift:427 / :549 / :510 | all-peer pull / single-peer network / sync-local |
| `TradeProfile.seekingDayIDs / wantToWorkDayIDs / opennessLevel` | TradeProfile.swift:79 / :102 / :195 | + **ADD** `tradeKindByDay`, `pickupPrefsByDay` |
| `DayIntentStore.seekingDayIDs / wantToWorkDayIDs / intentsRevision` | DayIntentStore.swift:117 / :127 / :24 | + **ADD** `tradeKindByDay`, `pickupPrefsByDay` |
| `WorkingIntentState.dontWantToWork` / `OffIntentState.wantToWork` | TradeEngineModels.swift:86 / :106 | the marks the kind-pill/prefs attach to |
| `MessagingStore.sendRequest` | Messaging.swift:903 | `(to:toName:note:take:give:daysValid:ecb:ecbValue:offerID:chain:qualSwap:origin:loopID:) async` |
| `MessagingStore.requests` / `status(of:)` | Messaging.swift:557 / :1120 | 2-way radar deal = single request → reads normally |
| `propose(_ pkg:)` | TradeIntentsFeed.swift:389 | fires `sendRequest` (sets `origin: .intents`) — **route proposes through this** |
| `CompactSwapCard` | TradeIntentsFeed.swift:741 | `onPropose: (TradePackage)->Void` — reuse for match/day-list cards |
| `TradeFeedCache.intentMatchCount` | TradeIntentsFeed.swift:36 | Intents badge |
| `TradeStatsBar` | ContentView.swift:335 (rendered :83) | the ONE new global counter |
| `LayerVisibility` | HomeView.swift:29 (fields :30–34) | **ADD `matches`** |
| Home cell markers | HomeCalendar.swift (`EventMarker` :61, `noteDot`, `numberColor`, `borderColor`) | disc/star/ring live here |
| Calendar tap | HomeView.swift:106 (`onTap: handleTap`) → :266 `handleTap` → :543 `DayEditTarget` | opens the 2-tab day sheet |
| New-master hook | ContentView.swift:272 `foregroundRefresh` → :283 `rosterRows>0 && diff.hasChanges` | `.full` recompute |
| Launch precompute slot | ContentView.swift:183–193 | radar seed under the loader |
| `NotificationManager` | Sources/Services/NotificationManager.swift | watch/batched scheduling |
| Existing engine tests | EngineTests.swift | must stay green (incl. 8 `INBOX-*` + `OPS-QUAL`) |

---

## 11. Build order (staged; each step: precondition → guardrail → gate → rollback; STOP after each)

1. **Model:** `TradeKind` + `tradeKindByDay`; `PickupPrefs` + `pickupPrefsByDay` on `DayIntentStore` + `TradeProfile` (optional/defaulted; JSON payload). *Gate:* build + harness green; codec round-trip test; unmarked = today's behavior.
2. **Engine `radarMatches`** (mutual, typed by kind) + determinism & completeness tests (a match with `acceptanceScore < floorNormalProb` absent from `intentSolutions`, present here). *Guardrail:* additive; do NOT edit `intentSolutions`/`finalize`.
3. **Engine `dayTradeList(dayID:)`** — all legal trades for one day, `rankLess`-sorted, PickupPrefs-pruned. *Gate:* determinism; a floored match still appears; PickupPrefs shrink (never grow) the set.
4. **MatchStore** (index, unseen, watch set, recompute scopes, `.local`) + local persistence. *Gate:* seed→grow→unseen; markSeen clears; regrow-no-growth stays seen.
5. **Calendar markers** behind `matches` layer: significant→orange disc, match→star, watch→ring-around-star, count chip; layering vs today-ring. *Gate:* layer OFF = pixel-identical to today; legible light+dark on every tile.
6. **Day 2-tab sheet:** Trade List (default, `dayTradeList` cards, kind badges, Propose, Pending) + Info (unchanged). *Gate:* Info identical to current editor; markSeen on Trade List appear.
7. **Inbox `Matches | Requests` split** + passive Matches lane (soonest-first) + propose-promotes. *Gate:* Requests tabs unchanged; proposing moves a match into Intents.
8. **Notifications:** watch→per-match, else batched+deduped. *Gate:* prove no per-match push for unwatched; watched fires per new match; foreground with no new master fires none.
9. **Stats:** global match-day counter + Home chips (matched/unseen/watched) + tap-to-scroll.

## 12. Anti-hallucination / anti-regression protocol (unchanged from v2)
Grep-before-use (verify §10, update it first on drift; `DocumentationSearch` for any new SwiftUI/Observation API) · Build gate + `XcodeRefreshCodeIssuesInFile` per touched file · **EngineTests stay green** after any `Sources/Domain/TradeEngine/` change (never edit a test to match new behavior without flagging) · blast-radius control (only declared files; don't touch the §8 magnifier or ECB accounting) · dark-behind-the-layer-toggle (layer OFF = today's behavior) · determinism as a test not a hope · no silent truncation (`log()` any cap that bites) · honest reporting (compile-verified ≠ runtime-verified) · one step / one pause / STOP for review · spec is the contract (update it first if reality forces a deviation).
