// AvailabilityView.swift
// Two-section view:
//   1. My Availability — edit your off-day availability type per day
//   2. Find Candidates — pick a date + shift type, see who's available,
//      message them directly or via Shortcuts

import SwiftUI
import UIKit

struct AvailabilityView: View {

    private let manager  = AvailabilityManager.shared
    private let settings = SettingsManager.shared

    @State private var selectedSegment = 0  // 0 = My Availability, 1 = Find Candidates

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedSegment) {
                    Text("My Availability").tag(0)
                    Text("Find Candidates").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                if selectedSegment == 0 {
                    MyAvailabilitySection()
                } else {
                    FindCandidatesSection()
                }
            }
            .navigationTitle("Availability")
            .navigationBarTitleDisplayMode(.large)
            .overlay {
                if !settings.sharedCalendarEnabled {
                    sharedCalendarPrompt
                }
            }
        }
    }

    private var sharedCalendarPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Shared Calendar Not Enabled")
                .font(.headline)
            Text("Enable the shared dispatcher calendar in Settings to see and share availability.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - My Availability

struct MyAvailabilitySection: View {

    private let manager = AvailabilityManager.shared
    private let store   = ShiftStore.shared
    private var intent  = TradeIntentStore.shared

    @State private var showSeekingCalendar = false

    var body: some View {
        List {
            Section("Trade preferences") {
                TradePrefsBox()
            }

            Section {
                if store.shifts.contains(where: { !$0.isOff }) {
                    Button { showSeekingCalendar = true } label: {
                        HStack {
                            Label("Days I want to trade away", systemImage: "calendar.badge.plus")
                            Spacer()
                            if !intent.seekingDayIDs.isEmpty {
                                Text("\(intent.seekingDayIDs.count)")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                } else {
                    Text("Import your schedule to mark days you want to trade away.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Mark the working days across the year you actively want to give away. Once cloud sync is enabled these are shared so others can offer to cover or swap.")
            }

            if manager.myAvailability.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Off Days",
                        systemImage: "calendar.badge.clock",
                        description: Text("Import your schedule to populate your off days.")
                    )
                }
            } else {
                Section("Your upcoming off days") {
                    ForEach(manager.myAvailability) { day in
                        AvailabilityRow(day: day)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .onAppear {
            intent.pruneExpired(using: store.shifts)
            Task { await TradeProfileStore.shared.publishMine() }
        }
        .sheet(isPresented: $showSeekingCalendar) { SeekingDaysSheet() }
    }
}

// MARK: - Days-to-trade-away calendar (sheet)

/// A full-screen month-navigable calendar (outside any List, so taps + month
/// navigation stay smooth) for marking the working days you want to give away.
struct SeekingDaysSheet: View {

    private let store  = ShiftStore.shared
    private var intent = TradeIntentStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text("Tap the working days you actively want to trade away. Use the month arrows to reach any week of the year.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ShiftSelectCalendar(shifts: store.shifts, selection: Binding(
                        get: { intent.seekingDayIDs },
                        set: { intent.seekingDayIDs = $0 }
                    ))

                    if !intent.seekingDayIDs.isEmpty {
                        Text("^[\(intent.seekingDayIDs.count) day](inflect: true) marked")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("Days to Trade Away")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { intent.seekingDayIDs = [] }
                        .disabled(intent.seekingDayIDs.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Trade preferences box (openness + blacklist)

struct TradePrefsBox: View {
    @Bindable private var settings = SettingsManager.shared
    @State private var showBlacklist = false

    private var openness: Binding<TradeOpenness> {
        Binding(
            get: { TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends },
            set: { settings.tradeOpenness = $0.rawValue; AvailabilityManager.shared.buildFromSchedule() }
        )
    }
    private var deskText: Binding<String> {
        Binding(
            get: { settings.blacklistedDesks.sorted().joined(separator: ", ") },
            set: { newValue in
                settings.blacklistedDesks = Set(newValue
                    .split { $0 == "," || $0 == " " }
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty })
            }
        )
    }

    private static let weekdaySymbols = Calendar.current.weekdaySymbols   // ["Sunday"…"Saturday"]

    var body: some View {
        Picker(selection: openness) {
            ForEach(TradeOpenness.allCases, id: \.self) { Text($0.label).tag($0) }
        } label: {
            Label("Openness", systemImage: "arrow.triangle.2.circlepath")
        }
        .pickerStyle(.menu)

        DisclosureGroup("Blacklist — never pick up", isExpanded: $showBlacklist) {
            ForEach(["AM", "PM", "MID"], id: \.self) { type in
                Toggle("No \(type) shifts", isOn: typeBinding(type))
            }
            ForEach(["Domestic", "European", "Latin America", "Pacific"], id: \.self) { region in
                Toggle("No \(region) desks", isOn: regionBinding(region))
            }
            ForEach(1...7, id: \.self) { wd in
                Toggle("No \(Self.weekdaySymbols[wd - 1])s", isOn: weekdayBinding(wd))
            }
            LabeledContent("Desks to avoid") {
                TextField("e.g. 29, 82", text: deskText)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
            }
        }
    }

    private func weekdayBinding(_ wd: Int) -> Binding<Bool> {
        Binding(
            get: { settings.blacklistedWeekdays.contains(wd) },
            set: { on in
                if on { settings.blacklistedWeekdays.insert(wd) } else { settings.blacklistedWeekdays.remove(wd) }
                AvailabilityManager.shared.buildFromSchedule()
            }
        )
    }
    private func typeBinding(_ t: String) -> Binding<Bool> {
        Binding(
            get: { settings.blacklistedShiftTypes.contains(t) },
            set: { on in
                if on { settings.blacklistedShiftTypes.insert(t) } else { settings.blacklistedShiftTypes.remove(t) }
                AvailabilityManager.shared.buildFromSchedule()
            }
        )
    }
    private func regionBinding(_ r: String) -> Binding<Bool> {
        Binding(
            get: { settings.blacklistedRegions.contains(r) },
            set: { on in if on { settings.blacklistedRegions.insert(r) } else { settings.blacklistedRegions.remove(r) } }
        )
    }
}

struct AvailabilityRow: View {

    let day: DayAvailability
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack {
                // Date
                VStack(alignment: .leading, spacing: 3) {
                    Text(day.formattedDate)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(day.isAvailable ? "Available to cover" : "Not Available")
                        .font(.caption)
                        .foregroundStyle(day.isAvailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }

                Spacer()

                // Availability badges — one per offered shift type
                if day.isAvailable {
                    HStack(spacing: 4) {
                        ForEach(day.sortedTypes, id: \.self) { type in
                            Text(type.rawValue)
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(availabilityColor(type).opacity(0.15))
                                .foregroundStyle(availabilityColor(type))
                                .clipShape(Capsule())
                        }
                    }
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .confirmationDialog(
            "Availability for \(day.formattedDate)",
            isPresented: $showPicker,
            titleVisibility: .visible
        ) {
            ForEach(ShiftAvailabilityType.allCases, id: \.self) { type in
                Button((day.availableTypes.contains(type) ? "Remove " : "Add ") + type.calendarLabel) {
                    AvailabilityManager.shared.toggleType(type, on: day.id)
                }
            }
            Button("Not Available (clear all)", role: .destructive) {
                AvailabilityManager.shared.disableDay(day.id)
            }
            Button("Reset to default") {
                AvailabilityManager.shared.resetDay(day.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func availabilityColor(_ type: ShiftAvailabilityType) -> Color {
        switch type {
        case .am:  return .orange
        case .pm:  return .indigo
        case .mid: return .purple
        }
    }
}

// MARK: - Find Candidates

struct FindCandidatesSection: View {

    private let store    = ShiftStore.shared
    private let settings = SettingsManager.shared
    private var intent   = TradeIntentStore.shared

    @State private var selectedIDs: Set<String> = []
    @State private var candidates: [PlanCandidate] = []
    @State private var selected: Set<String> = []      // candidates chosen for messaging
    @State private var bookendsOnly = false
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var calendarExpanded = true
    @State private var twoWayCandidate: PlanCandidate?

    private var hasShifts: Bool { !store.upcomingWorkingShifts().isEmpty }
    private var selectedShifts: [Shift] {
        store.shifts.filter { selectedIDs.contains($0.id) }.sorted { $0.date < $1.date }
    }
    private var displayed: [PlanCandidate] {
        bookendsOnly ? candidates.filter { $0.bookendCount > 0 } : candidates
    }
    private let resultColumns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .sheet(item: $twoWayCandidate) { c in
            TwoWaySheet(candidate: c)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if !hasShifts {
                Text("Import your schedule to pick shifts to trade away.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Trading away").font(.caption2).foregroundStyle(.secondary)
                        Text(selectedIDs.isEmpty
                             ? "Tap days on the calendar"
                             : "\(selectedIDs.count) shift\(selectedIDs.count == 1 ? "" : "s") selected")
                            .font(.subheadline).bold().lineLimit(1)
                    }
                    Spacer()
                    Button { Task { await search() } } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(selectedIDs.isEmpty || isSearching)

                    Button { withAnimation(.snappy) { calendarExpanded.toggle() } } label: {
                        Image(systemName: calendarExpanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(calendarExpanded ? "Collapse calendar" : "Expand calendar")
                }

                if calendarExpanded {
                    ShiftSelectCalendar(shifts: store.shifts, selection: $selectedIDs)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            ProgressView("Searching roster…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasSearched {
            ContentUnavailableView("Pick Shifts to Trade", systemImage: "person.2.badge.gearshape",
                description: Text("Tap the days you want to give away, then Find. (Import the roster file first.)"))
        } else if candidates.isEmpty {
            ContentUnavailableView("No Matches", systemImage: "person.slash",
                description: Text("No off, qualified, rested dispatcher matched these shifts."))
        } else {
            VStack(spacing: 0) {
                resultsHeader
                ScrollView {
                    // Many selected shifts → 1 full-width column so the coverage
                    // grid has room; few → dense 2-column.
                    LazyVGrid(columns: resultColumns, spacing: 6) {
                        ForEach(displayed) { c in
                            PlanCandidateCell(candidate: c, selectedShifts: selectedShifts,
                                              total: selectedShifts.count,
                                              isSelected: selected.contains(c.id),
                                              onTap: { toggle(c.id) },
                                              onEnter: { twoWayCandidate = c })
                        }
                    }
                    .padding(8)
                }
                messageBar
            }
        }
    }

    private var resultsHeader: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $bookendsOnly) {
                Label("Bookends", systemImage: "book.fill").font(.caption2)
            }
            .toggleStyle(.button).controlSize(.mini).tint(Color(red: 0.16, green: 0.46, blue: 0.22))

            Spacer()
            Text("\(displayed.count) matched").font(.caption).foregroundStyle(.secondary)
            Spacer()

            Button(allSelected ? "Clear" : "All") { toggleAll() }.font(.caption)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }

    private var messageBar: some View {
        Button { messageSelected() } label: {
            Label("Message \(selectedCount) selected", systemImage: "message.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedCount == 0)
        .padding(10)
        .background(.bar)
    }

    private var selectedCount: Int { displayed.filter { selected.contains($0.id) }.count }
    private var allSelected: Bool { !displayed.isEmpty && displayed.allSatisfy { selected.contains($0.id) } }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    private func toggleAll() {
        if allSelected { displayed.forEach { selected.remove($0.id) } }
        else { displayed.forEach { selected.insert($0.id) } }
    }

    private func search() async {
        let shifts = selectedShifts
        guard !shifts.isEmpty else { return }
        isSearching = true
        selected = []

        let able = await TradeMatcher.candidatesForTrades(shifts: shifts, excluding: settings.username)
        await TradeProfileStore.shared.refreshOthers()
        let profiles = TradeProfileStore.shared

        // Annotate each able candidate with their published willingness; drop
        // anyone who's opted in but won't take any of these shifts. No profile =
        // unknown (kept, ranked below the willing).
        var annotated: [PlanCandidate] = able.compactMap { c in
            let covered = shifts.filter { c.coveredShiftIDs.contains($0.id) }
            let w = TradeProfile.classify(coveredShifts: covered,
                                          bookendIDs: c.bookendShiftIDs,
                                          profile: profiles.profile(forWorker: c.workerID))
            guard w != .declined else { return nil }
            var x = c
            x.willingness = w
            return x
        }

        // 🔥×N gold — A (your give-away days they'd take) + B (their wanted days
        // you'd take), gated by the receiving side's openness + blacklist. The
        // give-away set is your year-round marks PLUS the days selected in this
        // search. Computed only for candidates who've published a profile.
        let mySeeking = DayIntentStore.shared.seekingDayIDs
        var giveByID: [String: Shift] = [:]
        for s in shifts { giveByID[s.id] = s }                                   // this search's selection
        for s in store.shifts where mySeeking.contains(s.id) { giveByID[s.id] = s } // year-round marks
        let myGiveShifts = Array(giveByID.values)
        let myEntries = await RosterStore.shared.schedule(forWorker: settings.username)
        let myProfile = profiles.myProfile()
        for i in annotated.indices {
            guard let theirProfile = profiles.profile(forWorker: annotated[i].workerID) else { continue }
            annotated[i].twoWayCount = await TradeMatcher.goldCount(
                workerID: annotated[i].workerID, myGiveShifts: myGiveShifts,
                theirProfile: theirProfile, myProfile: myProfile, myEntries: myEntries)
        }

        candidates = annotated.sorted {
            if $0.twoWayCount != $1.twoWayCount { return $0.twoWayCount > $1.twoWayCount }
            if $0.willingness.rank != $1.willingness.rank { return $0.willingness.rank < $1.willingness.rank }
            if $0.bookendCount != $1.bookendCount { return $0.bookendCount > $1.bookendCount }
            if $0.matchCount != $1.matchCount { return $0.matchCount > $1.matchCount }
            return $0.name < $1.name
        }

        isSearching = false
        hasSearched = true
        withAnimation(.snappy) { calendarExpanded = false }
    }

    private func messageSelected() {
        let chosen = displayed.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let dayList = selectedShifts.map { "\(Self.weekday($0.date)) \($0.formattedDate) (\($0.title))" }.joined(separator: "; ")
        let names = chosen.map { $0.name }.joined(separator: ", ")
        let body = "Hi — looking to trade away: \(dayList). Reaching out to: \(names). Let me know what you can take!"
        let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "sms:?body=\(encoded)") { UIApplication.shared.open(url) }
    }

    static func weekday(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: date)
    }
}

struct PlanCandidateCell: View {
    let candidate: PlanCandidate
    let selectedShifts: [Shift]
    let total: Int
    let isSelected: Bool
    let onTap: () -> Void
    let onEnter: () -> Void

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showMatchDates = false

    private let bookendGreen = Color(red: 0.16, green: 0.46, blue: 0.22)
    private let seekingGold  = Color(red: 0.80, green: 0.60, blue: 0.10)

    /// The traded-away shifts this candidate covers as a clean bookend — the
    /// dates the 📖 badge is counting.
    private var bookendShifts: [Shift] {
        selectedShifts.filter { candidate.bookendShiftIDs.contains($0.id) }
    }

    /// Gold = has mutual two-way swaps, green = bookend match, else none.
    private var borderColor: Color {
        if candidate.twoWayCount > 0 { return seekingGold }
        return candidate.bookendCount > 0 ? bookendGreen : .clear
    }

    var body: some View {
        Group {
            if hSize == .compact { compactRow } else { regularRow }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.blue.opacity(0.10) : Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    // iPhone: name on its own line; small 📖/🔥 icons beneath it. No mini, no "covers" line.
    private var compactRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                HStack(spacing: 10) {
                    if !candidate.quals.isEmpty {
                        Text(candidate.quals.joined(separator: " "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    smallBook
                    flameOrUnknown
                }
            }
            Spacer(minLength: 4)
            selectionCheck
            enterButton
        }
    }

    // iPad: big book badge left, name + quals + "covers", mini-schedule on the right.
    private var regularRow: some View {
        HStack(spacing: 10) {
            if candidate.bookendCount > 0 {
                Button { showMatchDates = true } label: {
                    VStack(spacing: 0) {
                        Text("📖").font(.system(size: 24))
                        Text("×\(candidate.bookendCount)")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(bookendGreen)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showMatchDates) {
                    MatchDatesPopover(name: candidate.name, shifts: bookendShifts)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(candidate.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    flameOrUnknown
                }
                Text(candidate.quals.joined(separator: " "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Text("covers \(candidate.matchCount) of \(total)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if candidate.week.isEmpty {
                CoverageStrip(shifts: selectedShifts, covered: candidate.coveredShiftIDs)
            } else {
                MiniSchedule(week: candidate.week)
            }
            selectionCheck
            enterButton
        }
    }

    // Small 📖×N badge (tappable for the match-dates popover) used in the compact row.
    @ViewBuilder private var smallBook: some View {
        if candidate.bookendCount > 0 {
            Button { showMatchDates = true } label: {
                HStack(spacing: 1) {
                    Text("📖").font(.system(size: 12))
                    Text("×\(candidate.bookendCount)").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(bookendGreen)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showMatchDates) {
                MatchDatesPopover(name: candidate.name, shifts: bookendShifts)
            }
        }
    }

    @ViewBuilder private var flameOrUnknown: some View {
        if candidate.twoWayCount > 0 {
            HStack(spacing: 1) {
                Image(systemName: "flame.fill").font(.system(size: 11))
                Text("×\(candidate.twoWayCount)").font(.system(size: 12, weight: .heavy))
            }
            .foregroundStyle(seekingGold)
        } else if candidate.willingness == .unknown {
            Image(systemName: "questionmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var selectionCheck: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.blue)
        }
    }

    private var enterButton: some View {
        Button(action: onEnter) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.title3).foregroundStyle(.blue.opacity(0.85))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Find two-way swaps with \(candidate.name)")
    }
}

/// Lists the dates a candidate covers as bookends — shown when the 📖 badge is tapped.
struct MatchDatesPopover: View {
    let name: String
    let shifts: [Shift]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(name) — bookend matches")
                .font(.headline)
            ForEach(shifts.sorted { $0.date < $1.date }) { s in
                HStack(spacing: 6) {
                    Text("📖").font(.caption2)
                    Text(s.weekdayDate)
                    Text(s.shiftShortLabel).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
        .padding(16)
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - Two-way swap explorer (sheet)

/// Opens on top of the one-way page for one dispatcher: a 4-month-at-a-time,
/// paginated list of feasible BOOKEND swaps — their work days you could cover and
/// your work days they could cover, all bookends. 🔥 marks days the owner has
/// actively marked to trade away (mutual intent).
struct TwoWaySheet: View {
    let candidate: PlanCandidate

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var full: TwoWayPlan?         // whole-horizon results, filtered client-side
    @State private var loading = true
    @State private var windowIndex = 0           // each step = 4 months ahead
    @State private var myDays: [String: String] = [:]      // ISO → A/P/M (mini glance)
    @State private var theirDays: [String: String] = [:]
    @State private var monthIndex = 0                       // month offset shown in the glance
    @State private var sentConfirmation = false
    @State private var selectedTake: Set<String> = []       // their days you'll take
    @State private var selectedGive: Set<String> = []       // your days they'll take
    @State private var zoom: CGFloat = 1

    private var glanceBaseHeight: CGFloat { hSize == .compact ? 360 : 176 }

    private let bookendGreen = Color(red: 0.16, green: 0.46, blue: 0.22)
    private let seekingGold  = Color(red: 0.80, green: 0.60, blue: 0.10)
    private let cal = Calendar.current
    private let windowMonths = 4
    private static let dayF:   DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f }()
    private static let rangeF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()

    private var today: Date { cal.startOfDay(for: Date()) }
    private var maxWindow: Int { max(0, TradeMatcher.twoWayHorizonMonths / windowMonths - 1) }
    private var windowStart: Date { cal.date(byAdding: .month, value: windowMonths * windowIndex, to: today) ?? today }
    private var windowEnd: Date { cal.date(byAdding: .month, value: windowMonths, to: windowStart) ?? windowStart }
    private var rangeLabel: String {
        let end = cal.date(byAdding: .day, value: -1, to: windowEnd) ?? windowEnd
        return "\(Self.rangeF.string(from: windowStart)) – \(Self.rangeF.string(from: end))"
    }
    private func inWindow(_ d: Date) -> Bool { d >= windowStart && d < windowEnd }

    // Full-horizon mutual matches (both marked the day) — drives the gold count.
    private var mutualTakes: [TwoWayLeg] { full?.iTake.filter(\.wanted) ?? [] }
    private var mutualGives: [TwoWayLeg] { full?.iGive.filter(\.wanted) ?? [] }
    private var mutualN: Int { min(mutualTakes.count, mutualGives.count) }

    // Windowed discovery lists.
    private var winTakes: [TwoWayLeg] { (full?.iTake ?? []).filter { inWindow($0.date) } }
    private var winGives: [TwoWayLeg] { (full?.iGive ?? []).filter { inWindow($0.date) } }

    // Mutual-wanted day-id sets → gold borders on the twin mini-calendars.
    private var myGoldDays: Set<String> { Set(mutualGives.map(\.dayID)) }
    private var theirGoldDays: Set<String> { Set(mutualTakes.map(\.dayID)) }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Finding bookend swaps…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let full, (!full.iTake.isEmpty || !full.iGive.isEmpty) {
                    content
                } else {
                    ContentUnavailableView(
                        "No Bookend Swaps",
                        systemImage: "arrow.triangle.swap",
                        description: Text("No feasible bookend swaps with \(candidate.name) in the next \(TradeMatcher.twoWayHorizonMonths) months."))
                }
            }
            .navigationTitle("Swap with \(candidate.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .alert("Request sent", isPresented: $sentConfirmation) {
                Button("OK") { dismiss() }
            } message: {
                Text("Sent to \(candidate.name). Track it in your Trade Inbox.")
            }
        }
    }

    private var thisMonthStart: Date {
        cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
    }
    private func monthAnchor(_ offset: Int) -> Date {
        cal.date(byAdding: .month, value: offset, to: thisMonthStart) ?? thisMonthStart
    }
    private let monthOffsets = Array(-1...13)
    private static let monthF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f }()

    /// Twin month grids that swipe together, month by month.
    private var scheduleGlance: some View {
        VStack(spacing: 4) {
            HStack {
                Button { setZoom(zoom - 0.5) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(zoom <= 1)
                Text(Self.monthF.string(from: monthAnchor(monthIndex)))
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                Button { setZoom(zoom + 0.5) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(zoom >= 3)
            }
            .buttonStyle(.plain)
            .font(.body.weight(.semibold))
            .padding(.horizontal, 8)
            TabView(selection: $monthIndex) {
                ForEach(monthOffsets, id: \.self) { off in
                    // Side-by-side on iPad; stacked on iPhone so each calendar gets
                    // full width and stays readable.
                    let layout = hSize == .compact
                        ? AnyLayout(VStackLayout(spacing: 10))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
                    layout {
                        MiniScheduleGrid(title: "You", days: myDays, month: monthAnchor(off),
                                         highlight: selectedGive, gold: myGoldDays)
                        MiniScheduleGrid(title: candidate.name, days: theirDays, month: monthAnchor(off),
                                         highlight: selectedTake, gold: theirGoldDays)
                    }
                    .padding(.horizontal, 2)
                    .tag(off)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: glanceBaseHeight)
            .scaleEffect(zoom, anchor: .top)
            .frame(height: glanceBaseHeight * zoom, alignment: .top)
            .clipped()
            Text("Use +/− to zoom · swipe for months")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    /// Steps the calendar zoom, clamped to 1×–3×.
    private func setZoom(_ value: CGFloat) {
        withAnimation { zoom = min(max(value, 1), 3) }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                scheduleGlance
                if mutualN > 0 { mutualSection }
                discoverySection
                VStack(spacing: 4) {
                    Button { propose() } label: {
                        Label("Propose selected swap", systemImage: "message.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedTake.isEmpty && selectedGive.isEmpty)
                    if selectedTake.isEmpty && selectedGive.isEmpty {
                        Text("Tap days above to add them to the proposal.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
    }

    // Highlighted, NOT windowed — guarantees a gold candidate always shows content.
    private var mutualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("^[\(mutualN) match](inflect: true) where you BOTH want the trade", systemImage: "flame.fill")
                .font(.subheadline.bold()).foregroundStyle(seekingGold)
            columns(takes: mutualTakes, gives: mutualGives)
        }
        .padding(12)
        .background(seekingGold.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var discoverySection: some View {
        VStack(spacing: 10) {
            HStack {
                Button { if windowIndex > 0 { windowIndex -= 1 } } label: { Image(systemName: "chevron.left").font(.headline) }
                    .disabled(windowIndex == 0)
                Spacer()
                VStack(spacing: 1) {
                    Text(rangeLabel).font(.subheadline).bold()
                    Text("All bookend swaps · 4-month window").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { if windowIndex < maxWindow { windowIndex += 1 } } label: { Image(systemName: "chevron.right").font(.headline) }
                    .disabled(windowIndex >= maxWindow)
            }
            columns(takes: winTakes, gives: winGives)
        }
    }

    // Two side-by-side columns: take (their shift) | give (your shift). Tap a day
    // to select it — selected days highlight on the calendars and form the proposal.
    private func columns(takes: [TwoWayLeg], gives: [TwoWayLeg]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            legColumn("You take ←", subtitle: "their shift", legs: takes, selected: selectedTake) { id in
                if selectedTake.contains(id) { selectedTake.remove(id) } else { selectedTake.insert(id) }
            }
            legColumn("You give →", subtitle: "they cover", legs: gives, selected: selectedGive) { id in
                if selectedGive.contains(id) { selectedGive.remove(id) } else { selectedGive.insert(id) }
            }
        }
    }

    private func legColumn(_ title: String, subtitle: String, legs: [TwoWayLeg],
                           selected: Set<String>, toggle: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold())
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            if legs.isEmpty {
                Text("None").font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
            } else {
                ForEach(legs) { leg in
                    legCard(leg, isSelected: selected.contains(leg.dayID))
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(leg.dayID) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legCard(_ leg: TwoWayLeg, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11)).foregroundStyle(isSelected ? .blue : .secondary)
                Text(leg.wanted ? "🔥" : "📖").font(.caption)
                Text(Self.dayF.string(from: leg.date)).font(.caption).bold().lineLimit(1)
            }
            Text(legLabel(leg)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text("bookend").font(.system(size: 10, weight: .bold)).foregroundStyle(bookendGreen)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.blue.opacity(0.14)
                               : (leg.wanted ? seekingGold.opacity(0.12) : Color(.secondarySystemBackground)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color.blue : (leg.wanted ? seekingGold : .clear), lineWidth: 1.5))
    }

    private func load() async {
        loading = true
        let myProfile    = TradeProfileStore.shared.myProfile()
        let theirSeeking = TradeProfileStore.shared.profile(forWorker: candidate.workerID)?.seekingDayIDs ?? []
        let mySeeking    = DayIntentStore.shared.seekingDayIDs
        let horizonEnd   = cal.date(byAdding: .month, value: TradeMatcher.twoWayHorizonMonths, to: today) ?? today
        full = await TradeMatcher.twoWayExplore(
            withWorker: candidate.workerID, name: candidate.name,
            windowStart: today, windowEnd: horizonEnd,
            mySeeking: mySeeking, theirSeeking: theirSeeking,
            myProfile: myProfile, myID: SettingsManager.shared.username)
        myDays    = await TradeMatcher.dayLetters(forWorker: SettingsManager.shared.username)
        theirDays = await TradeMatcher.dayLetters(forWorker: candidate.workerID)
        // Pre-select the mutually-wanted days as a sensible starting proposal.
        selectedTake = Set(full?.iTake.filter(\.wanted).map(\.dayID) ?? [])
        selectedGive = Set(full?.iGive.filter(\.wanted).map(\.dayID) ?? [])
        loading = false
    }

    private func legLabel(_ leg: TwoWayLeg) -> String {
        let type = ShiftAvailabilityType.infer(fromStartHour: leg.startHour).rawValue
        return leg.desk.isEmpty ? type : "\(type) · \(leg.desk)"
    }

    private func propose() {
        guard let full else { return }
        let takes = full.iTake.filter { selectedTake.contains($0.dayID) }
        let gives = full.iGive.filter { selectedGive.contains($0.dayID) }
        guard !takes.isEmpty || !gives.isEmpty else { return }
        var parts: [String] = []
        if !takes.isEmpty { parts.append("I take your \(takes.map { Self.dayF.string(from: $0.date) }.joined(separator: ", "))") }
        if !gives.isEmpty { parts.append("you take my \(gives.map { Self.dayF.string(from: $0.date) }.joined(separator: ", "))") }
        let note = "Swap: " + parts.joined(separator: "; ") + "."
        Task {
            await MessagingStore.shared.sendRequest(
                to: candidate.workerID, toName: candidate.name, note: note,
                take: takes.map(\.dayID), give: gives.map(\.dayID))
            WidgetData.update()
            sentConfirmation = true
        }
    }
}

/// A tiny Monday-first month grid (M–Su header, day# over A/P/M, off days blank)
/// for a quick glance at someone's schedule. No desks. Days outside the month dim.
struct MiniScheduleGrid: View {
    let title: String
    let days: [String: String]   // ISO "yyyy-MM-dd" → "A"/"P"/"M" ("" = off)
    let month: Date              // any date within the month to display
    var highlight: Set<String> = []   // proposed trade days → distinct box + larger
    var gold: Set<String> = []        // mutually-wanted days → gold border

    private let cal = Calendar.current
    private let tradeBox = Color.indigo.opacity(0.40)
    private let goldBorder = Color(red: 0.80, green: 0.60, blue: 0.10)
    private static let headers = ["M", "T", "W", "Th", "F", "S", "Su"]
    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// The Monday on or before the 1st of the month.
    private var gridStart: Date {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let wd = cal.component(.weekday, from: first)   // 1 = Sun … 7 = Sat
        return cal.date(byAdding: .day, value: -((wd + 5) % 7), to: first) ?? first
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2.bold()).lineLimit(1).frame(maxWidth: .infinity)
            HStack(spacing: 1) {
                ForEach(Self.headers, id: \.self) { h in
                    Text(h).font(.system(size: 8)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<6, id: \.self) { w in
                HStack(spacing: 1) {
                    ForEach(0..<7, id: \.self) { c in
                        cell(dayOffset: w * 7 + c)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func cell(dayOffset: Int) -> some View {
        let date    = cal.date(byAdding: .day, value: dayOffset, to: gridStart) ?? gridStart
        let key     = Self.isoF.string(from: date)
        let letter  = days[key] ?? ""
        let working = !letter.isEmpty
        let inMonth = cal.isDate(date, equalTo: month, toGranularity: .month)
        let isToday = cal.isDateInToday(date)
        let isGold  = gold.contains(key)
        let isTrade = isGold || highlight.contains(key)

        return VStack(spacing: 0) {
            Text("\(cal.component(.day, from: date))")
                .font(.system(size: isTrade ? 9 : 7, weight: isTrade ? .bold : .regular))
                .foregroundStyle(.secondary)
            Text(letter.isEmpty ? " " : letter)
                .font(.system(size: isTrade ? 12 : 9, weight: isTrade ? .heavy : .bold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isTrade ? 2 : 1)
        .background(cellBackground(isTrade: isTrade, working: working))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay {
            if isGold { RoundedRectangle(cornerRadius: 3).stroke(goldBorder, lineWidth: 2) }
            else if isToday { RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 1) }
        }
        .opacity(inMonth ? 1 : 0.25)
    }

    private func cellBackground(isTrade: Bool, working: Bool) -> Color {
        if isTrade { return tradeBox }
        return working ? Color.accentColor.opacity(0.15) : Color(.systemGray6)
    }
}

/// One small box per day you're trading away: the day-of-month over your shift
/// letter, solid green when this candidate can cover it, faint grey when not.
struct CoverageStrip: View {
    let shifts: [Shift]
    let covered: Set<String>

    private let coverGreen = Color(red: 0.16, green: 0.46, blue: 0.22)
    private static let dayF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d"; return f }()

    var body: some View {
        // Single row; cap at 10 boxes, then a "+N" so it never overflows.
        let sorted = shifts.sorted { $0.date < $1.date }
        let shown = Array(sorted.prefix(10))
        let extra = sorted.count - shown.count
        HStack(spacing: 2) {
            ForEach(shown) { s in
                let isCovered = covered.contains(s.id)
                VStack(spacing: 1) {
                    Text(Self.dayF.string(from: s.date))
                        .font(.system(size: 11, weight: .bold))
                    Text(s.shiftLetter.isEmpty ? "·" : s.shiftLetter)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(isCovered ? .white : .secondary)
                .frame(width: 18)
                .padding(.vertical, 3)
                .background(isCovered ? coverGreen : Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 22).padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

/// Tiny ±4-day schedule snapshot: weekday letters over shift-type letters,
/// the covered day highlighted yellow, off days blank.
struct MiniSchedule: View {
    let week: [DayCell]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                VStack(spacing: 1) {
                    Text(cell.weekday)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(cell.letter.isEmpty ? " " : cell.letter)
                        .font(.system(size: 13, weight: .bold))
                }
                .frame(width: 18)
                .padding(.vertical, 1)
                .background(cell.isTarget ? Color.yellow.opacity(0.85) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

// MARK: - CaseIterable for ForEach

extension ShiftAvailabilityType: Identifiable {
    public var id: String { rawValue }
}
