# CloudKit Schema — Production Deploy Checklist

> The app's data rides a JSON `payload` string per record (no schema work needed for most fields).
> A schema entry is required only for fields the app **queries/subscribes on** (must be a real,
> **Queryable**-indexed column) or for a **new record type**. Dev auto-creates fields on first save;
> **Production does NOT** — promote Dev → Production in the CloudKit Console.

- **Console:** https://icloud.developer.apple.com
- **Container:** `iCloud.com.ervinlee.batmanreader`
- Edit in **Development**, then **Schema → Deploy Schema Changes → Development → Production**.
- Field type is set under **Schema → Record Types** (add field → name + type). Index is set under
  **Schema → Indexes** (pick record type → field → Index Type = Queryable). Two separate steps.

## Record types & fields (custom fields only; system fields auto-exist)

| Record Type | DB | Fields (name → type) |
|---|---|---|
| `TradeRequest` | Public | `fromID` String · `toID` String · `candidateIDs` String (List) · `perfectMatch` Int64 · `hasQualSwap` Int64 · `payload` String |
| `TradeResponse` | Public | `requestID` String · `responderID` String · `payload` String |
| `BroadcastPost` | Public | `authorID` String · `createdAt` Date/Time · **`mentionedIDs` String (List)** · `payload` String |
| `BroadcastReply` | Public | `postID` String · `authorID` String · `payload` String |
| `ModerationHide` | Public | `targetID` String · `payload` String |
| `TradeProfile` | Public | `workerID` String · `updatedAt` Date/Time · `payload` String |
| `MetricEvent` | Public | `payload` String |
| `RosterPackage` | Public | `csv` Asset · `version` Date/Time |
| `AccountClaim` | Public | `employeeID` String · `appleUserID` String · `displayName` String |
| `PrivateState` | **Private** | `privateNotes` String · `updatedAt` Date/Time · **`intents` String (B4-2)** · **`intentsUpdatedAt` Date/Time (B4-2)** · `ecbLedger` String · `ecbLedgerUpdatedAt` Date/Time · **`tradeHistory` String (B6-sync)** · **`tradeHistoryUpdatedAt` Date/Time (B6-sync)** |

## Indexes (all Queryable)

| Record Type | Field | Note |
|---|---|---|
| `TradeRequest` | `toID` | inbox fetch + push filters |
| `TradeRequest` | `fromID` | outgoing fetch |
| `TradeRequest` | `candidateIDs` | `candidateIDs CONTAINS me` (bridge discovery) |
| `TradeRequest` | `perfectMatch` | `perfectMatch == 0/1` (push) |
| `TradeRequest` | `hasQualSwap` | `hasQualSwap == 1` (update push) |
| `TradeResponse` | `recordName` | fetch-all |
| `BroadcastPost` | `recordName` | fetch-all + post subscription |
| `BroadcastPost` | `mentionedIDs` | `mentionedIDs CONTAINS me` (@mention push) |
| `BroadcastReply` | `recordName` | fetch-all |
| `ModerationHide` | `recordName` | fetch-all |
| `TradeProfile` | `recordName` | fetch-all |
| `MetricEvent` | `recordName` | fetch-all |

`PrivateState`, `RosterPackage`, `AccountClaim` need **no index** — fetched by fixed record name.

## Why this matters
A Production query on an undeployed/un-indexed field **errors**, returning an empty set. That empty
fetch was the root of the P0 data-wipe (now also guarded in code by `FetchMerge.keepCacheOnEmpty`).

## Status
- Deployed to Production on 2026-06-20 (initial 5).
- **DEPLOYED:** `intents`/`intentsUpdatedAt` (B4-2) and `ecbLedger`/`ecbLedgerUpdatedAt` (personal ECB blob)
  are live in Production on the private `PrivateState` record (confirmed in the Console 2026-07-10).
- **PENDING (B6-sync):** add `tradeHistory` (String) + `tradeHistoryUpdatedAt` (Date/Time) to the **private**
  `PrivateState` record, then deploy Dev→Prod. No index needed. Until this ships, the trade **status board /
  history** stays per-device (each device keeps its own; nothing is lost, just not shared).
  All new profile PREFERENCE fields (openness overrides, notification lead time, daily-digest on/off + hour)
  ride the existing `TradeProfile.payload` JSON, so they need **no** schema change.
- **PENDING (@mention push):** add `mentionedIDs` (String, **List**, **Queryable**) to the public `BroadcastPost`
  record + index, then deploy Dev→Prod. The `mentioned-<id>` push subscription is already in the app
  (`CloudPush`) but won't fire until this field exists in Production.

### v2.2 ship deploy list (do these before/at TestFlight upload)
1. `PrivateState` (Private): add `tradeHistory` String + `tradeHistoryUpdatedAt` Date/Time — trade-history sync.
2. `BroadcastPost` (Public): add `mentionedIDs` String List + Queryable index — @mention push.
3. Deploy Schema Changes → Development → Production. (Nothing else new needs a schema change.)
