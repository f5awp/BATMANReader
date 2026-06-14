// AvailabilityView.swift
// Trade discovery surfaces used by the Trades tab (the standalone "My Availability"
// page was retired in v2 — openness/pills now live on the Home calendar):
//   • FindCandidatesSection — reciprocal Trade Search (date range → packages)
//   • ECBTradesView         — one-way ECB (points-for-coverage) trades
//   • TwoWaySheet           — the rich two-person swap explorer
//   • MiniScheduleGrid/Legend — the shared trade calendar + key

import SwiftUI
import UIKit

// MARK: - Find Candidates

struct FindCandidatesSection: View {

    @Binding var whatIf: Bool

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
    @State private var packages: [TradePackage] = []
    @State private var execRoute: NWayRoute?
    @State private var packageSent: String?
    @State private var detailPackage: TradePackage?

    private var hasShifts: Bool { !store.upcomingWorkingShifts().isEmpty }
    private var selectedShifts: [Shift] {
        store.shifts.filter { selectedIDs.contains($0.id) }.sorted { $0.date < $1.date }
    }
    /// Selected shifts listed by date, annotating the year only when it's not the
    /// current year (e.g. rolls into January).
    private var selectedDatesLabel: String {
        let cal = Calendar.current
        let thisYear = cal.component(.year, from: Date())
        let f  = DateFormatter(); f.dateFormat  = "EEE MMM d"
        let fy = DateFormatter(); fy.dateFormat = "EEE MMM d, yyyy"
        return selectedShifts.map {
            cal.component(.year, from: $0.date) == thisYear ? f.string(from: $0.date) : fy.string(from: $0.date)
        }.joined(separator: ", ")
    }
    private var displayed: [PlanCandidate] {
        // What If? widens results: ignore the bookends-only filter.
        (bookendsOnly && !whatIf) ? candidates.filter { $0.bookendCount > 0 } : candidates
    }
    private let resultColumns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .fullScreenCover(item: $twoWayCandidate) { c in
            TwoWaySheet(candidate: c)
        }
        .sheet(item: $execRoute) { ExecutionConfirmationView(route: $0) }
        .fullScreenCover(item: $detailPackage) { pkg in
            PackageDetailView(package: pkg,
                              onPropose: { Task { await propose(pkg) } },
                              onExecute: { if let r = pkg.route { execRoute = r } })
        }
        .alert("Package sent", isPresented: Binding(
            get: { packageSent != nil }, set: { if !$0 { packageSent = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(packageSent ?? "") }
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
                        if selectedIDs.isEmpty {
                            Text("Tap days on the calendar").font(.subheadline).bold()
                        } else {
                            Text(selectedDatesLabel).font(.subheadline).bold().lineLimit(2)
                        }
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

                Toggle(isOn: $whatIf.animation()) {
                    Label("What If? Mode — show every legal option", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                }
                .tint(.purple)
                .onChange(of: whatIf) { _, _ in if hasSearched { Task { await search() } } }
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
        } else if candidates.isEmpty && packages.isEmpty {
            ContentUnavailableView("No Matches", systemImage: "person.slash",
                description: Text("No one is off, desk-qualified, and rested for these shifts. Try other days or What If? mode."))
        } else {
            VStack(spacing: 0) {
                if !displayed.isEmpty { resultsHeader }
                ScrollView {
                    if !packages.isEmpty {
                        Text("Packages").font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal).padding(.top, 8)
                        Text("Swap away all selected days — fewest people first.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                        ForEach(packages) { pkg in
                            PackageCard(package: pkg,
                                        onPropose: { Task { await propose(pkg) } },
                                        onExecute: { if let r = pkg.route { execRoute = r } },
                                        onOpen: { detailPackage = pkg })
                        }
                        if !displayed.isEmpty {
                            Divider().padding(.vertical, 6)
                            Text("Individual takers").font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                        }
                    }
                    if displayed.isEmpty && !packages.isEmpty {
                        Text("No single person can take all your days — but the package(s) above do.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal).padding(.top, 4)
                    }
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
                if !displayed.isEmpty { messageBar }
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
            // What If? keeps even opted-out (declined) candidates in the fallback set.
            guard whatIf || w != .declined else { return nil }
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

        // Same packaging algos as Trade by Intents, seeded from the selected days.
        packages = await TradeRouter.packages(forGiveShifts: shifts, excluding: settings.username)

        isSearching = false
        hasSearched = true
        withAnimation(.snappy) { calendarExpanded = false }
    }

    /// Greedy package: send a cover request to each assigned dispatcher.
    private func propose(_ pkg: TradePackage) async {
        for a in pkg.assignments {
            await MessagingStore.shared.sendRequest(
                to: a.workerID, toName: a.name, note: swapNote(a),
                take: a.takeDayIDs, give: a.giveDayIDs)
        }
        WidgetData.update()
        let n = pkg.assignments.count
        packageSent = "Sent to \(n) dispatcher\(n == 1 ? "" : "s"). Track replies in your Inbox."
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

// MARK: - ECB Trades (one-way, points-for-coverage)

/// One-way trades: find who can cover shifts you want off, offer ECB points, and
/// request them all. No swap-back, no greedy/N-way — pure "who can work my shift".
struct ECBTradesView: View {
    private let store    = ShiftStore.shared
    private let settings = SettingsManager.shared

    @State private var selectedIDs: Set<String> = []
    @State private var candidates: [PlanCandidate] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var ecb = 9
    @State private var calendarExpanded = true
    @State private var sentMsg: String?

    private var hasShifts: Bool { !store.upcomingWorkingShifts().isEmpty }
    private var selectedShifts: [Shift] {
        store.shifts.filter { selectedIDs.contains($0.id) }.sorted { $0.date < $1.date }
    }
    private var selectedDatesLabel: String {
        let cal = Calendar.current
        let thisYear = cal.component(.year, from: Date())
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        let fy = DateFormatter(); fy.dateFormat = "EEE MMM d, yyyy"
        return selectedShifts.map {
            cal.component(.year, from: $0.date) == thisYear ? f.string(from: $0.date) : fy.string(from: $0.date)
        }.joined(separator: ", ")
    }
    private let columns = [GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .alert("ECB requests sent", isPresented: Binding(
            get: { sentMsg != nil }, set: { if !$0 { sentMsg = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(sentMsg ?? "") }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if !hasShifts {
                Text("Import your schedule to offer one-way ECB trades.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Stepper(value: $ecb, in: 0...50) {
                    HStack(spacing: 8) {
                        Label("ECB offered", systemImage: "star.circle.fill").foregroundStyle(.orange)
                        Text("\(ecb)").font(.headline.monospacedDigit())
                        Spacer()
                    }
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Take my shift (one-way)").font(.caption2).foregroundStyle(.secondary)
                        Text(selectedIDs.isEmpty ? "Tap days on the calendar" : selectedDatesLabel)
                            .font(.subheadline).bold().lineLimit(2)
                    }
                    Spacer()
                    Button { Task { await search() } } label: { Label("Find", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(selectedIDs.isEmpty || isSearching)
                    Button { withAnimation(.snappy) { calendarExpanded.toggle() } } label: {
                        Image(systemName: calendarExpanded ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                    }
                }
                if calendarExpanded {
                    ShiftSelectCalendar(shifts: store.shifts, selection: $selectedIDs)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8).background(.bar)
    }

    @ViewBuilder private var content: some View {
        if isSearching {
            ProgressView("Searching roster…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasSearched {
            ContentUnavailableView("One-Way ECB Trades", systemImage: "star.circle",
                description: Text("Pick shifts you want taken, set the ECB you'll offer, then Find. No swap back — you're paying ECB points."))
        } else if candidates.isEmpty {
            ContentUnavailableView("No Takers", systemImage: "person.slash",
                description: Text("No one is off, desk-qualified, and rested to take these shifts."))
        } else {
            VStack(spacing: 0) {
                Text("\(candidates.count) can take").font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(candidates) { c in
                            PlanCandidateCell(candidate: c, selectedShifts: selectedShifts,
                                              total: selectedShifts.count, isSelected: false,
                                              onTap: {}, onEnter: {}, showSchedule: true, showEnter: false)
                        }
                    }
                    .padding(8)
                }
                Button { Task { await requestAll() } } label: {
                    Label("Request all \(candidates.count) · offer \(ecb) ECB", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).padding(10).background(.bar)
            }
        }
    }

    private func search() async {
        let shifts = selectedShifts
        guard !shifts.isEmpty else { return }
        isSearching = true
        let able = await TradeMatcher.candidatesForTrades(shifts: shifts, excluding: settings.username)
        await TradeProfileStore.shared.refreshOthers()
        // People who actively marked WANT-TO-WORK (published availability) on these
        // off days are looking for a shift — surface them first.
        candidates = able.sorted {
            let aw = wantsToWork($0), bw = wantsToWork($1)
            if aw != bw { return aw }
            if $0.matchCount != $1.matchCount { return $0.matchCount > $1.matchCount }
            return $0.name < $1.name
        }
        isSearching = false; hasSearched = true
        withAnimation(.snappy) { calendarExpanded = false }
    }

    /// Whether this dispatcher published want-to-work availability for any of the
    /// requested days (= they're actively seeking a shift).
    private func wantsToWork(_ c: PlanCandidate) -> Bool {
        guard let prof = TradeProfileStore.shared.profile(forWorker: c.workerID),
              prof.hasPublishedAvailability else { return false }
        return selectedShifts.contains { s in
            let t = ShiftAvailabilityType.infer(fromStartHour: s.startHour)
            return prof.availabilityMap[s.id]?.contains(t) ?? false
        }
    }

    private func requestAll() async {
        let offerID = UUID().uuidString   // groups the broadcast; queue is per shift
        var sent = 0
        for c in candidates {
            // Only the selected days THIS person can actually cover.
            let theirDays = selectedShifts.filter { c.coveredShiftIDs.contains($0.id) }.map(\.id)
            guard !theirDays.isEmpty else { continue }
            let dates = theirDays.map { prettyDay($0) }.joined(separator: ", ")
            await MessagingStore.shared.sendRequest(
                to: c.workerID, toName: c.name,
                note: "One-way ECB trade — take my \(dates). Offering \(ecb) ECB. Accept the shifts you can take; first to accept each shift gets it. Reply with your employee #.",
                take: [], give: theirDays, ecb: ecb, offerID: offerID)
            sent += 1
        }
        WidgetData.update()
        sentMsg = "Sent ECB requests to \(sent) dispatcher\(sent == 1 ? "" : "s") offering \(ecb) ECB. Track replies in your Inbox."
    }
}

struct PlanCandidateCell: View {
    let candidate: PlanCandidate
    let selectedShifts: [Shift]
    let total: Int
    let isSelected: Bool
    let onTap: () -> Void
    let onEnter: () -> Void
    var showSchedule: Bool = false   // ECB tab shows the mini-schedule instead of status
    var showEnter: Bool = true       // ECB hides the two-way enter button

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
        .clipShape(RoundedRectangle(cornerRadius: DS.rowRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.rowRadius)
                .stroke(borderColor, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    // iPhone: name on its own line; small 📖/🔥 icons beneath it. No mini, no "covers" line.
    private var compactRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name).font(.dsCardTitle).lineLimit(1)
                HStack(spacing: 10) {
                    if !candidate.quals.isEmpty {
                        Text(candidate.quals.joined(separator: " "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    smallBook
                    flameOrUnknown
                }
                if let s = TradeProfileStore.shared.profile(forWorker: candidate.workerID)?.statusBroadcast,
                   !s.isEmpty {
                    Text(s).font(.dsCardMeta).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if showSchedule { scheduleStrip }
            selectionCheck
            if showEnter { enterButton }
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
                    Text(candidate.name).font(.dsCardTitle).lineLimit(1)
                    flameOrUnknown
                }
                Text(candidate.quals.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("takes \(candidate.matchCount) of \(total)")
                    .font(.dsCardMeta).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if showSchedule { scheduleStrip } else { statusMessage }
            selectionCheck
            if showEnter { enterButton }
        }
    }

    /// Mini-schedule (coverage of the selected shifts, or a ±4-day snapshot).
    @ViewBuilder private var scheduleStrip: some View {
        if candidate.week.isEmpty {
            CoverageStrip(shifts: selectedShifts, covered: candidate.coveredShiftIDs)
        } else {
            MiniSchedule(week: candidate.week)
        }
    }

    /// The candidate's public status line (replaces the mini-schedule).
    @ViewBuilder private var statusMessage: some View {
        if let s = TradeProfileStore.shared.profile(forWorker: candidate.workerID)?.statusBroadcast,
           !s.isEmpty {
            Text(s)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.trailing)
                .frame(maxWidth: 130, alignment: .trailing)
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
    @State private var theirSeeking: Set<String> = []       // days they want to trade away
    @State private var ignoreMyBlacklist = false            // active-outbound override
    @State private var zoom: CGFloat = 1
    @State private var showIntents = true                   // intent tint overlay on both calendars

    private let youColor  = BrickPalette.mineScheme
    private let themColor = BrickPalette.peerScheme

    private var glanceBaseHeight: CGFloat { 720 }   // two full-width calendars, stacked

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
            .onChange(of: ignoreMyBlacklist) { _, _ in Task { await load() } }
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
                Button { withAnimation { showIntents.toggle() } } label: {
                    Image(systemName: showIntents ? "paintpalette.fill" : "paintpalette")
                        .foregroundStyle(showIntents ? Color.accentColor : .secondary)
                }
                .accessibilityLabel(showIntents ? "Hide intent colors" : "Show intent colors")
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
                    VStack(spacing: 16) {
                        MiniScheduleGrid(title: "You", days: myDays, month: monthAnchor(off),
                                         accent: youColor,
                                         giveDays: selectedGive, takeDays: selectedTake,
                                         gold: myGoldDays, intent: myIntent,
                                         topology: myTopology, eventName: myEvent)
                        MiniScheduleGrid(title: candidate.name, days: theirDays, month: monthAnchor(off),
                                         accent: themColor,
                                         giveDays: selectedTake, takeDays: selectedGive,
                                         gold: theirGoldDays, intent: theirIntent,
                                         topology: Self.globalTopology, eventName: Self.globalEvent)
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

    /// Your intent as a corner chip on the "You" calendar (hidden when toggled off).
    private func myIntent(_ day: String) -> Color? {
        guard showIntents else { return nil }
        if let w = DayIntentStore.shared.workingIntent(forDay: day) { return w.brickColor }
        if let o = DayIntentStore.shared.offIntent(forDay: day) { return o.brickColor }
        return nil
    }

    /// Their published intent (days they want to trade away) as a corner chip.
    private func theirIntent(_ day: String) -> Color? {
        guard showIntents else { return nil }
        return theirSeeking.contains(day) ? BrickPalette.change : nil
    }

    /// Your own day markers (high-demand or personal milestone) and their detail text.
    private func myTopology(_ day: String) -> DayTopology { DayIntentStore.shared.topology(forDay: day) }
    private func myEvent(_ day: String) -> String? { Self.eventText(day, topology: myTopology(day), includePrivate: true) }

    /// The peer's calendar only shows GLOBAL high-demand days (personal milestones
    /// aren't published), so it's identical for everyone.
    static func globalTopology(_ day: String) -> DayTopology { Holidays.isHighDemand(day) ? .highDemand : .standard }
    static func globalEvent(_ day: String) -> String? { Holidays.name(forDay: day) }

    /// Shared text for a marked day's popover.
    static func eventText(_ day: String, topology: DayTopology, includePrivate: Bool) -> String? {
        switch topology {
        case .highDemand:
            return Holidays.name(forDay: day) ?? "High-impact day"
        case .personalMilestone:
            let note = DayIntentStore.shared.note(forDay: day)
            if let note, includePrivate || !note.isPrivate, !note.message.isEmpty { return note.message }
            return "Personal day"
        case .standard:
            return nil
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                scheduleGlance
                MiniScheduleLegend()
                Toggle(isOn: $ignoreMyBlacklist.animation()) {
                    Label("Show my blacklisted shifts (override)", systemImage: "eye.slash")
                        .font(.caption.weight(.semibold))
                }
                .tint(.orange)
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
            legColumn("You give →", subtitle: "they take", legs: gives, selected: selectedGive) { id in
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
        let theirProf    = await TradeProfileStore.shared.fetchProfile(forWorker: candidate.workerID)
            ?? TradeProfile(workerID: candidate.workerID, displayName: candidate.name,
                            openness: TradeOpenness.all.rawValue, blacklistedWeekdays: [],
                            blacklistedDesks: [], blacklistedShiftTypes: [], blacklistedRegions: [],
                            seekingDayIDs: [], updatedAt: Date())
        let theirSeek    = theirProf.seekingDayIDs
        theirSeeking = theirSeek
        let mySeeking    = DayIntentStore.shared.seekingDayIDs
        let horizonEnd   = cal.date(byAdding: .month, value: TradeMatcher.twoWayHorizonMonths, to: today) ?? today
        full = await TradeMatcher.twoWayExplore(
            withWorker: candidate.workerID, name: candidate.name,
            windowStart: today, windowEnd: horizonEnd,
            mySeeking: mySeeking, theirSeeking: theirSeek,
            myProfile: myProfile, theirProfile: theirProf, myID: SettingsManager.shared.username,
            ignoreOwnBlacklist: ignoreMyBlacklist)
        myDays    = await TradeMatcher.dayLabels(forWorker: SettingsManager.shared.username)
        theirDays = await TradeMatcher.dayLabels(forWorker: candidate.workerID)
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

/// One thin key bar under the paired trade calendars: give = border, get = fill;
/// you read blue, they read red.
struct MiniScheduleLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            swatch("You give") { RoundedRectangle(cornerRadius: 3).stroke(BrickPalette.mineScheme, lineWidth: 2.5) }
            swatch("You get")  { RoundedRectangle(cornerRadius: 3).fill(BrickPalette.mineScheme.opacity(0.5)) }
            swatch("They give"){ RoundedRectangle(cornerRadius: 3).stroke(BrickPalette.peerScheme, lineWidth: 2.5) }
            swatch("They get") { RoundedRectangle(cornerRadius: 3).fill(BrickPalette.peerScheme.opacity(0.5)) }
        }
        .font(.caption2)
        .lineLimit(1).minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6).padding(.horizontal, 12)
        .background(.bar, in: Capsule())
    }

    private func swatch<S: View>(_ label: String, @ViewBuilder _ shape: () -> S) -> some View {
        HStack(spacing: 4) {
            shape().frame(width: 13, height: 13)
            Text(label)
        }
    }
}

/// A full-width Sunday-first month grid with large day cells (day# over shift+desk).
/// One color per side (you = blue, the counterparty = red), one cue per direction:
/// a day you GIVE = own-color BORDER, a day you GET = own-color FILL. So on your
/// (blue) calendar a give is blue-bordered and a pickup is blue-filled; on their
/// (red) calendar their give is red-bordered and their pickup is red-filled. Intent
/// is a thin bar along the bottom; today is a blue circle.
struct MiniScheduleGrid: View {
    let title: String
    let days: [String: String]           // ISO → "AM 82" label ("" = off)
    let month: Date
    var accent: Color = .blue            // THIS calendar owner's signature color (You=blue, peer=red)
    var giveDays: Set<String> = []       // owner GIVES these away → own-color border
    var takeDays: Set<String> = []       // owner RECEIVES these → own-color fill
    var gold: Set<String> = []           // mutually-wanted → gold border
    var intent: (String) -> Color? = { _ in nil }              // thick bottom bar (toggle-able by caller)
    var topology: (String) -> DayTopology = { _ in .standard } // high-impact / personal-day circle
    var eventName: (String) -> String? = { _ in nil }          // popover text when a marked day is tapped

    @State private var openEvent: String?

    private let cal = Calendar.current
    private let blue = Color.blue
    private let goldBorder = Color(red: 0.85, green: 0.62, blue: 0.05)
    private static let headers = ["Su", "M", "T", "W", "Th", "F", "Sa"]
    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// The Sunday on or before the 1st of the month.
    private var gridStart: Date {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let wd = cal.component(.weekday, from: first)   // 1 = Sun
        return cal.date(byAdding: .day, value: -(wd - 1), to: first) ?? first
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(Self.headers, id: \.self) { h in
                    Text(h).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<6, id: \.self) { w in
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { c in
                        cell(dayOffset: w * 7 + c)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Scale with Dynamic Type, but cap it so the fixed-size day cells don't overflow.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private func cell(dayOffset: Int) -> some View {
        let date    = cal.date(byAdding: .day, value: dayOffset, to: gridStart) ?? gridStart
        let key     = Self.isoF.string(from: date)
        let label   = days[key] ?? ""
        let working = !label.isEmpty
        let inMonth = cal.isDate(date, equalTo: month, toGranularity: .month)
        let isToday = cal.isDateInToday(date)

        let marker = markerColor(key: key, isToday: isToday)
        let hasEvent = eventName(key) != nil

        return VStack(spacing: 1) {
            ZStack {
                // Today + a marked day → marker circle ringed in blue. Either alone →
                // a single filled circle (blue for today, gold/pink for marked days).
                if let marker {
                    Circle().fill(marker).frame(width: 26, height: 26)
                    if isToday && marker != blue {
                        Circle().stroke(blue, lineWidth: 2.5).frame(width: 31, height: 31)
                    }
                }
                Text("\(cal.component(.day, from: date))")
                    .font(.subheadline.weight(.semibold))
                    // Dark text on the light gold circle; white on blue/pink.
                    .foregroundStyle(marker == nil ? .primary
                        : (topology(key) == .highDemand ? Color.black.opacity(0.85) : .white))
            }
            .frame(height: 32)
            Text(label.isEmpty ? " " : label)
                .font(.caption.weight(.heavy))
                .foregroundStyle(working ? accent : .secondary)
                .lineLimit(1).minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(background(key: key, working: working))
        .overlay(alignment: .bottom) { intentBar(key: key) }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { border(key: key) }
        .opacity(inMonth ? 1 : 0.18)
        .contentShape(Rectangle())
        .onTapGesture { if hasEvent { openEvent = key } }
        .popover(isPresented: Binding(get: { openEvent == key },
                                      set: { if !$0 { openEvent = nil } })) {
            eventPopover(key: key)
        }
    }

    /// Gold for a high-demand day, pink for a personal day, blue for today (today is
    /// only the fallback when the day isn't otherwise marked). Returns nil = no circle.
    private func markerColor(key: String, isToday: Bool) -> Color? {
        switch topology(key) {
        case .highDemand:        return BrickPalette.highImpact
        case .personalMilestone: return BrickPalette.personalDay
        case .standard:          return isToday ? blue : nil
        }
    }

    private func background(key: String, working: Bool) -> Color {
        if takeDays.contains(key) { return accent.opacity(0.5) }    // owner receives → own-color fill
        return working ? accent.opacity(0.16) : Color(.systemGray5)
    }

    /// Intent rendered as a thick bar across the bottom of the cell — visible without
    /// fighting the trade fills. Hidden when the caller's `intent` closure returns nil.
    @ViewBuilder private func intentBar(key: String) -> some View {
        if let tint = intent(key) {
            tint.frame(maxWidth: .infinity).frame(height: 5)
        }
    }

    @ViewBuilder private func eventPopover(key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let isPersonal = topology(key) == .personalMilestone
            Label(isPersonal ? "Personal day" : "High-impact day",
                  systemImage: isPersonal ? "star.circle.fill" : "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isPersonal ? BrickPalette.personalDay : BrickPalette.highImpact)
            if let name = eventName(key) { Text(name).font(.body) }
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder private func border(key: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        // Give = own-color border; get = fill only (handled in background, no border).
        if giveDays.contains(key) { shape.stroke(accent, lineWidth: 3) }
        else if gold.contains(key) { shape.stroke(goldBorder, lineWidth: 2) }
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
