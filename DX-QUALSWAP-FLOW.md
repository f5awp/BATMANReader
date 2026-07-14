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

## 1. The model: a one-way FINDER that LINKS into a normal trade

Qual swaps are **not** baked into the Trade Solutions feed. There is one coherent flow:

1. **Find + request** the qual swap with the standalone one-way finder (the green ⇄ button).
2. **Link** it into a normal reciprocal trade in the inbox via `TradeMerge` (the "Merge with base trade"
   button) once a bridge finalizes.

This keeps the bridge separate from the trade until it's actually secured.

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
