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
        case .mustWork:       return "Want to Keep"
        case .wantToWork:     return "Want to Work"
        case .neutralOpen:    return "Open"
        case .dontWantToWork: return "Want to Trade Away"
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
        case .mustBeOff:   return "Must Be Off"
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

    /// How much the probabilistic score contributes to the deterministic `qualityScore` band (legacy,
    /// near-silent). The packageLogProb floor below is the real gate now.
    static let qualityBlendWeight = 0.05

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
    /// Admissible upper bound on a partial route's final log-prob: the running sum (remaining legs
    /// can only add ≤ 0). Prune mid-DFS when this drops below log(threshold) — never drops a valid route.
    static func upperBoundLogProb(partial legs: [LegFeatures]) -> Double { packageLogProb(legs) }

    /// A package-level acceptance log-prob from its summary signals, built on the REAL model
    /// (`legLogit`→`legProb`→`packageLogProb`). DEV-ONLY instrumentation: this is COMPUTED and recorded
    /// but is NOT a ranking input — it never changes which trades surface. `exp(result)` = P(executes).
    static func packageScore(legCount: Int, fireCount: Int, bookendTotal: Int,
                             partnerPrior: Double, ecb: Double = 0) -> Double {
        guard legCount > 0 else { return 0 }
        let feats = (0..<legCount).map { i in
            LegFeatures(wantToTake: i < fireCount, wantToTrade: i < fireCount, bookend: i < bookendTotal,
                        timeValue: 0.5, needsQualBridge: false, ecbValue: ecb, personPrior: partnerPrior)
        }
        return packageLogProb(feats)
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
}

/// A2: the "I'm Feeling Lucky" Master Filter — shapes the on-demand search. Pure value type so
/// the UI state and the result-filtering agree (single source of truth) and are harness-tested.
struct SearchFilter: Equatable, Sendable {
    enum Engine: String, CaseIterable, Sendable { case minCost, nWay, both }
    var engine: Engine = .both
    var maxPeople: Int = 4          // 1…4 distinct participants (incl. you)
    var requiredWorkerID: String?   // when set, only solutions that INCLUDE this person

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
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// True if `id` is a participant of `p` (peer assignment or a route participant).
    private func contains(_ id: String, _ p: TradePackage) -> Bool {
        p.assignments.contains { $0.workerID == id } || (p.route?.participants.contains(id) ?? false)
    }
    /// Apply the filter to a result set (post-search). Engine selects methodology, maxPeople caps
    /// participants, requiredWorkerID forces a person into every kept solution.
    func filter(_ packages: [TradePackage]) -> [TradePackage] {
        packages.filter { p in
            if p.peopleCount > maxPeople { return false }
            if let req = requiredWorkerID, !contains(req, p) { return false }
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
    /// Working-day brushes (every WorkingIntentState that's meaningful on a day you work).
    static let working: [WorkingIntentState] = [.dontWantToWork, .mustWork, .neutralOpen]
    /// Off-day brushes — must cover ALL OffIntentState cases.
    static let off: [OffIntentState] = [.mustBeOff, .wantToWork, .neutralOpen]
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

/// One release's notes for the startup "What's New" sheet (Z2).
struct ChangeLogEntry: Sendable {
    let title: String
    let added: [String]
    let fixed: [String]
    let changed: [String]
    let improved: [String]
    let toTest: [String]   // short, curated tester checklist
}

enum ChangeLog {
    /// Show the sheet once per build the user hasn't seen yet.
    static func shouldShow(currentBuild: String, lastSeen: String) -> Bool {
        !currentBuild.isEmpty && currentBuild != lastSeen
    }

    /// The latest release notes (hand-authored per release).
    static let current = ChangeLogEntry(
        title: "What's New",
        added: [
            "Qual swaps — automatically suggested in every search when a desk needs a qual the taker lacks (with a blast picker).",
            "“Just 2” tab — pick a day, see only direct two-person swaps, filter by dispatcher.",
            "Relief Dispatcher mode — hide your placeholder shifts past your real schedule date.",
            "Emoji reactions on posts, replies, and 1:1 chats.",
            "“Perfect Match” push when a trade hits a day you're after.",
            "Team-wide trade metrics on Home.",
            "Email a trade to the dispatch DL (prefilled Outlook draft).",
            "Attach a photo to a channel post.",
        ],
        fixed: [
            "Vacation days no longer read as working shifts (and auto-mark Must-Be-Off).",
            "Relief placeholder shifts are hidden everywhere — calendar, trading, and your schedule.",
        ],
        changed: [
            "“Search” is now “Trade Solutions” — every result is a clean package card.",
            "Intents is one sorted list (fewest people → 🔥 → bookends).",
            "Calendar event titles are just the shift + desk (e.g. “AM 82”).",
        ],
        improved: [
            "One unified matching engine behind Search, Intents, and ECB — consistent, more accurate.",
            "Faster launch (test scaffolding removed from the shipped app).",
        ],
        toTest: [
            "Mark a few intents on Home, then open Trade Solutions and propose one.",
            "Try a card with the purple “Q” (qual swap) and send the blast.",
            "Turn on Relief Dispatcher in Trade Settings + set a date.",
            "React to a channel post and attach a photo.",
            "Email a trade to the dispatch DL from a trade thread.",
        ])
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
        s += ". Sent via BATMAN Watcher."
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
        var s = "\(giver) is looking to trade away: \(days). Sent via BATMAN Watcher."
        if !blackoutDays.isEmpty { s += "\n\nBlackout days (unavailable): \(blackoutDays.joined(separator: ", "))." }
        return s
    }
    static func dispatchSubject(giver: String) -> String { "Trade request — \(giver)" }

    /// #7: ECB broadcast email — states the ECB offered for the days, and (per spec) NO blackout days.
    static func ecbBody(giver: String, giveDays: [String], ecb: Double) -> String {
        let days = giveDays.isEmpty ? "(no days selected)" : giveDays.joined(separator: ", ")
        return "\(giver) is offering \(ecbText(ecb)) ECB to cover: \(days). Sent via BATMAN Watcher."
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
