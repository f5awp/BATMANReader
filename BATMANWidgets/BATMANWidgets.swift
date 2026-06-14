//
//  BATMANWidgets.swift
//  BATMANWidgets
//
//  Reads the shared schedule snapshot the app writes into the App Group.
//

import WidgetKit
import SwiftUI

// MARK: - Shared snapshot (must match the app's WidgetSnapshot exactly)

struct WidgetSnapshot: Codable {
    struct Day: Codable, Hashable { let iso: String; let letter: String }
    var nextType: String?
    var nextDesk: String?
    var nextDateText: String?
    var nextTimeText: String?
    var week: [Day]
    var pending: Int
    var updatedAt: Date
}

enum WidgetShared {
    static let suiteName = "group.com.ervinlee.batmanreader"
    static let key = "batman.widget.snapshot"
    static func read() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

// MARK: - Timeline

struct ScheduleEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct ScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleEntry { ScheduleEntry(date: Date(), snap: nil) }
    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        completion(ScheduleEntry(date: Date(), snap: WidgetShared.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        let entry = ScheduleEntry(date: Date(), snap: WidgetShared.read())
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

// MARK: - Next Shift / This Week widget

struct NextShiftView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ScheduleEntry

    private let accent = Color.accentColor

    var body: some View {
        switch family {
        case .systemMedium: medium
        default:            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEXT SHIFT").font(.caption2).foregroundStyle(.secondary)
            if let type = entry.snap?.nextType {
                HStack(spacing: 4) {
                    Text(type).font(.title2.bold())
                    if let desk = entry.snap?.nextDesk {
                        Text("Desk \(desk)").font(.subheadline.bold()).foregroundStyle(accent)
                    }
                }
                if let d = entry.snap?.nextDateText { Text(d).font(.subheadline) }
                if let t = entry.snap?.nextTimeText { Text(t).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("No upcoming shift").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("NEXT SHIFT").font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(entry.snap?.nextType ?? "—").font(.headline)
                        if let desk = entry.snap?.nextDesk {
                            Text("· Desk \(desk)").font(.subheadline.bold()).foregroundStyle(accent)
                        }
                    }
                    if let d = entry.snap?.nextDateText { Text(d).font(.caption).foregroundStyle(.secondary) }
                    if let t = entry.snap?.nextTimeText { Text(t).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                if let p = entry.snap?.pending, p > 0 {
                    Label("\(p)", systemImage: "tray.full.fill")
                        .font(.caption.bold()).foregroundStyle(accent)
                }
            }
            weekStrip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var weekStrip: some View {
        HStack(spacing: 3) {
            ForEach(entry.snap?.week ?? [], id: \.iso) { day in
                VStack(spacing: 1) {
                    Text(weekdayLetter(day.iso)).font(.system(size: 8)).foregroundStyle(.secondary)
                    Text(day.letter.isEmpty ? " " : day.letter).font(.system(size: 11, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(day.letter.isEmpty ? Color(.systemGray5) : accent.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private func weekdayLetter(_ iso: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return "" }
        switch Calendar.current.component(.weekday, from: d) {
        case 1: return "Su"; case 2: return "M"; case 3: return "T"; case 4: return "W"
        case 5: return "Th"; case 6: return "F"; default: return "Sa"
        }
    }
}

struct NextShiftWidget: Widget {
    let kind = "NextShiftWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleProvider()) { entry in
            NextShiftView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next Shift")
        .description("Your next shift and this week at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Pending trade requests widget

struct PendingTradesView: View {
    let entry: ScheduleEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("TRADE INBOX", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2).foregroundStyle(.secondary)
            Text("\(entry.snap?.pending ?? 0)").font(.system(size: 40, weight: .heavy))
            Text((entry.snap?.pending ?? 0) == 1 ? "pending request" : "pending requests")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PendingTradesWidget: Widget {
    let kind = "PendingTradesWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleProvider()) { entry in
            PendingTradesView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Trade Requests")
        .description("How many trade requests are waiting for your reply.")
        .supportedFamilies([.systemSmall])
    }
}
