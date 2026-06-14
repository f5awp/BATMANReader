// NotificationManager.swift
// Schedules a local notification before each working shift.
// The lead time (hours before shift start) is set in SettingsManager.
//
// Notifications fire on the same day as the shift, lead-time hours before
// the start (e.g. 2h before 0500 = 0300 notification).
// If lead time pushes the notification to the previous calendar day, that
// is expected and correct — it becomes an "eve of shift" alert.

import UserNotifications
import Foundation

final class NotificationManager {

    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()

    // Notification identifiers are prefixed so we can batch-remove them
    // without touching notifications from other apps.
    private let idPrefix = "batman.shift."

    private init() {}

    // MARK: - Permission

    @discardableResult
    func requestPermission() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("⚠️ Notification permission error: \(error)")
            return false
        }
    }

    // MARK: - Schedule

    /// Cancels all existing shift notifications and re-schedules them
    /// for every non-OFF shift in the list. Call after each fetch.
    func scheduleAll(for shifts: [Shift]) async {
        // Remove all previous shift notifications
        await removeAllShiftNotifications()

        let leadHours = SettingsManager.shared.notificationLeadHours
        let now = Date()

        for shift in shifts where !shift.isOff {
            guard let fireDate = Calendar.current.date(
                byAdding: .hour,
                value: -leadHours,
                to: shift.startDate
            ), fireDate > now else { continue }

            let content         = UNMutableNotificationContent()
            content.title       = "Shift today — \(shift.title)"
            content.body        = makeBody(for: shift, leadHours: leadHours)
            content.sound       = .default
            content.userInfo    = ["shiftID": shift.id, "isoDate": shift.isoDate]

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: idPrefix + shift.id,
                content: content,
                trigger: trigger
            )

            do {
                try await center.add(request)
            } catch {
                print("⚠️ Could not schedule notification for shift \(shift.id): \(error)")
            }
        }

        let count = shifts.filter { !$0.isOff }.count
        print("✅ NotificationManager: scheduled \(count) shift notifications (\(leadHours)h lead).")
    }

    // MARK: - Cancel

    func removeAllShiftNotifications() async {
        let pending = await center.pendingNotificationRequests()
        let toRemove = pending
            .filter { $0.identifier.hasPrefix(idPrefix) }
            .map    { $0.identifier }
        center.removePendingNotificationRequests(withIdentifiers: toRemove)
    }

    // MARK: - Helpers

    private func makeBody(for shift: Shift, leadHours: Int) -> String {
        var lines = ["\(shift.startTimeString)–\(shift.endTimeString)"]
        if let lc = shift.leaveCode, !lc.isEmpty {
            lines.append("Leave: \(lc)")
        }
        lines.append("Starting in \(leadHours)h.")
        return lines.joined(separator: " · ")
    }
}
