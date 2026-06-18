# BATMAN Watcher — Project Context Blueprint

> A dispatcher-facing iOS/iPadOS app for **American Airlines flight dispatchers**: it reads their
> ARIS/WorkNet schedule and provides a full shift-trading system (two-way swaps, one-way ECB
> pickups, and multi-person circular trades) backed by a shared CloudKit master roster.
>
> _Last updated: 2026-06-15. Branch: `v2`. App version 1.9, build 3._

---

## 1. Product Overview

**Who it's for:** AA dispatchers (the "BATMAN"/dispatch desk world). Domain concepts: qualification
codes (quals), desks mapped to regions, 9-hour shifts (AM/PM/MID), 8-hour rest rules, holidays as
high-demand days, ECB (one-way pickups).

**What it does:**
1. **Schedule reading** — pulls the dispatcher's schedule (from the shared master roster, or by
   scraping ARIS/WorkNet), shows a scrolling month calendar, syncs to a personal EventKit calendar,
   fires shift reminders, and powers widgets + Siri.
2. **Trade discovery & execution** — the user marks days they want to trade away / keep / work, and
   the engine finds: single takers, optimal multi-person reciprocal swaps, and circular N-way loops.
   Deals are proposed to an inbox, negotiated via chat, and accepted in-app (the *official* change
   still happens in ARIS/WorkNet).
3. **Coordination** — a broadcast channel (`# trades` / `# feedback`), 1:1 inbox with chat, and
   push notifications.

**Key principle:** *parse-once / query-many.* One master roster is published to CloudKit; every
client derives their own schedule + the matching pool from it. Users never import per-trade.

---

## 2. Platform, Build & Identity

| Item | Value |
|------|-------|
| Platforms | iOS / iPadOS only (device family `1,2`). **Never build "My Mac."** Build for iPhone sim / iPad. |
| Deployment target | App **iOS 26.0**; Widget extension **iOS 27.0** |
| App bundle ID | **`DX.BATMANReader`** — must NOT change |
| Widget bundle ID | `DX.BATMANReader.BATMANWidgets` |
| Version / Build | MARKETING_VERSION **1.9** (app) / 1.1 (widget); CURRENT_PROJECT_VERSION **3** |
| Swift | 5.0 mode |
| CloudKit container | **`iCloud.com.ervinlee.batmanreader`** (defined as `CloudKitConfig.containerID` in `TradeProfile.swift`) |
| App Group | **`group.com.ervinlee.batmanreader`** (widget data share) |
| Dev-access password | `batman2026` (session-only unlock; gates moderation + master publish) |
| Capabilities | CloudKit (public DB), Push (`aps-environment`), Sign in with Apple, App Groups |

---

## 3. Architecture & Conventions

- **State:** Swift **Observation** (`@Observable`), NOT Combine. `@Bindable` only where writes are
  needed. Stores are `@MainActor @Observable` singletons (`*.shared`) bound directly into SwiftUI.
- **Concurrency:** async/await throughout; heavy work on `actor` / `@ModelActor`; results cross
  actor boundaries as `Sendable` value snapshots.
- **Persistence (multi-layer):**
  - **SwiftData** — the full roster only (`RosterShift`), **LOCAL** (`ModelConfiguration(cloudKitDatabase: .none)`). The container self-heals if the on-disk store is corrupt (wipe + rebuild, fall back to in-memory) so launch never crashes.
  - **UserDefaults (JSON + Codable)** — shifts, intents, profiles, messages, history, settings.
  - **Keychain** — dev password.
  - **EventKit** — personal "AA Schedule" calendar + shared "AA Dispatch" calendar.
  - **CloudKit public DB** — roster master, trade profiles, messaging, account claims.
- **Service abstraction:** `TradeProfileService` and `MessagingService` protocols each have a
  `Local*` (UserDefaults actor) and a `CloudKit*` implementation — enables local-first dev, CloudKit
  opt-in via `SettingsManager.useCloudKit`.
- **CloudKit schema-light pattern:** records store the whole model as a JSON `payload` (+ a few flat
  queryable fields). Adding optional Codable fields needs **no schema change** and stays
  backward/forward compatible (`decodeIfPresent`).

---

## 4. Navigation Map

```
BATMANReaderApp (@main)
└─ ContentView  — root TabView
   ├─ Tab 0: HomeView      (calendar, intents, schedule)
   ├─ Tab 1: TradesView    (discovery: Intents / Search / ECB + dashboard)
   ├─ Overlay: MessagingDock (top-right) → InboxView + ChannelView (fullScreenCover)
   ├─ Overlay: red "DEVELOPER MODE" border when DevAccess.unlocked
   └─ fullScreenCover: OnboardingView  (until Sign in with Apple + employee ID claimed)
   └─ .task on launch: MessagingStore.refresh → RosterStore.syncMasterIfNewer →
                       CloudPush.setup → WidgetData.update
```

Settings + Help are reached from within tabs. The **Tester Guide** lives in
**Settings → Help section → "Tester guide"** (`TesterGuideView`, `checklist` icon).

---

## 5. File Map by Domain

### App shell & navigation
- `BATMANReaderApp.swift` — `@main`; requests notif + calendar permission; injects roster container.
- `ContentView.swift` — root TabView, MessagingDock overlay, onboarding cover, theme, launch `.task`. Also `OnboardingView` (Sign in with Apple + claim employee ID), `AppAppearance`, `ThemePicker`.

### Schedule & roster
- `RosterShift.swift` — SwiftData `@Model`; one (dispatcher, day) row; indexed by `day`, `workerID`, `(day,isOff)`. `RosterEntry` is its Sendable snapshot.
- `RosterStore.swift` — `@MainActor` facade + `@ModelActor RosterModelActor`. Self-healing container. `publishMaster(csv:)`, `syncMasterIfNewer()` (also derives the user's own schedule from their row), `importRoster`, day/worker queries.
- `Shift.swift` — core value model of one 9-hour shift (`ShiftRole`, desk, leaveCode, isOff, time helpers).
- `ShiftStore.swift` — `@Observable` singleton; persists `shifts`, `lastFetchDate`, `lastDiff`; computes diffs; `nextShift`, `tomorrowsShift`, etc.
- `ShiftEntity.swift` — AppIntents entity wrapping `Shift` + `ShiftEntityQuery`.
- `ScheduleParser.swift` — parses the ARIS/WorkNet "Expanded Schedule" CSV grid (visual calendar, not row-per-shift). `parseAllWorkers(csv:) -> [ParsedWorker]`, `parse(csv:targetWorkerID:)`. Handles dropped separators, overlaps, rolling 15-month window.
- `ScheduleDiff.swift` — `compute(old:new:)` → added/removed/changed/unchanged; drives EventKit sync.
- `WebController.swift` — `WKWebView` login + scrape of the schedule report.

### Availability & intents
- `ShiftAvailability.swift` — `ShiftAvailabilityType {am,pm,mid}`, `DayAvailability`, `DispatcherAvailabilityEntry`.
- `AvailabilityManager.swift` — `@Observable`; manages the shared "AA Dispatch" calendar, `myAvailability`, per-day blacklist, `buildFromSchedule()`, peer availability queries.
- `DayIntentStore.swift` — **v2 source of truth** for per-day intents: working/off intents, topologies, notes, off-availability pills, manual off days. `seekingDayIDs`, `applyOpenness`, `applyMercenary`, `reconcile(withShifts:)`.
- `TradeIntentStore.swift` — legacy `seekingDayIDs` set (migrating to DayIntentStore).

### Trade profiles & willingness
- `TradeProfile.swift` — `TradeProfile` value type (openness, blacklists, seekingDayIDs, contact, v2 rules, availability pills, bookendDays); willingness gates (`acceptsPickup`, `wouldPickUp`, `classify`). **Defines `CloudKitConfig.containerID`.**
- `TradeProfileStore.swift` — `@Observable`; owns active service; `myProfile()`, `publishMine()`, `refreshOthers()`, `availableDispatchers(on:type:)`.

### Trade engine
- `TradeMatcher.swift` — hard-gate filtering + two-way exploration. `TradeOpenness {none,bookends,all}`, `candidatesForTrades`, `twoWayExplore`, `goldCount` (🔥×N mutual intent).
- `TradeRouter.swift` — packaged solutions. `packages(forGiveShifts:excluding:)` emits solo-peer swaps (`solo-<peerID>`), optimal multi-peer covers, greedy fallback, then circular loops (pad toward target 5). `tieredSolutions()` (4 `SolutionTier`s), `nWayRoutes()` (DFS circular, maxDepth 4 / maxRoutes 60). `peopleCount` correct for circular (`participants.count − 1` excludes self double-count).
- `OptimalMatcher.swift` — branch-and-bound over peer subsets + min-cost flow for provably fewest-people reciprocal assignment; contiguity validator rejects break-fragmenting packages. Bounds: peers 16, days 10, subset 5.
- `MinCostFlow.swift` — SPFA successive-shortest-paths `run(from:to:)`.
- `TradeEngineModels.swift` — pure value types: `DayTopology`, `IntentReason`, `WorkingIntentState`, `OffIntentState`, `SolutionTier`, `NWayLeg/NWayRoute`, `ShiftBlock`, `DayNote`, `DashboardCounts`.
- `TradeHistoryStore.swift` — `@Observable`; completed/pending trade log.
- `Holidays.swift` — high-demand holiday map per year (fixed + floating + Good Friday/Computus).
- `ReasonClassifier.swift` — `classify(_:)`; FoundationModels (iOS 27+) on-device LLM, keyword fallback.
- `EngineTests.swift` — self-test harness (MinCostFlow, OptimalMatcher feasibility/balance/contiguity/determinism, Holidays 2026, willingness gates).

### Messaging
- `Messaging.swift` — models: `BroadcastPost` (+optional `channel`), `BroadcastReply`, `HiddenItem`, `TradeRequest` (+`chain: [TradeLeg]?`), `TradeLeg`, `TradeResponse`, `TradeRequestStatus {pending,accepted,declined,countered,cancelled,message}`. `MessagingService` protocol + `LocalMessagingService` actor. `MessagingStore` `@Observable` facade (post, sendRequest with chain, respond, postMessage, ECB queue).
- `SlackKit.swift` — Slack-style UI atoms (Avatar, SlackMessageRow, SlackComposer, ChannelHeader).

### UI
- `HomeView.swift` + `HomeCalendar.swift` — month calendar with per-day intent overlays, Mark Intents mode, visibility toggles, private-notes bar, sync line, admin CSV import (publishes master).
- `TradesView.swift` — dashboard counters (accepted/pending/denied/unread) + segmented feed (Intents / Search / ECB).
- `TradeIntentsFeed.swift` — tiered package feed; `PackageDetailView` built around clickable trade **steps** (jump calendars to each leg's two people); `HandoffChain`, `TraderChips`.
- `AvailabilityView.swift` — Find Candidates, two-way swap explorer (dual month grids, give/take legs), ECB one-way flow, `MiniScheduleGrid`/`Legend`.
- `ScheduleStripView.swift`, `ShiftSelectCalendar.swift` — schedule strip; multi-select day picker.
- `MessagingViews.swift` — `InboxView`, `ThreadView` (literal package card + chat composer + conversation), `ChannelView` (`# trades` / `# feedback` switcher), `MessagingDock`, status badges.
- `SettingsView.swift` — account, contact, notifications, calendars, iCloud Trade Sync, debug tools (dev-gated), Help + Tester guide buttons.
- `HelpView.swift` — `HelpView` (how-to) + `TesterGuideView` (break-it checklist → `# feedback`).
- `DispatchPalette.swift` — `DS` design tokens + Font ramp + color language (see §8).

### Services, widgets, system
- `CloudKitRosterService.swift`, `CloudKitTradeProfileService.swift`, `CloudKitMessagingService.swift` — public-DB services (see §6).
- `CloudPush.swift` — `CKQuerySubscription`s for incoming requests + broadcasts.
- `AccountService.swift` — employee-ID → Apple-ID claim (`AccountClaim`, `claim_<id>`); `.ok/.takenByAnother/.error`.
- `WidgetData.swift` — writes `WidgetSnapshot` to App Group; reloads timelines.
- `BATMANWidgets/` — `NextShiftWidget`, `PendingTradesWidget`, bundle.
- `NotificationManager.swift` — local shift reminders (lead hours, default 2).
- `EventKitManager.swift` — personal + shared calendar sync.
- App Intents: `ScheduleIntents.swift`, `AvailabilityIntents.swift`, `AIScheduleSummaryIntent.swift` (see §7).

---

## 6. CloudKit Data Model (public database)

Container `iCloud.com.ervinlee.batmanreader`, **public** DB for all services.

| Record Type | recordName convention | Key fields | Service |
|-------------|----------------------|------------|---------|
| `RosterPackage` | `master_roster` (fixed) | `csv` (CKAsset), `version` (Date) | CloudKitRosterService |
| `TradeProfile` | `profile_<workerID>` | `workerID`, `updatedAt`, `payload` (JSON) | CloudKitTradeProfileService |
| `BroadcastPost` | model UUID | `authorID`, `createdAt`, `channel?`, `payload` | CloudKitMessagingService |
| `BroadcastReply` | model UUID | `authorID`, `postID`, `createdAt`, `payload` | CloudKitMessagingService |
| `TradeRequest` | model UUID | `fromID`, `toID`, `payload` | CloudKitMessagingService |
| `TradeResponse` | model UUID | `requestID`, `responderID`, `payload` | CloudKitMessagingService |
| `ModerationHide` | `hide_<targetID>` | `targetID`, `payload` | CloudKitMessagingService |
| `AccountClaim` | `claim_<employeeID>` | `employeeID`, `appleUserID`, `displayName` | AccountService |

Push subscriptions (`CloudPush`): `incoming-requests-<username>` (TradeRequest where toID==me),
`new-broadcasts` (all BroadcastPost). Alert + sound + badge.

**Environment split (critical):** Xcode debug builds → **Development** DB; TestFlight/App Store →
**Production** DB. Records do **not** migrate between them, and Production never auto-creates record
types. See §10.

---

## 7. App Intents / Siri / Widgets

**Schedule (`ScheduleIntents.swift`):** `FetchScheduleIntent`, `GetShiftsIntent`,
`GetTomorrowsShiftIntent`, `GetScheduleChangesIntent`, `GetShiftForDateIntent`,
`EnableShiftAlertsIntent`, `TomorrowAlarmTimeIntent`.

**Availability (`AvailabilityIntents.swift`):** `GetAvailableDispatchersIntent`,
`ComposeTradeMessageIntent` → `AvailableDispatcherEntity` (rewired to v2 TradeProfile data).

**AI (`AIScheduleSummaryIntent.swift`, iOS 27+ FoundationModels):** `AIScheduleSummaryIntent`,
`AITradeBroadcastIntent`.

**Widgets (App Group `group.com.ervinlee.batmanreader`):** `NextShiftWidget` (small/medium: next
shift type/desk/date/time + 7-day strip + pending count), `PendingTradesWidget` (small: pending
count). Data via `WidgetSnapshot` at key `batman.widget.snapshot`.

---

## 8. Design System (`DispatchPalette.swift`)

**`DS` tokens:** spacing `xs 4 / s 8 / m 12 / l 16 / xl 24`; `cardRadius 14`, `cardPadding 14`,
`rowRadius 12`, `pillRadius 8`, `pillFill 0.16`, `avatar 30`.

**Font ramp** (R2-#10d, scaled up): `dsCardTitle` (subheadline.semibold), `dsCardMeta` (caption), `dsChip`
(subheadline.semibold), `dsBadge` (caption.heavy), `dsLabel` (caption.bold).

**Color language:**
- Trade direction: `mineScheme` (blue, give) / `peerScheme` (red, get) — border = gives a shift
  away, fill = takes a shift.
- `loopTrade` (violet) for circular trades.
- `traderThemes: [Color]` = red, violet, orange, magenta, amber-brown — rotates **per trader** so
  every participant in a multi-person/circular trade has a consistent color across calendars + cards.
- Day markers: `highImpact` (gold, high-demand/holiday), `personalDay` (pink, significant day),
  `openOff` / off-day hues.

**Copy rule:** dispatcher-facing language — avoid the word "cover"; use trade/give/take/swap.

**Accessibility:** Dynamic Type is clamped where layout is tight (`.dynamicTypeSize(...xLarge)`).

---

## 9. Core User Flows

**First run:** Sign in with Apple → claim real employee ID (locked to Apple ID via `AccountClaim`)
→ name "Last, First" → iCloud Trade Sync turns on → schedule auto-derives from master row.

**Daily:** open app → `syncMasterIfNewer()` pulls the latest master (admin posts ~3×/day) → schedule
+ alerts + widgets refresh. No per-user import.

**Mark intents:** Home → Mark Intents → tag working days (trade away / keep) and off-day
availability (AM/PM/MID); set openness (none / bookends / all), blacklist, mercenary mode.

**Discover trades:** Trades tab → pick days to give → engine returns tiers: solo takers → optimal
multi-person reciprocal → circular loops (aims to surface ≥5 options when feasible).

**Execute:** open a package → tap each step to inspect each leg's two people on calendars → Propose →
lands in the counterparty's **Inbox** as a package card → Accept / Counter / Decline + free-form
**chat** → accepted in-app (official change still happens in ARIS/WorkNet).

**ECB (one-way):** pick shifts to give → set ECB → request all → takers accept per shift (queue
capped 3/shift, first-come-first-served) → reply with employee #.

---

## 10. CloudKit Rollout / Ops (the "publish" workflow)

Two separate "publishes" — easy to confuse:

1. **Schema deploy (CloudKit Console).** Promotes record-type definitions Dev → Production:
   Console → container → **Schema → Deploy Schema Changes…**. Once per schema change. There is **no**
   "publish" button for *data*.
2. **Master roster record (in-app).** The actual `master_roster` record is created by the app, not
   the console: with **Developer access unlocked + iCloud Trade Sync ON**, use **Home → import CSV**;
   importing the roster while dev-unlocked calls `RosterStore.publishMaster` → writes to whichever
   environment the build runs in.

**TestFlight gotcha:** a master published from Xcode lives in **Development**. TestFlight reads
**Production**. So you must (a) deploy schema to Production, then (b) publish the master once from a
**TestFlight (Production)** build. Late deploy is fine — server-side, no rebuild/reinstall; testers
just reopen and `syncMasterIfNewer()` pulls it. Verify: Console → **Production → Records** → query
`RosterPackage` / `master_roster`.

---

## 11. Invariants & Gotchas (do not break)

- Bundle ID `DX.BATMANReader` is fixed.
- Roster SwiftData stays **local** (`cloudKitDatabase: .none`) — its attributes are non-optional and
  would break CloudKit mirroring; only TradeProfile/messaging go to CloudKit via their own services.
- New CloudKit fields must be **optional** Codable in `payload` to stay backward-compatible.
- Build for iPhone simulator / iPad, **never "My Mac."**
- `@Observable`/Observation only — no Combine.
- The app must never `fatalError` on launch over a bad store (self-heal is in `RosterStore.init`).
- Dev password `batman2026`; CloudKit container `iCloud.com.ervinlee.batmanreader`; App Group
  `group.com.ervinlee.batmanreader`.

---

## 12. Open / Outstanding

- Deploy CloudKit schema Dev → Production; publish master from a Production build.
- Archive + upload Build 3 to TestFlight.
- Legacy `TradeIntentStore` → `DayIntentStore` migration still in progress (both present on `v2`).
</content>
</invoke>
