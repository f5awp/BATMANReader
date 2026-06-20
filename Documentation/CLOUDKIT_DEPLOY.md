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
| `BroadcastPost` | Public | `authorID` String · `createdAt` Date/Time · `payload` String |
| `BroadcastReply` | Public | `postID` String · `authorID` String · `payload` String |
| `ModerationHide` | Public | `targetID` String · `payload` String |
| `TradeProfile` | Public | `workerID` String · `updatedAt` Date/Time · `payload` String |
| `MetricEvent` | Public | `payload` String |
| `RosterPackage` | Public | `csv` Asset · `version` Date/Time |
| `AccountClaim` | Public | `employeeID` String · `appleUserID` String · `displayName` String |
| `PrivateState` | **Private** | `privateNotes` String · `updatedAt` Date/Time |

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
| `BroadcastReply` | `recordName` | fetch-all |
| `ModerationHide` | `recordName` | fetch-all |
| `TradeProfile` | `recordName` | fetch-all |
| `MetricEvent` | `recordName` | fetch-all |

`PrivateState`, `RosterPackage`, `AccountClaim` need **no index** — fetched by fixed record name.

## Why this matters
A Production query on an undeployed/un-indexed field **errors**, returning an empty set. That empty
fetch was the root of the P0 data-wipe (now also guarded in code by `FetchMerge.keepCacheOnEmpty`).

## Status
Deployed to Production on 2026-06-20.
