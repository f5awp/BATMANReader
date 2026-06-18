# BATMAN Watcher — Structural Spec (Data, Engine, Sync, Parsing)

> The **foundation** layer. `SPEC_UIUX.md` is built on top of this and references these section IDs
> (e.g., "see S-ENG-4"). Every requirement here traces back to a `NEXT_CHANGES.md` item (e.g., [Q4],
> [R3], [P1]). Written to be **exact and non-ambiguous**: where a field name, bound, or rule is
> stated, build it exactly.
>
> **Global invariants (never violate):**
> - Bundle ID `DX.BATMANReader`. CloudKit container `iCloud.com.ervinlee.batmanreader`. App Group
>   `group.com.ervinlee.batmanreader`. Roster SwiftData stays **local** (`cloudKitDatabase: .none`).
> - State = **Observation** (`@Observable`), never Combine. Stores are `@MainActor @Observable`
>   singletons; heavy work on actors with `Sendable` snapshots.
> - **All new CloudKit fields are optional** in a JSON `payload` (backward/forward compatible via
>   `decodeIfPresent`). Adding a SwiftData property must be **optional with a default** (lightweight
>   migration only).
> - Build iPhone-sim/iPad green before any item is "done." No stubbed branches, no `fatalError` paths,
>   no unresolved symbols.
> - Normal shifts start **only 05:00 / 13:00 / 21:00**; all are **9 hours**. Other starts = special
>   assignment = **not tradeable** (engine ignores them as trade candidates).

---

## S-DATA — Data Model Changes

### S-DATA-1 — Leave codes on `Shift` and `RosterShift` [P1, R2]
**Problem:** vacation days print a shift token (e.g. `21`) and are parsed as working.

- `Shift` already has `leaveCode: String?`. **Use it.** Add a computed:
  ```
  var isVacation: Bool { leaveCode == "V" }
  var isUnavailableForTrades: Bool { isOff || isVacation }   // vacation ≠ a free off day
  ```
- `RosterShift` (`@Model`): **add** `var leaveCode: String? = nil` (optional + default ⇒ lightweight
  migration). Add only the `isVacation` computed helper.
- `RosterEntry` (the Sendable snapshot): **add** `let leaveCode: String?`; update `snapshot(_:)` and
  every initializer call site.
- **Semantics — vacation is NOT a hard block [user correction 2026-06-16]:**
  - `leaveCode == "V"` ⇒ **Vacation**: parse the day as a **normal day OFF** (`isOff = true`,
    `startHour = 0`, `desk = ""`, `role = .off`) and carry `leaveCode = "V"` **only for display**
    (a distinct "Vacation" badge, S-UIUX U-VAC).
  - **Do NOT hard-code vacation as unavailable.** A person on vacation is **still allowed to trade
    into that day** if they choose. There is **no** `isUnavailableForTrades` gate. For trade
    eligibility a vacation day behaves exactly like a normal OFF day.
  - The only behavioral effect is a **soft, user-changeable auto-intent**: on the **current user's own**
    calendar, a vacation day auto-sets **Must-Be-Off** (S-PARSE-2). That intent — like any Must-Be-Off
    — keeps them from being offered **by default**, but they are **free to clear/change it** and then
    trade into the day. Nothing about vacation is hardcoded or locked.
  - Other codes (`x`, `S`, `R`, …) are **recorded into `leaveCode`** but **do not** change
    `isOff`/availability. The day stays exactly as the shift row dictates.

### S-DATA-2 — `TradeProfile` additions [Q4, A1, A3]
`TradeProfile` is a `Codable` value type published to the **public** CloudKit DB as JSON `payload`.
Add (all **optional**, defaulted):
- `var qualRanking: [String]? = nil` — the user's own quals, **highest-preference first**
  (e.g. `["L","E","D","P"]`). [Q4]
- `var qualSwapBlacklistDesks: Set<String>? = nil` — desks the user will never qual-swap into. [Q4]
- `var qualSwapBlacklistQuals: Set<String>? = nil` — quals the user will never qual-swap into. [Q4]
- `var statusBroadcast` already exists — ensure it's **published + re-fetched** so it syncs (A3).
- **Negative intents must be published [A1/A6 root cause]:** `TradeProfile` today carries only
  `seekingDayIDs` (give-away). It MUST also publish the per-day **negative** intents so the matcher
  can exclude them cross-user:
  - `var mustBeOffDayIDs: Set<String>? = nil` — off days the person refuses to be asked to work.
  - `var keepDayIDs: Set<String>? = nil` — working days the person refuses to trade away.
  These come from `DayIntentStore` at publish time. Without them, `wouldPickUp` cannot see a
  Must-Be-Off day and wrongly offers it (the June-23 bug). See S-ENG-1 gate 8.
- **Private notes do NOT go here** (public). See S-SYNC-2.

Add methods:
```
/// Rank index of a qual in the user's ranking; lower = more preferred. Unranked = worst.
func qualRank(_ q: String) -> Int
/// May the user accept being moved INTO `desk` for a qual swap, given the desk they
/// currently work that day? True iff newDeskQual ranks <= currentDeskQual (equal or better)
/// AND newDesk/qual not in the qual-swap blacklist.
func acceptsQualSwap(into newDesk: String, fromCurrentDesk currentDesk: String) -> Bool
```

### S-DATA-3 — Messaging model additions [B1, B3, B4, B5, B6, B7, Q3, Q5, Q6, R3, R6]
All additive + optional. `BroadcastPost`, `BroadcastReply`, `TradeRequest`, `TradeResponse` keep
their current fields; **add**:

**Shared editing/moderation (on `BroadcastPost`, `BroadcastReply`, and chat `TradeResponse`):**
- `var editedAt: Date? = nil` — set on edit; UI shows "edited · {time}". [B4, R6]
- `var deleted: Bool = false` — soft-delete tombstone → renders `[Deleted]`. [R6]
- `var pinned: Bool = false` — admin pin-to-top. [B7, R6]
- `var moderatedBy: String? = nil`, `var moderationReason: String? = nil`,
  `var moderatedAt: Date? = nil` — admin moderation audit (shown small/light/italic). [R6]
- `var reactions: [Reaction]? = nil` where `struct Reaction: Codable, Sendable { let emoji: String;
  let userID: String; let userName: String }`. [B6]
- `var attachments: [Attachment]? = nil` where `struct Attachment: Codable, Sendable { let id: String;
  let kind: String /* "image" | "gif" */; let assetField: String }`; the binary rides as a **CKAsset**
  on the record (field name = `assetField`). [B5]

**`BroadcastPost.channel`** already optional. **Channel set is fixed**: `"general"`, `"trades"`,
`"feedback"`; `channelOrDefault` defaults to `"general"`. [R6]

**`TradeRequest` additions (multi-party + qual-swap + ECB):**
- `chain: [TradeLeg]?` already exists (multi-person legs).
- `var qualSwap: QualSwapStep? = nil` — present when a leg needs a qual swap. [Q3, Q5, Q6]
- `var ecbValue: Double? = nil` — ECB price for one-way/ECB requests; **5…25 step 0.5**. [R3]

```
struct QualSwapStep: Codable, Sendable {
    let legID: String              // which TradeLeg this resolves
    let desk: String               // the foreign desk needing the qual
    let requiredQual: String       // e.g. "L"
    let candidateIDs: [String]      // everyone blasted (the multi-select set)
    let candidateNames: [String]
    var acceptances: [QualSwapAcceptance]   // up to 5, ECB-style FCFS
    var chosenAcceptanceID: String?         // set when desk-receiver picks (S-ENG-4 desk-choice)
    var sentCount: Int             // "how many total qual swaps were sent"
}
struct QualSwapAcceptance: Codable, Sendable, Identifiable {
    let id: String
    let qID: String                // the accepting dispatcher Q
    let qName: String
    let offeredDesk: String        // the domestic desk Q vacates (what the receiver would take)
    let offeredQualRegion: String  // e.g. "Domestic"
    let acceptedAt: Date
}
```

**`TradeRequestStatus`** (existing enum) — **add** cases:
- `.waitingOnQualSwap` — blasted, no Q accepted yet. [Q3]
- `.invalid` — trade no longer feasible (S-VALID-1). [B3]
(Existing `.message` stays for chat. `status(of:)` ignores `.message` as today.)

### S-DATA-4 — Metrics model [H1, R4]
- Extend `TradeHistoryStore` with derived global aggregates (computed from CloudKit messaging records,
  not just local history):
  - `successRate: Double` = acceptedInApp ÷ proposed (0 if proposed == 0). "Accepted" = a trade that
    reached **accepted/finalized in-app** (NOT ARIS). [H1]
  - `searchCount(period:)` where `enum MetricPeriod { case month, year, allTime }`. [R4]
- Add an admin reset: `func resetMetrics()` (dev-gated) that zeroes the counters' baseline (store a
  `metricsResetAt: Date` and count only events after it).
- A **trade-search event** is logged each time the user runs a search (S-ENG entrypoints) — store a
  lightweight `SearchEvent { id, userID, at }` in CloudKit (public) so the count is **global**.

---

## S-PARSE — Schedule Parsing (Leave Detection) [P1, R2]

**File:** `ScheduleParser.swift`. The CSV is a calendar grid; each worker's shift row is followed by
**one or more annotation sub-rows** (the redundant "2nd OFF line" and the **leave row**), each aligned
to the **same day-number spine** (day = `[startCol, deskCol]`).

### S-PARSE-1 — Algorithm (exact)
In `appendShifts`, after locating a worker row, also collect the contiguous **annotation sub-rows**
that follow it (rows whose name cell has **no** `(employeeID)` and that are not a strip header) until
the next worker row or header.

For each day column `idx` (the existing spine loop):
1. Compute the normal shift token as today (`startToken = field(shiftRow, idx)`).
2. **Scan all annotation sub-rows** at the same `idx`: read `aStart = field(ann, idx)` and
   `aCode = field(ann, idx+1)` (desk column).
3. If any annotation sub-row has `aStart == "L"` and `aCode == "V"` → this day is **Vacation**:
   emit `Shift(id, date, startHour: 0, endHour: 0, role: .off, desk: "", leaveCode: "V", isOff: true)`
   and **skip** the normal shift emission for this day (vacation overrides the printed shift).
4. Else if `aStart == "L"` and `aCode` is a **non-empty, non-"V"** code (`x`, `S`, `R`, …) → emit the
   normal shift/off as today **but** set `leaveCode = aCode` on it (recorded, not acted on). [R2]
5. Else → emit exactly as today.

Notes:
- The `"L"` here is a **leave marker in the annotation row**, NOT the Latin qual (quals live only in
  the name cell). [P1b]
- **Only `V` is acted upon.** Analysis of the full year shows the annotation's 2nd column is a large,
  qual-like alphabet (`A,E,F,J,P,R,S,V,U,e,f,j,m,o,p,w,x,y,z`), present in every month incl. Jun–Dec,
  and **always over a printed working shift (never on an OFF day)** — i.e., possibly per-day role/pay
  **record-keeping**, not a clean leave vocabulary. `V` = Vacation is the **only** code confirmed by
  the user against a real person (Keriellen). All other codes are stored in `leaveCode` but **must not
  change `isOff`/availability** until individually confirmed in ARIS.
- **Post-import audit:** after each master import, log/surface the count of `V` days applied
  ("N vacation days applied") so the magnitude can be sanity-checked.
- Apply the same change to **both** `parse(...)` and `parseAllWorkers(...)` (they share `appendShifts`).
- **Ground truth (regression fixture):** Beck Keriellen (750560), Nov 2026 ⇒ Vacation on
  **Nov 5, 6, 7, 8, 12, 13**; **Nov 14 is a normal OFF**. Add an `EngineTests` case asserting exactly
  this from a CSV fixture slice.

### S-PARSE-2 — Master re-import must preserve user intents (DIFF-BASED) [R2]
**Bug to fix:** re-uploading the master wiped **all** marked intents (`DayIntentStore.reconcile`
rebuilt from scratch). **The correct rule is a per-day DIFF, not a wholesale reset.** [R2 clarification]

**Algorithm (exact) — TWO buckets only: `unchanged` vs `changed` [user correction 2026-06-16]:**
"Removed" (a day that left the schedule) and "Added" (a day that appeared) are **both folded into
`changed`.** There are exactly two outcomes per day.

1. Snapshot the **previous** per-day schedule keyed by ISO day → `DayFacts { isOff, isVacation,
   startHour, desk }`.
2. For every day in (previous ∪ new), classify:
   - **`unchanged`** — the day exists in **both** previous and new with **identical** `DayFacts`.
   - **`changed`** — **anything else**: facts differ, OR the day disappeared (was in previous, not in
     new), OR the day appeared (in new, not in previous). All three are `changed`.
3. Apply intent edits by bucket — and **only** here:
   - **`unchanged` → DO NOTHING.** Every `workingIntents`, `offIntents`, `topologies`, `notes`,
     `offAvailability`, `manualOffDays` entry for that day is left **byte-for-byte** as it was. This is
     the core of the fix: on a normal master refresh almost every day is unchanged, so almost nothing
     is written.
   - **`changed` → reset only that day's *intent* entries** (`workingIntents`/`offIntents`/
     `offAvailability`/`topologies`), because the underlying shift changed/appeared/disappeared and the
     old intent may no longer apply. For a day that still exists, **preserve the user's `notes`**; for
     a day that disappeared there is nothing to keep.
4. Return the `changed` day set so the UI can flag "N of your marked days changed in this master."

**Invariant (testable):** a day's intents can be modified **iff** that day is in the `changed` set. An
`unchanged` day is never written. (S-TEST-2 asserts this.)

**Vacation handling — remove the shift FIRST, then set the soft intent [user correction 2026-06-16]:**
when a day is in the `changed` set and is Vacation (`leaveCode == "V"`):
1. **Remove the working shift from the schedule first** — the day becomes a normal day OFF
   (`isOff = true`, no desk/start). This happens in parsing (S-PARSE-1) before any intent logic runs.
2. **Then** auto-set, on the **current user's own** calendar, a **Must-Be-Off** intent **and a Note
   "vacation"**. Order matters: the shift must already be off the schedule before the Must-Be-Off
   intent is applied (you can't mark "must be off" a day still modeled as a working shift).
This is a **normal, user-changeable** intent + note — they may clear or flip it freely (e.g., to trade
into their vacation). **Never overwrite** an intent/note the user already authored; once the user edits
that day, their edit wins and the auto-rule does not re-apply on later syncs. Nothing is hardcoded or
locked; the only permanent effect is that the *working shift* is gone (they're genuinely off).

---

## S-ENG — Trade Engine

**Files:** `TradeMatcher.swift`, `TradeRouter.swift`, `OptimalMatcher.swift`, `MinCostFlow.swift`,
`DeskRules`, `EngineTests.swift`.

### S-ENG-1 — Canonical availability gates (one source of truth) [A1, A6, C2c]
A dispatcher T can **take** a shift on day D **iff ALL** hold (hard gates):
1. **T is free on D** — `isOff == true`. **Vacation is NOT excluded** — a vacation day is a normal off
   day for eligibility; it's the soft Must-Be-Off auto-intent (gate 8) that holds them back, and they
   may clear it to trade into their vacation. [P1, user correction]
2. **Qualified** — `DeskRules.qualified(quals: T.quals, forDesk: desk)` (or a qual swap exists; S-ENG-4).
3. **8-hour rest** on both sides vs T's actual adjacent shifts (existing `rested`/`eligibleTypes`).
4. **Weekly-hour cap** not exceeded (existing `maxWeeklyHours`).
5. **Shift is tradeable** — start hour ∈ {5,13,21} (special assignments excluded).

Soft gates (per T's profile) — a day is **NOT offered** to T if any fail [C2c]:
6. **Openness:** `.none` ⇒ never; `.bookends` ⇒ only bookend days (S-ENG-2); `.all` ⇒ any eligible.
   `OpennessOverride` ranges apply. **Mercenary** ⇒ forces openness to **`.all`** (S-ENG-6).
7. **Blacklist** (weekday/desk/shiftType/region) always blocks, **even in mercenary**.
8. **Intent semantics** — see **S-ENG-10** for the authoritative, *unordered* model of how each intent
   (Keep, Must-Be-Off, Want-to-Work, Trade-away), the blacklist, and per-day shift availability
   qualify, disqualify, enable, or merely *prefer* a day. Hard disqualifiers (Keep, Must-Be-Off,
   blacklist, shift-availability OFF) are read from the published profile (`keepDayIDs`,
   `mustBeOffDayIDs`, blacklist, pills) — **ROOT-CAUSE FIX [A1/A6]:** today the negative intents are
   not published and `wouldPickUp` never sees them (the June-23 bug).

**These gates must be applied identically in Intents, Trade Search, two-way, and packages.** See
S-ENG-9 (root cause of "don't work / don't refresh") and S-ENG-10 (intent semantics).

### S-ENG-2 — Bookend rule (final post-trade schedule) [D8, R5]
Canonical definition:
> A day **D** offered to taker **T** is a **bookend for T** iff, in **T's FINAL post-trade schedule**
> (after applying **all** legs of the proposed trade), **T is working D** and **at least one
> immediately adjacent day (D−1 or D+1) is also a day T works.** The giver's workweek is irrelevant.

- Evaluate against **T's own** post-trade schedule (not the giver's). This fixes the "first day of
  their workweek" mislabel (B2) and the "Aug 30 offered as bookend but not adjacent to my work" bug
  (A1).
- **Multi-step becomes-a-bookend [R5]:** when a trade has multiple legs, a day may be **non-adjacent
  mid-sequence but adjacent once all legs apply**. The engine must evaluate bookend status on the
  **union of all legs' effects**, so trading away D−3 is allowed if D−2 and D−1 are filled by other
  legs of the same trade (and symmetrically D+1, D+2…).
- **SYMMETRY — bookends for BOTH sides [user correction 2026-06-16]:** bookend optimization is
  **two-sided**. The solver prefers solutions where the days **the counterparty takes are bookends for
  them** AND the days **I take are bookends for me** — "bookends back to me" are an equal priority.
- **No override *order* — see S-ENG-10.** Bookend is a *preference that operates among the days that
  survive the hard disqualifiers*; it does not have a ranked relationship with blacklist/availability/
  Keep/Must-Be-Off (those simply remove days, equally and independently). **Want-to-Work overrides the
  bookend *requirement* for that person** (a non-bookend day they marked Want-to-Work is still eligible
  for them under `.bookends`), but **not** for the other person, and **not** over blacklist/shift-
  availability. **Trade-away** boosts solutions that offload the give-day but does **not** relax the
  trader's bookend preference on the return days.
- Implementation: replace the per-leg `anchored(...)` check with a function that takes the **set of
  all legs**, computes **each participant's** resulting day-map (self included), and tests immediate
  adjacency — producing a per-participant bookend flag used by the two-sided scorer (S-ENG-10).

### S-ENG-3 — Fewest-people optimization [A5]
- Prefer solutions with the **fewest distinct counterparties**. A single counterparty who can satisfy
  **all** of the user's give-days is the best package and sorts to the **top** (`solo-<peerID>`).
- `OptimalMatcher.minPeopleReciprocal` already does branch-and-bound; ensure `TradeRouter.packages`
  (a) **always** tries the single-person full-cover first, (b) is **exhaustive** within the existing
  bounds before falling back to greedy/circular, (c) **de-duplicates** packages that cover the same
  days with the same people.

### S-ENG-4 — Qual-swap routing [Q1–Q6, R5]
When a leg's taker **D** lacks `requiredQual(forDesk:)` for the shift's desk, attempt a **qual swap**
instead of discarding the leg.

**Candidate-Q discovery.** Q is a valid qual-swap partner for requester **R**'s shift on day X iff:
- Q **works day X** at the **same start hour** as R's shift [Q-a];
- Q **holds** the `requiredQual` of R's desk;
- Q is on a desk that **D can take** (D qualified for Q's desk; everyone holds D, so Q must be on a
  desk whose `requiredQual` ∈ D's quals — typically a Domestic desk);
- Q is **legal/rested** for staying on day X (no rest change — same hours, different desk);
- Q **accepts** per `acceptsQualSwap(into: R'sDesk, fromCurrentDesk: Q'sDesk)` (S-DATA-2): R's desk
  qual ranks **equal-or-better** in Q's ranking **and** not in Q's qual-swap blacklist. [Q4]

**Insertion [Q1]:** qual swaps are considered in **all** searches (Trade Search, Intents, two-way).
Inserting a qual-swap step adds **one participant** to the trade (2-way→3-way, 3-way→4-way).

**Desk-receiver gate [Q5]:** D (who ends on the swapped desk) is filtered by **D's NORMAL blacklist**
against the **new** desk only — **not** re-checked against D's intents/openness (already satisfied for
the day/time in S-ENG-1).

**Blast + acceptance [Q3, Q6]:**
- R **multi-selects** which candidate Qs to contact (UI: name-button line). On send, **blast** all
  selected Qs; request status = `.waitingOnQualSwap`.
- Each Q **Accepts/Declines** (full participant). Accept is **ECB-style FCFS capped at 5**; the 6th+
  sees "already filled." Record each into `QualSwapStep.acceptances` (≤5); set `sentCount`.
- Every acceptance pushes a notification and updates the card (person + desk + qual). D may **wait**
  or **pick** from `acceptances` → sets `chosenAcceptanceID` (desk-choice stage).
- **Auto-finalize:** once `chosenAcceptanceID` is set **and** all other parties have accepted, the
  whole trade transitions to accepted/finalized and everyone is notified. [Q3]

**Same-hour guarantee:** since all tradeable shifts start 5/13/21, a qual swap never changes hours —
only the desk/qual. [Q-a]

### S-ENG-5 — Participant counting / single trade-type label [B2, R1, user correction]
- Define `peopleCount = distinctParticipantIDs.count` across the trade (including self). A reciprocal
  You↔Cary = **2**. Qual swaps **increment** `peopleCount` by the chosen Q(s) (so a 2-person trade that
  needs a qual swap becomes 3 distinct people).
- **Exactly one** label/badge per card (the duplicate second label is removed). The label string is
  chosen by this **precedence**:
  1. **ECB one-way** (`ecbValue != nil`, no reciprocal legs) ⇒ **"1-Way Swap"**.
  2. **Contains a qual-swap step** (`qualSwap != nil`) ⇒ **"Qual Swap"**.
  3. **Otherwise** ⇒ **"{peopleCount}-Person Swap"** (e.g., "2-Person Swap", "3-Person Swap"). Do NOT
     use "Direct swap" or "N-way".
- No second/contradictory people label anywhere on the card (S-UIUX U-CARD-1). The detailed
  participant breakdown still lives in the card body (chips/handoff), but the **badge** is one of the
  three strings above.

### S-ENG-6 — Mercenary & openness coupling [A1]
- Enabling **Mercenary** sets effective openness to **`.all`** (cannot be "Not accepting" +
  mercenary). Persist this so toggling mercenary updates the openness control and the engine.
- Blacklist still applies under mercenary (S-ENG-1 gate 7).

### S-ENG-7 — Sorting & tiers (all ranked lists) [C2, C6, R6-tiersep]
Within any candidate/option/package list, sort by:
1. **Intent matches** (mutual 🔥) first;
2. then **bookends** (S-ENG-2);
3. then remaining eligible options, by location/preference then date.
**Exclude** anything unavailable per S-ENG-1. Tiers are visually separated (S-UIUX). Tie-break order
must be **deterministic** (stable sort with explicit comparator) so results don't reshuffle.

### S-ENG-8 — ECB value [R3]
- ECB price is a `Double` on the request, **min 5, max 25, step 0.5** (validated at the model layer).
- 1 ECB = 1 hr pay; informational only to the engine (it carries the value; the UI provides the
  stepper). Reject out-of-range or non-0.5-multiple values.

### S-ENG-9 — ROOT CAUSE: why Intents/openness "don't work" and don't refresh [A1, A6]
**Verified in code 2026-06-16. Three concrete defects, three concrete fixes:**

1. **Negative intents never reach the matcher (the smoking gun).**
   - **Cause:** `TradeProfile` carries only `seekingDayIDs` (give-away). `wouldPickUp`
     (`TradeProfile.swift:127`) gates on blacklist → mercenary → published pills → openness → bookend,
     but has **no knowledge of Keep-Shift or Must-Be-Off** because those `DayIntentStore` states are
     never published. So a day you marked **Must-Be-Off (June 23)** is invisible to the matcher and
     gets offered as "You Take."
   - **Fix:** publish `keepDayIDs` + `mustBeOffDayIDs` on `TradeProfile` (S-DATA-2); add them as a hard
     exclusion in the canonical evaluator and inside `wouldPickUp`, for **both** the user and peers.

2. **No single evaluator — each path gates differently.**
   - **Cause:** `TradeMatcher.twoWayExplore`, `TradeRouter.packages`, and `tieredSolutions` each
     re-implement gating; some branches skip a gate (e.g., openness applied in one path, not another),
     so results disagree and the Intents tab can come up empty.
   - **Fix:** extract **one** `canTake(...)`/`canGive(...)` evaluator implementing all S-ENG-1 gates;
     every surface calls it. Delete the divergent inline checks.

3. **Views don't recompute on change.**
   - **Cause:** the Intents feed derives its data once (e.g., in `.task`/`onAppear`) from a snapshot;
     toggling openness/mercenary/intents mutates `@Observable` stores the view doesn't **read**, so
     SwiftUI doesn't re-run the computation. Hence "changed my openness, nothing refreshed."
   - **Fix:** make the feed's computed input **read** `DayIntentStore`/`SettingsManager`/
     `TradeProfileStore` inside `body` (or a recomputed `@State` keyed on their values), so any change
     invalidates and re-derives. Also normalize **Mercenary ⇒ openness `.all`** (S-ENG-6) so the
     impossible "Not accepting + mercenary" state cannot occur.

**Regression coverage:** S-TEST adds (10) a Must-Be-Off day is never offered as "You Take", (11) a
Keep-Shift day is never offered to give, (12) changing openness from `.all`→`.bookends` changes the
candidate set deterministically.

### S-ENG-10 — Intent & preference semantics (AUTHORITATIVE) [user correction 2026-06-16]
Two distinct kinds of rules. **Disqualifiers are unordered** — each one independently removes a day;
there is **no ranking** among them ("considered equally"). **Preferences** only sort/enable among the
days that survive every disqualifier.

| Rule | Kind | Exact effect (for the person it belongs to) |
|------|------|---------------------------------------------|
| **Blacklist** match (weekday/desk/shiftType/region) | **Hard disqualify** | Day is **never** offered. Independent of everything else. |
| **Shift availability pill = OFF** for that day/type | **Hard disqualify** | Day is **never** offered. |
| **Shift availability pill = ON** | **Enabler** | Day is **allowed** (the pill being on is what permits the pickup under pill mode). |
| **Keep** (a working day) | **Hard disqualify** | They will **not give** that day — never offered to give. |
| **Must-Be-Off** (an off day) | **Hard disqualify** | They will **not work** that day — never offered to take. |
| **Want-to-Work** (an off day) | **Eligibility override + boost** | Makes a **non-bookend** off day **eligible for THEM** even under `.bookends` (they've said they want that day regardless of contiguity). **Boosts** its priority. Does **NOT** override blacklist or shift-availability-OFF. Does **NOT** affect the **other** person's bookend preference. |
| **Trade-away** (a working day) | **Priority boost only** | Prioritizes solutions where someone takes this give-day. Does **NOT** relax the trader's own bookend preference on the days coming **back** to them. |
| **Bookend-for-them / Bookend-for-me** | **Preference (sort)** | Among surviving days, bookends sort to the top — **two-sided** (S-ENG-2). "Bookends navigate **through** the disqualifications" — i.e., bookend logic runs only over days that already passed every hard disqualifier. |
| **Mutual intent (🔥)** | **Preference (sort)** | Sorts above plain bookends (S-ENG-7). |

**Pseudocode (canonical evaluator):**
```
func canTake(person P, day D, desk):
    // hard legal gates (S-ENG-1: off, qualified, rested, weekly cap, tradeable hours)
    if !legal(P,D,desk): return false
    // UNORDERED hard disqualifiers — any one fails ⇒ out
    if blacklisted(P, D, desk): return false
    if pill(P,D) == OFF: return false
    if isMustBeOff(P, D): return false          // off-day refusal
    // openness / eligibility
    if openness(P) == .none: return false
    if openness(P) == .bookends
       && !isBookendFor(P, D, allLegs)
       && !isWantToWork(P, D):                   // Want-to-Work lets a non-bookend through, for P only
        return false
    return true                                  // pill ON or openness .all/Want-to-Work satisfied

func canGive(person P, day D):                   // P's own working day going out
    if isKeep(P, D): return false                // unordered hard disqualify
    ...legal/qualified by the TAKER handled separately...
    return true

func score(solution):                            // among eligible only; preferences combined
    + mutualIntent bonus
    + bookendForThem bonus + bookendForMe bonus  // two-sided, equal
    + wantToWork bonus (their side)
    + tradeAway-offloaded bonus (their give-day got taken)
```
Mercenary forces `openness == .all` (S-ENG-6) but **blacklist still disqualifies**. This model
supersedes any earlier "ordered override" wording in S-ENG-1/2/7.

**Tests (S-TEST):** (13) blacklist disqualifies even a perfect bookend; (14) pill OFF disqualifies,
pill ON enables; (15) Keep never given, Must-Be-Off never taken; (16) Want-to-Work makes a non-bookend
day eligible **for that person** under `.bookends` but a non-bookend day **without** Want-to-Work is
not; (17) Want-to-Work does NOT relax the other person's bookend preference; (18) Trade-away boosts
offload but return days still respect the trader's bookend preference.

---

## S-VALID — Trade Validity & Notifications [B3]

### S-VALID-1 — Invalid detection
On every master re-sync (and on any intent/openness change by a participant), re-evaluate each
**active** (pending/accepted-not-final) trade. A trade is **invalid** when:
- (a) a day in the trade is **no longer on** a participant's schedule (schedule changed); or
- (b) a participant who was available for a day **no longer is** (now working it / on vacation / etc.); or
- (c) a participant **changed intent/openness/availability** so they'd no longer accept that day
  (e.g., set **Must-Be-Off** / reduced openness / blacklisted the desk).
Set status `.invalid` and attach a human reason.

### S-VALID-2 — Notification + status-bar surfacing
- Both parties get a **push** and an **urgent status-bar item** to attend to. [B3]
- The package card shows a **big, urgent alert** ("{Name} set Must-Be-Off / reduced availability for
  {day} — this trade may no longer work"). Urgent styling defined in S-UIUX.
- The alert **clears automatically** if the blocking condition is reversed (participant re-opens the
  day). [B3]
- For invalid trades, the inbox **highlights** the Delete/Archive control (S-UIUX inbox).

### S-VALID-3 — Delete vs Archive [B3a]
- **Delete** = removed forever (local + CloudKit record deleted).
- **Archive** = hidden from the active inbox but **kept in history**. Add `var archived: Bool = false`
  to `TradeRequest`. Archived items appear only under an Archived section / history.

---

## S-SYNC — CloudKit & Cross-Device [A2, A3, R6]

### S-SYNC-1 — Unread counts reset correctly [A2, R6]
- Unread is tracked per channel and per thread. **Opening** the channel/message resets its unread
  count; being **minimized** or having the message **inside an already-open thread** does **not**
  reset it. [R6]
- Fix the "sticking blue circle": the badge derives from `unread` state that is **cleared on open**
  and persisted, so it reaches zero. Per-channel circles + a **total** on the General button. [R6]

### S-SYNC-2 — Private notes & status sync across a user's devices [A3]
- **Status broadcast** (public, already on `TradeProfile`) — ensure published on change and fetched on
  launch so it appears on all the user's devices.
- **Private notes** are private: sync via the user's **CloudKit private database** (a single
  `PrivateState` record: `{ privateNotes: String, updatedAt: Date }`), **not** the public profile.
  Last-write-wins by `updatedAt`. New service `CloudKitPrivateStateService` (actor). [A3]

### S-SYNC-3 — Subscriptions / push [Q3, Q6, B3]
Extend `CloudPush` with subscriptions/notifications for: qual-swap blast received, qual-swap accepted,
trade became invalid, desk-choice ready. Notification bodies match S-UIUX copy.

---

## S-INTENT — Intents Store [F1, F2, A1]

- **Bulk actions [F1]:** `DayIntentStore` gains a bulk apply: choose an **action** (any of: working
  must-work/want-to/neutral/don't-want; off must-be-off/neutral/want-to-work; availability AM/PM/MID;
  topology; note), then apply to a **multi-selected set of days** in one commit.
- **Bulk note [F2]:** apply one `DayNote` (≤50 chars, reason, isPrivate) across the selected set.
- **Visibility of others' intents [A1]:** intents are **public** (used for trade decisions). The store
  exposes other dispatchers' marked intents per day (from `TradeProfileStore.others`) so the calendar
  and trade cards can show them, plus each person's current **Openness** label.

---

## S-EMAIL — Outlook trade-board email [G1–G3, user un-defer 2026-06-16]

**Recipient:** `DL_Dispatch_Trades@aa.com` (fixed). Generated from app data, mirroring the real board
format (see the four sample emails) but **richer + cleaner**.

### S-EMAIL-1 — Data assembled (auto-populated from the app)
A `TradeBoardEmail` builder pulls, for the current user:
- **Offer:** the shift(s) being given — date(s), start time, desk (e.g. "Sun Jun 21 · 0500 · FD31").
  Single day, a day-group, or ECB.
- **Trade type:** "Day for day", "Day for day or ECB" (+ the **ECB value** if set, S-ENG-8).
- **Wanted Days Off** (the user's `seekingDayIDs`, i.e. days they want covered) — month-grouped.
- **Want to Work** (off days marked Want-to-Work) — month-grouped.
- **Can't Trade** = **Keep** + **Must-Be-Off** day-ranges (the "blackout dates").
- **Blacklist** (desks/regions/weekdays/shift-types) — concise human phrasing.
- **Reason** (optional, from the day note).
- **Contact:** name, title, base, phone ("Text is best" if set), AA email — from settings.
- A **"Generated by BATMAN Watcher"** footer + a **deep link** back to the specific trade
  (S-EMAIL-3).
- **Taken days** render struck-through/("taken") like the real board (from trade history/responses).

### S-EMAIL-2 — Send mechanism: plain-text Outlook deep link, NO attachment [FINAL 2026-06-16]
**Hard environment fact:** dispatchers use work **iPads** with the **Outlook app**; **system Mail is
not used**, so `MFMailComposeViewController` is a dead end. **The Outlook URL scheme cannot carry
attachments.** Therefore the email is **plain text only**, sent via:
- `ms-outlook://compose?to=DL_Dispatch_Trades@aa.com&subject=<enc>&body=<enc>` (percent-encoded).
- **No attachment is possible.** The rich graphic flyer **cannot ride in this email** — it lives only
  in a separate share path (S-EMAIL-5).
- **URL-length budget:** keep the body reasonably short (long `body=` can be truncated by the OS).
  Include all the trade data (S-EMAIL-1) plus a **condensed** pitch + stats + link; the full marketing
  copy lives in the flyer/in-app About, not the email.
- Open via `UIApplication.open`. If `ms-outlook://` can't open (Outlook not installed), fall back to a
  `mailto:` compose (still plain text).

### S-EMAIL-3 — Deep link back into the app [G2/G3]
- Register custom URL scheme `batmanwatcher://`. `ContentView.onOpenURL` routes
  `batmanwatcher://trade/<id>` → open that trade; `…/inbox`, `…/channel/<name>` likewise.
- Add `CFBundleURLTypes` to `Info.plist`. (Universal Links deferred until a web domain exists.)

### S-EMAIL-5 — Marketing content: condensed text only (flyer DROPPED for now) [FINAL 2026-06-16]
Plain-text email only; **the graphic flyer is dropped** (no attachment path on work iPads). The pitch
ships as a short text tail in the body, and lives in full in the in-app About later.
- **Email body tail (text, kept short for the URL-length budget):**
  - **Stats line:** "{youCompleted} trades cleared · {systemTotal} across the team" (`TradeHistoryStore`
    + S-DATA-4 metrics).
  - **A few lines of `TradeBoardCopy`** (below). No deep link in the email (custom schemes don't
    linkify in plain-text Outlook).
- **`TradeBoardCopy` — premium voice, single source of truth** (tech/fashion cadence; short,
  declarative, confident; NO AI-buzzwords like "seamless/leverage/empower"):
  > **The board, rebuilt.**
  > BATMAN Watcher doesn't shout your trade to a crowd and hope. It reads the whole roster and finds the
  > swaps that actually clear — for you and the person across from you.
  > You see only what fits your days. No noise. No reply-all.
  >
  > — Every match works for both sides, or it never shows.
  > — Only trades that fit your schedule. Nothing else.
  > — Qual swaps and ECB: first five in.
  > — Message, settle, done — in one place.
  > — Yours alone. Not management's.
  > — Sharper with every dispatcher who joins.
  >
  > Less noise. More days off.
- The same `TradeBoardCopy` constant feeds the future in-app About — no duplication.

---

## S-DEFER — Deferred / Future (logged, not built now)

- **Dedicated qual-swap search [Q-c]:** standalone "qual-swap for a select shift + person."
- **See-all-trades-in-system inbox view [B1a].**
- **Unknown leave codes `x`/`S`/`R` [R2]:** recorded but inert until defined.
- **Rich-HTML email render (S-EMAIL-2 path B)** — after plain-text Outlook ships, if desired.

---

## S-TEST — Testing philosophy + required tests

### S-TEST-0 — Test-first, every change [user mandate 2026-06-16]
- **Every change/area gets an explicit fail test, written FIRST.** Before implementing an item, write
  the test that encodes its stated requirement, run it, **show it RED against the current code**, then
  implement to GREEN. If I can't make it fail first, the requirement isn't pinned — stop and fix that.
- Each test names the `NEXT_CHANGES`/spec ID it enforces (e.g. `test_S_PARSE_2_unchangedDaysNeverWritten`).

### S-TEST-1 — Consistency / convention guards (catch "weird decisions") [user mandate]
The general request — "analyze whether a new decision matches the established pattern / what I said" —
is realized concretely by **three mechanisms**, not a vague AI check:
1. **Single source of truth per decision.** Funnel each user-visible decision through ONE function so
   there is exactly one place to test. E.g. all trade-type labels come from `tradeLabel(_:) -> String`
   whose **only** possible outputs are `"1-Way Swap"`, `"Qual Swap"`, `"{n}-Person Swap"`.
2. **Universe assertion.** A test enumerates every input shape and asserts the output is in the
   approved set — so a stray `"Direct swap"` (the exact kind of off-pattern guess you called out)
   **fails immediately**. Likewise an "eligibility equality" test feeds one fixture to **all** surfaces
   (Intents/Search/two-way/packages) and asserts identical results — catching any path that quietly
   gates differently.
3. **Source-scan guard.** A unit test greps the source for **forbidden literals** outside their one
   home (e.g. any trade-type string literal outside `tradeLabel`, any `fatalError` on a launch path,
   any hardcoded `"5"`/`"13"`/`"21"` start-hour outside the shared constant). New code that
   reintroduces a banned pattern fails CI.
- **Principle:** every assumption, default, or "easy way out" I introduce must be backed by a named
  test asserting it matches a stated requirement. No silent guesses.

### S-TEST-2 — Required regression tests (`EngineTests.swift` + view-logic tests)
1. **Parsing:** Beck 750560 Nov ⇒ vacation {5,6,7,8,12,13}, Nov 14 OFF; working shift removed before
   intent set (S-PARSE-1, S-PARSE-2).
2. **Intent preservation (invariant):** re-import master ⇒ an `unchanged` day is **never written**;
   only `changed` days' intents reset; notes kept where day persists (S-PARSE-2). *Write this RED
   first against current code.*
3. **Vacation:** day's shift removed → day OFF; auto Must-Be-Off + note "vacation"; user can clear and
   then trade into it (S-DATA-1, S-ENG-1).
4. **Bookend final-state + symmetry:** D−3 give becomes a bookend when D−2/D−1 filled by other legs;
   bookends scored for both sides (S-ENG-2/R5).
5. **Intent semantics (S-ENG-10):** tests 13–18 from S-ENG-10 (blacklist/pill/Keep/Must-Be-Off
   disqualify unordered; Want-to-Work eligibility override one-sided; Trade-away boost only).
6. **Fewest people:** single full-cover beats multi-person; sorts first (S-ENG-3).
7. **Qual swap:** valid Q (same hour, holds qual, D-takeable, hierarchy ok); blast caps at 5;
   desk-choice finalizes (S-ENG-4).
8. **Label universe + count:** `tradeLabel` only ever returns the 3 approved strings; reciprocal 1:1 ⇒
   "2-Person Swap" (S-ENG-5, S-TEST-1).
9. **Eligibility equality:** all surfaces agree for one fixture (S-ENG-9, S-TEST-1).
10. **Mercenary ⇒ openness .all, blacklist still blocks (S-ENG-6).**
11. **ECB bounds:** rejects <5, >25, non-0.5 multiples (S-ENG-8).
12. **Unread reset:** opening a channel zeroes its badge; minimized/in-thread does not (S-SYNC-1).
13. **Email builder:** assembles offer + Wanted/Want-to-Work/Can't-Trade/Blacklist + deep link
    (S-EMAIL-1).
</content>
