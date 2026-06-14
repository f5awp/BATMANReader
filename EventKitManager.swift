// EventKitManager.swift
// Manages TWO calendars:
//
//  1. "AA Schedule" (personal, private)
//     Your own shifts — start/end times, role, desk.
//     Only you can see this. Never shared.
//
//  2. "AA Dispatch" (shared, group-visible)
//     Your OFF days only, tagged with your display name.
//     e.g. "Lee, Ervin — Available" on June 14.
//     Every dispatcher who joined the shared calendar can see
//     who is off and therefore potentially available to trade.
//     No shift details are ever written here — only availability.
//
// ── Shared calendar setup (done once by the group coordinator) ────────
// 1. Open Calendar.app → File → New Calendar (iCloud)
//    Name it "AA Dispatch"
// 2. Right-click → Share Calendar → Copy Link
// 3. Send link to all dispatchers. They accept the invite.
// 4. Each dispatcher opens BATMANReader Settings → Shared Calendar,
//    taps "Select Calendar" to pick "AA Dispatch" from the list.
// 5. From that point BATMANReader writes their off days automatically.
//
// ── Xcode: required Info.plist key ───────────────────────────────────
// NSCalendarsFullAccessUsageDescription
// Value: "BATMANReader adds work shifts to your calendar and marks
//         your off days on the shared dispatcher availability calendar."
// ─────────────────────────────────────────────────────────────────────

import EventKit
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
final class EventKitManager {

    static let shared = EventKitManager()

    private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    private(set) var personalCalendarName: String = "AA Schedule"
    private(set) var availableCalendars: [EKCalendar] = []

    private let ekStore = EKEventStore()

    // shift.id → EKEvent.eventIdentifier for personal calendar
    private var personalEventIDMap: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "batman.personalEventIDs") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "batman.personalEventIDs") }
    }

    // shift.id → EKEvent.eventIdentifier for shared calendar (off days)
    private var sharedEventIDMap: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "batman.sharedEventIDs") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "batman.sharedEventIDs") }
    }

    private var savedPersonalCalendarID: String? {
        get { UserDefaults.standard.string(forKey: "batman.personalCalID") }
        set { UserDefaults.standard.set(newValue, forKey: "batman.personalCalID") }
    }

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Permission

    @discardableResult
    func requestPermission() async -> Bool {
        do {
            let granted = try await ekStore.requestFullAccessToEvents()
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            if granted { refreshAvailableCalendars() }
            return granted
        } catch {
            print("⚠️ EventKit permission error: \(error)")
            return false
        }
    }

    var isAuthorized: Bool { authorizationStatus == .fullAccess }

    // MARK: - Calendar list (for Settings picker)

    /// Refreshes the list of iCloud/CalDAV calendars the user has access to.
    /// Call after permission is granted so SettingsView can show a picker.
    func refreshAvailableCalendars() {
        availableCalendars = ekStore.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .sorted { $0.title < $1.title }
    }

    // MARK: - Personal calendar

    private func personalCalendar() -> EKCalendar? {
        if let id = savedPersonalCalendarID,
           let cal = ekStore.calendar(withIdentifier: id) {
            return cal
        }

        let cal = EKCalendar(for: .event, eventStore: ekStore)
        cal.title = "AA Schedule"
        guard let source = preferredSource() else { return nil }
        cal.source  = source
        #if canImport(UIKit)
            cal.cgColor = UIColor.systemBlue.cgColor
        #elseif canImport(AppKit)
            cal.cgColor = NSColor.systemBlue.cgColor
        #else
            cal.cgColor = CGColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1.0) // fallback blue
        #endif
        do {
            try ekStore.saveCalendar(cal, commit: true)
            savedPersonalCalendarID = cal.calendarIdentifier
            personalCalendarName    = cal.title
            refreshAvailableCalendars()
            return cal
        } catch {
            print("❌ EventKit: could not create personal calendar: \(error)")
            return nil
        }
    }

    // MARK: - Shared calendar

    private func sharedCalendar() -> EKCalendar? {
        let settings = SettingsManager.shared
        guard settings.sharedCalendarEnabled,
              !settings.sharedCalendarIdentifier.isEmpty else { return nil }
        return ekStore.calendar(withIdentifier: settings.sharedCalendarIdentifier)
    }

    // MARK: - Public sync API

    /// Called by ShiftStore after every fetch.
    /// Personal calendar: sync working shifts (add/remove via diff)
    /// Shared calendar: sync off days (add/remove via diff)
    func sync(diff: ScheduleDiff) {
        guard isAuthorized else { return }

        // ── Personal calendar (your shifts) ──────────────────────────
        let shiftsToRemove = diff.removed + diff.changed.map { $0.old }
        let shiftsToAdd    = (diff.added + diff.changed.map { $0.new }).filter { !$0.isOff }
        removePersonalEvents(for: shiftsToRemove)
        addPersonalEvents(for: shiftsToAdd)

        // ── Shared calendar (your off days for group visibility) ──────
        if SettingsManager.shared.sharedCalendarEnabled {
            let offDaysToRemove = diff.removed.filter { $0.isOff }
                                + diff.changed.filter { $0.old.isOff }.map { $0.old }
            let offDaysToAdd    = diff.added.filter { $0.isOff }
                                + diff.changed.filter { $0.new.isOff }.map { $0.new }
            removeSharedEvents(for: offDaysToRemove)
            addSharedAvailabilityEvents(for: offDaysToAdd)
        }

        if diff.hasChanges {
            print("✅ EventKit synced: \(diff.summary)")
        }
    }

    func removeAllEvents() {
        guard isAuthorized else { return }
        removeAllPersonalEvents()
        removeAllSharedEvents()
        print("✅ EventKit: all events removed.")
    }

    /// Ensures every working shift has a personal calendar event, re-adding any
    /// that are missing — e.g. after "Clear calendar events" or events deleted
    /// externally, where the diff-based sync wouldn't notice. Idempotent.
    /// Returns the number of events re-added.
    @discardableResult
    func resyncPersonalEvents(for shifts: [Shift]) -> Int {
        guard isAuthorized else { return 0 }
        let map = personalEventIDMap
        let missing = shifts.filter { shift in
            guard !shift.isOff else { return false }
            guard let eid = map[shift.id] else { return true }   // not tracked → add
            return ekStore.event(withIdentifier: eid) == nil      // tracked but event gone → re-add
        }
        addPersonalEvents(for: missing)
        return missing.count
    }

    // MARK: - Personal calendar events

    private func addPersonalEvents(for shifts: [Shift]) {
        guard let cal = personalCalendar() else { return }
        var map       = personalEventIDMap
        let leadHours = SettingsManager.shared.notificationLeadHours

        for shift in shifts {
            let event       = EKEvent(eventStore: ekStore)
            event.calendar  = cal
            event.title     = shift.title
            event.startDate = shift.startDate
            event.endDate   = shift.endDate
            event.notes     = buildPersonalNotes(for: shift)
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-leadHours * 3600)))
            do {
                try ekStore.save(event, span: .thisEvent, commit: false)
                map[shift.id] = event.eventIdentifier
            } catch {
                print("⚠️ EventKit: personal event save failed for \(shift.id): \(error)")
            }
        }
        try? ekStore.commit()
        personalEventIDMap = map
    }

    private func removePersonalEvents(for shifts: [Shift]) {
        var map = personalEventIDMap
        for shift in shifts {
            if let eid = map[shift.id], let event = ekStore.event(withIdentifier: eid) {
                try? ekStore.remove(event, span: .thisEvent, commit: false)
            }
            map.removeValue(forKey: shift.id)
        }
        try? ekStore.commit()
        personalEventIDMap = map
    }

    private func removeAllPersonalEvents() {
        var map = personalEventIDMap
        for (shiftID, eid) in map {
            if let event = ekStore.event(withIdentifier: eid) {
                try? ekStore.remove(event, span: .thisEvent, commit: false)
            }
            map.removeValue(forKey: shiftID)
        }
        try? ekStore.commit()
        personalEventIDMap = map
    }

    // MARK: - Shared calendar (availability / off days)

    private func addSharedAvailabilityEvents(for offDays: [Shift]) {
        guard let cal = sharedCalendar() else { return }
        let name = SettingsManager.shared.displayName.isEmpty
            ? SettingsManager.shared.username
            : SettingsManager.shared.displayName
        var map = sharedEventIDMap

        for offDay in offDays {
            let event        = EKEvent(eventStore: ekStore)
            event.calendar   = cal
            event.title      = "\(name) — Available"
            event.isAllDay   = true
            event.startDate  = offDay.date
            event.endDate    = offDay.date
            event.notes      = "Marked available by BATMANReader"
            do {
                try ekStore.save(event, span: .thisEvent, commit: false)
                map[offDay.id] = event.eventIdentifier
            } catch {
                print("⚠️ EventKit: shared event save failed for \(offDay.id): \(error)")
            }
        }
        try? ekStore.commit()
        sharedEventIDMap = map
    }

    private func removeSharedEvents(for shifts: [Shift]) {
        var map = sharedEventIDMap
        for shift in shifts {
            if let eid = map[shift.id], let event = ekStore.event(withIdentifier: eid) {
                try? ekStore.remove(event, span: .thisEvent, commit: false)
            }
            map.removeValue(forKey: shift.id)
        }
        try? ekStore.commit()
        sharedEventIDMap = map
    }

    private func removeAllSharedEvents() {
        var map = sharedEventIDMap
        for (shiftID, eid) in map {
            if let event = ekStore.event(withIdentifier: eid) {
                try? ekStore.remove(event, span: .thisEvent, commit: false)
            }
            map.removeValue(forKey: shiftID)
        }
        try? ekStore.commit()
        sharedEventIDMap = map
    }

    // MARK: - Helpers

    private func preferredSource() -> EKSource? {
        ekStore.sources.first(where: {
            $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud")
        }) ??
        ekStore.sources.first(where: { $0.sourceType == .local }) ??
        ekStore.defaultCalendarForNewEvents?.source
    }

    private func buildPersonalNotes(for shift: Shift) -> String {
        var lines = [
            "Role: \(shift.role.rawValue)",
            "Desk: \(shift.desk.isEmpty ? "TBD" : shift.desk)",
            "\(shift.startTimeString)–\(shift.endTimeString)"
        ]
        if let lc = shift.leaveCode, !lc.isEmpty { lines.append("Leave: \(lc)") }
        lines.append("Added by BATMANReader")
        return lines.joined(separator: "\n")
    }
}
