// ShiftSelectCalendar.swift
// A month-navigable, MULTI-select calendar for choosing the working shifts you
// want to trade away. Tap working days to toggle them into the selection; use the
// month arrows to reach any week of the year. Off/past days are disabled.

import SwiftUI

struct ShiftSelectCalendar: View {
    let shifts: [Shift]
    @Binding var selection: Set<String>

    @State private var monthAnchor = Calendar.current.startOfDay(for: Date())

    private var intents = DayIntentStore.shared   // show your marks so the picker isn't blank (C3)
    private let cal = Calendar.current
    private static let headers = ["Su", "M", "T", "W", "Th", "F", "Sa"]
    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let monthF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    private var byDay: [String: Shift] {
        Dictionary(shifts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Six weeks of days covering the anchor month (Sunday-aligned).
    private var gridDays: [Date] {
        guard let interval = cal.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let weekdayIndex = cal.component(.weekday, from: interval.start) - 1
        guard let start = cal.date(byAdding: .day, value: -weekdayIndex, to: interval.start) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        let days = gridDays
        VStack(spacing: 5) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").font(.headline) }
                Spacer()
                Text(Self.monthF.string(from: monthAnchor)).font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").font(.headline) }
            }
            .padding(.horizontal, 6)

            HStack(spacing: 3) {
                ForEach(Self.headers, id: \.self) { h in
                    Text(h).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { col in
                        cell(days[week * 7 + col])
                    }
                }
            }
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) { monthAnchor = d }
    }

    private func cell(_ date: Date) -> some View {
        let inMonth   = cal.isDate(date, equalTo: monthAnchor, toGranularity: .month)
        let shift     = byDay[Self.isoF.string(from: date)]
        let isWorking = shift.map { !$0.isOff } ?? false
        let today     = cal.startOfDay(for: Date())
        let isToday   = cal.isDate(date, inSameDayAs: today)
        let isPast    = date < today && !isToday
        let isSelected = shift.map { selection.contains($0.id) } ?? false

        return Button {
            if let s = shift, isWorking, !isPast {
                if selection.contains(s.id) { selection.remove(s.id) } else { selection.insert(s.id) }
            }
        } label: {
            VStack(spacing: 1) {
                ZStack {
                    if isToday { Circle().fill(Color.accentColor).frame(width: 24, height: 24) }
                    Text("\(cal.component(.day, from: date))")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isToday ? .white : .primary)
                }
                .frame(height: 24)
                Text(isWorking ? (shift?.shiftShortLabel ?? "") : "")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minHeight: 15)
                // Your working-intent color (trade-away / keep / …) so the picker shows context. C3
                if isWorking, let id = shift?.id, let w = intents.workingIntent(forDay: id) {
                    Capsule().fill(w.brickColor).frame(height: 3)
                } else {
                    Color.clear.frame(height: 3)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(background(isWorking: isWorking, isSelected: isSelected))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
            )
            .overlay(alignment: .topTrailing) {
                if let id = shift?.id, intents.note(forDay: id) != nil {
                    Circle().fill(BrickPalette.info).frame(width: 5, height: 5).padding(3)
                }
            }
            .opacity(inMonth ? (isPast ? 0.3 : 1) : 0.18)
        }
        .buttonStyle(.plain)
        .disabled(!isWorking || isPast || !inMonth)
    }

    // Working days are clearly tinted; off days are flat grey.
    private func background(isWorking: Bool, isSelected: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.85) }
        if isWorking  { return Color.accentColor.opacity(0.18) }
        return Color(.systemGray5)
    }
}
