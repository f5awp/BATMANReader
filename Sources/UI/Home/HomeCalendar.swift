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
    let onTap: (_ dayID: String, _ isOff: Bool) -> Void
    let onLongPress: (_ dayID: String, _ isOff: Bool) -> Void

    private var intents = DayIntentStore.shared
    @State private var infoDay: String?
    private let cal = Calendar.current
    private static let headers = ["Su", "M", "T", "W", "Th", "F", "Sa"]
    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let monthF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    init(shifts: [Shift], mode: IntentMode, layers: LayerVisibility, flashDays: Set<String>,
         onTap: @escaping (String, Bool) -> Void, onLongPress: @escaping (String, Bool) -> Void) {
        self.shifts = shifts; self.mode = mode; self.layers = layers
        self.flashDays = flashDays; self.onTap = onTap; self.onLongPress = onLongPress
    }

    private var byDay: [String: Shift] {
        Dictionary(shifts.map { (Self.isoF.string(from: $0.date), $0) }, uniquingKeysWith: { a, _ in a })
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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(months, id: \.self) { month in
                    Section {
                        monthGrid(month)
                    } header: {
                        // Plain black header (matches the calendar background) — no elevated band
                        // slicing the view. Opaque so pinned scrolling still occludes rows cleanly.
                        Text(Self.monthF.string(from: month))
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal).padding(.top, 10).padding(.bottom, 6)
                            .background(Color(.systemBackground))
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
                    Text(h).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
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
        // Scale with Dynamic Type, but cap it so the day cells stay on their grid.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private func gridDays(_ month: Date) -> [Date] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let weekdayIndex = cal.component(.weekday, from: interval.start) - 1
        guard let start = cal.date(byAdding: .day, value: -weekdayIndex, to: interval.start) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    @ViewBuilder private func cell(_ date: Date, month: Date) -> some View {
        let dayID     = Self.isoF.string(from: date)
        let inMonth   = cal.isDate(date, equalTo: month, toGranularity: .month)
        let shift     = byDay[dayID]
        let hasShift  = shift != nil
        let isOff     = shift.map { $0.isOff } ?? true
        let isWorking = hasShift && !isOff
        let today     = cal.startOfDay(for: Date())
        let isToday   = cal.isDate(date, inSameDayAs: today)
        let isPast    = date < today && !isToday
        let faded     = isFaded(isWorking: isWorking, inMonth: inMonth)

        let marker = markerColor(dayID: dayID, isToday: isToday)

        VStack(spacing: 2) {
            ZStack {
                // Gold = high-impact, pink = personal day, blue = today. When today
                // also falls on a marked day, ring the gold/pink circle in blue.
                if let marker {
                    Circle().fill(marker).frame(width: 24, height: 24)
                    if isToday && marker != Color.accentColor {
                        // White gap + blue ring so "today on a marked day" reads on any fill.
                        Circle().stroke(Color(.systemBackground), lineWidth: 2).frame(width: 27, height: 27)
                        Circle().stroke(Color.accentColor, lineWidth: 3).frame(width: 30, height: 30)
                    }
                }
                Text("\(cal.component(.day, from: date))")
                    .font(.headline).fontWeight(isToday ? .black : .semibold)
                    // Dark text on the light gold circle; white on blue/pink.
                    .foregroundStyle(marker == nil ? .primary
                        : (intents.topology(forDay: dayID) == .highDemand ? Color.black.opacity(0.85) : .white))
            }
            .frame(height: 31)
            .contentShape(Circle())
            .onTapGesture {
                if intents.topology(forDay: dayID) != .standard { infoDay = dayID }
                else if inMonth, hasShift { onTap(dayID, isOff) }   // normal day → same as cell tap
            }
            .popover(isPresented: Binding(get: { infoDay == dayID },
                                          set: { if !$0 { infoDay = nil } })) {
                topologyInfo(dayID: dayID)
            }
            dayContent(shift: shift, isWorking: isWorking, isOff: isOff, dayID: dayID)
                .frame(minHeight: 14)
            noteDot(dayID)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(background(dayID: dayID, isToday: isToday, isWorking: isWorking, hasShift: hasShift, date: date, shift: shift))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(borderColor(dayID: dayID, isToday: isToday, isOff: isOff, hasShift: hasShift),
                        lineWidth: flashDays.contains(dayID) ? 3 : borderWidth(dayID: dayID, isOff: isOff))
        )
        .opacity(inMonth ? (faded ? 0.3 : (isPast ? 0.45 : 1)) : 0.12)
        .contentShape(Rectangle())
        .onTapGesture { if inMonth, hasShift { onTap(dayID, isOff) } }
        .onLongPressGesture(minimumDuration: 0.35) { if inMonth, hasShift { onLongPress(dayID, isOff) } }
    }

    @ViewBuilder private func dayContent(shift: Shift?, isWorking: Bool, isOff: Bool, dayID: String) -> some View {
        if isWorking, let shift {
            // Type (AM/PM/MID) and desk are independently toggleable. Both off → blank (the colored day
            // circle still marks it as worked).
            let type = layers.shiftType ? shift.shiftTypeLabel : ""
            let desk = (layers.deskAssignments && !shift.desk.isEmpty) ? shift.desk : ""
            let label = [type, desk].filter { !$0.isEmpty }.joined(separator: " ")
            if label.isEmpty {
                Color.clear.frame(height: 14)
            } else {
                Text(label)
                    .font(.caption.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.6)
            }
        } else if let shift, shift.isVacation {
            // Vacation reads as a distinct teal state, not a plain day off. (U-VAC)
            Image(systemName: "beach.umbrella.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(BrickPalette.vacation)
                .accessibilityLabel("Vacation")
        } else if isOff, layers.availability {
            // A/P/M availability pills on off days — controlled purely by the "Shift
            // availability" layer toggle (the clock button), so it works in the general
            // read-only view too, not just while marking days-off.
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
            let marked = intents.availability(forDay: dayID)
            // Amber only when you're ACTIVELY soliciting (want-to-work); passive
            // "open" availability (bookends/all) reads in a faded slate so an open
            // day off never looks like a want-to-work day.
            let tint = intents.offIntent(forDay: dayID) == .wantToWork
                ? BrickPalette.availableOff : BrickPalette.openOff
            if legal.isEmpty {
                // #1: no legal shift is coverable here (rest / legal-start) → auto-X; can't want-to-work it.
                Image(systemName: "nosign")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BrickPalette.critical.opacity(0.75))
                    .accessibilityLabel("No tradeable shift available")
            } else {
                HStack(spacing: 2) {
                    ForEach(ShiftAvailabilityType.allCases.filter { legal.contains($0) }, id: \.self) { t in
                        let on = marked.contains(t)
                        Text(String(t.rawValue.prefix(1)))
                            .font(.system(size: 9, weight: .black))   // fixed: the A/P/M pill is a compact glyph
                            .foregroundStyle(on ? .white : tint.opacity(0.8))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(on ? tint : Color.clear))
                            .overlay(Circle().stroke(tint.opacity(on ? 0 : 0.6), lineWidth: 1.5))
                    }
                }
            }
        }
    }

    @ViewBuilder private func noteDot(_ dayID: String) -> some View {
        if layers.notes, let note = intents.note(forDay: dayID) {
            NoteMarker(note: note)
        } else if layers.notes, let holiday = Holidays.name(forDay: dayID) {
            // Auto-label the event for high-demand holidays.
            EventMarker(name: holiday, color: BrickPalette.warning, icon: "exclamationmark.triangle.fill")
        } else if layers.notes, intents.topology(forDay: dayID) == .personalMilestone {
            EventMarker(name: "Personal milestone", color: BrickPalette.milestone, icon: "star.fill")
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
            // Explicit per-day intent wins over the blacklist Blackout tint (B4-3 precedence).
            if let tint = intentTint(dayID: dayID, isWorking: isWorking) { return tint }
            if let bo = blackoutTint(date: date, shift: shift) { return bo }
        }
        if !hasShift { return Color(.systemGray6) }
        return isWorking ? Color.accentColor.opacity(0.20) : Color(.systemGray5)
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
            guard let s = intents.workingIntent(forDay: dayID) else { return nil }
            return s.brickColor.opacity(0.62)
        } else {
            // must-be-off is shown by the red ⊗ marker, not a fill.
            guard let s = intents.offIntent(forDay: dayID), s != .mustBeOff else { return nil }
            // Passive "open" is the faintest; an active want-to-work off day is a bit stronger.
            return s.brickColor.opacity(s == .wantToWork ? 0.45 : 0.30)
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

    /// Gold for a high-demand day, pink for a personal day, blue (accent) for today.
    /// Today is only the fallback when the day isn't otherwise marked.
    private func markerColor(dayID: String, isToday: Bool) -> Color? {
        switch intents.topology(forDay: dayID) {
        case .highDemand:        return BrickPalette.highImpact
        case .personalMilestone: return BrickPalette.personalDay
        case .standard:          return isToday ? Color.accentColor : nil
        }
    }

    private func borderColor(dayID: String, isToday: Bool, isOff: Bool, hasShift: Bool) -> Color {
        // High-impact / personal days now read as gold/pink circles, not borders.
        flashDays.contains(dayID) ? BrickPalette.warning : .clear
    }

    private func borderWidth(dayID: String, isOff: Bool) -> CGFloat { 0 }
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
    private var blackout: Color { OffIntentState.mustBeOff.brickColor }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(!enabled ? Color.secondary.opacity(0.45) : (selected ? .white : .primary))
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(!enabled ? Color(.tertiarySystemFill).opacity(0.4)
                                     : (selected ? blackout : Color(.tertiarySystemFill)),
                            in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
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
                Picker("", selection: $tab) {
                    Text("Profile").tag(0)
                    Text("Trade Settings").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if tab == 0 { profile } else { tradeSettings }
            }
            .navigationTitle("Trade Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
                let q = await RosterStore.shared.schedule(forWorker: settings.username).first?.quals ?? []
                if !q.isEmpty { myQuals = q; settings.cachedQuals = q }
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
