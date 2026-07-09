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
import BackgroundTasks

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
            content.title       = "Shift today — \(shift.shiftShortLabel)"   // type + desk, e.g. "PM 32"
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

    // MARK: - Daily digest (once-a-day summary of what needs you)

    private let digestID = "batman.digest.daily"

    /// Schedule (or clear) the once-a-day summary at `hour`. The body reflects the counts known NOW and
    /// repeats daily; callers re-run this on launch so it stays reasonably current between opens. No
    /// server needed — a plain repeating local notification.
    func scheduleDailyDigest(enabled: Bool, hour: Int, pending: Int, unread: Int) async {
        center.removePendingNotificationRequests(withIdentifiers: [digestID])
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "BATMAN Watcher — daily check-in"
        content.body = Self.digestBody(pending: pending, unread: unread)
        content.sound = .default
        let total = pending + unread
        if total > 0 { content.badge = NSNumber(value: total) }
        var comps = DateComponents(); comps.hour = max(0, min(23, hour)); comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(identifier: digestID, content: content, trigger: trigger)
        do { try await center.add(request) } catch { print("⚠️ Could not schedule daily digest: \(error)") }
    }

    // MARK: - Live digest (BGTaskScheduler keeps the counts fresh)

    static let digestRefreshTaskID = "com.batmanwatcher.digestRefresh"

    /// Register the daily-digest background-refresh handler. MUST be called at launch (App.init) BEFORE
    /// the app finishes launching. When iOS runs it, we recompute counts and re-schedule the digest so its
    /// numbers are current at fire time (best-effort — iOS decides when to run it).
    func registerDigestRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.digestRefreshTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let work = Task { @MainActor in
                self.scheduleDigestRefresh()   // chain the next background run
                await MessagingStore.shared.refresh()
                let s = SettingsManager.shared
                let c = DashboardCounts.from(requests: MessagingStore.shared.requests,
                                             responses: MessagingStore.shared.responses,
                                             unread: MessagingStore.shared.pendingIncoming.count,
                                             pendingLedger: TradeHistoryStore.shared.pendingCount)
                await self.scheduleDailyDigest(enabled: s.dailyDigestEnabled, hour: s.dailyDigestHour,
                                               pending: c.pending, unread: c.unread)
                refresh.setTaskCompleted(success: true)
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    /// Ask iOS to run a background refresh shortly before the next digest hour (opportunistic).
    func scheduleDigestRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.digestRefreshTaskID)
        let hour = SettingsManager.shared.dailyDigestHour
        var comps = DateComponents(); comps.hour = max(0, min(23, hour)); comps.minute = 0
        // Next occurrence of the digest hour, minus an hour, so counts are fresh when it fires.
        if let next = Calendar.current.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime) {
            req.earliestBeginDate = next.addingTimeInterval(-3600)
        }
        try? BGTaskScheduler.shared.submit(req)
    }

    /// PURE, testable: the digest sentence for the given counts.
    static func digestBody(pending: Int, unread: Int) -> String {
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if pending > 0 { parts.append(plural(pending, "pending trade")) }
        if unread > 0  { parts.append(plural(unread, "unread message")) }
        if parts.isEmpty { return "Nothing needs you right now — tap to browse your matches." }
        return "You have " + parts.joined(separator: " and ") + ". Tap to review."
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
        // Colon-separated times ("13:00–22:00") so iOS doesn't mistake the bare digit run "1300–2200"
        // for a phone number ("1 (300) 220-0"). Also spell out the desk so the alert is self-explanatory.
        func hhmm(_ h: Int) -> String { String(format: "%02d:00", h) }
        var parts = ["\(hhmm(shift.startHour))–\(hhmm(shift.endHour))"]
        if !shift.desk.isEmpty { parts.append("Desk \(shift.desk)") }
        if let lc = shift.leaveCode, !lc.isEmpty { parts.append("Leave: \(lc)") }
        parts.append("starts in \(leadHours)h")
        return parts.joined(separator: " · ")
    }
}
