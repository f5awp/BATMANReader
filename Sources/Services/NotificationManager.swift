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
        // Fold in unwatched radar matches + trades that went invalid so everything surfaces daily
        // (delivery is on-open until push lands).
        let (matches, invalid) = await MainActor.run {
            (MatchStore.shared.unwatchedOpportunityCount, MessagingStore.shared.actionableInvalidCount)
        }
        let content = UNMutableNotificationContent()
        content.title = "\(AppGuide.appName) — daily check-in"
        content.body = Self.digestBody(pending: pending, unread: unread, matches: matches, invalid: invalid)
        content.sound = .default
        let total = pending + unread + matches + invalid
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
                // Refresh the radar so the digest's unwatched-match count is current — and give watched-day
                // alerts a chance to fire from the background (best-effort, when iOS grants the slot).
                await MatchStore.shared.recompute()
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
    static func digestBody(pending: Int, unread: Int, matches: Int = 0, invalid: Int = 0) -> String {
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if pending > 0 { parts.append(plural(pending, "pending trade")) }
        if unread > 0  { parts.append(plural(unread, "unread message")) }
        if matches > 0 { parts.append("\(matches) trade match\(matches == 1 ? "" : "es") you haven't watched") }
        if invalid > 0 { parts.append("\(plural(invalid, "trade")) to fix (a day changed)") }
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

    // MARK: - Match Radar (new-pickup alerts)

    private let radarPrefix = "batman.radar."

    /// Alert for days that just gained an opportunity, BOTH directions:
    ///   • pickups — an OFF day where a shift you can pick up appeared.
    ///   • takers  — a WORKING day where someone who'd take your shift appeared.
    /// Each WATCHED day gets its own immediate alert; the rest collapse into one batched summary per
    /// direction so the user isn't spammed. No-op if nothing gained or notifications aren't authorized.
    func notifyRadar(gainedPickups: Set<String>, gainedTakers: Set<String>, watched: Set<String>) async {
        guard !gainedPickups.isEmpty || !gainedTakers.isEmpty else { return }
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        // One alert PER day so each names its exact date and deep-links to that date's Trade List. `dayID`
        // rides in userInfo; the tap handler (RadarNotificationRouter) routes to the day.
        func fire(id: String, body: String, day: String) async {
            let content = UNMutableNotificationContent()
            content.title = AppGuide.appName; content.body = body; content.sound = .default
            content.userInfo = [Self.radarDayKey: day]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }

        // Alerts fire only for WATCHED days (Watch Day = "notify me about this day"); unwatched
        // opportunities stay visible silently via the calendar star.
        // OFF day (you want to work it) — someone is looking to drop that day.
        for day in gainedPickups.intersection(watched).sorted() {
            await fire(id: radarPrefix + "pickup." + day,
                       body: "Someone is looking to drop \(Self.prettyDay(day)) you want to work!", day: day)
        }
        // WORKING day (you want to trade it) — someone is looking to work that day.
        for day in gainedTakers.intersection(watched).sorted() {
            await fire(id: radarPrefix + "taker." + day,
                       body: "Someone is looking to work on \(Self.prettyDay(day)) you want to trade!", day: day)
        }
    }

    /// userInfo key carrying the ISO day a radar alert refers to (drives notification-tap deep-linking).
    static let radarDayKey = "batman.radar.dayID"
    static let radarIDPrefix = "batman.radar."

    /// Alert when a trade YOU'RE in just went invalid (a traded day changed on the roster — usually because
    /// that day got traded elsewhere). Fired per device, so the giver and the taker each get their own.
    func notifyTradesInvalid(_ items: [(peer: String, day: String)]) async {
        guard !items.isEmpty else { return }
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = "A trade is no longer valid"
            content.body = "Your trade with \(item.peer) for \(Self.prettyDay(item.day)) can't go through — that day changed. Pick another day, counter, or remove it."
            content.sound = .default
            content.userInfo = [Self.radarDayKey: item.day]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.radarIDPrefix + "invalid." + item.day + "." + item.peer,
                                                        content: content, trigger: trigger))
        }
    }

    /// A newly-formed mutual match — fired on BOTH parties' devices (each detects it independently), so both
    /// sides learn of the match, watched or not. Deep-links to the first involved day's Trade List.
    func notifyMutualMatch(_ items: [(peer: String, dayID: String, dayLabel: String)]) async {
        guard !items.isEmpty else { return }
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = AppGuide.appName
            content.body = "Match found for \(item.dayLabel)"
            content.sound = .default
            content.userInfo = [Self.radarDayKey: item.dayID]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.radarIDPrefix + "mutual." + item.peer + "." + item.dayID,
                                                        content: content, trigger: trigger))
        }
    }

    /// One newly-fillable standing offer. `sentCount`: 0 = heads-up only (owner proposes manually); 1 = auto-
    /// sent to one peer; >1 = auto-broadcast to N peers (first to accept wins).
    struct StandingAlert: Sendable { let getDayID: String; let giveDayID: String; let peer: String; let sentCount: Int }

    /// Alert when a STANDING OFFER becomes fillable. One per offer, naming both dates; taps deep-link to the
    /// get-day's Trade List (reuses the radar router).
    func notifyStanding(_ items: [StandingAlert]) async {
        guard !items.isEmpty else { return }
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        for item in items {
            let content = UNMutableNotificationContent()
            let days = "give \(Self.prettyDay(item.giveDayID)), get \(Self.prettyDay(item.getDayID))"
            switch item.sentCount {
            case 0:
                content.title = "Your standing offer can be filled"
                content.body = "Give \(Self.prettyDay(item.giveDayID)), get \(Self.prettyDay(item.getDayID)) with \(item.peer)."
            case 1:
                content.title = "Standing offer sent"
                content.body = "Auto-sent to \(item.peer) — \(days)."
            default:
                content.title = "Standing offer sent"
                content.body = "Auto-sent to \(item.sentCount) coworkers — first to accept wins (\(days))."
            }
            content.sound = .default
            content.userInfo = [Self.radarDayKey: item.getDayID]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.radarIDPrefix + "standing." + item.getDayID + "." + item.giveDayID,
                                                        content: content, trigger: trigger))
        }
    }

    static func prettyDay(_ id: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: id) else { return id }
        let out = DateFormatter(); out.dateFormat = "EEE, MMM d"; return out.string(from: d)
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

/// Routes radar notifications: shows their banner even in the foreground (they fire ~1s after an in-app
/// recompute), and on tap deep-links to the day's Trade List via `MatchStore.pendingDayID`. Non-radar
/// notifications keep the system default. Set as `UNUserNotificationCenter.delegate` at launch.
final class RadarNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RadarNotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix(NotificationManager.radarIDPrefix) ? [.banner, .sound, .list] : []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let day = response.notification.request.content.userInfo[NotificationManager.radarDayKey] as? String
        else { return }
        await MainActor.run { MatchStore.shared.pendingDayID = day }
    }
}
