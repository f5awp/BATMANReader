// ScheduleStripView.swift
// The Schedule tab's continuous, vertically-scrolling month calendar.

import SwiftUI

// MARK: - Continuous scrolling calendar

/// A vertically-scrolling, read-only calendar of the user's own schedule — one
/// month grid per section, from the current month through the last loaded shift.
/// Replaces the two-week strip + upcoming list on the Schedule tab.
struct ScheduleCalendarView: View {
    let shifts: [Shift]

    private let cal = Calendar.current
    private static let headers = ["Su", "M", "T", "W", "Th", "F", "Sa"]
    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let monthF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    private var byDay: [String: Shift] {
        Dictionary(shifts.map { (Self.isoF.string(from: $0.date), $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// First-of-month dates from the current month through the last shift's month.
    private var months: [Date] {
        let today = cal.startOfDay(for: Date())
        guard let startMonth = cal.dateInterval(of: .month, for: today)?.start else { return [] }
        let lastDate = shifts.map { $0.date }.max() ?? today
        let endMonth = cal.dateInterval(of: .month, for: lastDate)?.start ?? startMonth
        var result: [Date] = []
        var m = startMonth
        while m <= endMonth {
            result.append(m)
            guard let next = cal.date(byAdding: .month, value: 1, to: m) else { break }
            m = next
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                ForEach(months, id: \.self) { month in
                    Section {
                        monthGrid(month)
                    } header: {
                        Text(Self.monthF.string(from: month))
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .background(.bar)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func monthGrid(_ month: Date) -> some View {
        let days = gridDays(month)
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(Self.headers, id: \.self) { h in
                    Text(h).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<(days.count / 7), id: \.self) { week in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { col in
                        cell(days[week * 7 + col], month: month)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    /// Six Sunday-aligned weeks covering `month`.
    private func gridDays(_ month: Date) -> [Date] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let weekdayIndex = cal.component(.weekday, from: interval.start) - 1
        guard let start = cal.date(byAdding: .day, value: -weekdayIndex, to: interval.start) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private func cell(_ date: Date, month: Date) -> some View {
        let inMonth   = cal.isDate(date, equalTo: month, toGranularity: .month)
        let shift     = byDay[Self.isoF.string(from: date)]
        let isWorking = shift.map { !$0.isOff } ?? false
        let today     = cal.startOfDay(for: Date())
        let isToday   = cal.isDate(date, inSameDayAs: today)
        let isPast    = date < today && !isToday

        return VStack(spacing: 2) {
            Text("\(cal.component(.day, from: date))")
                .font(.system(size: isToday ? 16 : 13, weight: isToday ? .black : .medium))
            Text(isWorking ? (shift?.shiftShortLabel ?? "") : "")
                .font(.system(size: isToday ? 14 : 12, weight: .heavy))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(minHeight: 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isToday ? 10 : 8)
        .background(todayOrShiftBackground(isToday: isToday, isWorking: isWorking))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isToday ? Color.orange : .clear, lineWidth: 2)
        )
        .opacity(inMonth ? (isPast ? 0.4 : 1) : 0.12)
    }

    private func todayOrShiftBackground(isToday: Bool, isWorking: Bool) -> Color {
        if isToday { return Color.yellow.opacity(0.55) }
        return isWorking ? Color.accentColor.opacity(0.16) : Color(.systemGray5)
    }
}
