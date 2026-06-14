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
        case .pending, .countered: self = .pendingNegotiation
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
                     unread: Int) -> DashboardCounts {
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
        return DashboardCounts(accepted: accepted, pending: pending, denied: denied, unread: unread)
    }
}
