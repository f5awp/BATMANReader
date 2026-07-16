// ShiftAvailability.swift
// Data models for the shared dispatcher availability system.
//
// ── How availability works ────────────────────────────────────────────
// When the schedule is fetched, every off day gets a default
// availability type inferred from your typical shift pattern.
// You can override any day manually in the Availability tab.
//
// Your entries on the shared calendar look like:
//   "Lee, Ervin | AM Available"
//   "Lee, Ervin | PM Available"
//   "Lee, Ervin | MID Available"
//
// No entry = not available. Absence is the signal, not an explicit row.
//
// When you want to trade, you query the shared calendar for a date
// and get back every dispatcher who posted availability there.
// ─────────────────────────────────────────────────────────────────────

import Foundation
import AppIntents

// MARK: - Shift availability type

enum ShiftAvailabilityType: String, Codable, CaseIterable, Hashable, AppEnum {

    case am  = "AM"
    case pm  = "PM"
    case mid = "MID"

    // Conforms to AppEnum so it appears as a proper picker in Shortcuts
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Shift Type"

    static var caseDisplayRepresentations: [ShiftAvailabilityType: DisplayRepresentation] = [
        .am:  DisplayRepresentation(title: "AM (0500 start)"),
        .pm:  DisplayRepresentation(title: "PM (1300 start)"),
        .mid: DisplayRepresentation(title: "MID (overnight)")
    ]

    /// The string written to the shared calendar event title.
    var calendarLabel: String {
        switch self {
        case .am:  return "AM Available"
        case .pm:  return "PM Available"
        case .mid: return "MID Available"
        }
    }

    var sfSymbol: String {
        switch self {
        case .am:  return "sunrise.fill"
        case .pm:  return "sunset.fill"
        case .mid: return "moon.stars.fill"
        }
    }

    var color: String {
        switch self {
        case .am:  return "orange"
        case .pm:  return "indigo"
        case .mid: return "purple"
        }
    }

    /// 24-hour start hour of this availability type's 9-hour shift.
    var startHour: Int {
        switch self {
        case .am:  return 5
        case .pm:  return 13
        case .mid: return 21
        }
    }

    /// Infer availability type from a shift's start hour.
    nonisolated static func infer(fromStartHour hour: Int) -> ShiftAvailabilityType {
        switch hour {
        case 0..<10:  return .am
        case 10..<18: return .pm
        default:      return .mid
        }
    }
}

// MARK: - Match Radar model (DX-MATCH-RADAR-SPEC v3.1)

/// How a day is offered/accepted: a straight day-for-day swap, for ECB points, or either.
/// A match is valid only when the two sides' kinds intersect; the match kind = that intersection.
enum TradeKind: String, Codable, Sendable, CaseIterable, Hashable {
    case day, ecb, both
    /// The resolved kind when a giver of `self` meets a taker of `other` — nil if they can't transact.
    func resolve(with other: TradeKind) -> TradeKind? {
        if self == .both { return other }
        if other == .both { return self }
        return self == other ? self : nil
    }
}

/// What a user will accept — for a want-to-work pickup OR a day-for-day return. All-empty/nil = OPEN
/// (defer to the user's global trade prefs), so an unset day behaves exactly as today. (#Match-Radar §8)
struct AcceptScope: Codable, Sendable, Hashable {
    var dates: Set<String>? = nil                    // ISO days (or a range materialized to a set); nil = any date
    var shiftTypes: Set<ShiftAvailabilityType> = []  // empty = any shift type
    var quals: Set<String> = []                      // empty = any qual
    var desks: Set<String>? = nil                    // nil = any desk
    var isOpen: Bool { (dates?.isEmpty ?? true) && shiftTypes.isEmpty && quals.isEmpty && (desks?.isEmpty ?? true) }

    /// Does this scope accept a return/pickup leg with the given shift type, desk, and date? An OPEN scope
    /// (nothing set) accepts anything; otherwise every SET facet must match (AND across facets). Qual scoping
    /// is enforced upstream by desk eligibility, so it isn't re-checked at the leg level here.
    func accepts(shiftType: ShiftAvailabilityType, desk: String, dayID: String) -> Bool {
        if isOpen { return true }
        if let dates, !dates.isEmpty, !dates.contains(dayID) { return false }
        if !shiftTypes.isEmpty, !shiftTypes.contains(shiftType) { return false }
        if let desks, !desks.isEmpty, !desks.contains(desk) { return false }
        return true
    }

    /// Given ALL of a user's per-give-day accept-scopes and the days they'd give, would SOME give accept this
    /// return leg? A give day WITHOUT an explicit scope is OPEN (accepts anything) → never prunes. Only prunes
    /// when every scoped give rejects the leg. Inert (returns true) when no scopes are set — so unset behaves
    /// exactly as today. (#Match-Radar §8 — the deferred accept-scope prune.)
    static func acceptsUnderAny(_ scopes: [String: AcceptScope]?, giveDayIDs: [String],
                                shiftType: ShiftAvailabilityType, desk: String, dayID: String) -> Bool {
        guard let scopes, !scopes.isEmpty, !giveDayIDs.isEmpty else { return true }
        if giveDayIDs.contains(where: { scopes[$0] == nil }) { return true }   // an unscoped give is open
        return giveDayIDs.contains { scopes[$0]?.accepts(shiftType: shiftType, desk: desk, dayID: dayID) ?? true }
    }
}

// MARK: - Your availability entry for a single day

struct DayAvailability: Codable, Identifiable, Hashable {

    let id: String          // ISO date "2026-06-15"
    let date: Date

    /// Rest-eligible shift types the dispatcher is offering for this off day.
    /// Empty = not available.
    var availableTypes: Set<ShiftAvailabilityType>

    var isAvailable: Bool { !availableTypes.isEmpty }

    /// Offered types in display order (AM, PM, MID).
    var sortedTypes: [ShiftAvailabilityType] {
        ShiftAvailabilityType.allCases.filter { availableTypes.contains($0) }
    }

    /// Shared-calendar event title for one offered type, e.g. "Lee, Ervin | PM Available".
    func calendarTitle(displayName: String, type: ShiftAvailabilityType) -> String {
        "\(displayName) | \(type.calendarLabel)"
    }

    /// Formatted date string for display.
    var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }
}

// MARK: - Another dispatcher's availability as read from the shared calendar

struct DispatcherAvailabilityEntry: Identifiable, Hashable {
    var id: String { "\(name)-\(isoDate)" }
    let name: String
    let availability: ShiftAvailabilityType
    let date: Date
    let isoDate: String

    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }
}

// MARK: - Calendar title parser

extension DispatcherAvailabilityEntry {

    /// Parses a calendar event title of the form "Last, First | AM Available"
    /// Returns nil if the title doesn't match the expected format.
    static func parse(title: String, date: Date) -> DispatcherAvailabilityEntry? {
        let parts = title.components(separatedBy: " | ")
        guard parts.count == 2 else { return nil }

        let name       = parts[0].trimmingCharacters(in: .whitespaces)
        let typeString = parts[1]
            .replacingOccurrences(of: " Available", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty,
              let type = ShiftAvailabilityType(rawValue: typeString) else { return nil }

        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"

        return DispatcherAvailabilityEntry(
            name:         name,
            availability: type,
            date:         date,
            isoDate:      iso.string(from: date)
        )
    }
}
