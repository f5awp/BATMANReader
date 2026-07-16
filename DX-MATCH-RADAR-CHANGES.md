# Match Radar — Change Log & CloudKit Deploy Note

Feature: the "calendar star" / Match Radar (see `DX-MATCH-RADAR-SPEC.md` + `DX-MATCH-RADAR-PLAN.md`).
Branch: `build4-blackout-cards-sync`. All 11 stages shipped; build + `TradeEngineTests.runAll()` green.

---

## TL;DR — CloudKit deploy required?

**No.** Nothing needs to be deployed to the CloudKit Console for Match Radar.

Every new synced field rides inside an existing **`payload`** JSON-blob string field, not a new
queryable/indexed record field:

- `TradeProfile` → `CloudKitTradeProfileService` encodes the whole profile into `record["payload"]`
  (only `workerID` / `updatedAt` are discrete). New profile fields ride free.
- `TradeRequest` → `CloudKitMessagingService.save(...)` encodes the whole request into `record["payload"]`
  (only `fromID` / `toID` / `candidateIDs` / `perfectMatch` / `hasQualSwap` are discrete flat fields for
  querying). New request fields ride free.
- Per-day intent state (`tradeKindByDay` / `acceptScopeByDay` / `carryoverVacationDayIDs`) also syncs as a
  blob via `PrivateStateStore` (private DB).

This mirrors how `origin` / `loopID` were added before with no deploy, and is covered by the
`INBOX-CODEC` + `MATCH-ALT` round-trip tests.

⚠️ **The one caveat:** this holds ONLY because the new fields are non-indexed and live in the blob. If a
future change adds a field that must be **queried/filtered server-side** (a discrete `record["…"]` used in
an `NSPredicate`, like `mentionedIDs` was — see the memory note on the @mention push deploy), THAT field
*would* need a manual Console schema deploy. None of the Match Radar fields are queried, so none apply.

---

## Data-model additions

| Type | New field(s) | Storage | Deploy? |
|---|---|---|---|
| `TradeProfile` | `tradeKindByDay: [String:TradeKind]?`, `acceptScopeByDay: [String:AcceptScope]?`, `carryoverVacationDayIDs: Set<String>?` | `payload` blob | No |
| `TradeRequest` | `altGiveDayIDs: [String]?`, `altTakeDayIDs: [String]?` | `payload` blob | No |
| `DayIntentStore` (private) | `tradeKindByDay`, `acceptScopeByDay` (+ persisted `Keys.tradeKind`/`.acceptScope`) | private-DB blob | No |

All new fields are **optional / frozen-init** (set post-construction), so existing records decode with them
as `nil` — full backward compatibility with records written by older app versions.

New value types (both `Codable`, in `ShiftAvailability.swift`):
- `TradeKind` — `day` / `ecb` / `both` (`resolve(with:)` intersects two sides).
- `AcceptScope` — `dates?` / `shiftTypes` / `quals` / `desks?`; `isOpen` = all-empty defers to global prefs.

---

## Changes by stage (each is its own commit)

| Stage | Commit | Summary |
|---|---|---|
| 1 | `1f0fec4` | `TradeKind` + `AcceptScope` model; store + profile fields |
| 2 | `1de9107` | `TradeMatcher.allowsDayForDaySwap` — ECB-only excluded from two-way |
| 3 | `4e7e031` | `TradeRouter.radarScan` + pure `radarPeerContribution` (star + mutual) |
| 4 | `ff8078e` | `TradeRouter.dayTradeList(dayID:)` + pure `sortDayRows` |
| 5 | `f79e9ea` | `MatchStore` (star / matches / watch / seen; pure `newlyGainedDays`) |
| 6 | `37c7ba0` | Calendar day-cell markers — green star (pickup) + blue watch ring |
| 7 | `684cdf5` | Day detail 2-tab (Trade List default + Info); `DayTradeListView.swift` |
| 8 | `10464bb` | Trade-kind pills + accept-scope UI; `AcceptScope.acceptsUnderAny` prune in `twoWayExploreCore` |
| 11 | `0f4d806` | Recompute wiring (LIVE): Home task, inbox task, new-master adopt; manual refresh + "Radar updated" stat |
| 9a | `0d8d0cc` | Inbox **Matches ǀ Requests** split + passive Matches lane + `MatchDetailView` |
| 10 | `5dded93` | `NotificationManager.notifyRadar` (watched=immediate, rest=batched) + persisted baseline |
| 9b | `fac2113` | Propose-carries-alternates (`altGive/altTakeDayIDs`, propose from `MatchDetailView`, counter with alternates, both parties see them) |

## Engine tests added
`MATCH-KIND`, `MATCH-MODEL`, `MATCH-STAR`, `MATCH-DETERMINISM`, `MATCH-DAYLIST`, `MATCH-SEEN`,
`MATCH-SCOPE`, `MATCH-ALT`.

## On-device verification checklist (not runtime-verified in the headless build)
1. Home calendar: a day with a legal pickup shows the green star; toggling **Watch Day** shows the blue ring.
2. Tap a day → **Trade List** tab lists pickups + want-to-work; refresh shows "Radar updated …".
3. **Mark Intents / Info** on a trade-away day: Trade-as (Day/ECB/Either) + "Accept in return" pills persist.
4. **Trade Inbox → Matches**: mutual matches listed; open one → **Propose Trade** with a chosen give/get.
5. Recipient device: incoming card shows the picked days **plus** "Or counter with an alternate"; countering
   with an alt sends back correctly; both cards show the "Alternates: …" line.
6. Notifications: after a new match on a watched day, an alert fires (needs notification permission granted).
