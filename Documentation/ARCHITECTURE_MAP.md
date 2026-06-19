# BATMAN Watcher — Architecture Map (the WHERE index)

> **Purpose:** jump straight to the code that implements a feature — file → type → function — so we
> don't re-search 45 files for every change. This is the **WHERE** doc. **WHAT** a feature should do
> lives in `SPEC_STRUCTURAL.md` / `SPEC_UIUX.md`; **what we're changing** lives in `NEXT_CHANGES.md`.
>
> **Conventions**
> - Anchors are **type/function names + spec IDs**, never line numbers (they drift). To locate, grep
>   the symbol or the spec ID comment (e.g. `S-PARSE-2`).
> - **One source of truth** per decision — when you see "(SOT)", that function is the *only* place the
>   decision is made; change it there and nowhere else.
> - **Maintenance (Definition of Done):** any change that adds/moves/renames a symbol updates its row
>   here in the same pass. Stale rows are bugs. **Guard:** `bash scripts/check_arch_map.sh` fails if any
>   file/spec-ID/SOT-symbol this map references no longer resolves (run it as part of DoD; it can't
>   verify prose, only that references resolve). Add new SOT symbols to the script's `SOT_SYMBOLS` list.
> - State = `@Observable` singletons (`*.shared`), `@MainActor`; heavy work on actors with `Sendable`
>   snapshots. Persistence: SwiftData (roster, local), UserDefaults+Codable (most), CloudKit public
>   (profiles/messaging/roster master), Keychain (password).

---

## 1. Schedule ingest (read the roster → shifts)

| Feature | File | Key symbols | Spec / tests |
|---|---|---|---|
| Parse ARIS "Expanded Schedule" CSV grid | `ScheduleParser.swift` | `parseAllWorkers(csv:)`, `parse(csv:targetWorkerID:)`, `appendShifts(...)` (spine alignment), `workerIdentity(_:)`, `resolveYear(...)` | S-PARSE-1 |
| **Leave/vacation detection** | `ScheduleParser.swift` | inside `appendShifts`: `annRows` scan → `L|V` ⇒ off + `leaveCode "V"`; other codes recorded, inert | S-PARSE-1, EngineTests "Vacation:" |
| One shift value | `Shift.swift` | `Shift {id,date,startHour,endHour,role,desk,leaveCode,isOff}`, `ShiftRole`; add `isVacation` here | S-DATA-1 |
| Diff old↔new schedule | `ScheduleDiff.swift` | `ScheduleDiff{added,removed,changed,unchanged}`, `compute(old:new:)`, `shiftDetailsChanged` (incl. leaveCode) | S-PARSE-2 |
| Owns the user's shift list | `ShiftStore.swift` | `ShiftStore.shared`, `save(_:) -> ScheduleDiff` (sets `lastDiff`), `shifts`, `lastDiff`, `lastFetchDate`, `nextShift` | — |
| Scrape login/report | `WebController.swift` | `WKWebView` flow | — |

## 2. Roster (everyone, for matching)

| Feature | File | Key symbols | Spec |
|---|---|---|---|
| Roster store (SwiftData, LOCAL) | `RosterStore.swift` | `RosterStore.shared`, `container` (self-healing `init`), `RosterModelActor`, `importRoster`, `dispatchersOff/Working(on:)`, `entries(from:to:)`, `schedule(forWorker:)` | — |
| Master publish + pull | `RosterStore.swift` | `publishMaster(csv:)`, `syncMasterIfNewer()` (derives user schedule → `ShiftStore.save` + reconcile + alerts) | S-PARSE-2, S-SYNC |
| Roster row model | `RosterShift.swift` | `@Model RosterShift {workerID,workerName,quals,day,date,startHour,desk,isOff}`, `RosterEntry` snapshot; add `leaveCode` here | S-DATA-1 |

## 3. Intents (per-day marks: trade away / keep / must-be-off / availability)

| Feature | File | Key symbols | Spec |
|---|---|---|---|
| **Per-day intent store (SOT)** | `DayIntentStore.swift` | `DayIntentStore.shared`; maps `workingIntents`/`offIntents`/`topologies`/`notes`/`offAvailability`/`manualOffDays`; `seekingDayIDs` (derived) | — |
| Set/clear marks | `DayIntentStore.swift` | `setWorkingIntent`, `setOffIntent`, `toggleAvailability`, `setNote`, `setTopology`, `clearIntent` | — |
| Openness / mercenary bulk apply | `DayIntentStore.swift` | `applyOpenness(_:shifts:)`, `applyMercenary(_:openness:shifts:)`, `bookendGatedDays(...)` | S-ENG-6 |
| **Re-import preservation (SOT)** | `DayIntentStore.swift` | `reconcileTargets(diff:)` (pure), `reconcile(diff:)` | S-PARSE-2, EngineTests "reconcile:" |
| reconcile trigger (once/fetch) | `HomeView.swift` | `reconcileSnapshot()` + `@AppStorage lastReconciledFetch` | S-PARSE-2 |
| Intent value types | `TradeEngineModels.swift` | `WorkingIntentState`, `OffIntentState`, `DayTopology`, `IntentReason`, `DayNote`, `SolutionTier`, `NWayRoute/Leg` | — |
| Legacy (migrating away) | `TradeIntentStore.swift` | `seekingDayIDs` | — |

## 4. Trade engine (matching)

| Feature | File | Key symbols | Spec |
|---|---|---|---|
| Hard gates / candidates / two-way | `TradeMatcher.swift` | `TradeOpenness`, `DeskRules.region/requiredQual/qualified`, `candidatesForTrades`, `twoWayExplore`, `goldCount`, `anchored(...)` (bookend), `rested(...)` | S-ENG-1, S-ENG-2, S-ENG-10 |
| Packages / circular / tiers | `TradeRouter.swift` | `packages(forGiveShifts:excluding:)`, `tieredSolutions()`, `nWayRoutes()`, `TradePackage`, `PackageAssignment` | S-ENG-3, S-ENG-4, S-ENG-5 |
| Fewest-people reciprocal | `OptimalMatcher.swift` | `minPeopleReciprocal(giveDayIDs:peers:contiguous:)`, `Cand`, `Assignment` | S-ENG-3 |
| Min-cost flow | `MinCostFlow.swift` | `MinCostFlow`, `addEdge`, `run(from:to:)` | — |
| Holidays (high-demand) | `Holidays.swift` | `Holidays.map(year:)`, `isHighDemand`, `name(forDay:)` | — |
| Reason classify (on-device LLM) | `ReasonClassifier.swift` | `classify(_:)` | — |
| Self-test harness | `EngineTests.swift` | `TradeEngineTests.runAll() -> [String]` (Settings→Developer) | S-TEST |
| **Bookend rule (to refactor → SOT)** | `TradeMatcher.swift` | replace per-leg `anchored` with all-legs/both-sides bookend fn | S-ENG-2, S-ENG-10 |
| **Trade-type label (SOT)** | `TradeEngineModels.swift` `tradeTypeLabel(distinctPeople:isOneWayECB:hasQualSwap:)` + `distinctParticipants(in:)`. Only 3 outputs: `1-Way Swap`/`Qual Swap`/`{n}-Person Swap`. `TradePackage.peopleCount` (TradeRouter) = total distinct incl. self. Used by `TradeIntentsFeed`, `MessagingViews`. Guarded (no stray literals). | S-ENG-5, S-TEST-1 ✅ |

## 5. Trade profiles (published willingness)

| Feature | File | Key symbols | Spec |
|---|---|---|---|
| Profile value type | `TradeProfile.swift` | `TradeProfile`, `wouldPickUp(...)` (gates `mustBeOffDayIDs` first), `passesBlacklist(...)`, `availabilityMap`; **has** `mustBeOffDayIDs`/`keepDayIDs` (from `DayIntentStore.mustBeOffDayIDs`/`keepDayIDs` via `myProfile()`); **add** `qualRanking`/qual-swap blacklist | S-DATA-2, S-ENG-9 ✅(must-be-off) |
| Profile store + service | `TradeProfile.swift` (store), `CloudKitTradeProfileService.swift`, `LocalTradeProfileService` | `TradeProfileStore.shared`, `myProfile()`, `publishMine()`, `refreshOthers()`, `availableDispatchers(on:type:)` | S-SYNC-2 |
| CloudKit config | `TradeProfile.swift` | `CloudKitConfig.containerID = "iCloud.com.ervinlee.batmanreader"` | — |

## 6. Messaging (inbox, channels, ECB, qual-swap)

| Feature | File | Key symbols | Spec |
|---|---|---|---|
| Models | `Messaging.swift` | `BroadcastPost(channel?)`, `BroadcastReply`, `TradeRequest(chain?,ecb?)`, `TradeLeg`, `TradeResponse`, `TradeRequestStatus`; **add** reactions/attachments/edited/deleted/pinned/moderation, `QualSwapStep` | S-DATA-3, Q3–Q6 |
| Store (SOT facade) | `Messaging.swift` | `MessagingStore.shared`, `post(...)`, `sendRequest` (`ecbValue:`), `respond`, `postMessage`, ECB queue, `reconcileECBLedger()`; **unread:** `unreadCount(...)` (pure) / `unreadBroadcastCount` / `markBroadcastsSeen()` | A2 ✅ |
| ECB value | `Messaging.swift` | `TradeRequest.ecbValue`/`ecbAmount`/`isValidECB`/`clampECB`; `ecbText(_:)` | A4/S-ENG-8 ✅ |
| Service | `CloudKitMessagingService.swift`, `LocalMessagingService` | generic `save<T>/fetch<T>`, record types per model | S-SYNC-3 |
| Push subscriptions | `CloudPush.swift` | `setup()` (`CKQuerySubscription`s) | S-SYNC-3 |
| Identity claim | `AccountService.swift` | `claim(employeeID:appleUserID:displayName:) -> ClaimResult`, record `AccountClaim`/`claim_<id>` | — |

## 7. UI screens

| Screen | File | Key symbols | Spec |
|---|---|---|---|
| Root tabs + dock + onboarding + launch task | `ContentView.swift` | `ContentView`, `OnboardingView`, `MessagingDock` overlay, `AppAppearance` | — |
| App entry | `BATMANReaderApp.swift` | `@main`, perms, `.modelContainer` | — |
| Home (calendar/intents/import) | `HomeView.swift`, `HomeCalendar.swift` | `HomeView`, intent calendar, `MarkIntentsToolbar`, `handleImport`, `reconcileSnapshot`; metrics header → **U-HOME-1** | U-HOME |
| Trades (search/intents/ECB) | `TradesView.swift`, `TradeIntentsFeed.swift` | `TradesView` segments, `PackageDetailView`, `HandoffChain`, `TraderChips`; default=Search → **U-TRADES-1** | U-TRADES, U-CARD |
| Availability / two-way / ECB | `AvailabilityView.swift` | Find Candidates, `TwoWaySheet`, `MiniScheduleGrid/Legend`, ECB flow | U-SEARCH, U-SWAPS |
| Day pickers / strips | `ShiftSelectCalendar.swift`; `AvailabilityView.swift` | `ShiftSelectCalendar` (multi-select; shows intent bar + note dot, C3); `CoverageStrip` | C3 ✅ |
| Inbox / channels / chat | `MessagingViews.swift` | `InboxView`, `ThreadView`, `ChannelView`, `MessagingDock`, `StatusBadge` | U-INBOX, U-MSG |
| Slack-style atoms | `SlackKit.swift` | `Avatar`, `SlackMessageRow`, `SlackComposer`, `ChannelHeader` | U-MSG |
| Settings | `SettingsView.swift` | account/contact/notif/calendars/iCloud toggle/dev tools; qual-swap section → **U-SETTINGS-1** | U-SETTINGS |
| Help / tester guide | `HelpView.swift` | `HelpView`, `TesterGuideView` | I1 |
| Design tokens + colors | `DispatchPalette.swift` | `DS` tokens, font ramp, `mineScheme/peerScheme/loopTrade/traderThemes/highImpact`; add `qualSwap/vacation/urgentAlert` | U-GLOBAL, S-UIUX-NEW |

## 8. System / platform

| Feature | File | Key symbols | Spec |
|---|---|---|---|
| Settings store (SOT) | `SettingsManager.swift` | `SettingsManager.shared` (all `batman.*` keys), `DevAccess.shared` (pwd `batman2026`), `useCloudKit`, openness/blacklist/mercenary | — |
| Notifications | `NotificationManager.swift` | `requestPermission`, `scheduleAll(for:)` | — |
| Calendars (EventKit) | `EventKitManager.swift` | personal "AA Schedule" + shared "AA Dispatch"; `sync(diff:)` | — |
| Availability calendar | `AvailabilityManager.swift` | `buildFromSchedule()`, `eligibleTypes(forOffDay:workedShifts:)` (8h rest), shared-calendar I/O | — |
| Widgets + app-group data | `WidgetData.swift`, `BATMANWidgets/*` | `WidgetSnapshot`, `update()`; group `group.com.ervinlee.batmanreader` | — |
| App Intents / Siri | `ScheduleIntents.swift`, `AvailabilityIntents.swift`, `AIScheduleSummaryIntent.swift`, `ShiftEntity.swift` | the intent structs | — |
| Trade history / metrics | `TradeHistoryStore.swift` | `entries`, `record`, `markComplete`; **add** `successRate`, `searchCount(period:)` | S-DATA-4, U-HOME-1 |

## 9. CloudKit record types (public DB, container `iCloud.com.ervinlee.batmanreader`)

| Record | recordName | Fields | Service |
|---|---|---|---|
| `RosterPackage` | `master_roster` | `csv`(CKAsset), `version` | `CloudKitRosterService` |
| `TradeProfile` | `profile_<id>` | `workerID`,`updatedAt`,`payload` | `CloudKitTradeProfileService` |
| `BroadcastPost`/`Reply`/`TradeRequest`/`TradeResponse`/`ModerationHide` | UUID / derived | flat keys + `payload` | `CloudKitMessagingService` |
| `AccountClaim` | `claim_<id>` | `employeeID`,`appleUserID`,`displayName` | `AccountService` |
| `PrivateState` (**PRIVATE DB**) | `private_state` | `privateNotes`,`updatedAt` | `CloudKitPrivateStateService` (A3) — needs Prod schema deploy |

## 10. Build/identity facts
Bundle `DX.BATMANReader` · app v1.9 build 3 (widget 1.1) · iOS 26 (app) / 27 (widget) · device family iPhone+iPad (never "My Mac") · App Group `group.com.ervinlee.batmanreader`.

---

### Status of in-flight changes (keep current)
- ✅ **S-PARSE-2** intent preservation — `DayIntentStore.reconcile(diff:)` (diff-based) + `HomeView.reconcileSnapshot`; tested.
- ✅ **S-PARSE-1** vacation parse — `ScheduleParser.appendShifts` `L|V`→off+`leaveCode`; tested.
- ✅ **S-PARSE-2** vacation auto-intent — `DayIntentStore.reconcile(diff:)` sets soft Must-Be-Off + "vacation" note on flip; tested. *Pending:* vacation display (U-VAC), `RosterShift.leaveCode` field (others' vacation display).
- ✅ **Tooling** — `scripts/check_arch_map.sh` guards this map (run in DoD).
- ✅ **B2/S-ENG-5** single `tradeTypeLabel` SOT; `peopleCount`=distinct incl. self; 6 sites unified; source-scan guard. Tested.
- ✅ **S-ENG-9** — negative intents published + Must-Be-Off gate (June-23); Keep-day give-side guard; **feed/search recompute** via `MatchInputsSignature.current` (`.onChange` in `TradeIntentsFeed` + `AvailabilityView`). Tested. ⬜ (optional) single `canTake`/`canGive` evaluator cleanup.
- ✅ **S-ENG-6** mercenary forces openness `.all` (`SettingsManager.isMercenaryMode` didSet). Tested.
- ✅ **D2** Trades defaults to Search segment (`TradesView.segment = 1`). ✅ **C5** stale "import roster" copy removed (`AvailabilityView`). ✅ **D1** bookends already default (`SettingsManager.tradeOpenness` = "bookends").
- ✅ **A4/S-ENG-8** ECB 0.5 steps (5–25): `TradeRequest.ecbValue: Double?` + `ecbAmount`/`isValidECB`/`clampECB`/`ecbText` (Messaging); stepper + all inbox/thread display sites. Tested.
- ✅ **D2a** Intents-tab count badge — `DayIntentStore.activeIntentCount` → `TradesView` segment label. Tested.
- ✅ **A2** channel unread badge clears on open — `MessagingStore.unreadBroadcastCount`/`markBroadcastsSeen` + `MessagingDock`/`ChannelView`. Tested.
- ✅ **C1** "Individual takers" → "Individual Swaps" (3 sites) + forbidden-literal guard.
- ✅ **F3** char counters — pure `CharLimit.state` (TradeEngineModels) + `CharCounter` view (SlackKit); on note/status/private-notes. Tested.
- ✅ **A7/B8** status-by-name — `NameWithStatus` (SlackKit) + `participantStatus(_:)`; applied to inbox row, `TraderChips` (id param), thread card. Peers only. Tested.
- ✅ **U-VAC** vacation display — `Shift.isVacation`, `BrickPalette.vacation` (teal), beach glyph in `HomeCalendar.dayContent`. Tested. *Pending:* `RosterShift.leaveCode` (others' vacation in roster — deferred, low value).
- ✅ **C3** Trade Search picker shows intent bar + note dot (`ShiftSelectCalendar`). 
- ✅ **B3 (archive/delete)** — `MessagingStore.archivedRequestIDs`/`active(...)` (pure) + inbox swipe Archive/Delete/Unarchive + Archived section. Tested. ⬜ invalid-trade detection + urgent alerts (S-VALID, separate).
- ✅ **B4** reply edit/delete — `BroadcastReply.editedAt/deleted/isDeleted` + `MessagingStore.editReply/softDeleteReply/isMine(reply)`; `ChannelView.replyRow` tombstone + edited marker + edit alert. Tested.
- ✅ **E1 (General)** — `ChannelView` picker General·Trades·Feedback + `channelMeta` switch (fallback safeguard). ⬜ per-channel unread circles.
- ✅ **B7** admin pin — `BroadcastPost.pinned/isPinned` + `MessagingStore.setPinned`/`sortedForChannel` (pure) + `postMenu` admin Pin/Unpin + "Pinned" badge. Tested. Fixed `editPost` dropping channel.
- ✅ **F1** EVERY intent is a paintable brush (was only 2/4 working, 0 off) — `IntentBrushes.working` = `{dontWantToWork(Trade away), mustWork(Keep), neutralOpen(Open)}`; `IntentBrushes.off` = ALL `OffIntentState` `{mustBeOff, wantToWork, neutralOpen}`; + AM/PM/MID granular. `HomeView.applyWorking`/`applyOff` paint per tap. **Brush-completeness test** asserts coverage vs the enums. Tested.
- ✅ **F2** note-stamp — `HomeView.noteBrush`/`stampNote` + toolbar field (≤50, counter). Build-verified.
- ✅ **Audit discharges** — A5 `TradeRouter.rankPackages`; A6 `TradeMatcher.goldCountPure`; D1 bookends fallback; A7/B8 `InboxView` now `refreshOthers()`; C3 covers ECB picker too; B4-chat `TradeResponse.editedAt/deleted` + `editMessage`/`softDeleteMessage`; local `postReply`/`sendResponse` upsert; #10 vacation soft-rule; #11 `IntentTallyBar`. All tested. See `ASSUMED_PRESENT.md`.
- ✅ **A3 private notes** — `PrivateStateStore`/`CloudKitPrivateStateService` (in `CloudKitMessagingService.swift`) + `LWW` (tested) + `ContentView.task` launch-sync + editor publish-on-close; `SettingsManager.privateNotesUpdatedAt`/`editPrivateNotes`/`applyRemotePrivateNotes`. ⬜ status-sync (chunk #12), device-verify, Prod schema deploy. **Build note:** new `.swift` files must go in an existing compiled file (synced-group MCP caveat).
- 🔄 **S-ENG-10** — ✅ Want-to-Work overrides bookend gate (`TradeProfile.wantToWorkDayIDs`+`wouldPickUp`, one-sided, not over blacklist/Must-Be-Off), tested. ⬜ Trade-away scoring boost + two-sided bookend ranking (ASSUMED_PRESENT #15).
- 🔄 **S-VALID** — ✅ `TradeMatcher.staleDaysPure` (tested) + ThreadView urgent invalid banner. ⬜ inbox-wide invalid badge + auto-clear (ASSUMED_PRESENT #17).
- ✅ **H1** Home metrics header — `Metrics.successPercent`/`searchCount` (pure, tested) + `TradeHistoryStore.searchLog`/`recordSearch`/`completedCount`/`resetMetrics` + `HomeMetricsHeader`. LOCAL; global aggregation = chunk #18.
- ❌ **A1** others' intents on calendar — **REMOVED (R2-#2)**: unrequested speculative UI. Deleted `LayerVisibility.othersIntents`, the `person.2.fill` toggle, `othersBadge`, and `TradeProfileStore.peersInterested`/`peerInterest`/`peerInterestMap`/`peerInterestCounts` + their tests.
- ✅ **R2-#2 calendar layers** — exactly 3 toggles: Notes, Intent colors, **Shift availability** (`clock.badge.checkmark`, new — the AM/PM/MID off-day pills are now gated by `layers.availability`, previously always-on).
- ✅ **R3-D1/G2c peer intent palette** — `PeerIntentColor.forDay(day:seeking:wantToWork:mustBeOff:keep:) -> Color?` (pure SSOT in `DispatchPalette`; precedence must-be-off → keep → trade-away → want-to-work; reuses `OffIntentState`/`WorkingIntentState.brickColor`). `TwoWaySheet.theirIntent` now shows the peer's FULL intent (was only `theirSeeking` in one color); `load()` stores `theirWantToWork`/`theirMustBeOff`/`theirKeep` from the peer profile. Red proven (`cannot find 'PeerIntentColor'`) → 6 fail-tests green.
- ✅ **R3-#3 Intents = separate 2-person trades** — `packages()` step 1 now emits a 2-person package **per peer** for the days they can reciprocally cover (full OR partial; full-cover flagged `isOptimal`), instead of only full-cover solos + a bundled N-person fallback. So when no one covers everything, the user gets individual 2-person trades that **outrank** circular loops via `rankPackages` (peopleCount). Ranking guard test added (2-person beats a 3-loop even with more 🔥). Build-verified emission + harness-proven ordering.
- ✅ **R3-G3 n-way bookend awareness** — `NWayRoute.bookendCount` computed in `nWayRoutes` (legs anchored for their RECEIVER via `TradeMatcher.isAnchored`); the circular package's `bookendTotal` now = real per-leg count (was all-or-nothing), so split-heavy loops (the IMG-43/44 Aug-10 case) rank **below** clean ones in `rankPackages`. Pure `TradeScore.routeDesirability(legBookends:legFires:)` (split penalized, 🔥 boosted) for best-first/threshold. Red proven → 3 fail-tests green. (A8 already *prevents* no-profile splits; G3 *demotes* published-`.all` splits.)
- ✅ **R3-B1 international qual-swap button** — `DeskRules.hasQualGatedSelection(desks:)` (pure; only NON-D required quals count — D is universal) drives a **"Qual Swap"** button in `FindCandidatesSection` controls: gray+disabled normally, **glowing green** when a selected desk is international. Tapping opens `QualSwapDaysSheet` — a per-day paged (`.page` TabView) list of the qual-swap packages, each with **Broadcast** → the existing blast picker. Red proven (the failing test caught that domestic desks require universal "D") → 3 fail-tests green. Sheet build-verified.
- ✅ **R3-B2 package/request merge (core)** — `TradeMerge.canMerge(base:bridge:)` + `merge(...)` (pure, `Messaging.swift`): a clean base trade + an accepted qual-swap **bridge** sharing the give-day compose into ONE request carrying the bridge's `qualSwap` (new id, idempotent — merging an already-merged request is a no-op). Red proven (`cannot find 'TradeMerge'`) → 5 fail-tests. *(Messaging lifecycle — archive originals + save merged + a UI button — is the follow-on.)*
- ✅ **R3-E1/E2/E3 channel + settings UI** — **E1:** `MessagingStore.sortedForChannel` flipped to **oldest→newest** (pinned first) so the thread reads top→bottom; channel already nests replies under a tappable **threadline** with expand/collapse + a "Hide N replies" control (researched against Reddit patterns: capped indent, threadlines, collapsible). E1 ordering red-proven → 2 tests + the existing pin test reconciled. **E2:** author's published `statusBroadcast` (emoji) shown under their name in `postRow`. **E3:** qual-swap sections tinted indigo, relief section tinted teal (`.listRowBackground`) to separate them from the blacklists. E2/E3 build-verified.
- ✅ **R3-C1 SAVE-gated recompute (phase 1)** — `DayIntentStore.intentsRevision` + `markIntentsSaved()`; feeds recompute on `intentsRevision` change **instead of** `MatchInputsSignature` (which re-ran the heavy search on every edit). So editing intents no longer re-runs the search constantly — you SAVE, then it re-runs once. Red proven → 2 fail-tests.
- ✅ **R3-C1 phase-2 — dirty Save + Save-or-Discard guard** — `DayIntentStore.hasUnsavedChanges` (set by every user mutation, cleared on Save/Discard) + a `savedBaseline` snapshot with `discardChanges()` (true revert to last save). The **Save** button now lives *inside* the Mark Intents section (`MarkIntentsToolbar.saveButton`): transparent/faded green when clean, glowing green when there are unsaved edits. Leaving — tapping **Done** (`HomeView.attemptLeaveEditing`) or switching tabs (`ContentView.tabSelection` binding) — with unsaved edits forces a **Save / Discard / Keep Editing** confirmation. The general (read-only) Home view no longer marks intents: tap is a no-op; the per-day editor opens via long-press **only** inside the section. Red proven (no-op discard → flag assertion fails). Tests: C1.2 dirty-on-edit + discard-to-baseline + discard-to-last-saved.
- ✅ **R3-Intents marketplace engine (distinct from Trade Solutions)** — `TradeRouter.intentSolutions(excluding:generation:)` is the Intents feed's OWN engine — NOT `packages()`. It's a marketplace of intent-for-intent deals involving you: per peer it runs `twoWayExplore`, splits each side's coverable days into MARKED (`wanted`) vs PREF, and `assembleIntentDeal` (PURE, tested) builds the best balanced two-person deal that maximizes mutual marked intent — seeding from EITHER side's marked days (a peer's marked day seeds a deal even if you marked no give). `rankIntentPackages` (PURE, tested) sorts **most mutual intent first** (vs `rankPackages`' fewest-people-first). Heavy 3+/circular is gated to Lucky via `generation` (U-PERF). Feed wired (`TradeByIntentsFeed.reload`), header relabeled "Intent Matches". Red proven (marketplace-seed guard). *Pending:* peer-intent-seeded 3+ (only my-seeded circular for now), set-contiguity for bookend peers.
- ✅ **R3-U-PERF fast background / Lucky-gated heavy search** — `TradeRouter.packages(…, generation: SearchFilter)`: the 3+ multi-person cover (step 2, gated `generation.maxPeople >= 3`) and the N-Way circular DFS (step 3, gated `maxPeople >= 3 && engine != .minCost`, `maxDepth = maxPeople`) run ONLY when the caller widens the scope. `SearchFilter.fast` (`.minCost`, 2 people) is the default → background feeds (Intents `reloadFast`, Trade Solutions `searchFast`, SAVE/whatIf reruns, `JustTwoSection`) produce **2-person only**, cheap. The heavy search runs once per **Lucky → Generate** (`onGenerate(filter)`), and **Reset** returns to fast. Contract-tested (U-PERF threshold guards); gating behavior is build-verified, device-verify.
- ✅ **R3-Lucky Generate/Reset + label** — `SearchFilter.isActive`/`summary(nameFor:)` (tested A2b, red proven); `MasterFilterSheet` edits a draft → **Generate matches** (`onGenerate`) / **Reset to normal** (`onReset`) / Cancel; both feeds' Lucky button shows the active criteria ("Lucky: N-Way · ≤3 · with Cary"), tints orange when active.
- ⚠️ **R3-A1 "I'm Feeling Lucky" UI** — `TradeByIntentsFeed` gains a Lucky button → `MasterFilterSheet` (engine / max-people 1–4 / force-include person from full roster) + visible filter chips; results = `searchFilter.filter(packages).prefix(100)`. Roster dropdown = distinct `RosterStore.entries` names (G2a-resolved). **Build-verified (UI).** *Assumption:* filter is applied **post-search** to the auto-run results — the deeper in-DFS best-first seeding + cancellable Task + 60-cap-when-Both are NOT yet wired (follow-on). `displayed.prefix(100)` is the current cap.
- ✅ **R3-A2 Master Filter (core)** — `SearchFilter{engine: minCost|nWay|both, maxPeople 1…4, requiredWorkerID}` (pure, `Equatable`) + `.filter(packages)` (engine→methodology, maxPeople cap, required-person inclusion via assignments∪route.participants). `Engine` `CaseIterable` universe guard. Red proven (`cannot find 'SearchFilter'`) → 6 fail-tests. (UI sheet/button = A1.)
- ✅ **R3-A3 drop intent-only toggle** — no-op: the search already uses all-eligible (R-A/A8); no intent-only gate exists to remove.
- ✅ **R3-H1 unified acceptance score** — `LegFeatures` + `TradeScore` (`TradeEngineModels`): `legProb = σ(weighted features)`, `packageProb = ∏ legProb`, `packageLogProb = Σ log` (additive → `upperBoundLogProb` is an admissible prune bound). Weights hand-tuned (split heaviest negative), later fittable from accept/decline data. THE single scoring model for every surface (used by A1 best-first, A2 threshold, G3 desirability). Red proven (`cannot find 'LegFeatures'`) → 8 fail-tests (monotonicity, weakest-link, product==exp(logsum), admissible bound, ECB lever). *(wiring into the engines = A1/G3.)*
- ✅ **R3-G4 import-success audit** — `ImportAudit.validate(workers:selfID:) -> ImportReport` (pure, `ScheduleParser.swift`): flags name-less workers (reuses `TradeNames.isAllDigits` — the "660615" root), missing-self, duplicate IDs, empty parse; advisory (never blocks). Wired into `HomeView.handleImport` → appends a "looks good ✓" / "⚠️ Import check: …" line to the result banner. Red proven (`cannot find 'ImportAudit'`) → 5 fail-tests green.
- ✅ **R3-D5 qual-swap sorts under clean** — `TradePackage.needsQualSwap` + a `rankPackages` tiebreak inserted **directly after peopleCount** (before tier/🔥/bookend): within the same N, clean packages always precede qual-swap ones; usual priorities apply inside each group; N still dominates. Red proven (assertion) → 3 fail-tests green.
- ✅ **R3-D4 propose-button label** — `proposeButtonTitle(count:name:)` (pure, in `TradeEngineModels`): 1 counterparty → "Propose to {Name}", 2+ → "Propose to All", 0/nameless → "Propose". Wired into `PackageCard` (was hardcoded "Propose to all" even for one person — the Just-2 complaint). Red proven (`cannot find 'proposeButtonTitle'`) → 5 fail-tests green.
- ✅ **R3-D1/G2a peer-name resolution** — `TradeNames.resolved(displayName:rosterName:workerID:)` (pure SSOT: real displayName → real roster name → employee #; "real" = non-empty, ≠ workerID, not all-digits) fixes the IMG-42 "660615" bug. Wired into `TwoWaySheet` via `peerName` (nav title, calendar header `MiniScheduleGrid`, sent/no-bridge messages); `peerDisplayName` set from the loaded profile in `load()`. Red proven (`cannot find 'TradeNames'`) → 5 fail-tests green.
- ✅ **R3-F1 POSITIONAL trade colors (revised)** — per user: you = blue, then **seat-by-seat** red (2nd person) → orange (3rd) → green (4th) → violet/magenta. `TradeColors.color(forParticipant:myID:orderedPeers:)` (index into reordered `traderThemes`). Wired: `TwoWaySheet` ([peer]→red), `PackageCard` (assignment order), `PackageDetailView` (participants), `HandoffChain` (leg first-appearance). Replaces the earlier stable-hash approach. 6 fail-tests green.
- ⛔️ ~~**R3-D1/F1 stable per-worker color**~~ — superseded by the positional version above (hash colors weren't the spec). `TradeColors.forWorker(workerID:myID:)` (you = `mineScheme`; each peer = deterministic UTF8-byte-sum index into `traderThemes`, NOT randomized `hashValue`) is the SINGLE color source for every trade surface. Wired: `TwoWaySheet.themColor` (was hardcoded `peerScheme` red — the IMG-42 blue/red regression), `PackageCard` chips, `PackageDetailView.colorFor`, `HandoffChain.color` (removed index-based `orderedPeers`). 6 fail-tests incl. an empty-palette guard; **red proven** (broke `forWorker`→all-mine, "peer is never blue" failed) then green. First sub-step of D1.
- ✅ **R3-A8 no-profile → Bookends Only** — `TradeProfile.defaultForUnpublished(workerID:name:)` (openness `.bookends`, epoch `updatedAt` so a real profile wins LWW) replaces the 4 scattered `openness:"all"` missing-peer fallbacks (`TradeRouter.profileFor`/`openProfile`, `TradeMatcher` qual-bridge, `TwoWaySheet.load`). A profileless receiver now fails `canCover` for a non-bookend pickup → split trades never generated. 4 fail-tests (defaults-bookends, rejects-split, accepts-bookend, explicit-open-unaffected). Build + harness green. (Published `.all` peers handled by G3 desirability, not this.)
- ✅ **R2-R-B status/intents cross-device** — profile round-trip test (status + all intent sets survive the JSON `payload` codec); single publish funnel (`TradeSettingsSheet.onDisappear → publishProfile`); `refreshOthers()` on Home `.task`; `TwoWaySheet` renders the peer `statusBroadcast` banner. Device 2-account verify pending.
- ✅ **R2-#5 bookend display + intent key** — `TwoWaySheet.legCard` gates the "bookend" tag on `leg.bookend` (was unconditional); `TradeMatcher.anchored` made `internal` + tested (isolated give-day → not a bookend). Reusable `IntentColorKey` (calendar-hue legend + 🔥/📖) in the two-way sheet & ECB.
- ✅ **R2-#10 mass-action UX** — `overwriteConfirmed` (ask-overwrite once per painting session, reset on mode/brush `onChange`) in `applyOff`/`applyWorking`; `availabilityPills` puts AM/PM/MID inline with the intent brushes in a horizontal `ScrollView` under a **"Shift Availability"** label; `brushPill` enlarged (`.subheadline`, stroke+fill selected state). (Lag #10a resolved by removing the others'-intents badge per #2 — no per-tap 500-peer refilter remains.)
- ✅ **C4** person search + pin — `PeopleFilter.arrange` (pure, tested) + search field + per-row pin in `FindCandidatesSection`. Per-session.
- ✅ **TradeProfile explicit init** — froze the construction symbol (prevents stale memberwise-init linker errors). AUTORUN OFF.
- ✅ **B6 reactions (everywhere)** — `Reaction` + `toggle`/`counts` (pure, tested) + `MessagingStore.react(to:emoji:)` for `BroadcastPost` **+ `BroadcastReply` + `TradeResponse`** (all explicit init) + `reactionsBar`/reusable `ReactionChips` on posts, replies, and 1:1 chat. (#19 done.)
- ✅ **S-VALID inbox-wide** — `MessagingStore.invalidRequestIDs`/`refreshInvalidRequests` (recomputed each `refresh()` → auto-clears) + `RequestRow` "Invalid" badge. (#17 done.) **#15 (scoring) delivered via §U U4** (two-sided bookendTotal + trade-away fireCount).
- 🔨 **Qual swaps (Q-series) — engine layer DONE, flow/UI TODO:**
  - `TradeTiming.validStartHours = {5,13,21}` + `isTradeable(startHour:)` — GLOBAL rule, only 0500/1300/2100 trade (TradeMatcher.swift). ⚠️ still TODO: wire into the main matcher's candidate-building (enforced in qual-swap discovery only so far).
  - `DeskRules.qualValue` / `acceptsQualSwap(into:fromCurrentDesk:values:blacklistDesks:)` — Q4 value model (higher=better, 0=qual-blacklist, unset/nil=max) + desk-number blacklist; `TradeProfile.acceptsQualSwap(...)` convenience.
  - `QualSwap.bridges(giveDesk:takerQuals:startHour:workers:excludeIDs:)` — S-ENG-4 3-party bridge discovery (C slides onto the give-desk, freeing their desk for off-taker B; A goes off).
  - `SettingsManager.qualValues:[String:Int]` + `qualSwapBlacklistDesks` (published on TradeProfile).
  - ✅ **Q4 Settings UI** — `qualSwapSettings` in `TradeSettingsSheet` (per-qual picker + desk blacklist; T32).
  - ✅ **Q3/Q6 state machine** — `QualSwapLegStatus` (5-case CaseIterable: waiting/offersOpen/offersFull/finalized/invalid) + pure `QualSwapLeg.status(...)` reducer + first-5 `acceptorCap`/`acceptIsOpen`; tested incl. universe guard.
  - ✅ **Q3/Q5/Q6 data model** — embedded `TradeRequest.qualSwap: QualSwapLegData?` (+ explicit init freeze) holding `candidates`/`acceptances`/`chosenWorkerID`/`takerDeclined`/`expired`; pure `addingAcceptance` (first-5 cap + idempotent), derived `status`/`chosenAcceptance`. Store: `acceptQualSwapBridge`/`finalizeQualSwap`/`declineQualSwap` (+ local `sendRequest` now upserts). CloudKit JSON payload round-trips it. Tested.
  - ✅ **Bridge discovery + roles** — CloudKit request record now writes a flat queryable `candidateIDs` list; `fetchRequests` adds a `candidateIDs CONTAINS me` query so blasted bridges see the request. Pure `TradeRequest.qualSwapRole(for:)` (giver/taker/bridge/none, 4-case) + `QualSwapLegData.statusText`. Tested. ⚠️ schema-deploy `candidateIDs` (ASSUMED_PRESENT #20).
  - ✅ **Inbox UI (Q3/Q5/Q6)** — `TradeDetailView.qualSwapSection` (role-aware: bridge Accept / taker acceptances-list + Choose + Decline / giver-&-others contingent) + `qualSwapTint` color indicator. Driven by `statusText`/`qualSwapRole`. (T33)
  - ✅ **Q2 adapter** — pure `QualSwap.candidate(from:)` (bridge shift → blastable candidate, derives freed-desk qual); tested.
  - ✅ **Push (Q3 partial)** — `CloudPush` bridge subscription (`candidateIDs CONTAINS me` → "You can help fill a qual swap").
  - ✅ **Q1 COMPLETE** — `DeskRules.isQualBlocked` + `QualSwap.solutions` (3-party assembly, tested) + generator in `TradeRouter.packages` (qual-blocked give-day → qual-swap `TradePackage` with leg; bridge not in N) + `rankPackages` exempts qual-swap from the bookends cap (tested) + `PackageCard` purple Q-square badge + `propose`→`QualSwapPickerSheet` blast in Trade Solutions & Just 2. Surfaces automatically across all package feeds (incl. Intents via shared `packages()`).
  - All pure + tested (Q4, S-ENG-4, TIMING, Q-leg, Q-leg-data, Q-role, Q2-adapter, Q1-block, Q1-solution). ⬜ remaining polish: acceptance/finalize push needs record-UPDATE subscriptions (creation-only today).
- 🔨 **§U Unified trade engine + Solutions UI** (spec in NEXT_CHANGES §U). Build order 1–10, test-first:
  - ✅ **U1 step 1** — `TradeEligibility.canCover` SSOT (`EligibilityOptions` physicalOnly/full + `CoverCheck`), pure @MainActor; off/qual/rest/bookend always, cap+softgates toggle. Fail-test-proven (stub→red→green).
  - ✅ **step 3** — `twoWayExplore` delegates to `canCover` (Search + Intents + Individual Swaps now share one eligibility test).
  - ✅ **step 4** — `TradeRouter` `canCover` closure delegates to the SSOT (routes/circular inherit it).
  - ✅ **step 5** — ECB recipient filter via `TradeEligibility.canCover(.full)` (cap + must-be-off + pills); want-to-work stays a 🔥 surface, not a filter; searcher ungated.
  - ✅ **step 7** — `rankPackages` v2: fewest-people (N) groups → tier (🔥+bookends → 🔥 → bookends-only) → 🔥 count → total bookends; bookends-only capped to top-two bands (`max`,`max−1`). `TradePackage.fireCount`/`bookendTotal` added (+ explicit init). Fail-test-proven.
  - ✅ **step 6 (scoring)** — `packages()` populates `fireCount`/`bookendTotal` (both sides) from retained per-peer plans; circular approximated from route metadata.
  - ⚠️ **step 6 (generation)** — literal per-N greedy∪circular loop NOT rewritten (untested async core; conservative). Current generation (solo + min-people + circular) + rankPackages N-grouping delivers the sorted result; strict per-N generation is a flagged follow-up.
  - ⚠️ **step 2** — `candidatesForTrades` keeps its inline physical gate (set-anchor bookend differs from canCover's single-day); equivalent to `canCover(.physicalOnly)`. Retire when the Search candidate-list UI is removed (step 8) and ECB calls a canCover-based finder directly.
  - ✅ **step 8 (UI)** — Trades picker `Search`→**"Trade Solutions"**; that tab is **packages-only** (individual-takers grid removed; solo packages cover N=2). `PackageCard` header gains 📖 (total bookends, both sides) + 🔥 (mutual-intent) badges.
  - ✅ **step 9 (UI)** — new **"Just 2"** segment (`JustTwoSection`): pick a day → direct two-person packages (`peopleCount == 2`), same priority sort, + a **dropdown** filtering to one dispatcher.
  - ✅ **step 10** — inbox **🔥 intent-match**: pure `MessagingStore.intentMatch` (Want-to-Work pickup [ECB-only] OR Trade-Away day taken from me) + `matchesMyIntents` + `RequestRow` badge. Fail-test-proven. (Push stays in-app badge — CloudKit subs can't see intents.)
  - ⬜ CAL1 (Apple Calendar title = shift+desk only) — logged in NEXT_CHANGES, `EventKitManager.swift`.
- 🔨 **REL1 Relief Dispatcher** — `SettingsManager.isReliefDispatcher`/`reliefScheduleThrough`/`effectiveReliefThrough`; `TradeProfile.reliefThrough` (published via JSON payload, no schema deploy) + pure `isPastRelief`/`scheduleUnknown` (tested). Gated in `TradeEligibility.canCover` (cover-side), `twoWayExplore` (give+take), `nWayRoutes` (give-side); `EventKitManager` skips/removes post-relief events; Trade Settings toggle + forced DatePicker. ✅ own-display: `ShiftStore.shifts` is a relief-filtered computed view over private `rawShifts` (blank everywhere — Home, pickers, widget, Shortcuts); shared availability calendar skips post-relief off-days. REL1 complete.
- ✅ **#12 A3 status sync** — `SettingsManager.statusUpdatedAt` + publish-on-edit + `TradeProfileStore.syncMyStatus()` (LWW.pick vs own profile) at launch; rides profile JSON payload (no deploy). Tested (LWW). (T39)
- ✅ **#18 H1 global metrics** — `MetricEvent` log + `CloudKitMetricsService` + `MetricsStore` + pure `Metrics.global` (tested); Home header shows team-wide totals w/ local fallback; hooks on search/propose/complete. Needs `MetricEvent` schema deploy. (T40)
- ✅ **Qual-swap response push** — `hasQualSwap` flag + `.firesOnRecordUpdate` taker subscription (`CloudPush.ensure` gained an `options` param). Needs `hasQualSwap` queryable deploy. (T41)
- ✅ **C6 — Intents flattened** to ONE sorted package list (`packages(excluding:)` + `PackageCard`, qual-swap picker routing); tier accordions/`tieredSolutions`/`RouteCard`/`TierLegendSheet` no longer used (consistent with §U "everything is packages"). Desks **46, 47, 93–98** now explicitly domestic (tested).
- ✅ **G1 Outlook email** — pure `TradeEmail.body`/`subject`/`mailtoURL` (tested) incl. Must-Be-Off **blackout days**; `SettingsManager.tradeEmailDL` (default `DL_dispatch_trades@aa.com`); "Email trade to dispatch DL" button in `TradeDetailView` opens a prefilled mailto. (G2/G3 deep-link not needed for this flow.)
- ✅ **B5 images (posts)** — `BroadcastPost.imageBase64` (downscaled JPEG base64, rides the JSON payload — no protocol/CKAsset change, no deploy); `PostImage.encode/decode` (downscale + size-guard < 700KB); `PhotosPicker` attach in `ChannelView` composer + inline render in `postRow`. Replies/chat images = follow-up.
- ✅ **Z1 cleanup** — `EngineTests` DEBUG-gated (stripped from Release) + dead code removed (`tieredSolutions`/`route(from:)`/`RouteCard`/`TierLegendSheet`).
- ✅ **Z2 changelog** — `ChangeLogEntry`/`ChangeLog.current` + pure `shouldShow` (tested) + `ChangeLogView` shown once per new build on launch (`AppInfo.build` vs `lastSeenChangelogBuild`). (T45)
- 🔨 **Round-2 device fixes** (`FIXES_ROUND2.md`): ✅ **R-A** universe=roster (preloaded schedules) · ✅ **#4** circular needs ≥3 (`nWayRoutes` depth≥3 + `TradePackage.isCircular`) · ✅ **#4b** earliest-date sort tiebreak (`earliestDayID`). ✅ **P0** data-wipe hardened (`FetchMerge.keepCacheOnEmpty`) · ✅ **#3** tally factors + circled count (`TradesSegmentBar`) · ✅ **#1** WTW auto-X (red ⊘ + gate; `Legality` consolidated onto tested `eligibleTypes`). ✅ **#9** metrics → totals You+Company, shared period, successful=accepted+archived (`Metrics.count`/`isSuccessful`; `.trade` logged on `archiveRequest`). ✅ **#8a** reactions 1-per-user (`Reaction.setSingle`) · ✅ **#8b** premium reply box + send icon + photo (`BroadcastReply.imageBase64`). ✅ **#7** email moved to Trade Solutions/ECB tops (Outlook `ms-outlook://compose` + mailto fallback; dispatchBody/ecbBody) + redundant note dropped · ✅ **#10f** "Execute Trade"→"Propose Trade". ✅ **#6** ECB 2-col names + bookend-first sort + two broadcast buttons (Bookends/All). ⬜ remaining: mass-action UX (#10), fonts/colors (#10d/e), #5 bookend display + intent key, mystery layer (#2), status visibility (R-B; #8c data returns on deploy). Meta-fix: composition/seam tests (MatchUniverse, decode-compat) added.
- ⬜ I1 guides (parked).
</content>
