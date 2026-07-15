// HomeCalendar.swift
// The interactive intent calendar + per-day editor + Trade Settings sheet used by
// HomeView. The grid layout descends from ScheduleCalendarView; cells add tap /
// long-press and draw intent overlays from DayIntentStore.

import SwiftUI

// MARK: - Off-day legality

/// Which shift types you could LEGALLY pick up on an off day, given the 8-hour
/// rest rule versus the shifts you work on the adjacent days.
enum Legality {
    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// Legal pickup types for an off day. Delegates to the SINGLE source of truth
    /// (`AvailabilityManager.eligibleTypes`) so the calendar, the want-to-work gate, and the
    /// tests can never diverge (was a duplicate rest-rule implementation — the meta-seam bug).
    static func legalTypes(forDayID dayID: String, shifts: [Shift]) -> Set<ShiftAvailabilityType> {
        guard let day = isoF.date(from: dayID) else { return [] }
        return AvailabilityManager.eligibleTypes(forOffDay: day, workedShifts: shifts.filter { !$0.isOff })
    }
}

// MARK: - Tappable, color-coded note marker

/// A note icon on a calendar day — blue = public, orange = private — that shows
/// the note text in a popover when tapped.
struct NoteMarker: View {
    let note: DayNote
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: note.isPrivate ? "lock.doc.fill" : "note.text")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(note.isPrivate ? BrickPalette.warning : BrickPalette.info)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: note.isPrivate ? "lock.fill" : "globe")
                    Text(note.isPrivate ? "Private note" : "Public note").font(.caption.bold())
                }
                .foregroundStyle(note.isPrivate ? BrickPalette.warning : BrickPalette.info)
                Text(note.message).font(.subheadline)
                if let r = note.reason {
                    Text("Reason: \(r.label)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(minWidth: 180)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// A tappable event marker (holiday / milestone) showing the event name in a popover.
struct EventMarker: View {
    let name: String
    let color: Color
    let icon: String
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 6) {
                Label(name, systemImage: icon).font(.subheadline.bold()).foregroundStyle(color)
                Text("High-demand date").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14).frame(minWidth: 180)
            .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Interactive month calendar with intent overlays

struct IntentCalendarView: View {
    let shifts: [Shift]
    let mode: IntentMode
    let layers: LayerVisibility
    let flashDays: Set<String>
    let continuous: Bool          // false = paged month view (default); true = continuous week stream
    let onTap: (_ dayID: String, _ isOff: Bool) -> Void
    let onLongPress: (_ dayID: String, _ isOff: Bool) -> Void

    private var intents = DayIntentStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// Pinned type size so the grid renders 1:1 — but a step LARGER on iPad (regular width) so the
    /// date/shift/desk text scales up proportionally on the bigger canvas.
    private var calTypeSize: DynamicTypeSize { hSizeClass == .regular ? .xLarge : .large }
    @State private var infoDay: String?
    @State private var tappedDay: String?   // intent pill flashes only for the day you just tapped
    // Continuous-calendar month indicator (Tier 2): the month currently at the top of the scroll,
    // shown in a floating capsule that flashes in as you scroll into a new month, then fades.
    @State private var expandedMonths: Set<Date> = []   // continuous view: which month tabs are popped open
    private let cal = Calendar.current
    private static let headers = ["Su", "M", "T", "W", "Th", "F", "Sa"]
    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let monthF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    private static let monthAbbrevF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f   // "AUG" for the continuous month tab
    }()

    init(shifts: [Shift], mode: IntentMode, layers: LayerVisibility, flashDays: Set<String>,
         continuous: Bool = false,
         onTap: @escaping (String, Bool) -> Void, onLongPress: @escaping (String, Bool) -> Void) {
        self.shifts = shifts; self.mode = mode; self.layers = layers
        self.flashDays = flashDays; self.continuous = continuous
        self.onTap = onTap; self.onLongPress = onLongPress
    }

    private var byDay: [String: Shift] {
        Dictionary(shifts.map { (Self.isoF.string(from: $0.date), $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        Group {
            if continuous { continuousBody } else { pagedBody }
        }
        // Auto-dismiss the tapped-day intent pill after a moment.
        .task(id: tappedDay) {
            guard tappedDay != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.3)) { tappedDay = nil }
        }
    }

    // MARK: Paged month view (DEFAULT) — one grid per month, pinned header + stats, no grayed days.

    private var pagedBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                ForEach(months, id: \.self) { month in
                    Section { monthGrid(month) } header: { monthHeader(month) }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private var months: [Date] {
        let today = cal.startOfDay(for: Date())
        guard let startMonth = cal.dateInterval(of: .month, for: today)?.start else { return [] }
        let lastDate = shifts.map { $0.date }.max() ?? today
        let endMonth = cal.dateInterval(of: .month, for: lastDate)?.start ?? startMonth
        var result: [Date] = []; var m = startMonth
        while m <= endMonth {
            result.append(m)
            guard let next = cal.date(byAdding: .month, value: 1, to: m) else { break }
            m = next
        }
        return result
    }

    /// Pinned month header: the month title + the per-month stats (on / off + each marked intent).
    private func monthHeader(_ month: Date) -> some View {
        let s = monthStats(for: month)
        return VStack(alignment: .leading, spacing: 6) {
            Text(Self.monthF.string(from: month)).font(DXFont.heading(25))   // §8: Archivo ~25
            FlowLayout(spacing: 9) {
                statDot(AppColor.primary,  "\(s.on) on")
                statDot(AppColor.neutral,  s.vacation > 0 ? "\(s.off) off (\(s.vacation) vac)" : "\(s.off) off")
                if s.tradeAway  > 0 { statDot(AppColor.special, "\(s.tradeAway) trade") }
                if s.keep       > 0 { statDot(AppColor.keep,    "\(s.keep) keep") }
                if s.blackout   > 0 { statDot(AppColor.locked,  "\(s.blackout) blackout") }
                if s.wantToWork > 0 { statDot(AppColor.pending, "\(s.wantToWork) work") }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DXSpace.screenH)
        .padding(.top, 12).padding(.bottom, 8)
        .background(Color(.systemBackground))   // opaque so pinned scrolling occludes the rows
    }

    private func monthGrid(_ month: Date, showWeekdayHeader: Bool = true) -> some View {
        let days = gridDays(month)
        let weekRows = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        return VStack(spacing: DXSpace.cellGap) {
            if showWeekdayHeader {
                HStack(spacing: DXSpace.cellGap) {
                    ForEach(Self.headers, id: \.self) { h in
                        Text(h).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)   // §8
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            // Skip weeks with no day in this month; render out-of-month days BLANK (not grayed) — mockup.
            ForEach(weekRows.indices, id: \.self) { wi in
                let week = weekRows[wi]
                if week.contains(where: { cal.isDate($0, equalTo: month, toGranularity: .month) }) {
                    HStack(spacing: DXSpace.cellGap) {
                        ForEach(week, id: \.self) { date in
                            if cal.isDate(date, equalTo: month, toGranularity: .month) { cell(date) }
                            else { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, DXSpace.screenH)
        .padding(.bottom, 4)
        .dynamicTypeSize(calTypeSize)
    }

    private func gridDays(_ month: Date) -> [Date] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let weekdayIndex = cal.component(.weekday, from: interval.start) - 1
        guard let start = cal.date(byAdding: .day, value: -weekdayIndex, to: interval.start) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    // MARK: Continuous view (opt-in) — one uninterrupted week stream + floating month capsule.

    private var continuousBody: some View {
        // SHARED-ROW week stream: the previous month's trailing days and the new month's leading days live
        // in the SAME row, so a month that starts mid-week has NO empty leading row — the only separation
        // is the new month's cells dropping HALF A CELL (the tight gap you want). Nothing reacts to
        // scrolling (no per-frame preference), so no scroll lag. The month tab floats in that half-cell gap.
        VStack(spacing: 0) {
            pinnedWeekdayHeader   // ONE fixed Su…Sa row for the whole stream
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DXSpace.cellGap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { idx, week in
                        weekRow(week)
                            // Current month's tab sits just under the weekday header, left. If the 1st week
                            // has leading blank cells (mid-week start), the tab floats in those with the 1st
                            // week pinned to the top (no gap). ONLY a Sunday-start current month (no leading
                            // blanks) gets a tab-height gap that pushes its cells down (the exception).
                            .padding(.top, (idx == 0 && cal.component(.weekday, from: rangeStart) == 1) ? Self.monthTabHeight : 0)
                            .overlay(alignment: .topLeading) {
                                if idx == 0, let m = firstDisplayedMonth { monthTab(m, onLeft: true) }
                            }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 24)
                .dynamicTypeSize(calTypeSize)
            }
        }
    }

    // The continuous day range: first day of the current month → last day of the last month with data.
    private var rangeStart: Date {
        cal.dateInterval(of: .month, for: cal.startOfDay(for: Date()))?.start ?? cal.startOfDay(for: Date())
    }
    private var rangeEnd: Date {
        let today = cal.startOfDay(for: Date())
        let lastDate = shifts.map { $0.date }.max() ?? today
        let end = cal.dateInterval(of: .month, for: lastDate)?.end ?? today
        return cal.date(byAdding: .day, value: -1, to: end) ?? lastDate
    }
    private func inRange(_ date: Date) -> Bool { (rangeStart...rangeEnd).contains(cal.startOfDay(for: date)) }
    private var firstDisplayedMonth: Date? { cal.dateInterval(of: .month, for: rangeStart)?.start }

    /// Sun→Sat week rows spanning the whole range (shared boundary rows — no per-month blank padding).
    private var weeks: [[Date]] {
        let start = rangeStart, end = rangeEnd
        let startWeekday = cal.component(.weekday, from: start) - 1
        guard let gridStart = cal.date(byAdding: .day, value: -startWeekday, to: start) else { return [] }
        let endWeekday = cal.component(.weekday, from: end) - 1
        guard let gridEnd = cal.date(byAdding: .day, value: 6 - endWeekday, to: end) else { return [] }
        var days: [Date] = []; var d = gridStart
        while d <= gridEnd {
            days.append(d)
            guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    private func weekRow(_ week: [Date]) -> some View {
        // A month's 1st in this row → its cells drop half a cell; the old month's trailing days stay at the
        // top. That makes an L-shaped empty gap — a BOTTOM-LEFT strip (below the old days, width = # old
        // columns) and a TOP-RIGHT strip (above the new days, width = # new columns). The floating tab goes
        // in the WIDER strip (left preferred): Sunday start → full-width top gap → top-left; Thu–Sat starts
        // (≥4 old columns) → bottom-left; Mon–Wed starts → top-right.
        let newMonth: Date? = week.first { inRange($0) && cal.component(.day, from: $0) == 1 }
            .flatMap { cal.dateInterval(of: .month, for: $0)?.start }
        let showTab = newMonth != nil && newMonth != firstDisplayedMonth
        let firstCol = newMonth.map { cal.component(.weekday, from: $0) - 1 } ?? 0   // 0=Sun … 6=Sat
        // ALL tabs hug the LEFT: a Sunday start has a full-width top gap → top-left; any other start has
        // the previous month's trailing days on the left, leaving an empty strip BELOW them → bottom-left.
        let placement: Alignment = firstCol == 0 ? .topLeading : .bottomLeading
        return HStack(alignment: .top, spacing: DXSpace.cellGap) {
            ForEach(week, id: \.self) { date in
                if inRange(date) {
                    cell(date).padding(.top, monthOffset(date, newMonthInRow: newMonth))
                } else {
                    Color.clear.frame(maxWidth: .infinity)   // alignment spacer (prev/next month)
                }
            }
        }
        .padding(.horizontal, DXSpace.screenH)
        .overlay(alignment: placement) {
            if showTab, let m = newMonth { monthTab(m, onLeft: placement.horizontal == .leading) }
        }
    }

    /// Half-cell top offset for a cell in the row's NEW month (skips the earliest displayed month).
    private func monthOffset(_ date: Date, newMonthInRow: Date?) -> CGFloat {
        guard let nm = newMonthInRow, nm != firstDisplayedMonth,
              cal.dateInterval(of: .month, for: date)?.start == nm else { return 0 }
        return Self.monthTabHeight
    }

    /// The single pinned weekday header for the continuous stream.
    private var pinnedWeekdayHeader: some View {
        HStack(spacing: DXSpace.cellGap) {
            ForEach(Self.headers, id: \.self) { h in
                Text(h).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, DXSpace.screenH)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
        .dynamicTypeSize(calTypeSize)
    }

    /// The month offset gap — set equal to the tab's TOTAL height (bar + 2px top/bottom), so the drop
    /// between months is exactly the size of the tab that floats in it.
    private static let monthTabHeight: CGFloat = 22

    /// A month tab flush to the given screen edge (`onLeft`), sitting in the half-cell gap. Collapsed = a
    /// blue "AUG" chip; tap to slide it open HORIZONTALLY into the month's color-box stats (no month
    /// label). The bar is a few px shorter than the gap so it has breathing room above + below.
    @ViewBuilder private func monthTab(_ m: Date, onLeft: Bool) -> some View {
        let open = expandedMonths.contains(m)
        let barH = Self.monthTabHeight - 4          // 4px shorter than the gap → centered with 2px above/below
        // Chevron points toward the OPEN direction when collapsed, back toward the edge when open.
        let chevron = Image(systemName: onLeft ? (open ? "chevron.left" : "chevron.right")
                                               : (open ? "chevron.right" : "chevron.left"))
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(open ? Color.secondary : Color.white)
        let content = Group {
            if open {
                monthStatChips(m)                                   // opened → color-box stats, no month
            } else {
                Text(Self.monthAbbrevF.string(from: m).uppercased())
                    .font(.system(size: 14, weight: .heavy))
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .foregroundStyle(.white)
            }
        }
        Button {
            withAnimation(.snappy) {
                if open { expandedMonths.remove(m) } else { expandedMonths.insert(m) }
            }
        } label: {
            HStack(spacing: 5) {
                if onLeft { content; chevron } else { chevron; content }
            }
            .frame(height: barH)
            .padding(.leading, onLeft ? 10 : 8)     // tighter horizontal padding → less stick-out
            .padding(.trailing, onLeft ? 8 : 10)
            .background {
                let shape = UnevenRoundedRectangle(
                    topLeadingRadius:     onLeft ? 0 : barH / 2,
                    bottomLeadingRadius:  onLeft ? 0 : barH / 2,
                    bottomTrailingRadius: onLeft ? barH / 2 : 0,
                    topTrailingRadius:    onLeft ? barH / 2 : 0,
                    style: .continuous)
                // Open → neutral so the color boxes read like the normal stats; collapsed → deep maroon chip.
                let maroon = Color(red: 0.40, green: 0.11, blue: 0.18)   // deep maroon
                if open { shape.fill(Color(.secondarySystemBackground)) } else { shape.fill(maroon) }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)          // equal 2px above/below → centers the bar in the gap
        .frame(maxWidth: .infinity, alignment: onLeft ? .leading : .trailing)   // hug the chosen edge
    }

    /// The month's stats as the SAME color-box dots used in the month header (kept, per request).
    @ViewBuilder private func monthStatChips(_ m: Date) -> some View {
        let s = monthStats(for: m)
        HStack(spacing: 10) {
            statDot(AppColor.primary,  "\(s.on) on")
            statDot(AppColor.neutral,  s.vacation > 0 ? "\(s.off) off (\(s.vacation) vac)" : "\(s.off) off")
            if s.tradeAway  > 0 { statDot(AppColor.special, "\(s.tradeAway) trade") }
            if s.keep       > 0 { statDot(AppColor.keep,    "\(s.keep) keep") }
            if s.blackout   > 0 { statDot(AppColor.locked,  "\(s.blackout) blackout") }
            if s.wantToWork > 0 { statDot(AppColor.pending, "\(s.wantToWork) work") }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    private func statDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private struct MonthStats { var on = 0, off = 0, tradeAway = 0, keep = 0, wantToWork = 0, blackout = 0, vacation = 0 }

    /// Per-month tallies: worked ("on") / off days, plus a count for each marked intent.
    private func monthStats(for month: Date) -> MonthStats {
        var s = MonthStats()
        for shift in shifts where cal.isDate(shift.date, equalTo: month, toGranularity: .month) {
            let id = Self.isoF.string(from: shift.date)
            if shift.isVacation { s.off += 1; s.vacation += 1; continue }
            if shift.isOff {
                s.off += 1
                switch intents.offIntent(forDay: id) {
                case .wantToWork: s.wantToWork += 1
                case .mustBeOff:  s.blackout += 1
                default: break
                }
            } else {
                s.on += 1
                switch intents.workingIntent(forDay: id) {
                case .dontWantToWork: s.tradeAway += 1
                case .mustWork:       s.keep += 1
                default: break
                }
            }
        }
        return s
    }

    @ViewBuilder private func cell(_ date: Date) -> some View {
        let dayID     = Self.isoF.string(from: date)
        let shift     = byDay[dayID]
        let hasShift  = shift != nil
        let isOff     = shift.map { $0.isOff } ?? true
        let isWorking = hasShift && !isOff
        let today     = cal.startOfDay(for: Date())
        let isToday   = cal.isDate(date, inSameDayAs: today)
        let isPast    = date < today && !isToday
        let faded     = isFaded(isWorking: isWorking, inMonth: true)

        let kind = tileKind(dayID: dayID, isWorking: isWorking, hasShift: hasShift, date: date, shift: shift)

        VStack(spacing: 1) {
            ZStack {
                // §10: NO behind-number disc. High-demand (holiday) + personal-milestone days are marked by
                // the SAME small corner dot as notes (see `noteDot`); plain "today" is the inset tile ring
                // (see `borderColor`). One consistent marker language — no one-off copper circle.
                Text("\(cal.component(.day, from: date))")
                    .font(isToday ? DXFont.dayNumber.weight(.heavy) : DXFont.dayNumber)
                    .foregroundStyle(numberColor(dayID: dayID, isWorking: isWorking, hasShift: hasShift, date: date, shift: shift))
            }
            .frame(height: DXSpace.cellNumberH)
            .contentShape(Circle())
            .onTapGesture {
                if intents.topology(forDay: dayID) != .standard { infoDay = dayID }
                else if hasShift { onTap(dayID, isOff) }   // normal day → same as cell tap
                withAnimation(.snappy) { tappedDay = dayID }
            }
            .popover(isPresented: Binding(get: { infoDay == dayID },
                                          set: { if !$0 { infoDay = nil } })) {
                topologyInfo(dayID: dayID)
            }
            dayContent(shift: shift, isWorking: isWorking, isOff: isOff, dayID: dayID, date: date)
                .frame(height: DXSpace.cellLabelH)   // FIXED (not minHeight) so every cell is the same size
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DXSpace.cellVPad)
        // Ceramic glaze sits on the TILE FILL only (behind the number/label), clipped to the same radius
        // as the clipShape + stroke so the rim aligns. The intent color is unchanged — just glazed.
        // §1a/§2a: glazed tiles get a real two-tone ceramic gradient + the wet sheen. OFF is a flat matte
        // recessed neutral (no gloss). Blackout is flat matte with an inset border, no glaze (§2d).
        .background {
            let shape = RoundedRectangle(cornerRadius: DXSpace.cellRadius, style: .continuous)
            switch kind {
            case .glazed:
                shape.fill(ceramicFill(background(dayID: dayID, isToday: isToday, isWorking: isWorking, hasShift: hasShift, date: date, shift: shift)))
                    .dxGlaze(radius: DXSpace.cellRadius,
                             intensity: glazeIntensity(dayID: dayID, isWorking: isWorking, hasShift: hasShift, shift: shift))
            case .off:
                // Dark: a lighter glazed slate (still glossy — blackout stays the ONLY matte tile, §2d).
                // Light: flat, shadowless, recessed (§9b) — ON is the only lifted tile.
                if colorScheme == .dark {
                    shape.fill(ceramicFill(background(dayID: dayID, isToday: isToday, isWorking: isWorking, hasShift: hasShift, date: date, shift: shift)))
                        .dxGlaze(radius: DXSpace.cellRadius, intensity: 0.30)
                } else {
                    shape.fill(background(dayID: dayID, isToday: isToday, isWorking: isWorking, hasShift: hasShift, date: date, shift: shift))
                }
            case .blackout:
                shape.fill(AppColor.blackout)
                    .overlay(shape.strokeBorder(AppColor.blackoutBorder, lineWidth: 1))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DXSpace.cellRadius))
        // §9a: lift ONLY glazed tiles off the page in light mode; OFF + blackout stay recessed (no lift).
        .shadow(color: kind == .glazed ? AppColor.tileShadow : .clear, radius: 1.5, x: 0, y: 1)
        .overlay(
            RoundedRectangle(cornerRadius: DXSpace.cellRadius)
                .strokeBorder(borderColor(dayID: dayID, isToday: isToday, isOff: isOff, hasShift: hasShift),
                              lineWidth: flashDays.contains(dayID) ? 3
                                       : (isToday && intents.topology(forDay: dayID) == .standard ? 2
                                          : borderWidth(dayID: dayID, isOff: isOff)))
        )
        // Intent pill (TRADE / KEEP / BLACKOUT / WANT) flashes in ONLY when you tap the day — never
        // rendered persistently, so it can't crowd the number. Notes / events stay top-right.
        .overlay(alignment: .topLeading) {
            // Flash the intent pill ONLY in the read-only Main view — while MARKING, each paint-tap
            // would otherwise flash a stray TRADE/KEEP pill (the tile color already shows the result).
            if tappedDay == dayID, mode == .off {
                intentPill(dayID: dayID, isWorking: isWorking, date: date, shift: shift)
                    .padding(3).transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) { noteDot(dayID).padding(3) }
        .opacity(faded ? 0.3 : (isPast ? 0.45 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            if hasShift { onTap(dayID, isOff) }
            withAnimation(.snappy) { tappedDay = dayID }
        }
        .onLongPressGesture(minimumDuration: 0.35) { if hasShift { onLongPress(dayID, isOff) } }
    }

    @ViewBuilder private func dayContent(shift: Shift?, isWorking: Bool, isOff: Bool, dayID: String, date: Date) -> some View {
        if let shift, shift.isVacation {
            // Vacation (V or ECB-VC "w") → "VAC" always shows, on TOP of any intent formatting: it overrides
            // the blackout lock, and stays on a want-to-work gold tile too (the WANT pill still marks it).
            Text("VAC")
                .font(DXFont.dayNote)
                .foregroundStyle(Color.white.opacity(0.9))
                .accessibilityLabel("Vacation")
        } else if isBlackout(dayID: dayID, isWorking: isWorking, date: date, shift: shift) {
            // §2d: blackout shows a dim lock glyph (no red ✕) on the flat matte tile.
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppColor.blackoutNumber)
                .accessibilityLabel("Blackout")
        } else if isWorking, let shift {
            // Type (AM/PM/MID) and desk are independently toggleable. Both off → blank (the colored day
            // circle still marks it as worked).
            let type = layers.shiftType ? shift.shiftTypeLabel : ""
            let desk = (layers.deskAssignments && !shift.desk.isEmpty) ? shift.desk : ""
            if type.isEmpty && desk.isEmpty {
                Color.clear.frame(height: 14)
            } else {
                // Shift + desk sit in their own row with a clear gap, muted vs the bright day
                // number (mockup #9fb0c8 on navy); .primary.opacity adapts to light mode.
                HStack(spacing: 3) {
                    if !type.isEmpty { Text(type) }
                    if !desk.isEmpty { Text(desk) }
                }
                .font(DXFont.dayNote)
                // White-ish on vivid / black-blackout tiles, muted primary on neutral tiles.
                .foregroundStyle(lightText(dayID: dayID, isWorking: isWorking, shift: shift, date: date)
                                 ? Color.white.opacity(0.85) : Color.primary.opacity(0.7))
                .lineLimit(1).minimumScaleFactor(0.6)
            }
        } else if isOff, layers.availability {
            // A/P/M availability pills on off days — controlled purely by the "Shift
            // availability" layer toggle (the clock button), so it works in the general
            // read-only view too, not just while marking days-off. (Intent itself is shown by
            // the corner pill + tile color; "WANT" now lives in the corner pill.)
            offAvailability(dayID)
        } else {
            Color.clear.frame(height: 14)
        }
    }

    /// Off-day availability: legal pickup types (faint), your chosen ones solid;
    /// a red ⊗ when you've marked yourself unavailable (deselected everything).
    @ViewBuilder private func offAvailability(_ dayID: String) -> some View {
        if intents.offIntent(forDay: dayID) == .mustBeOff {
            Image(systemName: "xmark.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(BrickPalette.critical)
        } else {
            let legal = Legality.legalTypes(forDayID: dayID, shifts: shifts)
            // Per-shift state (gold + ✕ can coexist): gold = actively want-to-work; ✕ = explicitly blacked
            // out; neither = neutral/open. A cleared/open day has NO ✕ (fixes erase showing all-✕).
            let wanted = intents.wanted(forDay: dayID)
            let blacked = intents.blackedShifts(forDay: dayID, legal: Set(legal))
            if legal.isEmpty {
                // #1: no legal shift is coverable here (rest / legal-start) → auto-X; can't want-to-work it.
                Image(systemName: "nosign")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BrickPalette.critical.opacity(0.75))
                    .accessibilityLabel("No tradeable shift available")
            } else {
                HStack(spacing: 2) {
                    ForEach(ShiftAvailabilityType.allCases.filter { legal.contains($0) }, id: \.self) { t in
                        let gold = wanted.contains(t)
                        let x = blacked.contains(t) && !gold   // gold wins if somehow both
                        Text(String(t.rawValue.prefix(1)))
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(gold ? Color.white : Color(.secondaryLabel))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(gold ? BrickPalette.availableOff : Color(.tertiarySystemFill).opacity(0.5)))
                            // Red ✕ over any shift type blacked out on this day.
                            .overlay {
                                if x {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .heavy))
                                        .foregroundStyle(BrickPalette.critical)
                                }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder private func noteDot(_ dayID: String) -> some View {
        // §10: ONE small corner dot for every per-day marker. A user note (gated by the Notes layer) takes
        // the slot first; otherwise an event day — personal milestone or high-demand holiday — shows the same
        // corner dot in its semantic palette color (was a one-off copper disc behind the number). Vacation-
        // reason notes stay hidden (the "VAC" label conveys them).
        let topo = intents.topology(forDay: dayID)
        if layers.notes, let note = intents.note(forDay: dayID), note.reason != .vacation {
            NoteMarker(note: note)
        } else if topo == .personalMilestone {
            EventMarker(name: "Personal milestone", color: BrickPalette.milestone, icon: "star.fill")
        } else if topo == .highDemand {
            EventMarker(name: Holidays.name(forDay: dayID) ?? "High-demand day",
                        color: BrickPalette.highImpact, icon: "star.fill")
        } else {
            Color.clear.frame(height: 9)
        }
    }

    // MARK: Styling

    private func isFaded(isWorking: Bool, inMonth: Bool) -> Bool {
        guard inMonth else { return false }
        switch mode {
        case .off:           return false
        case .workingShifts: return !isWorking
        case .daysOff:       return isWorking
        }
    }

    private func background(dayID: String, isToday: Bool, isWorking: Bool, hasShift: Bool,
                            date: Date, shift: Shift?) -> Color {
        if layers.intentOverlays {
            // A user blackout (must-be-off) paints the black tile OVER a vacation day — the blackout cell
            // format is kept; only the lock GLYPH is swapped for "VAC" (in dayContent).
            if !isWorking, intents.offIntent(forDay: dayID) == .mustBeOff { return AppColor.blackout }
            if let tint = intentTint(dayID: dayID, isWorking: isWorking) { return tint }
            // A trade-blacklist match (desk / type / region / weekday) also reads as a black blocked tile.
            if blackoutTint(date: date, shift: shift) != nil { return AppColor.blackout }
        }
        // Vacation (with NO overriding intent) reads as a teal tile.
        if let shift, shift.isVacation { return AppColor.vacation }
        if !hasShift { return Color(.systemGray6) }
        // Worked no-intent = navy/white surface; off no-intent = slate/light-slate — both ADAPTIVE.
        return isWorking ? AppColor.cellWorked : AppColor.cellOff
    }

    /// A blocked/blackout day: explicit "must be off", or a trade-blacklist match with no overriding
    /// explicit intent (mirrors `background`'s precedence). Black tile → needs white text.
    private func isBlackout(dayID: String, isWorking: Bool, date: Date, shift: Shift?) -> Bool {
        guard layers.intentOverlays else { return false }
        if !isWorking, intents.offIntent(forDay: dayID) == .mustBeOff { return true }
        if intentTint(dayID: dayID, isWorking: isWorking) != nil { return false }
        return blackoutTint(date: date, shift: shift) != nil
    }

    /// Small corner pill naming the day's intent (TRADE / KEEP / BLACKOUT / WANT). White text on a
    /// translucent chip so it reads on every tile (purple / green / amber / black).
    @ViewBuilder private func intentPill(dayID: String, isWorking: Bool, date: Date, shift: Shift?) -> some View {
        if let text = intentLabel(dayID: dayID, isWorking: isWorking, date: date, shift: shift) {
            DXIntentPill(text: text)
        }
    }

    private func intentLabel(dayID: String, isWorking: Bool, date: Date, shift: Shift?) -> String? {
        if isWorking {
            switch intents.workingIntent(forDay: dayID) {
            case .dontWantToWork: return "TRADE"
            case .mustWork:       return "KEEP"
            default: break
            }
        } else {
            switch intents.offIntent(forDay: dayID) {
            case .mustBeOff:  return "BLACKOUT"
            case .wantToWork: return "WANT"
            default: break
            }
        }
        // No explicit intent, but a trade-blacklist match still reads as a blackout.
        if isBlackout(dayID: dayID, isWorking: isWorking, date: date, shift: shift) { return "BLACKOUT" }
        return nil
    }

    /// Tiles that need white text in BOTH modes: vivid semantic fills and black blackout tiles.
    private func lightText(dayID: String, isWorking: Bool, shift: Shift?, date: Date) -> Bool {
        isVividTile(dayID: dayID, isWorking: isWorking, shift: shift)
            || isBlackout(dayID: dayID, isWorking: isWorking, date: date, shift: shift)
    }

    /// B4-3: tint a day that matches the user's trade blacklist (never traded/worked). Working shifts
    /// match on desk/type/region/weekday; off days match on **weekday only** (no desk). Only reached
    /// when the day has no explicit intent (intent wins). Assumptions flagged in ASSUMED_PRESENT.
    private func blackoutTint(date: Date, shift: Shift?) -> Color? {
        let weekday = cal.component(.weekday, from: date)
        let s = SettingsManager.shared
        let hit: Bool
        if let shift, !shift.isOff {
            // Working day: tint only on the desk/type/region dimensions. The weekday ("Blackout days")
            // dimension is intentionally EXCLUDED here (pass []), because a blacked-out weekday only ever
            // suppresses PICKUPS — and pickups require you to be off (canCover's hard isOff gate). Tinting a
            // working shift for it would misrepresent the matching behavior.
            hit = Blackout.isBlacklisted(desk: shift.desk, startHour: shift.startHour, weekday: weekday,
                                         desks: s.blacklistedDesks, shiftTypes: s.blacklistedShiftTypes,
                                         regions: s.blacklistedRegions, weekdays: [])
        } else {
            hit = s.blacklistedWeekdays.contains(weekday)   // off day: weekday blackout applies here
        }
        // Blacklist "blocked" family reads SLATE (same as an off-day Blackout + the Trade-Settings pills),
        // visually distinct from the green "keep"/must-work intent. (One hue = one meaning.)
        return hit ? OffIntentState.mustBeOff.brickColor.opacity(0.30) : nil
    }

    /// Dispatch "brick" intent fill, or nil when the day has no explicit intent.
    /// Day-off fills are intentionally fainter than worked-day fills so a day off
    /// reads as the lighter, more passive layer of the calendar.
    private func intentTint(dayID: String, isWorking: Bool) -> Color? {
        if isWorking {
            // Only Keep / Trade-away paint. "Open" (neutralOpen) is the CLEARED state → normal cell color.
            switch intents.workingIntent(forDay: dayID) {
            case .dontWantToWork, .mustWork: return intents.workingIntent(forDay: dayID)?.brickColor
            default: return nil
            }
        } else {
            // Only Want-to-Work paints (amber). Blackout is black (handled in `background`); "Open" is
            // the cleared state → normal cell color (no faint tint).
            return intents.offIntent(forDay: dayID) == .wantToWork ? OffIntentState.wantToWork.brickColor : nil
        }
    }

    /// Popover shown when a gold/pink day's circle is tapped: what the day is, plus
    /// the reason (a public note's text, else the categorized reason).
    @ViewBuilder private func topologyInfo(dayID: String) -> some View {
        let topo = intents.topology(forDay: dayID)
        let isPersonal = topo == .personalMilestone
        let note = intents.note(forDay: dayID)
        VStack(alignment: .leading, spacing: 6) {
            Label(isPersonal ? "Personal milestone" : "High-impact day",
                  systemImage: isPersonal ? "star.circle.fill" : "exclamationmark.circle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(isPersonal ? BrickPalette.personalDay : BrickPalette.highImpact)
            if !isPersonal, let holiday = Holidays.name(forDay: dayID) {
                Text(holiday).font(.body)
            }
            if let note, !note.isPrivate, !note.message.isEmpty {
                Text(note.message).font(.body)
            } else if let r = note?.reason {
                Text("Reason: \(r.label)").font(.caption).foregroundStyle(.secondary)
            } else if isPersonal {
                Text("Long-press the day to add a reason or note.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(minWidth: 200)
        .presentationCompactAdaptation(.popover)
    }

    private func borderColor(dayID: String, isToday: Bool, isOff: Bool, hasShift: Bool) -> Color {
        if flashDays.contains(dayID) { return BrickPalette.warning }
        // "today" is a blue inset ring on the tile (mockup), for ANY day — including a holiday/milestone,
        // which now carries only the small corner dot (§10) rather than a disc, so the ring is its "today" cue.
        if isToday { return AppColor.primary }
        return .clear
    }

    private func borderWidth(dayID: String, isOff: Bool) -> CGFloat { 0 }

    /// A "vivid" tile = a saturated semantic fill (keep / trade-away / want-to-work / vacation). Vivid
    /// tiles take white text + a glossier glaze in BOTH modes (mockup); neutral tiles use adaptive text.
    private func isVividTile(dayID: String, isWorking: Bool, shift: Shift?) -> Bool {
        if let shift, shift.isVacation { return true }
        guard layers.intentOverlays else { return false }
        if isWorking {
            switch intents.workingIntent(forDay: dayID) {
            case .dontWantToWork, .mustWork: return true   // Open = cleared → not vivid
            default: return false
            }
        }
        return intents.offIntent(forDay: dayID) == .wantToWork
    }

    /// Glossier glaze on vivid tiles (mockup's strong top-highlight + inner shadow); subtle matte otherwise.
    private func glazeIntensity(dayID: String, isWorking: Bool, hasShift: Bool, shift: Shift?) -> CGFloat {
        isVividTile(dayID: dayID, isWorking: isWorking, shift: shift) ? 0.72 : 0.34
    }

    /// How a cell renders: glazed ceramic gradient (ON navy + all vivid states), flat recessed OFF, or
    /// flat matte blackout. Drives fill, glaze, shadow, and number color together (§1a / §2b / §2d).
    private enum TileKind { case glazed, off, blackout }
    private func tileKind(dayID: String, isWorking: Bool, hasShift: Bool, date: Date, shift: Shift?) -> TileKind {
        if isBlackout(dayID: dayID, isWorking: isWorking, date: date, shift: shift) { return .blackout }
        if isVividTile(dayID: dayID, isWorking: isWorking, shift: shift) { return .glazed }   // trade / keep / want / vacation
        if !hasShift { return .off }
        return isWorking ? .glazed : .off   // ON navy = glazed; off-neutral = recessed
    }

    /// Number color per tile: white on vivid tiles, adaptive `.primary` on the ON navy/white tile, dim on
    /// OFF + blackout. (No marker-disc case anymore — §10 removed the behind-number disc.)
    private func numberColor(dayID: String, isWorking: Bool, hasShift: Bool, date: Date, shift: Shift?) -> Color {
        if isBlackout(dayID: dayID, isWorking: isWorking, date: date, shift: shift) { return AppColor.blackoutNumber }
        if isVividTile(dayID: dayID, isWorking: isWorking, shift: shift) { return Color.white }
        if !isWorking { return AppColor.cellOffText }   // OFF / empty → dim
        return Color.primary                             // ON glazed neutral (navy dark / white light)
    }
}

// MARK: - Per-day intent editor (long-press)

struct DayIntentEditor: View {
    let target: DayEditTarget

    private var intents = DayIntentStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var working: WorkingIntentState?
    @State private var off: OffIntentState?
    @State private var reason: IntentReason?
    @State private var reasonText = ""
    @State private var significant = false
    @State private var carryover = false
    @State private var noteText = ""
    @State private var notePrivate = false
    @State private var saving = false

    init(target: DayEditTarget) { self.target = target }

    private var prettyDate: String {
        guard let d = TradeMatcher.dayDate(fromISO: target.dayID) else { return target.dayID }
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d, yyyy"; return f.string(from: d)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Intent") {
                    if target.isOff {
                        Picker("Day off", selection: Binding(
                            get: { off ?? .neutralOpen },
                            set: { off = $0 })) {
                            ForEach(OffIntentState.allCases) { Text($0.label).tag($0) }
                        }
                    } else {
                        Picker("Working shift", selection: Binding(
                            get: { working == .wantToWork ? .mustWork : (working ?? .neutralOpen) },
                            set: { working = $0 })) {
                            ForEach(WorkingIntentState.allCases.filter { $0 != .wantToWork }) {
                                Text($0.label).tag($0)   // .mustWork label = "Keep" (working-day protect; green)
                            }
                        }
                    }
                }

                Section {
                    TextField("Why? (free text)", text: $reasonText, axis: .vertical)
                        .lineLimit(1...3)
                    if let reason {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").foregroundStyle(AppColor.special)
                            Text("Tagged as \(reason.label)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Reason")
                } footer: {
                    Text("Type it naturally — it's tagged automatically on save.")
                }

                Section {
                    if let holiday = Holidays.name(forDay: target.dayID) {
                        Label("High-demand holiday: \(holiday)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(BrickPalette.warning)
                    }
                    Toggle("Significant day", isOn: $significant)
                } footer: {
                    Text("Protects this date from automatic trade suggestions.")
                }

                Section {
                    Toggle("Carryover Vacation", isOn: $carryover)
                } footer: {
                    Text("Marks this day as a vacation (you're off) and tells others — use it for a carryover vacation that isn't printed in the posted schedule.")
                }

                Section("Note (≤ 50 chars)") {
                    HStack {
                        TextField("Short note", text: $noteText)
                            .onChange(of: noteText) { _, v in if v.count > 50 { noteText = String(v.prefix(50)) } }
                        CharCounter(text: noteText, limit: 50)
                    }
                    Toggle("Make Private", isOn: $notePrivate)
                }

                Section {
                    Button("Clear all intent for this day", role: .destructive) {
                        intents.clearIntent(forDay: target.dayID)
                        intents.setNote(nil, forDay: target.dayID)
                        intents.setTopology(nil, forDay: target.dayID)
                        dismiss()
                    }
                }
            }
            .navigationTitle(prettyDate)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        working = intents.workingIntent(forDay: target.dayID)
        off = intents.offIntent(forDay: target.dayID)
        significant = intents.topology(forDay: target.dayID) != .standard
        carryover = intents.isCarryoverVacation(target.dayID)
        if let n = intents.note(forDay: target.dayID) {
            noteText = n.message; notePrivate = n.isPrivate; reason = n.reason
        }
    }

    private func save() async {
        saving = true
        // Categorize the free-text reason with the on-device model.
        reason = await ReasonClassifier.classify(reasonText)
        if target.isOff { intents.setOffIntent(off, forDay: target.dayID) }
        else { intents.setWorkingIntent(working, forDay: target.dayID) }
        intents.setTopology(significant ? .personalMilestone : nil, forDay: target.dayID)
        if carryover != intents.isCarryoverVacation(target.dayID) { intents.toggleCarryoverVacation(target.dayID) }
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        intents.setNote(trimmed.isEmpty ? nil
                        : DayNote(dayID: target.dayID, message: trimmed, reason: reason, isPrivate: notePrivate),
                        forDay: target.dayID)
        saving = false
        dismiss()
    }
}

// MARK: - Wrapping pill row + selectable blackout pill (Trade Settings)

/// A simple left-to-right wrapping layout — pills flow onto the next line when a row fills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxRowW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { maxRowW = max(maxRowW, x - spacing); x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        maxRowW = max(maxRowW, x - spacing)
        return CGSize(width: min(maxRowW, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

/// A tappable "blackout / blacklist" pill. Selected = excluded (slate Blackout hue, matching the calendar's
/// Blackout tint). `enabled == false` grays it out (e.g. a region the user isn't qualified for).
struct BlacklistPill: View {
    let label: String
    let selected: Bool
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(!enabled ? Color.secondary.opacity(0.45) : (selected ? .white : .primary))
                .padding(.horizontal, 13).padding(.vertical, 7)
                // §5: glazed ceramic chip. ACTIVE = the blackout matte-graphite tile (`AppColor.blackout`),
                // the SAME language as a blacked-out calendar cell — not the slate "locked" purple that
                // clashed. Inactive = neutral glazed. A blacklist chip and a blackout cell now read alike.
                .background {
                    let shape = RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous)
                    if !enabled {
                        shape.fill(Color(.tertiarySystemFill).opacity(0.4))
                    } else if selected {
                        shape.fill(AppColor.blackout).dxGlaze(radius: DS.controlRadius)
                    } else {
                        shape.fill(Color(.tertiarySystemFill)).dxGlaze(radius: DS.controlRadius)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Tabbed Trade Settings sheet

struct TradeSettingsSheet: View {
    @Bindable private var settings = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var myQuals: [String] = []
    @State private var showOverrideEditor = false
    @State private var editingNotes = false

    /// Re-run the base openness shortcut (which layers in the date-range overrides)
    /// and re-publish. Call after any override change.
    private func reapplyOpenness() {
        settings.markPrefsChanged()
        let level = TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends
        DayIntentStore.shared.applyOpenness(level, shifts: ShiftStore.shared.shifts)
        Task { await TradeProfileStore.shared.publishMine() }
    }

    private var openness: Binding<TradeOpenness> {
        Binding(get: { TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends },
                set: { level in
                    settings.tradeOpenness = level.rawValue
                    settings.markPrefsChanged()
                    // Openness is a shortcut: bulk-apply it to the availability pills,
                    // then publish so matching reflects it.
                    DayIntentStore.shared.applyOpenness(level, shifts: ShiftStore.shared.shifts)
                    Task { await TradeProfileStore.shared.publishMine() }
                })
    }
    private var mercenary: Binding<Bool> {
        Binding(get: { settings.isMercenaryMode },
                set: { on in
                    settings.isMercenaryMode = on
                    settings.markPrefsChanged()
                    let level = TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends
                    DayIntentStore.shared.applyMercenary(on, openness: level, shifts: ShiftStore.shared.shifts)
                    Task { await TradeProfileStore.shared.publishMine() }
                })
    }
    private var deskText: Binding<String> {
        Binding(get: { settings.blacklistedDesks.sorted().joined(separator: ", ") },
                set: { v in settings.blacklistedDesks = Set(v.split { $0 == "," || $0 == " " }
                    .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) })
    }

    // ── Qual-swap settings (Q4) ──────────────────────────────────────────
    /// Comma/space-separated list of desk numbers the user won't qual-swap into.
    private var qualSwapDeskText: Binding<String> {
        Binding(get: { settings.qualSwapBlacklistDesks.sorted().joined(separator: ", ") },
                set: { v in
                    settings.qualSwapBlacklistDesks = Set(v.split { $0 == "," || $0 == " " }
                        .map { String($0).uppercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                    publishProfile()
                })
    }
    /// Per-qual preference value: `-1` = Open (no preference, absent from the map),
    /// `0` = won't work (blacklisted), `1…` = least→most preferred.
    private func qualValueBinding(_ qual: String) -> Binding<Int> {
        Binding(get: { settings.qualValues[qual] ?? -1 },
                set: { newVal in
                    var v = settings.qualValues
                    if newVal < 0 { v.removeValue(forKey: qual) } else { v[qual] = newVal }
                    settings.qualValues = v
                    publishProfile()
                })
    }
    private func publishProfile() { settings.markPrefsChanged(); Task { await TradeProfileStore.shared.publishMine() } }

    /// Weekday pills for "Blackout days" — Calendar weekday numbers (1 = Sun … 7 = Sat) → single letters.
    static let weekdayPills: [(day: Int, letter: String)] =
        [(1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")]

    /// Toggle a value in one of the blacklist sets, then re-publish so peers' matching reflects it. The
    /// user's OWN feed/calendar update live (SettingsManager is @Observable); publish keeps peers current.
    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
        publishProfile()
    }

    // ── Relief dispatcher (schedule known only ~45 days out) ─────────────
    private var reliefOn: Binding<Bool> {
        Binding(get: { settings.isReliefDispatcher },
                set: { on in
                    settings.isReliefDispatcher = on
                    // Force a date when toggled on (default 45 days out).
                    if on && settings.reliefScheduleThrough == nil {
                        settings.reliefScheduleThrough = Calendar.current.date(byAdding: .day, value: 45, to: Date())
                    }
                    publishProfile()
                })
    }
    private var reliefDate: Binding<Date> {
        Binding(get: { settings.reliefScheduleThrough ?? (Calendar.current.date(byAdding: .day, value: 45, to: Date()) ?? Date()) },
                set: { settings.reliefScheduleThrough = Calendar.current.startOfDay(for: $0); publishProfile() })
    }

    var body: some View {
        NavigationStack {
            Form {
                DXSegmented(selection: $tab, options: [
                    .init(0, "Profile"), .init(1, "Trade Settings"),
                ])
                .listRowBackground(Color.clear)

                if tab == 0 { profile } else { tradeSettings }
            }
            .scrollContentBackground(.hidden)   // §11: drop the grouped-list chrome background
            .navigationTitle("Trade Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DXCloseButton { dismiss() } } }
            // R-B: single publish funnel — guarantees status/settings edits reach peers even
            // when a vertical TextField swallows .onSubmit (status was blank cross-device).
            .onDisappear { publishProfile() }
            .sheet(isPresented: $showOverrideEditor) {
                OpennessOverrideEditor { ov in
                    settings.opennessOverrides.append(ov)
                    reapplyOpenness()
                }
            }
            .sheet(isPresented: $editingNotes) { PrivateNotesEditor() }
            .task {
                // Heal any stale "want to work" left by the old openness behavior:
                // re-apply the (neutral) openness shortcut. Manual edits are preserved.
                if !settings.isMercenaryMode {
                    let lvl = TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends
                    DayIntentStore.shared.applyOpenness(lvl, shifts: ShiftStore.shared.shifts)
                }
                myQuals = settings.cachedQuals   // instant from cache so region pills aren't stale
                if myQuals.isEmpty {
                    // Fresh user / first launch: the master may still be importing, so the schedule fetch
                    // (and the import-time qual cache) land late. Poll on BOTH signals until quals resolve
                    // (~8s) instead of showing "no quals" until the sheet is re-opened.
                    for _ in 0..<20 {
                        let q = await RosterStore.shared.schedule(forWorker: settings.username).first?.quals ?? []
                        if !q.isEmpty { myQuals = q; settings.cachedQuals = q; break }
                        if !settings.cachedQuals.isEmpty { myQuals = settings.cachedQuals; break }
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                } else {
                    // Already have cached quals — refresh silently from the roster if it now differs.
                    let q = await RosterStore.shared.schedule(forWorker: settings.username).first?.quals ?? []
                    if !q.isEmpty { myQuals = q; settings.cachedQuals = q }
                }
            }
        }
    }

    private func prettyRange(_ start: String, _ end: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let out = DateFormatter(); out.dateFormat = "MMM d, yyyy"
        guard let s = f.date(from: start), let e = f.date(from: end) else { return "\(start) – \(end)" }
        return "\(out.string(from: s)) – \(out.string(from: e))"
    }

    // MARK: Profile tab

    @ViewBuilder private var profile: some View {
        Section("Status (public, 140 chars)") {
            TextField("e.g. \"😀 Happy to take weekend PMs\" — emojis welcome", text: Binding(
                get: { settings.statusBroadcast },
                set: { settings.statusBroadcast = String($0.prefix(140)) }), axis: .vertical)
                .lineLimit(1...3)
                .onSubmit { publishProfile() }   // publish status on change (A3 cross-device)
            HStack { Spacer(); CharCounter(text: settings.statusBroadcast, limit: 140) }
        }
        Section("Qualifications") {
            if myQuals.isEmpty {
                Text("No quals loaded — import your roster.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    ForEach(myQuals, id: \.self) { q in
                        Text(q).font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
        Section {
            // Read-only single-line bar; swipe horizontally to read long notes, tap to edit.
            Button { editingNotes = true } label: {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(settings.privateNotes.isEmpty ? "Tap to add private notes" : settings.privateNotes)
                            .font(.subheadline)
                            .foregroundStyle(settings.privateNotes.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.vertical, 2)
                    }
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Private notes")
        } footer: {
            Text("Stored on your device only and never shared. Tap to edit; swipe to read.")
        }
    }

    // MARK: Trade Settings tab

    @ViewBuilder private var tradeSettings: some View {
        Section {
            Picker("Accepting", selection: openness) {
                ForEach(TradeOpenness.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("Mercenary mode (take any qualifying shift)", isOn: mercenary)
        } header: {
            Text("Openness")
        } footer: {
            Text("A shortcut that sets your availability pills on Main View — “All” accepts any pickup, “Bookends” accepts only pickups that don’t split your time off, “Not accepting” blocks all matches. Both All and Bookends leave the calendar neutral; only Mercenary mode paints every off day “want to work.” You can fine-tune any day afterward.")
        }

        Section {
            ForEach(settings.opennessOverrides.sorted { $0.startDay < $1.startDay }) { ov in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ov.openness.label).font(.subheadline.weight(.semibold))
                        Text("\(prettyRange(ov.startDay, ov.endDay))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: ov.openness.symbol).foregroundStyle(.secondary)
                }
            }
            .onDelete { idx in
                let sorted = settings.opennessOverrides.sorted { $0.startDay < $1.startDay }
                let ids = Set(idx.map { sorted[$0].id })
                settings.opennessOverrides.removeAll { ids.contains($0.id) }
                reapplyOpenness()
            }
            Button { showOverrideEditor = true } label: {
                Label("Add date-range override", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Date-range overrides")
        } footer: {
            Text("Temporarily change your openness for a specific span — e.g. base “Bookends”, but “Open to all” for a slow week. Active until you delete it.")
        }
        Section {
            TextField("e.g. 29, 82", text: deskText)
                .autocorrectionDisabled().textInputAutocapitalization(.characters)
        } header: {
            Text("Blacklisted desks")
        } footer: {
            Text("You won't be offered automated pickups on these desks.")
        }
        Section {
            FlowLayout(spacing: 8) {
                ForEach(ShiftAvailabilityType.allCases, id: \.self) { type in
                    BlacklistPill(label: type.rawValue,
                                  selected: settings.blacklistedShiftTypes.contains(type.rawValue)) {
                        toggle(&settings.blacklistedShiftTypes, type.rawValue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
        } header: {
            Text("Blacklisted shift types")
        } footer: {
            Text("Tap a type (AM / PM / MID) to stop being offered those shifts.")
        }
        Section {
            FlowLayout(spacing: 8) {
                ForEach(DeskRegion.allCases, id: \.self) { region in
                    let qualed = DeskRules.isQualified(quals: myQuals, forRegion: region)
                    BlacklistPill(label: region.rawValue,
                                  selected: settings.blacklistedRegions.contains(region.rawValue),
                                  enabled: qualed) {
                        toggle(&settings.blacklistedRegions, region.rawValue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
        } header: {
            Text("Blacklisted regions")
        } footer: {
            Text("Grayed regions need a qualification you don't hold. Tap a region to stop being offered its desks.")
        }
        Section {
            FlowLayout(spacing: 8) {
                ForEach(Self.weekdayPills, id: \.day) { wd in
                    BlacklistPill(label: wd.letter,
                                  selected: settings.blacklistedWeekdays.contains(wd.day)) {
                        toggle(&settings.blacklistedWeekdays, wd.day)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
        } header: {
            Text("Blackout days")
        } footer: {
            Text("Tap the days you never want offered in trades — they show as Blackout on your calendar.")
        }

        qualSwapSettings
        reliefSettings
    }

    // MARK: Relief dispatcher

    @ViewBuilder private var reliefSettings: some View {
        Section {
            Toggle("Relief Dispatcher", isOn: reliefOn)
            if settings.isReliefDispatcher {
                DatePicker("Schedule known through", selection: reliefDate, displayedComponents: .date)
            }
        } header: {
            Text("Relief schedule")
        } footer: {
            Text("Relief dispatchers only get their schedule ~45 days out; the master roster pads the rest of the year with placeholder AMs. Set the last real date — your shifts after it are hidden from your calendar and from trading (for everyone), and stay hidden across roster updates.")
        }
        .listRowBackground(AppColor.vacation.opacity(0.20))   // E3: relief box visually distinct (higher contrast)
    }

    // MARK: Qual-swap preferences (Q4)

    private var qualSwapMaxValue: Int { max(myQuals.count, 2) }

    @ViewBuilder private var qualSwapSettings: some View {
        Section {
            if myQuals.isEmpty {
                Text("No quals loaded — import your roster to set qual-swap preferences.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(myQuals, id: \.self) { q in
                    Picker(q, selection: qualValueBinding(q)) {
                        Text("Open").tag(-1)
                        Text("Won't work").tag(0)
                        ForEach(1...qualSwapMaxValue, id: \.self) { v in
                            Text(v == 1 ? "1 (least)"
                                 : v == qualSwapMaxValue ? "\(v) (most)" : "\(v)").tag(v)
                        }
                    }
                }
            }
        } header: {
            Text("Qual-swap preferences")
        } footer: {
            Text("When a trade needs a qual swap, you'll be asked to move onto a different desk. You'll accept only if that desk's qual is ranked EQUAL OR HIGHER than the qual of the desk you're already working that day.\n\n• Open = no preference (you'll take it).\n• Won't work (0) = never swap into that qual.\n• 1 = least preferred … higher = more preferred.")
        }
        .listRowBackground(AppColor.special.opacity(0.20))   // E3: qual-swap section distinct from blacklists above

        Section {
            TextField("e.g. 64, 65", text: qualSwapDeskText)
                .autocorrectionDisabled().textInputAutocapitalization(.characters)
        } header: {
            Text("Qual-swap desk blacklist")
        } footer: {
            Text("Specific desk numbers you'll never qual-swap into — blocked regardless of qual preference.")
        }
        .listRowBackground(AppColor.special.opacity(0.20))   // E3
    }
}

// MARK: - Private notes editor

/// Full editor for the device-only private notes (the settings row shows a
/// read-only swipeable preview that opens this).
struct PrivateNotesEditor: View {
    private var settings = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: Binding(
                        get: { settings.privateNotes },
                        set: { settings.editPrivateNotes(String($0.prefix(2000))) }))
                        .frame(minHeight: 220)
                    HStack { Spacer(); CharCounter(text: settings.privateNotes, limit: 2000) }
                } footer: {
                    Text("Private to you — synced across your own devices, never shared with anyone else.")
                }
            }
            .navigationTitle("Private Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DXCloseButton { dismiss() } } }
            .onDisappear { Task { await PrivateStateStore.shared.publishLocal() } }   // sync up on close (A3)
        }
    }
}

// MARK: - Date-range openness override editor

/// Modal to add a date-range openness override that supersedes the base openness
/// for its span until deleted.
struct OpennessOverrideEditor: View {
    let onSave: (OpennessOverride) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var start = Date()
    @State private var end = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var openness: TradeOpenness = .all

    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section("Date range") {
                    DatePicker("Start", selection: $start, displayedComponents: .date)
                    DatePicker("End", selection: $end, in: start..., displayedComponents: .date)
                }
                Section("Openness for these days") {
                    Picker("Accepting", selection: $openness) {
                        ForEach(TradeOpenness.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Openness Override")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let cal = Calendar.current
                        let s = cal.startOfDay(for: start)
                        let e = cal.startOfDay(for: max(end, start))
                        onSave(OpennessOverride(id: UUID().uuidString,
                                                startDay: Self.isoF.string(from: s),
                                                endDay: Self.isoF.string(from: e),
                                                opennessRaw: openness.rawValue))
                        dismiss()
                    }
                }
            }
        }
    }
}
