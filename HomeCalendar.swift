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
    private static let minRest: TimeInterval = 8 * 3600
    private static let shiftLen: TimeInterval = 9 * 3600

    static func legalTypes(forDayID dayID: String, shifts: [Shift]) -> Set<ShiftAvailabilityType> {
        let cal = Calendar.current
        guard let day = isoF.date(from: dayID).map({ cal.startOfDay(for: $0) }) else { return [] }
        let byDay = Dictionary(shifts.map { (isoF.string(from: $0.date), $0) }, uniquingKeysWith: { a, _ in a })
        func shift(_ offset: Int) -> Shift? {
            guard let d = cal.date(byAdding: .day, value: offset, to: day) else { return nil }
            return byDay[isoF.string(from: d)]
        }
        let prev = shift(-1), next = shift(1)

        var legal = Set<ShiftAvailabilityType>()
        for t in ShiftAvailabilityType.allCases {
            guard let coverStart = cal.date(byAdding: .hour, value: t.startHour, to: day) else { continue }
            let coverEnd = coverStart.addingTimeInterval(shiftLen)
            var ok = true
            if let p = prev, !p.isOff {
                let pStart = cal.date(byAdding: .hour, value: p.startHour, to: cal.startOfDay(for: p.date)) ?? p.date
                if coverStart.timeIntervalSince(pStart.addingTimeInterval(shiftLen)) < minRest { ok = false }
            }
            if let n = next, !n.isOff {
                let nStart = cal.date(byAdding: .hour, value: n.startHour, to: cal.startOfDay(for: n.date)) ?? n.date
                if nStart.timeIntervalSince(coverEnd) < minRest { ok = false }
            }
            if ok { legal.insert(t) }
        }
        return legal
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
                        Text(Self.monthF.string(from: month))
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal).padding(.vertical, 6)
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
        .background(background(dayID: dayID, isToday: isToday, isWorking: isWorking, hasShift: hasShift))
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
            Text(shift.shiftShortLabel)
                .font(.caption.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.6)
        } else if isOff, mode == .daysOff {
            // A/P/M availability pills appear only while you're marking days-off
            // intents — the resting calendar stays clean.
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
                Color.clear.frame(height: 14)
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

    private func background(dayID: String, isToday: Bool, isWorking: Bool, hasShift: Bool) -> Color {
        if layers.intentOverlays, let tint = intentTint(dayID: dayID, isWorking: isWorking) { return tint }
        if !hasShift { return Color(.systemGray6) }
        return isWorking ? Color.accentColor.opacity(0.20) : Color(.systemGray5)
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
                                Text($0 == .mustWork ? "Keep" : $0.label).tag($0)
                            }
                        }
                    }
                }

                Section {
                    TextField("Why? (free text)", text: $reasonText, axis: .vertical)
                        .lineLimit(1...3)
                    if let reason {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").foregroundStyle(.purple)
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
                    TextField("Short note", text: $noteText)
                        .onChange(of: noteText) { _, v in if v.count > 50 { noteText = String(v.prefix(50)) } }
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

// MARK: - Tabbed Trade Settings sheet

struct TradeSettingsSheet: View {
    @Bindable private var settings = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var capWeeklyHours: Bool = SettingsManager.shared.maxWeeklyHours != nil
    @State private var myQuals: [String] = []
    @State private var showOverrideEditor = false
    @State private var editingNotes = false

    /// Re-run the base openness shortcut (which layers in the date-range overrides)
    /// and re-publish. Call after any override change.
    private func reapplyOpenness() {
        let level = TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends
        DayIntentStore.shared.applyOpenness(level, shifts: ShiftStore.shared.shifts)
        Task { await TradeProfileStore.shared.publishMine() }
    }

    private var openness: Binding<TradeOpenness> {
        Binding(get: { TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends },
                set: { level in
                    settings.tradeOpenness = level.rawValue
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
                myQuals = await RosterStore.shared.schedule(forWorker: settings.username)
                    .first?.quals ?? []
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
            TextField("e.g. \"Happy to take weekend PMs\"", text: Binding(
                get: { settings.statusBroadcast },
                set: { settings.statusBroadcast = String($0.prefix(140)) }), axis: .vertical)
                .lineLimit(1...3)
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
        Section("Weekly hours") {
            Toggle("Cap weekly hours", isOn: $capWeeklyHours)
            if capWeeklyHours {
                Stepper("Max: \(settings.maxWeeklyHours ?? 40)h",
                        value: Binding(get: { settings.maxWeeklyHours ?? 40 },
                                       set: { settings.maxWeeklyHours = $0 }), in: 9...80, step: 9)
            } else {
                Color.clear.frame(height: 0).onAppear { settings.maxWeeklyHours = nil }
            }
        }
        Section {
            TextField("e.g. 29, 82", text: deskText)
                .autocorrectionDisabled().textInputAutocapitalization(.characters)
        } header: {
            Text("Blacklisted desks")
        } footer: {
            Text("You won't be offered automated pickups on these desks.")
        }
        Section("Blacklisted shift types") {
            ForEach(ShiftAvailabilityType.allCases, id: \.self) { type in
                Toggle(type.rawValue, isOn: Binding(
                    get: { settings.blacklistedShiftTypes.contains(type.rawValue) },
                    set: { on in
                        if on { settings.blacklistedShiftTypes.insert(type.rawValue) }
                        else { settings.blacklistedShiftTypes.remove(type.rawValue) }
                    }))
            }
        }
        Section {
            ForEach(DeskRegion.allCases, id: \.self) { region in
                Toggle(region.rawValue, isOn: Binding(
                    get: { settings.blacklistedRegions.contains(region.rawValue) },
                    set: { on in
                        if on { settings.blacklistedRegions.insert(region.rawValue) }
                        else { settings.blacklistedRegions.remove(region.rawValue) }
                    }))
            }
        } header: {
            Text("Blacklisted regions")
        } footer: {
            Text("High-Demand and Personal Milestone dates are set by long-pressing a date on the calendar.")
        }
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
                        set: { settings.privateNotes = String($0.prefix(2000)) }))
                        .frame(minHeight: 220)
                } footer: {
                    Text("Stored on your device only and never shared. \(settings.privateNotes.count)/2000")
                }
            }
            .navigationTitle("Private Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
