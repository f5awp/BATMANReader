// ShiftEntity.swift
// AppEntity that exposes a Shift to the Shortcuts editor.
//
// Each @Property becomes a named variable in the Shortcuts UI.
// When you use "Get My Shifts" in a Shortcut, each shift in the
// returned list has all these fields available to drag into other actions.
//
// Key properties for the Shortcuts alarm/calendar workflow:
//   • "Title"       → use as the Calendar event name
//   • "ISO Date"    → use as the event/alarm date
//   • "Start Time"  → use as event start (formatted "HH:MM")
//   • "End Time"    → use as event end
//   • "Alarm Hour"  → pre-calculated alarm hour (start − lead time)
//                     plug directly into Shortcuts "Create Alarm" action

import AppIntents
import Foundation

struct ShiftEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Shift"
    static var defaultQuery = ShiftEntityQuery()

    // Unique identifier — ISO date string: "2026-06-15"
    var id: String

    // ── Shortcuts-visible properties ──────────────────────────────────

    @Property(title: "Title")
    var title: String           // "DSP @ 29" — use as calendar event title

    @Property(title: "Date")
    var dateString: String      // "June 15, 2026" — human-readable

    @Property(title: "ISO Date")
    var isoDate: String         // "2026-06-15" — for date math in Shortcuts

    @Property(title: "Start Time")
    var startTime: String       // "05:00" — calendar event start

    @Property(title: "End Time")
    var endTime: String         // "14:00" — calendar event end

    @Property(title: "Start Hour (24h)")
    var startHour: Int          // 5 or 13 — raw for Shortcuts math

    @Property(title: "Alarm Hour (pre-calculated)")
    var alarmHour: Int          // startHour − lead time → plug into Create Alarm

    @Property(title: "Start Date & Time")
    var startDateTime: Date     // actual shift start — for Shortcuts date math

    @Property(title: "Alarm Time (start − lead)")
    var alarmTime: Date         // start − lead time → plug straight into Create Alarm

    @Property(title: "Role")
    var role: String            // "DSP", "OJT", "RC", "OPS", "ATC"

    @Property(title: "Desk")
    var desk: String            // "29", "82", "OJT", "RC1"

    @Property(title: "Leave Code")
    var leaveCode: String       // "V", "S", "w", or "" (empty = no leave)

    @Property(title: "Is Off Day")
    var isOff: Bool

    // ── Display in Shortcuts picker ───────────────────────────────────

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(dateString): \(title)")
    }

    // ── Explicit memberwise init ──────────────────────────────────────

    init(
        id: String,
        title: String,
        dateString: String,
        isoDate: String,
        startTime: String,
        endTime: String,
        startHour: Int,
        alarmHour: Int,
        startDateTime: Date,
        alarmTime: Date,
        role: String,
        desk: String,
        leaveCode: String,
        isOff: Bool
    ) {
        self.id            = id
        self.title         = title
        self.dateString    = dateString
        self.isoDate       = isoDate
        self.startTime     = startTime
        self.endTime       = endTime
        self.startHour     = startHour
        self.alarmHour     = alarmHour
        self.startDateTime = startDateTime
        self.alarmTime     = alarmTime
        self.role          = role
        self.desk          = desk
        self.leaveCode     = leaveCode
        self.isOff         = isOff
    }
}

// MARK: - Entity query (required by AppEntity)

struct ShiftEntityQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [ShiftEntity] {
        await ShiftStore.shared.shifts
            .filter { identifiers.contains($0.id) }
            .map    { $0.toEntity() }
    }

    func suggestedEntities() async throws -> [ShiftEntity] {
        await ShiftStore.shared.upcomingWorkingShifts().map { $0.toEntity() }
    }
}

// MARK: - Shift → ShiftEntity conversion

extension Shift {

    func toEntity() -> ShiftEntity {
        let mediumDate = DateFormatter()
        mediumDate.dateStyle = .long
        mediumDate.timeStyle = .none

        let leadHours = SettingsManager.shared.notificationLeadHours

        // Format times as "HH:MM" for calendar event fields
        let startStr = String(format: "%02d:00", startHour)
        let endStr   = String(format: "%02d:00", endHour)
        let alarm    = Calendar.current.date(byAdding: .hour, value: -leadHours, to: startDate) ?? startDate

        return ShiftEntity(
            id:            id,
            title:         title,
            dateString:    mediumDate.string(from: date),
            isoDate:       isoDate,
            startTime:     startStr,
            endTime:       endStr,
            startHour:     startHour,
            alarmHour:     alarmHour(leadHours: leadHours),
            startDateTime: startDate,
            alarmTime:     alarm,
            role:          role.rawValue,
            desk:          desk,
            leaveCode:     leaveCode ?? "",
            isOff:         isOff
        )
    }
}
