// ScheduleIntents.swift
// Five App Intents exposed to Siri, Shortcuts, and Spotlight.
//
// ── Intent 1: FetchScheduleIntent ────────────────────────────────────
// Logs into ARIS/WorkNet, scrapes the full year report, diffs against
// the stored schedule, syncs EventKit (add/remove calendar events),
// and schedules day-before notifications. Returns the diff summary.
// Run this after every trade or bid change.
//
// ── Intent 2: GetShiftsIntent ────────────────────────────────────────
// Returns saved upcoming shifts. No login. Background-capable.
// Use with "Repeat with Each" + "Create Alarm" in Shortcuts.
//
// ── Intent 3: GetTomorrowsShiftIntent ────────────────────────────────
// Returns tomorrow's shift (or nothing). Use in a 9 PM automation:
// "If result exists → send notification / set alarm."
//
// ── Intent 4: GetShiftChangesIntent ──────────────────────────────────
// Returns what changed in the last fetch (added/removed/updated).
// Useful for a "what changed?" Shortcut after running a fetch.
//
// ── Intent 5: GetShiftForDateIntent ──────────────────────────────────
// Returns the shift on a specific date you choose in Shortcuts.
// "Do I work July 4th?" → run this with date = July 4.
// ─────────────────────────────────────────────────────────────────────

import AppIntents
import Foundation

// MARK: - Intent 1: Fetch

struct FetchScheduleIntent: AppIntent {

    static var title: LocalizedStringResource = "Fetch My Schedule"
    static var description = IntentDescription(
        "Logs into ARIS/WorkNet, downloads your full year schedule, updates your calendar, and reschedules notifications. Run after any trade or bid change."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[ShiftEntity]> {
        let shifts  = try await WebController.shared.fetchSchedule()
        let diff    = ShiftStore.shared.lastDiff
        let working = shifts.filter { !$0.isOff }
        let dialog  = IntentDialog(stringLiteral:
            "\(working.count) shifts loaded. " +
            (diff?.summary ?? "") +
            " Calendar updated."
        )
        return .result(value: working.map { $0.toEntity() }, dialog: dialog)
    }
}

// MARK: - Intent 2: Get saved shifts

struct GetShiftsIntent: AppIntent {

    static var title: LocalizedStringResource = "Get My Shifts"
    static var description = IntentDescription(
        "Returns saved shifts — no login needed. Use with Shortcuts 'Repeat with Each' → 'Create Alarm'."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Only upcoming shifts", default: true)
    var onlyUpcoming: Bool

    @Parameter(title: "Include off days", default: false)
    var includeOffDays: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ShiftEntity]> {
        let store  = ShiftStore.shared
        var shifts = onlyUpcoming ? store.upcomingAllShifts() : store.shifts
        if !includeOffDays { shifts = shifts.filter { !$0.isOff } }

        guard !shifts.isEmpty else {
            throw NSError(domain: "BATMANReader", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No shifts found. Run 'Fetch My Schedule' first."
            ])
        }
        return .result(value: shifts.map { $0.toEntity() })
    }
}

// MARK: - Intent 3: Get tomorrow's shift

struct GetTomorrowsShiftIntent: AppIntent {

    static var title: LocalizedStringResource = "Get Tomorrow's Shift"
    static var description = IntentDescription(
        "Returns your shift tomorrow, or nothing if you're off. Use in a nightly automation: if result exists → set alarm / send notification."
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ShiftEntity?> & ProvidesDialog {
        let shift = ShiftStore.shared.tomorrowsShift

        if let shift {
            let dialog = IntentDialog(stringLiteral:
                "You have a shift tomorrow — \(shift.title) at \(shift.startTimeString)."
            )
            return .result(value: shift.toEntity(), dialog: dialog)
        } else {
            return .result(
                value: nil,
                dialog: IntentDialog(stringLiteral: "You're off tomorrow.")
            )
        }
    }
}

// MARK: - Intent 4: Get last schedule changes

struct GetScheduleChangesIntent: AppIntent {

    static var title: LocalizedStringResource = "Get Schedule Changes"
    static var description = IntentDescription(
        "Returns what changed in the last fetch: added and removed shifts. Run after 'Fetch My Schedule' to see what trades affected your schedule."
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[ShiftEntity]> {
        guard let diff = ShiftStore.shared.lastDiff else {
            return .result(
                value: [],
                dialog: IntentDialog(stringLiteral: "No changes recorded yet. Run Fetch first.")
            )
        }

        guard diff.hasChanges else {
            return .result(
                value: [],
                dialog: IntentDialog(stringLiteral: "No changes since last fetch.")
            )
        }

        // Return added shifts as the "action items" — these need new alarms
        let addedEntities = diff.added.filter { !$0.isOff }.map { $0.toEntity() }
        return .result(
            value: addedEntities,
            dialog: IntentDialog(stringLiteral: diff.summary)
        )
    }
}

// MARK: - Intent 5: Get shift for a specific date

struct GetShiftForDateIntent: AppIntent {

    static var title: LocalizedStringResource = "Get Shift for Date"
    static var description = IntentDescription(
        "Returns your shift on a specific date. Ask 'Do I work July 4th?' — pick the date in the Shortcuts editor."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Date", description: "The date to check.")
    var date: Date

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<ShiftEntity?> {
        let shift = ShiftStore.shared.shift(on: date)

        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        let dateStr = f.string(from: date)

        if let shift, !shift.isOff {
            return .result(
                value: shift.toEntity(),
                dialog: IntentDialog(stringLiteral: "You work \(shift.title) on \(dateStr).")
            )
        } else {
            return .result(
                value: nil,
                dialog: IntentDialog(stringLiteral: "You're off on \(dateStr).")
            )
        }
    }
}

// MARK: - Intent 6: Turn on shift alerts (notifications)

struct EnableShiftAlertsIntent: AppIntent {

    static var title: LocalizedStringResource = "Turn On Shift Alerts"
    static var description = IntentDescription(
        "Asks for notification permission and schedules a reminder before every upcoming shift, using your lead-time setting. For alarms, chain 'Get My Shifts' into the Shortcuts 'Set Alarm' action."
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let granted = await NotificationManager.shared.requestPermission()
        guard granted else {
            return .result(dialog: IntentDialog(stringLiteral:
                "Notifications aren't allowed yet. Enable them in Settings › BATMAN Watcher › Notifications, then run this again."))
        }
        let shifts = ShiftStore.shared.upcomingAllShifts()
        await NotificationManager.shared.scheduleAll(for: shifts)
        let count = shifts.filter { !$0.isOff }.count
        let lead  = SettingsManager.shared.notificationLeadHours
        return .result(dialog: IntentDialog(stringLiteral:
            "Shift alerts are on — scheduled \(count) reminders, \(lead)h before each shift."))
    }
}

// MARK: - Intent 7: Tomorrow's alarm time (returns a Date)

struct TomorrowAlarmTimeIntent: AppIntent {

    static var title: LocalizedStringResource = "Tomorrow's Shift Alarm Time"
    static var description = IntentDescription(
        "Returns the time to set an alarm for tomorrow's shift (start minus the hours you choose), or nothing if you're off. Plug the result straight into the Shortcuts 'Create Alarm' action."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Hours before start", default: 2)
    var hoursBefore: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Date?> & ProvidesDialog {
        guard let shift = ShiftStore.shared.tomorrowsShift else {
            return .result(value: nil, dialog: IntentDialog(stringLiteral: "You're off tomorrow — no alarm needed."))
        }
        let alarm = Calendar.current.date(byAdding: .hour, value: -hoursBefore, to: shift.startDate) ?? shift.startDate
        return .result(value: alarm, dialog: IntentDialog(stringLiteral:
            "Set an alarm \(hoursBefore)h before tomorrow's \(shift.title)."))
    }
}

// MARK: - App Shortcuts (auto-registered phrases)

struct BATMANReaderShortcuts: AppShortcutsProvider {

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {

        AppShortcut(
            intent: FetchScheduleIntent(),
            phrases: [
                "Fetch my schedule in \(.applicationName)",
                "Update my work schedule in \(.applicationName)"
            ],
            shortTitle: "Fetch Schedule",
            systemImageName: "arrow.clockwise.circle.fill"
        )

        AppShortcut(
            intent: GetTomorrowsShiftIntent(),
            phrases: [
                "Do I work tomorrow in \(.applicationName)",
                "What's my shift tomorrow in \(.applicationName)"
            ],
            shortTitle: "Tomorrow's Shift",
            systemImageName: "moon.stars.fill"
        )

        AppShortcut(
            intent: EnableShiftAlertsIntent(),
            phrases: [
                "Turn on shift alerts in \(.applicationName)",
                "Remind me before my shifts in \(.applicationName)"
            ],
            shortTitle: "Turn On Shift Alerts",
            systemImageName: "bell.badge.fill"
        )

        AppShortcut(
            intent: TomorrowAlarmTimeIntent(),
            phrases: [
                "Tomorrow's alarm time in \(.applicationName)",
                "When should I wake up for work in \(.applicationName)"
            ],
            shortTitle: "Tomorrow's Alarm Time",
            systemImageName: "alarm.fill"
        )

        AppShortcut(
            intent: GetShiftsIntent(),
            phrases: [
                "Get my shifts from \(.applicationName)"
            ],
            shortTitle: "Get My Shifts",
            systemImageName: "calendar.badge.clock"
        )

        AppShortcut(
            intent: GetAvailableDispatchersIntent(),
            phrases: [
                "Find dispatchers available in \(.applicationName)",
                "Who can trade with me in \(.applicationName)"
            ],
            shortTitle: "Find Trade Candidates",
            systemImageName: "person.2.badge.gearshape.fill"
        )

        AppShortcut(
            intent: GetScheduleChangesIntent(),
            phrases: [
                "What changed in my schedule in \(.applicationName)"
            ],
            shortTitle: "Schedule Changes",
            systemImageName: "calendar.badge.exclamationmark"
        )

        AppShortcut(
            intent: AIScheduleSummaryIntent(),
            phrases: [
                "Summarize my schedule in \(.applicationName)",
                "What does my week look like in \(.applicationName)"
            ],
            shortTitle: "AI Schedule Summary",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: AITradeBroadcastIntent(),
            phrases: [
                "Compose a trade broadcast in \(.applicationName)"
            ],
            shortTitle: "Draft Trade Broadcast",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
