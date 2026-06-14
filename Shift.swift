// Shift.swift
// Core data model for a single work shift.
// Parsed from the ARIS/WorkNet Expanded Schedule Report (CSV grid).
//
// In the CSV each day is encoded as [start, desk]:
//   05, 29   → 0500–1400, desk 29
//   21, OJT  → 2100–0600 (next day), OJT
//   13, RC3  → 1300–2200, route check 3
//   OFF      → day off (no shift)
// All shifts are 9 official hours regardless of start time.

import Foundation

// MARK: - Role

enum ShiftRole: String, Codable, CaseIterable {
    case dispatcher = "DSP"
    case ojt        = "OJT"
    case routeCheck = "RC"
    case ops        = "OPS"
    case atc        = "ATC"
    case off        = "OFF"
}

// MARK: - Shift

struct Shift: Codable, Identifiable, Hashable {

    // Unique key: ISO date string, e.g. "2026-06-15"
    let id: String

    let date: Date

    // Raw 24-hour start/end hour (stored as integer hour, no leading zero).
    // Shifts are always 9 hours; start times vary (05, 07, 09, 13, 15, 17, 21, …)
    // and may cross midnight, so endHour can be earlier than startHour.
    let startHour: Int   // e.g. 5, 13, 21
    let endHour: Int     // (startHour + 9) mod 24

    let role: ShiftRole
    let desk: String        // "29", "82", "OJT", "RC1", ""
    let leaveCode: String?  // "S"=sick, "V"=vacation, "w"=weather/other, nil=none
    let isOff: Bool

    // MARK: - Computed helpers

    /// Full start datetime for this shift (0500 or 1300 local time).
    var startDate: Date {
        Calendar.current.date(bySettingHour: startHour, minute: 0, second: 0, of: date) ?? date
    }

    /// Full end datetime for this shift. Shifts are always 9 hours, which may
    /// cross midnight (e.g. a 2100 start ends 0600 the next day).
    var endDate: Date {
        Calendar.current.date(byAdding: .hour, value: 9, to: startDate) ?? startDate
    }

    /// Zero-padded 24h start string, e.g. "0500" or "1300".
    var startTimeString: String { String(format: "%02d00", startHour) }

    /// Zero-padded 24h end string, e.g. "1400" or "2200".
    var endTimeString: String   { String(format: "%02d00", endHour) }

    /// Calendar event title — start time and desk/special code,
    /// e.g. "0500 · 29", "2100 · OJT", or "Day Off".
    var title: String {
        guard !isOff else { return "Day Off" }
        return desk.isEmpty ? startTimeString : "\(startTimeString) · \(desk)"
    }

    /// Human-readable alarm hour pre-offset by the user's lead time.
    /// Used by Shortcuts to set alarm time without doing math.
    func alarmHour(leadHours: Int) -> Int {
        max(0, startHour - leadHours)
    }

    /// ISO-formatted date string: "2026-06-15". Used in Shortcuts date math.
    var isoDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Medium-format date for display: "Jun 15, 2026".
    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// Date with weekday for display: "Fri, Jun 15".
    var weekdayDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    /// Single-letter shift type for compact grids: "A"/"P"/"M", "" when off.
    var shiftLetter: String {
        guard !isOff else { return "" }
        switch ShiftAvailabilityType.infer(fromStartHour: startHour) {
        case .am:  return "A"
        case .pm:  return "P"
        case .mid: return "M"
        }
    }

    /// Short label for calendar cells: "AM 82", "PM OJT", "MID 27", "" when off.
    var shiftShortLabel: String {
        guard !isOff else { return "" }
        let type = ShiftAvailabilityType.infer(fromStartHour: startHour).rawValue
        return desk.isEmpty ? type : "\(type) \(desk)"
    }
}
