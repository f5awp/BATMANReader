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

// MARK: - Interactive month calendar with intent overlays

struct IntentCalendarView: View {
    let shifts: [Shift]
    let mode: IntentMode
    let layers: LayerVisibility
    let flashDays: Set<String>
    let onTap: (_ dayID: String, _ isOff: Bool) -> Void
    let onLongPress: (_ dayID: String, _ isOff: Bool) -> Void

    private var intents = DayIntentStore.shared
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

        VStack(spacing: 2) {
            ZStack {
                if isToday { Circle().fill(Color.accentColor).frame(width: 24, height: 24) }
                Text("\(cal.component(.day, from: date))")
                    .font(.system(size: 16, weight: isToday ? .black : .semibold))
                    .foregroundStyle(isToday ? .white : .primary)
            }
            .frame(height: 24)
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
                .font(.system(size: 11, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
        } else if isOff, layers.availability {
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
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(BrickPalette.critical)
        } else {
            let legal = Legality.legalTypes(forDayID: dayID, shifts: shifts)
            let marked = intents.availability(forDay: dayID)
            if legal.isEmpty {
                Color.clear.frame(height: 14)
            } else {
                HStack(spacing: 1) {
                    ForEach(ShiftAvailabilityType.allCases.filter { legal.contains($0) }, id: \.self) { t in
                        Text(String(t.rawValue.prefix(1)))
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(marked.contains(t) ? BrickPalette.availableOff : Color.secondary.opacity(0.35))
                    }
                }
            }
        }
    }

    @ViewBuilder private func noteDot(_ dayID: String) -> some View {
        if layers.notes, let note = intents.note(forDay: dayID) {
            NoteMarker(note: note)
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
    private func intentTint(dayID: String, isWorking: Bool) -> Color? {
        if isWorking {
            guard let s = intents.workingIntent(forDay: dayID) else { return nil }
            return s.brickColor.opacity(0.62)
        } else {
            // must-be-off is shown by the red ⊗ marker, not a fill.
            guard let s = intents.offIntent(forDay: dayID), s != .mustBeOff else { return nil }
            return s.brickColor.opacity(0.58)
        }
    }

    private func borderColor(dayID: String, isToday: Bool, isOff: Bool, hasShift: Bool) -> Color {
        if flashDays.contains(dayID) { return BrickPalette.warning }
        let topo = intents.topology(forDay: dayID)
        if topo != .standard { return topo.accent }
        return .clear
    }

    private func borderWidth(dayID: String, isOff: Bool) -> CGFloat {
        if intents.topology(forDay: dayID) != .standard { return 1.5 }
        return 0
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
                            Text("Categorized as \(reason.label)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Reason")
                } footer: {
                    Text("Type it naturally — it's categorized automatically on save.")
                }

                Section {
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
    @State private var notesExpanded = false
    @State private var myQuals: [String] = []

    private var openness: Binding<TradeOpenness> {
        Binding(get: { TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends },
                set: { settings.tradeOpenness = $0.rawValue })
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
            .task {
                myQuals = await RosterStore.shared.schedule(forWorker: settings.username)
                    .first?.quals ?? []
            }
        }
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
            DisclosureGroup("Private notes", isExpanded: $notesExpanded) {
                TextEditor(text: Binding(
                    get: { settings.privateNotes },
                    set: { settings.privateNotes = String($0.prefix(2000)) }))
                    .frame(minHeight: 120)
            }
        } footer: {
            Text("Private notes are stored on your device only and never shared.")
        }
    }

    // MARK: Trade Settings tab

    @ViewBuilder private var tradeSettings: some View {
        Section("Openness") {
            Picker("Accepting", selection: openness) {
                ForEach(TradeOpenness.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("Mercenary mode (take any qualifying shift)", isOn: $settings.isMercenaryMode)
            Toggle("Protect days off (chaining)", isOn: $settings.prioritizeChaining)
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
