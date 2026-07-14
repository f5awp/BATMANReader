# DX Qual-Swap Flow — End-to-End

How an international-desk give-away that needs a **qual swap** is found, requested, linked to a trade, and
resolved. Design-locked 2026-07-13. Documents the *implemented* behavior (code references inline).

---

## 0. What a qual swap is

A dispatcher can only work a desk they hold the qual for (E/L/P; D is universal — `DeskRules.requiredQual`).
When you give away an **international** desk (e.g. FD82 → Latin/`L`) but the off dispatcher who'd take it
isn't qualified, a **bridge** makes it work:

- **A** (you) give the international desk away and go off.
- **C** (bridge) — working that day at the same start hour, holds the qual, on a desk **B can take** — slides
  onto A's desk.
- **B** (taker) takes C's now-freed desk.

Coverage + start times stay whole. The bridge is an *enabling leg*, **not** counted in the people-count and
**has no calendar** in any view.

---

## 1. The model: TWO complementary paths

**A. Inline feed tier** — Trade Solutions actively offers qual-swap **solution cards** (amber **Q**
caution, ranked below clean trades). Tapping opens the package view where the **Q button** picks the bridge.
The reciprocal trade + the bridge leg are one package. (`packages()` step 1b.)

**B. Standalone one-way finder** (green ⇄ button) — pre-arrange a qual swap for a give-day, then **link** it
into a normal trade in the inbox via `TradeMerge` ("Merge with base trade") once a bridge finalizes.

Both are supported; A is the discovery path in the feed, B is the manual/pre-arrange path.

---

## 2. The finder (green double-arrow button → `QualSwapDaysSheet`)

`TradeRouter.qualSwapOptions(forGiveShifts:excluding:)`:

- For each selected **international** give-day, lists the off dispatchers who could take a bridge-freed desk
  that day (`QualSwap.solutions`), each carrying its eligible **bridges**.
- **Constrained** to genuinely willing takers via the **full** eligibility gate (openness / blacklist /
  availability) — *not* `.physicalOnly`, which surfaced every off dispatcher (the old "227" bug).
- One **standalone one-way** qual-swap request per (day, taker): `giveDayIDs = [day]`, `takeDayIDs = []`,
  plus a `qualSwap` leg with the bridge candidates.
- Multi-select who to ask → **Broadcast** sends each (`take: [], give: [day], qualSwap: leg`).

CloudKit (`CloudKitMessagingService`) stores a flat `candidateIDs` list so bridges (neither `fromID` nor
`toID`) discover it. All qual-swap requests file under the **Misc / "Other"** inbox tab (`tabIndex`).

---

## 3. Linking into a normal trade (`TradeMerge`, pre-existing)

- `TradeMerge.canMerge(base, bridge)` = base is a **clean** trade (`qualSwap == nil`), the bridge **has** a
  qual-swap leg, and the bridge's `giveShiftDayID` is one of the base's give-days.
- In the inbox (`MessagingViews`, giver role), once a bridge is finalized and a matching clean base exists,
  the **"Merge with base trade"** button appears → `MessagingStore.mergeRequests` fuses them into one request
  (`merged-…`), archiving both originals.

---

## 4. Inbox lifecycle (role-aware; `MessagingViews.qualSwapSection`, `qualSwapRole`)

| Role | Sees |
|---|---|
| **Bridge (C)** | "You'd move onto desk X; your desk Y goes to B." + **Accept qual swap**. First **5** acceptors (`QualSwapLeg.acceptorCap`); then "already filled." |
| **Taker (B)** | "X of Y accepted" + each accepting bridge (desk it frees) + **Choose** (`finalizeQualSwap`) + **Decline — cancels the trade** (`declineQualSwap`). |
| **Giver (A)** | "Contingent on the qual swap" (read-only) + **Merge with base trade** once finalized. |

**Status** (`QualSwapLeg.status`, tints): `waiting` (amber) → `offersOpen`/`offersFull` (blue) →
`finalized` (green) / `invalid` (red — declined or expired with no bridge).

Completion: `autoCompleteProvenTrades` closes it when the master schedule shows the moves went through.

---

## 5. The package view (`PackageDetailView`) — normal reciprocal trades

The readable twin-calendar view (`MiniScheduleGrid`) is where a normal trade is refined:

- **Day chips**: a **"Select specific days"** toggle differentiates *view* from *select*. Off → tapping a
  chip focuses it on the calendar. On → each tap includes/excludes it (checkmarks, "picked/total",
  "Propose selection").
- **"You get"**: when the peer offers ranked alternate give-back days, a single-select **radio** picks which
  day you receive; it drives the calendars + Propose.
- If a package *does* carry a `qualSwap` leg (e.g. a merged request), a **Q "Qual swap — choose a bridge"**
  button opens the picker; cards show an amber **Q** caution.
- **"Sent"** state: `MessagingStore.alreadyProposed` greys the Propose button (anti-spam, same peer+day).

---

## Build spec — favorability + two-flow rework (2026-07-13) — IMPLEMENTED

Status: shipped. Engine gate green incl. new S-ENG-4 (favorable+unfavorable bridges) + Q2 (freed-desk qual
+ favorability) checks. Fail-safe verified: `favorable` defaults `true`, so old records/other call sites are
unchanged.

### Assumptions ledger (decisions; revise here first if wrong)
1. **Bridges are not always domestic.** A bridge C may sit on a Euro/Pacific desk; what matters is whether
   the taker B can hold C's freed desk's qual. The taker-qual check stays for the *trade-first* path (a real
   B exists); the *bridge-first* green button has no B yet, so it skips it.
2. **Favorability is soft, blacklist is hard.** A bridge is DROPPED only if the give-desk (or its qual) is
   blacklisted for them. If they simply prefer their current desk's qual over the give-desk's, they're
   INCLUDED but flagged **unfavorable** (a stretch ask). `qualValue(give) ≥ qualValue(current)` ⇒ favorable.
3. **`QualSwapCandidate.favorable: Bool`** (default `true`, Codable-safe) rides on each bridge; UI sorts
   favorable-first and warns on unfavorable. Old records decode as favorable.
4. **Bridge-first request (green):** one request per selected day, `toID = self`, `qualSwap` leg with
   `takerID = ""` (unbound) + `candidates =` the selected bridges. `candidateIDs` lets bridges discover +
   accept. It's a standing "bridge found/requested" record in my Misc inbox.
5. **Linking:** `TradeMerge` fuses a bridge-first request into an A→B base trade on the same give-day; the
   base supplies B. `mergeBase` gate relaxed from `.finalized` to **≥1 acceptance** so a confirmed bridge can
   link before the (future) taker finalizes. The package view / card offers **"Use found bridge"** which
   merges at propose-time instead of forcing an inline pick.
6. Trade-first (Q caution) is unchanged in shape (A+B+C in one request); it only gains favorability
   ranking + warnings in the picker.

### Code map (verified 2026-07-13; re-grep before editing)
| Symbol | Loc | Change |
|---|---|---|
| `DeskRules.acceptsQualSwap` | TradeMatcher.swift:152 | split → `qualSwapHardOK` (blacklist) + `qualSwapFavorable` (pref ≥); `acceptsQualSwap` = both |
| `QualSwapCandidate` | Messaging.swift:315 | add `var favorable: Bool = true` |
| `QualSwap.bridges` | TradeMatcher.swift:209 | `takerQuals: [String]?` (nil ⇒ bridge-first, skip taker check); return `[QualSwapCandidate]` with `favorable` |
| `QualSwap.candidate(from:)` | TradeMatcher.swift:226 | fold into `bridges` |
| `TradeMatcher.qualSwapBridges` | TradeMatcher.swift:759 | `takerQuals: [String]?`; pass through |
| `TradeRouter.qualSwapOptions` | TradeRouter.swift:1084 | list BRIDGES (favorability-ranked), not takers |
| `QualSwapDaysSheet` / `QualSwapPickerSheet` | AvailabilityView.swift | sort favorable-first + warn unfavorable |
| `MessagingStore.mergeBase` | Messaging.swift:931 | gate `.finalized` → `.finalized || acceptances ≥ 1` |
| `PackageDetailView` Q button | TradeIntentsFeed.swift | offer "Use found bridge" when a matching bridge-first request exists |

### Fail-safes
- Each step: `BuildProject` clean + `EngineTests.runAll()` == 0 failures.
- Favorability + bridge changes are pure/nonisolated → EngineTests cover them (add favorability checks).
- `favorable` defaults true so any un-annotated candidate (old data / other call sites) behaves as before.
- No change to the inbox lifecycle roles; bridge-first reuses `candidateIDs` discovery + accept + TradeMerge.

## Code map

| Concern | Location |
|---|---|
| Desk → qual / gap check | `DeskRules` (TradeMatcher.swift) |
| Finder (green button) | `TradeRouter.qualSwapOptions` + `QualSwap.solutions` |
| Finder UI / broadcast | `AvailabilityView` (`showQualSwaps`, `QualSwapDaysSheet`) |
| Bridge search / leg build | `QualSwap.bridges`, `TradeMatcher.qualSwapBridges` / `buildQualSwapLeg` |
| Linking | `TradeMerge` (Messaging.swift); `MessagingStore.mergeBase` / `mergeRequests`; inbox "Merge with base trade" |
| Send + anti-spam | `MessagingStore.sendRequest` / `alreadyProposed` |
| CloudKit bridge discovery | `CloudKitMessagingService` (`candidateIDs`) |
| Inbox lifecycle | `MessagingViews.qualSwapSection`; `acceptQualSwapBridge` / `finalizeQualSwap` / `declineQualSwap` |
| Inbox folder routing | `MessagingViews.tabIndex` (qual swaps → Misc/Other) |
| Package view selection | `PackageDetailView` (`selectMode`, take radio, `subsetPackage`) |
| Status model | `QualSwapLegStatus`, `QualSwapLeg.status` (TradeMatcher.swift) |
