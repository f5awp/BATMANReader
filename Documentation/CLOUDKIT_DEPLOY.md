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
| `TradeRequest` | Public | `fromID` String · `toID` String · `candidateIDs` String (List) · `perfectMatch` Int64 · `hasQualSwap` Int64 · **`isAutoMatch` Int64** · **`autoMatchDate` String** · **`autoMatchPeer` String** · **`autoMatchDayISO` String** · `payload` String |
| `TradeResponse` | Public | `requestID` String · `responderID` String · **`notifyID` String** · `payload` String |
| `BroadcastPost` | Public | `authorID` String · `createdAt` Date/Time · **`mentionedIDs` String (List)** · `payload` String |
| `BroadcastReply` | Public | `postID` String · `authorID` String · `payload` String |
| `DMConversation` | Public | **`participantIDs` String (List)** · `payload` String |
| `DirectMessage` | Public | **`conversationID` String** · **`senderID` String** · **`toID` String** · `payload` String |
| `ModerationHide` | Public | `targetID` String · `payload` String |
| `TradeProfile` | Public | `workerID` String · `updatedAt` Date/Time · `payload` String |
| `MetricEvent` | Public | `payload` String |
| `RosterPackage` | Public | `csv` Asset · `version` Date/Time |
| `AccountClaim` | Public | `employeeID` String · `appleUserID` String · `displayName` String |
| `PrivateState` | **Private** | `privateNotes` String · `updatedAt` Date/Time · **`intents` String (B4-2)** · **`intentsUpdatedAt` Date/Time (B4-2)** · `ecbLedger` String · `ecbLedgerUpdatedAt` Date/Time · **`tradeHistory` String (B6-sync)** · **`tradeHistoryUpdatedAt` Date/Time (B6-sync)** · **`appPrefs` String (v2.3)** · **`appPrefsUpdatedAt` Date/Time (v2.3)** · **`dmReadState` String (DM)** · **`dmReadStateUpdatedAt` Date/Time (DM)** |

## Indexes (all Queryable)

| Record Type | Field | Note |
|---|---|---|
| `TradeRequest` | `toID` | inbox fetch + push filters |
| `TradeRequest` | `fromID` | outgoing fetch |
| `TradeRequest` | `candidateIDs` | `candidateIDs CONTAINS me` (bridge discovery) |
| `TradeRequest` | `perfectMatch` | `perfectMatch == 0/1` (push) |
| `TradeRequest` | `hasQualSwap` | `hasQualSwap == 1` (update push) |
| `TradeRequest` | `isAutoMatch` | `isAutoMatch == 1/0` (auto-match push + excludes it from the generic request pushes) |
| `TradeResponse` | `notifyID` | `notifyID == me` (someone-responded push) |
| `TradeResponse` | `recordName` | fetch-all |
| `BroadcastPost` | `recordName` | fetch-all + post subscription |
| `BroadcastPost` | `mentionedIDs` | `mentionedIDs CONTAINS me` (@mention push) |
| `DMConversation` | `participantIDs` | `participantIDs CONTAINS me` (my conversations) |
| `DirectMessage` | `toID` | incoming DM fetch + `toID == me` push |
| `DirectMessage` | `senderID` | outgoing DM fetch |
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
- **DEPLOYED (v2.3):** `appPrefs` (String) + `appPrefsUpdatedAt` (Date/Time) on the private `PrivateState`
  record — cross-device sync of the welcome/update-notes/consent flags (confirmed in the Console 2026-07-14).
  No index (fixed record name).
- **PENDING (B6-sync):** add `tradeHistory` (String) + `tradeHistoryUpdatedAt` (Date/Time) to the **private**
  `PrivateState` record, then deploy Dev→Prod. No index needed. Until this ships, the trade **status board /
  history** stays per-device (each device keeps its own; nothing is lost, just not shared).
  All new profile PREFERENCE fields (openness overrides, notification lead time, daily-digest on/off + hour)
  ride the existing `TradeProfile.payload` JSON, so they need **no** schema change.
- **PENDING (@mention push):** add `mentionedIDs` (String, **List**, **Queryable**) to the public `BroadcastPost`
  record + index, then deploy Dev→Prod. The `mentioned-<id>` push subscription is already in the app
  (`CloudPush`) but won't fire until this field exists in Production.

- **PENDING (Direct Messages):** the DM platform. Add BOTH new public record types + indexes, plus the
  private read-state fields, then deploy Dev→Prod. Until this ships, DMs work **locally only** (no cross-device
  or cross-user sync), and the incoming-DM push won't fire.
  1. `DMConversation` (Public): `participantIDs` String **List** + Queryable index · `payload` String.
  2. `DirectMessage` (Public): `conversationID` String · `senderID` String (Queryable) · `toID` String
     (Queryable) · `payload` String.
  3. `PrivateState` (Private): add `dmReadState` String + `dmReadStateUpdatedAt` Date/Time (no index) —
     cross-device unread/read-state sync.

- **PENDING (notification overhaul):** the auto-match + responses server pushes.
  1. `TradeRequest` (Public): add `isAutoMatch` Int64 (**Queryable index**), `autoMatchDate` String, `autoMatchPeer` String, `autoMatchDayISO` String. Drives the dynamic auto-match push *"An Auto-Match has been found for <date> with <name>!"*, excludes auto-matches from the generic request pushes, and (via the subscription's `desiredKeys = [autoMatchDayISO]`) ships the ISO day so a tap deep-links to that day's Trade List. `autoMatchDayISO` needs **no index** (it's a desiredKey, not queried).
  2. `TradeResponse` (Public): add `notifyID` String (**Queryable index**). Drives the "someone responded to your trade" push. Until deployed, the auto-match/response pushes won't fire and the generic `incoming-requests`/`perfect-match` predicates (now `AND isAutoMatch == 0`) won't match new records — deploy alongside.

### v2.2 ship deploy list (do these before/at TestFlight upload)
1. `PrivateState` (Private): add `tradeHistory` String + `tradeHistoryUpdatedAt` Date/Time — trade-history sync.
2. `BroadcastPost` (Public): add `mentionedIDs` String List + Queryable index — @mention push.
3. `DMConversation` + `DirectMessage` (Public) record types + indexes — direct messages (see above).
4. `PrivateState` (Private): add `dmReadState` String + `dmReadStateUpdatedAt` Date/Time — DM read-state sync.
5. Deploy Schema Changes → Development → Production. (Nothing else new needs a schema change.)
