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
    static func infer(fromStartHour hour: Int) -> ShiftAvailabilityType {
        switch hour {
        case 0..<10:  return .am
        case 10..<18: return .pm
        default:      return .mid
        }
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
