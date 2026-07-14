# DX Trader — Matching & Ranking Engine: Design Review Brief (for Fable / Claude)

> **How to use this file:** paste §0 as your prompt to Fable (or hand it the whole file — it's
> self-contained, including the verbatim source in the Appendices). Everything Fable needs to reason about
> the problem is here; it does **not** need repo access.

---

## §0 — THE ASK (prompt to Fable)

You are a **senior algorithms engineer**. Below is the complete matching / scoring / ranking subsystem of an
iOS shift-trading app for airline dispatchers (**DX Trader**), including the verbatim Swift source in the
Appendices, the domain context (§1), the current architecture (§2), a working engineer's analysis and a
draft proposal (§3), the invariants you must preserve (§4), and a list of edge cases (§5).

**Your task:** evaluate the *entire* system end-to-end **for the purpose of this app**, and design the best
solution. Specifically:

1. **Judge the objective, not just the code.** The app has two distinct feeds (see §1): **Trade Solutions**
   (cover the specific give-days I selected) and **Intents** with **Mutual** and **All** sub-modes (a
   marketplace of intent-for-intent deals). Decide what "best trade" *should* mean for each, and whether they
   should share one scoring function and one ranker or differ — and if they differ, exactly where.
2. **Fix the core misalignment.** Today, construction (min-cost flow / greedy / N-way DFS) optimizes
   structural proxies (fewest people, most coverage, urgency); the acceptance score is computed *post-hoc*
   and used only as a floor gate + a late tiebreak; and the live ranker (`rankLess`) sorts by hard
   lexicographic keys with score in 5th place. Two other rankers (`rankPackages`, `rankIntentPackages`) are
   **dead code**. Propose a coherent objective used *consistently* across construction, curation, and
   ranking.
3. **Get the N-penalty right.** The owner's requirement: an **all-mutual N-person trade** (everyone marked
   the day) should rank **highly** — a 4-way where all four mutually match should rank *almost as high as* a
   2-way all-mutual match. But as N grows **with non-mutual legs**, it should be penalized progressively and
   fall **below** a clean smaller trade (e.g. a 4-way with only 3 mutuals should sort under a clean 3-way).
   The current flat `0.85^(N−2)` penalty is intent-blind — fix it.
4. **Use the min-cost machinery for real.** `MinCostFlow` is currently invoked with `cost: 0` on every edge
   (Appendix: `OptimalMatcher`), so it's pure feasibility/b-matching — it never optimizes acceptance, and the
   return-leg (give-back) assignment is arbitrary prefix order. Decide whether/how to make the flow optimize
   the acceptance objective (edge costs), and whether both directions of the swap should be in the flow.
5. **Calibration.** Weights are hand-tuned (not fit to data). Decide whether the surfaced number should be a
   calibrated probability (fit from the app's stored accept/decline history — `partnerPrior`) or presented as
   a relative "match strength." Note any place the current absolute number could mislead.

**Be meticulous.** Reason about correctness and edge cases explicitly (§5): empty results, single give-day
vs multi-day, partial vs full cover, ties, floating-point equality in comparators, qual-swap packages
(bridge not counted in `peopleCount`), circular loops (close only at N≥3), profile-less peers, bookends-only
openness, mercenary mode, relief-dispatcher horizon, cancellation mid-search, and the admissibility of any
DFS pruning bound if you change the scoring. Call out anything that would change behavior the owner didn't
ask to change.

**Deliverables:**
- A crisp statement of the **objective function** (per feed), with the exact weighted terms and the
  intent-aware people penalty, in math.
- **Per-engine changes**: two-way, min-cost/optimal (+ MinCostFlow edge costs & readback), greedy fallback,
  N-way DFS (seed/expansion ordering + pruning bound), and the single ranker.
- **Swift code** (drop-in for the files in the Appendices), matching the existing style (Swift 6 strict
  concurrency: pure `nonisolated` cores, `Sendable` snapshots, no `Combine`).
- A **test plan**: which existing `EngineTests` assertions change and why, plus new adversarial tests for the
  edge cases and the N-penalty requirement.
- A short **migration order** (smallest safe step first).

**Hard constraints:** iOS/iPadOS, on-device, no server round-trips in the hot path; the roster window is
small (optimal tier bounded to ≤16 peers / ≤10 days); legality gates (§4) are contractual and must stay in
the single shared eligibility predicate; the pure scoring/ranking cores must remain unit-testable; keep the
regression harness (`EngineTests.runAll()` returns only failures — empty == pass) green.

---

## §1 — App & domain context

**Who/what:** airline **dispatchers** trade shifts against a master schedule. Hard realities: each desk needs
a **qualification** (Domestic D = universal, European E, Latin L, Pacific P, coordinator roles A/O/R/S);
only shifts starting at **0500 / 1300 / 2100** are tradeable; an **8-hour rest** gap between shifts is
mandatory; training desks never trade. A **bookend** is a pickup that attaches to the edge of your existing
days off (good); a **split** breaks up a block (bad). Reciprocity is **balanced** day-for-day (give N, get N).

**Per-day intents** a user marks: **Trade-away** (working day I'd give), **Want-to-work** (off day I'd pick
up), **Keep** (never give this working day — hard), **Must-be-off** (never take this off day — hard). A leg
is **mutual (🔥)** when BOTH sides marked it (giver marked trade-away AND receiver marked want-to-work) →
`intentLevel == 2`. One side = `intentLevel 1`. Neither = `0`.

**The two feeds (this is central to the review):**
- **Trade Solutions** (`TradeRouter.packages`): you pick specific **give-days**; the engine finds balanced
  covers — two-person swaps, fewest-people multi-person covers (min-cost/greedy), and circular loops (N-way).
  Goal: *cover the days I selected*, best options first.
- **Intents** (`TradeRouter.intentSolutions`), two sub-modes:
  - **Mutual**: only deals where BOTH sides marked a day (true 🔥 overlap). Seeds from your marked days AND
    peers' marked days.
  - **All**: also one-sided deals / peers without a published profile (a wider pool).
  Goal: *surface where people's wishes overlap*, most-mutual first (in principle).

**Also present:** ECB one-way give-aways (no swap back; fair first-come queue), and 3-party **qual-swaps**
(a qualified "bridge" C slides onto A's desk so an unqualified taker B can cover; C is an *enabling* leg and
is **not** counted in the trade's `peopleCount`).

---

## §2 — Current architecture (as built)

**Pipeline:** `construct candidate packages → score each post-hoc → curate (floor) → rank`.

1. **Construct** (`packages` / `intentSolutions`):
   - Two-person reciprocal swaps (`TradeMatcher.twoWayExploreCore`).
   - Fewest-people multi-person cover: `OptimalMatcher.minPeopleReciprocal` — branch-and-bound over subset
     **size** k=1…5; feasibility per subset via `MinCostFlow` (**all edge costs = 0** → pure max-flow
     b-matching); give-back assigned by `prefix`. Greedy balanced cover is the fallback.
   - Circular loops: `nWayRoutes` — bounded best-first DFS, loops close only at depth ≥3, cancellable,
     `maxRoutes` backstop. Seed/expansion ordering uses `seedScore` / `givePromise` (urgency + a
     representative `legProb`).
   - Qual-swap tiers.
2. **Score** (uniform, post-hoc): every package gets `acceptanceScore = TradeScore.packageQuality(legs,
   people)` = geometric mean of per-leg `σ(legLogit)`, times `0.85^(N−2)` (flat, intent-blind).
3. **Curate**: `finalize` drops `acceptanceScore < floor` (0.32 normal / 0.07 Lucky), with an empty-feed
   fallback (top few) and a safety ceiling (60).
4. **Rank**: `finalize` sorts by **`rankLess`** for BOTH feeds. `rankLess` keys (tiered/lexicographic):
   `dirtyReceives ↑ → coverageCount ↓ → peopleCount ↑ → bookendTotal ↓ → acceptanceScore ↓ → date ↑ → id`.

**Dead code to resolve:** `rankPackages` (fewest-people-first + 🔥/bookend tiers) and `rankIntentPackages`
(most-🔥-first, and the ONLY user of the learned `partnerPrior`) are defined and unit-tested but **never
called** — both feeds actually run `rankLess`. So the intended "intent-first Intents feed" and the
"individual partner-history tiebreak" are **not live**.

---

## §3 — Working engineer's analysis & draft proposal (for Fable to critique/improve)

### What each engine does re: the acceptance score
- **Min-cost/optimal:** finds the *fewest people* that can feasibly cover; **acceptance score never enters**
  (edge costs are 0; give-back is arbitrary prefix). Scored only afterward.
- **Greedy:** picks the peer covering the most uncovered days (ties → urgency → id); acceptance-blind;
  scored afterward.
- **N-way DFS:** *partially* score-aware — seeds/branches ordered by `legProb`-based promise — but the final
  set is curated by the floor on `packageQuality`.
- **Uniform post-hoc:** all packages then get `packageQuality`; `rankLess` uses it only as key #5.

### What `acceptanceScore` computes, and why numbers sit where they do
`packageQuality` = geometric mean of per-leg `legProb`, × `0.85^(N−2)`. `legProb = σ(1.5·intentLevel +
(bookend ? +0.8 : −(2.5 − 1.1·intentLevel)) + 0.8·soonness − 1.2·qualBridge + 1.5·ecb + 0.2·personPrior)`.
Representative single-leg values (soon trade): mutual+bookend ≈ 0.99, one-sided+bookend ≈ 0.96,
no-intent+bookend ≈ 0.83, one-sided+split ≈ 0.71, no-intent+split ≈ 0.15. So the ceiling is ~0.99 (not
"low"); a 3-way's 0.84 was the flat headcount penalty (0.99 × 0.85). The 0.32 floor sits between
one-sided-split (kept) and no-intent-split (dropped). **Caveat:** weights are hand-tuned → treat the number
as ordinal, not a calibrated probability.

### Identified problems (the review should confirm/expand)
1. **Three rankers, two dead, comments that contradict the wiring.** Consolidate to one.
2. **A rich score barely drives order** — it's a floor gate + a 5th-place tiebreak. The model's nuance is
   wasted on ranking.
3. **Lexicographic ranking is brittle** — a one-unit edge in a high key overrides everything below (e.g.
   coverage 3 vs 2 beats a vastly better 2-day trade). Real preference is a blend.
4. **N-penalty is intent-blind** — punishes a unanimous 4-way as hard as a coerced one (the owner's fix).
5. **`partnerPrior` (learned individual history) is dead** in the live path.
6. **`MinCostFlow` runs at cost 0** — the optimizer never optimizes acceptance; give-back assignment is
   arbitrary.

### Draft proposal (improve or replace)
- **Unify the objective:** fold coverage, people (**intent-aware** penalty), bookend/split, soonness, mutual
  intent, and partner history into ONE `packageQuality`, then **rank primarily by it**; keep at most one or
  two genuine hard gates outside it.
- **Intent-aware N-penalty:** scale the per-extra-person discount by the fraction of non-mutual legs, e.g.
  `0.85^((N−2) · nonMutualFraction)`, where `nonMutualFraction = (# legs with intentLevel < 2) / legCount`.
  All-mutual ⇒ ~no penalty (4-way ≈ 2-way, 2-way edges it on a fewest-people tiebreak); a non-mutual leg at
  larger N ⇒ falls below a clean smaller trade.
- **Real min-cost:** set `day→peer` (and return-leg) edge costs to `−round(K · legLogProb)` so the flow
  returns the max-acceptance cover *within* a fixed people-count k; keep branch-and-bound over k for
  fewest-people. (Fix `saturatedTargets`, which currently identifies forward edges by `cost >= 0`.)
- **One ranker;** delete the dead ones. Decide feed differences by *what is built/seeded*, not by a separate
  sort (or justify a separate sort).
- **Calibration:** optionally fit the logistic weights from stored accept/decline history.

**Owner's stated intent for ordering:** "rank by score, don't overweight fewest-people"; keep coverage-of-my-
days as a top concern; an all-mutual group should be near the top regardless of N.

---

## §4 — Invariants you must NOT break

- **Legality gates** (single shared predicate `TradeEligibility.canCover`, Appendix `TradeMatcher`): off on
  cover day, desk qualification, 8-hour rest, Must-Be-Off, Keep, relief-dispatcher horizon, bookend anchoring
  for bookends-only openness, dispatch-shift timing (0500/1300/2100, no training desks). *(Note: a weekly-hour
  cap was previously removed — do not reintroduce.)*
- **Balanced reciprocity:** give N ↔ receive N; one-way giveaways are the separate ECB path.
- **Qual-swap bridge is NOT counted in `peopleCount`** (it's an enabling leg).
- **Circular loops close only at ≥3 participants** (a 2-cycle is a two-way swap).
- **Concurrency:** heavy cores are `nonisolated` and run in `Task.detached` over `Sendable` snapshots;
  searches are cooperatively cancellable (`Task.isCancelled`) so a re-search supersedes a stale one. Any
  scoring change used as a DFS pruning bound must stay **admissible** (never prune a route that could clear
  the floor).
- **Determinism:** stable tiebreak by `id`; no `Date.now()`/`Math.random()` in pure cores.
- **The regression harness must stay green:** `EngineTests.runAll()` returns only failure strings.

---

## §5 — Edge cases to reason about explicitly

- Empty candidate set; nothing clears the floor (empty-feed fallback); single give-day vs many.
- Partial cover vs full cover of the selected give-days (coverage term).
- Exact ties and **floating-point equality** in comparators (`a.score != b.score` on Doubles).
- All-mutual N-way (must rank high); N-way with 1 non-mutual leg (must fall below clean N−1); monotonicity as
  non-mutual count grows.
- Qual-swap packages (floor-exempt today; bridge excluded from `peopleCount`); do they still surface and sort
  sensibly under the new objective?
- Bookends-only openness (islands hard-excluded) vs open-to-all (islands kept but demoted).
- Mercenary mode; profile-less peers (treated conservatively / bookends-only default).
- Relief-dispatcher horizon (post-horizon days invisible).
- Min-cost give-back assignment when a peer's `givesBack` count barely covers; balance failures → nil.
- DFS `maxRoutes`/`maxDepth` bounds; cancellation mid-search; N-way pruning-bound admissibility.
- Intents **Mutual** excludes no-intent pairings *by construction*; **All** includes unclaimed peers — make
  sure the new ranking doesn't resurrect excluded pairings.

---

## §6 — Source code (verbatim)

The complete algorithm source follows. Files: `TradeScore`/`LegFeatures` and `SearchFilter` from
`TradeEngineModels.swift`; `MinCostFlow.swift`; `OptimalMatcher.swift`; `TradeRouter.swift` (packaging,
scoring, ranking, finalize, N-way DFS); `TradeMatcher.swift` (eligibility, desk rules, timing, two-way
exploration, qual-swap); `TradeProfile.swift` (openness, blacklists, `wouldPickUp`). Line numbers are from
the live repo for cross-reference.


### Appendix A — TradeEngineModels.swift (models, LegFeatures, PersonPrior, TradeScore, SearchFilter — lines 1–700)

```swift
// TradeEngineModels.swift
// Shared value models for the v2 trade engine + UI ("Build 2").
//
// ⚠️ v2 BRANCH WORK — additive only. These are pure, self-contained value types;
// nothing references them yet, so they are inert until the v2 engine/UI is built.
// This file OWNS the shared models; the v2 UI imports them and must not redeclare.
//
// Reuses existing types verbatim (Shift, TradeRequest, TradeResponse,
// TradeRequestStatus). Adds only what the current codebase lacks.

import Foundation

// MARK: - Per-day topology (the "gravity" of a calendar date)

/// How valuable / scarce a single calendar date is. Drives protection of
/// high-value slots and ranking. String-backed so it persists cleanly.
enum DayTopology: String, Codable, Sendable, CaseIterable, Identifiable {
    case standard
    case highDemand
    case personalMilestone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard:          return "Standard"
        case .highDemand:        return "High-Demand"
        case .personalMilestone: return "Personal Milestone"
        }
    }

    /// Gravity weight used by the matcher's scoring. Heavier = protect harder.
    var weight: Double {
        switch self {
        case .standard:          return 1.0
        case .highDemand:        return 2.0
        case .personalMilestone: return 3.0
        }
    }
}

// MARK: - Intent reason (optional tag on a day note)

enum IntentReason: String, Codable, Sendable, CaseIterable, Identifiable {
    case vacation
    case avoidWeekends
    case medical
    case personalEvent
    case fatigueBlock

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vacation:      return "Vacation"
        case .avoidWeekends: return "Avoid Weekends"
        case .medical:       return "Medical"
        case .personalEvent: return "Personal Event"
        case .fatigueBlock:  return "Fatigue Block"
        }
    }

    /// How urgently the user needs the day off → ranks trade solutions. The AI
    /// categorizes free text into one of these, so the categorization directly
    /// influences match ranking.
    var urgency: Int {
        switch self {
        case .medical, .fatigueBlock: return 3   // health / safety — highest
        case .personalEvent:          return 2
        case .vacation:               return 2
        case .avoidWeekends:          return 1
        }
    }
}

// MARK: - Per-day intent states

/// Intent for a day the user is SCHEDULED TO WORK.
///   • `.dontWantToWork` = trade this shift away (purple in the UI)
///   • `.mustWork`       = keep it, hard (red)
/// "Ambivalent / unsure" collapse into `.neutralOpen`.
enum WorkingIntentState: String, Codable, Sendable, CaseIterable, Identifiable {
    case mustWork
    case wantToWork
    case neutralOpen
    case dontWantToWork

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mustWork:       return "Keep"   // working-day protect: keep this shift, never trade it away (green). Case unchanged.
        case .wantToWork:     return "Want to Work"
        case .neutralOpen:    return "Open"
        case .dontWantToWork: return "Want to Trade"
        }
    }
}

/// Intent for a day the user is OFF.
///   • `.wantToWork` = willing to pick up a shift here (green)
///   • `.mustBeOff`  = hard do-not-schedule constraint
enum OffIntentState: String, Codable, Sendable, CaseIterable, Identifiable {
    case mustBeOff
    case neutralOpen
    case wantToWork

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mustBeOff:   return "Blackout"   // B4-1: off-day blackout (never scheduled). Case unchanged.
        case .neutralOpen: return "Open"
        case .wantToWork:  return "Want to Work"
        }
    }
}

// MARK: - Day note (replaces the original "DateTag")

/// A short, optional note attached to a single date. Capped at 50 characters.
/// Private notes never publish to the shared `TradeProfile`.
struct DayNote: Codable, Sendable, Hashable, Identifiable {
    static let maxLength = 50

    let dayID: String          // ISO "yyyy-MM-dd"
    let message: String        // always ≤ maxLength (clamped on init)
    let reason: IntentReason?
    let isPrivate: Bool

    var id: String { dayID }

    init(dayID: String, message: String, reason: IntentReason? = nil, isPrivate: Bool = false) {
        self.dayID = dayID
        self.message = String(message.prefix(Self.maxLength))
        self.reason = reason
        self.isPrivate = isPrivate
    }
}

// MARK: - Shift block (consecutive shifts as one transactional package)

/// A package of consecutive days handled as a single trade unit (e.g. a vacation
/// block to give away). Does not mutate `Shift`.
struct ShiftBlock: Sendable, Hashable, Identifiable {
    let shifts: [Shift]        // sorted by date on init

    init(shifts: [Shift]) {
        self.shifts = shifts.sorted { $0.date < $1.date }
    }

    var id: String { dayIDs.joined(separator: "|") }

    var dayIDs: [String] { shifts.map(\.id) }

    /// True when every day touches the next (no gaps).
    var isContiguous: Bool {
        guard shifts.count > 1 else { return true }
        let cal = Calendar.current
        for i in 1..<shifts.count {
            let prev = cal.startOfDay(for: shifts[i - 1].date)
            let cur  = cal.startOfDay(for: shifts[i].date)
            guard let next = cal.date(byAdding: .day, value: 1, to: prev),
                  cal.isDate(next, inSameDayAs: cur) else { return false }
        }
        return true
    }

    /// The date span covered by the block (nil when empty).
    var span: ClosedRange<Date>? {
        guard let first = shifts.first?.date, let last = shifts.last?.date else { return nil }
        return first...last
    }
}

// MARK: - Solution tiers (the 4 matchmaking bands)

enum SolutionTier: String, Codable, Sendable, CaseIterable, Identifiable {
    case matchingIntents
    case intentsAndBookends
    case neutralOptimization
    case globalPool

    var id: String { rawValue }

    /// Display order (1 = strictest / highest priority).
    var order: Int {
        switch self {
        case .matchingIntents:     return 1
        case .intentsAndBookends:  return 2
        case .neutralOptimization: return 3
        case .globalPool:          return 4
        }
    }

    var label: String {
        switch self {
        case .matchingIntents:     return "Matching Intents"
        case .intentsAndBookends:  return "Intents & Bookends"
        case .neutralOptimization: return "Neutral Optimization"
        case .globalPool:          return "All Options"
        }
    }
}

// MARK: - N-way circular routes (3–4 participant loops)

/// One transfer within a circular trade: `fromID` gives the shift on `dayID`
/// (at `desk`/`startHour`) and `toID` picks it up.
struct NWayLeg: Codable, Sendable, Hashable, Identifiable {
    let fromID: String
    let toID: String
    let dayID: String          // ISO "yyyy-MM-dd"
    let desk: String
    let startHour: Int

    var id: String { "\(fromID)>\(toID)@\(dayID)" }
}

/// A closed-loop trade (A→B→C→A) presented as a single transactional solution.
/// 1-to-1 and 2-way swaps keep using the existing `TwoWayPlan`; this is for 3–4.
struct NWayRoute: Sendable, Hashable, Identifiable {
    let participants: [String]   // worker IDs, in loop order
    let legs: [NWayLeg]
    let tier: SolutionTier
    let score: Double
    let usesBookends: Bool
    var bookendCount: Int = 0   // G3: how many legs are a bookend for their receiver (more = better)

    var id: String { participants.joined(separator: ">") + "#" + legs.map(\.id).joined(separator: ",") }

    var participantCount: Int { participants.count }
}

// MARK: - Trade lifecycle staging

/// The post-proposal lifecycle of a trade. Extends the existing
/// `TradeRequestStatus` with the in-app "accepted" and "marked official" steps.
enum StagingState: String, Codable, Sendable, CaseIterable, Identifiable {
    case pendingNegotiation
    case acceptedInApp          // 100% agreed in app, not yet on the official board
    case markedOfficialByUser   // user confirmed on the company site → archived
    case denied

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pendingNegotiation:  return "Pending"
        case .acceptedInApp:       return "Accepted"
        case .markedOfficialByUser: return "Official"
        case .denied:              return "Denied"
        }
    }

    /// Best-effort mapping from the existing request status.
    init(requestStatus: TradeRequestStatus) {
        switch requestStatus {
        case .pending, .countered, .message: self = .pendingNegotiation
        case .accepted:            self = .acceptedInApp
        case .declined, .cancelled: self = .denied
        }
    }
}

// MARK: - Dashboard counts (green / yellow / red / blue)

/// Aggregated live counts for the global trades status button. Derived from the
/// existing `MessagingStore` data — not a separate source of truth.
struct DashboardCounts: Sendable, Hashable {
    var accepted: Int   // 🟢 agreed in app, not yet marked official
    var pending: Int    // 🟡 out for negotiation / circular confirmation
    var denied: Int     // 🔴 rejected or expired
    var unread: Int     // 💬 unread inbox messages

    static let zero = DashboardCounts(accepted: 0, pending: 0, denied: 0, unread: 0)

    /// Build from requests + their responses, plus an externally-computed unread
    /// count (the inbox already tracks this for `MessagingDock`).
    static func from(requests: [TradeRequest],
                     responses: [TradeResponse],
                     unread: Int,
                     pendingLedger: Int = 0) -> DashboardCounts {
        var accepted = 0, pending = 0, denied = 0
        for req in requests {
            let latest = responses
                .filter { $0.requestID == req.id }
                .max { $0.createdAt < $1.createdAt }?
                .statusValue ?? .pending
            switch StagingState(requestStatus: latest) {
            case .acceptedInApp:                       accepted += 1
            case .pendingNegotiation:                  pending += 1
            case .denied:                              denied += 1
            case .markedOfficialByUser:                break   // moved to history
            }
            if req.isExpired { /* expired proposals read as dead, counted via denied above if declined */ }
        }
        // Pending ECB transfers (form submitted, receipt not yet confirmed) count
        // as pending in the status tags.
        return DashboardCounts(accepted: accepted, pending: pending + pendingLedger,
                               denied: denied, unread: unread)
    }
}

// MARK: - Match-inputs signature (feed-refresh trigger — SPEC S-ENG-9)

/// A Hashable value that changes whenever ANYTHING affecting trade matching changes
/// (openness, mercenary, per-day intents, availability pills, blacklist). A view
/// `.onChange(of: MatchInputsSignature.current)`s it to recompute results — fixing the
/// "changed my openness/intents but nothing refreshed" bug.
struct MatchInputsSignature: Hashable {
    let openness: String
    let mercenary: Bool
    let working: [String: WorkingIntentState]
    let off: [String: OffIntentState]
    let availability: [String: Set<ShiftAvailabilityType>]
    let blacklistDesks: Set<String>
    let blacklistRegions: Set<String>
    let blacklistWeekdays: Set<Int>
    let blacklistShiftTypes: Set<String>

    @MainActor static var current: MatchInputsSignature {
        let s = SettingsManager.shared, d = DayIntentStore.shared
        return .init(openness: s.tradeOpenness, mercenary: s.isMercenaryMode,
                     working: d.workingIntents, off: d.offIntents, availability: d.offAvailability,
                     blacklistDesks: s.blacklistedDesks, blacklistRegions: s.blacklistedRegions,
                     blacklistWeekdays: s.blacklistedWeekdays, blacklistShiftTypes: s.blacklistedShiftTypes)
    }
}

// MARK: - Trade-type label (THE single source of truth — SPEC S-ENG-5 / S-TEST-1)

/// The ONLY function allowed to produce a trade-type badge. Its entire output
/// universe is exactly three shapes: "1-Way Swap", "Qual Swap", "{n}-Person Swap".
// MARK: - H1: unified acceptance-likelihood score (one model, every trade surface)

/// The bounded per-leg signals that drive acceptance probability. Indicators are 0/1; `timeValue`,
/// `hoursStrain`, `ecbValue` are in [0,1]. All inputs are pre-normalized so the score is
/// deterministic (no data-dependent normalization) and harness-testable.
struct LegFeatures {
    var wantToTake: Bool       // receiver marked want-to-work this day (they want to TAKE it)
    var wantToTrade: Bool      // giver marked the day trade-away (they want to TRADE it away)
    var bookend: Bool          // covering this day anchors the receiver's break; else it SPLITS it
    var timeValue: Double      // sooner = higher, e.g. exp(−λ·daysUntil) ∈ [0,1] (+)
    var needsQualBridge: Bool  // leg requires a qual swap (−)
    var ecbValue: Double = 0   // ECB points offered, normalized [0,1] (+; ECB legs only)
    var personPrior: Double = 0 // H2: receiver's acceptance bias in LOGIT space (tiny weight)
    /// 0 (neither wants), 1 (one side), 2 (dual = both want — "mutual").
    var intentLevel: Int { (wantToTake ? 1 : 0) + (wantToTrade ? 1 : 0) }
}

/// H2: a partner's acceptance PRIOR as a logit offset, learned from their accept/decline history.
/// Laplace-smoothed log-odds `log((accepted+α)/(declined+α))` — neutral (no history) → 0, clamped to
/// ±`cap` so a thin record can't dominate the score. PURE → harness-tested.
enum PersonPrior {
    static func logOdds(accepted: Int, declined: Int, alpha: Double = 1, cap: Double = 2) -> Double {
        let a = Double(max(0, accepted)) + alpha
        let d = Double(max(0, declined)) + alpha
        return min(cap, max(-cap, log(a / d)))
    }
}

/// Objective: maximize P(trade executes) = ∏ p(leg). Work in log-space (additive → admissible
/// pruning bound). Per-leg `p = σ(weighted features)`; the σ bounds it to (0,1) intrinsically.
/// Hand-tuned weights now; later fit from inbox accept/decline data (logistic regression).
enum TradeScore {
    // Weights = the DESIGNED match priorities. WANTS dominate (want-to-take + want-to-trade, 1.5
    // each → dual = 3.0). Bookend is a flat +0.8. The SPLIT penalty SHRINKS as intent grows
    // (`splitBase − splitRelief·intentLevel` → none 2.5, single 1.4, dual 0.3) so a split barely dents
    // a dual trade but wrecks a no-intent one. `qual` friction −1.2; `personPrior` tiny (0.2).
    static let wWant = 1.5, wBook = 0.8, wTime = 0.8, wQual = 1.2, wEcb = 1.5, wPerson = 0.2
    static let splitBase = 2.5, splitRelief = 1.1
    /// Per-extra-person multiplier on the package score (each participant beyond 2 scales it by this),
    /// so smaller trades dominate — `allDual+book(N+1) < allDual+split(N)`. (U-PERF N-penalty.)
    static let nPenalty = 0.85

    static func legLogit(_ f: LegFeatures) -> Double {
        let want = wWant * Double(f.intentLevel)
        let splitPen = splitBase - splitRelief * Double(f.intentLevel)   // intent shrinks the split hit
        let structural = f.bookend ? wBook : -splitPen
        return want + structural
             + wTime * f.timeValue
             - wQual * (f.needsQualBridge ? 1 : 0)
             + wEcb * f.ecbValue
             + wPerson * f.personPrior
    }
    /// Probability the receiver accepts this leg, in (0,1).
    static func legProb(_ f: LegFeatures) -> Double { 1.0 / (1.0 + exp(-legLogit(f))) }
    /// Joint probability the whole package executes (all parties accept) = ∏ legProb, with the
    /// N-penalty folded in (each person beyond 2 scales it down).
    static func packageProb(_ legs: [LegFeatures]) -> Double { exp(packageLogProb(legs)) }
    /// log of the joint probability + N-penalty = Σ log legProb + (N−2)·log(nPenalty). The ranking +
    /// floor signal. (Still an admissible upper bound for a partial route — both terms only subtract.)
    static func packageLogProb(_ legs: [LegFeatures]) -> Double {
        legs.map { log(legProb($0)) }.reduce(0.0, +) + Double(max(0, legs.count - 2)) * log(nPenalty)
    }

    /// Average per-leg acceptance QUALITY (geometric mean of legProb), scaled down per extra **person**
    /// (NOT per day) — so covering more days with one clean person is not penalized. In (0,1]. This is
    /// the ranking-floor signal: a clean full-cover scores like a clean single-day, and coverage/fewest-
    /// people are handled by the sort (not by punishing multi-day trades). Fixes the "single-day always
    /// wins" bug where the joint PRODUCT + per-leg N-penalty buried full covers.
    static func packageQuality(_ legs: [LegFeatures], people: Int) -> Double {
        guard !legs.isEmpty else { return 0 }
        let meanLogLeg = legs.map { log(legProb($0)) }.reduce(0.0, +) / Double(legs.count)   // geometric mean
        let peoplePenalty = Double(max(0, people - 2)) * log(nPenalty)                        // per PERSON, not leg
        return exp(meanLogLeg + peoplePenalty)
    }
    /// Admissible upper bound on a partial route's final log-prob: the running sum (remaining legs
    /// can only add ≤ 0). Prune mid-DFS when this drops below log(threshold) — never drops a valid route.
    static func upperBoundLogProb(partial legs: [LegFeatures]) -> Double { packageLogProb(legs) }

    /// G3: desirability (log-joint-acceptance) of a circular route from its per-leg bookend/🔥
    /// flags. A non-bookend leg is a SPLIT, and a 🔥 leg is treated as DUAL intent (both want it).
    /// Empty route → 0 (log 1).
    static func routeDesirability(legBookends: [Bool], legFires: [Bool]) -> Double {
        let feats = zip(legBookends, legFires).map { b, f in
            LegFeatures(wantToTake: f, wantToTrade: f, bookend: b, timeValue: 0.5, needsQualBridge: false)
        }
        return packageLogProb(feats)
    }
}

/// A2: the "I'm Feeling Lucky" Master Filter — shapes the on-demand search. Pure value type so
/// the UI state and the result-filtering agree (single source of truth) and are harness-tested.
struct SearchFilter: Equatable, Sendable {
    enum Engine: String, CaseIterable, Sendable { case minCost, nWay, both }
    var engine: Engine = .both
    var maxPeople: Int = 4          // 1…4 distinct participants (incl. you)
    var requiredWorkerID: String?   // when set, only solutions that INCLUDE this person
    var dateStart: Date?            // only solutions where EVERY moved day is on/after this date
    var dateEnd: Date?              // …and on/before this date
    var receiveTypes: Set<ShiftAvailabilityType> = []  // days you PICK UP must be one of these (empty = any)
    var deskQuals: Set<String> = [] // only trades involving desks requiring one of these quals (empty = any)
    /// Lucky one-time OPENNESS override for MY OWN side of this search (nil = use my saved openness). Lets
    /// me search as e.g. "Open to all" without changing my permanent setting. My blacklist + protective
    /// intents still apply; the counterparties' prefs are untouched. `.none` isn't offered (finds nothing).
    var myOpennessOverride: TradeOpenness? = nil

    /// The default "normal" criteria — every engine, up to 4 people, anyone.
    static let normal = SearchFilter()
    /// The fast BACKGROUND generation scope: two-person trades only (no 3+ multi-cover, no N-Way
    /// circular DFS). Used for auto-feeds; the heavy search runs only on an explicit Generate.
    static let fast = SearchFilter(engine: .minCost, maxPeople: 2)
    /// True when the user has narrowed away from the normal criteria (drives the Reset button +
    /// the "Lucky" button label). A default filter shows everything, so it's NOT active.
    var isActive: Bool { self != SearchFilter.normal }

    /// A compact human summary of only the NON-default selections, e.g. "N-Way · ≤3 · with Cary".
    /// `nameFor` resolves a worker ID to a display name. Returns nil when nothing is narrowed.
    func summary(nameFor: (String) -> String) -> String? {
        guard isActive else { return nil }
        var parts: [String] = []
        if engine != .both { parts.append(engine == .minCost ? "Min-Cost" : "N-Way") }
        if maxPeople != 4 { parts.append("≤\(maxPeople)") }
        if let r = requiredWorkerID { parts.append("with \(nameFor(r))") }
        if dateStart != nil || dateEnd != nil { parts.append("dates") }
        if !receiveTypes.isEmpty { parts.append(receiveTypes.map(\.rawValue).sorted().joined(separator: "/")) }
        if !deskQuals.isEmpty { parts.append(deskQuals.sorted().joined(separator: "/") + " desks") }
        if let o = myOpennessOverride { parts.append(o == .all ? "open to all" : "bookends") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// True if `id` is a participant of `p` (peer assignment or a route participant).
    private func contains(_ id: String, _ p: TradePackage) -> Bool {
        p.assignments.contains { $0.workerID == id } || (p.route?.participants.contains(id) ?? false)
    }
    /// Every day moved by a package (your gives + your gets + circular legs).
    private func movedDayIDs(_ p: TradePackage) -> [String] {
        var d = p.assignments.flatMap { $0.giveDayIDs + $0.takeDayIDs }
        if let legs = p.route?.legs { d += legs.map(\.dayID) }
        return d
    }
    private static let isoFmt: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func iso(_ d: Date) -> String { isoFmt.string(from: d) }

    /// Apply the package-intrinsic filters (post-search): engine/methodology, maxPeople, a required
    /// participant, and the date range (every moved day must fall inside it). The receive-type and
    /// desk-qual criteria need roster data and are applied in the view via `receiveTypes`/`deskQual`.
    func filter(_ packages: [TradePackage], selfID: String) -> [TradePackage] {
        let lo = dateStart.map(Self.iso)
        let hi = dateEnd.map(Self.iso)
        return packages.filter { p in
            if p.peopleCount > maxPeople { return false }
            if let req = requiredWorkerID, !contains(req, p) { return false }
            if lo != nil || hi != nil {
                // The date range is the window you want to trade INTO — so it constrains the days you'd
                // RECEIVE (your take-backs), NOT the days you give away. A single-date range therefore
                // matches a single-day trade (give 1, receive 1 that day). Give-days are your selection.
                let received: [String] = p.route.map { r in r.legs.filter { $0.toID == selfID }.map(\.dayID) }
                    ?? p.assignments.flatMap(\.takeDayIDs)
                guard !received.isEmpty else { return false }
                if let lo, received.contains(where: { $0 < lo }) { return false }
                if let hi, received.contains(where: { $0 > hi }) { return false }
            }
            switch engine {
            case .minCost: return p.methodology != .circular
            case .nWay:    return p.methodology == .circular
            case .both:    return true
            }
        }
    }
}

/// D4 (revised): a single generic propose label everywhere (user pref — no "to {Name}"/"to All").
func proposeButtonTitle(count: Int, name: String) -> String { "Propose" }

/// `distinctPeople` counts every participant INCLUDING you (You↔Cary ⇒ 2 ⇒
/// "2-Person Swap"). Precedence: ECB one-way → qual swap → person count.
/// Do NOT write trade-type label strings anywhere else (guarded by check_arch_map.sh).
func tradeTypeLabel(distinctPeople: Int, isOneWayECB: Bool = false, hasQualSwap: Bool = false) -> String {
    if isOneWayECB { return "1-Way Swap" }
    if hasQualSwap { return "Qual Swap" }
    return "\(max(2, distinctPeople))-Person Swap"
}

/// Distinct participant count for a set of legs (each leg has a from/to worker ID),
/// including everyone referenced. You↔Cary's two legs ⇒ 2. A 3-loop ⇒ 3.
func distinctParticipants(in legs: [TradeLeg]) -> Int {
    Set(legs.flatMap { [$0.fromID, $0.toID] }).count
}

/// The intent brushes shown in Mark-Intents — the SINGLE source of truth so the UI
/// can't silently omit an intent (F1). A test asserts these cover the enums.
enum IntentBrushes {
    /// Working-day brushes. "Open" (neutralOpen) is NOT a manual brush — it's the cleared state, reached
    /// with the intent eraser or set implicitly by the openness shortcut.
    static let working: [WorkingIntentState] = [.dontWantToWork, .mustWork]
    /// Off-day brushes. "Open" (neutralOpen) is likewise the cleared state, not a paintable brush.
    static let off: [OffIntentState] = [.mustBeOff, .wantToWork]
}

/// Pure metrics helpers for the Home header (H1). Global aggregation (CloudKit) is a
/// follow-on; these compute from local data and are unit-tested.
enum MetricPeriod: String, CaseIterable, Identifiable { case month, year, allTime
    var id: String { rawValue }
    var label: String { switch self { case .month: "Month"; case .year: "Year"; case .allTime: "All" } }
}
/// One team-wide metric event (H1 #18) — logged to the public DB so the Home header can show
/// GLOBAL totals (everyone's), not just this device's. `kind` distinguishes the three counters.
struct MetricEvent: Sendable, Codable, Hashable, Identifiable {
    enum Kind: String, Sendable, Codable { case search, proposed, trade }
    let id: String
    let workerID: String
    let kind: Kind
    let createdAt: Date
}

enum Metrics {
    /// Whole-percent success rate; 0 when nothing proposed.
    static func successPercent(accepted: Int, proposed: Int) -> Int {
        proposed > 0 ? Int((Double(accepted) / Double(proposed) * 100).rounded()) : 0
    }

    /// #9: a trade is SUCCESSFUL only once it's both ACCEPTED and ARCHIVED — not merely completed.
    static func isSuccessful(accepted: Bool, archived: Bool) -> Bool { accepted && archived }

    /// Whether `d` falls in the period relative to `now` (shared by all metric counts).
    static func inPeriod(_ d: Date, _ period: MetricPeriod, _ now: Date, _ cal: Calendar = .current) -> Bool {
        switch period {
        case .allTime: return true
        case .month:   return cal.isDate(d, equalTo: now, toGranularity: .month)
        case .year:    return cal.isDate(d, equalTo: now, toGranularity: .year)
        }
    }

    /// #9: total events of `kind` in `period` — whole company (workerID nil) or just YOU (workerID set).
    static func count(_ events: [MetricEvent], kind: MetricEvent.Kind, period: MetricPeriod, now: Date,
                      workerID: String? = nil, cal: Calendar = .current) -> Int {
        events.filter {
            $0.kind == kind
            && (workerID == nil || $0.workerID == workerID!)
            && inPeriod($0.createdAt, period, now, cal)
        }.count
    }

    /// PURE (H1 #18): team-wide counts within `period`, grouped by kind.
    static func global(_ events: [MetricEvent], period: MetricPeriod, now: Date,
                       cal: Calendar = .current) -> (searches: Int, proposed: Int, trades: Int) {
        func inPeriod(_ d: Date) -> Bool {
            switch period {
            case .allTime: return true
            case .month:   return cal.isDate(d, equalTo: now, toGranularity: .month)
            case .year:    return cal.isDate(d, equalTo: now, toGranularity: .year)
            }
        }
        let scoped = events.filter { inPeriod($0.createdAt) }
        return (scoped.filter { $0.kind == .search }.count,
                scoped.filter { $0.kind == .proposed }.count,
                scoped.filter { $0.kind == .trade }.count)
    }
    /// Count of timestamps within the period relative to `now`.
    static func searchCount(_ events: [Date], period: MetricPeriod, now: Date, cal: Calendar = .current) -> Int {
        switch period {
        case .allTime: return events.count
        case .month:   return events.filter { cal.isDate($0, equalTo: now, toGranularity: .month) }.count
        case .year:    return events.filter { cal.isDate($0, equalTo: now, toGranularity: .year) }.count
        }
    }
}

// MARK: - Startup changelog (Z2)

/// App version/build, read from the bundle.
enum AppInfo {
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}

enum ChangeLog {
    /// Show the welcome/changelog once per build the user hasn't seen yet (Z2). The CONTENT now lives
    /// in `AppGuide` (purpose + mechanisms + versionHistory) — a single source the Welcome flow renders —
    /// so there is no separate "current release notes" copy that could drift out of sync.
    static func shouldShow(currentBuild: String, lastSeen: String) -> Bool {
        !currentBuild.isEmpty && currentBuild != lastSeen
    }
}

// MARK: - Blackout matching (B4-3) — a shift the user won't accept per their trade blacklist

/// SSOT for "does this shift match the user's trade blacklist?" — used both by matching (already, via
/// `wouldPickUp`) and to PAINT the shift as blacked-out on the calendar (B4-3). Pure + testable: it takes
/// the shift's dimensions and the four blacklist sets and returns true if ANY dimension is blacklisted.
enum Blackout {
    static func isBlacklisted(desk: String, startHour: Int, weekday: Int,
                              desks: Set<String>, shiftTypes: Set<String>,
                              regions: Set<String>, weekdays: Set<Int>) -> Bool {
        if desks.contains(desk) { return true }
        if weekdays.contains(weekday) { return true }
        if shiftTypes.contains(ShiftAvailabilityType.infer(fromStartHour: startHour).rawValue) { return true }
        if regions.contains(DeskRules.region(forDesk: desk).rawValue) { return true }
        return false
    }
}

/// B4-5: infer what a profileless dispatcher actually works from their recent shifts, so their A8
/// default is hard-restricted to that behavior (region + shift type + weekends). Pure + deterministic.
enum InferredPrefs {
    struct Result: Equatable, Sendable {
        var shiftTypes: Set<String>   // AM/PM/MID they worked
        var regions: Set<String>      // regions they worked
        var worksWeekend: Bool        // worked ≥1 Sat/Sun in the window
    }

    /// From a worker's WORKED shifts within [asOf − lookbackDays, asOf]: the shift types + regions they
    /// work, and whether they work weekends. Returns nil when there's too little history (< `minSample`
    /// worked shifts) so sparse/new people aren't boxed in ("more than a few days" → default 6).
    static func from(entries: [RosterEntry], asOf: Date, lookbackDays: Int = 60,
                     minSample: Int = 6) -> Result? {
        let cutoff = asOf.addingTimeInterval(-Double(lookbackDays) * 86_400)
        let cal = Calendar.current
        var types = Set<String>(), regions = Set<String>()
        var worksWeekend = false, count = 0
        for e in entries where !e.isOff {
            guard let d = TradeMatcher.dayDate(fromISO: e.day), d >= cutoff, d <= asOf else { continue }
            count += 1
            types.insert(ShiftAvailabilityType.infer(fromStartHour: e.startHour).rawValue)
            regions.insert(DeskRules.region(forDesk: e.desk).rawValue)
            let wd = cal.component(.weekday, from: d)
            if wd == 1 || wd == 7 { worksWeekend = true }   // Sun / Sat
        }
        guard count >= minSample else { return nil }
        return Result(shiftTypes: types, regions: regions, worksWeekend: worksWeekend)
    }
}

/// B4-4: one-tap "Blackout weekends" — Sat (7) + Sun (1). Pure so the toggle only ever touches those
/// two weekdays and never disturbs weekdays the user blacklisted individually.
enum WeekendBlackout {
    static let days: Set<Int> = [1, 7]   // 1 = Sun … 7 = Sat (Calendar weekday)
    static func isOn(_ weekdays: Set<Int>) -> Bool { days.isSubset(of: weekdays) }
    static func apply(on: Bool, to weekdays: Set<Int>) -> Set<Int> {
        on ? weekdays.union(days) : weekdays.subtracting(days)
    }
}

// MARK: - Welcome / app guide (startup) — purpose, mechanisms, version history

/// One welcome-page "how it works" topic — operator-facing prose (no jargon).
struct WelcomeTopic: Sendable, Identifiable {
    let title: String
    let symbol: String   // SF Symbol
    let body: String
    var id: String { title }
}

/// One "how it works" section — an engineer-level explanation of a subsystem.
struct MechanismSection: Sendable, Identifiable {
    let title: String
    let symbol: String        // SF Symbol
    let summary: String       // one-line plain-language gist
    let details: [String]     // the real machinery, named
    var id: String { title }
}

/// One shipped release, for the version history (showcases the work done).
struct ReleaseNote: Sendable, Identifiable {
    let version: String       // e.g. "Build 3"

```

### Appendix B — MinCostFlow.swift (full)

```swift
// MinCostFlow.swift
// A general min-cost max-flow solver (successive shortest paths with SPFA, so it
// handles negative edge costs). Used by the optimal reciprocal matcher to verify
// balanced assignments and to minimize cost. Pure value type, fully testable.

import Foundation

struct MinCostFlow {
    private struct Edge { var to: Int; var cap: Int; let cost: Int; let rev: Int }
    private var graph: [[Edge]]

    init(nodes: Int) { graph = Array(repeating: [], count: nodes) }

    /// Directed edge `from → to` with capacity and per-unit cost (residual added).
    mutating func addEdge(_ from: Int, _ to: Int, cap: Int, cost: Int) {
        graph[from].append(Edge(to: to, cap: cap, cost: cost, rev: graph[to].count))
        graph[to].append(Edge(to: from, cap: 0, cost: -cost, rev: graph[from].count - 1))
    }

    /// Push max flow at minimum cost from `s` to `t`. Returns (flow, cost).
    mutating func run(from s: Int, to t: Int) -> (flow: Int, cost: Int) {
        let n = graph.count
        var totalFlow = 0, totalCost = 0
        while true {
            var dist = Array(repeating: Int.max, count: n)
            var inQ  = Array(repeating: false, count: n)
            var prevV = Array(repeating: -1, count: n)
            var prevE = Array(repeating: -1, count: n)
            dist[s] = 0
            var queue = [s]; inQ[s] = true; var qi = 0
            while qi < queue.count {
                let v = queue[qi]; qi += 1; inQ[v] = false
                guard dist[v] != Int.max else { continue }
                for (i, e) in graph[v].enumerated() where e.cap > 0 && dist[v] + e.cost < dist[e.to] {
                    dist[e.to] = dist[v] + e.cost
                    prevV[e.to] = v; prevE[e.to] = i
                    if !inQ[e.to] { inQ[e.to] = true; queue.append(e.to) }
                }
            }
            if dist[t] == Int.max { break }                 // no more augmenting paths
            var f = Int.max, v = t
            while v != s { f = min(f, graph[prevV[v]][prevE[v]].cap); v = prevV[v] }
            v = t
            while v != s {
                graph[prevV[v]][prevE[v]].cap -= f
                let r = graph[prevV[v]][prevE[v]].rev
                graph[v][r].cap += f
                v = prevV[v]
            }
            totalFlow += f
            totalCost += f * dist[t]
        }
        return (totalFlow, totalCost)
    }

    /// After `run`, which `to`-nodes received flow from each `from`-node in a unit
    /// bipartite graph (forward edge fully saturated). Used to read back the
    /// assignment.
    func saturatedTargets(from: Int) -> [Int] {
        graph[from].filter { $0.cap == 0 && $0.cost >= 0 && $0.to != from }.map(\.to)
    }
}

```

### Appendix C — OptimalMatcher.swift (full)

```swift
// OptimalMatcher.swift
// The "optimal" reciprocal-package tier: provably FEWEST counterparties that can
// cover all your give-days with a BALANCED day-for-day swap, using min-cost flow
// for the assignment and a bounded branch-and-bound over counterparty subsets for
// the fewest-people objective (the part plain flow can't express). Falls back to
// the greedy heuristic for large instances (caller decides).

import Foundation

enum OptimalMatcher {

    struct Cand {
        let id: String
        let name: String
        let canTake: Set<String>   // my give-days this peer can cover
        let givesBack: [String]    // their days I can take back (balance capacity)
    }

    struct Assignment {
        let id: String
        let name: String
        let giveDayIDs: [String]   // my shifts they take
        let takeDayIDs: [String]   // their shifts I take back
    }

    // Bounds so this stays instant on-device; beyond these the caller uses greedy.
    static let maxPeers = 16
    static let maxDays = 10
    static let maxSubsetSize = 5

    /// Minimum-counterparty balanced reciprocal cover, or nil if infeasible / too
    /// large (use greedy then). `contiguous` validates the per-person SET so a
    /// package can't fragment anyone's break (the constraint pure flow can't
    /// express); default accepts everything.
    static func minPeopleReciprocal(giveDayIDs: [String], peers: [Cand],
                                    contiguous: ([Assignment]) -> Bool = { _ in true }) -> [Assignment]? {
        let days = Array(Set(giveDayIDs)).sorted()                 // deterministic
        guard !days.isEmpty, days.count <= maxDays, peers.count <= maxPeers else { return nil }
        // Only peers that can take a give-day and give something back; stable order.
        let usable = peers.filter { !$0.canTake.isDisjoint(with: days) && !$0.givesBack.isEmpty }
            .sorted { $0.id < $1.id }
        guard !usable.isEmpty else { return nil }

        let maxK = min(maxSubsetSize, usable.count, days.count)
        for k in 1...maxK {
            var best: [Assignment]?
            combinations(usable.count, k) { idxs in
                let subset = idxs.map { usable[$0] }
                if let a = feasibleAssignment(days: days, subset: subset), contiguous(a) {
                    best = a; return false
                }
                return true   // keep searching this size
            }
            if let best { return best }   // first feasible size = fewest people
        }
        return nil
    }

    // MARK: - Feasibility + assignment via min-cost flow (unit bipartite b-matching)

    private static func feasibleAssignment(days: [String], subset: [Cand]) -> [Assignment]? {
        let g = days.count, p = subset.count
        let source = 0
        let dayNode = { (i: Int) in 1 + i }
        let peerNode = { (j: Int) in 1 + g + j }
        let sink = 1 + g + p
        var mcf = MinCostFlow(nodes: sink + 1)

        for i in 0..<g { mcf.addEdge(source, dayNode(i), cap: 1, cost: 0) }
        for (j, c) in subset.enumerated() {
            for i in 0..<g where c.canTake.contains(days[i]) {
                mcf.addEdge(dayNode(i), peerNode(j), cap: 1, cost: 0)
            }
            mcf.addEdge(peerNode(j), sink, cap: c.givesBack.count, cost: 0)
        }
        let (flow, _) = mcf.run(from: source, to: sink)
        guard flow == g else { return nil }   // not every give-day covered

        // Read the assignment: each give-day → the peer whose edge it saturated.
        var byPeer = [Int: [String]]()   // peer index → my give-days they take
        for i in 0..<g {
            for target in mcf.saturatedTargets(from: dayNode(i)) {
                let j = target - (1 + g)
                if j >= 0 && j < p { byPeer[j, default: []].append(days[i]); break }
            }
        }

        // Balance: each peer takes back as many distinct days as they took of mine.
        var usedBack = Set<String>()
        var result: [Assignment] = []
        for (j, gives) in byPeer where !gives.isEmpty {
            let backs = subset[j].givesBack.filter { !usedBack.contains($0) }
            guard backs.count >= gives.count else { return nil }
            let takes = Array(backs.prefix(gives.count))
            usedBack.formUnion(takes)
            result.append(Assignment(id: subset[j].id, name: subset[j].name,
                                     giveDayIDs: gives, takeDayIDs: takes))
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Bounded combination generator (stops when `body` returns false)

    private static func combinations(_ n: Int, _ k: Int, _ body: ([Int]) -> Bool) {
        var idx = Array(0..<k)
        guard k <= n else { return }
        while true {
            if !body(idx) { return }
            var i = k - 1
            while i >= 0 && idx[i] == n - k + i { i -= 1 }
            if i < 0 { return }
            idx[i] += 1
            for j in (i + 1)..<k { idx[j] = idx[j - 1] + 1 }
        }
    }
}

```

### Appendix D — TradeRouter.swift (packaging, scoring, ranking, finalize, N-way DFS — full)

```swift
// TradeRouter.swift
// v2 matchmaking on top of the existing TradeMatcher. Adds:
//   • packages          — reciprocal "fewest people" covers (optimal + greedy)
//   • tieredSolutions   — segments swaps into the 4 SolutionTiers for the feed
//   • nWayRoutes        — bounded 3–4-person circular trade loops
// Reuses TradeMatcher's hard gates (qualified / rested / anchored) verbatim; never
// duplicates that logic. All roster reads go through RosterStore.

import Foundation

// MARK: - Constraints (soft prefs are bypassable; hard gates always apply)

/// Soft-preference switches. Hard gates (qualification, 8h rest, weekly-hour caps,
/// `.mustBeOff`) are ALWAYS enforced and are not represented here.
struct MatchConstraints: Sendable {
    var enforceChaining: Bool          // bookend / "no floating island" screening
    var enforceTopology: Bool          // protect high-demand / milestone dates
    var enforceShiftTimeBlacklist: Bool

    static let standard = MatchConstraints(enforceChaining: true,
                                           enforceTopology: true,
                                           enforceShiftTimeBlacklist: true)

    /// "What If?" mode flips every soft preference off, widening the result set.
    static func make(isWhatIfModeActive: Bool) -> MatchConstraints {
        isWhatIfModeActive
            ? MatchConstraints(enforceChaining: false, enforceTopology: false,
                               enforceShiftTimeBlacklist: false)
            : .standard
    }
}


// MARK: - Packaged solution (one card per deal)

enum TradeMethodology: String, Sendable {
    case greedy   = "Fewest people"
    case circular = "Circular swap"
}

/// One counterparty in a reciprocal package: your shifts they take, and their
/// shifts you take back (balanced for a true day-for-day swap).
struct PackageAssignment: Sendable, Hashable, Identifiable {
    let workerID: String
    let name: String
    let giveDayIDs: [String]   // YOUR shifts this person covers (you → them)
    let takeDayIDs: [String]   // THEIR shifts you cover (them → you) — the DEFAULT (top-ranked) give-back
    /// All eligible give-back days from this peer, ranked (bookend-first, then soonest) — a superset of
    /// `takeDayIDs`. Lets the UI offer the alternatives (e.g. Jul 15 under Sep) instead of only the top pick.
    /// Empty = no alternatives surfaced (multi-day/circular/qual-swap packages).
    var takeOptions: [String] = []
    var id: String { workerID }
    var dayIDs: [String] { giveDayIDs }   // back-compat for simple displays
}

/// A complete, proposable deal: either a greedy give-away (you → coverers) or a
/// circular swap loop. Rendered as a single card with one action button.
struct TradePackage: Sendable, Hashable, Identifiable {
    let id: String
    let methodology: TradeMethodology
    let assignments: [PackageAssignment]
    let route: NWayRoute?               // present for circular (drives Execute)
    var urgency: Int = 0                // max reason-urgency over the days covered
    var isOptimal: Bool = false         // true = provably fewest people; false = fast heuristic
    // U4 sort signals. fireCount = mutual-intent (🔥) matches in the package; bookendTotal =
    // total bookends delivered across ALL sides (more = more optimal, even when open-to-all).
    var fireCount: Int = 0
    var bookendTotal: Int = 0
    // Q1: a qual-swap leg this package depends on (a give-day blocked only by qualification, with
    // a bridge available). nil = no qual swap needed. Drives the card indicator + send-time blast.
    var qualSwap: QualSwapLegData? = nil
    // H2: avg of the counterparties' learned acceptance priors (logit). A late ranking tiebreaker so,
    // all else equal, partners who historically accept float up. 0 = neutral / no history.
    var partnerPrior: Double = 0
    // TradeScore: the model's average per-leg acceptance QUALITY (0…1). Ranking tiebreak + floor signal.
    var acceptanceScore: Double = 0
    // How many of YOUR requested give-days this package covers — the PRIMARY ranking key (most coverage
    // first, so one person covering all your days floats to the top). Set at generation.
    var coverageCount: Int = 0
    // How many days YOU receive that are NOT a clean bookend for you (a random mid-week island you didn't
    // mark want-to-work). When you're open-to-all these aren't excluded, but a package with any of them
    // ranks BELOW every all-clean package (bookends ranked higher). Set at generation.
    var dirtyReceives: Int = 0

    // EXPLICIT init — freezes the construction signature so adding the fields above doesn't
    // churn the memberwise-init symbol (stale-incremental-link fix). New fields are defaulted.
    init(id: String, methodology: TradeMethodology, assignments: [PackageAssignment],
         route: NWayRoute?, urgency: Int = 0, isOptimal: Bool = false,
         fireCount: Int = 0, bookendTotal: Int = 0, qualSwap: QualSwapLegData? = nil,
         partnerPrior: Double = 0, acceptanceScore: Double = 0, coverageCount: Int = 0) {
        self.id = id; self.methodology = methodology; self.assignments = assignments
        self.route = route; self.urgency = urgency; self.isOptimal = isOptimal
        self.fireCount = fireCount; self.bookendTotal = bookendTotal; self.qualSwap = qualSwap
        self.partnerPrior = partnerPrior; self.acceptanceScore = acceptanceScore
        self.coverageCount = coverageCount
    }

    // TOTAL distinct people INCLUDING you (SPEC S-ENG-5): You↔Cary ⇒ 2. The route
    // lists each participant once (incl. self); assignments list only the others, so + you.
    var peopleCount: Int {
        if let route { return Set(route.participants).count }
        return Set(assignments.map(\.workerID)).count + 1
    }
    var allDayIDs: [String] { assignments.flatMap(\.dayIDs) }
    /// D5: a package needing a qual-swap bridge sorts UNDER clean ones of the same N.
    var needsQualSwap: Bool { qualSwap != nil }
    /// A package is CIRCULAR only with **≥3 participants** (#4) — a 2-cycle is just a 2-way swap.
    var isCircular: Bool { methodology == .circular && peopleCount >= 3 }
    /// B4-14: two-person swaps (you + one, incl. a 2-way qual-swap) render as the compact ECB-style card;
    /// 3+-person and circular keep the full `PackageCard`. Presentation routing only.
    var usesCompactCard: Bool { peopleCount == 2 }
    /// Earliest ISO day anything moves in this package (give/take + route legs) — the global sort
    /// tiebreak (#4b: closer trades first). ISO "yyyy-MM-dd" strings sort chronologically.
    var earliestDayID: String? {
        var days = assignments.flatMap { $0.giveDayIDs + $0.takeDayIDs }
        if let legs = route?.legs { days += legs.map(\.dayID) }
        return days.min()
    }
}

// MARK: - Router

@MainActor
enum TradeRouter {

    private typealias DayMap = [String: RosterEntry]   // ISO day → entry

    /// Horizon shared with the two-way badge logic.
    private static var horizon: (start: Date, end: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .month, value: TradeMatcher.twoWayHorizonMonths, to: today) ?? today
        return (today, end)
    }

    // MARK: - Shared search context (built once per pass)

    /// The derived world for ONE matching pass — built once and reused across packaging, intent
    /// assembly, and the N-way DFS instead of each re-fetching the roster, rebuilding the day-maps,
    /// re-deriving the candidate universe, and re-scanning all responses for acceptance priors.
    /// Behavior-identical to building these inline (same rows, same formulas); just not repeated.
    /// (U-PERF — collapses the previously 4×-duplicated load/build block.)
    // NOT main-actor isolated + Sendable: everything here is a value snapshot, so the heavy candidate
    // loops that consume it can run off the main thread.
    private struct MatchContext: Sendable {
        let start: Date
        let end: Date
        let selfID: String
        let maps: [String: DayMap]                                 // worker → (ISO day → entry)
        let rosterMeta: [String: (name: String, quals: [String])]
        let profilesByID: [String: TradeProfile]
        let universe: [MatchCandidate]
        let priors: [String: Double]                               // worker → acceptance log-odds
        let inferred: [String: InferredPrefs.Result]               // B4-5: profileless peers' recent behavior

        /// My own schedule entries in the window (the preload `twoWayExplore` reuses).
        var mineEntries: [RosterEntry] { Array((maps[selfID] ?? [:]).values) }
        /// worker → quals, for the per-leg qual-bridge feature.
        var qualsDict: [String: [String]] { rosterMeta.mapValues { $0.quals } }

        /// A roster peer with no published profile is included (never invisible). B4-5: if they've worked
        /// enough recently, hard-restrict their default to that behavior — region + shift type + weekends
        /// (weekend blacklist only if they worked none). A real published profile always wins.
        nonisolated func profile(for id: String, name: String) -> TradeProfile {
            if let p = profilesByID[id] { return p }
            guard let inf = inferred[id] else {
                return TradeProfile.defaultForUnpublished(workerID: id, name: name)
            }
            return TradeProfile.defaultForUnpublished(workerID: id, name: name,
                                                      inferredShiftTypes: inf.shiftTypes,
                                                      inferredRegions: inf.regions,
                                                      blacklistWeekends: !inf.worksWeekend)
        }

        static func build(selfID: String) async -> MatchContext {
            let (start, end) = horizon
            // The store reads stay on the main actor (RosterModelActor hop + @Observable reads); the heavy
            // CPU — building the per-worker day-maps, the candidate universe, and the 60-day inferred-prefs
            // — is pure over these Sendable snapshots, so it runs OFF the main thread (no UI freeze).
            let allEntries = await RosterStore.shared.entries(from: start, to: end)
            let lookbackStart = start.addingTimeInterval(-60 * 86_400)
            let recentEntries = await RosterStore.shared.entries(from: lookbackStart, to: start)
            let profilesByID = TradeProfileStore.shared.others
            let priors = MessagingStore.shared.acceptancePriorMap()
            let d = await derive(allEntries: allEntries, recentEntries: recentEntries,
                                 profilesByID: profilesByID, selfID: selfID, asOf: start)
            return MatchContext(start: start, end: end, selfID: selfID, maps: d.maps,
                                rosterMeta: d.rosterMeta, profilesByID: profilesByID,
                                universe: d.universe, priors: priors, inferred: d.inferred)
        }

        /// The pure, CPU-heavy derivation, run on a background thread (`Task.detached`). Everything in and
        /// out is `Sendable`; it reads NO shared/main-actor state — so it's identical to the old inline code,
        /// just off the main run loop.
        nonisolated private static func derive(
            allEntries: [RosterEntry], recentEntries: [RosterEntry],
            profilesByID: [String: TradeProfile], selfID: String, asOf: Date
        ) async -> (maps: [String: DayMap], rosterMeta: [String: (name: String, quals: [String])],
                    universe: [MatchCandidate], inferred: [String: InferredPrefs.Result]) {
            await Task.detached(priority: .userInitiated) {
                var maps: [String: DayMap] = [:]
                var rosterMeta: [String: (name: String, quals: [String])] = [:]
                for e in allEntries {
                    maps[e.workerID, default: [:]][e.day] = e
                    if rosterMeta[e.workerID] == nil { rosterMeta[e.workerID] = (e.workerName, e.quals) }
                }
                // People permanently on TRN / irregular shifts are "not a dispatch shift" → not tradeable.
                // Keep only workers whose in-window schedule holds at least one genuine dispatch shift; a
                // real dispatcher with a stray training day is retained (canCover still blocks that one leg).
                let dispatchWorkers = Set(maps.compactMap { (wid, map) in
                    map.values.contains { TradeTiming.isDispatchShift(desk: $0.desk, startHour: $0.startHour, isOff: $0.isOff) } ? wid : nil
                })
                let universe = MatchUniverse.candidates(
                    roster: rosterMeta.map { (id: $0.key, name: $0.value.name, quals: $0.value.quals) },
                    profiles: profilesByID, selfID: selfID)
                    .filter { dispatchWorkers.contains($0.workerID) }
                // B4-5: infer each PROFILELESS peer's recent (60d) behavior to hard-restrict their default.
                var recentByWorker: [String: [RosterEntry]] = [:]
                for e in recentEntries { recentByWorker[e.workerID, default: []].append(e) }
                var inferred: [String: InferredPrefs.Result] = [:]
                for (wid, entries) in recentByWorker where profilesByID[wid] == nil {
                    if let inf = InferredPrefs.from(entries: entries, asOf: asOf) { inferred[wid] = inf }
                }
                return (maps, rosterMeta, universe, inferred)
            }.value
        }
    }

    // MARK: Greedy recipient minimization


    // MARK: Packaged solutions (greedy first, circular as a >2-person alternative)

    /// Build proposable packages for the user's give-away days. Greedy "fewest
    /// people" covers come first; if the best greedy needs >2 coverers, circular
    /// swap loops are offered alongside (not instead). Sorted fewest-people first.
    /// `generation` bounds how hard the search works. The DEFAULT (`.fast`) finds only 2-person
    /// trades — cheap enough to auto-run in the background. The expensive 3+ multi-person covers and
    /// N-Way circular DFS run ONLY when the caller widens the scope (the "I'm Feeling Lucky" Generate),
    /// so they never burn cycles in the background. (Speed: U-PERF.)
    static func packages(excluding selfID: String, generation: SearchFilter = .fast,
                         lucky: Bool = false) async -> [TradePackage] {
        let (start, end) = horizon
        let giveShifts = await selfSeekingShifts(myID: selfID, start: start, end: end)
        return await packages(forGiveShifts: giveShifts, excluding: selfID, generation: generation, lucky: lucky)
    }

    /// RECIPROCAL packaging for an explicit set of give-away shifts. Every package
    /// is balanced — you give N and receive N back, all passing your criteria. A
    /// pairwise greedy (fewest counterparties) comes first; N-way circular loops
    /// are offered when pairwise can't fully reciprocate. Used by both feeds.
    static func packages(forGiveShifts giveShifts: [Shift], excluding selfID: String,
                         generation: SearchFilter = .fast, lucky: Bool = false) async -> [TradePackage] {
        let giveDayIDs = Set(giveShifts.filter { !$0.isOff }.map(\.id))
        guard !giveDayIDs.isEmpty else { return [] }

        // A day's urgency blends the AI-categorized reason with the day's topology,
        // so personal milestones and high-demand holidays raise a day's priority too
        // — not just the free-text reason. Used to rank/tie-break trade solutions.
        func dayUrgency(_ dayID: String) -> Int {
            let reason = DayIntentStore.shared.note(forDay: dayID)?.reason?.urgency ?? 0
            let topo: Int
            switch DayIntentStore.shared.topology(forDay: dayID) {
            case .personalMilestone: topo = 3   // your protected personal date
            case .highDemand:        topo = 2   // holiday / known high-demand
            case .standard:          topo = 0
            }
            return reason + topo
        }
        func urgency(of dayIDs: [String]) -> Int { dayIDs.map(dayUrgency).max() ?? 0 }
        func urgencyWeight(_ dayIDs: [String]) -> Int { dayIDs.map(dayUrgency).reduce(0, +) }

        let ctx = await MatchContext.build(selfID: selfID)
        let (start, end) = (ctx.start, ctx.end)
        let mySeeking = DayIntentStore.shared.seekingDayIDs
        let myWantToWork = DayIntentStore.shared.wantToWorkDayIDs   // non-bookend days I'll still accept receiving
        // Lucky one-time openness override: search with my openness set to the chosen level (else my saved
        // one). The effective profile carries the level through wouldPickUp / bookend gating naturally.
        let myProfile = generation.myOpennessOverride.map { TradeProfileStore.shared.myProfile().withOpenness($0) }
            ?? TradeProfileStore.shared.myProfile()
        let myBookendsOnly = myProfile.opennessLevel == .bookends

        // The date range is the RECEIVE window (days you want to trade INTO). When set, the give-back the
        // package offers you must fall inside it — otherwise the bookend-first ranking would keep handing
        // you the "best" (bookend) day instead of the specific day you're targeting (e.g. Jul 15).
        let winLo = generation.dateStart.map(SearchFilter.iso)
        let winHi = generation.dateEnd.map(SearchFilter.iso)
        func inReceiveWindow(_ dayID: String) -> Bool {
            (winLo.map { dayID >= $0 } ?? true) && (winHi.map { dayID <= $0 } ?? true)
        }

        // Whether `prof` would actually pick up a leg — honors their availability
        // pills, openness, bookend (no-split) rule, blacklist, and mercenary mode.
        func wouldTake(_ prof: TradeProfile, _ leg: TwoWayLeg) -> Bool {
            let cal = Calendar.current
            let weekday = cal.component(.weekday, from: leg.date)
            let region  = DeskRules.region(forDesk: leg.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: leg.startHour).rawValue
            return prof.wouldPickUp(onDay: leg.dayID, weekday: weekday, desk: leg.desk,
                                    shiftType: type, region: region, isBookend: leg.bookend)
        }

        // R-A: the candidate UNIVERSE is the whole roster, not just opted-in profiles. The shared
        // `ctx` already loaded every worker's window schedule ONCE, built the day-maps, and derived
        // the universe (unknown-profile peers included); twoWayExplore reuses those (no per-peer re-fetch).
        let maps = ctx.maps
        let universe = ctx.universe
        let profileFor: @Sendable (String, String) -> TradeProfile = { id, name in ctx.profile(for: id, name: name) }
        let mineEntries = ctx.mineEntries

        // Per-peer reciprocal capacity via two-way exploration, gated by BOTH parties' real rules.
        struct PeerSwap { let id: String; let name: String; let canTake: [String]; let givesBack: [String] }
        var peerSwaps: [PeerSwap] = []
        var plansByPeer: [String: TwoWayPlan] = [:]   // retained for U4 fire/bookend scoring
        for cand in universe.sorted(by: { $0.workerID < $1.workerID }) {
            if Task.isCancelled { return [] }   // U-PERF: cancellable mid-scan (Cancel button / supersede)
            await Task.yield()                  // hand the main run loop a turn so the UI never freezes
            let profile = profileFor(cand.workerID, cand.name)
            let plan = TradeMatcher.twoWayExploreCore(
                withWorker: cand.workerID, name: cand.name,
                windowStart: start, windowEnd: end,
                mySeeking: mySeeking, theirSeeking: profile.seekingDayIDs,
                myProfile: myProfile, theirProfile: profile,
                ignoreOwnBlacklist: false,
                myEntries: mineEntries, peerEntries: Array((maps[cand.workerID] ?? [:]).values))
            plansByPeer[cand.workerID] = plan
            let canTake   = plan.iGive.filter { giveDayIDs.contains($0.dayID) && wouldTake(profile, $0) }.map(\.dayID)
            // The days I'll RECEIVE back, bookends-first. If I'm Bookends Only, non-bookend islands are
            // dropped; if I'm open-to-all they're kept (but sorted last, and demote the package in ranking).
            let givesBack = TradeRouter.cleanReceiveLegs(plan.iTake.filter { wouldTake(myProfile, $0) },
                                                         wantToWork: myWantToWork,
                                                         bookendsOnly: myBookendsOnly).map(\.dayID)
                                                         .filter(inReceiveWindow)   // honor the receive window
            if !canTake.isEmpty, !givesBack.isEmpty {
                peerSwaps.append(PeerSwap(id: cand.workerID, name: cand.name, canTake: canTake, givesBack: givesBack))
            }
        }

        var result: [TradePackage] = []
        func anchoredSet(_ ids: [String], in map: [String: RosterEntry]) -> Bool {
            let plan = Set(ids)
            return ids.allSatisfy { d in
                guard let day = TradeMatcher.dayDate(fromISO: d) else { return false }
                return TradeMatcher.isAnchored(day: day, map: map, plan: plan)
            }
        }
        // Only people whose rule is "bookends" must keep contiguous breaks. My side uses my EFFECTIVE
        // openness (the one-time override, if set), so an "open to all" search skips my contiguity naturally.
        func contiguityOK(_ assignments: [OptimalMatcher.Assignment]) -> Bool {
            for a in assignments {
                if TradeProfileStore.shared.profile(forWorker: a.id)?.opennessLevel == .bookends,
                   !anchoredSet(a.giveDayIDs, in: maps[a.id] ?? [:]) { return false }
            }
            if myProfile.opennessLevel == .bookends,
               !anchoredSet(assignments.flatMap(\.takeDayIDs), in: maps[selfID] ?? [:]) { return false }
            return true
        }

        // We aim to surface a fuller SET of real options (target ~5) — but only
        // FEASIBLE ones; an empty pool can't be padded with fake trades.
        let targetCount = 5
        let giveAll = Array(giveDayIDs)
        func asOpt(_ a: [PackageAssignment]) -> [OptimalMatcher.Assignment] {
            a.map { OptimalMatcher.Assignment(id: $0.workerID, name: $0.name,
                                              giveDayIDs: $0.giveDayIDs, takeDayIDs: $0.takeDayIDs) }
        }

        // 1) #3: a SEPARATE two-person trade per peer for the days THEY can reciprocally cover —
        //    full OR partial. The user proposes these individually instead of one bundled N-person
        //    package; 2-person packages outrank circular via rankPackages (peopleCount). Full-cover
        //    (one peer takes everything) is flagged optimal so it floats to the top of the 2-person band.
        for ps in peerSwaps {
            let canTakeSet = Set(ps.canTake)
            let cover = giveAll.filter { canTakeSet.contains($0) }
            guard !cover.isEmpty, ps.givesBack.count >= cover.count else { continue }
            let a = [PackageAssignment(workerID: ps.id, name: ps.name,
                                       giveDayIDs: cover, takeDayIDs: Array(ps.givesBack.prefix(cover.count)),
                                       // Single give-day → surface every eligible give-back (ranked) so the
                                       // card can offer alternatives (e.g. Jul 15 under the top pick).
                                       takeOptions: cover.count == 1 ? ps.givesBack : [])]
            guard contiguityOK(asOpt(a)) else { continue }
            let fullCover = Set(cover).isSuperset(of: giveDayIDs)
            result.append(TradePackage(id: "two-\(ps.id)", methodology: .greedy, assignments: a,
                                       route: nil, urgency: urgency(of: cover), isOptimal: fullCover))
        }

        // 1b) QUAL-SWAP TIER (D5): a peer who'd take one of my INTERNATIONAL give-days but LACKS the desk
        //     qual is normally dropped by `twoWayExplore`'s eligibility gate. If a working bridge can slide
        //     onto that desk, surface a reciprocal package FLAGGED with the qual-swap leg (bridge candidates
        //     ride along; the user picks the bridge via the Q button in the package view). These carry a
        //     `qualSwap` leg so `rankPackages` sorts them BELOW clean trades of the same people-count. (This
        //     is the feed's inline offering; the green button's one-way finder + `TradeMerge` is a SEPARATE,
        //     complementary path for pre-arranging a swap.)
        let tierCal = Calendar.current
        let intlGives = giveShifts.filter { !$0.isOff && DeskRules.hasQualGatedSelection(desks: [$0.desk]) }
        for s in intlGives where giveDayIDs.contains(s.id) {
            let region  = DeskRules.region(forDesk: s.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: s.startHour).rawValue
            let weekday = tierCal.component(.weekday, from: s.date)
            for cand in universe.sorted(by: { $0.workerID < $1.workerID }) {
                if Task.isCancelled { return [] }
                await Task.yield()
                let pMap = maps[cand.workerID] ?? [:]
                guard let pe = pMap[s.id], pe.isOff else { continue }                              // peer OFF that day
                let peerQuals = pMap.values.first?.quals ?? []
                guard !DeskRules.qualified(quals: peerQuals, forDesk: s.desk) else { continue }    // qualified → normal path
                guard TradeMatcher.isRested(map: pMap, day: s.date, startHour: s.startHour, cal: tierCal) else { continue }
                let profile = profileFor(cand.workerID, cand.name)
                let isBookend = TradeMatcher.anchored(day: s.date, map: pMap, plan: [s.id], cal: tierCal)
                guard profile.wouldPickUp(onDay: s.id, weekday: weekday, desk: s.desk,
                                          shiftType: type, region: region, isBookend: isBookend) else { continue }
                // Reciprocal give-back (their days I'd take), clean/bookend-first, inside the receive window.
                let givesBack = TradeRouter.cleanReceiveLegs((plansByPeer[cand.workerID]?.iTake ?? []).filter { wouldTake(myProfile, $0) },
                                                             wantToWork: myWantToWork, bookendsOnly: myBookendsOnly)
                                                             .map(\.dayID).filter(inReceiveWindow)
                guard !givesBack.isEmpty else { continue }
                // A bridge must exist, else it's a true dead end — don't surface it. (buildQualSwapLeg = nil.)
                guard let leg = await TradeMatcher.buildQualSwapLeg(
                    giveDayID: s.id, giveDesk: s.desk, giveStartHour: s.startHour,
                    giverID: selfID, takerID: cand.workerID, takerName: cand.name, takerQuals: peerQuals) else { continue }
                let a = [PackageAssignment(workerID: cand.workerID, name: cand.name,
                                           giveDayIDs: [s.id], takeDayIDs: Array(givesBack.prefix(1)),
                                           takeOptions: givesBack)]
                guard contiguityOK(asOpt(a)) else { continue }
                result.append(TradePackage(id: "qualtrade-\(s.id)-\(cand.workerID)", methodology: .greedy,
                                           assignments: a, route: nil, urgency: urgency(of: [s.id]), qualSwap: leg))
            }
        }

        // 2) Also offer a fewest-people MULTI-person cover of your days (optimal, else a greedy balanced
        //    cover) — ALWAYS when 3+ is allowed, not only when no 2-person exists. Coverage-first ranking
        //    then floats a full multi-person cover above 2-person partials. (Was gated on `result.isEmpty`,
        //    which hid multi-person covers whenever any 2-person partial existed.)
        if generation.maxPeople >= 3 {
            let cands = peerSwaps.map {
                OptimalMatcher.Cand(id: $0.id, name: $0.name, canTake: Set($0.canTake), givesBack: $0.givesBack)
            }
            var addedMulti = false
            // ≥2 peers only: a single-peer "cover" is already emitted as a `two-` card in step 1 (both are
            // peopleCount==2 → both render as compact cards → the SAME peer shows twice). Step 2 exists for
            // genuine MULTI-person covers, so skip the degenerate 1-peer case here. (B6-DEDUP.)
            if let opt = OptimalMatcher.minPeopleReciprocal(giveDayIDs: giveAll, peers: cands, contiguous: contiguityOK),
               opt.count >= 2 {
                let a = opt.map { PackageAssignment(workerID: $0.id, name: $0.name,
                                                    giveDayIDs: $0.giveDayIDs, takeDayIDs: $0.takeDayIDs) }
                result.append(TradePackage(
                    id: "optimal-" + a.map(\.workerID).sorted().joined(separator: ","),
                    methodology: .greedy, assignments: a, route: nil,
                    urgency: urgency(of: a.flatMap(\.giveDayIDs)), isOptimal: true))
                addedMulti = true
            }
            // Greedy balanced cover — only as a fallback when the optimal one didn't produce a cover.
            if !addedMulti {
                var uncovered = giveDayIDs
                var usedBack = Set<String>()
                var assigns: [PackageAssignment] = []
                var pool = peerSwaps
                while !uncovered.isEmpty {
                    let best = pool.compactMap { ps -> (PeerSwap, [String], [String])? in
                        let gives = ps.canTake.filter { uncovered.contains($0) }
                        let backs = ps.givesBack.filter { !usedBack.contains($0) }
                        let k = min(gives.count, backs.count)
                        guard k > 0 else { return nil }
                        return (ps, Array(gives.prefix(k)), Array(backs.prefix(k)))
                    }.max { l, r in
                        if l.1.count != r.1.count { return l.1.count < r.1.count }
                        let lu = urgencyWeight(l.1), ru = urgencyWeight(r.1)
                        if lu != ru { return lu < ru }
                        return l.0.id > r.0.id
                    }
                    guard let (ps, gives, takes) = best else { break }
                    assigns.append(PackageAssignment(workerID: ps.id, name: ps.name,
                                                     giveDayIDs: gives, takeDayIDs: takes))
                    uncovered.subtract(gives)
                    usedBack.formUnion(takes)
                    pool.removeAll { $0.id == ps.id }
                }
                // Same ≥2-peer rule as the optimal branch: a lone-peer greedy cover duplicates its step-1
                // `two-` card, so only surface genuine multi-person covers here. (B6-DEDUP.)
                if uncovered.isEmpty, assigns.count >= 2, contiguityOK(asOpt(assigns)) {
                    result.append(TradePackage(
                        id: "recip-" + assigns.map(\.workerID).sorted().joined(separator: ","),
                        methodology: .greedy, assignments: assigns, route: nil,
                        urgency: urgency(of: assigns.flatMap(\.giveDayIDs))))
                }
            }
        }

        // 3) Circular loops — GATED: the N-Way DFS is the most expensive step, so it runs ONLY when
        //    the caller widened the scope (Lucky/Generate with N-Way/Both and ≥3 people), never in the
        //    fast background pass. `maxDepth` is bounded to the requested people cap.
        if generation.maxPeople >= 3, generation.engine != .minCost {
            // OFF-MAIN (Step 3): snapshot the main-actor state the DFS reads, then run it detached — same
            // pattern as intentSolutions so the Generate tap can't freeze the UI either.
            let notesByDay = DayIntentStore.shared.notes
            let topologyByDay = DayIntentStore.shared.topologies
            let myKeepDays = DayIntentStore.shared.keepDayIDs
            let myReliefThrough = SettingsManager.shared.effectiveReliefThrough
            let profilesByID = ctx.profilesByID
            let loops: [NWayRoute] = await Task.detached(priority: .utility) {
                nWayRoutes(seedShifts: giveShifts, maxDepth: generation.maxPeople,
                           excluding: selfID, maxRoutes: 500,   // high safety backstop; the floor curates
                           windowStart: start, maps: maps,      // U-PERF: reuse the loaded window
                           myProfile: myProfile, profilesByID: profilesByID,
                           myKeepDays: myKeepDays, mySeeking: mySeeking,
                           myReliefThrough: myReliefThrough,
                           notesByDay: notesByDay, topologyByDay: topologyByDay)
            }.value
            if Task.isCancelled { return [] }
            for loop in loops.prefix(targetCount * 2) {
                var gv: [String: [String]] = [:]   // peer → my days they cover
                var tk: [String: [String]] = [:]   // peer → their days I cover
                for leg in loop.legs {
                    if leg.fromID == selfID { gv[leg.toID, default: []].append(leg.dayID) }
                    if leg.toID == selfID   { tk[leg.fromID, default: []].append(leg.dayID) }
                }
                let participants = Set(gv.keys).union(tk.keys)
                let a = participants.map { pid in
                    PackageAssignment(workerID: pid, name: participantName(pid),
                                      giveDayIDs: gv[pid] ?? [], takeDayIDs: tk[pid] ?? [])
                }
                result.append(TradePackage(id: "circular-" + loop.id, methodology: .circular,
                                           assignments: a, route: loop,
                                           urgency: urgency(of: a.flatMap(\.giveDayIDs))))
            }
        }

        // Q1: give-days blocked PURELY by qualification (no off peer that day is qualified for the
        // desk) → assemble 3-party qual-swap packages (bridge C takes my desk; off-taker B takes C's
        // freed desk). The bridge is NOT counted in N. Reuses the loaded `maps` (no extra fetches).
        func openProfile(_ id: String, _ name: String) -> TradeProfile {
            TradeProfileStore.shared.profile(forWorker: id)
                ?? TradeProfile.defaultForUnpublished(workerID: id, name: name)   // A8: missing → Bookends Only
        }
        for giveDay in giveDayIDs.sorted() {
            guard let myEntry = (maps[selfID] ?? [:])[giveDay],
                  let dayDate = TradeMatcher.dayDate(fromISO: giveDay) else { continue }
            var workingPairs: [(QualSwapShift, TradeProfile)] = []
            var offEntries: [RosterEntry] = []
            for (wid, m) in maps {
                guard wid != selfID, let e = m[giveDay] else { continue }
                if e.isOff { offEntries.append(e) }
                else {
                    workingPairs.append((QualSwapShift(workerID: wid, name: e.workerName, desk: e.desk,
                                                       startHour: e.startHour, quals: e.quals),
                                         openProfile(wid, e.workerName)))
                }
            }
            guard DeskRules.isQualBlocked(forDesk: myEntry.desk, candidateTakerQuals: offEntries.map(\.quals)) else { continue }
            let offTakers = offEntries.map { (id: $0.workerID, name: $0.workerName, quals: $0.quals) }
            let sols = QualSwap.solutions(giveDesk: myEntry.desk, giveStartHour: myEntry.startHour,
                                          giverID: selfID, workers: workingPairs, offTakers: offTakers)
            guard !sols.isEmpty else { continue }
            let giveQual = DeskRules.requiredQual(forDesk: myEntry.desk) ?? "D"
            // One package per off-taker B; blast candidates = bridges whose freed desk B will take.
            for (takerID, group) in Dictionary(grouping: sols, by: { $0.takerID }).sorted(by: { $0.key < $1.key }) {
                guard let bMap = maps[takerID], let bEntry = bMap[giveDay] else { continue }
                let bProfile = openProfile(takerID, bEntry.workerName)
                let willing = group.filter { sol in
                    TradeEligibility.canCover(coverDayID: giveDay, coverDay: dayDate, desk: sol.bridgeDesk,
                                              startHour: myEntry.startHour, coverMap: bMap, coverQuals: bEntry.quals,
                                              coverProfile: bProfile, options: .full).eligible
                }
                guard !willing.isEmpty else { continue }
                let candidates = willing.map {
                    QualSwapCandidate(workerID: $0.bridgeID, name: $0.bridgeName, desk: $0.bridgeDesk, qual: $0.bridgeQual)
                }
                let leg = QualSwapLegData(giveShiftDayID: giveDay, giveDesk: myEntry.desk, giveQual: giveQual,
                                          takerID: takerID, takerName: bEntry.workerName, candidates: candidates)
                let assignment = PackageAssignment(workerID: takerID, name: bEntry.workerName,
                                                   giveDayIDs: [giveDay], takeDayIDs: [])
                result.append(TradePackage(id: "qualswap-\(giveDay)-\(takerID)", methodology: .greedy,
                                           assignments: [assignment], route: nil,
                                           urgency: urgency(of: [giveDay]), qualSwap: leg))
            }
        }

        // U4 scoring: total bookends + 🔥 (mutual-intent) across BOTH sides of each package.
        // Greedy packages read the retained per-peer plans; circular approximate from route
        // metadata (exact per-leg flag is threaded in a later UI step).
        let scored = result.map { pkg -> TradePackage in
            var p = pkg
            if let route = pkg.route {
                p.fireCount    = route.tier == .matchingIntents ? route.legs.count : 0
                p.bookendTotal = route.bookendCount   // G3: real per-leg bookend count (split legs don't count)
                // Circular loop: count the days I RECEIVE that aren't a clean bookend for me.
                p.dirtyReceives = TradeRouter.routeDirtyReceives(route, selfID: selfID,
                                                                 myMap: maps[selfID] ?? [:], wantToWork: myWantToWork)
            } else {
                var fire = 0, book = 0, dirty = 0
                for a in pkg.assignments {
                    let plan = plansByPeer[a.workerID]
                    let giveByDay = Dictionary((plan?.iGive ?? []).map { ($0.dayID, $0) }, uniquingKeysWith: { x, _ in x })
                    let takeByDay = Dictionary((plan?.iTake ?? []).map { ($0.dayID, $0) }, uniquingKeysWith: { x, _ in x })
                    for d in a.giveDayIDs { if let l = giveByDay[d] { if l.bookend { book += 1 }; if l.wanted { fire += 1 } } }
                    for d in a.takeDayIDs { if let l = takeByDay[d] {
                        if l.bookend { book += 1 } else if !myWantToWork.contains(d) { dirty += 1 }   // a non-bookend island I receive
                        if l.wanted { fire += 1 }
                    } }
                }
                p.fireCount = fire; p.bookendTotal = book; p.dirtyReceives = dirty
            }
            return p
        }
        // Rank, then the shared variable score-floor + safety ceiling (same gate as every match type).
        // Step 2/3/5: real packageLogProb per package → score-order + floor + ceiling.
        let qualsDict = ctx.qualsDict
        let priors = ctx.priors   // U-PERF: built once in ctx (one responses scan, not per-leg)
        let rescored = scored.map { p -> TradePackage in
            var q = p
            q.acceptanceScore = packageQuality(for: p, selfID: selfID, maps: maps, quals: qualsDict,
                                               priors: priors, start: start,
                                               mySeeking: mySeeking, myWantToWork: myWantToWork, profilesByID: ctx.profilesByID)
            q.coverageCount = myGiveCoverage(p, selfID: selfID)
            return q
        }
        // Bookends Only (my setting): hard-exclude any package that would hand me a non-bookend island —
        // across 2-way, multi-person, AND circular. Open-to-all keeps them (ranked below clean via rankLess).
        let gated = myBookendsOnly ? rescored.filter { $0.dirtyReceives == 0 } : rescored
        return finalize(gated, lucky: lucky)
    }

    // MARK: - Intents marketplace (DISTINCT from packages — intent-for-intent, intent-first ranking)

    /// One side's give-days for an intent pairing, split into MARKED (a real trade-away intent) and
    /// PREF-ONLY (a day they'd merely accept covering). Used to assemble marketplace deals.
    struct IntentPairing: Equatable, Sendable {
        var myGiveMarked: [String]      // my marked trade-away days this peer would take
        var myGivePref: [String]        // my other days this peer would take (pref, not marked)
        var theirGiveMarked: [String]   // their marked trade-away days I would take
        var theirGivePref: [String]     // their other days I would take (pref, not marked)
    }

    /// PURE core of the Intents marketplace. Assembles the best balanced TWO-person deal that fulfils
    /// the most MARKED intents. Marketplace rule (distinct from `packages`): surface the deal if
    /// EITHER side marked ≥1 day — so a peer's marked day I'd happily take seeds a deal even when I
    /// marked no give. Marked legs are placed first so a balanced k-for-k swap maximises mutual intent.
    /// Returns the chosen give/take day IDs + the mutual-marked leg count (the intent score). nil if
    /// nothing marked on either side, or it can't balance.
    nonisolated static func assembleIntentDeal(_ p: IntentPairing) -> (gives: [String], takes: [String], mutualMarked: Int)? {
        guard !p.myGiveMarked.isEmpty || !p.theirGiveMarked.isEmpty else { return nil }   // marketplace seed
        let giveOrdered = p.myGiveMarked + p.myGivePref       // marked first → kept when we trim to balance
        let takeOrdered = p.theirGiveMarked + p.theirGivePref
        let k = min(giveOrdered.count, takeOrdered.count)
        guard k >= 1 else { return nil }
        let gives = Array(giveOrdered.prefix(k))
        let takes = Array(takeOrdered.prefix(k))
        let myMarked = Set(p.myGiveMarked), theirMarked = Set(p.theirGiveMarked)
        let mutual = gives.filter(myMarked.contains).count + takes.filter(theirMarked.contains).count
        return (gives, takes, mutual)
    }

    /// PURE, testable: the Intents ranking — INTENT-FIRST. The most mutual marked intent (`fireCount`)
    /// wins, THEN fewest people, then bookends/date/urgency. This is the marquee difference from
    /// `rankPackages` (Trade Solutions), which sorts fewest-people first.
    static func rankIntentPackages(_ packages: [TradePackage]) -> [TradePackage] {
        var seen = Set<String>()
        let deduped = packages.filter { seen.insert($0.id).inserted }
        return deduped.sorted {
            if $0.fireCount != $1.fireCount { return $0.fireCount > $1.fireCount }        // most mutual intent first
            if $0.dirtyReceives != $1.dirtyReceives { return $0.dirtyReceives < $1.dirtyReceives } // then clean (bookend) receives
            if $0.peopleCount != $1.peopleCount { return $0.peopleCount < $1.peopleCount } // then fewest people
            if $0.bookendTotal != $1.bookendTotal { return $0.bookendTotal > $1.bookendTotal }
            if $0.partnerPrior != $1.partnerPrior { return $0.partnerPrior > $1.partnerPrior } // H2: likelier-to-accept partners
            let e0 = $0.earliestDayID ?? "9999-12-31", e1 = $1.earliestDayID ?? "9999-12-31"
            if e0 != e1 { return e0 < e1 }
            if $0.urgency != $1.urgency { return $0.urgency > $1.urgency }
            return $0.id < $1.id
        }
    }

    /// The Intents feed's engine — a MARKETPLACE of intent-for-intent deals involving you, ranked
    /// intent-first. DISTINCT from `packages` (Trade Solutions): it seeds from BOTH your marked
    /// trade-away days AND peers' marked trade-away days you'd take (so a peer's marked day seeds a
    /// deal even when you marked no give), and ranks by most mutual intent. `generation` gates the
    /// heavy 3+/circular work to Lucky → Generate, exactly like `packages` (U-PERF).
    /// `mutualOnly` (default): a deal shows only when BOTH sides marked a day in it (true mutual intent).
    /// When false, one-sided deals (your marked days a peer would cover) also show.
    ///
    /// **Robot gate (B6-INTENTS):** the active-account filter (real signed-in profile) is applied ONLY in
    /// Mutual mode — there, 🔥 means both-sides-marked, so unclaimed/robot records are meaningless clutter.
    /// In **All** mode every peer is eligible (an unclaimed peer can still be a valid bookend counterparty),
    /// so All keeps showing matches even before anyone has claimed an account. See `peerEligibleForIntents`.
    nonisolated static func peerEligibleForIntents(isActiveAccount: Bool, mutualOnly: Bool) -> Bool {
        !mutualOnly || isActiveAccount
    }

    static func intentSolutions(excluding selfID: String, generation: SearchFilter = .fast,
                                lucky: Bool = false, mutualOnly: Bool = true) async -> [TradePackage] {
        let ctx = await MatchContext.build(selfID: selfID)
        let (start, end) = (ctx.start, ctx.end)
        let mySeeking = DayIntentStore.shared.seekingDayIDs
        let myWantToWork = DayIntentStore.shared.wantToWorkDayIDs   // non-bookend days I'll still accept receiving
        // Lucky one-time openness override for my side (else my saved openness).
        let myProfile = generation.myOpennessOverride.map { TradeProfileStore.shared.myProfile().withOpenness($0) }
            ?? TradeProfileStore.shared.myProfile()
        let myBookendsOnly = myProfile.opennessLevel == .bookends

        // STEP-1 snapshots: MY per-day intent sources, captured ONCE on the main actor so `dayUrgency`
        // is a pure lookup with no main-actor read inside the candidate loop (prereq for going off-main).
        let notesSnapshot = DayIntentStore.shared.notes
        let topologySnapshot = DayIntentStore.shared.topologies
        // STEP-3 snapshots: my Keep days + my relief horizon, captured on the main actor so the N-way
        // DFS (which runs off-main) reads them as pure lookups instead of `.shared`.
        let myKeepDays = DayIntentStore.shared.keepDayIDs
        let myReliefThrough = SettingsManager.shared.effectiveReliefThrough

        // These are @Sendable closures (not local funcs) so they can run inside the off-main Task.detached
        // as well as on-main — they touch only nonisolated helpers + the Sendable snapshots captured above.
        let wouldTake: @Sendable (TradeProfile, TwoWayLeg) -> Bool = { prof, leg in
            let cal = Calendar.current
            let weekday = cal.component(.weekday, from: leg.date)
            let region  = DeskRules.region(forDesk: leg.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: leg.startHour).rawValue
            return prof.wouldPickUp(onDay: leg.dayID, weekday: weekday, desk: leg.desk,
                                    shiftType: type, region: region, isBookend: leg.bookend)
        }
        let dayUrgency: @Sendable (String) -> Int = { dayID in
            let reason = notesSnapshot[dayID]?.reason?.urgency ?? 0
            switch topologySnapshot[dayID] ?? .standard {
            case .personalMilestone: return reason + 3
            case .highDemand:        return reason + 2
            case .standard:          return reason
            }
        }
        let urgency: @Sendable ([String]) -> Int = { dayIDs in dayIDs.map(dayUrgency).max() ?? 0 }

        // Candidate universe = the whole roster (unknown-profile peers included). Sourced from the
        // shared `ctx` (roster loaded once, maps + universe + priors built once).
        let maps = ctx.maps
        let rosterMeta = ctx.rosterMeta
        let profilesByID = ctx.profilesByID
        let universe = ctx.universe
        let profileFor: @Sendable (String, String) -> TradeProfile = { id, name in ctx.profile(for: id, name: name) }
        let mineEntries = ctx.mineEntries
        let priors = ctx.priors   // U-PERF: one responses scan for all prior lookups
        // STEP-1 snapshot: per-peer active-account flags (isActiveAccount reads the main-actor profile
        // store). Captured for the whole window roster so the loop's eligibility check is a pure lookup.
        let activeByID: [String: Bool] = maps.reduce(into: [:]) { $0[$1.key] = TradeProfileStore.shared.isActiveAccount($1.key) }

        // Set-contiguity: a `.bookends` party must keep CONTIGUOUS breaks across the WHOLE set of days
        // they pick up — not just each leg in isolation. @Sendable so the off-main loop can call it.
        let anchoredSet: @Sendable ([String], [String: RosterEntry]) -> Bool = { ids, map in
            let plan = Set(ids)
            return ids.allSatisfy { d in
                guard let day = TradeMatcher.dayDate(fromISO: d) else { return false }
                return TradeMatcher.isAnchored(day: day, map: map, plan: plan)
            }
        }

        var result: [TradePackage] = []

        // PERF BOUND (B6-INTENTS-CAP): "All" mode explores the WHOLE roster (Mutual skips inactive accounts
        // up front, so it's already small). Two guards keep it fast:
        //  1) Result-neutral OVERLAP PRUNE — a peer can only form a deal if our schedules cross: they're OFF
        //     on a day I work (they could take it) OR I'm OFF on a day they work (I could take theirs). With
        //     no overlap, `twoWayExplore` yields an empty plan and the deal is dropped anyway — so skipping
        //     them changes nothing but the runtime.
        //  2) A best-first HARD CAP so a pathological roster can't run unbounded. Ordered by acceptance prior
        //     (then workerID for determinism); anything past the cap is the least likely to matter, and we
        //     log the drop (no silent truncation).
        let myWorkDays = Set(mineEntries.filter { !$0.isOff }.map(\.day))
        let myOffDays  = Set(mineEntries.filter {  $0.isOff }.map(\.day))
        func schedulesCross(_ id: String) -> Bool {
            let m = maps[id] ?? [:]
            return myWorkDays.contains { m[$0]?.isOff == true }
                || myOffDays.contains  { m[$0].map { !$0.isOff } ?? false }
        }
        let relevant = universe
            .filter { schedulesCross($0.workerID) }
            .sorted {   // acceptance prior desc, then workerID asc (deterministic tiebreak)
                let a = priors[$0.workerID] ?? 0, b = priors[$1.workerID] ?? 0
                return a != b ? a > b : $0.workerID < $1.workerID
            }
        let candidates = Array(relevant.prefix(Self.intentCandidateCap))
        #if DEBUG
        if relevant.count > candidates.count {
            print("⚠️ intentSolutions: capped candidates \(relevant.count) → \(candidates.count) (intentCandidateCap)")
        }
        #endif

        // The WHOLE roster is eligible as a counterparty. The INTENT side must be someone who actually
        // marked a day (enforced by `assembleIntentDeal`'s marketplace seed) — but the OTHER side may be
        // an unprofiled peer joining via PREFERENCES (bookend-only by default, A8). Low-intent deals
        // simply score lower and fall off the top-20 cap.
        // The heavy 2-way exploration runs OFF the main actor (Task.detached over the Sendable snapshots),
        // so it never blocks the UI. Everything inside touches only pure `nonisolated` helpers + immutable
        // snapshots — no `.shared` access (the compiler proves it). (N-way still runs on main — Step 3.)
        let twoWayPkgs: [TradePackage] = await Task.detached(priority: .utility) {
            var out: [TradePackage] = []
            for cand in candidates {
                if Task.isCancelled { break }   // U-PERF: cancellable mid-scan (Cancel button / supersede)
                await Task.yield()
                // Robot gate is Mutual-only (B6-INTENTS): All shows every peer; Mutual = real accounts only.
                guard peerEligibleForIntents(isActiveAccount: activeByID[cand.workerID] ?? false,
                                             mutualOnly: mutualOnly) else { continue }
                let profile = profileFor(cand.workerID, cand.name)
                let plan = TradeMatcher.twoWayExploreCore(
                    withWorker: cand.workerID, name: cand.name,
                    windowStart: start, windowEnd: end,
                    mySeeking: mySeeking, theirSeeking: profile.seekingDayIDs,
                    myProfile: myProfile, theirProfile: profile,
                    ignoreOwnBlacklist: false,
                    myEntries: mineEntries, peerEntries: Array((maps[cand.workerID] ?? [:]).values))

                // Days each side can actually cover, split MARKED (wanted) vs PREF-only.
                let myTakeable    = plan.iGive.filter { wouldTake(profile, $0) }      // my days the peer takes
                let theirTakeable = plan.iTake.filter { wouldTake(myProfile, $0) }    // their days I take
                let pairing = IntentPairing(
                    myGiveMarked:    myTakeable.filter { $0.wanted }.map(\.dayID),
                    myGivePref:      myTakeable.filter { !$0.wanted }.map(\.dayID),
                    theirGiveMarked: theirTakeable.filter { $0.wanted }.map(\.dayID),
                    theirGivePref:   theirTakeable.filter { !$0.wanted }.map(\.dayID))
                guard let deal = assembleIntentDeal(pairing) else { continue }
                // Mutual mode (default): require a real TWO-SIDED intent — ≥1 day I marked AND ≥1 the peer did.
                if mutualOnly {
                    let iMarked    = deal.gives.contains { mySeeking.contains($0) }
                    let theyMarked = deal.takes.contains { profile.seekingDayIDs.contains($0) }
                    guard iMarked && theyMarked else { continue }
                }
                // Set-contiguity for bookend parties.
                if profile.opennessLevel == .bookends, !anchoredSet(deal.gives, maps[cand.workerID] ?? [:]) { continue }
                if myProfile.opennessLevel == .bookends, !anchoredSet(deal.takes, maps[selfID] ?? [:]) { continue }
                let takeOpts = deal.gives.count == 1 ? theirTakeable.map(\.dayID) : []
                let a = [PackageAssignment(workerID: cand.workerID, name: cand.name,
                                           giveDayIDs: deal.gives, takeDayIDs: deal.takes, takeOptions: takeOpts)]
                var pkg = TradePackage(id: "intent-\(cand.workerID)", methodology: .greedy, assignments: a,
                                       route: nil, urgency: urgency(deal.gives + deal.takes),
                                       isOptimal: deal.mutualMarked == deal.gives.count + deal.takes.count)
                pkg.fireCount = deal.mutualMarked
                pkg.partnerPrior = priors[cand.workerID] ?? 0
                let takeBookend = Dictionary(theirTakeable.map { ($0.dayID, $0.bookend) }, uniquingKeysWith: { x, _ in x })
                pkg.dirtyReceives = deal.takes.filter { !(takeBookend[$0] ?? false) && !myWantToWork.contains($0) }.count
                out.append(pkg)
            }
            return out
        }.value
        if Task.isCancelled { return [] }
        result.append(contentsOf: twoWayPkgs)

        // Lucky (gated): circular loops that need only ≥1 marked-intent leg (the marked seed
        // guarantees it). Other participants join via PREFERENCES (`allowPrefMiddles`). fireCount =
        // the REAL marked-leg count, so all-intent loops rank highest without hard-coding it.
        if generation.maxPeople >= 3, generation.engine != .minCost {
            let giveShifts = await selfSeekingShifts(myID: selfID, start: start, end: end)
            // OFF-MAIN (Step 3): the circular DFS is the launch-freeze culprit (maxRoutes:500, recursive).
            // Run it detached over the Sendable snapshots; the ≤10-package build below stays on main (cheap).
            let loops: [NWayRoute] = await Task.detached(priority: .utility) {
                nWayRoutes(seedShifts: giveShifts, maxDepth: generation.maxPeople,
                           excluding: selfID, allowPrefMiddles: true,
                           maxRoutes: 500,        // high safety backstop; the floor curates
                           windowStart: start, maps: maps,   // U-PERF: reuse ctx's window
                           myProfile: myProfile, profilesByID: profilesByID,
                           myKeepDays: myKeepDays, mySeeking: mySeeking,
                           myReliefThrough: myReliefThrough,
                           notesByDay: notesSnapshot, topologyByDay: topologySnapshot)
            }.value
            if Task.isCancelled { return [] }
            func legMarked(_ leg: NWayLeg) -> Bool {
                leg.fromID == selfID ? mySeeking.contains(leg.dayID)
                    : (profilesByID[leg.fromID]?.seekingDayIDs.contains(leg.dayID) ?? false)
            }
            for loop in loops.prefix(10) where loop.legs.contains(where: legMarked) {
                var gv: [String: [String]] = [:]; var tk: [String: [String]] = [:]
                for leg in loop.legs {
                    if leg.fromID == selfID { gv[leg.toID, default: []].append(leg.dayID) }
                    if leg.toID == selfID   { tk[leg.fromID, default: []].append(leg.dayID) }
                }
                let participants = Set(gv.keys).union(tk.keys)
                // Robot gate is Mutual-only (B6-INTENTS): in All mode unclaimed peers may join a loop.
                guard participants.allSatisfy({
                    peerEligibleForIntents(isActiveAccount: activeByID[$0] ?? false,
                                           mutualOnly: mutualOnly)
                }) else { continue }
                let a = participants.map { pid in
                    PackageAssignment(workerID: pid, name: participantName(pid),
                                      giveDayIDs: gv[pid] ?? [], takeDayIDs: tk[pid] ?? [])
                }
                var pkg = TradePackage(id: "intent-circular-\(loop.id)", methodology: .circular,
                                       assignments: a, route: loop, urgency: urgency(a.flatMap(\.giveDayIDs)))
                pkg.fireCount = loop.legs.filter(legMarked).count   // real mutual-intent legs (not assumed)
                pkg.bookendTotal = loop.bookendCount
                pkg.dirtyReceives = TradeRouter.routeDirtyReceives(loop, selfID: selfID,
                                                                   myMap: maps[selfID] ?? [:], wantToWork: myWantToWork)
                // H2: average the other participants' acceptance priors.
                let others = participants
                if !others.isEmpty {
                    pkg.partnerPrior = others.map { priors[$0] ?? 0 }.reduce(0, +) / Double(others.count)
                }
                result.append(pkg)
            }
        }

        // Step 2/3/5: compute the REAL packageLogProb per package, then score-order + floor + ceiling.
        let qualsDict = rosterMeta.mapValues { $0.quals }
        let scored = result.map { p -> TradePackage in
            var q = p
            q.acceptanceScore = packageQuality(for: p, selfID: selfID, maps: maps, quals: qualsDict,
                                               priors: priors, start: start,
                                               mySeeking: mySeeking, myWantToWork: myWantToWork, profilesByID: profilesByID)
            q.coverageCount = myGiveCoverage(p, selfID: selfID)
            return q
        }
        // Bookends Only: hard-exclude any deal/loop that hands me a non-bookend island (open-to-all keeps
        // them but rankLess demotes them below all-clean). Consistent with Trade Solutions.
        let gated = myBookendsOnly ? scored.filter { $0.dirtyReceives == 0 } : scored
        return finalize(gated, lucky: lucky)
    }
    /// Safety ceiling — neither feed ever shows more than this, even if the floor passes a huge set.
    static let intentResultCap = 60
    /// Worst-case bound on how many peers `intentSolutions` explores (after the result-neutral overlap
    /// prune), best-first by acceptance prior. Well above a typical relevant set, so it only bites huge
    /// rosters. (B6-INTENTS-CAP.)
    static let intentCandidateCap = 300

    // MARK: - Real per-leg scoring (Step 2: packageLogProb from live data)

    /// Grade one leg from live data. The RECEIVER picks up `day` (on the giver's `desk`). Pulls the
    /// real intent (want-to-take / want-to-trade), bookend (anchored for the receiver), soonness, qual
    /// friction, and the receiver's tiny acceptance prior. Pure-ish (reads the shared stores).
    nonisolated private static func legFeatures(giverID: String, receiverID: String, day: String, desk: String,
                            receiverQuals: [String], maps: [String: DayMap], priors: [String: Double],
                            selfID: String, start: Date,
                            mySeeking: Set<String>, myWantToWork: Set<String>,
                            profilesByID: [String: TradeProfile]) -> LegFeatures {
        // Snapshots instead of `.shared` reads → pure, runs off-main.
        func seeking(_ id: String) -> Set<String> {
            id == selfID ? mySeeking : (profilesByID[id]?.seekingDayIDs ?? [])
        }
        func wantWork(_ id: String) -> Set<String> {
            id == selfID ? myWantToWork : (profilesByID[id]?.wantToWorkDayIDs ?? [])
        }
        let bookend: Bool = {
            guard let d = TradeMatcher.dayDate(fromISO: day), let m = maps[receiverID] else { return false }
            return TradeMatcher.isAnchored(day: d, map: m, plan: [day])
        }()
        let daysUntil = max(0, Int((TradeMatcher.dayDate(fromISO: day)?.timeIntervalSince(start) ?? 0) / 86400))
        return LegFeatures(
            wantToTake: wantWork(receiverID).contains(day),       // receiver wants to work it
            wantToTrade: seeking(giverID).contains(day),          // giver marked it trade-away
            bookend: bookend,
            timeValue: exp(-0.05 * Double(daysUntil)),
            needsQualBridge: !DeskRules.qualified(quals: receiverQuals, forDesk: desk),
            personPrior: priors[receiverID] ?? 0)   // O(1) lookup; absent → neutral (U-PERF)
    }

    /// The package's average per-leg acceptance QUALITY (0…1): build per-leg features for every handoff
    /// and take the geometric mean, with a per-PERSON penalty (not per-leg) so covering more days with
    /// one clean person isn't punished. Circular reads `route.legs`; a reciprocal package synthesizes
    /// legs (you→them for gives, them→you for takes).
    nonisolated private static func packageQuality(for pkg: TradePackage, selfID: String,
                               maps: [String: DayMap], quals: [String: [String]],
                               priors: [String: Double], start: Date,
                               mySeeking: Set<String>, myWantToWork: Set<String>,
                               profilesByID: [String: TradeProfile]) -> Double {
        var legs: [(g: String, r: String, day: String, desk: String)] = []
        if let route = pkg.route {
            for l in route.legs { legs.append((l.fromID, l.toID, l.dayID, l.desk)) }
        } else {
            for a in pkg.assignments {
                for d in a.giveDayIDs { if let e = maps[selfID]?[d] { legs.append((selfID, a.workerID, d, e.desk)) } }
                for d in a.takeDayIDs { if let e = maps[a.workerID]?[d] { legs.append((a.workerID, selfID, d, e.desk)) } }
            }
        }
        guard !legs.isEmpty else { return 0 }
        let feats = legs.map { legFeatures(giverID: $0.g, receiverID: $0.r, day: $0.day, desk: $0.desk,
                                           receiverQuals: quals[$0.r] ?? [], maps: maps, priors: priors,
                                           selfID: selfID, start: start,
                                           mySeeking: mySeeking, myWantToWork: myWantToWork, profilesByID: profilesByID) }
        return TradeScore.packageQuality(feats, people: pkg.peopleCount)
    }

    /// How many of YOUR give-days this package covers (distinct days you hand off) — the PRIMARY ranking key.
    nonisolated private static func myGiveCoverage(_ pkg: TradePackage, selfID: String) -> Int {
        if let route = pkg.route { return Set(route.legs.filter { $0.fromID == selfID }.map(\.dayID)).count }
        return Set(pkg.assignments.flatMap(\.giveDayIDs)).count
    }

    // MARK: - Unified gate (per-leg quality floor + coverage-first ranking)
    static let floorNormalProb = 0.32   // normal feed: keep packages whose AVERAGE leg quality ≥ 0.32
    static let floorLuckyProb  = 0.07   // Lucky: wider, allow weaker matches
    static let emptyFallbackCount = 5   // if nothing clears the floor, still show the top few by quality

    /// Coverage-first ranking (what the user asked for): most of YOUR days covered → fewest people →
    /// bookends → acceptance quality → soonest → id. `acceptanceScore` is the AVERAGE leg quality (0…1),
    /// so a clean full-cover isn't buried for having many legs.
    /// PURE, testable: the reciprocal days I'll RECEIVE from a peer, in preference order (bookends — days
    /// that attach to my existing work — first, then soonest). A "clean" receive is a bookend or a day I
    /// explicitly marked want-to-work. When `bookendsOnly` (my openness = Bookends Only) the random
    /// mid-week islands are DROPPED entirely; otherwise (open-to-all) they're kept but sorted last, and a
    /// package built from them is ranked below all-clean ones (see `dirtyReceives`).
    static func cleanReceiveLegs(_ legs: [TwoWayLeg], wantToWork: Set<String>, bookendsOnly: Bool) -> [TwoWayLeg] {
        let base = bookendsOnly ? legs.filter { $0.bookend || wantToWork.contains($0.dayID) } : legs
        return base.sorted { ($0.bookend ? 0 : 1, $0.date) < ($1.bookend ? 0 : 1, $1.date) }
    }

    /// Is a received day "clean" for me — a bookend, or one I explicitly marked want-to-work?
    static func isCleanReceive(_ leg: TwoWayLeg, wantToWork: Set<String>) -> Bool {
        leg.bookend || wantToWork.contains(leg.dayID)
    }

    /// How many days a circular ROUTE hands ME that aren't clean — i.e. I receive them (leg points to me),
    /// I didn't mark want-to-work, and the day doesn't anchor to my existing work (not a bookend for me).
    /// `NWayLeg` carries no bookend flag, so it's derived from my own schedule via `isAnchored`.
    static func routeDirtyReceives(_ route: NWayRoute, selfID: String,
                                   myMap: [String: RosterEntry], wantToWork: Set<String>) -> Int {
        let myReceived = Set(route.legs.filter { $0.toID == selfID }.map(\.dayID))
        return route.legs.filter { leg in
            guard leg.toID == selfID, !wantToWork.contains(leg.dayID),
                  let d = TradeMatcher.dayDate(fromISO: leg.dayID) else { return false }
            return !TradeMatcher.isAnchored(day: d, map: myMap, plan: myReceived)
        }.count
    }

    static func rankLess(_ a: TradePackage, _ b: TradePackage) -> Bool {
        // Bookends ranked higher even when open-to-all: any package that hands YOU a non-bookend island
        // sorts below every all-clean package, regardless of coverage. (User: rank bookends significantly
        // higher; only Bookends-Only mode excludes the island outright.)
        if a.dirtyReceives != b.dirtyReceives { return a.dirtyReceives < b.dirtyReceives }
        if a.coverageCount != b.coverageCount { return a.coverageCount > b.coverageCount }   // most days first
        if a.peopleCount != b.peopleCount { return a.peopleCount < b.peopleCount }           // fewest people
        if a.bookendTotal != b.bookendTotal { return a.bookendTotal > b.bookendTotal }       // cleaner (bookends)
        if a.acceptanceScore != b.acceptanceScore { return a.acceptanceScore > b.acceptanceScore } // likelier
        let e0 = a.earliestDayID ?? "9999-12-31", e1 = b.earliestDayID ?? "9999-12-31"
        if e0 != e1 { return e0 < e1 }
        return a.id < b.id
    }

    /// Drop trades whose AVERAGE leg quality is below the floor (never a full-cover just for having many
    /// legs), keep a top-N fallback if the floor empties it, rank coverage-first, then a safety ceiling.
    nonisolated static func finalize(_ pkgs: [TradePackage], lucky: Bool) -> [TradePackage] {
        let floor = lucky ? floorLuckyProb : floorNormalProb
        // Qual-swap packages carry a `needsQualBridge` scoring penalty that would sink them below the floor,
        // so they'd never surface. Exempt them — they still sort LAST (rankLess `needsQualSwap`) and the
        // feed's "No Qual Swap" filter can hide them. (D6.)
        let passed = pkgs.filter { $0.acceptanceScore >= floor || $0.needsQualSwap }
        let base = passed.isEmpty
            ? Array(pkgs.sorted { $0.acceptanceScore > $1.acceptanceScore }.prefix(emptyFallbackCount))
            : passed
        return Array(base.sorted(by: rankLess).prefix(intentResultCap))
    }

    /// U4 priority tier (lower = higher priority): 0 = 🔥+bookends, 1 = 🔥-only, 2 = bookends-only.
    static func packageTier(_ p: TradePackage) -> Int {
        if p.fireCount > 0 { return p.bookendTotal > 0 ? 0 : 1 }
        return 2
    }

    /// PURE, testable (A5 + U4): dedupe by id; drop bookends-only packages below the **top two
    /// bands** (keep `max` and `max−1`, hide the clutter); then sort **fewest people first**
    /// (the N groups), then by tier (🔥+bookends → 🔥 → bookends-only), then 🔥 count, then total
    /// bookends (more is more optimal even when open-to-all), then urgency, then greedy ahead of circular.
    static func rankPackages(_ packages: [TradePackage]) -> [TradePackage] {
        var seen = Set<String>()
        let deduped = packages.filter { seen.insert($0.id).inserted }
        // Bookends-only tier (no 🔥) is capped to the top two bands. 🔥 packages AND qual-swap
        // packages are EXEMPT — a qual-swap solution must never be hidden by a low bookend count.
        let capped = deduped.filter { $0.fireCount == 0 && $0.qualSwap == nil }
        let exempt = deduped.filter { $0.fireCount > 0 || $0.qualSwap != nil }
        let keptCapped: [TradePackage]
        if let maxBO = capped.map(\.bookendTotal).max() {
            keptCapped = capped.filter { $0.bookendTotal >= maxBO - 1 }
        } else {
            keptCapped = capped
        }
        return (exempt + keptCapped).sorted {
            // Clean (bookend) receives ranked higher even when open-to-all — a package that hands YOU an
            // island sorts below every all-clean one.
            if $0.dirtyReceives != $1.dirtyReceives { return $0.dirtyReceives < $1.dirtyReceives }
            if $0.peopleCount != $1.peopleCount { return $0.peopleCount < $1.peopleCount }   // N groups
            if $0.needsQualSwap != $1.needsQualSwap { return !$0.needsQualSwap }             // D5: clean before qual, same N
            let t0 = packageTier($0), t1 = packageTier($1)
            if t0 != t1 { return t0 < t1 }
            if $0.fireCount != $1.fireCount { return $0.fireCount > $1.fireCount }
            if $0.bookendTotal != $1.bookendTotal { return $0.bookendTotal > $1.bookendTotal }
            // #4b: all else equal, the CLOSER (earlier) trade date sorts first.
            let e0 = $0.earliestDayID ?? "9999-12-31", e1 = $1.earliestDayID ?? "9999-12-31"
            if e0 != e1 { return e0 < e1 }
            if $0.urgency != $1.urgency { return $0.urgency > $1.urgency }
            if ($0.methodology == .greedy) != ($1.methodology == .greedy) { return $0.methodology == .greedy }
            return $0.id < $1.id
        }
    }

    /// B1: the BRIDGE-FIRST qual-swap finder (the green double-arrow button). For each selected international
    /// give-day it lists the **C bridges** — dispatchers WORKING that day who can slide onto my give-desk
    /// (any desk, not just domestic), favorability-ranked (their qual-swap preference), unfavorable ones
    /// flagged not dropped. One package per day carrying the bridges as `candidates`; there's no taker yet.
    /// Selecting + broadcasting sends a standing bridge request that LINKS into a normal A→B trade later
    /// (same give-day) via `TradeMerge`. (D6.)
    static func qualSwapOptions(forGiveShifts giveShifts: [Shift], excluding selfID: String) async -> [TradePackage] {
        let intlDays = giveShifts.filter { !$0.isOff && DeskRules.hasQualGatedSelection(desks: [$0.desk]) }
        guard !intlDays.isEmpty else { return [] }
        var result: [TradePackage] = []
        for shift in intlDays {
            let bridges = await TradeMatcher.qualSwapBridges(
                giveDayID: shift.id, giveDesk: shift.desk, giveStartHour: shift.startHour,
                excludeIDs: [selfID])   // bridge-first: no taker → lists every working bridge, favorability-ranked
            guard !bridges.isEmpty else { continue }
            let giveQual = DeskRules.requiredQual(forDesk: shift.desk) ?? "D"
            // takerID empty = unbound; the taker is supplied when this links into an A→B trade.
            let leg = QualSwapLegData(giveShiftDayID: shift.id, giveDesk: shift.desk, giveQual: giveQual,
                                      takerID: "", takerName: "", candidates: bridges)
            result.append(TradePackage(id: "qualbridge-\(shift.id)", methodology: .greedy,
                                       assignments: [], route: nil, urgency: 0, qualSwap: leg))
        }
        return result
    }

    // MARK: N-way circular routing

    /// A1 best-first: order the give-day seeds so the most promising are explored FIRST — under the
    /// route cap, the best loops surface instead of whatever the dictionary happened to yield first.
    /// `score` folds urgency + the TradeScore acceptance estimate (see `seedScore`); higher seeds
    /// first, ties broken by sooner ISO day (give-day IDs are "yyyy-MM-dd" → chronological). PURE.
    nonisolated static func bestFirstSeeds(_ seeds: [(dayID: String, score: Double)]) -> [String] {
        seeds.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.dayID < b.dayID
        }.map(\.dayID)
    }

    /// A1: a give-day's seed promise = urgency (dominant) + the TradeScore acceptance estimate of a
    /// representative leg (so soonness + qual-bridge friction refine within an urgency tier). The
    /// receiver is unknown at seed time, so only the giver-side/day-level features are used.
    nonisolated static func seedScore(urgency: Int, daysUntil: Int, qualGatedDesk: Bool) -> Double {
        let timeValue = exp(-0.05 * Double(max(0, daysUntil)))   // sooner → higher, in (0,1]
        let f = LegFeatures(wantToTake: false, wantToTrade: true, bookend: false,
                            timeValue: timeValue, needsQualBridge: qualGatedDesk)
        return Double(urgency) + TradeScore.legProb(f)   // urgency dominates; legProb refines ties
    }

    /// Resolves 3- and 4-person circular swap loops seeded from the user's
    /// give-away days. A→B→C→A: each person gives one shift and receives one, so
    /// everyone nets the same hours. Bounded by `maxDepth` participants.
    /// `allowPrefMiddles` (used by the Intents marketplace) lets non-seed participants join a loop on
    /// their PREFERENCES (availability/bookend) rather than requiring each to have marked the day. The
    /// loop still starts from a marked seed (≥1 intent leg); ranking by the real marked-leg count then
    /// floats all-intent loops to the top — without hard-coding an all-marked requirement.
    /// `maxRoutes` is the hard mid-search cap: the BASELINE search stops at 60; "I'm Feeling Lucky"
    /// raises it to 100 (the user opted in + narrowed the criteria, so it may take its time). With
    /// best-first seeding, the routes kept under the cap are the most promising ones. (A1.)
    // PURE / `nonisolated`: runs off the main actor over preloaded maps + Sendable snapshots (no `.shared`
    // access). Callers snapshot the main-actor state (`myProfile`, peer profiles, my keep/seeking days,
    // relief horizon, day notes/topologies) on the main actor and pass them in.
    nonisolated private static func nWayRoutes(seedShifts: [Shift], maxDepth: Int = 4,
                           excluding selfID: String,
                           constraints: MatchConstraints = .standard,
                           allowPrefMiddles: Bool = false,
                           maxRoutes: Int = 60,
                           windowStart: Date,
                           maps: [String: DayMap],
                           myProfile: TradeProfile,
                           profilesByID: [String: TradeProfile],
                           myKeepDays: Set<String>,
                           mySeeking: Set<String>,
                           myReliefThrough: Date?,
                           notesByDay: [String: DayNote],
                           topologyByDay: [String: DayTopology]) -> [NWayRoute] {
        let giveDays = seedShifts.filter { !$0.isOff }
        guard !giveDays.isEmpty else { return [] }
        let start = windowStart
        guard let selfMap = maps[selfID] else { return [] }

        var routes: [NWayRoute] = []
        var seen = Set<String>()

        // Whether `coverer` can legally cover `giver`'s shift on `dayID`. Delegates to the
        // unified predicate (U1): hard physical gates + weekly cap + the coverer's own rules
        // (`.full`). Bookend (no-split) stays a per-person preference owned by `wouldPickUp`.
        func canCover(covererID: String, covererMap: DayMap, giver entry: RosterEntry) -> Bool {
            guard let cover = covererMap[entry.day],
                  let day = TradeMatcher.dayDate(fromISO: entry.day) else { return false }
            let profile: TradeProfile? = covererID == selfID ? myProfile : profilesByID[covererID]
            guard let profile else { return false }
            return TradeEligibility.canCover(
                coverDayID: entry.day, coverDay: day, desk: entry.desk, startHour: entry.startHour,
                coverMap: covererMap, coverQuals: cover.quals, coverProfile: profile, options: .full).eligible
        }

        // A giver never gives away a day they marked KEEP (mustWork) — hard
        // disqualifier on the give side (SPEC S-ENG-9/10).
        func keepDays(_ workerID: String) -> Set<String> {
            workerID == selfID ? myKeepDays
                               : (profilesByID[workerID]?.keepDayIDs ?? [])
        }

        // A relief dispatcher's shift past their horizon isn't real → never give it.
        func reliefThrough(_ workerID: String) -> Date? {
            workerID == selfID ? myReliefThrough
                               : profilesByID[workerID]?.reliefThrough
        }
        func giveBlocked(_ workerID: String, _ entry: RosterEntry) -> Bool {
            guard let day = TradeMatcher.dayDate(fromISO: entry.day) else { return true }
            return TradeProfile.isPastRelief(day: day, reliefThrough: reliefThrough(workerID))
        }
        // A1 seed/expansion promise (hoisted so the DFS can order EVERY node best-first, not just seeds).
        func seedUrgency(_ dayID: String) -> Int {
            let reason = notesByDay[dayID]?.reason?.urgency ?? 0
            switch topologyByDay[dayID] ?? .standard {
            case .personalMilestone: return reason + 3
            case .highDemand:        return reason + 2
            case .standard:          return reason
            }
        }
        func daysUntil(_ dayID: String) -> Int {
            guard let d = TradeMatcher.dayDate(fromISO: dayID) else { return 0 }
            return max(0, Int(d.timeIntervalSince(start) / 86400))
        }
        /// Promise of `current` giving `entry` next — soonness + qual friction (+ urgency for self's
        /// own days). Used to order the DFS expansion so the cap keeps the best COMPLETE paths.
        func givePromise(_ entry: RosterEntry, by giverID: String) -> Double {
            seedScore(urgency: giverID == selfID ? seedUrgency(entry.day) : 0,
                      daysUntil: daysUntil(entry.day),
                      qualGatedDesk: DeskRules.hasQualGatedSelection(desks: [entry.desk]))
        }
        // U-PERF (B4-10): the giver's working days, best-first. `givePromise` is computed ONCE per entry
        // here instead of ~O(n log n) times inside a sort comparator at every DFS node. Result-neutral —
        // same entries, same keys, same deterministic sort → identical order (see B4-10 reasoning).
        func promiseSorted(_ map: DayMap, by giverID: String) -> [RosterEntry] {
            map.values.filter { !$0.isOff }
                .map { (entry: $0, p: givePromise($0, by: giverID)) }
                .sorted { $0.p > $1.p }
                .map(\.entry)
        }

        // DFS: path of leg tuples. Each step, the current node gives one of THEIR
        // working days to a next node who can cover it. Close when the last node's
        // gift is covered by SELF. A1: at EVERY node, the give-day candidates are tried best-first.
        func extend(path: [NWayLeg], visited: Set<String>, current: String, currentMap: DayMap) {
            if Task.isCancelled { return }                   // A1: cooperatively cancellable (Lucky re-filter)
            if routes.count > maxRoutes { return }           // hard mid-search cap (60 baseline / 100 Lucky)
            let depth = visited.count

            // Try to close the loop back to self — needs ≥3 participants total (#4). `depth` is
            // visited.count (self + others), so `>= 3` = self + ≥2 others; a 2-cycle is a 2-way swap,
            // handled by twoWayExplore/packages, never emitted here as a fake "circular."
            if depth >= 3 {
                for entry in promiseSorted(currentMap, by: current) {   // A1: best-first (B4-10: precomputed)
                    guard entry.day >= TradeMatcher.isoDay(start) else { continue }
                    guard !keepDays(current).contains(entry.day) else { continue }   // never give a Keep day
                    guard !giveBlocked(current, entry) else { continue }             // relief: not a real shift
                    // current gives `entry`; self must cover it.
                    if canCover(covererID: selfID, covererMap: selfMap, giver: entry) {
                        let closing = NWayLeg(fromID: current, toID: selfID, dayID: entry.day,
                                              desk: entry.desk, startHour: entry.startHour)
                        let legs = path + [closing]
                        let participants = [selfID] + legs.dropLast().map(\.toID)
                        // G3: count legs that are a bookend for their RECEIVER (no split). Drives the
                        // package's bookendTotal so split-heavy loops rank below clean ones.
                        let bookendCount = legs.filter { leg in
                            guard let d = TradeMatcher.dayDate(fromISO: leg.dayID), let m = maps[leg.toID] else { return false }
                            return TradeMatcher.isAnchored(day: d, map: m, plan: [leg.dayID])
                        }.count
                        let route = NWayRoute(
                            participants: participants, legs: legs,
                            tier: .matchingIntents,
                            score: Double(participants.count) + topologyWeight(of: legs, selfID: selfID, topologyByDay: topologyByDay),
                            usesBookends: constraints.enforceChaining,
                            bookendCount: bookendCount)
                        if seen.insert(route.id).inserted { routes.append(route) }
                        break
                    }
                }
            }
            guard depth < maxDepth else { return }

            // Otherwise, current gives one of their working days to a fresh node — A1: best-first.
            for entry in promiseSorted(currentMap, by: current) {   // B4-10: givePromise precomputed once/entry
                if keepDays(current).contains(entry.day) { continue }   // never give a Keep day
                if giveBlocked(current, entry) { continue }             // relief: not a real shift
                // Prefer days the current giver actually wants to give (intent). The Intents engine
                // (`allowPrefMiddles`) lets non-seed participants join via preferences instead — the
                // marked seed still guarantees ≥1 intent leg, and ranking rewards more marked legs.
                let wantsGive: Bool = current == selfID
                    ? mySeeking.contains(entry.day)
                    : (profilesByID[current]?.seekingDayIDs.contains(entry.day) ?? false)
                if constraints.enforceChaining && !allowPrefMiddles && !wantsGive { continue }

                for (nextID, nextMap) in maps.sorted(by: { $0.key < $1.key }) where !visited.contains(nextID) && nextID != selfID {
                    guard canCover(covererID: nextID, covererMap: nextMap, giver: entry) else { continue }
                    let leg = NWayLeg(fromID: current, toID: nextID, dayID: entry.day,
                                      desk: entry.desk, startHour: entry.startHour)
                    extend(path: path + [leg], visited: visited.union([nextID]),
                           current: nextID, currentMap: nextMap)
                }
            }
        }

        // Seed: self gives each seeking day to a first coverer. High-value dates
        // (high-demand / personal milestone) are protected from auto give-away
        // unless What If? mode is on. A1: explore the most URGENT/soonest seeds FIRST so the best
        // loops are found before the route cap bites. (seedUrgency/daysUntil hoisted above extend.)
        let seedOrder = bestFirstSeeds(giveDays.map { s in
            (dayID: s.id, score: seedScore(urgency: seedUrgency(s.id), daysUntil: daysUntil(s.id),
                                           qualGatedDesk: DeskRules.hasQualGatedSelection(desks: [s.desk])))
        })
        let orderedGiveDays = seedOrder.compactMap { id in giveDays.first { $0.id == id } }
        for s in orderedGiveDays {
            if Task.isCancelled { break }   // A1: bail the seed loop too when cancelled
            if constraints.enforceTopology, (topologyByDay[s.id] ?? .standard) != .standard { continue }
            guard let myEntry = selfMap[s.id] else { continue }
            if giveBlocked(selfID, myEntry) { continue }   // relief: my own post-horizon shift isn't real
            for (nextID, nextMap) in maps.sorted(by: { $0.key < $1.key }) where nextID != selfID {
                guard canCover(covererID: nextID, covererMap: nextMap, giver: myEntry) else { continue }
                let leg = NWayLeg(fromID: selfID, toID: nextID, dayID: myEntry.day,
                                  desk: myEntry.desk, startHour: myEntry.startHour)
                extend(path: [leg], visited: [selfID, nextID], current: nextID, currentMap: nextMap)
            }
        }
        return routes
    }

    // MARK: Helpers

    /// Score bonus for resolving higher-gravity dates (weight − 1 per self give-leg;
    /// standard days add nothing).
    nonisolated private static func topologyWeight(of legs: [NWayLeg], selfID: String,
                                                   topologyByDay: [String: DayTopology]) -> Double {
        legs.filter { $0.fromID == selfID }
            .reduce(0) { $0 + (topologyByDay[$1.dayID] ?? .standard).weight - 1 }
    }

    /// The user's working days they're actively seeking to give away, as `Shift`s.
    private static func selfSeekingShifts(myID: String, start: Date, end: Date) async -> [Shift] {
        let seeking = DayIntentStore.shared.seekingDayIDs
        guard !seeking.isEmpty else { return [] }
        let mine = await RosterStore.shared.schedule(forWorker: myID)
        return mine.compactMap { e in
            guard !e.isOff, seeking.contains(e.day), let date = TradeMatcher.dayDate(fromISO: e.day) else { return nil }
            return Shift(id: e.day, date: date,
                         startHour: e.startHour, endHour: (e.startHour + 9) % 24,
                         role: .dispatcher, desk: e.desk, leaveCode: nil, isOff: false)
        }
    }

}

```

### Appendix E — TradeMatcher.swift (eligibility, DeskRules, TradeTiming, twoWayExplore, qual-swap — full)

```swift
// TradeMatcher.swift
// Trade-matching engine over the SwiftData roster.
//
// Tier 1 — "who can cover my shift": dispatchers who are OFF on the date, are
// QUALIFIED for the desk, and have the mandatory 8-hour rest vs their own
// adjacent shifts. (Mutual swaps build on this next.)

import Foundation

// MARK: - Trade openness

/// How open a dispatcher is to trades — drives which off days they offer.
enum TradeOpenness: String, CaseIterable, Sendable {
    case none     // not accepting any trades — no availability at all
    case bookends // available only on bookend days (edge of a 2+-day off stretch)
    case all      // available on every eligible off day (still respects blacklist)

    var label: String {
        switch self {
        case .none:     return "Not accepting trades"
        case .bookends: return "Open to bookend trades"
        case .all:      return "Open to all trades"
        }
    }

    var symbol: String {
        switch self {
        case .none:     return "nosign"
        case .bookends: return "book"
        case .all:      return "checkmark.seal.fill"
        }
    }
}

/// A temporary openness change for a specific date range that overrides the base
/// openness while it exists. E.g. base "Bookends", but "Open to all" for Jul 1–10.
/// Inclusive ISO day bounds; string compare works for "yyyy-MM-dd".
struct OpennessOverride: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var startDay: String          // ISO "yyyy-MM-dd"
    var endDay: String            // ISO inclusive
    var opennessRaw: String

    var openness: TradeOpenness { TradeOpenness(rawValue: opennessRaw) ?? .all }
    func covers(_ dayID: String) -> Bool { dayID >= startDay && dayID <= endDay }
}

// MARK: - Desk → region / qualification rules

enum DeskRegion: String, Sendable, CaseIterable {
    case domestic   = "Domestic"
    case european   = "European"
    case latin      = "Latin America"
    case pacific    = "Pacific"
    case coordinator = "Coordinator"
}

nonisolated enum DeskRules {

    /// Region a desk belongs to (line-dispatcher desk numbers per the user; can
    /// change). Non-numeric desks (A#, C#, OJT, RC…) are coordinator/training.
    static func region(forDesk desk: String) -> DeskRegion {
        if let n = Int(desk.trimmingCharacters(in: .whitespaces)) {
            switch n {
            case 46, 47, 93...98:   return .domestic        // explicit domestic desks
            case 48...58:           return .european
            case 60...63, 72...83:  return .latin
            case 64...68:           return .pacific
            default:                return .domestic        // 1–45, 59, 69–71, 84–92, 99+
            }
        }
        return .coordinator
    }

    /// Qualification code a desk requires, or nil if no special gate.
    static func requiredQual(forDesk desk: String) -> String? {
        let d = desk.uppercased().trimmingCharacters(in: .whitespaces)
        if Int(d) != nil {
            switch region(forDesk: d) {
            case .european: return "E"
            case .latin:    return "L"
            case .pacific:  return "P"
            case .domestic: return "D"      // every dispatcher holds D
            case .coordinator: return nil
            }
        }
        if d.hasPrefix("RC") { return nil }                 // route check
        if d.hasPrefix("A")  { return "A" }                 // ATC coordinator
        if d.hasPrefix("C") || d.hasPrefix("I") { return "O" } // ops coordinator
        if d.hasPrefix("R")  { return "R" }                 // regional coordinator
        if d.hasPrefix("S")  { return "S" }                 // chief dispatcher
        return nil                                          // OJT, TR, etc.
    }

    /// Whether a worker holding `quals` may work `desk`.
    static func qualified(quals: [String], forDesk desk: String) -> Bool {
        guard let required = requiredQual(forDesk: desk) else { return true }
        return quals.contains(required)
    }

    /// Whether a worker holding `quals` can work ANY desk in `region`. Drives graying-out regions the user
    /// isn't qualified for in Trade Settings. Domestic = every dispatcher (D); Coordinator = holding any
    /// coordinator qual (A/O/R/S). PURE/testable.
    static func isQualified(quals: [String], forRegion region: DeskRegion) -> Bool {
        switch region {
        case .domestic:    return true
        case .european:    return quals.contains("E")
        case .latin:       return quals.contains("L")
        case .pacific:     return quals.contains("P")
        case .coordinator: return quals.contains { ["A", "O", "R", "S"].contains($0) }
        }
    }

    /// B1: does the selection include a qual-gated (international) desk? "D" is universal (every
    /// dispatcher holds it), so only a NON-D required qual counts. Drives the "Qual Swap" button
    /// (gray → glowing green) — a give-day on such a desk may need a bridge.
    static func hasQualGatedSelection(desks: [String]) -> Bool {
        desks.contains { let r = requiredQual(forDesk: $0); return r != nil && r != "D" }
    }

    /// SINGLE SOURCE OF TRUTH: does giving `desk` to a taker holding `takerQuals`
    /// require a qual swap? True exactly when the taker isn't qualified for the desk.
    /// Every matcher path (trade search, intents, routes) calls this — not its own copy.
    static func qualSwapNeeded(forDesk desk: String, takerQuals: [String]) -> Bool {
        !qualified(quals: takerQuals, forDesk: desk)
    }

    /// Q1: is giving `desk` BLOCKED by qualification — i.e. NONE of the candidate takers
    /// (each a list of quals) is qualified for it? When true, a direct trade is impossible
    /// and only a qual swap (bridge) can unblock it. False if any taker is qualified, or if
    /// there are no takers (that's a coverage gap, not a qual block).
    static func isQualBlocked(forDesk desk: String, candidateTakerQuals: [[String]]) -> Bool {
        guard !candidateTakerQuals.isEmpty else { return false }
        return !candidateTakerQuals.contains { qualified(quals: $0, forDesk: desk) }
    }

    // MARK: Qual-swap preference (Q4)

    /// Preference VALUE of a qual for a person — HIGHER is more preferred.
    /// `0` = blacklisted. A qual ABSENT from the map (or a no-gate desk's nil qual, or a
    /// nil map) = no preference = fully open = the highest value (`Int.max`).
    static func qualValue(_ qual: String?, values: [String: Int]?) -> Int {
        guard let q = qual else { return Int.max }    // no-gate desk = fully open
        return values?[q] ?? Int.max                  // unset qual = highest preference
    }

    /// Q4 acceptance rule: will a person move INTO `newDesk` (giving up `currentDesk`)
    /// for a qual swap? True iff the new desk is NOT a blacklisted desk number, its qual is
    /// NOT blacklisted (value 0), AND its preference value is **equal-or-higher** than their
    /// current desk's qual. Eligibility (do they hold the qual) is checked separately by
    /// `qualified(quals:forDesk:)`.
    static func acceptsQualSwap(into newDesk: String, fromCurrentDesk currentDesk: String,
                                values: [String: Int]?, blacklistDesks: Set<String>? = nil) -> Bool {
        qualSwapHardOK(into: newDesk, values: values, blacklistDesks: blacklistDesks)
            && qualSwapFavorable(into: newDesk, fromCurrentDesk: currentDesk, values: values)
    }

    /// HARD gate (never overridden): the give-desk isn't a blacklisted desk number and its qual isn't
    /// blacklisted (value 0). A bridge failing this is dropped entirely.
    static func qualSwapHardOK(into newDesk: String, values: [String: Int]?, blacklistDesks: Set<String>? = nil) -> Bool {
        let newDeskU = newDesk.uppercased().trimmingCharacters(in: .whitespaces)
        if blacklistDesks?.contains(newDeskU) == true { return false }
        if let nq = requiredQual(forDesk: newDesk), values?[nq] == 0 { return false }
        return true
    }
    /// SOFT signal (Q4): moving onto `newDesk` is an EQUAL-or-BETTER qual preference than their current
    /// desk. `false` = unfavorable — a stretch ask, surfaced with a warning rather than dropped.
    static func qualSwapFavorable(into newDesk: String, fromCurrentDesk currentDesk: String, values: [String: Int]?) -> Bool {
        qualValue(requiredQual(forDesk: newDesk), values: values) >= qualValue(requiredQual(forDesk: currentDesk), values: values)
    }
}

// MARK: - Global trade timing rule

/// Single source of truth for trade timing. Per the user: **all** trading globally
/// (not just qual swaps) only ever considers shifts that start at 0500, 1300, or 2100.
nonisolated enum TradeTiming {
    /// The only start hours (24h) that any trade considers.
    static let validStartHours: Set<Int> = [5, 13, 21]
    static func isTradeable(startHour: Int) -> Bool { validStartHours.contains(startHour) }

    /// A training slot (e.g. "TRN" / "TRNG"), NOT a real dispatch desk. Someone permanently
    /// in a training shift is not doing coverable dispatch work.
    static func isTrainingDesk(_ desk: String) -> Bool {
        desk.uppercased().trimmingCharacters(in: .whitespaces).hasPrefix("TRN")
    }

    /// A genuine, tradeable dispatch shift: a regular start hour (0500/1300/2100) on a real
    /// dispatch desk — never a training (TRN) slot or an irregular start time. "Not a dispatch
    /// shift" (e.g. a permanent trainee like a TRN-only roster) is never coverable/tradeable.
    static func isDispatchShift(desk: String, startHour: Int, isOff: Bool = false) -> Bool {
        !isOff && isTradeable(startHour: startHour) && !isTrainingDesk(desk)
    }
}

// MARK: - Qual swaps (same-day desk swap, Q-series)

/// One person's working shift on the swap day — the minimal info the qual-swap
/// finder needs about a potential partner.
struct QualSwapShift: Sendable, Hashable, Identifiable {
    let workerID: String
    let name: String
    let desk: String
    let startHour: Int      // 24h start, so only same-start-hour swaps pair (coverage-neutral)
    let quals: [String]
    var id: String { workerID }
}

nonisolated enum QualSwap {
    /// Bridge partners (C) that unblock GIVING a desk to a willing-but-unqualified taker.
    ///
    /// Scenario: A gives away `giveDesk` (needs qual X) on a day; the off taker (B) is
    /// willing but lacks X. A bridge C — already working that day — slides onto A's desk,
    /// freeing C's desk for B. A goes off. Coverage and start time stay whole.
    ///
    /// C qualifies iff: starts at the same (tradeable) hour, HOLDS X (can take giveDesk), and is not
    /// HARD-blocked (blacklisted give-desk/qual). Their desk needn't be domestic — Euro/Pacific bridges are
    /// fine. When `takerQuals` is provided (trade-first: a real B exists) C's freed desk must be one B can
    /// hold; when nil (bridge-first: the green button, no B yet) that check is skipped. Each result is
    /// flagged `favorable` — UNfavorable bridges (they prefer their current desk's qual) are INCLUDED with a
    /// warning, not dropped. `excludeIDs` drops A and B themselves.
    static func bridges(giveDesk: String, takerQuals: [String]?, startHour: Int,
                        workers: [(shift: QualSwapShift, profile: TradeProfile)],
                        excludeIDs: Set<String>) -> [QualSwapCandidate] {
        guard TradeTiming.isTradeable(startHour: startHour) else { return [] }
        return workers.compactMap { worker -> QualSwapCandidate? in
            let c = worker.shift
            guard !excludeIDs.contains(c.workerID) else { return nil }
            guard c.startHour == startHour else { return nil }                                // same start time
            guard DeskRules.qualified(quals: c.quals, forDesk: giveDesk) else { return nil }   // C can take give-desk (has X)
            if let tq = takerQuals {                                                           // trade-first only
                guard DeskRules.qualified(quals: tq, forDesk: c.desk) else { return nil }       // taker can take C's freed desk
            }
            let vals = worker.profile.qualValues
            guard DeskRules.qualSwapHardOK(into: giveDesk, values: vals,
                                           blacklistDesks: worker.profile.qualSwapBlacklistDesks) else { return nil }
            let favorable = DeskRules.qualSwapFavorable(into: giveDesk, fromCurrentDesk: c.desk, values: vals)
            return QualSwapCandidate(workerID: c.workerID, name: c.name, desk: c.desk,
                                     qual: DeskRules.requiredQual(forDesk: c.desk) ?? "D", favorable: favorable)
        }
        // Favorable first, then by name — the caller may re-sort, but a sane default keeps stretch asks last.
        .sorted { ($0.favorable ? 0 : 1, $0.name) < ($1.favorable ? 0 : 1, $1.name) }
    }

    /// One auto-discovered 3-party qual-swap solution (Q1): giver A goes off, bridge C slides
    /// onto A's give-desk, off-taker B takes C's freed desk.
    struct Solution: Sendable, Hashable {
        let bridgeID: String; let bridgeName: String
        let bridgeDesk: String; let bridgeQual: String   // C's desk (freed for B) + its qual
        let takerID: String; let takerName: String       // B, who takes C's freed desk
    }

    /// PURE: enumerate qual-swap solutions to unblock giving `giveDesk` on a (tradeable-hour) day.
    /// `workers` are people working that day (shift + profile); `offTakers` are people OFF that day
    /// the CALLER has already gated as willing/eligible (their `canCover` of the bridge's desk is
    /// checked here by qual only — the caller applies the full availability gate). Self is excluded.
    static func solutions(giveDesk: String, giveStartHour: Int, giverID: String,
                          workers: [(shift: QualSwapShift, profile: TradeProfile)],
                          offTakers: [(id: String, name: String, quals: [String])]) -> [Solution] {
        guard TradeTiming.isTradeable(startHour: giveStartHour) else { return [] }
        var out: [Solution] = []
        for w in workers {
            let c = w.shift
            guard c.workerID != giverID, c.startHour == giveStartHour else { continue }
            guard DeskRules.qualified(quals: c.quals, forDesk: giveDesk) else { continue }    // C can take A's desk
            guard w.profile.acceptsQualSwap(into: giveDesk, fromCurrentDesk: c.desk) else { continue }  // C willing (Q4)
            let cQual = DeskRules.requiredQual(forDesk: c.desk) ?? "D"
            for b in offTakers where b.id != giverID && b.id != c.workerID {
                guard DeskRules.qualified(quals: b.quals, forDesk: c.desk) else { continue }  // B can take C's freed desk
                out.append(Solution(bridgeID: c.workerID, bridgeName: c.name,
                                    bridgeDesk: c.desk, bridgeQual: cQual,
                                    takerID: b.id, takerName: b.name))
            }
        }
        return out
    }
}

/// Lifecycle of a qual-swap leg inside a trade package (Q3/Q5/Q6). Drives the card
/// indicator + inbox text. CaseIterable so the UI can be enumerated against it.
enum QualSwapLegStatus: String, Sendable, Codable, CaseIterable {
    case waiting        // blasted; no bridge has accepted yet → "Waiting on qual swap"
    case offersOpen     // ≥1 bridge accepted; first-5 slots remain → taker may pick now or wait
    case offersFull     // first-5 acceptor cap reached; no more bridges can respond
    case finalized      // taker chose a swap → leg locked, trade can complete
    case invalid        // taker declined OR no bridge accepted in time → package dead (reason: qual swap)

    var isTerminal: Bool { self == .finalized || self == .invalid }
}

enum QualSwapLeg {
    /// First-N acceptor cap for a qual-swap blast (ECB-style). The 6th+ sees "already filled".
    static let acceptorCap = 5

    /// Whether another bridge may still accept (first-5 rule).
    static func acceptIsOpen(acceptedCount: Int) -> Bool { acceptedCount < acceptorCap }

    /// Pure reducer: the leg's status from the live signals. `finalized` wins; a taker
    /// decline or a timeout with ZERO acceptances is invalid; otherwise it's waiting /
    /// offers-open / offers-full by acceptance count. Acceptances stand through expiry —
    /// only the taker finalizing or declining (or nobody bridging) resolves the leg.
    static func status(acceptedCount: Int, finalized: Bool, declined: Bool, expired: Bool) -> QualSwapLegStatus {
        if finalized { return .finalized }
        if declined { return .invalid }
        if acceptedCount == 0 { return expired ? .invalid : .waiting }
        return acceptIsOpen(acceptedCount: acceptedCount) ? .offersOpen : .offersFull
    }
}

// MARK: - Match results

/// One day in a candidate's mini-schedule snapshot.
struct DayCell: Sendable, Hashable {
    let weekday: String   // "M","T","W","Th","F","Sa","Su"
    let letter: String    // "A"/"P"/"M" for AM/PM/MID, or "" when off
    let isTarget: Bool    // the day being covered
}

/// A candidate for a MULTI-shift trade request: how many of the requested shifts
/// they can cover, and how many of those are clean bookends for them.
struct PlanCandidate: Sendable, Hashable, Identifiable {
    let workerID: String
    let name: String
    let quals: [String]
    let coveredShiftIDs: Set<String>
    let bookendShiftIDs: Set<String>
    let week: [DayCell]   // ±4 snapshot when a single day is requested; empty otherwise
    var willingness: TradeWillingness = .unknown   // annotated post-match from profiles
    var twoWayCount: Int = 0                        // mutual-intent swaps available (🔥×N)
    var matchCount: Int { coveredShiftIDs.count }
    var bookendCount: Int { bookendShiftIDs.count }
    var id: String { workerID }
}

/// One day in a two-way swap. `bookend` = covering this day keeps the RECEIVER's
/// time off contiguous (bookend for whoever picks it up). `wanted` = the owner
/// has actively marked this day to trade away (mutual intent → 🔥).
struct TwoWayLeg: Sendable, Hashable, Identifiable {
    let dayID: String      // ISO "yyyy-MM-dd"
    let date: Date
    let desk: String
    let startHour: Int
    let bookend: Bool
    let wanted: Bool
    var id: String { dayID }
}

/// Feasible bookend swaps with one dispatcher over a window: the days you'd give
/// them (they cover) and the days you'd take (they're working, you cover).
/// `wanted` legs are ones the owner actively marked to trade away.
struct TwoWayPlan: Sendable {
    let workerID: String
    let name: String
    let iGive: [TwoWayLeg]   // your work days they cover — bookend for THEM
    let iTake: [TwoWayLeg]   // their work days you cover — bookend for YOU
    var isViable: Bool { !iGive.isEmpty && !iTake.isEmpty }
    var mutualWanted: Int { min(iGive.filter(\.wanted).count, iTake.filter(\.wanted).count) }
}

// MARK: - Matcher

@MainActor
enum TradeMatcher {

    private static let minRest: TimeInterval = 8 * 3600
    private static let shiftLength: TimeInterval = 9 * 3600

    /// A blank "open, no relief" profile for `canCover(.physicalOnly)` — that mode reads the
    /// profile only for relief (nil here), so a coarse physical probe needs no real profile.
    private static let physicalProbeProfile = TradeProfile(
        workerID: "", displayName: "", openness: "all", blacklistedWeekdays: [],
        blacklistedDesks: [], blacklistedShiftTypes: [], blacklistedRegions: [],
        seekingDayIDs: [], updatedAt: Date(timeIntervalSince1970: 0))

    /// How far ahead two-way matching looks (badge count + explorer span).
    static let twoWayHorizonMonths = 12

    /// The shift TYPES (AM/PM/MID) a worker actually WORKED in the last `days` days — their recent
    /// behavior. Used to filter ECB offers so a dispatcher who's only worked MIDs isn't offered a PM.
    static func recentWorkedTypes(workerID: String, asOf: Date = Date(), days: Int = 60) async -> Set<ShiftAvailabilityType> {
        let cal = Calendar.current
        guard let lower = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: asOf)) else { return [] }
        let sched = await RosterStore.shared.schedule(forWorker: workerID)
        var types: Set<ShiftAvailabilityType> = []
        for e in sched where !e.isOff {
            guard let d = dayDate(fromISO: e.day), d >= lower, d <= asOf else { continue }
            types.insert(ShiftAvailabilityType.infer(fromStartHour: e.startHour))
        }
        return types
    }

    /// Pure decision for the ECB 60-day behavior filter: keep a candidate only if a type they
    /// recently worked overlaps a type they'd cover here. Empty `recent` (no recent work / robot)
    /// → excluded. Testable without the roster.
    static func recentBehaviorAllows(recentTypes: Set<ShiftAvailabilityType>,
                                     coveredTypes: Set<ShiftAvailabilityType>) -> Bool {
        !recentTypes.isDisjoint(with: coveredTypes)
    }

    /// Candidates for a MULTI-shift trade: for the given shifts (your days to give
    /// away), how many each dispatcher can cover (off + qualified + 8h rest) and how
    /// many are bookends for them. Ranked by bookends, then total matches.
    static func candidatesForTrades(shifts: [Shift], excluding selfID: String) async -> [PlanCandidate] {
        guard !shifts.isEmpty else { return [] }
        let cal = Calendar.current
        let days = shifts.map { cal.startOfDay(for: $0.date) }
        guard let minD = days.min(), let maxD = days.max(),
              let lower = cal.date(byAdding: .day, value: -4, to: minD),
              let upper = cal.date(byAdding: .day, value:  4, to: maxD) else { return [] }

        let entries = await RosterStore.shared.entries(from: lower, to: upper)
        var byWorker: [String: [String: RosterEntry]] = [:]
        for e in entries { byWorker[e.workerID, default: [:]][e.day] = e }

        var result: [PlanCandidate] = []
        for (wid, dayMap) in byWorker where wid != selfID {
            guard let meta = dayMap.values.first else { continue }
            var covered = Set<String>()
            for shift in shifts {
                let day = cal.startOfDay(for: shift.date)
                guard let target = dayMap[iso(day)] else { continue }
                // Off + qualified + 8h-rest via the unified predicate (#22-proven). cap/soft are
                // physical-irrelevant here, and relief is applied downstream (ECB .full filter).
                if TradeEligibility.canCover(coverDayID: iso(day), coverDay: day, desk: shift.desk,
                                             startHour: shift.startHour, coverMap: dayMap,
                                             coverQuals: target.quals, coverProfile: physicalProbeProfile,
                                             options: .physicalOnly, cal: cal).eligible {
                    covered.insert(shift.id)
                }
            }

            // Bookend = the picked-up day attaches to the candidate's REAL
            // schedule rather than floating in their time off. Treat every shift
            // they're covering in THIS request as worked, then a covered day is a
            // bookend only if its contiguous in-plan work block contains at least
            // one of their EXISTING worked days (the block is anchored).
            //   • OFF-[ON ON ON]-OFF (whole block in their off time) → none count
            //   • W-O-O (give away the edge, attaches to real work)   → counts
            //   • one day of a 2-day weekend W-[O]-O-W                → counts
            //   • lone OFF-ON-OFF                                     → no count
            let coveredDays = Set(shifts.filter { covered.contains($0.id) }
                                        .map { iso(cal.startOfDay(for: $0.date)) })
            func existingWork(_ d: Date) -> Bool { dayMap[iso(d)].map { !$0.isOff } ?? false }
            func worksInPlan(_ d: Date) -> Bool { coveredDays.contains(iso(d)) || existingWork(d) }
            // Walk the in-plan work block out from `day`; true if it touches real work.
            func anchored(_ day: Date) -> Bool {
                for dir in [-1, 1] {
                    var step = dir, guardCount = 0
                    while let cur = cal.date(byAdding: .day, value: step, to: day),
                          worksInPlan(cur), guardCount < 90 {
                        if existingWork(cur) { return true }
                        step += dir; guardCount += 1
                    }
                }
                return false
            }
            var bookendIDs = Set<String>()
            for shift in shifts where covered.contains(shift.id) {
                if anchored(cal.startOfDay(for: shift.date)) { bookendIDs.insert(shift.id) }
            }

            if !covered.isEmpty {
                var week: [DayCell] = []
                if shifts.count == 1, let only = shifts.first {
                    let day = cal.startOfDay(for: only.date)
                    for offset in -4...4 {
                        let d = cal.date(byAdding: .day, value: offset, to: day) ?? day
                        let e = dayMap[iso(d)]
                        let letter = (e != nil && !e!.isOff) ? typeLetter(e!.startHour) : ""
                        week.append(DayCell(weekday: weekdayLetter(d), letter: letter, isTarget: offset == 0))
                    }
                }
                result.append(PlanCandidate(workerID: wid, name: meta.workerName, quals: meta.quals,
                                            coveredShiftIDs: covered, bookendShiftIDs: bookendIDs, week: week))
            }
        }
        return result.sorted {
            if $0.bookendCount != $1.bookendCount { return $0.bookendCount > $1.bookendCount }
            if $0.matchCount != $1.matchCount { return $0.matchCount > $1.matchCount }
            return $0.name < $1.name
        }
    }

    // MARK: - Two-way swap

    /// Explores all feasible BOOKEND swaps with one dispatcher inside a date
    /// window: their work days you could cover (bookend for you) and your work
    /// days they could cover (bookend for them). `wanted` legs are days the owner
    /// actively marked to trade away. Single-worker roster queries keep it cheap.
    /// @MainActor wrapper for callers that DON'T preload schedules (e.g. the two-way sheet): fetch the two
    /// rosters on the main actor, then delegate to the pure `nonisolated` core below.
    static func twoWayExplore(withWorker workerID: String, name: String,
                              windowStart: Date, windowEnd: Date,
                              mySeeking: Set<String>, theirSeeking: Set<String>,
                              myProfile: TradeProfile, theirProfile: TradeProfile, myID: String,
                              ignoreOwnBlacklist: Bool = false,
                              preloadedMine: [RosterEntry]? = nil,
                              preloadedPeer: [RosterEntry]? = nil) async -> TwoWayPlan {
        // Perf (R-A): reuse preloaded schedules when the caller already has them (looping the roster).
        let myEntries: [RosterEntry]
        if let pm = preloadedMine { myEntries = pm } else { myEntries = await RosterStore.shared.schedule(forWorker: myID) }
        let peerEntries: [RosterEntry]
        if let pp = preloadedPeer { peerEntries = pp } else { peerEntries = await RosterStore.shared.schedule(forWorker: workerID) }
        return twoWayExploreCore(withWorker: workerID, name: name, windowStart: windowStart, windowEnd: windowEnd,
                                 mySeeking: mySeeking, theirSeeking: theirSeeking,
                                 myProfile: myProfile, theirProfile: theirProfile,
                                 ignoreOwnBlacklist: ignoreOwnBlacklist,
                                 myEntries: myEntries, peerEntries: peerEntries)
    }

    /// PURE two-way exploration over PRELOADED schedules — no `.shared` access, so it runs off the main
    /// actor (the intent loop calls this directly inside `Task.detached`). Logic identical to before.
    nonisolated static func twoWayExploreCore(withWorker workerID: String, name: String,
                              windowStart: Date, windowEnd: Date,
                              mySeeking: Set<String>, theirSeeking: Set<String>,
                              myProfile: TradeProfile, theirProfile: TradeProfile,
                              ignoreOwnBlacklist: Bool,
                              myEntries: [RosterEntry], peerEntries: [RosterEntry]) -> TwoWayPlan {
        let cal = Calendar.current
        let pEntries = peerEntries
        let myMap = Dictionary(myEntries.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let pMap  = Dictionary(pEntries.map  { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let myQuals = myEntries.first?.quals ?? []

        func inWindow(_ d: Date) -> Bool { d >= windowStart && d < windowEnd }

        // You take ← their work days you can cover (off + qualified + rested) that
        // pass YOUR rules (availability/openness/bookend/blacklist/mercenary/cap).
        // You take ← their work days you can cover. The unified predicate applies the
        // hard physical gates + your cap + your rules (soft gates skipped when you're
        // overriding your own restrictions). (U1 — delegates to TradeEligibility.canCover.)
        var iTake: [TwoWayLeg] = []
        for pe in pEntries where !pe.isOff {
            guard let day = dateFromISO(pe.day), inWindow(day) else { continue }
            // Their working shift isn't real past THEIR relief horizon — don't offer it.
            if theirProfile.scheduleUnknown(on: day, cal: cal) { continue }
            let check = TradeEligibility.canCover(
                coverDayID: pe.day, coverDay: day, desk: pe.desk, startHour: pe.startHour,
                coverMap: myMap, coverQuals: myQuals, coverProfile: myProfile,
                options: EligibilityOptions(applySoftGates: !ignoreOwnBlacklist), cal: cal)
            guard check.eligible else { continue }
            // GIVER-side bookend: don't ask a bookends-only peer to give away a mid-week day that would
            // leave them an isolated day off (unless they explicitly marked it trade-away). Symmetric to
            // the pickup bookend rule — fixes "random inconvenient give-back" (e.g. a peer's mid-week Sep 15).
            if theirProfile.opennessLevel == .bookends,
               !theirSeeking.contains(pe.day),
               !TradeMatcher.isCleanGiveAway(day: day, map: pMap, cal: cal) { continue }
            iTake.append(TwoWayLeg(dayID: pe.day, date: day, desk: pe.desk, startHour: pe.startHour,
                                   bookend: check.isBookend, wanted: theirSeeking.contains(pe.day)))
        }

        // You give → your work days they can cover that pass THEIR full rules.
        var iGive: [TwoWayLeg] = []
        for me in myEntries where !me.isOff {
            // Never offer a working day you marked KEEP (SPEC S-ENG-9/10) — a give-side gate.
            if myProfile.keepDayIDs?.contains(me.day) == true { continue }
            guard let day = dateFromISO(me.day), inWindow(day), let pe = pMap[me.day] else { continue }
            // My working shift isn't real past MY relief horizon — don't offer it.
            if myProfile.scheduleUnknown(on: day, cal: cal) { continue }
            let check = TradeEligibility.canCover(
                coverDayID: me.day, coverDay: day, desk: me.desk, startHour: me.startHour,
                coverMap: pMap, coverQuals: pe.quals, coverProfile: theirProfile,
                options: .full, cal: cal)
            guard check.eligible else { continue }
            iGive.append(TwoWayLeg(dayID: me.day, date: day, desk: me.desk, startHour: me.startHour,
                                   bookend: check.isBookend, wanted: mySeeking.contains(me.day)))
        }

        let order: (TwoWayLeg, TwoWayLeg) -> Bool = { ($0.wanted ? 0 : 1, $0.date) < ($1.wanted ? 0 : 1, $1.date) }
        return TwoWayPlan(workerID: workerID, name: name,
                          iGive: iGive.sorted(by: order), iTake: iTake.sorted(by: order))
    }

    /// Drives the 🔥×N one-way badge. N = A + B (any aligned trade move counts —
    /// one-way or two-way):
    ///   A = your give-away days (marked ∪ this search's selection) that THEY would
    ///       take — gated by THEIR openness + blacklist (bookend only required if
    ///       their openness is `.bookends`; `.all` accepts any day).
    ///   B = their marked days YOU would take — gated by YOUR openness + blacklist
    ///       (bookend only required if your openness is `.bookends`).
    /// `myEntries` is passed in so your schedule is fetched once.
    static func goldCount(workerID: String, myGiveShifts: [Shift],
                          theirProfile: TradeProfile, myProfile: TradeProfile,
                          myEntries: [RosterEntry]) async -> Int {
        let cal = Calendar.current
        let pEntries = await RosterStore.shared.schedule(forWorker: workerID)
        let myMap = Dictionary(myEntries.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let pMap  = Dictionary(pEntries.map  { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let today = cal.startOfDay(for: Date())
        guard let horizonEnd = cal.date(byAdding: .month, value: twoWayHorizonMonths, to: today) else { return 0 }
        return goldCountPure(myGiveShifts: myGiveShifts, myMap: myMap, pMap: pMap,
                             theirProfile: theirProfile, myProfile: myProfile,
                             myQuals: myEntries.first?.quals ?? [], today: today, horizonEnd: horizonEnd, cal: cal)
    }

    /// PURE core of `goldCount` (A6 — testable WITHOUT RosterStore). N = A + B:
    ///   A = your give-shifts THEY would take · B = their seeking days YOU would take.
    static func goldCountPure(myGiveShifts: [Shift], myMap: [String: RosterEntry], pMap: [String: RosterEntry],
                              theirProfile: TradeProfile, myProfile: TradeProfile, myQuals: [String],
                              today: Date, horizonEnd: Date, cal: Calendar) -> Int {
        func inHorizon(_ d: Date) -> Bool { d >= today && d < horizonEnd }
        // A — your give-away days THEY would take (their openness + blacklist).
        var a = 0
        var countedGive = Set<String>()
        for s in myGiveShifts {
            let day = cal.startOfDay(for: s.date)
            let key = iso(day)
            guard !countedGive.contains(key), inHorizon(day),
                  let pe = pMap[key], pe.isOff,
                  DeskRules.qualified(quals: pe.quals, forDesk: s.desk),
                  rested(map: pMap, day: day, startHour: s.startHour, cal: cal) else { continue }
            let weekday = cal.component(.weekday, from: day)
            let region  = DeskRules.region(forDesk: s.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: s.startHour).rawValue
            let bookend = anchored(day: day, map: pMap, plan: [key], cal: cal)
            guard theirProfile.wouldPickUp(onDay: key, weekday: weekday, desk: s.desk,
                                           shiftType: type, region: region, isBookend: bookend) else { continue }
            countedGive.insert(key); a += 1
        }
        // B — their marked days YOU would take (your openness + blacklist).
        var b = 0
        for dayID in theirProfile.seekingDayIDs {
            guard let pe = pMap[dayID], !pe.isOff, let me = myMap[dayID], me.isOff,
                  let day = dateFromISO(dayID), inHorizon(day),
                  DeskRules.qualified(quals: myQuals, forDesk: pe.desk),
                  rested(map: myMap, day: day, startHour: pe.startHour, cal: cal) else { continue }
            let weekday = cal.component(.weekday, from: day)
            let region  = DeskRules.region(forDesk: pe.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: pe.startHour).rawValue
            let bookend = anchored(day: day, map: myMap, plan: [dayID], cal: cal)
            guard myProfile.wouldPickUp(onDay: dayID, weekday: weekday, desk: pe.desk,
                                        shiftType: type, region: region, isBookend: bookend) else { continue }
            b += 1
        }
        return a + b
    }

    #if DEBUG
    struct MutualSeed: Sendable {
        let peerID: String
        let peerName: String
        let myGiveDayID: String      // a day YOU work that the peer can bookend-cover
        let theirTakeDayID: String   // a day the PEER works that you can bookend-cover
    }

    /// Scans the roster for a peer with whom a true mutual-bookend swap exists, so
    /// the gold 🔥 path can be exercised in testing. Returns the two days to mark.
    static func findMutualBookendPair(excluding myID: String) async -> MutualSeed? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let upper = cal.date(byAdding: .day, value: 90, to: today) else { return nil }
        let entries = await RosterStore.shared.entries(from: today, to: upper)
        var byWorker: [String: [String: RosterEntry]] = [:]
        for e in entries { byWorker[e.workerID, default: [:]][e.day] = e }
        guard let myMap = byWorker[myID] else { return nil }
        let myQuals = myMap.values.first?.quals ?? []

        for (pid, pMap) in byWorker where pid != myID {
            let pQuals = pMap.values.first?.quals ?? []
            // A peer work day you can cover as a bookend.
            let take = pMap.first { (dayID, pe) in
                guard !pe.isOff, let me = myMap[dayID], me.isOff, let d = dateFromISO(dayID),
                      DeskRules.qualified(quals: myQuals, forDesk: pe.desk),
                      rested(map: myMap, day: d, startHour: pe.startHour, cal: cal),
                      anchored(day: d, map: myMap, plan: [dayID], cal: cal) else { return false }
                return true
            }?.key
            guard let take else { continue }
            // A day you work the peer can cover as a bookend.
            let give = myMap.first { (dayID, me) in
                guard !me.isOff, let pe = pMap[dayID], pe.isOff, let d = dateFromISO(dayID),
                      DeskRules.qualified(quals: pQuals, forDesk: me.desk),
                      rested(map: pMap, day: d, startHour: me.startHour, cal: cal),
                      anchored(day: d, map: pMap, plan: [dayID], cal: cal) else { return false }
                return true
            }?.key
            guard let give else { continue }
            return MutualSeed(peerID: pid, peerName: pMap.values.first?.workerName ?? pid,
                              myGiveDayID: give, theirTakeDayID: take)
        }
        return nil
    }
    #endif

    /// Days in a trade request that are no longer valid against the CURRENT master
    /// roster — i.e. the person who should be working that day no longer is (they
    /// already traded it, bid it away, etc.). Empty set = still fully valid.
    /// `giveDayIDs` must be days the SENDER works; `takeDayIDs` days the RECIPIENT
    /// works.
    static func staleDays(fromID: String, toID: String,
                          giveDayIDs: [String], takeDayIDs: [String]) async -> Set<String> {
        let fromSched = await RosterStore.shared.schedule(forWorker: fromID)
        let toSched   = await RosterStore.shared.schedule(forWorker: toID)
        let fromMap = Dictionary(fromSched.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let toMap   = Dictionary(toSched.map   { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        return staleDaysPure(giveDayIDs: giveDayIDs, takeDayIDs: takeDayIDs, fromMap: fromMap, toMap: toMap)
    }

    /// PURE core (S-VALID, testable): a trade day is STALE/invalid when the giver no
    /// longer works it (now off/vacation/gone) or the taker no longer works their leg.
    static func staleDaysPure(giveDayIDs: [String], takeDayIDs: [String],
                              fromMap: [String: RosterEntry], toMap: [String: RosterEntry]) -> Set<String> {
        var stale = Set<String>()
        for d in giveDayIDs where (fromMap[d]?.isOff ?? true) { stale.insert(d) }  // sender no longer works it
        for d in takeDayIDs where (toMap[d]?.isOff ?? true)   { stale.insert(d) }  // recipient no longer works it
        return stale
    }

    /// A worker's day → "AM 82" type+desk label ("" when off), for the larger
    /// trade calendars.
    static func dayLabels(forWorker workerID: String) async -> [String: String] {
        let entries = await RosterStore.shared.schedule(forWorker: workerID)
        var map: [String: String] = [:]
        for e in entries {
            if e.isOff { map[e.day] = "" }
            else {
                let type = ShiftAvailabilityType.infer(fromStartHour: e.startHour).rawValue
                map[e.day] = e.desk.isEmpty ? type : "\(type) \(e.desk)"
            }
        }
        return map
    }

    /// 8-hour rest before/after a shift on `day` vs the map owner's adjacent shifts.
    nonisolated private static func rested(map: [String: RosterEntry], day: Date, startHour: Int, cal: Calendar) -> Bool {
        guard let coverStart = cal.date(byAdding: .hour, value: startHour, to: cal.startOfDay(for: day)) else { return false }
        let coverEnd = coverStart.addingTimeInterval(shiftLength)
        if let prev = cal.date(byAdding: .day, value: -1, to: day), let p = map[iso(prev)], !p.isOff {
            let pEnd = (cal.date(byAdding: .hour, value: p.startHour, to: cal.startOfDay(for: prev)) ?? prev).addingTimeInterval(shiftLength)
            if coverStart.timeIntervalSince(pEnd) < minRest { return false }
        }
        if let next = cal.date(byAdding: .day, value: 1, to: day), let n = map[iso(next)], !n.isOff {
            let nStart = cal.date(byAdding: .hour, value: n.startHour, to: cal.startOfDay(for: next)) ?? next
            if nStart.timeIntervalSince(coverEnd) < minRest { return false }
        }
        return true
    }

    /// Whether covering `day` attaches to the map owner's existing work (same
    /// "no floating island" bookend rule as the one-way matcher).
    nonisolated static func anchored(day: Date, map: [String: RosterEntry], plan: Set<String>, cal: Calendar) -> Bool {
        func existingWork(_ d: Date) -> Bool { map[iso(d)].map { !$0.isOff } ?? false }
        func worksInPlan(_ d: Date) -> Bool { plan.contains(iso(d)) || existingWork(d) }
        for dir in [-1, 1] {
            var step = dir, guardCount = 0
            while let cur = cal.date(byAdding: .day, value: step, to: cal.startOfDay(for: day)),
                  worksInPlan(cur), guardCount < 90 {
                if existingWork(cur) { return true }
                step += dir; guardCount += 1
            }
        }
        return false
    }

    /// The GIVER-side bookend: giving away a worked `day` is CLEAN only if it sits at the EDGE of a work
    /// block — a neighbor is already off/absent — so trading it out extends the giver's time off instead
    /// of leaving an isolated mid-week "island" day off. (Symmetric to `anchored`, which is the pickup
    /// bookend.) Used to stop offering a peer's inconvenient mid-week give-backs.
    nonisolated static func isCleanGiveAway(day: Date, map: [String: RosterEntry], cal: Calendar) -> Bool {
        func offOrAbsent(_ d: Date) -> Bool { map[iso(d)].map { $0.isOff } ?? true }
        let base = cal.startOfDay(for: day)
        let prev = cal.date(byAdding: .day, value: -1, to: base) ?? base
        let next = cal.date(byAdding: .day, value: 1, to: base) ?? base
        return offOrAbsent(prev) || offOrAbsent(next)
    }

    // MARK: - Qual swaps (shared by trade search + intents + routes)

    /// Bridge candidates that could unblock giving `giveDesk` on `giveDayID` to a taker
    /// holding `takerQuals` but lacking the desk's qual. THE single entry point used by
    /// every matcher path. Returns [] when no swap is needed, the start hour isn't
    /// tradeable, or nobody qualifies. Bridges with no published profile default to open.
    /// `takerQuals == nil` ⇒ BRIDGE-FIRST (green button, no taker yet): list every working bridge that can
    /// take the give-desk, skipping the "taker can take C's freed desk" check. Non-nil ⇒ trade-first.
    static func qualSwapBridges(giveDayID: String, giveDesk: String, giveStartHour: Int,
                                takerID: String = "", takerQuals: [String]? = nil,
                                excludeIDs: Set<String>) async -> [QualSwapCandidate] {
        // A specific taker who ALREADY holds the qual doesn't need a swap; bridge-first (nil) always proceeds.
        if let tq = takerQuals, !qualSwapNeededShared(forDesk: giveDesk, takerQuals: tq) { return [] }
        guard TradeTiming.isTradeable(startHour: giveStartHour),
              let date = dateFromISO(giveDayID) else { return [] }
        let working = await RosterStore.shared.dispatchersWorking(on: date)
        let workers: [(QualSwapShift, TradeProfile)] = working.map { e in
            let shift = QualSwapShift(workerID: e.workerID, name: e.workerName, desk: e.desk,
                                      startHour: e.startHour, quals: e.quals)
            let prof = TradeProfileStore.shared.profile(forWorker: e.workerID)
                ?? TradeProfile.defaultForUnpublished(workerID: e.workerID, name: e.workerName)   // A8: missing → Bookends Only
            return (shift, prof)
        }
        var exclude = excludeIDs; if !takerID.isEmpty { exclude.insert(takerID) }
        return QualSwap.bridges(giveDesk: giveDesk, takerQuals: takerQuals, startHour: giveStartHour,
                                workers: workers, excludeIDs: exclude)
    }

    /// Build an embedded qual-swap leg for giving `giveDesk` to a taker. nil when no swap
    /// is needed or no bridge qualifies. `chosenCandidateIDs` (Q2 multi-select) limits which
    /// bridges to blast — nil/empty = blast all eligible.
    static func buildQualSwapLeg(giveDayID: String, giveDesk: String, giveStartHour: Int,
                                 giverID: String, takerID: String, takerName: String, takerQuals: [String],
                                 chosenCandidateIDs: Set<String>? = nil) async -> QualSwapLegData? {
        var cands = await qualSwapBridges(giveDayID: giveDayID, giveDesk: giveDesk, giveStartHour: giveStartHour,
                                          takerID: takerID, takerQuals: takerQuals, excludeIDs: [giverID])
        if let chosen = chosenCandidateIDs, !chosen.isEmpty {
            cands = cands.filter { chosen.contains($0.workerID) }
        }
        guard !cands.isEmpty else { return nil }
        let qual = DeskRules.requiredQual(forDesk: giveDesk) ?? "D"
        return QualSwapLegData(giveShiftDayID: giveDayID, giveDesk: giveDesk, giveQual: qual,
                               takerID: takerID, takerName: takerName, candidates: cands)
    }

    /// Thin alias so this @MainActor enum can call the pure SSOT gap check by name.
    private static func qualSwapNeededShared(forDesk desk: String, takerQuals: [String]) -> Bool {
        DeskRules.qualSwapNeeded(forDesk: desk, takerQuals: takerQuals)
    }

    // MARK: - Snapshot helpers

    nonisolated private static func iso(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    nonisolated private static func dateFromISO(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s).map { Calendar.current.startOfDay(for: $0) }
    }

    private static func weekdayLetter(_ date: Date) -> String {
        switch Calendar.current.component(.weekday, from: date) {
        case 1:  return "Su"
        case 2:  return "M"
        case 3:  return "T"
        case 4:  return "W"
        case 5:  return "Th"
        case 6:  return "F"
        default: return "Sa"
        }
    }

    private static func typeLetter(_ startHour: Int) -> String {
        switch ShiftAvailabilityType.infer(fromStartHour: startHour) {
        case .am:  return "A"
        case .pm:  return "P"
        case .mid: return "M"
        }
    }
}

// MARK: - Reusable hard-gate helpers for the v2 router
//
// `rested`/`anchored`/`iso`/`dateFromISO` are `private` (file-scoped) above. This
// same-file extension re-exposes them as internal wrappers so `TradeRouter` can
// reuse the exact same gate logic instead of duplicating it.
extension TradeMatcher {
    /// 8-hour rest check vs the map owner's adjacent shifts.
    nonisolated static func isRested(map: [String: RosterEntry], day: Date, startHour: Int,
                         cal: Calendar = .current) -> Bool {
        rested(map: map, day: day, startHour: startHour, cal: cal)
    }

    /// Whether covering `day` attaches to existing work (no floating island).
    nonisolated static func isAnchored(day: Date, map: [String: RosterEntry], plan: Set<String>,
                           cal: Calendar = .current) -> Bool {
        anchored(day: day, map: map, plan: plan, cal: cal)
    }

    /// ISO "yyyy-MM-dd" for a date.
    nonisolated static func isoDay(_ date: Date) -> String { iso(date) }

    /// Parse an ISO "yyyy-MM-dd" day string to a start-of-day Date.
    nonisolated static func dayDate(fromISO s: String) -> Date? { dateFromISO(s) }

}

// MARK: - Unified eligibility predicate (U1 — shared by Search / Intents / ECB)

/// Toggles for the unified cover predicate. The hard PHYSICAL gates (off · qualified ·
/// 8h-rest) are ALWAYS applied; this switches on the soft/policy gates.
struct EligibilityOptions: Sendable, Hashable {
    var applySoftGates: Bool   // wouldPickUp: openness · blacklist · pills · must-be-off · want-to-work
    /// Active searcher / raw physical capacity — hard gates only.
    static let physicalOnly = EligibilityOptions(applySoftGates: false)
    /// Full policy — Search two-way, Intents, ECB broadcast filter.
    static let full = EligibilityOptions(applySoftGates: true)
}

/// Result of a cover check: eligible + whether covering this day is a bookend for the coverer.
struct CoverCheck: Sendable, Hashable {
    let eligible: Bool
    let isBookend: Bool
    static let no = CoverCheck(eligible: false, isBookend: false)
}

/// THE single per-(coverer, day) eligibility test — every matcher path calls this instead
/// of its own inline copy (U1). PURE + synchronous: all roster/profile data is passed in
/// (loaded once per search), so it never fetches and is safe in tight loops at 550-user scale.
nonisolated enum TradeEligibility {
    /// Can `coverProfile` (off-roster `coverMap`, holding `coverQuals`) cover a shift on
    /// `coverDay`/`desk`/`startHour`? Returns eligibility + the computed bookend flag.
    static func canCover(coverDayID: String, coverDay: Date, desk: String, startHour: Int,
                         coverMap: [String: RosterEntry], coverQuals: [String],
                         coverProfile: TradeProfile, options: EligibilityOptions,
                         cal: Calendar = .current) -> CoverCheck {
        // Global gate (SSOT): only a genuine dispatch shift ever trades — never a training (TRN)
        // desk or an irregular start hour. This is a property of the shift itself, so it's checked
        // before any coverer property. Keeps permanent-TRN / off-hour rosters out of every path.
        guard TradeTiming.isDispatchShift(desk: desk, startHour: startHour) else { return .no }
        // Relief dispatcher: their schedule isn't real past the horizon, so they can't cover then.
        if coverProfile.scheduleUnknown(on: coverDay, cal: cal) { return .no }
        // Hard PHYSICAL gates (always): coverer is off that day, qualified for the desk, 8h-rested.
        guard let entry = coverMap[coverDayID], entry.isOff,
              DeskRules.qualified(quals: coverQuals, forDesk: desk),
              TradeMatcher.isRested(map: coverMap, day: coverDay, startHour: startHour, cal: cal)
        else { return .no }
        // Bookend = covering this day attaches to the coverer's existing work (no floating island).
        let bookend = TradeMatcher.isAnchored(day: coverDay, map: coverMap, plan: [coverDayID], cal: cal)

        // Soft policy: openness / blacklist / pills / must-be-off / want-to-work, via the SSOT.
        if options.applySoftGates {
            let weekday = cal.component(.weekday, from: coverDay)
            let region  = DeskRules.region(forDesk: desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: startHour).rawValue
            guard coverProfile.wouldPickUp(onDay: coverDayID, weekday: weekday, desk: desk,
                                           shiftType: type, region: region, isBookend: bookend)
            else { return CoverCheck(eligible: false, isBookend: bookend) }
        }
        return CoverCheck(eligible: true, isBookend: bookend)
    }
}

```

### Appendix F — TradeProfile.swift (openness, blacklists, wouldPickUp — full)

```swift
// TradeProfile.swift
// The cross-user "willingness" layer — the only data that must be shared between
// dispatchers (the airline roster gives schedules + quals locally; this gives
// INTENT). Built from each person's openness + blacklist + the working days they
// want to trade away.
//
// The backend is swappable behind `TradeProfileService`:
//   • `LocalTradeProfileService`   — on-device, free, works today (no account)
//   • `CloudKitTradeProfileService`— public-DB broadcast, added once enrolled
// Nothing in the app depends on which backend is active.

import Foundation
import Observation

/// Shared CloudKit configuration. The container id must EXACTLY match the one
/// checked in Signing & Capabilities → iCloud → CloudKit Containers.
enum CloudKitConfig {
    static let containerID = "iCloud.com.ervinlee.batmanreader"
}

/// G2a: THE single source of a peer's human-readable name, used by every surface so a peer
/// never renders as a bare employee number (the IMG-42 "660615" bug). Prefers a real
/// `displayName` → real roster name → the employee #. A candidate is NOT "real" if it's
/// empty/blank, equals the workerID, or is all-digits.
enum TradeNames {
    static func isAllDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isNumber) }
    static func resolved(displayName: String?, rosterName: String?, workerID: String) -> String {
        for candidate in [displayName, rosterName] {
            let c = candidate?.trimmingCharacters(in: .whitespaces) ?? ""
            if !c.isEmpty, c != workerID, !isAllDigits(c) { return c }
        }
        return workerID
    }
}

/// Thread-safe "do this once" gate (used to resume a continuation exactly once).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - Willingness category

/// How willing a candidate is to COVER your shift (one-way), derived from their
/// published profile. The gold 🔥 highlight is separate (mutual-intent count).
enum TradeWillingness: Sendable, Hashable {
    case willing    // opted in and accepts at least one of the shifts
    case unknown    // no published profile yet (hasn't adopted/opted in) → "?"
    case declined   // opted in but won't take any of these — excluded from display

    /// Sort priority (lower = shown first).
    var rank: Int {
        switch self {
        case .willing: return 0
        case .unknown: return 1
        case .declined: return 2
        }
    }
}

// MARK: - Model

/// One dispatcher's published trade intent. Sendable + Codable so it can cross
/// actors and serialize to UserDefaults today / CloudKit later.
struct TradeProfile: Sendable, Hashable, Codable, Identifiable {
    let workerID: String                    // employee ID — the match key
    let displayName: String
    let openness: String                    // TradeOpenness rawValue
    let blacklistedWeekdays: Set<Int>       // 1 = Sun … 7 = Sat
    let blacklistedDesks: Set<String>
    let blacklistedShiftTypes: Set<String>  // "AM" / "PM" / "MID"
    let blacklistedRegions: Set<String>     // DeskRegion rawValues
    let seekingDayIDs: Set<String>          // working days they actively want to give away
    let updatedAt: Date
    // Contact (optional; group shares these). Optional so older records still decode.
    var personalEmail: String? = nil
    var aaEmail: String? = nil
    var phone: String? = nil
    // v2 trade rules (all optional so older records still decode).
    var statusBroadcast: String? = nil
    var isMercenaryMode: Bool? = nil
    /// True ONLY when this profile was published by a real, signed-in account (see `publishMine`).
    /// Legacy/orphan CloudKit records lack it (nil) → treated as "not on the app" (🤖, can't be messaged).
    var accountClaimed: Bool? = nil
    // Per-day availability pills, published so matching is pill-based cross-user.
    // Each entry is "ISO|TYPE", e.g. "2026-07-04|AM". Optional so old records decode.
    var availabilitySlots: [String]? = nil
    // ISO days whose effective openness is "bookends" (base or a date-range override),
    // so peers can apply the no-split gate per-day. nil = fall back to opennessLevel.
    var bookendDays: [String]? = nil
    // NEGATIVE intents, published so the matcher can hard-exclude them cross-user
    // (SPEC S-ENG-9/10). Without these the matcher never sees a Must-Be-Off day and
    // wrongly offers it (the June-23 bug). All optional ⇒ old records still decode.
    var mustBeOffDayIDs: Set<String>? = nil   // off days they refuse to be asked to work
    var keepDayIDs: Set<String>? = nil        // working days they refuse to trade away
    var wantToWorkDayIDs: Set<String>? = nil  // off days they actively want to work (overrides bookend gate, S-ENG-10)
    // Qual-swap preference VALUES (Q4). Set POST-init (not in the explicit init) to avoid
    // churning the init symbol. qual code → preference value: HIGHER = more preferred.
    // 0 = blacklisted (never accept that qual). A qual ABSENT from the map = no preference
    // = fully open (treated as the highest value). nil map = open to everything.
    var qualValues: [String: Int]? = nil
    // Specific DESK NUMBERS the user will never qual-swap into, regardless of qual value.
    var qualSwapBlacklistDesks: Set<String>? = nil
    // Relief dispatcher: last date this person's schedule is REAL. nil = not a relief dispatcher.
    // Published so EVERY peer's matcher ignores their bogus post-relief shifts. Set post-init.
    var reliefThrough: Date? = nil
    // Cross-device-only PREFERENCES (never used by peers' matchers) — carried on the profile purely so a
    // user's own devices converge. Set post-init; all optional so old records decode.
    var opennessOverrides: [OpennessOverride]? = nil   // date-range openness overrides
    var notificationLeadHours: Int? = nil              // hours before a shift the reminder fires
    var dailyDigestEnabled: Bool? = nil                // once-a-day summary on/off
    var dailyDigestHour: Int? = nil                    // hour (0–23) the summary fires

    // EXPLICIT init — this REPLACES Swift's synthesized memberwise init and FREEZES the
    // construction signature. Adding a NEW optional published field above does NOT change
    // this init, so callers' compiled object files stay valid — preventing the stale
    // "Undefined symbol: TradeProfile.init(…old signature…)" linker error. New optional
    // fields are set via assignment after construction, NOT added here.
    init(workerID: String, displayName: String, openness: String,
         blacklistedWeekdays: Set<Int>, blacklistedDesks: Set<String>,
         blacklistedShiftTypes: Set<String>, blacklistedRegions: Set<String>,
         seekingDayIDs: Set<String>, updatedAt: Date,
         personalEmail: String? = nil, aaEmail: String? = nil, phone: String? = nil,
         statusBroadcast: String? = nil,
         isMercenaryMode: Bool? = nil, availabilitySlots: [String]? = nil, bookendDays: [String]? = nil,
         mustBeOffDayIDs: Set<String>? = nil, keepDayIDs: Set<String>? = nil, wantToWorkDayIDs: Set<String>? = nil) {
        self.workerID = workerID; self.displayName = displayName; self.openness = openness
        self.blacklistedWeekdays = blacklistedWeekdays; self.blacklistedDesks = blacklistedDesks
        self.blacklistedShiftTypes = blacklistedShiftTypes; self.blacklistedRegions = blacklistedRegions
        self.seekingDayIDs = seekingDayIDs; self.updatedAt = updatedAt
        self.personalEmail = personalEmail; self.aaEmail = aaEmail; self.phone = phone
        self.statusBroadcast = statusBroadcast
        self.isMercenaryMode = isMercenaryMode; self.availabilitySlots = availabilitySlots; self.bookendDays = bookendDays
        self.mustBeOffDayIDs = mustBeOffDayIDs; self.keepDayIDs = keepDayIDs; self.wantToWorkDayIDs = wantToWorkDayIDs
    }

    /// A8: THE single fabricated profile for a peer who hasn't published one. Defaults to
    /// **Bookends Only** (conservative) so a profileless dispatcher is never offered a
    /// non-bookend (split-the-weekend) pickup until they opt into broader trading. `updatedAt`
    /// is the epoch so any real published profile always wins last-write-wins.
    static func defaultForUnpublished(workerID: String, name: String,
                                      inferredShiftTypes: Set<String>? = nil,
                                      inferredRegions: Set<String>? = nil,
                                      blacklistWeekends: Bool = false) -> TradeProfile {
        // B4-5: if we've inferred what they actually work (last 60d), hard-blacklist the COMPLEMENT so a
        // profileless peer is only offered shift types / regions / weekdays they've been working. A real
        // published profile always wins LWW (`updatedAt` stays epoch).
        let blShiftTypes = inferredShiftTypes.map {
            Set(ShiftAvailabilityType.allCases.map(\.rawValue)).subtracting($0)
        } ?? []
        let blRegions = inferredRegions.map {
            Set(DeskRegion.allCases.map(\.rawValue)).subtracting($0)
        } ?? []
        let blWeekdays: Set<Int> = blacklistWeekends ? [1, 7] : []   // Sun + Sat
        return TradeProfile(workerID: workerID, displayName: name,
                     openness: TradeOpenness.bookends.rawValue,
                     blacklistedWeekdays: blWeekdays, blacklistedDesks: [],
                     blacklistedShiftTypes: blShiftTypes, blacklistedRegions: blRegions,
                     seekingDayIDs: [], updatedAt: Date(timeIntervalSince1970: 0))
    }

    /// A copy of this profile with a one-time OPENNESS override (used by the "I'm Feeling Lucky" openness
    /// dropdown). Drops the per-day availability pills + bookend-day list so the chosen level governs purely
    /// (`.all` = any eligible off day, `.bookends` = bookend days only). Blacklist and protective intents
    /// (Must-Be-Off / Keep) are PRESERVED — openness ≠ blacklist. Mercenary is cleared so the level wins.
    func withOpenness(_ level: TradeOpenness) -> TradeProfile {
        var p = TradeProfile(workerID: workerID, displayName: displayName, openness: level.rawValue,
                             blacklistedWeekdays: blacklistedWeekdays, blacklistedDesks: blacklistedDesks,
                             blacklistedShiftTypes: blacklistedShiftTypes, blacklistedRegions: blacklistedRegions,
                             seekingDayIDs: seekingDayIDs, updatedAt: updatedAt,
                             personalEmail: personalEmail, aaEmail: aaEmail, phone: phone,
                             statusBroadcast: statusBroadcast, isMercenaryMode: nil,
                             availabilitySlots: nil, bookendDays: nil,
                             mustBeOffDayIDs: mustBeOffDayIDs, keepDayIDs: keepDayIDs, wantToWorkDayIDs: wantToWorkDayIDs)
        p.accountClaimed = accountClaimed
        p.qualValues = qualValues
        p.qualSwapBlacklistDesks = qualSwapBlacklistDesks
        p.reliefThrough = reliefThrough
        return p
    }

    var id: String { workerID }
    var bookendDaySet: Set<String> { Set(bookendDays ?? []) }
    var bestEmail: String? {
        let p = personalEmail?.trimmingCharacters(in: .whitespaces) ?? ""
        let a = aaEmail?.trimmingCharacters(in: .whitespaces) ?? ""
        return !p.isEmpty ? p : (a.isEmpty ? nil : a)
    }
    var opennessLevel: TradeOpenness { TradeOpenness(rawValue: openness) ?? .bookends }

    /// Whether this person would CONSIDER picking up a shift with these traits —
    /// i.e. they're accepting trades and it isn't on their blacklist. (Physical
    /// ability — off + qualified + rested — is checked separately by the matcher;
    /// the per-day bookends-only nuance of `.bookends` is applied there too.)
    func acceptsPickup(weekday: Int, desk: String, shiftType: String, region: String) -> Bool {
        guard opennessLevel != .none else { return false }
        return passesBlacklist(weekday: weekday, desk: desk, shiftType: shiftType, region: region)
    }

    /// Blacklist gate only (no openness).
    func passesBlacklist(weekday: Int, desk: String, shiftType: String, region: String) -> Bool {
        if blacklistedWeekdays.contains(weekday) { return false }
        if blacklistedDesks.contains(desk) { return false }
        if blacklistedShiftTypes.contains(shiftType) { return false }
        if blacklistedRegions.contains(region) { return false }
        return true
    }

    /// ISO day → published availability types (parsed from `availabilitySlots`).
    var availabilityMap: [String: Set<ShiftAvailabilityType>] {
        guard let slots = availabilitySlots else { return [:] }
        var m: [String: Set<ShiftAvailabilityType>] = [:]
        for s in slots {
            let parts = s.split(separator: "|")
            if parts.count == 2, let t = ShiftAvailabilityType(rawValue: String(parts[1])) {
                m[String(parts[0]), default: []].insert(t)
            }
        }
        return m
    }

    /// True only when the user has actually published per-day pills (≥ 1 slot).
    var hasPublishedAvailability: Bool { !(availabilitySlots?.isEmpty ?? true) }

    /// PURE: is `day` past this person's relief horizon (their schedule isn't real there)?
    /// False when they aren't a relief dispatcher (nil horizon). The horizon date is inclusive.
    static func isPastRelief(day: Date, reliefThrough: Date?, cal: Calendar = .current) -> Bool {
        guard let rt = reliefThrough else { return false }
        return cal.startOfDay(for: day) > cal.startOfDay(for: rt)
    }
    /// Instance form: is `day` past THIS profile's relief horizon?
    func scheduleUnknown(on day: Date, cal: Calendar = .current) -> Bool {
        Self.isPastRelief(day: day, reliefThrough: reliefThrough, cal: cal)
    }

    /// Q4: would this person accept moving INTO `newDesk` (off their `currentDesk`)
    /// for a qual swap, given their preference values?
    func acceptsQualSwap(into newDesk: String, fromCurrentDesk currentDesk: String) -> Bool {
        DeskRules.acceptsQualSwap(into: newDesk, fromCurrentDesk: currentDesk,
                                  values: qualValues, blacklistDesks: qualSwapBlacklistDesks)
    }

    /// Whether this person would take a pickup on a SPECIFIC day. Uses published
    /// per-day availability pills when present; falls back to openness otherwise.
    func wouldPickUp(onDay dayID: String, weekday: Int, desk: String,
                     shiftType: String, region: String, isBookend: Bool) -> Bool {
        // Hard disqualifier (SPEC S-ENG-9/10): a day marked Must-Be-Off is NEVER
        // offered — even under mercenary. This is the June-23 "offered as You Take" fix.
        if mustBeOffDayIDs?.contains(dayID) == true { return false }
        guard passesBlacklist(weekday: weekday, desk: desk, shiftType: shiftType, region: region) else { return false }
        // Mercenary mode: take ANY qualifying shift — ignore availability pills,
        // openness, and bookend protection (the hard legal gates still apply
        // outside this method: off + qualified + 8h rest + weekly cap).
        if isMercenaryMode == true { return true }
        // Want-to-Work OVERRIDES the bookend requirement for THIS person (S-ENG-10):
        // they explicitly want this day regardless of contiguity. Does NOT override
        // blacklist (above) or per-day availability (the pill gate below).
        let isWantToWork = wantToWorkDayIDs?.contains(dayID) == true
        if hasPublishedAvailability {
            guard let t = ShiftAvailabilityType(rawValue: shiftType),
                  availabilityMap[dayID]?.contains(t) == true else { return false }
            let bookendGated = bookendDays != nil ? bookendDaySet.contains(dayID)
                                                  : (opennessLevel == .bookends)
            if bookendGated, !isBookend, !isWantToWork { return false }
            return true
        }
        guard opennessLevel != .none else { return false }
        return opennessLevel == .all || isBookend || isWantToWork
    }

    /// Classify a candidate's willingness to COVER the shifts they can physically
    /// take. `.bookends` openness only accepts their bookend days; `.all` accepts
    /// any. No profile → `.unknown`; accepts none → `.declined`; else `.willing`.
    static func classify(coveredShifts: [Shift], bookendIDs: Set<String>,
                         profile: TradeProfile?) -> TradeWillingness {
        guard let profile else { return .unknown }
        let cal = Calendar.current
        let accepts = coveredShifts.contains { s in
            let weekday = cal.component(.weekday, from: s.date)
            let region  = DeskRules.region(forDesk: s.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: s.startHour).rawValue
            let opennessOK = profile.opennessLevel == .all || bookendIDs.contains(s.id)
            return opennessOK && profile.acceptsPickup(weekday: weekday, desk: s.desk,
                                                        shiftType: type, region: region)
        }
        return accepts ? .willing : .declined
    }
}

// MARK: - Service abstraction

/// The swappable backend. Local today, CloudKit public DB once enrolled.
protocol TradeProfileService: Sendable {
    func publish(_ profile: TradeProfile) async
    func fetchAll() async -> [TradeProfile]
    func profile(forWorker workerID: String) async -> TradeProfile?
}

/// On-device stand-in: persists profiles to UserDefaults. Lets the entire
/// matching pipeline + UI be built and tested with no account or sync. `seed`
/// injects synthetic peer profiles for local testing of one-way / two-way flows.
actor LocalTradeProfileService: TradeProfileService {
    private static let key = "batman.localTradeProfiles"
    private var cache: [String: TradeProfile]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: TradeProfile].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func publish(_ profile: TradeProfile) async {
        cache[profile.workerID] = profile
        save()
    }

    func fetchAll() async -> [TradeProfile] { Array(cache.values) }

    func profile(forWorker workerID: String) async -> TradeProfile? { cache[workerID] }

    /// Add peer profiles without overwriting real ones (test scaffolding).
    func seed(_ profiles: [TradeProfile]) async {
        for p in profiles where cache[p.workerID] == nil { cache[p.workerID] = p }
        save()
    }

    /// Wipe all stored profiles (test scaffolding).
    func reset() async {
        cache = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Main-actor facade

/// Owns the active backend, builds + publishes YOUR profile from local prefs,
/// and caches everyone else's for the matcher/UI.
@MainActor
@Observable
final class TradeProfileStore {

    static let shared = TradeProfileStore()

    /// Active backend — CloudKit public DB when iCloud sync is on, else local.
    private var service: TradeProfileService

    /// Other dispatchers' profiles, keyed by employee ID. Empty until refreshed.
    private(set) var others: [String: TradeProfile] = [:]

    private init() {
        service = SettingsManager.shared.useCloudKit
            ? CloudKitTradeProfileService()
            : LocalTradeProfileService()
    }

    /// Switch the backend when the iCloud-sync toggle changes, then re-publish
    /// your profile and refresh everyone else's from the new source.
    func setCloudKit(_ on: Bool) async {
        service = on ? CloudKitTradeProfileService() : LocalTradeProfileService()
        await publishMine()
        await refreshOthers()
    }

    /// Your current profile, assembled from settings + seeking marks.
    func myProfile() -> TradeProfile {
        let s = SettingsManager.shared
        var p = TradeProfile(
            workerID:              s.username,
            displayName:           s.displayName.isEmpty ? s.username : s.displayName,
            openness:              s.tradeOpenness,
            blacklistedWeekdays:   s.blacklistedWeekdays,
            blacklistedDesks:      s.blacklistedDesks,
            blacklistedShiftTypes: s.blacklistedShiftTypes,
            blacklistedRegions:    s.blacklistedRegions,
            seekingDayIDs:         DayIntentStore.shared.seekingDayIDs,
            updatedAt:             Date(),
            personalEmail:         s.personalEmail.isEmpty ? nil : s.personalEmail,
            aaEmail:               s.aaEmail.isEmpty ? nil : s.aaEmail,
            phone:                 s.phone.isEmpty ? nil : s.phone,
            statusBroadcast:       s.statusBroadcast.isEmpty ? nil : s.statusBroadcast,
            isMercenaryMode:       s.isMercenaryMode,
            availabilitySlots:     DayIntentStore.shared.offAvailability.flatMap { day, types in
                types.map { "\(day)|\($0.rawValue)" }
            },
            bookendDays:           DayIntentStore.shared.bookendGatedDays(
                base: TradeOpenness(rawValue: s.tradeOpenness) ?? .bookends,
                shifts: ShiftStore.shared.shifts),
            mustBeOffDayIDs:       DayIntentStore.shared.mustBeOffDayIDs,
            keepDayIDs:            DayIntentStore.shared.keepDayIDs,
            wantToWorkDayIDs:      DayIntentStore.shared.wantToWorkDayIDs
        )
        // Qual-swap preference values (Q4) — set post-init to keep the init symbol stable.
        p.qualValues = s.qualValues.isEmpty ? nil : s.qualValues
        p.qualSwapBlacklistDesks = s.qualSwapBlacklistDesks.isEmpty ? nil : s.qualSwapBlacklistDesks
        p.reliefThrough = s.effectiveReliefThrough   // nil unless relief toggled ON + dated
        // Cross-device-only prefs (carried so the user's own devices converge; peers ignore these).
        p.opennessOverrides    = s.opennessOverrides.isEmpty ? nil : s.opennessOverrides
        p.notificationLeadHours = s.notificationLeadHours
        p.dailyDigestEnabled   = s.dailyDigestEnabled
        p.dailyDigestHour      = s.dailyDigestHour
        // Proof this profile belongs to a real, signed-in account (not a legacy/orphan cloud record).
        p.accountClaimed = s.appleUserID.isEmpty ? nil : true
        return p
    }

    /// Push your latest profile to the backend.
    func publishMine() async {
        await service.publish(myProfile())
    }

    /// Refresh the local cache of everyone else's profiles.
    func refreshOthers() async {
        let all  = await service.fetchAll()
        let myID = SettingsManager.shared.username
        let fetched = all.filter { $0.workerID != myID }
        // P0/R-A: a transient empty fetch must not wipe the visible roster of peers.
        let merged = FetchMerge.keepCacheOnEmpty(existing: Array(others.values), fetched: fetched)
        others = Dictionary(uniqueKeysWithValues: merged.map { ($0.workerID, $0) })
    }

    /// A3: restore the user's public STATUS from their own published profile on a fresh device,
    /// last-write-wins against the local edit clock. Call at launch.
    func syncMyStatus() async {
        let myID = SettingsManager.shared.username
        guard !myID.isEmpty,
              let mine = await service.fetchAll().first(where: { $0.workerID == myID }) else { return }
        let s = SettingsManager.shared
        let resolved = LWW.pick(local: s.statusBroadcast, localAt: s.statusUpdatedAt ?? .distantPast,
                                remote: mine.statusBroadcast ?? "", remoteAt: mine.updatedAt)
        if resolved != s.statusBroadcast {
            s.statusBroadcast = resolved          // didSet bumps statusUpdatedAt → corrected below
            s.statusUpdatedAt = mine.updatedAt
        }
    }

    /// Restore the user's TRADE PREFERENCES (openness, blacklists, mercenary, qual values) from their
    /// own published profile — the fix for prefs not syncing across a user's devices. LWW by the local
    /// prefs clock. MUST run at launch BEFORE `publishMine()`, so a device that just launched can't
    /// overwrite the cloud with its stale prefs and clobber the other device's newer edit.
    func syncMyPreferences() async {
        let s = SettingsManager.shared
        guard s.useCloudKit, !s.username.isEmpty else { return }
        // FAILSAFE 1 (empty/failed fetch): a transient network blip returns [], so `.first` is nil and we
        // no-op — a failed pull can never wipe local prefs.
        guard let mine = await service.fetchAll().first(where: { $0.workerID == s.username }) else { return }
        // FAILSAFE 2 (legacy/orphan record): only adopt from a real, signed-in account. A stray cloud
        // record with default/empty prefs must never overwrite the user's real local settings, even if
        // its clock looks newer.
        guard mine.accountClaimed == true else { return }
        guard mine.updatedAt > (s.prefsUpdatedAt ?? .distantPast) else { return }   // adopt only when strictly newer
        s.tradeOpenness          = mine.openness
        s.blacklistedWeekdays    = mine.blacklistedWeekdays
        s.blacklistedDesks       = mine.blacklistedDesks
        s.blacklistedShiftTypes  = mine.blacklistedShiftTypes
        s.blacklistedRegions     = mine.blacklistedRegions
        s.qualValues             = mine.qualValues ?? [:]
        s.qualSwapBlacklistDesks = mine.qualSwapBlacklistDesks ?? []
        // Relief-dispatcher window: published in the profile but previously not restored. It hides shifts
        // past the relief date from calendar + trading, so it must match across the user's devices.
        s.isReliefDispatcher     = (mine.reliefThrough != nil)
        s.reliefScheduleThrough  = mine.reliefThrough
        // Contact info the user typed once — carry it to their other devices.
        if let e = mine.personalEmail, !e.isEmpty { s.personalEmail = e }
        if let e = mine.aaEmail,       !e.isEmpty { s.aaEmail = e }
        if let ph = mine.phone,        !ph.isEmpty { s.phone = ph }
        // Date-range openness overrides — a real trade decision, must follow the user across devices.
        s.opennessOverrides      = mine.opennessOverrides ?? []
        // Notification settings — adopt, then re-schedule locally so both devices alert identically
        // (avoids two lead-times / a digest firing on one device only).
        let notifChanged = (mine.notificationLeadHours != nil && mine.notificationLeadHours != s.notificationLeadHours)
            || (mine.dailyDigestEnabled != nil && mine.dailyDigestEnabled != s.dailyDigestEnabled)
            || (mine.dailyDigestHour != nil && mine.dailyDigestHour != s.dailyDigestHour)
        if let lead = mine.notificationLeadHours { s.notificationLeadHours = lead }
        if let dd = mine.dailyDigestEnabled { s.dailyDigestEnabled = dd }
        if let dh = mine.dailyDigestHour { s.dailyDigestHour = dh }
        s.isMercenaryMode        = mine.isMercenaryMode ?? false // last: its didSet enforces the openness invariant
        s.prefsUpdatedAt         = mine.updatedAt                // adopt the remote stamp so we don't re-adopt
        if notifChanged { await Self.rescheduleNotifications() }
    }

    /// Re-schedule shift reminders + the daily digest from the CURRENT settings — run after adopting
    /// notification prefs from another device so alerts match everywhere.
    @MainActor
    static func rescheduleNotifications() async {
        let s = SettingsManager.shared
        await NotificationManager.shared.scheduleAll(for: ShiftStore.shared.shifts)
        let m = MessagingStore.shared
        let c = DashboardCounts.from(requests: m.requests, responses: m.responses,
                                     unread: m.pendingIncoming.count,
                                     pendingLedger: TradeHistoryStore.shared.pendingCount)
        await NotificationManager.shared.scheduleDailyDigest(
            enabled: s.dailyDigestEnabled, hour: s.dailyDigestHour, pending: c.pending, unread: c.unread)
    }

    func profile(forWorker workerID: String) -> TradeProfile? { others[workerID] }

    /// Is this worker a REAL, on-the-app account — not just a legacy/orphan profile record? You are
    /// always active. A peer is active ONLY if their published profile is stamped `accountClaimed`
    /// (set on real signup/publish). This is what drives the 🤖 marker + the "can't message" gate.
    func isActiveAccount(_ workerID: String) -> Bool {
        if workerID == SettingsManager.shared.username { return true }
        return others[workerID]?.accountClaimed == true
    }

    private static let isoDayF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// Dispatchers whose PUBLISHED v2 profile says they'd take a pickup on `date`
    /// (optionally of `type`) — the same availability pills / openness the in-app
    /// matcher uses, so Siri/Shortcuts results match what the app would surface.
    /// Returns (profile, shift-type) pairs, deterministically ordered.
    func availableDispatchers(on date: Date, type: ShiftAvailabilityType?) -> [(profile: TradeProfile, type: ShiftAvailabilityType)] {
        let iso = Self.isoDayF.string(from: date)
        var out: [(TradeProfile, ShiftAvailabilityType)] = []
        for (_, p) in others.sorted(by: { $0.key < $1.key }) {
            guard p.opennessLevel != .none else { continue }
            // Published pills are authoritative; with no pills, openness ".all" means
            // any legal type. (".bookends" without pills is ambiguous off-app, so we
            // surface it as a candidate and let the in-app two-way sheet confirm.)
            let types: [ShiftAvailabilityType] = p.hasPublishedAvailability
                ? (p.availabilityMap[iso].map { Array($0) } ?? [])
                : ShiftAvailabilityType.allCases
            for t in types.sorted(by: { $0.rawValue < $1.rawValue }) where type == nil || t == type {
                if p.blacklistedShiftTypes.contains(t.rawValue) { continue }
                out.append((p, t))
            }
        }
        return out
    }

    /// Cached profile if present, else fetch the single record from the backend
    /// (used by the inbox/two-way to show a person's contact info).
    func fetchProfile(forWorker workerID: String) async -> TradeProfile? {
        if let p = others[workerID] { return p }
        if let p = await service.profile(forWorker: workerID) {
            others[p.workerID] = p
            return p
        }
        return nil
    }

    #if DEBUG
    /// Seed synthetic peer profiles so one-way/two-way flows can be exercised
    /// before CloudKit exists.
    func seedPeers(_ profiles: [TradeProfile]) async {
        if let local = service as? LocalTradeProfileService {
            await local.seed(profiles)
            await refreshOthers()
        }
    }

    /// Build synthetic peer profiles from the loaded roster (varied openness +
    /// some actively-seeking days) so willingness filtering is demonstrable now.
    /// Returns the number of peer profiles seeded.
    @discardableResult
    func seedFromRoster() async -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let upper = cal.date(byAdding: .day, value: 120, to: today) else { return 0 }
        let entries = await RosterStore.shared.entries(from: today, to: upper)
        guard !entries.isEmpty else { return 0 }

        var byWorker: [String: [RosterEntry]] = [:]
        for e in entries { byWorker[e.workerID, default: []].append(e) }

        let myID = SettingsManager.shared.username
        var profiles: [TradeProfile] = []
        var i = 0
        for (wid, es) in byWorker where wid != myID {
            i += 1
            // Vary openness: every 5th declines, else alternate all/bookends.
            let openness: TradeOpenness = (i % 5 == 0) ? .none : (i % 2 == 0 ? .all : .bookends)
            // Every 3rd actively seeks to give away a few of their working days.
            var seeking = Set<String>()
            if i % 3 == 0 {
                seeking = Set(es.filter { !$0.isOff }.prefix(3).map { $0.day })
            }
            profiles.append(TradeProfile(
                workerID: wid, displayName: es.first?.workerName ?? wid,
                openness: openness.rawValue,
                blacklistedWeekdays: [], blacklistedDesks: [],
                blacklistedShiftTypes: [], blacklistedRegions: [],
                seekingDayIDs: seeking, updatedAt: Date()))
        }
        await seedPeers(profiles)
        return profiles.count
    }

    /// Build a guaranteed mutual-bookend match: marks one of YOUR work days and
    /// seeds a peer who wants a day you can cover — so 🔥×1 shows up. Returns the
    /// peer's name, or nil if the roster has no qualifying pair.
    func seedGuaranteedMutual() async -> (name: String, giveDay: String)? {
        let myID = SettingsManager.shared.username
        guard let seed = await TradeMatcher.findMutualBookendPair(excluding: myID) else { return nil }
        TradeIntentStore.shared.seekingDayIDs.insert(seed.myGiveDayID)
        let peer = TradeProfile(
            workerID: seed.peerID, displayName: seed.peerName, openness: TradeOpenness.all.rawValue,
            blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [], blacklistedRegions: [],
            seekingDayIDs: [seed.theirTakeDayID], updatedAt: Date())
        await service.publish(peer)
        await publishMine()
        await refreshOthers()
        return (seed.peerName, seed.myGiveDayID)
    }

    /// Run a CloudKit health check (account + write/read round-trip). Uses a
    /// continuation race so a hung CloudKit call is ABANDONED at the timeout
    /// instead of blocking forever (a TaskGroup would await the hung child).
    func checkCloudKit() async -> String {
        guard let ck = service as? CloudKitTradeProfileService else {
            return "iCloud Trade Sync is OFF — turn it on in Settings first, then re-check."
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let once = OnceFlag()
            Task {
                let result = await ck.diagnose()
                if once.set() { cont.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if once.set() {
                    cont.resume(returning: "CloudKit timed out (12s) — the call never returned. Almost always: the container isn't in THIS build's provisioning profile. Fix: delete the app from the device, then rebuild/reinstall from Xcode so the profile regenerates with the container. Also confirm you're signed into iCloud.")
                }
            }
        }
    }

    /// Clear all peer profiles (test scaffolding).
    func resetPeers() async {
        if let local = service as? LocalTradeProfileService {
            await local.reset()
            await publishMine()        // keep your own profile present
            await refreshOthers()
        }
    }
    #endif
}

```

---

*Assembled from the live repo. If a symbol referenced in §1–§5 is not in these appendices, ask for it — do not assume its behavior.*

### Appendix G — EngineTests.swift (the regression harness; `runAll()` returns only failures — empty == pass)

```swift
// EngineTests.swift
// A runnable self-test harness for the trade engine. There's no XCTest target, so
// these are plain assertions invokable from Developer Tools (Settings → Developer →
// "Run engine tests"). Returns the list of failures ([] = all pass). Covers the
// risky, pure logic: min-cost flow, the optimal reciprocal matcher (golden cases,
// balance, determinism, infeasibility), holiday math, and the pickup gate.

import Foundation
import SwiftData

#if DEBUG   // Z1: the self-test harness ships in DEBUG only — excluded from Release/TestFlight builds.

@MainActor
enum TradeEngineTests {

    static func runAll() -> [String] {
        var fails: [String] = []
        func check(_ cond: Bool, _ msg: String) { if !cond { fails.append("❌ \(msg)") } }

        // MARK: Min-cost flow — a tiny known instance.
        do {
            var mcf = MinCostFlow(nodes: 4)
            mcf.addEdge(0, 1, cap: 1, cost: 0)
            mcf.addEdge(1, 2, cap: 1, cost: 5)
            mcf.addEdge(2, 3, cap: 1, cost: 0)
            let (f, c) = mcf.run(from: 0, to: 3)
            check(f == 1 && c == 5, "MCF basic: expected flow 1 cost 5, got \(f)/\(c)")

            // Two parallel paths, cheaper first.
            var m2 = MinCostFlow(nodes: 4)
            m2.addEdge(0, 1, cap: 2, cost: 0)
            m2.addEdge(1, 3, cap: 1, cost: 1)   // cheap
            m2.addEdge(1, 3, cap: 1, cost: 10)  // expensive
            let (f2, c2) = m2.run(from: 0, to: 3)
            check(f2 == 2 && c2 == 11, "MCF two-path: expected flow 2 cost 11, got \(f2)/\(c2)")
        }

        // MARK: Optimal reciprocal matcher.
        let A = OptimalMatcher.Cand(id: "001", name: "A", canTake: ["d1", "d2"], givesBack: ["x1", "x2"])
        let B = OptimalMatcher.Cand(id: "002", name: "B", canTake: ["d1"], givesBack: ["y1"])
        let C = OptimalMatcher.Cand(id: "003", name: "C", canTake: ["d2"], givesBack: ["z1"])

        let one = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [A, B, C])
        check(one?.count == 1, "Optimal: 1-person cover preferred over 2, got \(String(describing: one?.count))")
        check(balanced(one), "Optimal: balanced give==take")

        let split = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [B, C])
        check(split?.count == 2, "Optimal: 2-person split when no single covers both")

        let infeasible = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [B])
        check(infeasible == nil, "Optimal: infeasible (d2 uncoverable) → nil")

        let unbalanced = OptimalMatcher.Cand(id: "001", name: "A", canTake: ["d1", "d2"], givesBack: ["x1"])
        let ub = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [unbalanced])
        check(ub == nil, "Optimal: give 2 / back 1 with one peer is unbalanced → nil")

        let r1 = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [B, C, A])
        let r2 = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [A, C, B])
        check(r1?.map(\.id).sorted() == r2?.map(\.id).sorted(), "Optimal: deterministic across peer order")

        // Contiguity gate (the no-split rule shared by the optimal AND greedy paths):
        // a validator that rejects every assignment must yield NO solution — a
        // break-fragmenting package is never emitted.
        let blocked = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [A, B, C],
                                                         contiguous: { _ in false })
        check(blocked == nil, "Contiguity: rejecting validator → nil (never split a break)")
        let allowed = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [A, B, C],
                                                         contiguous: { _ in true })
        check(allowed?.count == 1, "Contiguity: permissive validator still returns the 1-person cover")

        // MARK: Holiday math (2026).
        let h = Holidays.map(year: 2026)
        check(h["2026-01-01"] == "New Year's Day", "Holiday: New Year 2026")
        check(h["2026-01-19"] == "Martin Luther King Day", "Holiday: MLK 2026 = 3rd Mon Jan (Jan 19)")
        check(h["2026-02-16"] == "Presidents Day", "Holiday: Presidents 2026 = 3rd Mon Feb")
        check(h["2026-04-03"] == "Good Friday", "Holiday: Good Friday 2026 (Easter Apr 5)")
        check(h["2026-05-25"] == "Memorial Day", "Holiday: Memorial 2026 = last Mon May")
        check(h["2026-09-07"] == "Labor Day", "Holiday: Labor 2026 = 1st Mon Sep")
        check(h["2026-11-26"] == "Thanksgiving Day", "Holiday: Thanksgiving 2026 = 4th Thu Nov")
        check(h["2026-11-27"] == "Day after Thanksgiving", "Holiday: Day-after 2026")
        check(h["2026-12-25"] == "Christmas Day", "Holiday: Christmas 2026")

        // MARK: Pickup gate (wouldPickUp) — bookends + mercenary.
        var prof = TradeProfile(workerID: "001", displayName: "A", openness: "bookends",
                                blacklistedWeekdays: [], blacklistedDesks: [],
                                blacklistedShiftTypes: [], blacklistedRegions: [],
                                seekingDayIDs: [], updatedAt: Date.distantPast)
        check(prof.wouldPickUp(onDay: "2026-07-04", weekday: 7, desk: "29", shiftType: "AM", region: "Domestic", isBookend: false) == false,
              "wouldPickUp: bookends rejects non-bookend")
        check(prof.wouldPickUp(onDay: "2026-07-04", weekday: 7, desk: "29", shiftType: "AM", region: "Domestic", isBookend: true) == true,
              "wouldPickUp: bookends accepts bookend")
        prof.isMercenaryMode = true
        check(prof.wouldPickUp(onDay: "x", weekday: 1, desk: "29", shiftType: "AM", region: "Domestic", isBookend: false) == true,
              "wouldPickUp: mercenary takes any qualifying shift")
        prof.isMercenaryMode = false

        // Blacklist always blocks (even mercenary off).
        var bl = prof
        bl.isMercenaryMode = true
        let blProf = TradeProfile(workerID: "001", displayName: "A", openness: "all",
                                  blacklistedWeekdays: [], blacklistedDesks: ["29"],
                                  blacklistedShiftTypes: [], blacklistedRegions: [],
                                  seekingDayIDs: [], updatedAt: Date.distantPast)
        check(blProf.wouldPickUp(onDay: "x", weekday: 1, desk: "29", shiftType: "AM", region: "Domestic", isBookend: true) == false,
              "wouldPickUp: blacklisted desk blocked")

        // MARK: Intent preservation on master re-import (SPEC S-PARSE-2 / S-TEST-2 #2).
        // The invariant the old `reconcile(withShifts:)` broke: an UNCHANGED day must
        // never be reset; only added/removed/changed days are.
        func day(_ iso: String, off: Bool) -> Shift {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
            let d = f.date(from: iso) ?? Date(timeIntervalSince1970: 0)
            return off ? Shift(id: iso, date: d, startHour: 0, endHour: 0, role: .off, desk: "", leaveCode: nil, isOff: true)
                       : Shift(id: iso, date: d, startHour: 5, endHour: 14, role: .dispatcher, desk: "29", leaveCode: nil, isOff: false)
        }
        // 07-01 unchanged(work); 07-02 work→off (changed); 07-03 unchanged(off); 07-04 added.
        let oldS = [day("2026-07-01", off: false), day("2026-07-02", off: false), day("2026-07-03", off: true)]
        let newS = [day("2026-07-01", off: false), day("2026-07-02", off: true),
                    day("2026-07-03", off: true),  day("2026-07-04", off: false)]
        let (reset, gone) = DayIntentStore.reconcileTargets(diff: .compute(old: oldS, new: newS))
        check(!reset.contains("2026-07-01"), "reconcile: unchanged WORKING day must NOT reset (the wipe bug)")
        check(!reset.contains("2026-07-03"), "reconcile: unchanged OFF day must NOT reset")
        check(reset.contains("2026-07-02"),  "reconcile: flipped day IS reset")
        check(reset.contains("2026-07-04"),  "reconcile: added day IS reset")
        check(gone.isEmpty,                  "reconcile: nothing removed in this diff")
        // Removed day: reset AND note-dropping (gone).
        let (reset2, gone2) = DayIntentStore.reconcileTargets(
            diff: .compute(old: [day("2026-07-01", off: false), day("2026-07-09", off: false)],
                           new: [day("2026-07-01", off: false)]))
        check(!reset2.contains("2026-07-01"), "reconcile: unchanged survives even when another day is removed")
        check(reset2.contains("2026-07-09") && gone2.contains("2026-07-09"), "reconcile: removed day reset + gone")

        // MARK: Vacation parsing (SPEC S-PARSE-1 / S-TEST-2 #1). An "L|V" annotation
        // overrides the printed shift → genuine day OFF carrying leaveCode "V". A day
        // with no annotation stays as printed. Mirrors the real Keriellen Nov data.
        let vacCSV = """
        Name (ID) Qualification,,Nov,,Nov,,Nov,,Nov,
        ,,05,,06,,07,,08,
        ,,Thu,,Fri,,Sat,,Sun,
        ,"Test, T  (999999) D",21,,21,,21,,05,20
        ,,L,V,L,V,,,L,V
        """
        if let w = try? ScheduleParser().parseAllWorkers(csv: vacCSV).first(where: { $0.id == "999999" }) {
            let v05 = w.shifts.first { $0.id == "2026-11-05" }
            let v06 = w.shifts.first { $0.id == "2026-11-06" }
            let w07 = w.shifts.first { $0.id == "2026-11-07" }
            let t08 = w.shifts.first { $0.id == "2026-11-08" }
            check(v05?.isOff == true && v05?.leaveCode == "V" && v05?.isVacation == true, "Vacation: 11-05 L|V (no desk) → off + leaveCode V + isVacation")
            check(v06?.isOff == true && v06?.leaveCode == "V", "Vacation: 11-06 L|V (no desk) → off + leaveCode V")
            check(w07?.isOff == false && w07?.startHour == 21 && w07?.leaveCode == nil,
                  "Vacation: 11-07 (no annotation) stays a normal working shift")
            // A vacation day still prints its base rotation (incl. a desk) — it must stay OFF. (The Build 5
            // "traded back in if a desk is printed" heuristic was reverted; it wrongly flipped real vacations.)
            check(t08?.isOff == true && t08?.leaveCode == "V",
                  "Vacation: 11-08 L|V WITH a desk (no clear home desk in this fixture) → vacation OFF")
        } else {
            check(false, "Vacation: parser failed to return worker 999999")
        }

        // MARK: Vacation resolution (B6-VAC-2LINE) — resolved at INGEST from the stacked shift lines.
        // The export prints a base/vacation-placeholder line (carries L,V or L,w) AND, when picked up, a
        // second WORKED line on the traded-in desk. The worked shift = the NON-vacation line whose desk
        // isn't also a vacation/base desk. A genuine vacation has only the V line (no worked line) → OFF.
        // Oracle values are the user-confirmed real fixture (Documentation/fixtures/expanded_schedule_sample.csv):
        //   Gar 523734 Jul 20-23 → 62/63/63/63 ; Ervin 292216 Jul 26-29 → 20/43/01/34.
        do {
            typealias C = ScheduleParser.DayCandidate
            let dt = Date(timeIntervalSince1970: 1_700_000_000)
            func resolve(_ cands: [C]) -> Shift { ScheduleParser.resolveDay(cands, date: dt, dayID: "d") }
            func work(_ h: Int, _ desk: String, v: Bool) -> C {
                C(startHour: h, desk: desk, isVacationLeave: v, vacationCode: v ? "V" : nil, otherLeaveCode: nil)
            }
            func offC() -> C { C(startHour: nil, desk: "", isVacationLeave: false, vacationCode: nil, otherLeaveCode: nil) }

            // Gar Jul 20: base 24 [V] + worked 62 → 62. Jul 21: worked 63 + base 24 [V] → 63 (order-independent).
            let g20 = resolve([work(5, "24", v: true), work(5, "62", v: false)])
            check(!g20.isOff && g20.desk == "62", "B6-VAC-2LINE: Gar Jul20 picks the worked non-V desk 62 (got \(g20.isOff ? "OFF" : g20.desk))")
            let g21 = resolve([work(5, "63", v: false), work(5, "24", v: true)])
            check(!g21.isOff && g21.desk == "63", "B6-VAC-2LINE: Gar Jul21 picks 63 regardless of line order")

            // Ervin (lines page-split across strips): Jul 26 = 41 [V] + 20 → 20 ; Jul 27 = 43 + 41 [V] → 43.
            let e26 = resolve([work(5, "41", v: true), work(5, "20", v: false)])
            let e27 = resolve([work(5, "43", v: false), work(5, "41", v: true)])
            check(!e26.isOff && e26.desk == "20" && !e27.isOff && e27.desk == "43",
                  "B6-VAC-2LINE: Ervin Jul26→20 (worked) and Jul27→43 (worked), a mix of both stacked lines")

            // Genuine vacation (Gar Jul 7): only the V line has a shift, other line OFF → OFF vacation.
            let gen = resolve([work(5, "39", v: true), offC()])
            check(gen.isOff && gen.isVacation, "B6-VAC-2LINE: a lone V line with no worked line → genuine vacation OFF")

            // Dropped annotation on a duplicate strip: the non-V desk equals the V/base desk → NOT a pickup → OFF.
            let drop = resolve([work(5, "22", v: true), work(5, "22", v: false)])
            check(drop.isOff, "B6-VAC-2LINE: non-V desk == V/base desk is a dropped annotation, not a pickup → OFF")

            // ECB VC ("w") behaves exactly like V.
            let wc = resolve([C(startHour: 5, desk: "24", isVacationLeave: true, vacationCode: "w", otherLeaveCode: nil),
                              work(5, "62", v: false)])
            check(!wc.isOff && wc.desk == "62", "B6-VAC-2LINE: ECB-VC (w) placeholder + worked line → picks the worked desk 62")

            // A normal working day (no vacation anywhere) is untouched.
            let norm = resolve([work(13, "22", v: false), offC()])
            check(!norm.isOff && norm.desk == "22", "B6-VAC-2LINE: a normal working day resolves to its worked desk")
        }

        // B6-AUTOCOMPLETE: a master import flipping my schedule proves a pending trade went through.
        do {
            func req(from: String, to: String, give: [String], take: [String]) -> TradeRequest {
                TradeRequest(id: "r", fromID: from, fromName: from, toID: to, toName: to, note: "",
                             takeDayIDs: take, giveDayIDs: give, createdAt: Date(),
                             expiresAt: Date().addingTimeInterval(9999))
            }
            let r = req(from: "me", to: "x", give: ["D1"], take: ["D2"])
            let legs = TradeProof.myLegs(r, myID: "me")
            check(legs.give == ["D1"] && legs.take == ["D2"], "B6-AUTO: sender legs = give→giveDays, take→takeDays")
            let legsR = TradeProof.myLegs(r, myID: "x")
            check(legsR.give == ["D2"] && legsR.take == ["D1"], "B6-AUTO: recipient legs are mirrored")
            check(TradeProof.proved(give: ["D1"], take: ["D2"], becameOff: ["D1"], becameWorking: ["D2"]),
                  "B6-AUTO: proved when every give→off and take→working")
            check(!TradeProof.proved(give: ["D1"], take: ["D2"], becameOff: ["D1"], becameWorking: []),
                  "B6-AUTO: a PARTIAL match is NOT proved (false-positive guard)")
            check(!TradeProof.proved(give: [], take: [], becameOff: ["D1"], becameWorking: ["D2"]),
                  "B6-AUTO: a request not touching my schedule is never auto-completed")
            let d0 = Date()
            func sh(_ id: String, off: Bool) -> Shift {
                Shift(id: id, date: d0, startHour: off ? 0 : 5, endHour: off ? 0 : 14,
                      role: off ? .off : .dispatcher, desk: off ? "" : "22", leaveCode: nil, isOff: off)
            }
            let diff = ScheduleDiff.compute(old: [sh("D1", off: false), sh("D2", off: true)],
                                            new: [sh("D1", off: true),  sh("D2", off: false)])
            let t = TradeProof.transitions(diff)
            check(t.becameOff.contains("D1") && t.becameWorking.contains("D2"),
                  "B6-AUTO: transitions() reads working→off and off→working from a diff")
            var chainReq = req(from: "me", to: "x", give: [], take: [])
            chainReq.chain = [TradeLeg(fromID: "me", fromName: "me", toID: "x", toName: "x", dayID: "G"),
                              TradeLeg(fromID: "y", fromName: "y", toID: "me", toName: "me", dayID: "T")]
            let cl = TradeProof.myLegs(chainReq, myID: "me")
            check(cl.give == ["G"] && cl.take == ["T"], "B6-AUTO: chain legs mapped by fromID/toID")
        }

        // B6-ECB60: the ECB behavior filter (4101) — only offer a shift to someone who actually WORKED
        // that TYPE in the last 60 days. A MID-only dispatcher is excluded from a PM offer; someone who
        // worked PM recently passes; an empty recent set (robot/inactive) is always excluded.
        do {
            check(TradeMatcher.recentBehaviorAllows(recentTypes: [.pm, .am], coveredTypes: [.pm]),
                  "B6-ECB60: recently worked PM → included for a PM offer")
            check(!TradeMatcher.recentBehaviorAllows(recentTypes: [.mid], coveredTypes: [.pm]),
                  "B6-ECB60: MID-only recent behavior → excluded from a PM offer")
            check(!TradeMatcher.recentBehaviorAllows(recentTypes: [], coveredTypes: [.pm, .am, .mid]),
                  "B6-ECB60: no recent work (robot/inactive) → excluded from any offer")
        }

        // B6-FILTER: the Trade Solutions date-range criterion keeps only solutions whose EVERY moved
        // day (give + get) falls inside the window; a package with any day outside is dropped.
        do {
            func pkg(_ give: [String], _ take: [String]) -> TradePackage {
                TradePackage(id: give.joined() + take.joined(), methodology: .greedy,
                             assignments: [PackageAssignment(workerID: "x", name: "X", giveDayIDs: give, takeDayIDs: take)],
                             route: nil)
            }
            let inWindow  = pkg(["2026-07-10"], ["2026-07-20"])
            let outWindow = pkg(["2026-07-10"], ["2026-08-05"])   // Aug 5 is past the end
            let df = DateFormatter(); df.calendar = Calendar(identifier: .gregorian); df.dateFormat = "yyyy-MM-dd"
            func d(_ iso: String) -> Date { df.date(from: iso) ?? Date() }
            var f = SearchFilter(); f.dateStart = d("2026-07-01"); f.dateEnd = d("2026-07-31")
            let kept = f.filter([inWindow, outWindow], selfID: "")
            check(kept.contains(inWindow) && !kept.contains(outWindow),
                  "B6-FILTER: date range keeps trades whose RECEIVED day is in-window, drops out-of-window receives")
        }

        // (Removed: the old "vacation auto-sets Must-Be-Off + 'vacation' note" checks — that behavior was
        // intentionally dropped in the vacation-leave-code model; reconcile no longer auto-blacks-out
        // vacation days or stamps an auto note.)

        // MARK: Trade-type label SOT (SPEC S-ENG-5 / S-TEST-1). The fix for the
        // "3-way / 2-way" contradiction: one function, distinct-people count, three shapes.
        check(tradeTypeLabel(distinctPeople: 2) == "2-Person Swap", "label: You+Cary ⇒ 2-Person Swap")
        check(tradeTypeLabel(distinctPeople: 3) == "3-Person Swap", "label: 3 ⇒ 3-Person Swap")
        check(tradeTypeLabel(distinctPeople: 1) == "2-Person Swap", "label: floor at 2-Person Swap")
        check(tradeTypeLabel(distinctPeople: 2, isOneWayECB: true) == "1-Way Swap", "label: ECB ⇒ 1-Way Swap")
        check(tradeTypeLabel(distinctPeople: 3, hasQualSwap: true) == "Qual Swap", "label: qual ⇒ Qual Swap")
        check(tradeTypeLabel(distinctPeople: 2, isOneWayECB: true, hasQualSwap: true) == "1-Way Swap",
              "label: ECB precedence over qual")
        for n in 1...6 { for ecb in [false, true] { for q in [false, true] {
            let s = tradeTypeLabel(distinctPeople: n, isOneWayECB: ecb, hasQualSwap: q)
            check(s == "1-Way Swap" || s == "Qual Swap" || s.hasSuffix("-Person Swap"),
                  "label universe: unexpected '\(s)'")
        }}}
        let recipLegs = [TradeLeg(fromID: "A", fromName: "A", toID: "B", toName: "B", dayID: "d1"),
                         TradeLeg(fromID: "B", fromName: "B", toID: "A", toName: "A", dayID: "d2")]
        check(distinctParticipants(in: recipLegs) == 2, "distinctParticipants: 2-person reciprocal ⇒ 2 (the B2 bug)")

        // MARK: Negative-intent gate (SPEC S-ENG-9/10). A Must-Be-Off day is NEVER
        // offered as a pickup — even otherwise-pickable, even under mercenary. June-23 fix.
        var np = TradeProfile(workerID: "001", displayName: "A", openness: "all",
                              blacklistedWeekdays: [], blacklistedDesks: [],
                              blacklistedShiftTypes: [], blacklistedRegions: [],
                              seekingDayIDs: [], updatedAt: Date.distantPast)
        np.mustBeOffDayIDs = ["2026-06-23"]
        check(np.wouldPickUp(onDay: "2026-06-23", weekday: 3, desk: "29", shiftType: "AM", region: "Domestic", isBookend: true) == false,
              "wouldPickUp: Must-Be-Off day never offered (June-23 bug)")
        check(np.wouldPickUp(onDay: "2026-06-24", weekday: 4, desk: "29", shiftType: "AM", region: "Domestic", isBookend: true) == true,
              "wouldPickUp: a non-marked day still offered")
        np.isMercenaryMode = true
        check(np.wouldPickUp(onDay: "2026-06-23", weekday: 3, desk: "29", shiftType: "AM", region: "Domestic", isBookend: false) == false,
              "wouldPickUp: Must-Be-Off beats mercenary")

        // Negative-intent sets derive from intents (these feed the matcher gates). Sentinel days.
        do {
            let store = DayIntentStore.shared
            let kd = "2099-04-01", md = "2099-04-02"
            let clean = store.workingIntent(forDay: kd) == nil && store.offIntent(forDay: md) == nil
            store.setWorkingIntent(.mustWork, forDay: kd)
            store.setOffIntent(.mustBeOff, forDay: md)
            check(store.keepDayIDs.contains(kd), "keepDayIDs: mustWork day present")
            check(store.mustBeOffDayIDs.contains(md), "mustBeOffDayIDs: mustBeOff day present")
            check(!store.seekingDayIDs.contains(kd), "Keep day is NOT a give-away (seeking) day")
            store.clearIntent(forDay: kd); store.clearIntent(forDay: md)   // cleanup
            check(clean, "keep/mustBeOff sentinel days clean before test")
        }

        // MARK: Feed-refresh trigger (SPEC S-ENG-9). The match-inputs signature MUST
        // change when openness / intents change, so the feed recomputes (the "nothing
        // refreshed" bug). Pure — no view needed.
        func sig(_ openness: String, _ off: [String: OffIntentState]) -> MatchInputsSignature {
            MatchInputsSignature(openness: openness, mercenary: false, working: [:], off: off,
                                 availability: [:], blacklistDesks: [], blacklistRegions: [],
                                 blacklistWeekdays: [], blacklistShiftTypes: [])
        }
        check(sig("bookends", [:]) != sig("all", [:]), "match signature changes when openness changes")
        check(sig("bookends", [:]) != sig("bookends", ["2026-06-23": .mustBeOff]),
              "match signature changes when an intent changes")
        check(sig("bookends", [:]) == sig("bookends", [:]), "match signature stable for identical inputs")

        // MARK: Mercenary forces openness to All (SPEC S-ENG-6). "Not accepting +
        // mercenary" cannot coexist. Save/restore the singleton.
        do {
            let s = SettingsManager.shared
            let oldMerc = s.isMercenaryMode, oldOpen = s.tradeOpenness
            s.tradeOpenness = "none"
            s.isMercenaryMode = true
            check(s.tradeOpenness == TradeOpenness.all.rawValue, "mercenary forces openness to All")
            s.isMercenaryMode = oldMerc; s.tradeOpenness = oldOpen   // restore
        }

        // MARK: ECB amount — 0.5 steps, 5…25 (SPEC S-ENG-8 / A4).
        check(TradeRequest.isValidECB(13.5), "ECB: 13.5 valid (1.5× OT)")
        check(TradeRequest.isValidECB(5) && TradeRequest.isValidECB(25), "ECB: bounds 5 and 25 valid")
        check(!TradeRequest.isValidECB(4.5), "ECB: below 5 invalid")
        check(!TradeRequest.isValidECB(25.5), "ECB: above 25 invalid")
        check(!TradeRequest.isValidECB(13.3), "ECB: non-0.5 step invalid")
        check(TradeRequest.clampECB(4) == 5 && TradeRequest.clampECB(30) == 25, "ECB: clamp to 5…25")
        check(TradeRequest.clampECB(13.3) == 13.5, "ECB: clamp rounds to nearest 0.5")
        check(ecbText(9) == "9" && ecbText(13.5) == "13.5", "ecbText: drops trailing .0")

        // MARK: Intents-tab badge count (D2a). activeIntentCount counts non-neutral intents.
        do {
            let store = DayIntentStore.shared
            let d1 = "2099-05-01", d2 = "2099-05-02", d3 = "2099-05-03"
            let base = store.activeIntentCount
            store.setWorkingIntent(.dontWantToWork, forDay: d1)   // trade-away
            store.setOffIntent(.mustBeOff, forDay: d2)            // must-be-off
            store.setWorkingIntent(.neutralOpen, forDay: d3)      // neutral → NOT counted
            check(store.activeIntentCount == base + 2, "activeIntentCount: counts non-neutral only")
            store.clearIntent(forDay: d1); store.clearIntent(forDay: d2); store.clearIntent(forDay: d3)
            check(store.activeIntentCount == base, "activeIntentCount: back to baseline after cleanup")
        }

        // MARK: Channel unread badge (A2/S-SYNC-1). Unread = posts AFTER last-seen, not
        // your own — so it clears on read (old badge showed total count and never cleared).
        func post(_ id: String, author: String, at: Date) -> BroadcastPost {
            BroadcastPost(id: id, authorID: author, authorName: author, text: "hi",
                          createdAt: at, expiresAt: at.addingTimeInterval(86_400))
        }
        let now = Date()
        let t0 = now.addingTimeInterval(-3_000), t1 = now.addingTimeInterval(-2_000),
            t2 = now.addingTimeInterval(-1_000)
        let posts = [post("a", author: "peer", at: t0), post("b", author: "peer", at: t2),
                     post("c", author: "me", at: t2)]
        check(MessagingStore.unreadCount(broadcasts: posts, since: t1, excluding: "me") == 1,
              "unread: only peer posts newer than last-seen count (not mine, not old)")
        check(MessagingStore.unreadCount(broadcasts: posts, since: t2, excluding: "me") == 0,
              "unread: marking seen at latest clears the badge")
        check(MessagingStore.unreadCount(broadcasts: posts, since: .distantPast, excluding: "me") == 2,
              "unread: both peer posts unread before any read")

        // MARK: Character counter logic (F3). near-limit at ≥90%, over past limit.
        let empty = CharLimit.state("", limit: 50)
        check(empty.used == 0 && empty.remaining == 50 && !empty.nearLimit && !empty.over, "charlimit: empty")
        let mid = CharLimit.state(String(repeating: "x", count: 25), limit: 50)
        check(mid.remaining == 25 && !mid.nearLimit, "charlimit: half is not near-limit")
        let near = CharLimit.state(String(repeating: "x", count: 46), limit: 50)
        check(near.nearLimit && !near.over, "charlimit: 46/50 is near-limit, not over")
        let over = CharLimit.state(String(repeating: "x", count: 51), limit: 50)
        check(over.over && over.remaining == -1, "charlimit: 51/50 is over")

        // MARK: Status-by-name lookup (A7/B8). Empty status → nil; set → returned.
        do {
            let s = SettingsManager.shared
            let old = s.statusBroadcast
            s.statusBroadcast = ""
            check(participantStatus(s.username) == nil, "participantStatus: empty → nil (no clutter)")
            s.statusBroadcast = "Taking weekend PMs"
            check(participantStatus(s.username) == "Taking weekend PMs", "participantStatus: returns set status")
            s.statusBroadcast = old
        }

        // MARK: Inbox archive filter (B3). active() excludes archived; delete is separate.
        func req(_ id: String) -> TradeRequest {
            TradeRequest(id: id, fromID: "a", fromName: "A", toID: "b", toName: "B", note: "",
                         takeDayIDs: [], giveDayIDs: [], createdAt: Date(), expiresAt: Date().addingTimeInterval(86_400))
        }
        let reqs = [req("r1"), req("r2"), req("r3")]
        let activeSet = MessagingStore.active(reqs, archived: ["r2"])
        check(activeSet.map(\.id) == ["r1", "r3"], "inbox: active() hides archived, keeps the rest")
        check(MessagingStore.active(reqs, archived: []).count == 3, "inbox: nothing archived → all active")

        // MARK: Reply edit/delete model (B4). edited stamps a date; soft-delete tombstones.
        var rep = BroadcastReply(id: "x", postID: "p", authorID: "me", authorName: "Me",
                                 text: "hello", isPublic: true, createdAt: Date())
        check(rep.editedAt == nil && !rep.isDeleted, "reply: fresh reply not edited/deleted")
        rep.editedAt = Date()
        check(rep.editedAt != nil, "reply: edited stamps editedAt")
        rep.deleted = true
        check(rep.isDeleted, "reply: soft-delete sets isDeleted (renders [Deleted])")

        // MARK: Pinned posts sort to top (B7). Pinned-first, then newest.
        func bp(_ id: String, at: Date, pinned: Bool) -> BroadcastPost {
            BroadcastPost(id: id, authorID: "x", authorName: "X", text: id, createdAt: at,
                          expiresAt: at.addingTimeInterval(86_400), channel: "trades", pinned: pinned)
        }
        let n = Date()
        let sortedPosts = MessagingStore.sortedForChannel([
            bp("old", at: n.addingTimeInterval(-300), pinned: false),
            bp("newest", at: n, pinned: false),
            bp("pinnedOld", at: n.addingTimeInterval(-600), pinned: true),
        ])
        check(sortedPosts.first?.id == "pinnedOld", "pin: a pinned (even old) post sorts to the very top")
        check(sortedPosts.map(\.id) == ["pinnedOld", "newest", "old"], "pin: pinned first, then unpinned NEWEST→oldest (latest at top)")

        // MARK: Brush completeness (F1). EVERY intent must be paintable — this is the
        // exact guard against "I thought the brush already covered it". A new enum case
        // with no brush fails here.
        // Off-day: the actionable intents are brushable; "Open" (neutralOpen) is the cleared state (eraser).
        check(Set(IntentBrushes.off) == Set([.mustBeOff, .wantToWork]),
              "F1: off-day brushes = Blackout + Want-to-Work (Open = cleared state, not a brush)")
        // Working-day: Trade-away + Keep are brushable; "Open" (neutralOpen) is the cleared state (eraser).
        check(Set(IntentBrushes.working) == Set([.dontWantToWork, .mustWork]),
              "F1: working brushes = Trade-away + Keep (Open = cleared state, not a brush)")
        // Every brush has a non-empty human label (no blank pills).
        check(IntentBrushes.working.allSatisfy { !$0.label.isEmpty } && IntentBrushes.off.allSatisfy { !$0.label.isEmpty },
              "F1: every brush has a label")

        // MARK: A5 — fewest-people ranking (discharges ASSUMED_PRESENT #4). A single-person
        // full-cover tops the list; greedy ranks ahead of circular at equal people count.
        func pa(_ id: String) -> PackageAssignment { PackageAssignment(workerID: id, name: id, giveDayIDs: ["d1"], takeDayIDs: ["d2"]) }
        let solo  = TradePackage(id: "solo-A", methodology: .greedy, assignments: [pa("A")], route: nil, urgency: 0, isOptimal: true)
        let multi = TradePackage(id: "multi",  methodology: .greedy, assignments: [pa("A"), pa("B")], route: nil, urgency: 0)
        let route = NWayRoute(participants: ["me", "A", "B"], legs: [], tier: .matchingIntents, score: 0, usesBookends: false)
        let circ  = TradePackage(id: "circular-1", methodology: .circular, assignments: [pa("A"), pa("B")], route: route, urgency: 0)
        let ranked = TradeRouter.rankPackages([circ, multi, solo])
        check(ranked.first?.id == "solo-A", "A5: single-person full-cover sorts to the very top")
        check(ranked.map(\.peopleCount) == [2, 3, 3], "A5: fewest people first (solo=2, others=3)")
        check(ranked[1].methodology == .greedy && ranked[2].methodology == .circular, "A5: greedy before circular at equal people")

        // MARK: U4 — priority sort (🔥+bookends → 🔥 → bookends-only) + bookends-only top-two-bands cap.
        func pkg(_ id: String, people: Int, fire: Int, book: Int) -> TradePackage {
            let a = (1..<people).map { pa("P\($0)") }   // people-1 counterparties + you = `people`
            return TradePackage(id: id, methodology: .greedy, assignments: a, route: nil,
                                urgency: 0, isOptimal: false, fireCount: fire, bookendTotal: book)
        }
        // All N=2 so the tier ordering is the discriminator.
        let fireBook = pkg("fb", people: 2, fire: 2, book: 3)   // 🔥 + bookends → tier 0
        let fireOnly = pkg("fo", people: 2, fire: 1, book: 0)   // 🔥 only → tier 1
        let bookHi   = pkg("b3", people: 2, fire: 0, book: 3)   // bookends-only, max band
        let bookMid  = pkg("b2", people: 2, fire: 0, book: 2)   // bookends-only, max-1 band
        let bookLo   = pkg("b1", people: 2, fire: 0, book: 1)   // bookends-only, below cap → dropped
        let u4 = TradeRouter.rankPackages([bookLo, bookMid, bookHi, fireOnly, fireBook])
        check(u4.map(\.id).prefix(2).elementsEqual(["fb", "fo"]),
              "U4: 🔥+bookends first, then 🔥-only")
        check(u4.contains { $0.id == "b3" } && u4.contains { $0.id == "b2" },
              "U4: bookends-only top two bands (3 and 2) are kept")
        check(!u4.contains { $0.id == "b1" },
              "U4: bookends-only below max-1 (band 1) is filtered out")
        // N grouping dominates tiers: a fewer-people bookends-only beats a more-people 🔥.
        let nGroup = TradeRouter.rankPackages([pkg("fire3", people: 3, fire: 5, book: 5),
                                               pkg("book2", people: 2, fire: 0, book: 1)])
        check(nGroup.first?.id == "book2", "U4: fewest-people (N) grouping dominates the tier priority")
        // MARK: #4 — a 2-person package is NEVER circular (circular needs ≥3); #4b — earliest-date tiebreak.
        let route2 = NWayRoute(participants: ["me", "A"], legs: [], tier: .matchingIntents, score: 0, usesBookends: false)
        let twoCirc = TradePackage(id: "c2", methodology: .circular, assignments: [pa("A")], route: route2)
        check(!twoCirc.isCircular, "#4: a 2-participant package is not circular (a 2-cycle is a 2-way swap)")
        let route3 = NWayRoute(participants: ["me", "A", "B"], legs: [], tier: .matchingIntents, score: 0, usesBookends: false)
        let threeCirc = TradePackage(id: "c3", methodology: .circular, assignments: [pa("A"), pa("B")], route: route3)
        check(threeCirc.isCircular, "#4: a 3-participant circular IS circular")
        // #4b: equal on N/🔥/bookends, the earlier-dated trade sorts first — even past the alphabetical id tiebreak.
        let earlyPkg = TradePackage(id: "zzz", methodology: .greedy,
                                    assignments: [PackageAssignment(workerID: "A", name: "A", giveDayIDs: ["2026-07-01"], takeDayIDs: ["2026-07-02"])],
                                    route: nil)
        let latePkg = TradePackage(id: "aaa", methodology: .greedy,
                                   assignments: [PackageAssignment(workerID: "B", name: "B", giveDayIDs: ["2026-12-01"], takeDayIDs: ["2026-12-02"])],
                                   route: nil)
        let dateRanked = TradeRouter.rankPackages([latePkg, earlyPkg])
        check(dateRanked.first?.id == "zzz", "#4b: earlier-dated trade sorts first (beats alphabetical id)")

        // Q1: a qual-swap package (0 bookends) is EXEMPT from the bookends-only cap — never hidden.
        var qsPkg = pkg("qs", people: 2, fire: 0, book: 0)
        qsPkg.qualSwap = QualSwapLegData(giveShiftDayID: "d", giveDesk: "50", giveQual: "E",
                                         takerID: "B", takerName: "B",
                                         candidates: [QualSwapCandidate(workerID: "C", name: "C", desk: "10", qual: "D")])
        let qsRank = TradeRouter.rankPackages([pkg("b3", people: 2, fire: 0, book: 3), qsPkg])
        check(qsRank.contains { $0.id == "qs" }, "Q1: a qual-swap package survives the bookends-only cap (exempt)")

        // MARK: A6 — mutual-intent (🔥) match end-to-end (discharges ASSUMED_PRESENT #5).
        // I work k1 (give), off k2; peer off k1, works k2 (gives k2). Both openness .all.
        do {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let horizon = cal.date(byAdding: .month, value: 12, to: today)!
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let day1 = cal.date(byAdding: .day, value: 30, to: today)!
            let day2 = cal.date(byAdding: .day, value: 37, to: today)!
            let k1 = f.string(from: day1), k2 = f.string(from: day2)
            func entry(_ w: String, _ day: String, off: Bool) -> RosterEntry {
                RosterEntry(workerID: w, workerName: w, quals: ["D"], day: day,
                            startHour: off ? 0 : 5, desk: off ? "" : "29", isOff: off)
            }
            let myMap = [k1: entry("me", k1, off: false), k2: entry("me", k2, off: true)]
            let pMap  = [k1: entry("p", k1, off: true),   k2: entry("p", k2, off: false)]
            let giveShift = Shift(id: k1, date: day1, startHour: 5, endHour: 14, role: .dispatcher, desk: "29", leaveCode: nil, isOff: false)
            func prof(_ id: String, seeking: Set<String>) -> TradeProfile {
                TradeProfile(workerID: id, displayName: id, openness: "all",
                             blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [], blacklistedRegions: [],
                             seekingDayIDs: seeking, updatedAt: .distantPast)
            }
            var meP = prof("me", seeking: [k1]); let them = prof("p", seeking: [k2])
            let n = TradeMatcher.goldCountPure(myGiveShifts: [giveShift], myMap: myMap, pMap: pMap,
                                               theirProfile: them, myProfile: meP, myQuals: ["D"],
                                               today: today, horizonEnd: horizon, cal: cal)
            check(n == 2, "A6: a true mutual swap surfaces (they take k1 + I take k2) = 2, got \(n)")
            meP.mustBeOffDayIDs = [k2]
            let n2 = TradeMatcher.goldCountPure(myGiveShifts: [giveShift], myMap: myMap, pMap: pMap,
                                                theirProfile: them, myProfile: meP, myQuals: ["D"],
                                                today: today, horizonEnd: horizon, cal: cal)
            check(n2 == 1, "A6: Must-Be-Off on k2 removes the B match → 1, got \(n2)")
        }

        // MARK: B6-QUAL — region qualification gate (grays out regions in Trade Settings).
        check(DeskRules.isQualified(quals: ["D"], forRegion: .domestic), "B6-QUAL: everyone qualifies for Domestic (D)")
        check(!DeskRules.isQualified(quals: ["D"], forRegion: .european), "B6-QUAL: no E → not qualified for European")
        check(DeskRules.isQualified(quals: ["D", "E"], forRegion: .european), "B6-QUAL: holding E → qualified for European")
        check(DeskRules.isQualified(quals: ["D", "L"], forRegion: .latin), "B6-QUAL: holding L → qualified for Latin America")
        check(!DeskRules.isQualified(quals: ["D", "E"], forRegion: .coordinator), "B6-QUAL: no coordinator qual → not qualified")
        check(DeskRules.isQualified(quals: ["D", "R"], forRegion: .coordinator), "B6-QUAL: a coordinator qual (R) → qualified")

        // MARK: B6-BLACKOUT — a blacked-out weekday blocks a pickup (arbitrary days, not just weekends).
        do {
            let prof = TradeProfile(workerID: "z", displayName: "Z", openness: "all",
                                    blacklistedWeekdays: [4], blacklistedDesks: [], blacklistedShiftTypes: [],
                                    blacklistedRegions: [], seekingDayIDs: [], updatedAt: .distantPast)
            check(!prof.passesBlacklist(weekday: 4, desk: "29", shiftType: "AM", region: "Domestic"),
                  "B6-BLACKOUT: a blacked-out weekday (Wed=4) is rejected by the matcher")
            check(prof.passesBlacklist(weekday: 3, desk: "29", shiftType: "AM", region: "Domestic"),
                  "B6-BLACKOUT: a non-blacked-out weekday passes")
            // Display parity: the calendar tints a WORKING shift only via desk/type/region — the weekday
            // dimension is opt-in via the `weekdays` set, so HomeCalendar passes [] for working days (a
            // blacked-out weekday only bites off-day pickups). With weekdays:[] a clean working day → no tint.
            check(!Blackout.isBlacklisted(desk: "29", startHour: 5, weekday: 4,
                                          desks: [], shiftTypes: [], regions: [], weekdays: []),
                  "B6-BLACKOUT: working-day tint ignores the weekday dimension (weekdays: [])")
            check(Blackout.isBlacklisted(desk: "29", startHour: 5, weekday: 4,
                                         desks: [], shiftTypes: [], regions: [], weekdays: [4]),
                  "B6-BLACKOUT: off-day path (weekdays passed) still flags a blacked-out weekday")
        }

        // MARK: B6-ECB — ECB accounting pure core (signed amount, available vs projected, cap, IOU, decode).
        do {
            let d = Date(timeIntervalSince1970: 1_700_000_000)
            func personal(_ amt: Double, _ cat: ECBCategory, cleared: Bool) -> ECBEntry {
                ECBEntry(date: d, amount: amt, category: cat, cleared: cleared)
            }
            func trade(_ mag: Double, payer: String, payee: String, _ state: ECBLineState, cleared: Bool) -> ECBEntry {
                ECBEntry(date: d, amount: mag, category: .trade, cleared: cleared, payerID: payer, payeeID: payee, state: state)
            }
            // signedAmount: personal passthrough; shared → payee +, payer −.
            check(ECBAccounting.signedAmount(for: "me", personal(9, .overtime, cleared: true)) == 9, "B6-ECB: personal line passes its signed amount through")
            check(ECBAccounting.signedAmount(for: "me", trade(5, payer: "you", payee: "me", .confirmed, cleared: true)) == 5, "B6-ECB: shared line credits the payee (+)")
            check(ECBAccounting.signedAmount(for: "me", trade(5, payer: "me", payee: "you", .confirmed, cleared: true)) == -5, "B6-ECB: shared line debits the payer (−)")
            // available = agreed + CLEARED only; projected = agreed (cleared or scheduled); pending-confirm excluded from both.
            let ledger = [personal(9, .overtime, cleared: true),                            // +9 available
                          personal(-4, .withdrawal, cleared: false),                        // −4 scheduled only
                          ECBEntry(date: d, amount: 2.5, category: .adjustment, cleared: true), // +2.5 available
                          trade(5, payer: "you", payee: "me", .confirmed, cleared: true),    // +5 available
                          trade(3, payer: "you", payee: "me", .confirmed, cleared: false),   // +3 scheduled only
                          trade(7, payer: "you", payee: "me", .pendingIncoming, cleared: false)] // awaiting confirm → neither
            check(ECBAccounting.available(ledger, viewerID: "me") == 16.5, "B6-ECB: available = 9 + 2.5 + 5 (cleared only) = 16.5")
            check(ECBAccounting.projected(ledger, viewerID: "me") == 15.5, "B6-ECB: projected = 16.5 − 4 + 3 (agreed incl. scheduled) = 15.5")
            check(ECBAccounting.pendingConfirmations(ledger, myID: "me").count == 1, "B6-ECB: one shared line awaits my confirmation")
            // 144 cap: can't CLEAR a positive delta that pushes available over 144.
            check(ECBAccounting.wouldExceedCap(available: 140, clearing: 5), "B6-ECB: clearing +5 at 140 exceeds the 144 cap")
            check(!ECBAccounting.wouldExceedCap(available: 140, clearing: 4), "B6-ECB: clearing +4 at 140 is fine (=144)")
            check(!ECBAccounting.wouldExceedCap(available: 200, clearing: -10), "B6-ECB: a withdrawal never trips the cap")
            // IOU capacity = available + net scheduled (you can only promise what you have or will have).
            let capLedger = [personal(10, .holidayPay, cleared: false),   // scheduled deposit +10
                             personal(6, .overtime, cleared: true)]       // cleared +6
            check(ECBAccounting.payableCapacity(capLedger, myID: "me") == 16, "B6-ECB: payable = cleared 6 + scheduled 10 = 16")
            // owe / owed = outstanding (agreed, uncleared) shared lines; cleared ones drop off.
            let iouLedger = [trade(4, payer: "me", payee: "you", .confirmed, cleared: false),  // I owe 4
                             trade(2, payer: "you", payee: "me", .confirmed, cleared: false),  // owed 2 to me
                             trade(9, payer: "me", payee: "you", .confirmed, cleared: true)]    // cleared → neither
            check(ECBAccounting.owe(iouLedger, myID: "me") == 4, "B6-ECB: owe = agreed uncleared I pay = 4")
            check(ECBAccounting.owed(iouLedger, myID: "me") == 2, "B6-ECB: owed = agreed uncleared others pay me = 2")
            // Setting balance produces the correct delta.
            check(ECBAccounting.adjustmentAmount(current: 16.5, target: 20) == 3.5, "B6-ECB: set-balance delta 16.5→20 = +3.5")
            // INV-3: a minimal (legacy-shaped) entry decodes with defaults (incl. cleared=false).
            let legacyJSON = #"{"id":"x","date":0,"amount":6,"category":"overtime"}"#.data(using: .utf8)!
            if let back = try? JSONDecoder().decode(ECBEntry.self, from: legacyJSON) {
                check(back.state == .confirmed && back.payerID == nil && back.memo == "" && back.cleared == false,
                      "B6-ECB: legacy entry decodes with defaults (INV-3)")
            } else { check(false, "B6-ECB: legacy entry failed to decode") }
        }

        // MARK: B6-INTENTS — the robot/active-account gate applies ONLY in Mutual mode.
        // Regression: gating BOTH modes on isActiveAccount zeroed the feed when no peer had claimed an
        // account. All (mutualOnly=false) must include an unclaimed peer; Mutual (true) must exclude it.
        check(TradeRouter.peerEligibleForIntents(isActiveAccount: false, mutualOnly: false),
              "B6-INTENTS: unclaimed peer IS eligible in All mode")
        check(!TradeRouter.peerEligibleForIntents(isActiveAccount: false, mutualOnly: true),
              "B6-INTENTS: unclaimed peer is EXCLUDED in Mutual mode")
        check(TradeRouter.peerEligibleForIntents(isActiveAccount: true, mutualOnly: true),
              "B6-INTENTS: a claimed account is eligible in Mutual mode")

        // MARK: D1 — bookends is the DEFAULT/fallback openness (discharges #3). Verified by
        // code that onboarding never writes tradeOpenness and load() defaults to "bookends";
        // here we lock the resolution fallback.
        check((TradeOpenness(rawValue: "garbage") ?? .bookends) == .bookends, "D1: unknown openness → bookends")
        let freshProf = TradeProfile(workerID: "x", displayName: "x", openness: "",
                                     blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [], blacklistedRegions: [],
                                     seekingDayIDs: [], updatedAt: .distantPast)
        check(freshProf.opennessLevel == .bookends, "D1: empty/new openness resolves to .bookends")

        // MARK: B4 chat-message edit/delete model (discharges ASSUMED_PRESENT #9).
        var msg = TradeResponse(id: "m1", requestID: "r", responderID: "me", responderName: "Me",
                                status: TradeRequestStatus.message.rawValue, note: "hi", createdAt: Date())
        check(msg.editedAt == nil && !msg.isDeleted, "chat: fresh message not edited/deleted")
        msg.editedAt = Date()
        check(msg.editedAt != nil, "chat: edit stamps editedAt")
        msg.deleted = true
        check(msg.isDeleted, "chat: soft-delete sets isDeleted (renders [Deleted])")

        // MARK: #10 — vacation is a SOFT exclusion, not a hard gate (your rule: "still
        // allowed to trade into it"). A vacation day is an OFF day flagged for display;
        // there is NO separate "unavailable for trades" state, so peers aren't hard-blocked.
        let vacOff = Shift(id: "2099-06-01", date: Date(timeIntervalSince1970: 4_086_000_000),
                           startHour: 0, endHour: 0, role: .off, desk: "", leaveCode: "V", isOff: true)
        check(vacOff.isOff && vacOff.isVacation, "#10: vacation = an OFF day flagged vacation (no hard unavailable state)")

        // MARK: #11 — per-intent counts drive the color-coded tier bubbles (D2a). Sentinel days.
        do {
            let s = DayIntentStore.shared
            let a = "2099-07-01", b = "2099-07-02", c = "2099-07-03"
            let baseW = s.workingIntentCounts[.dontWantToWork] ?? 0
            let baseO = s.offIntentCounts[.mustBeOff] ?? 0
            s.setWorkingIntent(.dontWantToWork, forDay: a)
            s.setWorkingIntent(.dontWantToWork, forDay: b)
            s.setOffIntent(.mustBeOff, forDay: c)
            check((s.workingIntentCounts[.dontWantToWork] ?? 0) == baseW + 2, "#11: trade-away tally counts both days")
            check((s.offIntentCounts[.mustBeOff] ?? 0) == baseO + 1, "#11: must-be-off tally counts its day")
            s.clearIntent(forDay: a); s.clearIntent(forDay: b); s.clearIntent(forDay: c)
        }

        // MARK: A3 — last-write-wins merge for private-notes sync (#6). Pure core; the
        // CloudKit round-trip itself needs a 2-device device check (in USER_TEST_LIST).
        let older = Date(timeIntervalSince1970: 1_000), newer = Date(timeIntervalSince1970: 2_000)
        check(LWW.pick(local: "L", localAt: older, remote: "R", remoteAt: newer) == "R", "A3: newer remote wins")
        check(LWW.pick(local: "L", localAt: newer, remote: "R", remoteAt: older) == "L", "A3: newer local wins")
        check(LWW.pick(local: "L", localAt: newer, remote: "R", remoteAt: newer) == "L", "A3: tie keeps local")

        // MARK: S-ENG-10 — Want-to-Work OVERRIDES the bookend requirement (one-sided),
        // but NOT blacklist or Must-Be-Off.
        let d = "2026-09-10"
        func wp(blacklistDesk: Bool = false, wantToWork: Bool = false, mustBeOff: Bool = false) -> TradeProfile {
            var p = TradeProfile(workerID: "x", displayName: "x", openness: "bookends",
                                 blacklistedWeekdays: [], blacklistedDesks: blacklistDesk ? ["29"] : [],
                                 blacklistedShiftTypes: [], blacklistedRegions: [],
                                 seekingDayIDs: [], updatedAt: .distantPast)
            if wantToWork { p.wantToWorkDayIDs = [d] }
            if mustBeOff { p.mustBeOffDayIDs = [d] }
            return p
        }
        func take(_ p: TradeProfile, bookend: Bool) -> Bool {
            p.wouldPickUp(onDay: d, weekday: 5, desk: "29", shiftType: "AM", region: "Domestic", isBookend: bookend)
        }
        check(take(wp(), bookend: false) == false, "S-ENG-10: under bookends, a non-bookend day is rejected by default")
        check(take(wp(wantToWork: true), bookend: false) == true, "S-ENG-10: Want-to-Work makes a non-bookend day eligible")
        check(take(wp(blacklistDesk: true, wantToWork: true), bookend: false) == false, "S-ENG-10: Want-to-Work does NOT override the blacklist")
        check(take(wp(wantToWork: true, mustBeOff: true), bookend: true) == false, "S-ENG-10: Must-Be-Off still wins over Want-to-Work")

        // MARK: S-VALID — a trade day is invalid when a participant no longer works it.
        func re(_ w: String, _ day: String, off: Bool) -> RosterEntry {
            RosterEntry(workerID: w, workerName: w, quals: ["D"], day: day, startHour: off ? 0 : 5, desk: off ? "" : "29", isOff: off)
        }
        // Sender gives g1 (still works it) + g2 (now OFF → stale). Taker takes t1 (still works).
        let fromMap = ["g1": re("f", "g1", off: false), "g2": re("f", "g2", off: true)]
        let toMap   = ["t1": re("t", "t1", off: false)]
        let stale = TradeMatcher.staleDaysPure(giveDayIDs: ["g1", "g2"], takeDayIDs: ["t1"], fromMap: fromMap, toMap: toMap)
        check(stale == ["g2"], "S-VALID: only the no-longer-worked give day is stale/invalid")
        let noStale = TradeMatcher.staleDaysPure(giveDayIDs: ["g1"], takeDayIDs: ["t1"], fromMap: fromMap, toMap: toMap)
        check(noStale.isEmpty, "S-VALID: a fully-worked trade is valid (no stale days)")
        let staleGone = TradeMatcher.staleDaysPure(giveDayIDs: ["gX"], takeDayIDs: [], fromMap: fromMap, toMap: toMap)
        check(staleGone == ["gX"], "S-VALID: a day no longer in the schedule at all is stale")

        // MARK: H1 — Home metrics helpers (pure).
        check(Metrics.successPercent(accepted: 3, proposed: 4) == 75, "H1: success % = accepted/proposed")
        check(Metrics.successPercent(accepted: 0, proposed: 0) == 0, "H1: no proposals → 0% (no divide-by-zero)")
        let nowD = Date()
        let calM = Calendar.current
        let thisMonth = nowD
        let lastYear = calM.date(byAdding: .year, value: -1, to: nowD)!
        let events = [thisMonth, thisMonth, lastYear]
        check(Metrics.searchCount(events, period: .allTime, now: nowD) == 3, "H1: all-time counts every search")
        check(Metrics.searchCount(events, period: .month, now: nowD) == 2, "H1: month counts only this month")
        check(Metrics.searchCount(events, period: .year, now: nowD) == 2, "H1: year excludes last year's search")

        // (A1 "others' intents" layer removed per #2 — was unrequested UI; tests dropped with it.)

        // MARK: C4 — people search + pin-to-top (pure).
        let people = [("1", "Alice"), ("2", "Bob"), ("3", "Albert")]
        let byName = PeopleFilter.arrange(people, query: "al", pinned: [], id: { $0.0 }, name: { $0.1 })
        check(byName.map(\.1) == ["Alice", "Albert"], "C4: name filter is case-insensitive substring")
        let pinned = PeopleFilter.arrange(people, query: "", pinned: ["2"], id: { $0.0 }, name: { $0.1 })
        check(pinned.map(\.1) == ["Bob", "Alice", "Albert"], "C4: pinned person sorts to top, rest keep order")
        let noMatch = PeopleFilter.arrange(people, query: "zzz", pinned: [], id: { $0.0 }, name: { $0.1 })
        check(noMatch.isEmpty, "C4: no name match → empty")

        // MARK: B6/#8a — ONE reaction per user (setSingle): replace on a different emoji, clear on same.
        var rx: [Reaction] = []
        rx = Reaction.setSingle(rx, emoji: "👍", userID: "me", userName: "Me")
        check(rx.count == 1, "8a: first reaction added")
        rx = Reaction.setSingle(rx, emoji: "❤️", userID: "me", userName: "Me")
        check(rx.count == 1 && rx.first?.emoji == "❤️", "8a: a different emoji REPLACES (still 1 per user)")
        rx = Reaction.setSingle(rx, emoji: "❤️", userID: "me", userName: "Me")
        check(rx.isEmpty, "8a: tapping the same emoji again clears it")
        rx = Reaction.setSingle(rx, emoji: "👍", userID: "me", userName: "Me")
        rx = Reaction.setSingle(rx, emoji: "🔥", userID: "you", userName: "You")
        check(rx.count == 2, "8a: different users keep their own single reactions")
        let counts = Reaction.counts(rx)
        check(counts.contains(where: { $0.emoji == "👍" && $0.count == 1 }) && counts.contains(where: { $0.emoji == "🔥" && $0.count == 1 }),
              "8a: counts group by emoji")

        // MARK: Q4 — qual-swap acceptance via preference VALUES (higher = better, 0 = blacklist, unset = open/max).
        // Desk regions: 1–47 = Domestic(D), 48–58 = Euro(E), 60–63/72–83 = Latin(L), 64–68 = Pacific(P).
        // Someone currently on Domestic desk 10 (qual D). Values: E best, D middle, P worst.
        let prefHi: [String: Int] = ["E": 3, "D": 2, "P": 1]
        check(DeskRules.acceptsQualSwap(into: "50", fromCurrentDesk: "10", values: prefHi),
              "Q4: into a higher-valued qual (E>D) is accepted")
        check(!DeskRules.acceptsQualSwap(into: "64", fromCurrentDesk: "10", values: prefHi),
              "Q4: into a lower-valued qual (P<D) is rejected")
        check(DeskRules.acceptsQualSwap(into: "11", fromCurrentDesk: "10", values: prefHi),
              "Q4: equal qual is accepted")
        // value 0 = blacklisted, rejected even though the move would otherwise compare.
        check(!DeskRules.acceptsQualSwap(into: "50", fromCurrentDesk: "10", values: ["D": 2, "E": 0]),
              "Q4: a qual set to 0 is blacklisted → rejected")
        // Unset qual = highest preference → accepted from a ranked current desk.
        check(DeskRules.acceptsQualSwap(into: "50", fromCurrentDesk: "10", values: ["D": 2]),
              "Q4: an unset qual is treated as highest preference → accepted")
        // nil map = fully open → any non-blacklisted move accepted.
        check(DeskRules.acceptsQualSwap(into: "64", fromCurrentDesk: "10", values: nil),
              "Q4: a nil value map is fully open → accepted")
        // Desk-number blacklist hard-blocks even when the qual value would accept.
        check(!DeskRules.acceptsQualSwap(into: "50", fromCurrentDesk: "10", values: prefHi, blacklistDesks: ["50"]),
              "Q4: a blacklisted desk number is rejected regardless of qual value")
        // Profile convenience mirrors the pure rule.
        var qp = TradeProfile(workerID: "q", displayName: "Q", openness: "all",
                              blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                              blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date())
        qp.qualValues = prefHi
        check(qp.acceptsQualSwap(into: "50", fromCurrentDesk: "10"), "Q4: profile accepts E over D")
        check(!qp.acceptsQualSwap(into: "64", fromCurrentDesk: "10"), "Q4: profile rejects P below D")
        qp.qualSwapBlacklistDesks = ["50"]
        check(!qp.acceptsQualSwap(into: "50", fromCurrentDesk: "10"), "Q4: profile rejects blacklisted desk number")

        // MARK: S-ENG-4 — qual-swap BRIDGE discovery (3-party unblock, pure).
        // A gives Euro desk 50 (needs E). Off taker B is willing but holds only [D,L] (no E).
        // Find a bridge C working the same day at start hour 5 who HOLDS E (can take 50) and is
        // on a desk whose qual B holds (so B can take C's desk), and who ACCEPTS moving onto 50.
        func bridgeProf(_ id: String, _ values: [String: Int]) -> TradeProfile {
            var p = TradeProfile(workerID: id, displayName: id, openness: "all",
                                 blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                                 blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date())
            p.qualValues = values; return p
        }
        let takerQuals = ["D", "L"]
        // C1: Domestic desk 10 (D), holds [D,E], start 5, values E>D → accepts moving to 50. VALID.
        let c1 = QualSwapShift(workerID: "C1", name: "C1", desk: "10", startHour: 5, quals: ["D", "E"])
        // C2: same as C1 but start hour 13 → excluded (different start time).
        let c2 = QualSwapShift(workerID: "C2", name: "C2", desk: "10", startHour: 13, quals: ["D", "E"])
        // C3: Pacific desk 64 (P), holds [P,E], start 5 → B can't take desk 64 (no P) → excluded.
        let c3 = QualSwapShift(workerID: "C3", name: "C3", desk: "64", startHour: 5, quals: ["P", "E"])
        // C4: Domestic desk 11 (D), holds only [D], start 5 → can't take Euro desk 50 → excluded.
        let c4 = QualSwapShift(workerID: "C4", name: "C4", desk: "11", startHour: 5, quals: ["D"])
        // C5: like C1 but values E=1 < D=2 → moving onto 50 is UNfavorable. NEW (D6): still listed, but
        // flagged `favorable == false` (a stretch ask) rather than dropped.
        let c5 = QualSwapShift(workerID: "C5", name: "C5", desk: "10", startHour: 5, quals: ["D", "E"])
        let workers: [(QualSwapShift, TradeProfile)] = [
            (c1, bridgeProf("C1", ["E": 3, "D": 2])),
            (c2, bridgeProf("C2", ["E": 3, "D": 2])),
            (c3, bridgeProf("C3", ["E": 3, "P": 2])),
            (c4, bridgeProf("C4", ["D": 2])),
            (c5, bridgeProf("C5", ["E": 1, "D": 2])),
        ]
        let bridges = QualSwap.bridges(giveDesk: "50", takerQuals: takerQuals, startHour: 5,
                                       workers: workers, excludeIDs: ["A", "B"])
        // C1 (favorable) + C5 (unfavorable) both qualify + same-hour + B can take their desk; C2 (hour),
        // C3 (B can't take Pacific 64), C4 (no E) are dropped. Favorable sorts first. (D6.)
        check(bridges.map(\.workerID) == ["C1", "C5"], "S-ENG-4: favorable (C1) + unfavorable (C5) bridges return, favorable first")
        check(bridges.first(where: { $0.workerID == "C1" })?.favorable == true
                && bridges.first(where: { $0.workerID == "C5" })?.favorable == false,
              "S-ENG-4: C1 flagged favorable, C5 flagged unfavorable")
        // Excluded IDs (A, B) never appear even if working that day.
        let withExcluded = QualSwap.bridges(giveDesk: "50", takerQuals: takerQuals, startHour: 5,
            workers: workers + [(QualSwapShift(workerID: "B", name: "B", desk: "10", startHour: 5, quals: ["D", "E"]),
                                 bridgeProf("B", ["E": 3, "D": 2]))],
            excludeIDs: ["A", "B"])
        check(!withExcluded.contains(where: { $0.workerID == "B" }), "S-ENG-4: excluded parties never bridge")
        // Global timing gate: a non-tradeable start hour yields nothing even with a perfect bridge.
        check(QualSwap.bridges(giveDesk: "50", takerQuals: takerQuals, startHour: 7,
                               workers: [(QualSwapShift(workerID: "C1", name: "C1", desk: "10", startHour: 7, quals: ["D", "E"]),
                                          bridgeProf("C1", ["E": 3, "D": 2]))],
                               excludeIDs: []).isEmpty,
              "S-ENG-4: start hour outside {5,13,22} yields no bridges (global timing rule)")

        // MARK: Q3/Q6 — qual-swap leg state machine (pure reducer).
        check(QualSwapLeg.status(acceptedCount: 0, finalized: false, declined: false, expired: false) == .waiting,
              "Q-leg: no acceptances yet → waiting")
        check(QualSwapLeg.status(acceptedCount: 1, finalized: false, declined: false, expired: false) == .offersOpen,
              "Q-leg: ≥1 acceptance, slots remain → offersOpen")
        check(QualSwapLeg.status(acceptedCount: 5, finalized: false, declined: false, expired: false) == .offersFull,
              "Q-leg: first-5 cap reached → offersFull")
        check(QualSwapLeg.status(acceptedCount: 3, finalized: true, declined: false, expired: false) == .finalized,
              "Q-leg: taker finalized → finalized (wins over open offers)")
        check(QualSwapLeg.status(acceptedCount: 2, finalized: false, declined: true, expired: false) == .invalid,
              "Q-leg: taker declined → invalid even with acceptances")
        check(QualSwapLeg.status(acceptedCount: 0, finalized: false, declined: false, expired: true) == .invalid,
              "Q-leg: no bridge accepted in time → invalid")
        check(QualSwapLeg.status(acceptedCount: 2, finalized: false, declined: false, expired: true) == .offersOpen,
              "Q-leg: acceptances stand through expiry (taker can still finalize)")
        check(QualSwapLeg.acceptIsOpen(acceptedCount: 4) && !QualSwapLeg.acceptIsOpen(acceptedCount: 5),
              "Q-leg: first-5 acceptor cap (5th fills, 6th closed)")
        check(QualSwapLegStatus.allCases.count == 5, "Q-leg: status universe is exactly 5 cases (UI completeness guard)")

        // MARK: Q3/Q5/Q6 — embedded qual-swap leg data (first-5 cap, idempotency, derived status).
        let qsCands = (1...7).map { QualSwapCandidate(workerID: "C\($0)", name: "C\($0)", desk: "1\($0)", qual: "D") }
        var qleg = QualSwapLegData(giveShiftDayID: "2026-07-01", giveDesk: "50", giveQual: "E",
                                   takerID: "B", takerName: "B", candidates: qsCands)
        check(qleg.status == .waiting, "Q-leg-data: fresh leg is waiting")
        for i in 1...6 {
            qleg = qleg.addingAcceptance(QualSwapAcceptance(workerID: "C\(i)", name: "C\(i)", desk: "1\(i)", qual: "D", acceptedAt: Date()))
        }
        check(qleg.acceptances.count == 5, "Q-leg-data: first-5 acceptor cap holds (6th ignored)")
        check(qleg.status == .offersFull, "Q-leg-data: 5 acceptances → offersFull")
        let beforeDup = qleg.acceptances.count
        qleg = qleg.addingAcceptance(QualSwapAcceptance(workerID: "C1", name: "C1", desk: "11", qual: "D", acceptedAt: Date()))
        check(qleg.acceptances.count == beforeDup, "Q-leg-data: duplicate acceptance ignored (idempotent)")
        qleg.chosenWorkerID = "C2"
        check(qleg.status == .finalized && qleg.chosenAcceptance?.workerID == "C2", "Q-leg-data: chosen bridge → finalized")
        var qleg2 = QualSwapLegData(giveShiftDayID: "d", giveDesk: "50", giveQual: "E",
                                    takerID: "B", takerName: "B", candidates: qsCands)
        qleg2.takerDeclined = true
        check(qleg2.status == .invalid, "Q-leg-data: taker decline → invalid")

        // MARK: Q3 — role classifier + status text (drives inbox UI).
        let legForRole = QualSwapLegData(giveShiftDayID: "d", giveDesk: "50", giveQual: "E",
                                         takerID: "B", takerName: "B",
                                         candidates: [QualSwapCandidate(workerID: "C1", name: "C1", desk: "10", qual: "D")])
        let reqRole = TradeRequest(id: "r1", fromID: "A", fromName: "A", toID: "B", toName: "B",
                                   note: "", takeDayIDs: [], giveDayIDs: ["d"], createdAt: Date(), expiresAt: Date(),
                                   qualSwap: legForRole)
        check(reqRole.qualSwapRole(for: "A") == .giver, "Q-role: sender is giver")
        check(reqRole.qualSwapRole(for: "B") == .taker, "Q-role: leg taker is taker")
        check(reqRole.qualSwapRole(for: "C1") == .bridge, "Q-role: blasted candidate is bridge")
        check(reqRole.qualSwapRole(for: "Z") == .none, "Q-role: uninvolved worker is none")
        check(TradeRequest(id: "r2", fromID: "A", fromName: "A", toID: "B", toName: "B", note: "",
                           takeDayIDs: [], giveDayIDs: [], createdAt: Date(), expiresAt: Date()).qualSwapRole(for: "A") == .none,
              "Q-role: no leg → none")
        check(QualSwapRole.allCases.count == 4, "Q-role: role universe is exactly 4 cases")
        check(legForRole.statusText == "Waiting on qual swap", "Q-status: fresh leg text")

        // MARK: A3 #12 — status cross-device resolution is last-write-wins.
        let early = Date(timeIntervalSince1970: 1_000)
        let late  = Date(timeIntervalSince1970: 2_000)
        check(LWW.pick(local: "old status", localAt: early, remote: "new status", remoteAt: late) == "new status",
              "A3-status: a newer remote status wins on a fresh device")
        check(LWW.pick(local: "my latest", localAt: late, remote: "stale", remoteAt: early) == "my latest",
              "A3-status: a newer local edit is kept over a stale remote")

        // MARK: H1 #18 — global metrics aggregation (pure, team-wide).
        let now18 = Date(timeIntervalSince1970: 1_700_000_000)
        let evNow = now18
        let evOld = Date(timeIntervalSince1970: 1_600_000_000)
        let ev: [MetricEvent] = [
            MetricEvent(id: "1", workerID: "A", kind: .search, createdAt: evNow),
            MetricEvent(id: "2", workerID: "B", kind: .search, createdAt: evNow),
            MetricEvent(id: "3", workerID: "A", kind: .proposed, createdAt: evNow),
            MetricEvent(id: "4", workerID: "C", kind: .trade, createdAt: evNow),
            MetricEvent(id: "5", workerID: "C", kind: .trade, createdAt: evOld),   // out of month/year
        ]
        let g = Metrics.global(ev, period: .month, now: now18)
        check(g.searches == 2 && g.proposed == 1 && g.trades == 1,
              "H1-global: month aggregation counts only this month's events by kind")
        let gAll = Metrics.global(ev, period: .allTime, now: now18)
        check(gAll.trades == 2, "H1-global: all-time includes every period")
        check(Metrics.successPercent(accepted: g.trades, proposed: g.proposed) == 100,
              "H1-global: success% from global trade/proposed counts")

        // MARK: U6 — inbox intent-match 🔥 (pure).
        // ECB offer of a day I marked Want-to-Work → 🔥.
        check(MessagingStore.intentMatch(pickupDayIDs: ["2026-08-01"], takenFromMeDayIDs: [], isECB: true,
                                          myWantToWork: ["2026-08-01"], mySeeking: []),
              "U6: ECB pickup of a Want-to-Work day → 🔥")
        // Same pickup but NON-ECB → want-to-work doesn't apply → no 🔥.
        check(!MessagingStore.intentMatch(pickupDayIDs: ["2026-08-01"], takenFromMeDayIDs: [], isECB: false,
                                          myWantToWork: ["2026-08-01"], mySeeking: []),
              "U6: want-to-work only counts for ECB")
        // A day taken from me that I marked Trade-Away → 🔥 (any request type).
        check(MessagingStore.intentMatch(pickupDayIDs: [], takenFromMeDayIDs: ["2026-08-05"], isECB: false,
                                          myWantToWork: [], mySeeking: ["2026-08-05"]),
              "U6: taking my Trade-Away day → 🔥")
        // No overlap → no 🔥.
        check(!MessagingStore.intentMatch(pickupDayIDs: ["2026-09-09"], takenFromMeDayIDs: ["2026-09-10"], isECB: true,
                                          myWantToWork: ["2026-08-01"], mySeeking: ["2026-08-05"]),
              "U6: no intent overlap → no 🔥")
        // Sender-side "Perfect Match" uses the RECIPIENT's published intents.
        check(MessagingStore.requestPerfectMatch(give: [], take: ["2026-08-05"], isECB: false,
                                                 recipientSeeking: ["2026-08-05"], recipientWantToWork: []),
              "U6: perfect match when the request takes the recipient's Trade-Away day")
        check(!MessagingStore.requestPerfectMatch(give: ["2026-08-05"], take: [], isECB: false,
                                                  recipientSeeking: [], recipientWantToWork: ["2026-08-05"]),
              "U6: want-to-work pickup only perfect-matches for ECB, not a plain swap")

        // MARK: Q2 — bridges derive the freed desk's qual + favorability (D6).
        // Give a Latin desk (72 → L). C9 holds L (can bridge), sits on Euro desk 50. `takerQuals: nil` =
        // bridge-first (green button) → no taker-can-take check.
        let favBridges = QualSwap.bridges(
            giveDesk: "72", takerQuals: nil, startHour: 5,
            workers: [(QualSwapShift(workerID: "C9", name: "C9", desk: "50", startHour: 5, quals: ["D", "E", "L"]),
                       bridgeProf("C9", ["L": 3, "E": 2]))],   // Latin(3) > Euro(2) → favorable
            excludeIDs: [])
        check(favBridges.first?.desk == "50" && favBridges.first?.qual == "E",
              "Q2: bridge frees desk 50 → derives qual E")
        check(favBridges.first?.favorable == true, "Q2: Latin pref (3) ≥ Euro (2) → favorable")
        // Unfavorable (Latin ranked BELOW their Euro desk) is INCLUDED with the flag, not dropped.
        let unfavBridges = QualSwap.bridges(
            giveDesk: "72", takerQuals: nil, startHour: 5,
            workers: [(QualSwapShift(workerID: "C8", name: "C8", desk: "50", startHour: 5, quals: ["D", "E", "L"]),
                       bridgeProf("C8", ["L": 1, "E": 3]))],   // Latin(1) < Euro(3) → unfavorable
            excludeIDs: [])
        check(unfavBridges.count == 1 && unfavBridges.first?.favorable == false,
              "Q2: unfavorable bridge (Latin<Euro pref) is listed but flagged unfavorable")

        // MARK: Q1 — shared qual-gap SSOT (used by trade search + intents + routes).
        check(DeskRules.qualSwapNeeded(forDesk: "50", takerQuals: ["D"]),
              "Q1-gap: taker lacking Euro qual → swap needed for desk 50")
        check(!DeskRules.qualSwapNeeded(forDesk: "50", takerQuals: ["D", "E"]),
              "Q1-gap: taker holding Euro qual → no swap needed")
        check(!DeskRules.qualSwapNeeded(forDesk: "10", takerQuals: ["D"]),
              "Q1-gap: domestic desk needs only D → no swap")
        check(!DeskRules.qualSwapNeeded(forDesk: "OJT", takerQuals: []),
              "Q1-gap: no-gate desk → no swap")
        // Desks 46, 47, 93–98 are DOMESTIC (qual D) — explicit + guarded.
        check(["46", "47", "93", "94", "95", "96", "97", "98"].allSatisfy { DeskRules.region(forDesk: $0) == .domestic },
              "DESK: 46, 47, 93–98 are domestic")
        check(["46", "98"].allSatisfy { DeskRules.requiredQual(forDesk: $0) == "D" },
              "DESK: those domestic desks require qual D")
        // Q1 qual-BLOCKED: a Euro desk where no candidate taker holds E → blocked (needs a bridge).
        check(DeskRules.isQualBlocked(forDesk: "50", candidateTakerQuals: [["D"], ["D", "L"]]),
              "Q1-block: Euro desk with no E-qualified taker is qual-blocked")
        check(!DeskRules.isQualBlocked(forDesk: "50", candidateTakerQuals: [["D"], ["D", "E"]]),
              "Q1-block: a qualified taker present → not blocked")
        check(!DeskRules.isQualBlocked(forDesk: "50", candidateTakerQuals: []),
              "Q1-block: no takers at all is a coverage gap, not a qual block")

        // MARK: Q1 — 3-party qual-swap solution assembly (pure).
        // A gives Euro desk 50 (needs E). Bridge C1 works Domestic 10 (holds D+E), willing (E≥D).
        // Off-taker B1 holds D → can take C1's freed desk 10. Expect one solution (C1 frees 10, B1).
        let c1solo = QualSwapShift(workerID: "C1", name: "C1", desk: "10", startHour: 5, quals: ["D", "E"])
        let c2pac  = QualSwapShift(workerID: "C2", name: "C2", desk: "64", startHour: 5, quals: ["P"])      // no E → can't take 50
        let c3hr   = QualSwapShift(workerID: "C3", name: "C3", desk: "10", startHour: 13, quals: ["D", "E"]) // wrong hour
        let sols = QualSwap.solutions(
            giveDesk: "50", giveStartHour: 5, giverID: "A",
            workers: [(c1solo, bridgeProf("C1", ["E": 3, "D": 2])),
                      (c2pac, bridgeProf("C2", ["P": 1])),
                      (c3hr, bridgeProf("C3", ["E": 3, "D": 2]))],
            offTakers: [("B1", "B1", ["D"]), ("B2", "B2", ["L"])])   // B2 lacks D → can't take desk 10
        check(sols.count == 1 && sols.first?.bridgeID == "C1" && sols.first?.takerID == "B1"
              && sols.first?.bridgeDesk == "10",
              "Q1-solution: one valid (bridge C1 frees desk 10 → taker B1) solution assembled")

        // MARK: U1 — unified eligibility predicate (TradeEligibility.canCover).
        // Coverer is OFF Wed 2026-07-15; works Tue 07-14 (so covering 15 anchors → bookend).
        func rEntry(_ day: String, off: Bool, desk: String = "10", start: Int = 5, quals: [String] = ["D"]) -> RosterEntry {
            RosterEntry(workerID: "cov", workerName: "Cov", quals: quals, day: day, startHour: start, desk: desk, isOff: off)
        }
        let covMap: [String: RosterEntry] = [
            "2026-07-14": rEntry("2026-07-14", off: false),   // worked → anchor neighbor
            "2026-07-15": rEntry("2026-07-15", off: true),    // the off day we'd cover
            "2026-07-16": rEntry("2026-07-16", off: true),
        ]
        let d15 = DateComponents(calendar: .current, year: 2026, month: 7, day: 15).date!
        let openProfile = TradeProfile(workerID: "cov", displayName: "Cov", openness: "all",
                                       blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                                       blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date())
        // Physical-only: off + qualified (D for desk 10) + rested → eligible, and it's a bookend (anchors to 07-14).
        let cov1 = TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                             coverMap: covMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly)
        check(cov1.eligible && cov1.isBookend, "U1: off+qualified+rested coverer is eligible and bookended")
        // Not off that day → ineligible.
        var workingMap = covMap; workingMap["2026-07-15"] = rEntry("2026-07-15", off: false)
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                         coverMap: workingMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly).eligible,
              "U1: a coverer who isn't off that day is ineligible")
        // Not qualified (Euro desk 50 needs E, coverer holds only D) → ineligible.
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "50", startHour: 5,
                                         coverMap: covMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly).eligible,
              "U1: an unqualified coverer is ineligible")
        // Soft gates: a profile that blacklists desk 10 is rejected under .full but allowed under .physicalOnly.
        let blProfile = TradeProfile(workerID: "cov", displayName: "Cov", openness: "all",
                                     blacklistedWeekdays: [], blacklistedDesks: ["10"], blacklistedShiftTypes: [],
                                     blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date())
        check(TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                        coverMap: covMap, coverQuals: ["D"], coverProfile: blProfile, options: .physicalOnly).eligible,
              "U1: physicalOnly ignores blacklist (searcher ungated)")
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                         coverMap: covMap, coverQuals: ["D"], coverProfile: blProfile, options: .full).eligible,
              "U1: full applies soft gates — blacklisted desk rejected")
        // Option presets are distinct.
        check(EligibilityOptions.physicalOnly.applySoftGates == false && EligibilityOptions.full.applySoftGates,
              "U1: option presets differ on soft gates")

        // MARK: U1-regression — the gate matrix (hand-reasoned oracles locking the §U merge, #22).
        // (a) REST: prev day worked 1300 (ends 2200) → only 7h before a 0500 cover → not rested.
        var restMap = covMap
        restMap["2026-07-14"] = rEntry("2026-07-14", off: false, start: 13)
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                         coverMap: restMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly).eligible,
              "U1-rest: <8h rest (2200→0500) → ineligible")
        // (c) BOOKEND: an ISOLATED off day (no adjacent work) → eligible but NOT a bookend.
        let isoMap = ["2026-07-15": rEntry("2026-07-15", off: true)]
        let isoChk = TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                               coverMap: isoMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly)
        check(isoChk.eligible && !isoChk.isBookend, "U1-bookend: isolated off day → eligible, NOT a bookend")
        // (d) SOFT GATE: openness=none → wouldPickUp false → fails under .full, passes .physicalOnly.
        let noneProfile = TradeProfile(workerID: "cov", displayName: "Cov", openness: "none",
                                       blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                                       blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date())
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                         coverMap: covMap, coverQuals: ["D"], coverProfile: noneProfile, options: .full).eligible,
              "U1-soft: openness=none → ineligible under .full")
        check(TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                        coverMap: covMap, coverQuals: ["D"], coverProfile: noneProfile, options: .physicalOnly).eligible,
              "U1-soft: .physicalOnly ignores openness")

        // MARK: U1-dispatch — only genuine dispatch shifts trade. A training (TRN) desk or an
        // irregular start hour is NEVER coverable, regardless of off/qualified/rested. (User: a
        // permanent-TRN peer like Lee Roper is "not a dispatch shift" → not available for trading.)
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "TRN", startHour: 5,
                                         coverMap: covMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly).eligible,
              "U1-dispatch: a training (TRN) desk is never coverable — not a dispatch shift")
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 7,
                                         coverMap: covMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly).eligible,
              "U1-dispatch: an irregular start hour (0700) is never coverable")
        check(TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                        coverMap: covMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly).eligible,
              "U1-dispatch: a regular 0500 dispatch desk still covers (regression)")
        check(!TradeTiming.isDispatchShift(desk: "TRN", startHour: 5), "U1-dispatch: isDispatchShift false for TRN desk")
        check(!TradeTiming.isDispatchShift(desk: "10", startHour: 7), "U1-dispatch: isDispatchShift false for irregular hour")
        check(TradeTiming.isDispatchShift(desk: "10", startHour: 13), "U1-dispatch: isDispatchShift true for 1300 dispatch")

        // MARK: Daily digest copy — plural-correct summary sentence; friendly zero-state.
        check(NotificationManager.digestBody(pending: 0, unread: 0) == "Nothing needs you right now — tap to browse your matches.",
              "digest: zero state")
        check(NotificationManager.digestBody(pending: 1, unread: 0) == "You have 1 pending trade. Tap to review.",
              "digest: singular pending")
        check(NotificationManager.digestBody(pending: 3, unread: 2) == "You have 3 pending trades and 2 unread messages. Tap to review.",
              "digest: both, pluralized")

        // MARK: U-RECV — a day I RECEIVE back must be a clean bookend for me (attaches to my work) or a
        // day I explicitly marked want-to-work; a random mid-week island is dropped. Bookends rank first.
        // (User: rank bookends higher even when my openness is open-to-everything.)
        do {
            func rleg(_ id: String, _ day: Int, bookend: Bool) -> TwoWayLeg {
                let date = DateComponents(calendar: .current, year: 2026, month: 9, day: day).date!
                return TwoWayLeg(dayID: id, date: date, desk: "29", startHour: 5, bookend: bookend, wanted: false)
            }
            let island = rleg("2026-09-15", 15, bookend: false)   // Mitchell's random mid-week Sep 15
            let clean1 = rleg("2026-09-07", 7,  bookend: true)
            let clean2 = rleg("2026-09-22", 22, bookend: true)
            // Bookends Only → the island is DROPPED; clean bookends kept, soonest-first.
            let strict = TradeRouter.cleanReceiveLegs([island, clean2, clean1], wantToWork: [], bookendsOnly: true)
            check(strict.map(\.dayID) == ["2026-09-07", "2026-09-22"],
                  "U-RECV: Bookends-Only excludes the non-bookend island")
            // Open-to-all → the island is KEPT but sorted LAST (bookends preferred).
            let open = TradeRouter.cleanReceiveLegs([island, clean2, clean1], wantToWork: [], bookendsOnly: false)
            check(open.map(\.dayID) == ["2026-09-07", "2026-09-22", "2026-09-15"],
                  "U-RECV: open-to-all keeps the island but ranks bookends first")
            // A want-to-work day I marked is kept even under Bookends Only.
            let kept = TradeRouter.cleanReceiveLegs([island], wantToWork: ["2026-09-15"], bookendsOnly: true)
            check(kept.map(\.dayID) == ["2026-09-15"],
                  "U-RECV: a want-to-work day I marked is kept even if it isn't a bookend")
            // Ranking: an all-clean package outranks a dirtier one (hands me an island) even with MORE coverage.
            var dirtyPkg = TradePackage(id: "dirty", methodology: .greedy, assignments: [], route: nil)
            dirtyPkg.coverageCount = 4; dirtyPkg.dirtyReceives = 1
            var cleanPkg = TradePackage(id: "clean", methodology: .greedy, assignments: [], route: nil)
            cleanPkg.coverageCount = 3; cleanPkg.dirtyReceives = 0
            check(TradeRouter.rankLess(cleanPkg, dirtyPkg),
                  "U-RECV: an all-clean package ranks above a dirtier one even with less coverage")
        }

        // MARK: A8 — a peer with NO published profile defaults to Bookends Only (conservative):
        // never offered a non-bookend (split-the-weekend) pickup until they opt into broader trading.
        do {
            let unpub = TradeProfile.defaultForUnpublished(workerID: "999", name: "Nobody")
            check(unpub.openness == TradeOpenness.bookends.rawValue, "A8: unpublished profile defaults to Bookends Only")
            let openPub = TradeProfile(workerID: "888", displayName: "Open", openness: TradeOpenness.all.rawValue,
                                       blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                                       blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date.distantPast)
            check(openPub.openness == TradeOpenness.all.rawValue, "A8: an explicitly-published Open profile stays Open (only MISSING profiles default)")
            let isoSplit = ["2026-07-15": rEntry("2026-07-15", off: true)]   // isolated off day → non-bookend (split)
            check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                             coverMap: isoSplit, coverQuals: ["D"], coverProfile: unpub, options: .full).eligible,
                  "A8: profileless (bookends) receiver REJECTS a non-bookend split pickup")
            check(TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                            coverMap: covMap, coverQuals: ["D"], coverProfile: unpub, options: .full).eligible,
                  "A8: profileless (bookends) receiver ACCEPTS a bookend pickup")
            check(TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                            coverMap: isoSplit, coverQuals: ["D"], coverProfile: openPub, options: .full).eligible,
                  "A8: an Open profile still accepts the split (proves the default is what changes behavior)")
        }

        // MARK: D1/F1 — POSITIONAL trade colors: you = blue, then seat-by-seat red → orange → green.
        do {
            let me = "me", p1 = "A", p2 = "B", p3 = "C"
            let order = [p1, p2, p3]   // the non-me participants in seat order
            check(TradeColors.color(forParticipant: me, myID: me, orderedPeers: order) == BrickPalette.mineScheme, "F1: you are always blue")
            check(TradeColors.color(forParticipant: p1, myID: me, orderedPeers: order) == BrickPalette.traderThemes[0], "F1: 2nd person = seat-1 color (red)")
            check(TradeColors.color(forParticipant: p2, myID: me, orderedPeers: order) == BrickPalette.traderThemes[1], "F1: 3rd person = seat-2 color (orange)")
            check(TradeColors.color(forParticipant: p3, myID: me, orderedPeers: order) == BrickPalette.traderThemes[2], "F1: 4th person = seat-3 color (green)")
            check(BrickPalette.traderThemes[0] == BrickPalette.peerScheme, "F1: seat-1 (2nd person) is red")
            check(BrickPalette.traderThemes.count >= 3, "F1: palette has ≥ red/orange/green")
        }

        // MARK: G2a — peer name resolution (the IMG-42 "660615" bug). Prefer a real
        // displayName → real roster name → employee #; a numeric "name" is never preferred.
        do {
            check(TradeNames.resolved(displayName: "Lee, Ervin", rosterName: "660615", workerID: "660615") == "Lee, Ervin",
                  "G2a: a real displayName wins over a numeric roster name")
            check(TradeNames.resolved(displayName: nil, rosterName: "Khuu, Julie", workerID: "555") == "Khuu, Julie",
                  "G2a: falls back to a real roster name when no displayName")
            check(TradeNames.resolved(displayName: "660615", rosterName: "Mitchell, Kristi", workerID: "660615") == "Mitchell, Kristi",
                  "G2a: a numeric displayName is rejected in favor of a real roster name")
            check(TradeNames.resolved(displayName: nil, rosterName: nil, workerID: "660615") == "660615",
                  "G2a: with no real name, falls back to the employee #")
            check(TradeNames.resolved(displayName: "  ", rosterName: "660615", workerID: "660615") == "660615",
                  "G2a: blank/numeric everywhere → employee # (nothing real to show)")
        }

        // MARK: D4 (revised) — a single generic "Propose" label for every count (user pref).
        check(proposeButtonTitle(count: 1, name: "Cary") == "Propose", "D4: always generic 'Propose' (1)")
        check(proposeButtonTitle(count: 4, name: "Cary") == "Propose", "D4: always generic 'Propose' (many)")

        // MARK: G2c — peer's FULL intent palette on the two-way calendar (was only trade-away).
        // Precedence: must-be-off → keep → trade-away (seeking) → want-to-work; else nil.
        do {
            let mbo = "2027-01-01", keep = "2027-01-02", seek = "2027-01-03", wtw = "2027-01-04", none = "2027-01-05"
            let sk: Set<String> = [seek], ww: Set<String> = [wtw], mb: Set<String> = [mbo], kp: Set<String> = [keep]
            check(PeerIntentColor.forDay(mbo, seeking: sk, wantToWork: ww, mustBeOff: mb, keep: kp) == OffIntentState.mustBeOff.brickColor, "G2c: must-be-off day → locked-off color")
            check(PeerIntentColor.forDay(keep, seeking: sk, wantToWork: ww, mustBeOff: mb, keep: kp) == WorkingIntentState.mustWork.brickColor, "G2c: keep day → keep color")
            check(PeerIntentColor.forDay(seek, seeking: sk, wantToWork: ww, mustBeOff: mb, keep: kp) == WorkingIntentState.dontWantToWork.brickColor, "G2c: trade-away day → change color")
            check(PeerIntentColor.forDay(wtw, seeking: sk, wantToWork: ww, mustBeOff: mb, keep: kp) == OffIntentState.wantToWork.brickColor, "G2c: want-to-work day → available color")
            check(PeerIntentColor.forDay(none, seeking: sk, wantToWork: ww, mustBeOff: mb, keep: kp) == nil, "G2c: an unmarked day has no peer-intent tint")
            // Precedence: a day in BOTH must-be-off and seeking shows must-be-off (strongest).
            check(PeerIntentColor.forDay(mbo, seeking: [mbo], wantToWork: [], mustBeOff: [mbo], keep: []) == OffIntentState.mustBeOff.brickColor,
                  "G2c: must-be-off outranks trade-away when a day is in both")
        }

        // MARK: #3 — a separate two-person trade always outranks a three-person circular loop
        // (Intents prefers individual pairwise trades; loops sink below them).
        do {
            let two = TradePackage(id: "two", methodology: .greedy,
                                   assignments: [PackageAssignment(workerID: "A", name: "A", giveDayIDs: ["d"], takeDayIDs: ["e"])], route: nil)
            let loop = TradePackage(id: "loop", methodology: .circular,
                                    assignments: [PackageAssignment(workerID: "A", name: "A", giveDayIDs: ["d"], takeDayIDs: []),
                                                  PackageAssignment(workerID: "B", name: "B", giveDayIDs: ["f"], takeDayIDs: [])],
                                    route: nil, fireCount: 9)
            check(TradeRouter.rankPackages([loop, two]).first?.id == "two",
                  "#3: a two-person trade outranks a three-person loop even when the loop has more 🔥")
        }

        // MARK: D5 — qual-swap packages sort UNDER clean ones for the SAME N (regardless of 🔥/
        // bookend); usual priorities apply WITHIN each group; people-count still dominates.
        do {
            func pkg(_ id: String, peers: [String], fire: Int, qual: Bool) -> TradePackage {
                let a = peers.map { PackageAssignment(workerID: $0, name: $0, giveDayIDs: ["2027-02-01"], takeDayIDs: ["2027-02-02"]) }
                let q: QualSwapLegData? = qual ? QualSwapLegData(giveShiftDayID: "2027-02-01", giveDesk: "50",
                        giveQual: "E", takerID: peers.first ?? "A", takerName: peers.first ?? "A", candidates: []) : nil
                return TradePackage(id: id, methodology: .greedy, assignments: a, route: nil,
                                    fireCount: fire, bookendTotal: 0, qualSwap: q)
            }
            let r1 = TradeRouter.rankPackages([pkg("qual", peers: ["A"], fire: 5, qual: true),
                                               pkg("clean", peers: ["B"], fire: 0, qual: false)])
            check(r1.first?.id == "clean", "D5: clean 2-way sorts above a qual-swap 2-way even with more 🔥")
            let r2 = TradeRouter.rankPackages([pkg("qlow", peers: ["A"], fire: 1, qual: true),
                                               pkg("qhigh", peers: ["C"], fire: 9, qual: true)])
            check(r2.first?.id == "qhigh", "D5: within the qual group, more 🔥 sorts first (usual priorities)")
            let r3 = TradeRouter.rankPackages([pkg("clean3", peers: ["A", "B"], fire: 9, qual: false),
                                               pkg("qual2", peers: ["C"], fire: 0, qual: true)])
            check(r3.first?.id == "qual2", "D5: people-count dominates — a qual 2-way precedes a clean 3-way")
        }

        // MARK: G4 — import-success audit. Flags name-less workers (the "660615" malformed
        // import), missing-self, duplicate IDs, empty parse; clean import → ok with no warnings.
        do {
            let clean = ImportAudit.validate(workers: [("001", "Lee, Ervin"), ("002", "Khuu, Julie")], selfID: "001")
            check(clean.ok && clean.warnings.isEmpty && clean.workerCount == 2, "G4: a clean import passes with no warnings")
            let nameless = ImportAudit.validate(workers: [("660615", "660615"), ("002", "Khuu, Julie")], selfID: "002")
            check(!nameless.ok && nameless.namelessWorkers.contains("660615"), "G4: a worker named like its employee # is flagged nameless")
            let noSelf = ImportAudit.validate(workers: [("001", "Lee, Ervin")], selfID: "999")
            check(!noSelf.ok && !noSelf.selfFound, "G4: the importer's own ID missing is flagged")
            let dupes = ImportAudit.validate(workers: [("001", "A"), ("001", "A2")], selfID: "001")
            check(!dupes.ok && dupes.duplicateIDs.contains("001"), "G4: duplicate employee IDs are flagged")
            let empty = ImportAudit.validate(workers: [], selfID: "001")
            check(!empty.ok && empty.workerCount == 0, "G4: an empty parse is flagged (wrong file format)")
        }

        // MARK: H1 — unified acceptance-likelihood score (log-joint). legProb is a sigmoid of
        // weighted features; package = product (weakest-link); pruning bound is admissible.
        do {
            func leg(_ book: Bool, take: Bool, trade: Bool) -> LegFeatures {
                LegFeatures(wantToTake: take, wantToTrade: trade, bookend: book, timeValue: 0, needsQualBridge: false)
            }
            let dualBook = leg(true, take:true, trade:true), dualSplit = leg(false, take:true, trade:true)
            let singleBook = leg(true, take:true, trade:false), singleSplit = leg(false, take:true, trade:false)
            let noBook = leg(true, take:false, trade:false), noSplit = leg(false, take:false, trade:false)
            // Intent tiers: dual > single > none (same bookend).
            check(TradeScore.legProb(dualBook) > TradeScore.legProb(singleBook), "H1: dual want > single want")
            check(TradeScore.legProb(singleBook) > TradeScore.legProb(noBook), "H1: single want > no intent")
            // Bookend beats split within a tier.
            check(TradeScore.legProb(dualBook) > TradeScore.legProb(dualSplit), "H1: bookend > split (same intent)")
            // DUAL intent OVERRIDES a split: dual+split outranks no-intent+bookend.
            check(TradeScore.legProb(dualSplit) > TradeScore.legProb(noBook), "H1: dual intent overrides a split (dual+split > no-intent bookend)")
            // But a SINGLE want does NOT beat a clean no-intent trade.
            check(TradeScore.legProb(noBook) > TradeScore.legProb(singleSplit), "H1: no-intent bookend > single+split (single doesn't override)")
            check((0...1).contains(TradeScore.legProb(noSplit)), "H1: legProb is a probability in [0,1]")
            // package = product; weakest-link.
            check(TradeScore.packageProb([dualBook, noSplit]) < TradeScore.packageProb([dualBook, dualBook]),
                  "H1: one weak leg drags the package down (weakest-link)")
            check(abs(TradeScore.packageProb([dualBook, dualSplit]) - exp(TradeScore.packageLogProb([dualBook, dualSplit]))) < 1e-9,
                  "H1: packageProb == exp(packageLogProb)")
            // N-penalty: a bigger all-perfect package scores BELOW a smaller imperfect one.
            check(TradeScore.packageLogProb(Array(repeating: dualBook, count: 3)) < TradeScore.packageLogProb(Array(repeating: dualSplit, count: 2)),
                  "H1/N-penalty: all-dual+book(3) < all-dual+split(2)")
            // admissible bound: adding legs never RAISES the log-prob.
            check(TradeScore.packageLogProb([dualBook]) >= TradeScore.packageLogProb([dualBook, dualBook]) - 1e-12,
                  "H1: partial-route log-prob is an admissible upper bound")
            // ECB lever: more points offered → higher acceptance.
            var ecbLo = noBook; ecbLo.ecbValue = 0.1
            var ecbHi = noBook; ecbHi.ecbValue = 0.9
            check(TradeScore.legProb(ecbHi) > TradeScore.legProb(ecbLo), "H1: more ECB offered → higher acceptance")
        }

        // MARK: G3 — a circular route's desirability drops when a leg SPLITS its receiver's
        // time off (non-bookend); all-bookend routes score highest.
        check(TradeScore.routeDesirability(legBookends: [true, true, true], legFires: [false, false, false])
              > TradeScore.routeDesirability(legBookends: [true, false, true], legFires: [false, false, false]),
              "G3: a split leg lowers the route's desirability vs all-bookend")
        check(TradeScore.routeDesirability(legBookends: [true, true], legFires: [true, true])
              > TradeScore.routeDesirability(legBookends: [true, true], legFires: [false, false]),
              "G3: mutual-🔥 legs raise the route's desirability")
        check(TradeScore.routeDesirability(legBookends: [], legFires: []) == 0, "G3: empty route → logprob 0")

        // MARK: A2 — Master Filter (pure): engine selector, max-people cap, force-include person.
        do {
            func pkg(_ id: String, peers: [String], circular: Bool) -> TradePackage {
                let a = peers.map { PackageAssignment(workerID: $0, name: $0, giveDayIDs: ["d"], takeDayIDs: ["e"]) }
                return TradePackage(id: id, methodology: circular ? .circular : .greedy, assignments: a, route: nil)
            }
            let pkgs = [pkg("solo", peers: ["A"], circular: false),       // 2 people
                        pkg("tri", peers: ["A", "B"], circular: true),     // 3 people
                        pkg("quad", peers: ["A", "B", "C"], circular: true)] // 4 people
            check(SearchFilter(engine: .both, maxPeople: 2, requiredWorkerID: nil).filter(pkgs, selfID: "").allSatisfy { $0.peopleCount <= 2 },
                  "A2: maxPeople caps participant count")
            check(SearchFilter(engine: .both, maxPeople: 4, requiredWorkerID: nil).filter(pkgs, selfID: "").count == 3, "A2: maxPeople 4 keeps all")
            check(SearchFilter(engine: .minCost, maxPeople: 4, requiredWorkerID: nil).filter(pkgs, selfID: "").allSatisfy { $0.methodology != .circular },
                  "A2: minCost engine drops circular")
            check(SearchFilter(engine: .nWay, maxPeople: 4, requiredWorkerID: nil).filter(pkgs, selfID: "").allSatisfy { $0.methodology == .circular },
                  "A2: nWay engine keeps only circular")
            let req = SearchFilter(engine: .both, maxPeople: 4, requiredWorkerID: "C").filter(pkgs, selfID: "")
            check(!req.isEmpty && req.allSatisfy { $0.assignments.contains { a in a.workerID == "C" } },
                  "A2: required person → only solutions containing them")
            check(Set(SearchFilter.Engine.allCases.map(\.rawValue)) == ["minCost", "nWay", "both"], "A2: engine CaseIterable universe guard")

            // A2b: Lucky button state — default is NOT active; any narrowing IS; summary shows only non-defaults.
            check(!SearchFilter.normal.isActive, "A2b: default filter is not active (shows everything)")
            check(SearchFilter(engine: .nWay, maxPeople: 4, requiredWorkerID: nil).isActive, "A2b: a narrowed engine is active")
            check(SearchFilter(engine: .both, maxPeople: 3, requiredWorkerID: nil).isActive, "A2b: a lowered max-people is active")
            check(SearchFilter.normal.summary(nameFor: { $0 }) == nil, "A2b: default filter has no summary")
            let sum = SearchFilter(engine: .nWay, maxPeople: 3, requiredWorkerID: "C").summary(nameFor: { _ in "Cary" })
            check(sum == "N-Way · ≤3 · with Cary", "A2b: summary lists only the non-default selections")
            check(SearchFilter(engine: .both, maxPeople: 4, requiredWorkerID: "C").summary(nameFor: { _ in "Cary" }) == "with Cary",
                  "A2b: summary omits defaulted engine/people, keeps the required person")

            // U-PERF: the fast BACKGROUND scope must stay 2-person / minCost — these thresholds GATE the
            // expensive 3+ multi-cover (maxPeople >= 3) and N-Way circular (engine != minCost) in packages().
            check(SearchFilter.fast.maxPeople == 2, "U-PERF: fast generation caps at 2 people (no 3+ multi-cover)")
            check(SearchFilter.fast.engine == .minCost, "U-PERF: fast generation is minCost (no N-Way circular DFS)")
            check(SearchFilter.fast.maxPeople < 3 && SearchFilter.fast.engine == .minCost,
                  "U-PERF: fast scope fails BOTH heavy-step gates (3+ and N-Way) — background stays cheap")
        }

        // MARK: INTENTS MARKETPLACE — pure deal assembler + intent-first ranking (distinct from packages).
        do {
            // Both sides marked → mutual deal, every leg counts toward intent score.
            let both = TradeRouter.assembleIntentDeal(.init(
                myGiveMarked: ["A1", "A2"], myGivePref: [],
                theirGiveMarked: ["B1", "B2"], theirGivePref: []))
            check(both?.gives == ["A1", "A2"] && both?.takes == ["B1", "B2"] && both?.mutualMarked == 4,
                  "Intents: both-sides-marked deal counts all 4 legs as mutual intent")

            // PEER-seeded: I marked NO give, but the peer marked a day I'd take → still a deal,
            // balanced with my pref give. This is the marketplace difference vs packages().
            let peerSeeded = TradeRouter.assembleIntentDeal(.init(
                myGiveMarked: [], myGivePref: ["P1"],
                theirGiveMarked: ["B1"], theirGivePref: []))
            check(peerSeeded?.gives == ["P1"] && peerSeeded?.takes == ["B1"] && peerSeeded?.mutualMarked == 1,
                  "Intents: a peer's marked day seeds a deal even when I marked no give (mutual=1, their side only)")

            // Neither side marked → NOT in the marketplace (pure availability is not an intent match).
            check(TradeRouter.assembleIntentDeal(.init(
                myGiveMarked: [], myGivePref: ["P1"], theirGiveMarked: [], theirGivePref: ["Q1"])) == nil,
                  "Intents: no marked intent on either side → no marketplace deal")

            // Unbalanced → trims to k = min, keeping MARKED legs first (they're ordered ahead of pref).
            let unbal = TradeRouter.assembleIntentDeal(.init(
                myGiveMarked: ["A1"], myGivePref: ["P1", "P2"],
                theirGiveMarked: ["B1"], theirGivePref: []))
            check(unbal?.gives == ["A1"] && unbal?.takes == ["B1"] && unbal?.mutualMarked == 2,
                  "Intents: balances to k=min and keeps the marked legs (drops surplus pref gives)")

            // Intent-first ranking: a 3-person package with MORE mutual intent outranks a 2-person with less.
            func pkg(_ id: String, people: Int, fire: Int) -> TradePackage {
                let others = (1..<people).map { PackageAssignment(workerID: "\(id)-\($0)", name: "n", giveDayIDs: ["d"], takeDayIDs: ["e"]) }
                var p = TradePackage(id: id, methodology: .greedy, assignments: others, route: nil)
                p.fireCount = fire; return p
            }
            let ranked = TradeRouter.rankIntentPackages([pkg("two", people: 2, fire: 1), pkg("three", people: 3, fire: 3)])
            check(ranked.first?.id == "three", "Intents: MOST mutual intent ranks first, even with more people (vs Trade Solutions' fewest-people-first)")

            // H2: person-prior — neutral at no history; +/- with accept/decline; clamped; weights the logit.
            check(PersonPrior.logOdds(accepted: 0, declined: 0) == 0, "H2: no history → neutral prior (0)")
            check(PersonPrior.logOdds(accepted: 5, declined: 0) > 0, "H2: a history of accepting → positive prior")
            check(PersonPrior.logOdds(accepted: 0, declined: 5) < 0, "H2: a history of declining → negative prior")
            check(PersonPrior.logOdds(accepted: 1000, declined: 0) <= 2.0001, "H2: prior is clamped (thin/extreme record can't dominate)")
            var fHi = LegFeatures(wantToTake: false, wantToTrade: false, bookend: true, timeValue: 0.5, needsQualBridge: false)
            var fLo = fHi; fHi.personPrior = 1.5; fLo.personPrior = -1.5
            check(TradeScore.legProb(fHi) > TradeScore.legProb(fLo), "H2: a higher person-prior raises the leg's acceptance probability")

            // H2 tiebreaker: equal intent/people/bookends → the higher partnerPrior package ranks first.
            var pa = pkg("low", people: 2, fire: 2); pa.partnerPrior = -0.5
            var pb = pkg("high", people: 2, fire: 2); pb.partnerPrior = 0.5
            check(TradeRouter.rankIntentPackages([pa, pb]).first?.id == "high", "H2: all else equal, the likelier-to-accept partner ranks first")

            // Safety ceiling: intentSolutions never shows more than intentResultCap (the score floor
            // does the real curation; this is just a runaway guard).
            check(TradeRouter.intentResultCap == 60, "Intents: safety ceiling is 60")
            let many = (0..<70).map { pkg("p\($0)", people: 2, fire: $0 % 5) }
            check(Array(TradeRouter.rankIntentPackages(many).prefix(TradeRouter.intentResultCap)).count == 60,
                  "Intents: safety ceiling caps the list at 60")

            // finalize (unified gate): AVERAGE-leg-quality floor (normal 0.32 / Lucky 0.07), then
            // coverage-first ranking, with a top-N empty-feed fallback. acceptanceScore is now 0…1.
            func fpkg(_ id: String, _ prob: Double, coverage: Int = 0) -> TradePackage {
                var p = TradePackage(id: id, methodology: .greedy,
                                     assignments: [PackageAssignment(workerID: "w", name: "n", giveDayIDs: ["d"], takeDayIDs: ["e"])],
                                     route: nil)
                p.acceptanceScore = prob; p.coverageCount = coverage; return p
            }
            let hi = fpkg("hi", 0.9), midp = fpkg("mid", 0.2), lop = fpkg("lo", 0.02)
            check(TradeRouter.finalize([midp, lop, hi], lucky: false).map(\.id) == ["hi"],
                  "finalize: normal floor (0.32) keeps only ≥0.32 avg-quality")
            check(TradeRouter.finalize([midp, lop, hi], lucky: true).map(\.id) == ["hi", "mid"],
                  "finalize: Lucky floor (0.07) admits more")
            check(TradeRouter.finalize([fpkg("w1", 0.01), fpkg("w2", 0.005)], lucky: false).map(\.id) == ["w1", "w2"],
                  "finalize: empty-feed fallback shows the top few by quality when nothing clears the floor")
            // THE FIX: a full-cover (more of your days) outranks a higher-scored single-day.
            let fullCover = fpkg("full", 0.80, coverage: 3), oneDay = fpkg("one", 0.95, coverage: 1)
            check(TradeRouter.finalize([oneDay, fullCover], lucky: false).map(\.id).first == "full",
                  "finalize: coverage-first — a 3-day full-cover beats a higher-scored 1-day")

            // packageQuality: covering more DAYS (more legs) with one person doesn't lower quality; more
            // PEOPLE does. (This is what un-buried the full-cover.)
            let cleanLeg = LegFeatures(wantToTake: true, wantToTrade: true, bookend: true,
                                       timeValue: 1, needsQualBridge: false)
            let q2legs = TradeScore.packageQuality(Array(repeating: cleanLeg, count: 2), people: 2)
            let q6legs = TradeScore.packageQuality(Array(repeating: cleanLeg, count: 6), people: 2)
            check(abs(q2legs - q6legs) < 0.0001, "packageQuality: more days (legs) with one person → same quality")
            check(TradeScore.packageQuality(Array(repeating: cleanLeg, count: 4), people: 3) < q2legs,
                  "packageQuality: more PEOPLE lowers quality")

            // Giver-side bookend: a peer's mid-week give (island off) is NOT clean; an edge day is.
            func rEntry(_ day: String, _ off: Bool) -> RosterEntry {
                RosterEntry(workerID: "R", workerName: "R", quals: ["D"], day: day, startHour: 5, desk: "10", isOff: off)
            }
            // Off Sun 13 · work Mon14–Fri18 · off Sat19
            let rDays: [(String, Bool)] = [("2026-09-13", true), ("2026-09-14", false), ("2026-09-15", false),
                                           ("2026-09-16", false), ("2026-09-17", false), ("2026-09-18", false), ("2026-09-19", true)]
            let rMap = Dictionary(rDays.map { ($0.0, rEntry($0.0, $0.1)) }, uniquingKeysWith: { a, _ in a })
            check(!TradeMatcher.isCleanGiveAway(day: TradeMatcher.dayDate(fromISO: "2026-09-15")!, map: rMap, cal: Calendar.current),
                  "give-bookend: a mid-week give (both neighbors worked → island off) is NOT clean")
            check(TradeMatcher.isCleanGiveAway(day: TradeMatcher.dayDate(fromISO: "2026-09-18")!, map: rMap, cal: Calendar.current),
                  "give-bookend: an edge give (neighbor off) IS clean")

            // A1 best-first seeding: highest score first, then soonest day (give-day IDs sort chronologically).
            check(TradeRouter.bestFirstSeeds([("2026-07-10", 0.5), ("2026-07-04", 3.5), ("2026-07-02", 0.5)])
                  == ["2026-07-04", "2026-07-02", "2026-07-10"],
                  "A1: best-first seeds order by score desc, then sooner date")
            check(TradeRouter.bestFirstSeeds([("2026-07-09", 2.0), ("2026-07-03", 2.0)]) == ["2026-07-03", "2026-07-09"],
                  "A1: equal score → the sooner day seeds first")
            // A1 seedScore folds urgency (dominant) + TradeScore (timeValue/qual friction refine ties).
            check(TradeRouter.seedScore(urgency: 3, daysUntil: 0, qualGatedDesk: false)
                  > TradeRouter.seedScore(urgency: 0, daysUntil: 0, qualGatedDesk: false),
                  "A1: higher urgency → higher seed score (urgency dominates)")
            check(TradeRouter.seedScore(urgency: 2, daysUntil: 1, qualGatedDesk: false)
                  > TradeRouter.seedScore(urgency: 2, daysUntil: 30, qualGatedDesk: false),
                  "A1: same urgency, sooner day → higher seed score (TradeScore timeValue)")
            check(TradeRouter.seedScore(urgency: 2, daysUntil: 5, qualGatedDesk: false)
                  > TradeRouter.seedScore(urgency: 2, daysUntil: 5, qualGatedDesk: true),
                  "A1: a qual-gated desk lowers the seed score (TradeScore qual friction)")

        }

        // MARK: #9 — Reddit-style reply threading (pure pre-order tree + subtree collapse).
        do {
            func rep(_ id: String, _ parent: String?, _ t: Double) -> BroadcastReply {
                BroadcastReply(id: id, postID: "P", authorID: "a", authorName: "A", text: id,
                               isPublic: true, createdAt: Date(timeIntervalSince1970: t), parentReplyID: parent)
            }
            // a (root) → b (child of a) → d (child of b); c is a 2nd root after a. Siblings oldest-first.
            let flat = [rep("c", nil, 30), rep("a", nil, 10), rep("d", "b", 25), rep("b", "a", 20)]
            let tree = ReplyThread.flatten(flat)
            check(tree.map(\.reply.id) == ["a", "b", "d", "c"], "#9: pre-order walk (parent then descendants), roots oldest-first")
            check(tree.map(\.depth) == [0, 1, 2, 0], "#9: nesting depth tracks the tree level")

            // Orphan (parent missing) surfaces at top level, never dropped.
            let orphan = ReplyThread.flatten([rep("x", "ghost", 5)])
            check(orphan.map(\.reply.id) == ["x"] && orphan.first?.depth == 0, "#9: a reply with a missing parent surfaces at top level")

            // Cycle safety: a↔b mutually parent each other → terminates, each emitted once.
            let cyclic = ReplyThread.flatten([rep("a", "b", 1), rep("b", "a", 2)])
            check(cyclic.count == 2, "#9: mutual-parent cycle terminates (each reply once)")

            // Subtree collapse: hiding a hides b and d, not c.
            check(ReplyThread.subtreeIDs(of: "a", in: flat) == ["b", "d"], "#9: subtreeIDs returns all descendants for per-comment collapse")
        }

        // MARK: E1 — channel shows newest at the top (newest → oldest); pinned still first.
        do {
            func post(_ id: String, at: TimeInterval, pinned: Bool? = nil) -> BroadcastPost {
                BroadcastPost(id: id, authorID: "x", authorName: "x", text: "t",
                              createdAt: Date(timeIntervalSince1970: at), expiresAt: Date(timeIntervalSince1970: at + 86400),
                              pinned: pinned)
            }
            let ordered = MessagingStore.sortedForChannel([post("new", at: 300), post("old", at: 100), post("mid", at: 200)])
            check(ordered.map(\.id) == ["new", "mid", "old"], "E1: channel posts show newest→oldest (latest at the top)")
            let withPin = MessagingStore.sortedForChannel([post("old", at: 100), post("pinNew", at: 500, pinned: true)])
            check(withPin.first?.id == "pinNew", "E1: a pinned post stays first regardless of age")
        }

        // MARK: B2 — merge an accepted qual-swap bridge into its base trade (one request).
        do {
            let now = Date()
            func req(_ id: String, give: [String], qual: QualSwapLegData?) -> TradeRequest {
                TradeRequest(id: id, fromID: "me", fromName: "Me", toID: "B", toName: "B", note: "",
                             takeDayIDs: [], giveDayIDs: give, createdAt: now, expiresAt: now.addingTimeInterval(86400),
                             qualSwap: qual)
            }
            let bridgeLeg = QualSwapLegData(giveShiftDayID: "2027-03-01", giveDesk: "50", giveQual: "E",
                                            takerID: "B", takerName: "B", candidates: [])
            let base = req("base", give: ["2027-03-01"], qual: nil)
            let bridge = req("bridge", give: ["2027-03-01"], qual: bridgeLeg)
            check(TradeMerge.canMerge(base: base, bridge: bridge), "B2: clean base + bridge sharing the give-day can merge")
            check(!TradeMerge.canMerge(base: req("b2", give: ["2027-03-09"], qual: nil), bridge: bridge),
                  "B2: cannot merge when the give-day doesn't match")
            check(!TradeMerge.canMerge(base: bridge, bridge: bridge), "B2: a base that already has a qual-swap can't merge again")
            let merged = TradeMerge.merge(base: base, bridge: bridge)
            check(merged.qualSwap == bridgeLeg && merged.giveDayIDs == base.giveDayIDs && merged.id != base.id,
                  "B2: merged request carries the bridge's qual-swap + base's days, with a new id")
            check(TradeMerge.merge(base: merged, bridge: bridge).id == merged.id, "B2: merging an already-merged request is a no-op")

            // B2 lifecycle (pure parts): findBase locates the mergeable clean base; active() drops the
            // archived originals and keeps the merged record — the inbox shows ONE card after merge.
            check(TradeMerge.findBase(for: bridge, in: [base, req("other", give: ["2027-03-09"], qual: nil)])?.id == "base",
                  "B2: findBase locates the clean base sharing the give-day")
            check(TradeMerge.findBase(for: bridge, in: [req("other", give: ["2027-03-09"], qual: nil)]) == nil,
                  "B2: findBase returns nil when no base shares the give-day")
            let archivedAfter: Set<String> = [base.id, bridge.id]   // what mergeRequests archives
            let activeAfter = MessagingStore.active([base, bridge, merged], archived: archivedAfter)
            check(activeAfter.map(\.id) == [merged.id], "B2: after merge, only the merged request stays active (originals archived)")
        }

        // MARK: B1 — detect a qual-gated (international) desk in the selection, which enables the
        // glowing "Qual Swap" button.
        check(DeskRules.hasQualGatedSelection(desks: ["50", "10"]), "B1: a qual-gated desk (50) enables qual-swap")
        check(!DeskRules.hasQualGatedSelection(desks: ["10", "29"]), "B1: only domestic desks → qual-swap disabled")
        check(!DeskRules.hasQualGatedSelection(desks: []), "B1: empty selection → disabled")

        // MARK: C1 — the trade recompute is gated on an explicit SAVE (a revision bump), not on
        // every intent edit, so the search isn't re-run constantly.
        do {
            let store = DayIntentStore.shared
            let before = store.intentsRevision
            store.markIntentsSaved()
            check(store.intentsRevision == before + 1, "C1: markIntentsSaved bumps the recompute revision")
            store.markIntentsSaved()
            check(store.intentsRevision == before + 2, "C1: each SAVE advances the revision")
        }

        // MARK: C1 phase-2 — dirty tracking + Discard buffer (Save-or-Discard guard).
        do {
            let store = DayIntentStore.shared
            let day = "2099-01-02"   // a far-future test day that no real schedule touches
            store.setWorkingIntent(nil, forDay: day)   // clean slate for this day
            store.markIntentsSaved()                    // baseline: day has no intent, flag clear
            check(!store.hasUnsavedChanges, "C1.2: a fresh SAVE clears the unsaved-changes flag")

            store.setWorkingIntent(.dontWantToWork, forDay: day)
            check(store.hasUnsavedChanges, "C1.2: editing an intent sets the unsaved-changes flag")
            check(store.workingIntent(forDay: day) == .dontWantToWork, "C1.2: the edit is visible before saving")

            store.discardChanges()
            check(!store.hasUnsavedChanges, "C1.2: Discard clears the unsaved-changes flag")
            check(store.workingIntent(forDay: day) == nil, "C1.2: Discard reverts the edit to the saved baseline")

            // Save then edit then discard reverts only to the SAVED value, not all the way to empty.
            store.setWorkingIntent(.mustWork, forDay: day)
            store.markIntentsSaved()
            store.setWorkingIntent(.dontWantToWork, forDay: day)
            store.discardChanges()
            check(store.workingIntent(forDay: day) == .mustWork, "C1.2: Discard reverts to the last SAVED value")
            store.setWorkingIntent(nil, forDay: day); store.markIntentsSaved()   // cleanup
        }

        // MARK: Relief dispatcher — schedule unknown past the horizon (pure).
        let reliefDate = DateComponents(calendar: .current, year: 2026, month: 8, day: 7).date!
        let beforeRelief = DateComponents(calendar: .current, year: 2026, month: 8, day: 7).date!  // inclusive
        let afterRelief  = DateComponents(calendar: .current, year: 2026, month: 8, day: 8).date!
        check(!TradeProfile.isPastRelief(day: beforeRelief, reliefThrough: reliefDate),
              "Relief: the horizon date itself is still known (inclusive)")
        check(TradeProfile.isPastRelief(day: afterRelief, reliefThrough: reliefDate),
              "Relief: the day after the horizon is unknown")
        check(!TradeProfile.isPastRelief(day: afterRelief, reliefThrough: nil),
              "Relief: a non-relief dispatcher (nil horizon) is never past relief")
        // canCover rejects covering a day past the coverer's relief horizon (schedule not real).
        var reliefProf = openProfile; reliefProf.reliefThrough = reliefDate
        check(!TradeEligibility.canCover(coverDayID: TradeMatcher.isoDay(afterRelief), coverDay: afterRelief,
                                         desk: "10", startHour: 5, coverMap: ["\(TradeMatcher.isoDay(afterRelief))": rEntry(TradeMatcher.isoDay(afterRelief), off: true)],
                                         coverQuals: ["D"], coverProfile: reliefProf, options: .physicalOnly).eligible,
              "Relief: canCover rejects a day past the coverer's relief horizon")

        // MARK: #1 — a fully rest-blocked off day has NO legal shift → auto-X (can't mark Want-to-Work).
        func shiftOn(_ day: Int, _ start: Int) -> Shift {
            let d = DateComponents(calendar: .current, year: 2026, month: 8, day: day).date!
            return Shift(id: "s\(day)", date: d, startHour: start, endHour: (start + 9) % 24,
                         role: .dispatcher, desk: "10", leaveCode: nil, isOff: false)
        }
        let offDay = DateComponents(calendar: .current, year: 2026, month: 8, day: 15).date!
        // Surrounded: MID the day before (2100→0600) + AM the day after (0500) blocks AM/PM/MID on the 15th.
        let blockedShifts = [shiftOn(14, 21), shiftOn(16, 5)]
        check(!AvailabilityManager.hasAnyLegalShift(forOffDay: offDay, workedShifts: blockedShifts),
              "#1: a fully rest-blocked off day has no legal shift")
        check(AvailabilityManager.hasAnyLegalShift(forOffDay: offDay, workedShifts: []),
              "#1: an unconstrained off day has legal shifts")

        // MARK: R-A — the match universe is the ROSTER, profiles layer on top (fixes "only 3 dispatchers").
        func mkProf(_ id: String, _ openness: String) -> TradeProfile {
            TradeProfile(workerID: id, displayName: id, openness: openness, blacklistedWeekdays: [],
                         blacklistedDesks: [], blacklistedShiftTypes: [], blacklistedRegions: [],
                         seekingDayIDs: [], updatedAt: Date())
        }
        let rosterUni: [(id: String, name: String, quals: [String])] =
            [("A", "A", ["D"]), ("B", "B", ["D"]), ("C", "C", ["D"]), ("me", "Me", ["D"])]
        let profsUni = ["A": mkProf("A", "all"), "B": mkProf("B", "none")]   // C has NO profile
        let uni = MatchUniverse.candidates(roster: rosterUni, profiles: profsUni, selfID: "me")
        check(uni.contains { $0.workerID == "C" && $0.willingness == .unknown },
              "R-A: a roster worker with NO profile is in the universe as .unknown")
        check(uni.contains { $0.workerID == "A" && $0.willingness == .willing },
              "R-A: an opted-in peer is .willing")
        check(!uni.contains { $0.workerID == "B" },
              "R-A: a declined (openness=none) peer is excluded by default")
        check(!uni.contains { $0.workerID == "me" }, "R-A: self is never a candidate")
        let uniWhatIf = MatchUniverse.candidates(roster: rosterUni, profiles: profsUni, selfID: "me", includeDeclined: true)
        check(uniWhatIf.contains { $0.workerID == "B" && $0.willingness == .declined },
              "R-A: What-If includes declined peers")

        // MARK: P0 — an empty fetch (transient CloudKit error) must NOT wipe a non-empty cache.
        check(FetchMerge.keepCacheOnEmpty(existing: [1, 2, 3], fetched: [Int]()) == [1, 2, 3],
              "P0: an empty fetch keeps the existing non-empty cache (no wipe)")
        check(FetchMerge.keepCacheOnEmpty(existing: [1], fetched: [9, 8]) == [9, 8],
              "P0: a non-empty fetch replaces the cache normally")
        check(FetchMerge.keepCacheOnEmpty(existing: [Int](), fetched: [Int]()) == [],
              "P0: empty→empty stays empty (fresh account)")

        // MARK: P0 — old records still decode after new optional fields (data-wipe guard, img 32).
        func decodes<T: Decodable>(_ type: T.Type, _ json: String) -> Bool {
            guard let data = json.data(using: .utf8) else { return false }
            return (try? JSONDecoder().decode(type, from: data)) != nil
        }
        check(decodes(BroadcastPost.self, #"{"id":"p1","authorID":"A","authorName":"A","text":"hi","createdAt":0,"expiresAt":0}"#),
              "P0: a v1 BroadcastPost (no channel/pinned/reactions/image) still decodes")
        check(decodes(BroadcastReply.self, #"{"id":"r1","postID":"p1","authorID":"A","authorName":"A","text":"hi","isPublic":true,"createdAt":0}"#),
              "P0: a v1 BroadcastReply still decodes")
        check(decodes(TradeResponse.self, #"{"id":"x1","requestID":"q1","responderID":"A","responderName":"A","status":"pending","note":"","createdAt":0}"#),
              "P0: a v1 TradeResponse still decodes")
        check(decodes(TradeRequest.self, #"{"id":"q1","fromID":"A","fromName":"A","toID":"B","toName":"B","note":"","takeDayIDs":[],"giveDayIDs":[],"createdAt":0,"expiresAt":0}"#),
              "P0: a v1 TradeRequest (no qualSwap/perfectMatch) still decodes")
        check(decodes(TradeProfile.self, #"{"workerID":"A","displayName":"A","openness":"all","blacklistedWeekdays":[],"blacklistedDesks":[],"blacklistedShiftTypes":[],"blacklistedRegions":[],"seekingDayIDs":[],"updatedAt":0}"#),
              "P0: a v1 TradeProfile (no qualValues/reliefThrough) still decodes")

        // MARK: B4-14 — compact ECB-style card gate (2-person only; 3+/circular keep PackageCard).
        do {
            func pa2(_ id: String) -> PackageAssignment {
                PackageAssignment(workerID: id, name: id, giveDayIDs: ["2026-07-01"], takeDayIDs: ["2026-07-02"])
            }
            let two = TradePackage(id: "t2", methodology: .greedy, assignments: [pa2("A")], route: nil)
            let three = TradePackage(id: "t3", methodology: .greedy, assignments: [pa2("A"), pa2("B")], route: nil)
            let r3 = NWayRoute(participants: ["me", "A", "B"], legs: [], tier: .matchingIntents, score: 0, usesBookends: false)
            let circ3 = TradePackage(id: "c3", methodology: .circular, assignments: [pa2("A"), pa2("B")], route: r3)
            let qsLeg = QualSwapLegData(giveShiftDayID: "2026-07-01", giveDesk: "82", giveQual: "L",
                                        takerID: "A", takerName: "A", candidates: [])
            let qs2 = TradePackage(id: "qs2", methodology: .greedy,
                                   assignments: [PackageAssignment(workerID: "A", name: "A", giveDayIDs: ["2026-07-01"], takeDayIDs: [])],
                                   route: nil, qualSwap: qsLeg)
            check(two.usesCompactCard, "B4-14: a two-person swap uses the compact card")
            check(qs2.usesCompactCard, "B4-14: a 2-way qual-swap uses the compact card")
            check(!three.usesCompactCard, "B4-14: a 3-person package keeps PackageCard")
            check(!circ3.usesCompactCard, "B4-14: a circular (3) package keeps PackageCard")
        }

        // MARK: B4-2 — intent snapshot round-trips (marks + notes + topology survive cross-device sync).
        do {
            let snap = DayIntentStore.IntentSnapshot(
                working: ["2026-07-01": .dontWantToWork, "2026-07-02": .mustWork],
                off: ["2026-07-03": .wantToWork, "2026-07-04": .mustBeOff],
                topologies: ["2026-07-05": .personalMilestone],
                notes: ["2026-07-01": DayNote(dayID: "2026-07-01", message: "swap wk", reason: .personalEvent)],
                availability: ["2026-07-03": [.am, .pm]],
                manualOff: ["2026-07-04"])
            let enc = try? JSONEncoder().encode(snap)
            check(enc != nil, "B4-2: intent snapshot encodes")
            let back = enc.flatMap { try? JSONDecoder().decode(DayIntentStore.IntentSnapshot.self, from: $0) }
            check(back == snap, "B4-2: intent snapshot round-trips (marks + notes + topology intact)")
        }

        // MARK: B4-4 — "Blackout weekends" only ever touches Sat(7)+Sun(1).
        do {
            check(WeekendBlackout.apply(on: true, to: [3]) == [1, 3, 7], "B4-4: on adds Sat+Sun, keeps existing")
            check(WeekendBlackout.apply(on: false, to: [1, 3, 7]) == [3], "B4-4: off removes only Sat+Sun, keeps others")
            check(WeekendBlackout.isOn([1, 7, 4]) && !WeekendBlackout.isOn([1, 4]), "B4-4: isOn requires BOTH weekend days")
        }

        // MARK: B4-5 — hard-blacklist profileless peers to their recent behavior (region + type + weekend).
        do {
            let asOf = TradeMatcher.dayDate(fromISO: "2026-03-02")!   // a Monday
            func e(_ day: String, off: Bool = false, hour: Int = 5, desk: String = "10") -> RosterEntry {
                RosterEntry(workerID: "W", workerName: "W", quals: ["D"], day: day, startHour: hour, desk: desk, isOff: off)
            }
            let amType = ShiftAvailabilityType.infer(fromStartHour: 5).rawValue
            let reg10 = DeskRules.region(forDesk: "10").rawValue
            // 6 weekday AM/desk-10 shifts, no weekends → weekend blacklist expected.
            let weekdays = ["2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20", "2026-02-23"].map { e($0) }
            let inf = InferredPrefs.from(entries: weekdays + [e("2026-02-10", off: true), e("2025-01-01")], asOf: asOf)
            check(inf?.shiftTypes == [amType], "B4-5: infers only worked shift types (AM); off/old excluded")
            check(inf?.regions == [reg10], "B4-5: infers only worked regions")
            check(inf?.worksWeekend == false, "B4-5: no Sat/Sun in window → worksWeekend false")
            check(InferredPrefs.from(entries: [e("2026-02-20")], asOf: asOf) == nil, "B4-5: < 6 shifts → nil (no over-restriction)")
            // A worker WITH a weekend shift (Sat 2026-02-21).
            let withWknd = InferredPrefs.from(entries: weekdays + [e("2026-02-21")], asOf: asOf)
            check(withWknd?.worksWeekend == true, "B4-5: a Sat shift → worksWeekend true")
            // Default profile: complement blacklisted + weekends blacklisted when they don't work them.
            let prof = TradeProfile.defaultForUnpublished(workerID: "W", name: "W",
                        inferredShiftTypes: [amType], inferredRegions: [reg10], blacklistWeekends: true)
            check(!prof.blacklistedShiftTypes.contains(amType)
                  && prof.blacklistedShiftTypes.count == ShiftAvailabilityType.allCases.count - 1,
                  "B4-5: inferred default blacklists every shift type EXCEPT worked")
            check(prof.blacklistedWeekdays == [1, 7], "B4-5: blacklistWeekends → Sun+Sat blacklisted")
            let plain = TradeProfile.defaultForUnpublished(workerID: "W", name: "W")
            check(plain.blacklistedShiftTypes.isEmpty && plain.blacklistedRegions.isEmpty && plain.blacklistedWeekdays.isEmpty,
                  "B4-5: plain A8 default unchanged")
        }

        // MARK: B4-3 — Blackout blacklist predicate (paints blacklisted shifts on the calendar).
        do {
            let amType = ShiftAvailabilityType.infer(fromStartHour: 5).rawValue
            let region82 = DeskRules.region(forDesk: "82").rawValue
            check(Blackout.isBlacklisted(desk: "82", startHour: 5, weekday: 3, desks: ["82"], shiftTypes: [], regions: [], weekdays: []),
                  "B4-3: a blacklisted desk is blacked out")
            check(Blackout.isBlacklisted(desk: "10", startHour: 5, weekday: 7, desks: [], shiftTypes: [], regions: [], weekdays: [7]),
                  "B4-3: a blacklisted weekday is blacked out")
            check(Blackout.isBlacklisted(desk: "10", startHour: 5, weekday: 3, desks: [], shiftTypes: [amType], regions: [], weekdays: []),
                  "B4-3: a blacklisted shift type is blacked out")
            check(Blackout.isBlacklisted(desk: "82", startHour: 5, weekday: 3, desks: [], shiftTypes: [], regions: [region82], weekdays: []),
                  "B4-3: a blacklisted region is blacked out")
            check(!Blackout.isBlacklisted(desk: "10", startHour: 5, weekday: 3, desks: ["82"], shiftTypes: ["ZZ"], regions: ["ZZ"], weekdays: []),
                  "B4-3: a shift matching NO blacklist dimension is not blacked out")
        }

        // MARK: B6-LABEL — working protect = "Keep" (green), off protect = "Blackout" (slate). (Supersedes
        // B4-1's shared "Blackout" label: the working keep is now visually + verbally distinct from blocked.)
        check(WorkingIntentState.mustWork.label == "Keep", "B6-LABEL: working-protect day label reads 'Keep'")
        check(OffIntentState.mustBeOff.label == "Blackout", "B6-LABEL: off-protect (must-be-off) day label reads 'Blackout'")
        // Cases/keys are unchanged (no data migration) — raw values must stay stable.
        check(WorkingIntentState.mustWork.rawValue == "mustWork", "B4-1: mustWork raw value unchanged (no migration)")
        check(OffIntentState.mustBeOff.rawValue == "mustBeOff", "B4-1: mustBeOff raw value unchanged (no migration)")

        // MARK: Z2 — changelog show-once.
        check(ChangeLog.shouldShow(currentBuild: "12", lastSeen: "11"), "Z2: a newer build shows the changelog")
        check(!ChangeLog.shouldShow(currentBuild: "12", lastSeen: "12"), "Z2: same build → no re-show")
        check(ChangeLog.shouldShow(currentBuild: "1", lastSeen: ""), "Z2: first launch shows it")
        check(!ChangeLog.shouldShow(currentBuild: "", lastSeen: ""), "Z2: empty build → never show (no crash)")

        // MARK: #9 — "successful" = accepted AND archived; totals (You vs Company) per period.
        check(Metrics.isSuccessful(accepted: true, archived: true), "#9: accepted+archived = successful")
        check(!Metrics.isSuccessful(accepted: true, archived: false), "#9: accepted but not archived ≠ successful")
        check(!Metrics.isSuccessful(accepted: false, archived: true), "#9: archived but not accepted ≠ successful")
        let mNow = Date(timeIntervalSince1970: 1_700_000_000)
        let mEvents = [
            MetricEvent(id: "t1", workerID: "me", kind: .trade, createdAt: mNow),
            MetricEvent(id: "t2", workerID: "B",  kind: .trade, createdAt: mNow),
            MetricEvent(id: "t3", workerID: "C",  kind: .trade, createdAt: Date(timeIntervalSince1970: 1_600_000_000)),
        ]
        check(Metrics.count(mEvents, kind: .trade, period: .allTime, now: mNow) == 3, "#9: company all-time total")
        check(Metrics.count(mEvents, kind: .trade, period: .month, now: mNow) == 2, "#9: month total scopes by period")
        check(Metrics.count(mEvents, kind: .trade, period: .allTime, now: mNow, workerID: "me") == 1, "#9: YOUR total filters to you")

        // MARK: G1 — Outlook/email trade announcement (pure body + mailto).
        let emBody = TradeEmail.body(giver: "Me", taker: "Cary", giveDays: ["Jul 4"],
                                     takeDays: ["Jul 6"], blackoutDays: ["Jul 10", "Jul 11"])
        check(emBody.contains("Me ⇄ Cary") && emBody.contains("Me gives Jul 4")
              && emBody.contains("Cary gives Jul 6")
              && emBody.contains("Blackout days (unavailable): Jul 10, Jul 11"),
              "G1: email body has the trade + Must-Be-Off blackout days")
        check(!TradeEmail.body(giver: "A", taker: "B", giveDays: [], takeDays: [], blackoutDays: []).contains("Blackout"),
              "G1: no blackout line when there are none")
        check(TradeEmail.mailtoURL(dl: "DL_dispatch_trades@aa.com", subject: "s", body: emBody) != nil,
              "G1: a mailto URL builds when the DL is set")
        check(TradeEmail.mailtoURL(dl: "", subject: "s", body: "b") == nil,
              "G1: no DL → no URL")
        // #7: Trade Solutions DL email has blackout days; ECB email states the ECB count, NO blackout.
        check(TradeEmail.dispatchBody(giver: "Me", giveDays: ["Jul 4"], blackoutDays: ["Jul 10"]).contains("Blackout days"),
              "#7: dispatch trade email includes blackout days")
        let ecbB = TradeEmail.ecbBody(giver: "Me", giveDays: ["Jul 4"], ecb: 9)
        check(ecbB.contains("9 ECB") && !ecbB.contains("Blackout"),
              "#7: ECB email states the ECB count and has NO blackout days")
        check(TradeEmail.outlookURL(dl: "DL_dispatch_trades@aa.com", subject: "s", body: "b") != nil,
              "#7: Outlook compose URL builds")

        // MARK: Global trade timing — only 0500/1300/2100 are tradeable.
        check(TradeTiming.isTradeable(startHour: 5) && TradeTiming.isTradeable(startHour: 13) && TradeTiming.isTradeable(startHour: 21),
              "TIMING: 0500/1300/2100 are tradeable")
        check(!TradeTiming.isTradeable(startHour: 22) && !TradeTiming.isTradeable(startHour: 6) && !TradeTiming.isTradeable(startHour: 0),
              "TIMING: other start hours are not tradeable")

        // MARK: #5 — bookend display: an ISOLATED give-day (no adjacent existing work for
        // the receiver) is NOT a bookend; TwoWaySheet.legCard must only show the "bookend"
        // tag when leg.bookend is true (was printed unconditionally).
        do {
            let cal = Calendar.current
            func entry(_ iso: String, off: Bool) -> RosterEntry {
                RosterEntry(workerID: "P", workerName: "P", quals: [], day: iso,
                            startHour: off ? 0 : 13, desk: "29", isOff: off)
            }
            func d(_ iso: String) -> Date { TradeMatcher.dayDate(fromISO: iso) ?? Date.distantPast }
            // Receiver works Jul 4 & Jul 6; off otherwise. Giving them Jul 5 anchors (between two
            // work days) → bookend. Giving them Jul 18 (isolated) → NOT a bookend.
            let map: [String: RosterEntry] = [
                "2026-07-04": entry("2026-07-04", off: false),
                "2026-07-06": entry("2026-07-06", off: false),
            ]
            check(TradeMatcher.anchored(day: d("2026-07-05"), map: map, plan: ["2026-07-05"], cal: cal),
                  "#5: a day adjacent to existing work IS a bookend")
            check(!TradeMatcher.anchored(day: d("2026-07-18"), map: map, plan: ["2026-07-18"], cal: cal),
                  "#5: an isolated give-day is NOT a bookend (Jun-18 mislabel bug)")
        }

        // MARK: R-B — cross-device profile round-trip. The CloudKit publish/fetch path
        // JSON-encodes the whole TradeProfile into one `payload`; status + intents MUST
        // survive encode→decode (else peers see blank status / no uploaded intents).
        do {
            var p = TradeProfile(workerID: "001", displayName: "Me", openness: "all",
                                 blacklistedWeekdays: [2], blacklistedDesks: ["29"],
                                 blacklistedShiftTypes: ["AM"], blacklistedRegions: ["Domestic"],
                                 seekingDayIDs: ["2026-07-04", "2026-07-05"], updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 statusBroadcast: "Open to bookends this month")
            p.wantToWorkDayIDs = ["2026-07-10"]
            p.mustBeOffDayIDs = ["2026-07-20"]
            p.keepDayIDs = ["2026-07-22"]
            guard let data = try? JSONEncoder().encode(p),
                  let back = try? JSONDecoder().decode(TradeProfile.self, from: data) else {
                check(false, "R-B: profile failed to encode/decode through the payload codec"); return fails
            }
            check(back.statusBroadcast == "Open to bookends this month", "R-B: statusBroadcast survives round-trip")
            check(back.seekingDayIDs == ["2026-07-04", "2026-07-05"], "R-B: seekingDayIDs (give-away intents) survive")
            check(back.wantToWorkDayIDs == ["2026-07-10"], "R-B: wantToWorkDayIDs survive")
            check(back.mustBeOffDayIDs == ["2026-07-20"], "R-B: mustBeOffDayIDs survive")
            check(back.keepDayIDs == ["2026-07-22"], "R-B: keepDayIDs survive")
        }

        return fails
    }

    /// B6-SYNC — verifies the ATOMIC roster import (generation tag + pointer swap). Kept SEPARATE from the
    /// pure synchronous `runAll()` because it's async and touches SwiftData (an in-memory `RosterShift`
    /// store + `RosterModelActor`). Discharges the ASSUMED_PRESENT B6-SYNC "no cross-generation duplicates"
    /// item that the RunCodeSnippet harness couldn't (it can't build the `@ModelActor` init out-of-module).
    ///
    /// Run from Developer Tools, or:  `print(await TradeEngineTests.rosterAtomicityFailures())`
    static func rosterAtomicityFailures() async -> [String] {
        var fails: [String] = []
        func check(_ cond: Bool, _ msg: String) { if !cond { fails.append("❌ " + msg) } }

        let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: RosterShift.self, configurations: cfg) else {
            return ["❌ ROSTER-ATOMIC: could not build an in-memory RosterShift container"]
        }
        let act = RosterModelActor(modelContainer: container)

        func worker(_ id: String, _ desk: String) -> ParsedWorker {
            let d = Date(timeIntervalSince1970: 1_700_000_000)
            let s = Shift(id: "\(id)-2026-07-10", date: d, startHour: 13, endHour: 22,
                          role: .dispatcher, desk: desk, leaveCode: nil, isOff: false)
            return ParsedWorker(id: id, name: "W\(id)", quals: ["D"], shifts: [s])
        }
        let genA = Date(timeIntervalSince1970: 1000)
        let genB = Date(timeIntervalSince1970: 2000)

        do {
            // Generation A becomes the live roster.
            try await act.insertGeneration([worker("1", "29"), worker("2", "30")], version: genA)
            let aRows = try await act.totalRows(generation: genA)
            check(aRows == 2, "ROSTER-ATOMIC: gen A has 2 rows (got \(aRows))")

            // MID-IMPORT: generation B rows land while readers are still pinned to gen A. The reader must
            // see the COMPLETE old generation, never a mix — this is the core atomicity guarantee.
            try await act.insertGeneration([worker("1", "99"), worker("2", "98")], version: genB)
            let aStill = try await act.totalRows(generation: genA)
            check(aStill == 2, "ROSTER-ATOMIC: gen A untouched while gen B mid-insert (got \(aStill))")
            let deskA = (try await act.schedule(forWorker: "1", generation: genA)).first?.desk
            check(deskA == "29", "ROSTER-ATOMIC: pre-swap reader sees OLD desk 29 (got \(deskA ?? "nil"))")

            // Swap complete → clean up the old generation.
            try await act.deleteOtherGenerations(keeping: genB)
            let bRows = try await act.totalRows(generation: genB)
            check(bRows == 2, "ROSTER-ATOMIC: gen B has 2 rows — NO cross-gen dupes (got \(bRows))")
            let aAfter = try await act.totalRows(generation: genA)
            check(aAfter == 0, "ROSTER-ATOMIC: gen A swept after cleanup (got \(aAfter))")
            let deskB = (try await act.schedule(forWorker: "1", generation: genB)).first?.desk
            check(deskB == "99", "ROSTER-ATOMIC: post-swap reader sees NEW desk 99 (got \(deskB ?? "nil"))")

            // Sentinel/migration invariant: rows written with the epoch default are visible to the epoch
            // reader (the seamless-upgrade path — pre-field rows stay visible with no wipe).
            let epoch = Date(timeIntervalSince1970: 0)
            try await act.insertGeneration([worker("9", "12")], version: epoch)
            let epochRows = try await act.totalRows(generation: epoch)
            check(epochRows == 1, "ROSTER-ATOMIC: epoch-default rows visible to the epoch reader (got \(epochRows))")
        } catch {
            fails.append("❌ ROSTER-ATOMIC: threw \(error)")
        }
        return fails
    }

    private static func balanced(_ a: [OptimalMatcher.Assignment]?) -> Bool {
        guard let a else { return false }
        return a.allSatisfy { $0.giveDayIDs.count == $0.takeDayIDs.count }
    }
}

#endif

```
