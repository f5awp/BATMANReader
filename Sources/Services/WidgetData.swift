// WidgetData.swift
// Writes a tiny schedule snapshot into the shared App Group so the widget
// extension (a separate process) can render without touching the app's stores.
// Call `WidgetData.update()` after any schedule/messaging change.

import Foundation
import WidgetKit

/// Shared shape — kept byte-for-byte identical in the widget target (separate
/// module, so it's duplicated rather than shared-compiled).
struct WidgetSnapshot: Codable {
    struct Day: Codable, Hashable { let iso: String; let letter: String }  // "A"/"P"/"M" or "" off
    var nextType: String?       // "AM"/"PM"/"MID"
    var nextDesk: String?       // "82" (nil when none)
    var nextDateText: String?   // "Fri, Jun 13"
    var nextTimeText: String?   // "0500–1400"
    var week: [Day]             // 7 days starting today
    var pending: Int            // pending incoming trade requests
    var updatedAt: Date
}

@MainActor
enum WidgetData {
    static let suiteName = "group.com.ervinlee.batmanreader"
    static let key = "batman.widget.snapshot"

    static func update() {
        let store = ShiftStore.shared
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd"
        var byDay: [String: Shift] = [:]
        for s in store.shifts { byDay[s.id] = s }

        var week: [WidgetSnapshot.Day] = []
        for offset in 0..<7 {
            let d = cal.date(byAdding: .day, value: offset, to: today) ?? today
            let dayKey = iso.string(from: d)
            let letter = byDay[dayKey].map { $0.isOff ? "" : $0.shiftLetter } ?? ""
            week.append(.init(iso: dayKey, letter: letter))
        }

        let next = store.upcomingWorkingShifts().first
        let snap = WidgetSnapshot(
            nextType:     next.map { ShiftAvailabilityType.infer(fromStartHour: $0.startHour).rawValue },
            nextDesk:     next.flatMap { $0.desk.isEmpty ? nil : $0.desk },
            nextDateText: next?.weekdayDate,
            nextTimeText: next.map { "\($0.startTimeString)–\($0.endTimeString)" },
            week:         week,
            pending:      MessagingStore.shared.pendingIncoming.count,
            updatedAt:    Date())

        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults(suiteName: suiteName)?.set(data, forKey: key)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
