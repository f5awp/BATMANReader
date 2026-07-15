# Carryover Vacation — Staged Implementation Plan (published / option b)

A per-day **"Carryover Vacation"** toggle in the day detail that turns a day into a **vacation (OFF)** day, **published** so other dispatchers' matching treats you as on vacation (not working/available) that day. Fixes: a carryover-vacation day (not coded in the master, e.g. `L,S`) that renders as a worked shift, so you show as available.

## Why published needs an override layer
`RosterEntry` (the shared roster others match against) has **no `leaveCode`** — a peer's day is only `isOff`. A carryover day the master codes as worked (`resolveDay`) shows the person **working**. So the override must (a) live on the user's `TradeProfile` (others fetch it) and (b) be **applied on top of the roster** wherever a peer's day is evaluated → force that day OFF/vacation.

## Global rules (every stage)
re-grep the touched anchors → change only declared files → `XcodeRefreshCodeIssuesInFile` (0 errors) → `BuildProject` (success) → `TradeEngineTests.runAll()` (**0 failures**) → stage behavioral check → commit (`CARRYOVER:` prefix, pathspec) → STOP. New Codable fields are **optional + defaulted** (old records decode); everything rides the JSON `payload` (no CloudKit index). Never proceed on red.

## Code map (verified 2026-07-15; re-grep before each stage)
| Symbol | Location | Role |
|---|---|---|
| `Shift.isVacation` / `isVacationOrigin` / `vacationLeaveCodes` | Shift.swift:54 / :57 / :50 | vacation = `leaveCode ∈ {V,w}` && isOff; calendar reads `isVacation` |
| `ScheduleParser.resolveDay` | ScheduleParser.swift:212 | worked-vs-off resolution (why `L,S` renders worked) |
| `DayIntentStore` (workingIntents :78, offIntents :82, manualOffDays :105, Baseline :35, exportSnapshotJSON :463, load :154, Keys) | DayIntentStore.swift | local store + user's private cross-device sync; **ADD `carryoverVacationDays`** |
| `DayIntentStore` intents publish | CloudKitMessagingService.swift:246 (`exportSnapshotJSON`) / :281 | private_state `intents` blob (user's own devices) |
| `TradeProfile` (fields :79–102, init :128, fromLocal build :385–405, decode back-compat) | TradeProfile.swift | published to peers; **ADD `carryoverVacationDayIDs`** |
| `TradeProfile.fromLocal` (populates seeking/mustBeOff/wantToWork from DayIntentStore) | TradeProfile.swift:385–405 | where to populate the new field |
| `ShiftStore.shifts` (relief-filtered computed) / `rawShifts` | ShiftStore.swift:25 | **self** consumption — override own carryover days → vacation OFF |
| Peer schedule for matching | `MatchContext.build` (TradeRouter:281) → `maps` (RosterEntry per day); `RosterStore.dispatchersWorking/Off` | **others** consumption — apply peer's profile carryover override |
| `TradeEligibility.canCover` | TradeMatcher.swift:907 | per-(coverer,day) gate; `entry.isOff` is the hinge |
| `DayIntentEditor` | HomeView.swift:119 (host) + its definition file | **UI** — add the toggle |
| Calendar vacation render | HomeCalendar.swift:532/659/787 (`shift.isVacation`) | shows VAC / vacation color |
| EngineTests | EngineTests.swift | must stay green; add `CARRYOVER-*` |

## Assumptions
1. Vacation is a display + availability concept driven by `Shift.isVacation` (self) and `isOff` (peers). *Verify no hidden leaveCode dependency in the matcher (there isn't — RosterEntry has none).*
2. Peers fetch each other's `TradeProfile` already (radar/intents/solutions use `TradeProfileStore`). The new field rides that fetch.
3. Applying a per-day OFF override to a peer is safe: it only ever REMOVES a working peer from that day (they're on vacation), never adds — so it can't create illegal matches.
4. `exportSnapshotJSON` / profile encode are plain Codable → adding an optional set round-trips.

---

## Stage 1 — Model (`DayIntentStore.carryoverVacationDays`)
Add `carryoverVacationDays: Set<String>` (persist to UserDefaults; include in `Baseline` for save/discard; include in `exportSnapshotJSON`/load so it syncs to the user's own devices) + `toggleCarryoverVacation(_ dayID:)` / `isCarryoverVacation(_:)`.
- *Gate:* build + harness green; `CARRYOVER-SNAPSHOT` test — snapshot JSON round-trips the set; absent field decodes (back-compat).
- *Commit:* `CARRYOVER Stage 1: DayIntentStore.carryoverVacationDays (+ snapshot test)`.

## Stage 2 — Publish (`TradeProfile.carryoverVacationDayIDs`)
Add optional field; populate in `fromLocal` from `DayIntentStore.carryoverVacationDays`; ensure decode back-compat (optional).
- *Gate:* build + harness green; `CARRYOVER-PROFILE` test — profile encodes/decodes the field; empty profile still decodes.
- *Commit:* `CARRYOVER Stage 2: publish carryoverVacationDayIDs on TradeProfile`.

## Stage 3 — Self consumption (own calendar + own availability)
`ShiftStore.shifts`: for any day in `DayIntentStore.carryoverVacationDays`, emit an OFF vacation shift (leaveCode `"V"`, isOff true) overriding the parsed shift — so the calendar shows VAC and the user isn't offered to give that day away.
- *Guardrail:* pure override at read; `rawShifts`/persistence untouched; observation flows (ShiftStore reads DayIntentStore).
- *Gate:* build + harness green; behavioral — toggling a worked day flips it to VAC on the calendar and drops it from `upcomingWorkingShifts`.
- *Commit:* `CARRYOVER Stage 3: self schedule shows carryover days as vacation`.

## Stage 4 — Others consumption (published effect)
When the matcher evaluates a peer, treat the peer's `profile.carryoverVacationDayIDs` days as vacation/OFF (override the roster). Apply where peer day-maps/candidacy are built (a pure helper the candidate paths call), so a peer on carryover vacation is not surfaced as working/available.
- *Guardrail:* override only REMOVES a working peer on that day (Assumption 3); no new match can appear.
- *Gate:* build + harness green; `CARRYOVER-PEER` test (pure helper) — a peer day in their carryover set resolves to off/vacation.
- *Commit:* `CARRYOVER Stage 4: peers on carryover vacation excluded from matching`.

## Stage 5 — UI toggle
Add a **"Carryover Vacation"** toggle to `DayIntentEditor` (writes `DayIntentStore.toggleCarryoverVacation`, triggers profile publish + intent sync). Copy: "Marks this day as vacation (you're off) and tells others."
- *Gate:* build clean; issues-refresh on the edited file; behavioral — toggle persists, publishes, and the day renders VAC.
- *Commit:* `CARRYOVER Stage 5: day-detail Carryover Vacation toggle`.

## Test ledger
| Tag | Stage | Asserts |
|---|---|---|
| `CARRYOVER-SNAPSHOT` | 1 | set round-trips in the intent snapshot; absent decodes |
| `CARRYOVER-PROFILE` | 2 | `carryoverVacationDayIDs` round-trips on TradeProfile; empty decodes |
| `CARRYOVER-PEER` | 4 | a peer's carryover day resolves to off/vacation (pure helper) |

## Watch-list
- **CloudKit:** rides the existing `intents` blob (self) + `TradeProfile.payload` (peers) → **no schema deploy**. Confirm before ship.
- **Cross-device (self):** carryover set syncs via the intents blob like other intents.
- Don't touch the `S`/`vacationLeaveCodes` parser (this is a user override, not a parse change).
