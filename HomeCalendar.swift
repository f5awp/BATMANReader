// HomeCalendar.swift
// The interactive intent calendar + per-day editor + Trade Settings sheet used by
// HomeView. The grid layout descends from ScheduleCalendarView; cells add tap /
// long-press and draw intent overlays from DayIntentStore.

import SwiftUI

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
            Text("\(cal.component(.day, from: date))")
                .font(.system(size: isToday ? 16 : 13, weight: isToday ? .black : .medium))
            label(for: shift, isWorking: isWorking)
                .frame(minHeight: 14)
            noteDot(dayID)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isToday ? 9 : 7)
        .background(background(dayID: dayID, isToday: isToday, isWorking: isWorking, hasShift: hasShift))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(borderColor(dayID: dayID, isToday: isToday, isOff: isOff, hasShift: hasShift),
                        lineWidth: flashDays.contains(dayID) ? 3 : (isToday ? 2 : borderWidth(dayID: dayID, isOff: isOff)))
        )
        .opacity(inMonth ? (faded ? 0.3 : (isPast ? 0.45 : 1)) : 0.12)
        .contentShape(Rectangle())
        .onTapGesture { if inMonth, hasShift { onTap(dayID, isOff) } }
        .onLongPressGesture(minimumDuration: 0.35) { if inMonth, hasShift { onLongPress(dayID, isOff) } }
    }

    @ViewBuilder private func label(for shift: Shift?, isWorking: Bool) -> some View {
        if isWorking, let shift {
            if layers.shiftCircles {
                Text(shift.shiftLetter)
                    .font(.system(size: 11, weight: .heavy))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor.opacity(0.22)))
            } else {
                Text(shift.shiftShortLabel)
                    .font(.system(size: 11, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
            }
        } else {
            Color.clear.frame(height: 14)
        }
    }

    @ViewBuilder private func noteDot(_ dayID: String) -> some View {
        if layers.notes, intents.note(forDay: dayID) != nil {
            Circle().fill(.blue).frame(width: 5, height: 5)
        } else {
            Color.clear.frame(height: 5)
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
        if isToday { return Color.yellow.opacity(0.5) }
        if layers.intentOverlays, let tint = intentTint(dayID: dayID, isWorking: isWorking) { return tint }
        if !hasShift { return Color(.systemGray6) }
        return isWorking ? Color.accentColor.opacity(0.14) : Color(.systemGray5)
    }

    /// Purple/green/red intent fill, or nil when the day has no explicit intent.
    private func intentTint(dayID: String, isWorking: Bool) -> Color? {
        if isWorking {
            switch intents.workingIntent(forDay: dayID) {
            case .dontWantToWork: return Color.purple.opacity(0.30)
            case .mustWork:       return Color.red.opacity(0.20)
            case .wantToWork:     return Color.green.opacity(0.20)
            case .neutralOpen:    return Color.gray.opacity(0.18)
            case .none:           return nil
            }
        } else {
            switch intents.offIntent(forDay: dayID) {
            case .wantToWork:  return Color.green.opacity(0.28)
            case .mustBeOff:   return Color.red.opacity(0.16)
            case .neutralOpen: return Color.gray.opacity(0.18)
            case .none:        return nil
            }
        }
    }

    private func borderColor(dayID: String, isToday: Bool, isOff: Bool, hasShift: Bool) -> Color {
        if flashDays.contains(dayID) { return .orange }
        if isToday { return .orange }
        if hasShift, isOff, intents.offIntent(forDay: dayID) == .mustBeOff { return .red }
        if intents.topology(forDay: dayID) != .standard { return .indigo }
        return .clear
    }

    private func borderWidth(dayID: String, isOff: Bool) -> CGFloat {
        if isOff, intents.offIntent(forDay: dayID) == .mustBeOff { return 1.5 }
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
    @State private var topology: DayTopology = .standard
    @State private var noteText = ""
    @State private var notePrivate = false

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
                            get: { working ?? .neutralOpen },
                            set: { working = $0 })) {
                            ForEach(WorkingIntentState.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }

                Section("Reason (optional)") {
                    Picker("Reason", selection: Binding(
                        get: { reason },
                        set: { reason = $0 })) {
                        Text("None").tag(IntentReason?.none)
                        ForEach(IntentReason.allCases) { Text($0.label).tag(IntentReason?.some($0)) }
                    }
                }

                Section("Calendar gravity") {
                    Picker("Topology", selection: $topology) {
                        ForEach(DayTopology.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section("Note (≤ 50 chars)") {
                    TextField("Short note", text: $noteText)
                        .onChange(of: noteText) { _, v in if v.count > 50 { noteText = String(v.prefix(50)) } }
                    Toggle("Private (never shared)", isOn: $notePrivate)
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
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        working = intents.workingIntent(forDay: target.dayID)
        off = intents.offIntent(forDay: target.dayID)
        topology = intents.topology(forDay: target.dayID)
        if let n = intents.note(forDay: target.dayID) {
            noteText = n.message; notePrivate = n.isPrivate; reason = n.reason
        }
    }

    private func save() {
        if target.isOff { intents.setOffIntent(off, forDay: target.dayID) }
        else { intents.setWorkingIntent(working, forDay: target.dayID) }
        intents.setTopology(topology, forDay: target.dayID)
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        intents.setNote(trimmed.isEmpty ? nil
                        : DayNote(dayID: target.dayID, message: trimmed, reason: reason, isPrivate: notePrivate),
                        forDay: target.dayID)
        dismiss()
    }
}

// MARK: - Tabbed Trade Settings sheet

struct TradeSettingsSheet: View {
    @Bindable private var settings = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var capWeeklyHours: Bool = SettingsManager.shared.maxWeeklyHours != nil

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
                    Text("Profile & Rules").tag(0)
                    Text("Calendar Gravity").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if tab == 0 { profileAndRules } else { calendarGravity }
            }
            .navigationTitle("Trade Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder private var profileAndRules: some View {
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
        Section("Status (140 chars, public)") {
            TextField("e.g. \"Happy to take weekend PMs\"", text: Binding(
                get: { settings.statusBroadcast },
                set: { settings.statusBroadcast = String($0.prefix(140)) }), axis: .vertical)
                .lineLimit(1...3)
        }
    }

    @ViewBuilder private var calendarGravity: some View {
        Section {
            TextField("e.g. 29, 82", text: deskText)
                .autocorrectionDisabled().textInputAutocapitalization(.characters)
        } header: {
            Text("Blacklisted desks")
        } footer: {
            Text("You won't be offered automated pickups on these desks. High-Demand and Personal Milestone dates are set by long-pressing a date on the calendar.")
        }
    }
}
