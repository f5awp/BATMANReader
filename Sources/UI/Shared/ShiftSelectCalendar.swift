// ShiftSelectCalendar.swift
// A month-navigable, MULTI-select calendar for choosing the working shifts you
// want to trade away. Tap working days to toggle them into the selection; use the
// month arrows to reach any week of the year. Off/past days are disabled.

import SwiftUI

struct ShiftSelectCalendar: View {
    let shifts: [Shift]
    @Binding var selection: Set<String>

    @State private var monthAnchor = Calendar.current.startOfDay(for: Date())

    private let cal = Calendar.current
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// Pinned type size (1:1 grid) but a step larger on iPad so date/shift/desk scale up proportionally.
    private var calTypeSize: DynamicTypeSize { hSizeClass == .regular ? .xLarge : .large }
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

            HStack(spacing: DXSpace.cellGap) {
                ForEach(Self.headers, id: \.self) { h in
                    Text(h).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: DXSpace.cellGap) {
                    ForEach(0..<7, id: \.self) { col in
                        cell(days[week * 7 + col])
                    }
                }
            }
        }
        // Match IntentCalendarView: pinned type size (larger on iPad) so the grid renders like Home.
        .dynamicTypeSize(calTypeSize)
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
                    Text("\(cal.component(.day, from: date))")
                        .font(isToday ? DXFont.dayNumber.weight(.heavy) : DXFont.dayNumber)
                        .foregroundStyle(textColor(isWorking: isWorking, isSelected: isSelected))
                }
                .frame(height: DXSpace.cellNumberH)
                // Shift TYPE + desk as two muted labels — same treatment as Home's `dayContent`
                // (white·0.9 on the accent pick, muted primary·0.7 on the navy worked tile).
                Group {
                    if isWorking, let shift {
                        HStack(spacing: 3) {
                            Text(shift.shiftTypeLabel)
                            if !shift.desk.isEmpty { Text(shift.desk) }
                        }
                        .font(DXFont.dayNote)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.primary.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    } else {
                        Color.clear   // reserve the label row so EVERY cell is the same height (matches Home)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: DXSpace.cellLabelH)   // fixed → uniform cell size
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DXSpace.cellVPad)
            // §2: ONE glazed ceramic cell everywhere (matches Home) — no flat gray boxes. Working =
            // Home's navy `cellWorked`, selected = accent, off/greyed = Home's slate `cellOff`; disabled
            // days are DIMMED (opacity below), not flattened. Same radius (7) + grout as Home.
            .background {
                RoundedRectangle(cornerRadius: DXSpace.cellRadius, style: .continuous)
                    .fill(ceramicFill(tileColor(isWorking: isWorking, isSelected: isSelected)))
                    .dxGlaze(radius: DXSpace.cellRadius)
            }
            .clipShape(RoundedRectangle(cornerRadius: DXSpace.cellRadius))
            .shadow(color: AppColor.tileShadow, radius: 1.5, x: 0, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: DXSpace.cellRadius)
                    // selected = thick accent ring; plain "today" = 2pt inset ring (matches Home).
                    .strokeBorder(isSelected ? Color.accentColor : (isToday ? Color.accentColor : .clear),
                                  lineWidth: isSelected ? 2.5 : (isToday ? 2 : 0))
            )
            // No persistent intent pill — Home only flashes it on tap, so the picker shows selection via
            // the accent tile + ring instead (the "TRADE/KEEP texts all over" were from this overlay).
            // Selectable days full-strength; off/past greyed but still the same glazed tile; out-of-month dimmest.
            .opacity(!inMonth ? 0.18 : (isPast ? 0.3 : ((isWorking || isSelected) ? 1 : 0.55)))
        }
        .buttonStyle(.plain)
        .disabled(!isWorking || isPast || !inMonth)
    }

    /// The ceramic base color per state — Home's exact tokens so the two calendars read identically:
    /// selected = accent, selectable working = navy `cellWorked`, off/greyed = slate `cellOff`.
    private func tileColor(isWorking: Bool, isSelected: Bool) -> Color {
        if isSelected { return Color.accentColor }
        if isWorking  { return AppColor.cellWorked }
        return AppColor.cellOff
    }

    /// Number/label color, matching Home: white on the accent pick, adaptive `.primary` on the navy tile
    /// (`cellWorked` is light-in-light / dark-in-dark), dim `cellOffText` on the slate off tile.
    private func textColor(isWorking: Bool, isSelected: Bool) -> Color {
        if isSelected { return .white }
        if isWorking  { return .primary }
        return AppColor.cellOffText
    }
}
