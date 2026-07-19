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
// U-OBJ: ONE objective, used consistently by construction (flow edge costs, DFS
// ordering/pruning), curation (floor), and ranking (rankLess). Three factors:
//
//   Q  = meanLegQuality  — geometric mean of per-leg σ(logit). Size- and people-
//        neutral, in (0,1]. THE floor signal (0.32/0.07 keep their single-leg
//        meaning) and the displayed "match strength" basis.
//   π  = peoplePenalty   — INTENT-AWARE: nPenalty^((N−2)·nonMutualFraction) ·
//        peopleEdge^(N−2). All-mutual ⇒ only the tiny peopleEdge applies, so a
//        unanimous 4-way ranks ~as high as a 2-way (and the 2-way still edges it);
//        every non-mutual leg raises the fraction, so growth-by-coercion falls
//        below a clean smaller trade. (Owner requirement; replaces flat 0.85^(N−2).)
//   κ  = coverage        — (urgency-weighted covered fraction)^coverageWeight.
//        Trade Solutions only; the Intents marketplace has no selected-days target
//        and passes 1.
//
//   rankScore = Q · π · κ    (packageScore below)

enum TradeScore {
    // Weights = the DESIGNED match priorities. WANTS dominate (want-to-take + want-to-trade, 1.5
    // each → dual = 3.0). Bookend is a flat +0.8. The SPLIT penalty SHRINKS as intent grows
    // (`splitBase − splitRelief·intentLevel` → none 2.5, single 1.4, dual 0.3) so a split barely dents
    // a dual trade but wrecks a no-intent one. `qual` friction −1.2; `personPrior` tiny (0.2).
    static let wWant = 1.5, wBook = 0.8, wTime = 0.8, wQual = 1.2, wEcb = 1.5, wPerson = 0.2
    static let splitBase = 2.5, splitRelief = 1.1

    /// Per-extra-person multiplier, applied only to the NON-MUTUAL fraction of the package
    /// (U-N2). An all-mutual trade of any size pays none of this.
    static let nPenalty = 0.85
    /// Tiny unconditional per-extra-person edge, so between two otherwise-equal all-mutual
    /// trades the SMALLER one still sorts first (2-way edges a unanimous 4-way by ~1%).
    static let peopleEdge = 0.995
    /// Coverage exponent (Trade Solutions): rankScore ×= coverageFrac^coverageWeight. At 2.0,
    /// an excellent half-cover (Q≈0.99 → 0.25) sorts under even a fair full cover (Q≈0.77) —
    /// coverage stays a top concern without being an absolute tier.
    static let coverageWeight = 2.0

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
    /// Probability-shaped acceptance signal for one leg, in (0,1). Presented to users only as
    /// RELATIVE match strength (weights are hand-tuned, not fit) — see `matchStrength`.
    static func legProb(_ f: LegFeatures) -> Double { 1.0 / (1.0 + exp(-legLogit(f))) }

    /// The UNIVERSAL display band for one option day, derived from the SAME `LegFeatures` the score
    /// uses. Coarser than `legProb` (which orders WITHIN a band); this is what draws the `|` tier
    /// dividers and enforces "intents highest" consistently across every option list:
    ///   0  both sides marked an intent (mutual)      · 1  one side marked an intent
    ///   2  no intent but it's a clean bookend          · 3  no intent, splits a break (unpreferred)
    static func displayTier(_ f: LegFeatures) -> Int {
        switch f.intentLevel {
        case 2:  return 0
        case 1:  return 1
        default: return f.bookend ? 2 : 3
        }
    }

    /// Q — geometric mean of per-leg quality, in (0,1]. Size/people-neutral by design: this is
    /// the FLOOR + DISPLAY signal, so a clean full-cover reads like a clean single-day and the
    /// floor constants keep their single-leg calibration. Empty → 0.
    static func meanLegQuality(_ legs: [LegFeatures]) -> Double {
        guard !legs.isEmpty else { return 0 }
        return exp(legs.map { log(legProb($0)) }.reduce(0.0, +) / Double(legs.count))
    }

    /// Mutual legs = both sides marked the day (giver trade-away AND receiver want-to-work).
    static func mutualLegCount(_ legs: [LegFeatures]) -> Int {
        legs.filter { $0.intentLevel == 2 }.count
    }

    /// π — the intent-aware people penalty. `people` counts every participant including you and
    /// EXCLUDES a qual-swap bridge (an enabling leg, invariant). Monotone: non-increasing in
    /// `people`, non-increasing as mutual legs are lost.
    static func peoplePenalty(people: Int, mutualLegs: Int, legCount: Int) -> Double {
        guard legCount > 0 else { return 1 }
        let extra = Double(max(0, people - 2))
        guard extra > 0 else { return 1 }
        let f = Double(legCount - min(max(0, mutualLegs), legCount)) / Double(legCount)
        return exp(extra * (f * log(nPenalty) + log(peopleEdge)))
    }

    /// THE ranking objective (both feeds): rankScore = Q · π · κ. `coverageFrac` is the
    /// urgency-weighted share of the user's SELECTED give-days this package covers — pass 1
    /// for the Intents marketplace (no selected-days target there).
    static func packageScore(_ legs: [LegFeatures], people: Int, coverageFrac: Double = 1) -> Double {
        guard !legs.isEmpty else { return 0 }
        let q = meanLegQuality(legs)
        let pi = peoplePenalty(people: people, mutualLegs: mutualLegCount(legs), legCount: legs.count)
        let kappa = pow(min(1, max(0, coverageFrac)), coverageWeight)
        return q * pi * kappa
    }

    /// Joint probability the whole package executes (all parties accept) = ∏ legProb, with the
    /// intent-aware people penalty folded in (legs ≈ participants for a loop).
    static func packageProb(_ legs: [LegFeatures]) -> Double { exp(packageLogProb(legs)) }
    /// log of the joint probability + intent-aware penalty. NOTE (U-N2): an all-mutual loop now
    /// pays only the tiny peopleEdge — a unanimous 3-way SORTS ABOVE a 2-person split, which is
    /// the owner's intended flip of the old flat-penalty property.
    static func packageLogProb(_ legs: [LegFeatures]) -> Double {
        let joint = legs.map { log(legProb($0)) }.reduce(0.0, +)
        let pi = peoplePenalty(people: legs.count, mutualLegs: mutualLegCount(legs), legCount: legs.count)
        return joint + log(pi)
    }

    /// COMPAT (existing tests + any UI reading `acceptanceScore` semantics): per-leg quality ×
    /// the intent-aware people penalty. Under U-N2 an ALL-MUTUAL package is ~people-invariant
    /// (only peopleEdge, −0.5%/person); a package with non-mutual legs still drops with people.
    static func packageQuality(_ legs: [LegFeatures], people: Int) -> Double {
        meanLegQuality(legs) * peoplePenalty(people: people,
                                             mutualLegs: mutualLegCount(legs), legCount: legs.count)
    }

    /// ADMISSIBLE DFS pruning bound: the highest FINAL mean-log-quality any completion of a
    /// partial route can reach. Each remaining leg contributes log p ≤ 0 and the final leg count
    /// is at most `maxLegs`, so partialSum/maxLegs (partialSum ≤ 0) over-estimates every
    /// completion. The floor gates Q (pre-penalty) — the penalty is deliberately ABSENT here:
    /// with the intent-aware π, adding mutual legs can SHRINK the penalty, so folding π into the
    /// bound would not be admissible. Prune when this < log(floor) — never drops a valid route.
    static func upperBoundMeanLog(partialLegLogSum: Double, maxLegs: Int) -> Double {
        guard maxLegs > 0 else { return 0 }
        return min(0, partialLegLogSum) / Double(maxLegs)
    }

    /// G3: desirability (log-joint-acceptance) of a circular route from its per-leg bookend/🔥
    /// flags. A non-bookend leg is a SPLIT, and a 🔥 leg is treated as DUAL intent (both want it).
    /// Empty route → 0 (log 1).
    static func routeDesirability(legBookends: [Bool], legFires: [Bool]) -> Double {
        let feats = zip(legBookends, legFires).map { b, f in
            LegFeatures(wantToTake: f, wantToTrade: f, bookend: b, timeValue: 0.5, needsQualBridge: false)
        }
        return packageLogProb(feats)
    }

    // MARK: - Displayed number (calibration decision: RELATIVE strength, not a probability)

    /// The surfaced number: a 0–100 RELATIVE match strength from the per-leg quality Q.
    /// Deliberately NOT labeled a probability — weights are hand-tuned and per-partner history
    /// is thin. When enough accept/decline rows exist, a logistic re-fit can upgrade this in
    /// place without touching the ranking machinery.
    static func matchStrength(_ meanLegQuality: Double) -> Int {
        Int((min(1, max(0, meanLegQuality)) * 100).rounded())
    }
    /// Card tier label. Thresholds align with the floor: below `floorNormalProb` only surfaces
    /// via Lucky / the empty-feed fallback → "Long shot".
    static func strengthTier(_ meanLegQuality: Double) -> String {
        if meanLegQuality >= 0.80 { return "Excellent" }
        if meanLegQuality >= 0.55 { return "Good" }
        if meanLegQuality >= 0.32 { return "Fair" }
        return "Long shot"
    }
}

/// A2: the "I'm Feeling Lucky" Master Filter — shapes the on-demand search. Pure value type so
/// the UI state and the result-filtering agree (single source of truth) and are harness-tested.
struct SearchFilter: Equatable, Sendable {
    enum Engine: String, CaseIterable, Sendable { case minCost, nWay, both }
    var engine: Engine = .both
    var maxPeople: Int = 4          // 1…4 distinct participants (incl. you)
    var requiredWorkerID: String?   // when set, only solutions that INCLUDE this person
    var dateStart: Date?            // range mode: only solutions where EVERY moved day is on/after this date
    var dateEnd: Date?              // …and on/before this date
    var dates: Set<String>? = nil   // "specific days" mode: ISO days you'll accept back (NOT collapsed to a
                                    // range) — a package qualifies if it can return one of these days
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
        if dateStart != nil || dateEnd != nil || !(dates?.isEmpty ?? true) { parts.append("dates") }
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
            // The date filter constrains the days you'd RECEIVE (your take-backs), not the days you give.
            let received: [String] = p.route.map { r in r.legs.filter { $0.toID == selfID }.map(\.dayID) }
                ?? p.assignments.flatMap(\.takeDayIDs)
            if let dates, !dates.isEmpty {
                // Specific days: keep a package that can return one of the chosen days (default take OR an
                // alternate take-option). NOT a min→max envelope — Jul 29 + Aug 28 means exactly those.
                let candidates = Set(received).union(p.assignments.flatMap(\.takeOptions))
                if candidates.isDisjoint(with: dates) { return false }
            } else if lo != nil || hi != nil {
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


/// All the static copy behind the Welcome flow: the purpose pitch, the engineer-level
/// mechanisms tour, and the version history. Pure data so it's testable + lives in a compiled file.
enum AppGuide {
    static let appName  = "DX Trader"
    static let tagline  = "Schedule reading + shift trading for dispatchers — matched, scored, and synced."

    /// The "why this exists" pitch, shown on the welcome page (operator-facing — no jargon).
    static let purpose: [String] = [
        "DX Trader reads the dispatch master schedule for you — your shifts, days off, vacation, and qualifications — with no file to import and nothing to maintain by hand.",
        "Then it does the hard part. You mark the days you want to give away, and it searches the entire roster for trades that would actually work — checking each one against the real rules (desk qualification, the 8-hour rest gap) and each person's own preferences before it ever shows up. It looks at straight two-person swaps, larger multi-person packages, and full circular trades where everyone covers someone else — then puts the ones most likely to get a yes at the top.",
        "It's built to be consistent and trustworthy: the same rules and the same ranking sit behind every search. And everything — your trades, the channel, statuses, and team stats — syncs across the shop through iCloud, so everyone is working from the same board.",
    ]

    /// The concrete first things to do after joining — the welcome page LEADS with these (a checklist)
    /// instead of a long pitch. Operator-facing, ordered as a first-day walkthrough.
    struct FirstStep: Identifiable, Sendable { let id = UUID(); let symbol: String; let title: String; let detail: String }
    static let firstSteps: [FirstStep] = [
        FirstStep(symbol: "icloud.fill", title: "Turn on iCloud & shared calendar",
                  detail: "In Trade Settings, keep iCloud Trade Sync on and connect the shared calendar — that's how you see everyone, the channel, and your schedule from the master."),
        FirstStep(symbol: "arrow.left.arrow.right", title: "Set your trade settings",
                  detail: "Set your openness (Bookends-Only or Open to all), any blacklists, and a status — so matches fit how you actually trade."),
        FirstStep(symbol: "pencil.and.list.clipboard", title: "Mark your intents",
                  detail: "On Home, tap Mark Intents and paint the working days you want to trade away and the off days you'd pick up."),
        FirstStep(symbol: "megaphone.fill", title: "Say hi in the channel",
                  detail: "Open the Channel and introduce yourself — @mention someone or @everyone. It's how the shop coordinates."),
        FirstStep(symbol: "magnifyingglass", title: "Search for a trade",
                  detail: "On Trades, use Intents or Trade Solutions to find real, legal swaps for your days — best matches on top."),
        FirstStep(symbol: "paperplane.fill", title: "Send a trade request",
                  detail: "Found a good one? Tap Propose to send it, and track replies in your Inbox."),
        FirstStep(symbol: "hammer.fill", title: "Try to break it",
                  detail: "Poke at edge cases and unusual trades — this is a beta, and real use is what finds the sharp edges."),
        FirstStep(symbol: "exclamationmark.bubble.fill", title: "Report bugs in #feedback",
                  detail: "Anything weird or broken? Post it in the #feedback channel so it gets fixed fast."),
    ]

    /// Feature pillars (quick "what it does" grid on the welcome page).
    static let pillars: [(symbol: String, title: String, blurb: String)] = [
        ("calendar", "Auto schedule", "Your roster, vacation, and quals — read from the master, kept current automatically."),
        ("arrow.left.arrow.right", "Real trades", "Two-person, multi-person, and circular swaps that pass every hard rule."),
        ("gauge.with.dots.needle.67percent", "Acceptance scoring", "Every trade graded by how likely both sides accept — best on top."),
        ("person.2.badge.gearshape", "Qual swaps", "A qualified bridge desk-swaps so an unqualified taker can still cover."),
        ("star.circle", "ECB one-way", "Give a shift away for ECB with a fair, queue-ordered claim."),
        ("bubble.left.and.bubble.right", "Channel + chat", "Broadcast what you're trading, thread replies, 1:1 chat with photos."),
    ]

    /// Welcome-page methodology — operator-facing (detailed, but no math jargon). Renders as a
    /// "How it works" walkthrough right on the welcome popup.
    static let methodology: [WelcomeTopic] = [
        WelcomeTopic(
            title: "Intents — telling the app what you want",
            symbol: "hand.raised.fill",
            body: "On Home you mark days with four intents: Trade away (a working day you'd give up), Want to work (a day off you'd pick up), Keep (a working day you won't trade), and Must be off (a day off you won't take). These marks are the heart of matching — the app pairs your Trade-away days with other people's Want-to-work days, and your Want-to-work days with their Trade-away days. Keep and Must-be-off are hard limits it will never cross."),
        WelcomeTopic(
            title: "How matches are found",
            symbol: "arrow.triangle.swap",
            body: "Open Intents (or pick days in Trade Solutions) and the app scans the entire roster, building every legal trade it can — two-person swaps first, then multi-person packages, then circular loops where everyone covers someone else and nobody loses hours. Every leg is checked against the hard rules (desk qualification, the 8-hour rest gap) and both people's preferences before it's ever shown."),
        WelcomeTopic(
            title: "Prioritization — the best matches rise to the top",
            symbol: "list.number",
            body: "Matches are ranked, not piled. A deal where BOTH of you marked the day — a mutual 🔥 match — sits at the very top. After that the app prefers trades that keep everyone's days off together (bookends) over ones that split a weekend, fewer people over more, and sooner dates over later. The trades most likely to get a yes are the ones you see first."),
        WelcomeTopic(
            title: "The score behind the sort",
            symbol: "gauge.with.dots.needle.67percent",
            body: "Every possible trade gets an acceptance score — one number estimating how likely everyone says yes. It rewards mutual intent and clean bookends, lightly favors sooner and same-desk trades, and pushes down weekend splits and trades that need an extra person. Anything too unlikely is filtered out, so the feed stays honest instead of padded with deals nobody would take."),
        WelcomeTopic(
            title: "Blacklisting & preferences",
            symbol: "nosign",
            body: "You're never offered something you ruled out. In Trade Settings you set your openness (bookends-only or open to all) and blacklist shift types, regions, desks, weekdays, or specific qual-swap desks. A Must-be-off day is never offered to you; a Keep day is never given away. Anyone who hasn't set up a profile is treated conservatively — bookends-only — so you won't get split-the-weekend offers from people who haven't opted in."),
        WelcomeTopic(
            title: "Proposing — straight to their inbox",
            symbol: "paperplane.fill",
            body: "Found a trade you like? Tap Propose and it goes directly to the other person's in-app inbox. They Accept, Counter, or Decline, and you can chat (with photos) right on the trade. You get a push the moment a request arrives — and a stronger 'perfect match' alert when a trade lands exactly on a day you were after."),
        WelcomeTopic(
            title: "ECB — automatic first-come, first-served",
            symbol: "star.circle.fill",
            body: "When you just want a shift covered with no swap back, post it for ECB (in 0.5 steps, 5–25). Everyone who can legally work it claims it, and the app automatically orders claimants into a fair queue — first come, first served — and shows each person their place in line. You confirm once the credit lands; the official ECB form is filed outside the app."),
        WelcomeTopic(
            title: "Built into your iPhone",
            symbol: "apple.logo",
            body: "Your schedule flows to Apple Calendar, Home-Screen widgets show your next shift and trade requests, and you can ask Siri or run Shortcuts ('turn on shift alerts', 'tomorrow's alarm time'). Everything syncs across your devices and the whole shop through iCloud — set your Employee ID once and it follows you."),
    ]

    /// The scoring table shown on the welcome page — what raises or lowers a match's rank, in plain terms.
    static let scoringSignals: [(signal: String, meaning: String, effect: String)] = [
        ("🔥 Mutual intent", "Both of you marked the day", "Top priority"),
        ("One-sided intent", "Only one side marked it", "Strong"),
        ("Bookend", "Pickup sits on the edge of days off", "Boosts"),
        ("Split", "Pickup breaks up a weekend", "Penalized*"),
        ("Sooner date", "The trade is coming up", "Small boost"),
        ("Qual bridge needed", "A 3rd person must desk-swap", "Small penalty"),
        ("Fewer people", "2-person vs 3–4 person", "Preferred"),
        ("Past acceptance", "Partner usually says yes", "Tiebreak only"),
    ]

    /// The trade types the engine can build, for the welcome-page table.
    static let matchTypes: [(type: String, detail: String)] = [
        ("Two-person swap", "You ↔ one person, day-for-day"),
        ("Multi-person package", "Several people each cover part"),
        ("Circular trade", "A→B→C→A — everyone nets even hours"),
        ("Qual swap", "A qualified bridge frees a desk for the taker"),
        ("ECB one-way", "Give a shift for ECB, claimed first-come"),
    ]

    /// The engineer-level "under the hood" tour.
    static let mechanisms: [MechanismSection] = [
        MechanismSection(
            title: "Schedule ingestion & data model",
            symbol: "doc.text.magnifyingglass",
            summary: "The master CSV becomes a queryable, per-device SwiftData roster.",
            details: [
                "A day-row-spine parser (ScheduleParser) reads the grid-format dispatch master: it locates the day spine, then walks each worker column, reconstructing per-day shifts (start hour, desk, qualifications) and bounding every worker to a rolling 15-month window. A known quirk — a dropped column separator on certain rows — is handled explicitly. Vacation (L|V) rows resolve to true days off, never phantom shifts, and auto-stamp a Must-Be-Off intent + 'vacation' note (which you can override).",
                "The parsed roster persists locally in SwiftData via a background @ModelActor (RosterStore), configured cloudKitDatabase=.none so it is never mirrored — the store is per-device and queried by date/worker predicates. Only the master CSV itself is shared, as one record on the CloudKit public database, version-stamped so a device re-imports only when the master actually changes. A corrupt store self-heals: it wipes the on-disk store + WAL/SHM sidecars and rebuilds rather than bricking launch.",
                "Your personal schedule, shift reminders, widgets, and Siri intents are all derived from your row in the master — set your Employee ID once and everything follows; nothing is maintained by hand.",
            ]),
        MechanismSection(
            title: "Intents, profiles & the candidate universe",
            symbol: "person.text.rectangle",
            summary: "What you mark, what you publish, and who is eligible to match.",
            details: [
                "Per-day intent lives in DayIntentStore as four disjoint sets: seekingDayIDs (trade-away), keepDayIDs (never give), mustBeOffDayIDs (never take), and wantToWorkDayIDs (off-day you'd pick up). These drive both the legality gates (Keep/Must-Be-Off are hard) and the scoring (intent raises a leg's accept probability).",
                "Your TradeProfile publishes openness (Bookends-Only / All / None), per-shift-type and per-region/desk blacklists, qual-swap preferences, and relief horizon. It rides a single JSON payload to CloudKit, so adding fields needs no schema change.",
                "The candidate universe is computed by MatchUniverse.candidates: EVERY roster worker is a candidate, annotated with willingness — willing (published, open), unknown (no profile yet → still included, ranked lower), or declined (openness=None → excluded unless What-If). A peer with no profile defaults to Bookends-Only via one factory (defaultForUnpublished), so a profileless person is never offered a split-the-weekend pickup.",
            ]),
        MechanismSection(
            title: "The matching engine — three layers",
            symbol: "square.stack.3d.up",
            summary: "Eligibility predicate → two-way exploration → N-way circular DFS.",
            details: [
                "Layer 1 — Eligibility (TradeEligibility.canCover): the SINGLE shared predicate every path delegates to. It enforces all HARD gates — desk qualification (DeskRules.qualified), 8-hour inter-shift rest, Must-Be-Off, the relief-dispatcher horizon (isPastRelief), and bookend anchoring (isAnchored, the no-split-the-weekend rule). Two option sets, .full and .physicalOnly, let callers include or exclude the soft/preference layer. Because every matcher runs this exact code, the contractual rules can never diverge between feeds.",
                "Layer 2 — Two-way exploration (TradeMatcher.twoWayExplore): for a given peer, it constructs the reciprocal balanced set — the days I could cover for them and they for me — gated by BOTH parties' real profiles, and tags each leg as wanted (mutual intent, 🔥) and bookend vs split. Peer schedules are preloaded once, so there is no per-peer re-fetch.",
                "Layer 3 — N-way circular routing (nWayRoutes): a bounded depth-first search for loops A→B→C→A where each participant gives one shift and receives one, netting equal hours. Loops close only at depth ≥ 3 (a 2-cycle is just a two-way swap). The DFS is best-first at EVERY node (candidates ordered by givePromise — urgency + soonness + qual friction), cooperatively cancellable (Task.isCancelled, so a re-search supersedes rather than races a stale one), and bounded by a maxRoutes backstop (500) — the acceptance floor, not the cap, is what actually curates the results.",
            ]),
        MechanismSection(
            title: "Optimal & min-cost reciprocal matching",
            symbol: "point.3.connected.trianglepath.dotted",
            summary: "Provably-fewest-people covers via branch-and-bound and min-cost flow.",
            details: [
                "When no single peer can reciprocally cover all your give-days, OptimalMatcher.minPeopleReciprocal searches for the provably fewest counterparties that can — a branch-and-bound over peer subsets, pruned by an admissible bound so it doesn't explore dominated combinations. A greedy balanced cover is the fallback when an exact optimum isn't reached in budget.",
                "A min-cost flow engine (MinCostFlow) underlies the assignment of give-days to coverers, so when several arrangements have the same people-count, the one with the best total cost (urgency-weighted, fewest splits) is chosen rather than an arbitrary first match.",
                "Reciprocity is always balanced: you give N and receive N back, every leg passing Layer 1 — the app never proposes a one-sided giveaway as a 'swap' (one-way giveaways are the separate ECB path).",
            ]),
        MechanismSection(
            title: "Acceptance scoring model (packageLogProb)",
            symbol: "function",
            summary: "Each trade scores as the product of its per-leg accept probabilities.",
            details: [
                "Every handoff (leg) is reduced to a LegFeatures vector from live data: intentLevel ∈ {0,1,2} (want-to-take + want-to-trade), bookend vs split, timeValue = exp(−0.05 · daysUntil) (soonness decay), a qual-bridge friction flag, an ECB term, and a small learned per-person acceptance prior.",
                "A leg's log-odds is a weighted linear model: legLogit = 1.5·intentLevel + (bookend ? +0.8 : −(2.5 − 1.1·intentLevel)) + 0.8·timeValue − 1.2·(needs-qual-bridge) + 1.5·ecbValue + 0.2·personPrior. Note the split penalty is intent-scaled — a fully-mutual leg (intentLevel 2) almost cancels the split cost, so a wanted split can still surface while a no-intent split is heavily punished. The logistic σ(legLogit) gives the leg's accept probability.",
                "A package's score is the product of its legs in log-space: packageLogProb = Σ ln σ(legLogitᵢ) + max(0, N−2)·ln(0.85). That last N-penalty (0.85 per extra person beyond two) guarantees that, all else equal, a smaller clean trade outranks a larger one — e.g. an all-mutual 3-person book sorts below an all-mutual 2-person split.",
                "The per-person prior is learned, not hand-set: PersonPrior.logOdds(accepted, declined) turns a partner's historical accept/decline record into a logit, computed once per search from all responses (acceptancePriorMap) and looked up O(1) per leg. It ships at a deliberately low weight (0.2) — match priorities dominate, individual history only breaks ties.",
            ]),
        MechanismSection(
            title: "Curation — absolute floors, not top-N",
            symbol: "line.3.horizontal.decrease.circle",
            summary: "Results are score-ordered and cut at a probability floor.",
            details: [
                "Instead of an arbitrary 'top 60', finalize() score-orders by packageLogProb and keeps everything above an ABSOLUTE acceptance floor: 0.32 combined-accept for the normal feed, a wider 0.07 under 'I'm Feeling Lucky'. A no-intent split-the-weekend trade simply scores below the floor and never appears.",
                "An empty-feed fallback shows the top few by score if nothing clears the floor (so you always get the best available), and a safety ceiling caps the absolute maximum. The branch-and-bound and DFS also prune against an admissible upper bound on packageLogProb, so partial paths that can't beat the floor are abandoned early.",
                "The same scoring + floor gate runs behind Trade Solutions, Intents, and ECB — one curation rule, not three.",
            ]),
        MechanismSection(
            title: "Intents marketplace (intent-first)",
            symbol: "flame",
            summary: "A distinct engine that ranks by mutual intent, not just availability.",
            details: [
                "Intents (intentSolutions) is a separate engine from Trade Solutions (packages). It seeds from any day someone actually MARKED — yours OR a peer's trade-away — so a peer's marked day you'd happily take seeds a deal even when you marked no give. assembleIntentDeal then builds the best balanced two-person deal maximizing mutual-marked legs.",
                "Ranking is intent-first: most mutual 🔥 (both sides marked), then fewest people, then bookends/soonness. Unprofiled peers can still join via preferences (Bookends-Only default), but a pairing where NEITHER side marked an intent is excluded by construction — that's what makes it a marketplace rather than a plain availability search.",
                "Under 'I'm Feeling Lucky', the marketplace also runs circular loops that require only ≥1 marked seed leg (allowPrefMiddles), with fireCount = the real count of marked legs so all-intent loops rank highest without hard-coding it.",
            ]),
        MechanismSection(
            title: "Qual swaps (3-party bridge)",
            symbol: "person.2.badge.gearshape",
            summary: "Slide a qualified person aside so an unqualified taker can cover.",
            details: [
                "When a give-day's desk needs a qualification no available off-taker holds (DeskRules.isQualBlocked), QualSwap.solutions assembles a 3-party bridge: a qualified working dispatcher C slides onto your desk, freeing C's desk for off-taker B to take. The bridge C is NOT counted in the trade's people-count — it's an enabling leg, not a participant in your N.",
                "It surfaces automatically as a purple-Q card in any search where it unblocks a give-day, and Propose opens a blast picker so multiple eligible bridges are asked at once; acceptances fill up to a cap, then the taker chooses which bridge's freed desk to take (Q5 desk-choice). A settled bridge can later be merged into its clean base trade so the two requests become one.",
                "There's also a dedicated multi-select Qual-Swap button that enumerates ALL bridge arrangements for chosen international give-days on demand, independent of whether a direct trade also exists.",
            ]),
        MechanismSection(
            title: "ECB one-way give-aways",
            symbol: "star.circle",
            summary: "Hand a shift off for ECB credit, claimed fairly in queue order.",
            details: [
                "When you want a shift covered rather than swapped, broadcast it with an ECB value in 0.5 steps (5–25; a 1.5× OT shift = 13.5). The value is carried losslessly everywhere — request, offer, accept, receipt, history.",
                "Interested dispatchers accept per shift and are ordered into a fair queue (each sees their position); the same eligibility gates apply via canCover(.physicalOnly). The recipient confirms receipt; the official ECB form is filed outside the app — DX Trader coordinates the agreement, ARIS/WorkNet records the change.",
            ]),
        MechanismSection(
            title: "Sync, conflict-resolution & push",
            symbol: "icloud",
            summary: "CloudKit public/private DBs, last-write-wins merges, targeted subscriptions.",
            details: [
                "Profiles, the channel, trade requests/responses, and team metrics live in the CloudKit public database. Each record stores the WHOLE model as a JSON payload, plus a few flat, queryable-indexed fields (toID, fromID, candidateIDs, perfectMatch, hasQualSwap) used only for server-side filtering — so the data model evolves without schema churn while filtered fetches stay cheap.",
                "Private notes use the private database with a last-write-wins merge (LWW, by updatedAt clock) across your own devices; status broadcasts sync the same way. A FetchMerge.keepCacheOnEmpty guard ensures a transient query error (which returns an empty set) can never wipe a populated local cache — the root cause of an earlier data-loss class.",
                "Push uses targeted CKQuerySubscriptions: an ordinary incoming request (perfectMatch==0), a stronger 'perfect match' alert (perfectMatch==1), a qual-swap bridge blast (candidateIDs CONTAINS me), and a qual-swap response (hasQualSwap==1, fires on record update) — each scoped by predicate so you're pinged only for what's actually yours.",
            ]),
        MechanismSection(
            title: "Performance & architecture",
            symbol: "bolt",
            summary: "Parse-once/query-many; cheap by default, heavy search only on demand.",
            details: [
                "The matching is parse-once/query-many: the roster is parsed and indexed once, then every search is in-memory map lookups, not re-parsing. The background feed runs ONLY the fast two-person pass — the expensive 3+/circular DFS, min-cost optimization, and qual-swap assembly run once, on demand, behind 'I'm Feeling Lucky → Generate', so they never burn cycles in the background.",
                "Each search builds one shared MatchContext: the roster window, per-worker day-maps, the candidate universe, and the acceptance-prior map are loaded a SINGLE time and threaded through packaging, intent assembly, and the N-way DFS — collapsing what used to be 2–4 redundant SwiftData fetches and a per-leg responses scan into one pass.",
                "Behavior-preserving refactors are guarded: pure cores (scoring, ranking, eligibility, parsing) have a unit harness with adversarial 'teeth' tests, and an architecture-map guard script blocks drift between the code and its documented contracts.",
            ]),
    ]

    /// Build 6 "What's New" — the most impactful changes, each with WHAT changed and WHY it matters.
    /// Shown as the second welcome screen. Operator-facing.
    struct Build6Highlight: Identifiable, Sendable {
        let id = UUID(); let symbol: String; let title: String; let what: String; let why: String
    }
    static let build6Highlights: [Build6Highlight] = [
        Build6Highlight(
            symbol: "banknote.fill", title: "ECB Accounting — track your ECB",
            what: "Now when you tap ⋯ you'll find ECB Accounting: a YNAB-style ledger for all your ECB. Log every deposit (OT, holidays), withdrawal, and trade, and it keeps a running balance — Available (what's cleared, capped at 144), Projected (once scheduled ECB and IOUs land), and what you Owe / are Owed. Lines stay pending until you clear them on a pay day.",
            why: "Your ECB is finally budgeted like money instead of tracked on paper or in your head — you always know exactly what you have, what's coming, and what's promised. Trades post to BOTH ledgers and stay in sync, and you can even IOU a future deposit before it lands."),
        Build6Highlight(
            symbol: "beach.umbrella.fill", title: "Vacation & ECB VC days",
            what: "The master schedule can't tell whether you traded into a vacation day, so all vacation (and ECB-VC) days start OFF. Picked one up? Open the day and toggle \"Trade Picked Up.\"",
            why: "That builds the day into both the in-app calendar and your Apple Calendar, so what you actually work shows up instead of a blanket \"off.\""),
        Build6Highlight(
            symbol: "calendar.badge.plus", title: "Apple Calendar sync",
            what: "Your working shifts build straight into Apple Calendar, and any day you change in the app (like a picked-up vacation day) updates there too. On Google Calendar? Add your Google account in iOS Settings → Calendar and your shifts flow there automatically.",
            why: "Your real schedule lives in the calendar you already check — no double entry."),
        Build6Highlight(
            symbol: "apps.iphone", title: "Home Screen widgets",
            what: "Long-press your Home Screen → tap ＋ → search \"DX Trader.\" \"Next Shift\" shows your next shift and a week-at-a-glance strip; \"Trade Requests\" shows how many requests are waiting to reply to.",
            why: "Your next shift and pending trades sit on your Home Screen — a glance instead of opening the app."),
        Build6Highlight(
            symbol: "plus.magnifyingglass", title: "Screen magnifier",
            what: "Left ON by default — turn it off in ⋯ → App Settings → Accessibility. A draggable button appears on every screen — tap it, pinch to zoom, drag with two fingers to pan; one finger still taps and scrolls.",
            why: "Makes the whole app usable if you're hard of sight, without fighting the system zoom."),
        Build6Highlight(
            symbol: "sparkles", title: "Smarter, faster Intents",
            what: "Two sections now — \"Mutual\" (both of you marked the day) and \"All\" (every possible partner, not just people on the app). Switching is instant; the heavy 3+person / loop search is opt-in via \"More: 3+ & loops.\"",
            why: "True mutual matches and the wider pool, right away — the app only runs the heavy search when you ask."),
        Build6Highlight(
            symbol: "square.grid.2x2.fill", title: "Cleaner, less-cluttered layout",
            what: "Redesigned trade/package cards (one \"Name — dates\" line each) and calendar; Trade Settings are now tap pills (shift types, regions, blackout days); a tidier top bar (Inbox · Channel · Trade status · ⋯); tapping any day opens the full editor. \"Keep\" (green) and \"Blackout\" (slate) are distinct everywhere.",
            why: "Less noise, fewer taps — what you use most is easier to find and act on."),
        Build6Highlight(
            symbol: "bell.badge.fill", title: "Live daily digest + @mentions",
            what: "The daily summary refreshes its counts in the background so it's current when it fires, and @-mentioning a dispatcher in a channel sends them a push.",
            why: "Timely nudges about what needs you — without opening the app."),
    ]

}

/// Outlook/email trade announcement to the dispatch DL (G1). Pure body/URL builders so
/// the text is unit-testable; the view just opens the URL. Blackout days = the sender's
/// Must-Be-Off intents (NOT blacklist).
enum TradeEmail {
    /// The email body. `giveDays`/`takeDays`/`blackoutDays` are already human-formatted.
    static func body(giver: String, taker: String, giveDays: [String], takeDays: [String],
                     blackoutDays: [String]) -> String {
        var parts: [String] = []
        if !giveDays.isEmpty { parts.append("\(giver) gives \(giveDays.joined(separator: ", "))") }
        if !takeDays.isEmpty { parts.append("\(taker) gives \(takeDays.joined(separator: ", "))") }
        var s = "Trade request: \(giver) ⇄ \(taker)"
        if !parts.isEmpty { s += " — " + parts.joined(separator: "; ") }
        s += ". Sent via DX Trader."
        if !blackoutDays.isEmpty {
            s += "\n\nBlackout days (unavailable): \(blackoutDays.joined(separator: ", "))."
        }
        return s
    }

    static func subject(giver: String, taker: String) -> String { "Trade request: \(giver) ⇄ \(taker)" }

    /// #7: broadcast trade-away email to the dispatch DL (from Trade Solutions) — the days offered
    /// + the sender's Must-Be-Off blackout days.
    static func dispatchBody(giver: String, giveDays: [String], blackoutDays: [String]) -> String {
        let days = giveDays.isEmpty ? "(no days selected)" : giveDays.joined(separator: ", ")
        var s = "\(giver) is looking to trade away: \(days). Sent via DX Trader."
        if !blackoutDays.isEmpty { s += "\n\nBlackout days (unavailable): \(blackoutDays.joined(separator: ", "))." }
        return s
    }
    static func dispatchSubject(giver: String) -> String { "Trade request — \(giver)" }

    /// #7: ECB broadcast email — states the ECB offered for the days, and (per spec) NO blackout days.
    static func ecbBody(giver: String, giveDays: [String], ecb: Double) -> String {
        let days = giveDays.isEmpty ? "(no days selected)" : giveDays.joined(separator: ", ")
        return "\(giver) is offering \(ecbText(ecb)) ECB to cover: \(days). Sent via DX Trader."
    }
    static func ecbSubject(giver: String, ecb: Double) -> String { "ECB trade — \(ecbText(ecb)) ECB — \(giver)" }

    /// `mailto:` draft to the DL (opens the default mail app, incl. Outlook if it's default).
    static func mailtoURL(dl: String, subject: String, body: String) -> URL? {
        let allowed = CharacterSet.urlQueryAllowed
        guard !dl.trimmingCharacters(in: .whitespaces).isEmpty,
              let s = subject.addingPercentEncoding(withAllowedCharacters: allowed),
              let b = body.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "mailto:\(dl)?subject=\(s)&body=\(b)")
    }

    /// Outlook compose deep-link (opens Outlook directly if installed).
    static func outlookURL(dl: String, subject: String, body: String) -> URL? {
        let allowed = CharacterSet.urlQueryAllowed
        guard !dl.trimmingCharacters(in: .whitespaces).isEmpty,
              let to = dl.addingPercentEncoding(withAllowedCharacters: allowed),
              let s = subject.addingPercentEncoding(withAllowedCharacters: allowed),
              let b = body.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "ms-outlook://compose?to=\(to)&subject=\(s)&body=\(b)")
    }
}

/// Guards against a transient CloudKit fetch error (e.g. querying an undeployed field) wiping the
/// visible list: keep the existing cache when a fetch comes back EMPTY but we had data. (P0 data-wipe)
enum FetchMerge {
    static func keepCacheOnEmpty<T>(existing: [T], fetched: [T]) -> [T] {
        (fetched.isEmpty && !existing.isEmpty) ? existing : fetched
    }
}

// MARK: - Match universe (R-A) — the candidate set is the ROSTER, profiles layer on top

/// One matchable dispatcher: from the roster, annotated with published willingness.
struct MatchCandidate: Sendable, Hashable {
    let workerID: String
    let name: String
    let quals: [String]
    let willingness: TradeWillingness
}

enum MatchUniverse {
    /// THE candidate universe for matching (R-A fix): EVERY roster worker except self, annotated
    /// with their published willingness. A worker with NO published profile is `.unknown` (kept,
    /// ranked below willing) — NOT invisible. `.declined` (openness = none) is excluded unless
    /// `includeDeclined` (What-If). Profiles are the willingness LAYER, not the universe.
    static func candidates(roster: [(id: String, name: String, quals: [String])],
                           profiles: [String: TradeProfile], selfID: String,
                           includeDeclined: Bool = false) -> [MatchCandidate] {
        roster.compactMap { w in
            guard w.id != selfID else { return nil }
            let willingness: TradeWillingness
            if let p = profiles[w.id] {
                willingness = (p.opennessLevel == .none) ? .declined : .willing
            } else {
                willingness = .unknown   // on the roster but hasn't opted in → still a candidate
            }
            if willingness == .declined && !includeDeclined { return nil }
            return MatchCandidate(workerID: w.id, name: w.name, quals: w.quals, willingness: willingness)
        }
    }
}

/// People search + pin-to-top for the unified people lists (C4). Pure + testable.
enum PeopleFilter {
    /// Case-insensitive name filter; pinned ids first, each group keeping its original order.
    static func arrange<T>(_ items: [T], query: String, pinned: Set<String>,
                           id: (T) -> String, name: (T) -> String) -> [T] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? items : items.filter { name($0).lowercased().contains(q) }
        return filtered.filter { pinned.contains(id($0)) } + filtered.filter { !pinned.contains(id($0)) }
    }
}

/// Last-write-wins merge for cross-device sync (A3). Pure + testable.
enum LWW {
    /// Pick the value with the newer timestamp; ties keep `local`.
    static func pick<T>(local: T, localAt: Date, remote: T, remoteAt: Date) -> T {
        remoteAt > localAt ? remote : local
    }
}

/// Pure char-limit state for the field counters (F3). `nearLimit` at ≥90% used.
enum CharLimit {
    static func state(_ text: String, limit: Int) -> (used: Int, remaining: Int, nearLimit: Bool, over: Bool) {
        let used = text.count
        return (used, limit - used, limit > 0 && Double(used) >= Double(limit) * 0.9, used > limit)
    }
}
