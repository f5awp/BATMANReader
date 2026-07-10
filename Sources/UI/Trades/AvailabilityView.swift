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

/// #7: open a prefilled draft in the OUTLOOK app (ms-outlook://compose); if Outlook isn't installed,
/// fall back to the default mail app via mailto. To = the dispatch trades DL.
@MainActor func openDispatchDraft(subject: String, body: String) {
    let dl = SettingsManager.shared.tradeEmailDL
    if let outlook = TradeEmail.outlookURL(dl: dl, subject: subject, body: body) {
        UIApplication.shared.open(outlook, options: [:]) { ok in
            if !ok, let mail = TradeEmail.mailtoURL(dl: dl, subject: subject, body: body) {
                UIApplication.shared.open(mail)
            }
        }
    } else if let mail = TradeEmail.mailtoURL(dl: dl, subject: subject, body: body) {
        UIApplication.shared.open(mail)
    }
}

struct FindCandidatesSection: View {

    @Binding var whatIf: Bool
    var onReady: () -> Void = {}   // fired once the cold roster load settles (drops the Trades spinner)

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
    @State private var searchText = ""                 // C4: filter candidates by name
    @State private var pinnedPeople: Set<String> = []  // C4: pinned to top (per session)
    @State private var execRoute: NWayRoute?
    @State private var packageSent: String?
    @State private var detailPackage: TradePackage?
    @State private var pkgSwap: PackageSwapContext?    // Q1: qual-swap package → blast picker
    // A1/A2 on Trade Solutions: candidate-focused Master Filter (engine / max-people / Connection),
    // applied to the package results (TS keeps whole packages — no 2-person decomposition).
    @State private var searchFilter = SearchFilter()
    @State private var showFilter = false
    @State private var rosterPeople: [(id: String, name: String)] = []
    @State private var allDispatchers: [(id: String, name: String)] = []   // D2: full-roster lookup (was Just 2)
    @State private var searchTask: Task<Void, Never>?   // A1: cancellable Lucky search
    // More-filter resolution maps for the receive-type / desk-qual criteria (need roster data):
    @State private var dayType: [String: ShiftAvailabilityType] = [:]   // "workerID|dayID" → that shift's type
    @State private var dayQual: [String: String] = [:]                  // "workerID|dayID" → desk's required qual
    @State private var myDayQual: [String: String] = [:]                // my give-day id → desk's required qual
    private var filteredPackages: [TradePackage] { searchFilter.filter(packages).filter(criteriaMatch) }
    /// Quals present across the current results — the qual filter's option list.
    private var availableQuals: [String] { Set(dayQual.values).union(myDayQual.values).sorted() }
    /// Apply the roster-backed More-filter criteria (receive shift-type + desk qual). Date range,
    /// engine, max-people and required-person are handled by `searchFilter.filter`.
    private func criteriaMatch(_ p: TradePackage) -> Bool {
        let types = searchFilter.receiveTypes
        let quals = searchFilter.deskQuals
        if types.isEmpty && quals.isEmpty { return true }
        var recvTypes: Set<ShiftAvailabilityType> = []
        var deskQuals: Set<String> = []
        for a in p.assignments {
            for d in a.takeDayIDs {                     // days I PICK UP (partner shifts)
                if let t = dayType["\(a.workerID)|\(d)"] { recvTypes.insert(t) }
                if let q = dayQual["\(a.workerID)|\(d)"] { deskQuals.insert(q) }
            }
            for d in a.giveDayIDs { if let q = myDayQual[d] { deskQuals.insert(q) } }   // my give desks
        }
        for leg in p.route?.legs ?? [] {
            if leg.toID == settings.username { recvTypes.insert(.infer(fromStartHour: leg.startHour)) }
            if let q = DeskRules.requiredQual(forDesk: leg.desk) { deskQuals.insert(q) }
        }
        if !types.isEmpty, recvTypes.isDisjoint(with: types) { return false }
        if !quals.isEmpty, deskQuals.isDisjoint(with: quals) { return false }
        return true
    }
    // B1: international-desk qual-swap entry — the button glows green only when a selected desk is gated.
    @State private var showQualSwaps = false
    @State private var qualSwapResults: [TradePackage] = []
    @State private var loadingQual = false
    private var qualGatedSelected: Bool { DeskRules.hasQualGatedSelection(desks: selectedShifts.map(\.desk)) }

    private var hasShifts: Bool { !store.upcomingWorkingShifts().isEmpty }
    private var selectedShifts: [Shift] {
        store.shifts.filter { selectedIDs.contains($0.id) }.sorted { $0.date < $1.date }
    }
    /// Selected shifts listed by date, annotating the year only when it's not the
    /// current year (e.g. rolls into January).
    private var selectedDatesLabel: String {
        // Compact numeric dates (7/15, 7/17…) so more fit before truncating; add the year only off-year.
        let cal = Calendar.current
        let thisYear = cal.component(.year, from: Date())
        let f  = DateFormatter(); f.dateFormat  = "M/d"
        let fy = DateFormatter(); fy.dateFormat = "M/d/yy"
        return selectedShifts.map {
            cal.component(.year, from: $0.date) == thisYear ? f.string(from: $0.date) : fy.string(from: $0.date)
        }.joined(separator: ", ")
    }
    private var displayed: [PlanCandidate] {
        // What If? widens results: ignore the bookends-only filter.
        let base = (bookendsOnly && !whatIf) ? candidates.filter { $0.bookendCount > 0 } : candidates
        // C4: name search + pinned-to-top.
        return PeopleFilter.arrange(base, query: searchText, pinned: pinnedPeople,
                                    id: { $0.workerID }, name: { $0.name })
    }
    private let resultColumns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .fullScreenCover(item: $twoWayCandidate) { c in
            TwoWaySheet(candidate: c).magnifiable()
        }
        .sheet(isPresented: $showFilter) {
            MasterFilterSheet(filter: $searchFilter, people: rosterPeople, availableQuals: availableQuals,
                              onGenerate: { f in if !selectedIDs.isEmpty { runSearch { await search(generation: f, lucky: true) } } },
                              onReset: { if !selectedIDs.isEmpty { runSearch { await searchFast() } } })
        }
        .onDisappear {
            // Leaving Trade Solutions resets the search — no auto-re-search on return (per user). Clear the
            // in-flight task, local state, and the cached snapshot so coming back shows a clean day picker.
            searchTask?.cancel()
            selectedIDs = []; packages = []; candidates = []; hasSearched = false; calendarExpanded = true
            TradeFeedCache.shared.clear(Self.cacheKey)
        }
        .task {
            defer { onReady() }   // clear the Trades spinner however this task exits (incl. early return)
            if allDispatchers.isEmpty { await loadAllDispatchers() }
            // U-PERF: restore prior results on tab return; only re-search if intents/settings changed
            // while away (and we'd already searched). Keeps Trade Solutions loaded across tab switches.
            guard let snap = TradeFeedCache.shared.snapshot(Self.cacheKey) else { return }
            // Only restore the cached selection when the user has NONE in progress — never clobber a
            // selection they've changed since (the "deselected Aug 5 but it came back" bug).
            if selectedIDs.isEmpty { selectedIDs = snap.selectedIDs }
            packages = snap.packages
            candidates = snap.candidates; rosterPeople = snap.rosterPeople; hasSearched = snap.hasSearched
            if snap.hasSearched { calendarExpanded = false }
            if snap.hasSearched, !selectedIDs.isEmpty,
               snap.signature != TradeFeedCache.signature(selectedIDs: selectedIDs, whatIf: whatIf) {
                runSearch { await searchFast() }
            }
        }
        .sheet(isPresented: $showQualSwaps) {
            QualSwapDaysSheet(packages: qualSwapResults, loading: loadingQual, selectedShifts: selectedShifts) { selectedPkgs in
                showQualSwaps = false
                Task {
                    var n = 0
                    for pkg in selectedPkgs {
                        guard let leg = pkg.qualSwap else { continue }
                        await MessagingStore.shared.sendRequest(
                            to: leg.takerID, toName: leg.takerName,
                            note: "Qual swap to give away \(SwapChips.chipDay(leg.giveShiftDayID)) — \(leg.takerName) takes a freed desk.",
                            take: [], give: [leg.giveShiftDayID], qualSwap: leg, origin: .search)
                        n += 1
                    }
                    WidgetData.update()
                    packageSent = "Qual-swap request\(n == 1 ? "" : "s") sent to \(n) dispatcher\(n == 1 ? "" : "s"). Track replies in your Inbox."
                }
            }
        }
        .sheet(item: $execRoute) { ExecutionConfirmationView(route: $0) }
        .fullScreenCover(item: $detailPackage) { pkg in
            PackageDetailView(package: pkg,
                              onPropose: { Task { await propose(pkg) } },
                              onExecute: { if let r = pkg.route { execRoute = r } })
                .magnifiable()
        }
        .alert("Package sent", isPresented: Binding(
            get: { packageSent != nil }, set: { if !$0 { packageSent = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(packageSent ?? "") }
        .sheet(item: $pkgSwap) { ctx in
            QualSwapPickerSheet(giveDeskLabel: "desk \(ctx.leg.giveDesk) (\(ctx.leg.giveQual))",
                                takerName: ctx.leg.takerName, dayLabel: ctx.dayLabel,
                                candidates: ctx.leg.candidates) { chosen in
                Task {
                    var sendLeg = ctx.leg
                    sendLeg.candidates = ctx.leg.candidates.filter { chosen.contains($0.workerID) }
                    await MessagingStore.shared.sendRequest(
                        to: ctx.leg.takerID, toName: ctx.leg.takerName,
                        note: "Qual swap to give away \(ctx.dayLabel) — \(ctx.leg.takerName) takes a freed desk.",
                        take: [], give: [ctx.leg.giveShiftDayID], qualSwap: sendLeg, origin: .search)
                    WidgetData.update()
                    pkgSwap = nil
                    packageSent = "Qual-swap request sent. Track it in your Inbox."
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if !hasShifts {
                Text("Waiting for your schedule to sync — pull to refresh, or check your Employee ID in Settings.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // ONE clean action row: [selection summary ▾] · [Qual Swap when needed] · Find · ⋯
                HStack(spacing: 10) {
                    // Tap the summary to show/hide the day calendar (replaces the separate chevron button).
                    Button { withAnimation(.snappy) { calendarExpanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Trading away").font(.caption2).foregroundStyle(.secondary)
                                Text(selectedIDs.isEmpty ? "Tap to pick days" : selectedDatesLabel)
                                    .font(.subheadline).bold().lineLimit(1).foregroundStyle(.primary)
                            }
                            Image(systemName: calendarExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(calendarExpanded ? "Hide day calendar" : "Show day calendar")

                    Spacer(minLength: 8)

                    // Qual Swap surfaces ONLY when a selected desk actually needs it (progressive disclosure).
                    if qualGatedSelected {
                        Button {
                            Task {
                                loadingQual = true; showQualSwaps = true
                                qualSwapResults = await TradeRouter.qualSwapOptions(forGiveShifts: selectedShifts, excluding: settings.username)
                                loadingQual = false
                            }
                        } label: { Image(systemName: "arrow.triangle.swap") }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(AppColor.success)
                        .disabled(isSearching)
                        .accessibilityLabel("Qual swap for international desks")
                    }

                    // Primary action.
                    Button { TradeHistoryStore.shared.recordSearch(at: Date()); runSearch { await searchFast() } } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(selectedIDs.isEmpty || isSearching)

                    // Everything secondary lives in the overflow — no clutter by default.
                    Menu {
                        if !selectedIDs.isEmpty {
                            Button(role: .destructive) {
                                selectedIDs = []; packages = []; candidates = []; hasSearched = false
                            } label: { Label("Clear selection", systemImage: "xmark.circle") }
                        }
                        Button { showFilter = true } label: { Label(luckyTitle, systemImage: "wand.and.stars") }
                        // What If? hidden for now — it doesn't affect the new package-based results yet.
                        if !allDispatchers.isEmpty {
                            Menu {
                                ForEach(allDispatchers, id: \.id) { p in
                                    Button(p.name) {
                                        twoWayCandidate = PlanCandidate(workerID: p.id, name: p.name, quals: [],
                                                                        coveredShiftIDs: [], bookendShiftIDs: [], week: [])
                                    }
                                }
                            } label: { Label("Look up a dispatcher", systemImage: "magnifyingglass.circle") }
                        }
                        Button { emailSelectedToDispatch() } label: { Label("Email to dispatch DL", systemImage: "envelope") }
                            .disabled(selectedIDs.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                            .foregroundStyle(searchFilter.isActive ? AppColor.primary : .secondary)   // orange = a Lucky filter is on
                    }
                    .accessibilityLabel("More trade options")
                }

                // Trade size appears only once Lucky is engaged; calendar only when expanded.
                if searchFilter.isActive { MaxPeoplePicker() }
                if calendarExpanded {
                    ShiftSelectCalendar(shifts: store.shifts, selection: $selectedIDs)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
        // Re-run FAST when inputs change (What If / saved intents / max-people). Heavy 3+/N-Way is Lucky-only.
        .onChange(of: whatIf) { _, _ in if hasSearched { runSearch { await searchFast() } } }
        .onChange(of: DayIntentStore.shared.intentsRevision) { _, _ in if hasSearched { runSearch { await searchFast() } } }
        .onChange(of: SettingsManager.shared.normalMaxPeople) { _, _ in if hasSearched { runSearch { await searchFast() } } }
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            VStack(spacing: 14) {
                ProgressView("Searching roster…")
                Button(role: .cancel) { searchTask?.cancel(); isSearching = false } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasSearched {
            ContentUnavailableView("Pick Shifts to Trade", systemImage: "person.2.badge.gearshape",
                description: Text("Tap the days you want to give away, then Find."))
        } else if candidates.isEmpty && packages.isEmpty {
            ContentUnavailableView("No Matches", systemImage: "person.slash",
                description: Text("No one is off, desk-qualified, and rested for these shifts. Try other days or What If? mode."))
        } else if packages.isEmpty {
            ContentUnavailableView("No Package", systemImage: "shippingbox",
                description: Text(candidates.isEmpty
                    ? "No one is off, desk-qualified, and rested for these shifts. Try other days or What If? mode."
                    : "No single package covers all your selected days. Set Trade size to “Pairs” for two-person-only swaps, or look up a specific dispatcher above."))
        } else {
            // Packages only (U5): every solution is a card, sorted fewest-people → 🔥 → bookends.
            ScrollView {
                Text("Trade Solutions").font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.top, 8)
                Text("Swap away all selected days — fewest people first, then most 🔥 and bookends.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                let shown = filteredPackages
                if shown.isEmpty {
                    ContentUnavailableView("No matches for your filter", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Widen the filter (engine / max people / Connection)."))
                        .padding(.top, 12)
                } else {
                    ForEach(shown) { pkg in
                        if pkg.usesCompactCard {   // B4-14: 2-person → compact ECB-style card
                            CompactSwapCard(package: pkg,
                                            onPropose: { Task { await propose(pkg) } },
                                            onOpen: { detailPackage = pkg })
                        } else {
                            PackageCard(package: pkg,
                                        onPropose: { Task { await propose(pkg) } },
                                        onExecute: { if let r = pkg.route { execRoute = r } },
                                        onOpen: { detailPackage = pkg })
                        }
                    }
                }
            }
        }
    }

    /// A1/A2: the "I'm Feeling Lucky" filter bar for Trade Solutions + active-choice chips.
    private var luckyTitle: String {
        searchFilter.summary(nameFor: { id in rosterPeople.first { $0.id == id }?.name ?? id })
            .map { "Lucky: \($0)" } ?? "I'm Feeling Lucky"
    }

    // (Old always-on lucky bar / look-up capsule / chip removed — their actions now live in the
    // trade bar's overflow ⋯ menu. `luckyTitle` above is still used as that menu item's label.)

    private var resultsHeader: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $bookendsOnly) {
                Label("Bookends", systemImage: "book.fill").font(.caption2)
            }
            .toggleStyle(.button).controlSize(.mini).tint(AppColor.success)

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

    /// A1: run a search, CANCELLING any still-running one first (Find / Generate / Reset / What-If
    /// supersedes the previous search instead of racing it).
    private func runSearch(_ work: @escaping () async -> Void) {
        searchTask?.cancel()
        searchTask = Task {
            // B4-10: debounce — coalesce rapid triggers so the engine starts once for the settled input.
            // A superseded task is cancelled during the sleep and bails; the final trigger still runs.
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            await work()
        }
    }

    /// Find: fast 2-person generation, with any Lucky filter cleared so the results show.
    private func searchFast() async {
        searchFilter = .normal
        // Step 4: Find searches up to the user's N-max toggle (default 3); floor + N-penalty keep
        // small trades on top.
        await search(generation: SearchFilter(engine: .both, maxPeople: SettingsManager.shared.normalMaxPeople))
    }

    /// `generation` bounds the engine work: `.fast` (2-person, the Find default) or the user's Lucky
    /// criteria (heavy 3+/N-Way, one-time via Generate). Display still filters via `searchFilter`.
    private func search(generation: SearchFilter = .fast, lucky: Bool = false) async {
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

        // Same packaging algos as Trade by Intents, seeded from the selected days. Generation
        // scope gates the heavy 3+/N-Way work to Lucky → Generate (Find stays fast).
        let result = await TradeRouter.packages(forGiveShifts: shifts, excluding: settings.username, generation: generation, lucky: lucky)
        if Task.isCancelled { return }   // A1: superseded by a newer search — don't clobber its state
        packages = result

        // Resolve type + desk-qual for every result day so the More-filter (shift-time / qual) can
        // apply synchronously. Partner shifts come from their cached schedules; mine from the store.
        var dt: [String: ShiftAvailabilityType] = [:]; var dq: [String: String] = [:]
        for wid in Set(packages.flatMap { $0.assignments.map(\.workerID) }) {
            for e in await RosterStore.shared.schedule(forWorker: wid) where !e.isOff {
                dt["\(wid)|\(e.day)"] = ShiftAvailabilityType.infer(fromStartHour: e.startHour)
                if let q = DeskRules.requiredQual(forDesk: e.desk) { dq["\(wid)|\(e.day)"] = q }
            }
        }
        dayType = dt; dayQual = dq
        myDayQual = Dictionary(uniqueKeysWithValues: store.shifts.compactMap { s in
            (!s.isOff ? DeskRules.requiredQual(forDesk: s.desk) : nil).map { (s.id, $0) }
        })

        // A2: people for the Connection dropdown — candidates + published peers + result participants.
        var seen = Set<String>(); var people: [(id: String, name: String)] = []
        func add(_ id: String, _ name: String) {
            guard id != settings.username, seen.insert(id).inserted else { return }
            people.append((id, TradeNames.resolved(displayName: nil, rosterName: name, workerID: id)))
        }
        for c in candidates { add(c.workerID, c.name) }
        for (id, p) in profiles.others { add(id, p.displayName) }
        for pkg in packages { for a in pkg.assignments { add(a.workerID, a.name) } }
        rosterPeople = people.sorted { $0.name < $1.name }

        isSearching = false
        hasSearched = true
        withAnimation(.snappy) { calendarExpanded = false }
        // U-PERF: cache so a tab switch restores results without re-running the engine.
        TradeFeedCache.shared.save(Self.cacheKey, .init(
            signature: TradeFeedCache.signature(selectedIDs: Set(shifts.map(\.id)), whatIf: whatIf),
            selectedIDs: selectedIDs, packages: packages, candidates: candidates,
            rosterPeople: rosterPeople, hasSearched: true))
    }

    private static let cacheKey = "tradeSolutions"

    /// D2: load the full distinct roster (minus you) for the "Look up a dispatcher" dropdown — ONCE per
    /// session (cached in TradeFeedCache), so it's not re-fetched on every tab return.
    private func loadAllDispatchers() async {
        if !TradeFeedCache.shared.allDispatchers.isEmpty {
            allDispatchers = TradeFeedCache.shared.allDispatchers; return
        }
        let myID = settings.username
        let now = Date(); let end = Calendar.current.date(byAdding: .month, value: 12, to: now) ?? now
        let entries = await RosterStore.shared.entries(from: now, to: end)
        var seen = Set<String>(); var out: [(id: String, name: String)] = []
        for e in entries where e.workerID != myID && seen.insert(e.workerID).inserted {
            out.append((e.workerID, TradeNames.resolved(displayName: nil, rosterName: e.workerName, workerID: e.workerID)))
        }
        allDispatchers = out.sorted { $0.name < $1.name }
        TradeFeedCache.shared.allDispatchers = allDispatchers
    }

    /// #7: email the selected give-days to the dispatch DL (Outlook draft) + Must-Be-Off blackout days.
    private func emailSelectedToDispatch() {
        let me = settings.displayName.isEmpty ? settings.username : settings.displayName
        let give = selectedShifts.map { prettyDay($0.id) }
        let blackout = DayIntentStore.shared.mustBeOffDayIDs.sorted().map { prettyDay($0) }
        openDispatchDraft(subject: TradeEmail.dispatchSubject(giver: me),
                          body: TradeEmail.dispatchBody(giver: me, giveDays: give, blackoutDays: blackout))
    }

    /// Greedy package: send a cover request to each assigned dispatcher. A qual-swap package
    /// instead opens the blast picker so the user chooses which bridges to ask (Q1).
    private func propose(_ pkg: TradePackage) async {
        if let leg = pkg.qualSwap { pkgSwap = PackageSwapContext(leg: leg); return }
        for a in pkg.assignments {
            await MessagingStore.shared.sendRequest(
                to: a.workerID, toName: a.name, note: swapNote(a),
                take: a.takeDayIDs, give: a.giveDayIDs, origin: .search)
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
    @State private var selectedRecipients: Set<String> = []   // tap-to-select takers for the ECB send
    @State private var candidates: [PlanCandidate] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var ecb: Double = 9
    @State private var calendarExpanded = true
    @State private var sentMsg: String?
    @Environment(\.horizontalSizeClass) private var hSize

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
    // #6: two columns on regular-width (iPad), one on compact (iPhone portrait).
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: hSize == .regular ? 2 : 1)
    }
    /// Candidates who'd cover at least one selected day as a bookend (for the bookend-only broadcast).
    private var bookendCandidates: [PlanCandidate] { candidates.filter { $0.bookendCount > 0 } }

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
                Text("Waiting for your schedule to sync — pull to refresh.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Stepper(value: $ecb, in: 5...25, step: 0.5) {
                    HStack(spacing: 8) {
                        Label("ECB offered", systemImage: "star.circle.fill").foregroundStyle(AppColor.pending)
                        Text(ecbText(ecb)).font(.headline.monospacedDigit())
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
                    Button { emailECBToDispatch() } label: { Image(systemName: "envelope.fill") }
                        .controlSize(.small).disabled(selectedIDs.isEmpty)
                        .accessibilityLabel("Email ECB offer to dispatch DL")
                    Button { TradeHistoryStore.shared.recordSearch(at: Date()); Task { await search() } } label: { Label("Find", systemImage: "magnifyingglass") }
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
                IntentColorKey().padding(.horizontal, 8)   // #5: intent-color legend in ECB
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(candidates) { c in
                            PlanCandidateCell(candidate: c, selectedShifts: selectedShifts,
                                              total: selectedShifts.count,
                                              isSelected: selectedRecipients.contains(c.workerID),
                                              onTap: { toggleRecipient(c.workerID) },
                                              onEnter: {}, showSchedule: true, showEnter: false)
                        }
                    }
                    .padding(8)
                }
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Button { Task { await requestAll(bookendsOnly: true) } } label: {
                            Label("Bookends (\(bookendCandidates.count))", systemImage: "book.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(AppColor.success)
                        .disabled(bookendCandidates.isEmpty)
                        Button { Task { await requestAll(bookendsOnly: false) } } label: {
                            Label("All \(candidates.count)", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    // Tap dispatchers above to pick exactly who gets the offer, then send to just them.
                    Button { Task { await requestSelected() } } label: {
                        Label(selectedRecipients.isEmpty ? "Send to Selected"
                                                          : "Send to Selected (\(selectedRecipients.count))",
                              systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedRecipients.isEmpty)
                }
                .padding(10).background(.bar)
            }
        }
    }

    /// #7: email the ECB offer (selected days + ECB count, NO blackout) to the dispatch DL (Outlook).
    private func emailECBToDispatch() {
        let me = settings.displayName.isEmpty ? settings.username : settings.displayName
        let give = selectedShifts.map { prettyDay($0.id) }
        openDispatchDraft(subject: TradeEmail.ecbSubject(giver: me, ecb: ecb),
                          body: TradeEmail.ecbBody(giver: me, giveDays: give, ecb: ecb))
    }

    private func search() async {
        let shifts = selectedShifts
        guard !shifts.isEmpty else { return }
        isSearching = true
        selectedRecipients = []   // a fresh candidate list — clear any prior hand-picked takers
        let able = await TradeMatcher.candidatesForTrades(shifts: shifts, excluding: settings.username)
        await TradeProfileStore.shared.refreshOthers()
        // ECB broadcast filter (U2/U5): only offer to recipients whose OWN rules accept it —
        // weekly cap, must-be-off, and published shift availability (the unified `.full` gate).
        // Want-to-work is NOT a filter (it's surfaced as 🔥 + sorted first below). The initiating
        // searcher is ungated. Load the roster span once (perf rule), then filter.
        let cal = Calendar.current
        let dates = shifts.map { cal.startOfDay(for: $0.date) }
        let lower = cal.date(byAdding: .day, value: -8, to: dates.min() ?? Date()) ?? Date()
        let upper = cal.date(byAdding: .day, value: 8, to: dates.max() ?? Date()) ?? Date()
        let entries = await RosterStore.shared.entries(from: lower, to: upper)
        var maps: [String: [String: RosterEntry]] = [:]
        for e in entries { maps[e.workerID, default: [:]][e.day] = e }
        let eligible = able.filter { c in
            guard let prof = TradeProfileStore.shared.profile(forWorker: c.workerID) else { return true }
            let map = maps[c.workerID] ?? [:]
            return shifts.contains { s in
                guard c.coveredShiftIDs.contains(s.id) else { return false }
                let day = cal.startOfDay(for: s.date)
                return TradeEligibility.canCover(
                    coverDayID: TradeMatcher.isoDay(day), coverDay: day, desk: s.desk, startHour: s.startHour,
                    coverMap: map, coverQuals: c.quals, coverProfile: prof, options: .full).eligible
            }
        }
        // 4101: behavior filter for INACTIVE/robot accounts only. An ACTIVE dispatcher (claimed account)
        // already had their own prefs/blacklists applied by the `.full` gate above, so they pass through
        // untouched. For someone NOT on the app (no claimed profile), we can't read prefs — so we infer
        // willingness from their last-60-day behavior: only offer a TYPE (AM/PM/MID) they've actually
        // worked recently (a MID-only dispatcher won't be offered a PM).
        var behaviorFiltered: [PlanCandidate] = []
        for c in eligible {
            let isActive = TradeProfileStore.shared.profile(forWorker: c.workerID)?.accountClaimed == true
            if isActive { behaviorFiltered.append(c); continue }
            let coveredTypes = Set(shifts.filter { c.coveredShiftIDs.contains($0.id) }
                .map { ShiftAvailabilityType.infer(fromStartHour: $0.startHour) })
            let recent = await TradeMatcher.recentWorkedTypes(workerID: c.workerID)
            if TradeMatcher.recentBehaviorAllows(recentTypes: recent, coveredTypes: coveredTypes) {
                behaviorFiltered.append(c)
            }
        }
        // People who actively marked WANT-TO-WORK (published availability) on these
        // off days are looking for a shift — surface them first (🔥).
        candidates = behaviorFiltered.sorted {
            if $0.bookendCount != $1.bookendCount { return $0.bookendCount > $1.bookendCount }  // #6: bookends first
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

    /// Toggle a taker in/out of the hand-picked recipient set (tap-to-select, no checkbox).
    private func toggleRecipient(_ id: String) {
        if selectedRecipients.contains(id) { selectedRecipients.remove(id) }
        else { selectedRecipients.insert(id) }
    }

    private func requestAll(bookendsOnly: Bool) async {
        await sendECB(to: bookendsOnly ? bookendCandidates : candidates)   // #6: bookends-only or everyone
    }

    /// Send the ECB offer to exactly the hand-picked takers (tap-to-select).
    private func requestSelected() async {
        await sendECB(to: candidates.filter { selectedRecipients.contains($0.workerID) })
    }

    /// One ECB send path — a request per taker for only the selected days THEY can cover.
    private func sendECB(to targets: [PlanCandidate]) async {
        let offerID = UUID().uuidString   // groups the broadcast; queue is per shift
        var sent = 0
        for c in targets {
            let theirDays = selectedShifts.filter { c.coveredShiftIDs.contains($0.id) }.map(\.id)
            guard !theirDays.isEmpty else { continue }
            let dates = theirDays.map { prettyDay($0) }.joined(separator: ", ")
            // No boilerplate note — the card shows the ECB offer + shifts, and the accepter's employee #
            // appears automatically in the sender's ECB offer view once they accept.
            await MessagingStore.shared.sendRequest(
                to: c.workerID, toName: c.name, note: "",
                take: [], give: theirDays, ecb: Int(ecb.rounded()), ecbValue: ecb, offerID: offerID, origin: .ecb)
            sent += 1
        }
        WidgetData.update()
        sentMsg = "Sent ECB requests to \(sent) dispatcher\(sent == 1 ? "" : "s") offering \(ecbText(ecb)) ECB. Track replies in your Inbox."
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

    private let bookendGreen = AppColor.success
    private let seekingGold  = AppColor.pending

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
        .background(isSelected ? AppColor.primary.opacity(0.10) : Color(.secondarySystemBackground))
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
                Text(candidate.name + botSuffix(candidate.workerID)).font(.dsCardTitle).lineLimit(1)
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
                    Text(candidate.name + botSuffix(candidate.workerID)).font(.dsCardTitle).lineLimit(1)
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
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(AppColor.primary)
        }
    }

    private var enterButton: some View {
        Button(action: onEnter) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.title3).foregroundStyle(AppColor.primary.opacity(0.85))
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
    @State private var theirWantToWork: Set<String> = []     // G2c: peer's full intent palette
    @State private var theirMustBeOff: Set<String> = []      // G2c
    @State private var theirKeep: Set<String> = []           // G2c
    @State private var theirStatus: String?                  // R-B: peer's published status, shown in-context
    @State private var peerDisplayName: String?              // G2a: published displayName (resolved into peerName)
    @State private var ignoreMyBlacklist = false            // active-outbound override
    @State private var zoom: CGFloat = 1
    @State private var showIntents = true                   // intent tint overlay on both calendars
    @State private var qualSwapPicker: QualSwapPickerContext?  // Q1/Q2: blast-picker when a give-desk needs a qual swap
    @State private var qualSwapNoBridge: String?               // Q1: a needed swap has no eligible bridge

    private let youColor  = BrickPalette.mineScheme
    // F1/D1: the peer reads in their STABLE per-worker color (was hardcoded red).
    private var themColor: Color { TradeColors.color(forParticipant: candidate.workerID, myID: SettingsManager.shared.username, orderedPeers: [candidate.workerID]) }
    // G2a: the peer's human name — published displayName → roster name → employee # (fixes "660615").
    private var peerName: String { TradeNames.resolved(displayName: peerDisplayName, rosterName: candidate.name, workerID: candidate.workerID) }

    private var isPad: Bool { hSize == .regular }
    /// LANDSCAPE (any device — iPhone rotated or iPad) lays the calendars side by side; PORTRAIT
    /// stacks them. Chosen by real geometry (wider than tall) rather than size class, so an iPhone
    /// in landscape goes side-by-side and a portrait iPad (still `.regular`) doesn't.
    private func sideBySide(_ viewport: CGSize) -> Bool { viewport.width > viewport.height }
    /// Height the twin-calendar glance should occupy. Landscape (either device) and portrait iPad
    /// scale-to-fit the viewport so both calendars are visible without scrolling; portrait iPhone
    /// keeps the fixed full-width stacked height.
    private func glanceBaseHeight(_ viewport: CGSize) -> CGFloat {
        guard viewport.height > 0 else { return 720 }
        if sideBySide(viewport) { return viewport.height * 0.78 }   // landscape: one row of two → fill height
        return isPad ? viewport.height * 0.82 : 720                 // portrait: iPad fills; iPhone stacked fixed
    }

    private let bookendGreen = AppColor.success
    private let seekingGold  = AppColor.pending
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
                        description: Text("No feasible bookend swaps with \(peerName) in the next \(TradeMatcher.twoWayHorizonMonths) months."))
                }
            }
            .navigationTitle("Swap with \(peerName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .onChange(of: ignoreMyBlacklist) { _, _ in Task { await load() } }
            .alert("Request sent", isPresented: $sentConfirmation) {
                Button("OK") { dismiss() }
            } message: {
                Text("Sent to \(peerName). Track it in your Trade Inbox.")
            }
            .alert("Qual swap needed", isPresented: Binding(
                get: { qualSwapNoBridge != nil }, set: { if !$0 { qualSwapNoBridge = nil } })) {
                Button("OK", role: .cancel) { qualSwapNoBridge = nil }
            } message: {
                Text(qualSwapNoBridge ?? "")
            }
            .sheet(item: $qualSwapPicker) { ctx in
                QualSwapPickerSheet(
                    giveDeskLabel: "desk \(ctx.giveLeg.desk) (\(ctx.giveQual))",
                    takerName: candidate.name, dayLabel: Self.dayF.string(from: ctx.giveLeg.date),
                    candidates: ctx.candidates) { chosen in
                        Task {
                            let leg = await TradeMatcher.buildQualSwapLeg(
                                giveDayID: ctx.giveLeg.dayID, giveDesk: ctx.giveLeg.desk,
                                giveStartHour: ctx.giveLeg.startHour, giverID: SettingsManager.shared.username,
                                takerID: candidate.workerID, takerName: candidate.name,
                                takerQuals: candidate.quals, chosenCandidateIDs: chosen)
                            await sendTwoWay(note: ctx.note, takes: ctx.takes, gives: ctx.gives, qualSwap: leg)
                            qualSwapPicker = nil
                        }
                    }
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

    /// Twin month grids that swipe together, month by month. `viewport` is the sheet's available
    /// size, used to scale the calendars to fit the screen on iPad (portrait & landscape).
    private func scheduleGlance(_ viewport: CGSize) -> some View {
        let baseHeight = glanceBaseHeight(viewport)
        let wide = sideBySide(viewport)
        return VStack(spacing: 4) {
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
                    // Side-by-side on iPad (both fit without scrolling); stacked on iPhone so
                    // each calendar gets full width and stays readable. `fill` stretches the
                    // grids to the glance height so they scale to fit either layout.
                    Group {
                        if wide {
                            HStack(alignment: .top, spacing: 16) { youGrid(off); peerGrid(off) }
                        } else {
                            VStack(spacing: 16) { youGrid(off); peerGrid(off) }
                        }
                    }
                    .padding(.horizontal, 2)
                    .tag(off)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: baseHeight)
            .scaleEffect(zoom, anchor: .top)
            .frame(height: baseHeight * zoom, alignment: .top)
            .clipped()
            Text("Use +/− to zoom · swipe for months")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    /// The "You" calendar — `fill: true` so it stretches to the glance height (scale-to-fit
    /// in both the stacked-iPhone and side-by-side-iPad layouts).
    private func youGrid(_ off: Int) -> some View {
        MiniScheduleGrid(title: "You", days: myDays, month: monthAnchor(off),
                         accent: youColor, giveDays: selectedGive, takeDays: selectedTake,
                         gold: myGoldDays, intent: myIntent,
                         topology: myTopology, eventName: myEvent, fill: true)
    }
    /// The peer's calendar — same fill behavior.
    private func peerGrid(_ off: Int) -> some View {
        MiniScheduleGrid(title: peerName, days: theirDays, month: monthAnchor(off),
                         accent: themColor, giveDays: selectedTake, takeDays: selectedGive,
                         gold: theirGoldDays, intent: theirIntent,
                         topology: Self.globalTopology, eventName: Self.globalEvent, fill: true)
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

    /// G2c: their FULL published intent palette as a corner chip (was only trade-away).
    private func theirIntent(_ day: String) -> Color? {
        guard showIntents else { return nil }
        return PeerIntentColor.forDay(day, seeking: theirSeeking, wantToWork: theirWantToWork,
                                      mustBeOff: theirMustBeOff, keep: theirKeep)
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
        GeometryReader { geo in
        ScrollView {
            VStack(spacing: 16) {
                if let theirStatus {   // R-B: show the peer's published status in-context
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "quote.bubble").font(.caption).foregroundStyle(themColor)
                        Text(theirStatus).font(.caption).italic().foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(themColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
                scheduleGlance(geo.size)
                MiniScheduleLegend()
                Toggle(isOn: $ignoreMyBlacklist.animation()) {
                    Label("Show my blacklisted shifts (override)", systemImage: "eye.slash")
                        .font(.caption.weight(.semibold))
                }
                .tint(AppColor.pending)
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
            IntentColorKey()   // #5: intent-color legend in the two-way sheet
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
                    .font(.system(size: 11)).foregroundStyle(isSelected ? AppColor.primary : .secondary)
                Text(leg.wanted ? "🔥" : "📖").font(.caption)
                Text(Self.dayF.string(from: leg.date)).font(.caption).bold().lineLimit(1)
            }
            Text(legLabel(leg)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            // #5: only label legs that are ACTUALLY bookends (was printed unconditionally).
            if leg.bookend {
                Text("bookend").font(.system(size: 10, weight: .bold)).foregroundStyle(bookendGreen)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AppColor.primary.opacity(0.14)
                               : (leg.wanted ? seekingGold.opacity(0.12) : Color(.secondarySystemBackground)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? AppColor.primary : (leg.wanted ? seekingGold : .clear), lineWidth: 1.5))
    }

    private func load() async {
        loading = true
        let myProfile    = TradeProfileStore.shared.myProfile()
        let theirProf    = await TradeProfileStore.shared.fetchProfile(forWorker: candidate.workerID)
            ?? TradeProfile.defaultForUnpublished(workerID: candidate.workerID, name: candidate.name)   // A8: missing → Bookends Only
        let theirSeek    = theirProf.seekingDayIDs
        peerDisplayName  = theirProf.displayName   // G2a
        theirWantToWork  = theirProf.wantToWorkDayIDs ?? []   // G2c: peer's full intent palette
        theirMustBeOff   = theirProf.mustBeOffDayIDs ?? []
        theirKeep        = theirProf.keepDayIDs ?? []

        theirSeeking = theirSeek
        let trimmedStatus = theirProf.statusBroadcast?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        theirStatus  = trimmedStatus.isEmpty ? nil : trimmedStatus
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
        let takeIDs = takes.map(\.dayID), giveIDs = gives.map(\.dayID)
        Task {
            // Q1 (shared SSOT): a give-desk the taker can't work needs a qual swap before the trade can go through.
            if let gap = gives.first(where: { !$0.desk.isEmpty && DeskRules.qualSwapNeeded(forDesk: $0.desk, takerQuals: candidate.quals) }) {
                let bridges = await TradeMatcher.qualSwapBridges(
                    giveDayID: gap.dayID, giveDesk: gap.desk, giveStartHour: gap.startHour,
                    takerID: candidate.workerID, takerQuals: candidate.quals,
                    excludeIDs: [SettingsManager.shared.username])
                guard !bridges.isEmpty else {
                    qualSwapNoBridge = "\(peerName) isn't qualified for desk \(gap.desk), and no one working that day can qual-swap onto it. Adjust the days you give away."
                    return
                }
                let qual = DeskRules.requiredQual(forDesk: gap.desk) ?? "D"
                qualSwapPicker = QualSwapPickerContext(giveLeg: gap, giveQual: qual, candidates: bridges,
                                                       takes: takeIDs, gives: giveIDs, note: note)
                return
            }
            await sendTwoWay(note: note, takes: takeIDs, gives: giveIDs, qualSwap: nil)
        }
    }

    private func sendTwoWay(note: String, takes: [String], gives: [String], qualSwap: QualSwapLegData?) async {
        await MessagingStore.shared.sendRequest(
            to: candidate.workerID, toName: candidate.name, note: note,
            take: takes, give: gives, qualSwap: qualSwap, origin: .search)
        WidgetData.update()
        sentConfirmation = true
    }
}

/// Context for the qual-swap blast picker (Q1/Q2): the give leg that needs a swap, the
/// eligible bridges, and the pending proposal to send once the user picks who to ask.
struct QualSwapPickerContext: Identifiable {
    let id = UUID()
    let giveLeg: TwoWayLeg
    let giveQual: String
    let candidates: [QualSwapCandidate]
    let takes: [String]
    let gives: [String]
    let note: String
}

/// Identifiable wrapper so a qual-swap PACKAGE's leg can drive the blast picker sheet (Q1).
struct PackageSwapContext: Identifiable {
    let id = UUID()
    let leg: QualSwapLegData
    var dayLabel: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let out = DateFormatter(); out.dateFormat = "EEE MMM d"
        guard let d = f.date(from: leg.giveShiftDayID) else { return leg.giveShiftDayID }
        return out.string(from: d)
    }
}

/// B1: a per-day paged sheet of potential qual swaps for the selected international give-days.
/// Swipe between days; each lists the qual-swap options. You SELECT which dispatchers to ask
/// (multi-select, all selected by default) then BATCH-broadcast them all at once — no per-row button.
struct QualSwapDaysSheet: View {
    let packages: [TradePackage]
    var loading: Bool = false
    var selectedShifts: [Shift] = []   // ALL the days you picked — so we can label qual vs normal
    let onBroadcast: ([TradePackage]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private var byDay: [(day: String, pkgs: [TradePackage])] {
        let grouped = Dictionary(grouping: packages) { $0.qualSwap?.giveShiftDayID ?? "" }
        return grouped.keys.sorted().map { (day: $0, pkgs: grouped[$0] ?? []) }
    }
    private var allIDs: [String] { packages.filter { $0.qualSwap != nil }.map(\.id) }
    private var selectedPkgs: [TradePackage] { packages.filter { selected.contains($0.id) } }

    // Multi-day breakdown of the selection (qual-only flow: domestic days stay in Find).
    private var workingShifts: [Shift] { selectedShifts.filter { !$0.isOff } }
    private var qualGatedDays: [String] {
        workingShifts.filter { DeskRules.hasQualGatedSelection(desks: [$0.desk]) }.map(\.id).sorted()
    }
    private var solvedDays: Set<String> { Set(packages.compactMap { $0.qualSwap?.giveShiftDayID }) }
    private var unsolvedQualDays: [String] { qualGatedDays.filter { !solvedDays.contains($0) }.sorted() }
    private var normalDays: [String] {
        workingShifts.filter { !DeskRules.hasQualGatedSelection(desks: [$0.desk]) }.map(\.id).sorted()
    }
    private func dayList(_ ids: [String]) -> String { ids.map(SwapChips.chipDay).joined(separator: ", ") }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Finding qual swaps…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        if !selectedShifts.isEmpty { summaryHeader }
                        if byDay.isEmpty {
                            ContentUnavailableView("No qual swaps found", systemImage: "arrow.triangle.swap",
                                description: Text("No off dispatcher could take these international shifts with a desk swap. Try other days."))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            TabView {
                                ForEach(byDay, id: \.day) { group in
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text(SwapChips.chipDay(group.day)).font(.title3.bold()).padding(.horizontal)
                                            Text("Select who to ask for this day, then broadcast. Each request only goes out for the day it covers.")
                                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                                            ForEach(group.pkgs) { pkg in selectableRow(pkg) }
                                        }.padding(.vertical)
                                    }.tag(group.day)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .always))
                            broadcastBar
                        }
                    }
                }
            }
            .navigationTitle("Qual Swaps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !byDay.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selected.count == allIDs.count ? "Deselect All" : "Select All") {
                            selected = selected.count == allIDs.count ? [] : Set(allIDs)
                        }
                    }
                }
            }
            .onAppear { if selected.isEmpty { selected = Set(allIDs) } }   // default: everyone selected
        }
    }

    /// Clear multi-day breakdown: how many of the selected days need a qual swap, which had a bridge,
    /// which didn't, and which are normal days handled by Find.
    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("^[\(qualGatedDays.count) of \(workingShifts.count) selected day](inflect: true) need a qual swap.")
                .font(.subheadline.weight(.semibold))
            if !solvedDays.isEmpty {
                Label("Options for: \(dayList(solvedDays.sorted()))", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(AppColor.success)
            }
            if !unsolvedQualDays.isEmpty {
                Label("No bridge found for: \(dayList(unsolvedQualDays))", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(AppColor.heat)
            }
            if !normalDays.isEmpty {
                Label("Normal days (trade in Find): \(dayList(normalDays))", systemImage: "arrow.left.arrow.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func selectableRow(_ pkg: TradePackage) -> some View {
        let on = selected.contains(pkg.id)
        return Button {
            if on { selected.remove(pkg.id) } else { selected.insert(pkg.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pkg.assignments.first?.name ?? "Taker").font(.subheadline.bold())
                    if let leg = pkg.qualSwap {
                        Text("desk \(leg.giveDesk) (\(leg.giveQual)) · ^[\(leg.candidates.count) bridge](inflect: true)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(.bar, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Color.accentColor : .clear, lineWidth: 1.5))
            .padding(.horizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var broadcastBar: some View {
        HStack {
            Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { onBroadcast(selectedPkgs) } label: {
                Label("Broadcast", systemImage: "megaphone.fill").font(.subheadline.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
        }
        .padding()
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Q2: the multi-select "who to ask" blast picker. Lists every dispatcher who could
/// qual-swap onto the give-desk; the user selects which to blast (default = all).
struct QualSwapPickerSheet: View {
    let giveDeskLabel: String
    let takerName: String
    let dayLabel: String
    let candidates: [QualSwapCandidate]
    let onSend: (Set<String>) -> Void
    @State private var selected: Set<String>
    @Environment(\.dismiss) private var dismiss

    init(giveDeskLabel: String, takerName: String, dayLabel: String,
         candidates: [QualSwapCandidate], onSend: @escaping (Set<String>) -> Void) {
        self.giveDeskLabel = giveDeskLabel; self.takerName = takerName; self.dayLabel = dayLabel
        self.candidates = candidates; self.onSend = onSend
        _selected = State(initialValue: Set(candidates.map(\.workerID)))   // default: ask everyone eligible
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(takerName) can't work \(giveDeskLabel) on \(dayLabel). These dispatchers are working that day and could **qual-swap** onto it, freeing their desk for \(takerName). Pick who to ask — the first 5 to accept can respond.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Who to ask (\(selected.count)/\(candidates.count))") {
                    ForEach(candidates) { c in
                        Button {
                            if selected.contains(c.workerID) { selected.remove(c.workerID) }
                            else { selected.insert(c.workerID) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text("frees desk \(c.desk) (\(c.qual))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selected.contains(c.workerID) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(c.workerID) ? AppColor.success : .secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Request qual swap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { onSend(selected) }.disabled(selected.isEmpty)
                }
            }
        }
    }
}

/// The key under the trade calendars — now the shared comprehensive, collapsed-by-default
/// color key. (In the calendars themselves: border = trades away, fill = takes, each in that
/// person's own color — spelled out inside the legend.)
struct MiniScheduleLegend: View {
    var body: some View { CollapsibleLegend() }
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
    var accent: Color = AppColor.primary            // THIS calendar owner's signature color (You=blue, peer=red)
    var giveDays: Set<String> = []       // owner GIVES these away → own-color border
    var takeDays: Set<String> = []       // owner RECEIVES these → own-color fill
    var loopDays: Set<String> = []       // circular handoff between OTHERS → violet fill+border
    var focusDay: String? = nil          // the selected step's day → bold focus ring
    var gold: Set<String> = []           // mutually-wanted → gold border
    var intent: (String) -> Color? = { _ in nil }              // thick bottom bar (toggle-able by caller)
    var topology: (String) -> DayTopology = { _ in .standard } // high-impact / personal-day circle
    var eventName: (String) -> String? = { _ in nil }          // popover text when a marked day is tapped
    var fill: Bool = false               // stretch rows to fill the container's height (scale-to-fit on iPad)

    @State private var openEvent: String?

    private let cal = Calendar.current
    private let blue = AppColor.primary
    private let goldBorder = AppColor.pending
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
            Text(title).font(.headline).foregroundStyle(accent).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .frame(maxHeight: fill ? .infinity : nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil)
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
            .frame(height: fill ? 23 : 32)
            Text(label.isEmpty ? " " : label)
                // As large as the cell allows (subheadline, up from caption); minimumScaleFactor lets it
                // shrink on narrow/side-by-side cells so it never wraps, clips, or overlaps.
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(working ? accent : .secondary)
                .lineLimit(1).minimumScaleFactor(0.5)
                // Clear the 5-pt intent bar that overlays the bottom edge, so shift labels
                // (e.g. "AM 82") aren't clipped by it in fill mode.
                .padding(.bottom, fill ? 5 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: fill ? 30 : 50, maxHeight: fill ? .infinity : nil)
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
        if loopDays.contains(key) { return BrickPalette.loopTrade.opacity(0.5) }  // 3rd-party handoff
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
        // Focus (selected step) wins — a bold high-contrast ring on top of any fill.
        if focusDay == key { shape.stroke(.primary, lineWidth: 3.5) }
        else if loopDays.contains(key) { shape.stroke(BrickPalette.loopTrade, lineWidth: 3) }
        else if giveDays.contains(key) { shape.stroke(accent, lineWidth: 3) }
        else if gold.contains(key) { shape.stroke(goldBorder, lineWidth: 2) }
    }
}

/// One small box per day you're trading away: the day-of-month over your shift
/// letter, solid green when this candidate can cover it, faint grey when not.
struct CoverageStrip: View {
    let shifts: [Shift]
    let covered: Set<String>

    private let coverGreen = AppColor.success
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
                .background(cell.isTarget ? AppColor.pending.opacity(0.85) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

// MARK: - CaseIterable for ForEach

extension ShiftAvailabilityType: Identifiable {
    public var id: String { rawValue }
}

// MARK: - ECB Accounting (B6-ECB)

/// The ECB bookkeeping register: a balance derived from dated line items, opened from the top-bar ⋯ menu.
struct ECBAccountingView: View {
    private var store = ECBAccountingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var editing: ECBEntry?
    @State private var capBlocked = false
    private var myID: String { SettingsManager.shared.username }

    var body: some View {
        NavigationStack {
            List {
                Section { balanceHeader }
                if !store.pendingConfirmations.isEmpty {
                    Section {
                        Label("^[\(store.pendingConfirmations.count) shared trade](inflect: true) awaiting confirmation — respond in your Inbox.",
                              systemImage: "clock.badge.questionmark")
                            .font(.caption).foregroundStyle(AppColor.pending)
                    }
                }
                if store.register.isEmpty {
                    Section {
                        ContentUnavailableView("No ECB activity yet", systemImage: "banknote",
                            description: Text("Tap + to log overtime, holiday pay, a withdrawal, or a trade with another dispatcher."))
                    }
                } else {
                    Section("Register") {
                        ForEach(store.register) { e in
                            row(e)
                                .contentShape(Rectangle())
                                .onTapGesture { editing = e }
                                .swipeActions(edge: .leading) {
                                    // Mark a scheduled (agreed, un-posted) line as cleared/received.
                                    if e.isAgreed && !e.cleared {
                                        Button {
                                            if !store.markCleared(id: e.id) { capBlocked = true }
                                        } label: { Label(e.isShared ? "Received" : "Cleared", systemImage: "checkmark.circle") }
                                        .tint(AppColor.success)
                                    } else if e.cleared {
                                        Button { store.markCleared(id: e.id, false) } label: {
                                            Label("Un-clear", systemImage: "arrow.uturn.backward")
                                        }.tint(.secondary)
                                    }
                                }
                        }
                        .onDelete { idx in
                            let items = store.register
                            idx.map { items[$0].id }.forEach { store.delete(id: $0) }
                        }
                    }
                }
            }
            .navigationTitle("ECB Accounting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add line item")
                }
            }
            .sheet(isPresented: $showAdd) { ECBAddSheet().magnifiable() }
            .sheet(item: $editing) { ECBAddSheet(editing: $0).magnifiable() }
            .alert("Over the 144 cap", isPresented: $capBlocked) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Clearing this would push your available ECB over 144. Add a withdrawal first, then clear it.")
            }
        }
    }

    private var balanceHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Left: the two headline numbers (Available now + Projected). Right: a smaller card with
            // Owe / Owed stacked vertically — same row, visually secondary to the big balances.
            HStack(alignment: .top, spacing: 16) {
                HStack(alignment: .top, spacing: 20) {
                    bigStat("Available now", store.available, store.available < 0 ? AppColor.danger : AppColor.success,
                            caption: "/ \(ecbText(ECBAccounting.maxBalance)) max")
                    bigStat("Projected", store.projected, .primary,
                            caption: "once scheduled + IOUs clear")
                }
                Spacer(minLength: 8)
                // Owe / Owed card — ALWAYS shown so your position is visible; counts every uncleared
                // shared line by side, incl. awaiting-confirm ones (matches the register).
                VStack(alignment: .leading, spacing: 8) {
                    midStat("You owe", outstandingOwe, AppColor.danger)
                    midStat("Owed to you", outstandingOwed, AppColor.success)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            if pendingCount > 0 {
                Text("^[\(pendingCount) line](inflect: true) still awaiting confirmation — counts once confirmed and cleared.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if store.available >= ECBAccounting.maxBalance - 0.0001 {
                Label("At the 144 cap — withdraw before clearing more.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(AppColor.pending)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bigStat(_ label: String, _ value: Double, _ color: Color, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(ecbText(value)).font(.system(size: 32, weight: .bold).monospacedDigit()).foregroundStyle(color)
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
    }
    private func midStat(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(ecbText(value)).font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(color)
        }
    }

    /// Every uncleared shared line where I'm the payer (I'll pay ECB), incl. awaiting-confirm.
    private var outstandingOwe: Double {
        store.entries.filter { $0.isShared && !$0.cleared && $0.payerID == myID }
            .reduce(0) { $0 + abs($1.amount) }
    }
    /// Every uncleared shared line where I'm the payee (they'll pay me), incl. awaiting-confirm.
    private var outstandingOwed: Double {
        store.entries.filter { $0.isShared && !$0.cleared && $0.payeeID == myID }
            .reduce(0) { $0 + abs($1.amount) }
    }
    /// Shared lines not yet confirmed by the counterparty.
    private var pendingCount: Int {
        store.entries.filter { $0.isShared && $0.state != .confirmed }.count
    }

    @ViewBuilder private func row(_ e: ECBEntry) -> some View {
        let signed = ECBAccounting.signedAmount(for: myID, e)
        let pending = e.isShared && e.state != .confirmed
        HStack(spacing: 10) {
            Image(systemName: e.category.symbol)
                .foregroundStyle(signed < 0 ? AppColor.danger : AppColor.success)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.isShared ? "Trade · \(e.counterpartyName(myID: myID) ?? "dispatcher")" : e.category.label)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle(e)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(signed >= 0 ? "+" : "−")\(ecbText(abs(signed)))")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(signed < 0 ? AppColor.danger : AppColor.success)
                statusChip(e)
            }
        }
        .opacity(pending ? 0.6 : 1)
    }

    /// Right-aligned status under the amount: confirmation state first, else cleared vs scheduled.
    @ViewBuilder private func statusChip(_ e: ECBEntry) -> some View {
        if e.isShared && e.state == .pendingIncoming {
            Text("Confirm in Inbox").font(.caption2).foregroundStyle(AppColor.pending)
        } else if e.isShared && e.state == .pendingOutgoing {
            Text("Awaiting confirm").font(.caption2).foregroundStyle(AppColor.pending)
        } else if !e.cleared {
            Text(e.isShared ? "Scheduled · swipe to receive" : "Scheduled · swipe to clear")
                .font(.caption2).foregroundStyle(AppColor.pending)
        } else {
            Label("Cleared", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly).font(.caption2).foregroundStyle(AppColor.success)
        }
    }

    private func subtitle(_ e: ECBEntry) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"
        let date = f.string(from: e.date)
        return e.memo.isEmpty ? date : "\(date) · \(e.memo)"
    }
}

/// Add / edit an ECB line. Segmented type: Add · Subtract · Trade · Set balance.
struct ECBAddSheet: View {
    var editing: ECBEntry? = nil
    private var store = ECBAccountingStore.shared
    @Environment(\.dismiss) private var dismiss
    private var myID: String { SettingsManager.shared.username }

    enum Mode: String, CaseIterable, Identifiable { case add = "Add", subtract = "Subtract", trade = "Trade", setBalance = "Set balance"; var id: String { rawValue } }
    @State private var mode: Mode = .add
    @State private var creditCat: ECBCategory = .overtime
    @State private var debitCat: ECBCategory = .withdrawal
    @State private var amount: Double = 1
    @State private var memo = ""
    @State private var target: Double = 0
    @State private var payDate = Date()         // effective / pay date this line posts
    @State private var alreadyPosted = false    // add/subtract that already hit the balance → cleared now
    @State private var overCapacity = false     // IOU/trade exceeds what I can promise
    // Trade
    @State private var dispatchers: [(id: String, name: String)] = []
    @State private var counterpartyID = ""
    @State private var iPaid = true

    init(editing: ECBEntry? = nil) { self.editing = editing }

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil {
                    Picker("Type", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
                switch mode {
                case .add:
                    Picker("Category", selection: $creditCat) {
                        ForEach(ECBCategory.creditCases) { Text($0.label).tag($0) }
                    }
                    amountStepper
                    // Preset OT rates — prefill the standard ECB values (payroll conversions).
                    HStack(spacing: 8) {
                        Button("1.5× OT · 13.04") { creditCat = .overtime; amount = 13.04 }
                        Button("2× OT · 17.39") { creditCat = .overtime; amount = 17.39 }
                        Spacer()
                    }
                    .buttonStyle(.bordered).controlSize(.small).font(.caption)
                    payDateRow
                    memoField
                case .subtract:
                    Picker("Category", selection: $debitCat) {
                        ForEach(ECBCategory.debitCases) { Text($0.label).tag($0) }
                    }
                    amountStepper
                    payDateRow
                    memoField
                case .trade:
                    Picker("Dispatcher", selection: $counterpartyID) {
                        Text("Select…").tag("")
                        ForEach(dispatchers, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("Direction", selection: $iPaid) {
                        Text("I paid them").tag(true)
                        Text("They paid me").tag(false)
                    }.pickerStyle(.segmented)
                    amountStepper
                    DatePicker("Arrives / pay date", selection: $payDate, displayedComponents: .date)
                    memoField
                    if iPaid {
                        if store.payableCapacity <= 0.0001 {
                            Text("You have no ECB to trade yet — log a cleared balance or a scheduled deposit (OT / Holiday) first. You can only promise what you have or will have.")
                                .font(.caption).foregroundStyle(AppColor.pending)
                        } else {
                            Text("You can trade up to \(ecbText(store.payableCapacity)) ECB — your cleared balance plus scheduled deposits. Anything beyond your cleared balance is an IOU that settles when your deposit lands.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .setBalance:
                    HStack {
                        Text("Available now")
                        Spacer()
                        TextField("0", value: $target, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .monospacedDigit().frame(maxWidth: 120)
                    }
                    Text("Adds a dated Adjustment (cleared) line so your available balance equals the sum of your entries.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(editing == nil ? "Add ECB line" : (editing!.isShared ? "Edit trade line" : "Edit line"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { if save() { dismiss() } }.disabled(!canSave) }
            }
            .alert("Not enough ECB to promise", isPresented: $overCapacity) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You can only trade/IOU up to \(ecbText(store.payableCapacity)) ECB — your cleared balance plus scheduled deposits. Log the deposit first, or lower the amount.")
            }
            .task { await loadDispatchers(); preload() }
        }
    }

    /// Pay/effective date + an "already posted" shortcut for add/subtract lines.
    private var payDateRow: some View {
        Group {
            DatePicker("Pay date", selection: $payDate, displayedComponents: .date)
            Toggle("Already posted (counts now)", isOn: $alreadyPosted)
        }
    }

    /// Free decimal amount entry (ECB isn't restricted to 0.5 increments).
    private var amountStepper: some View {
        HStack {
            Text("ECB")
            Spacer()
            TextField("0", value: $amount, format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .monospacedDigit().frame(maxWidth: 120)
        }
    }
    private var memoField: some View {
        TextField("Note (optional)", text: $memo).font(.subheadline)
    }
    private var canSave: Bool {
        switch mode {
        case .trade: return !counterpartyID.isEmpty && amount > 0
        case .setBalance: return true
        default: return amount > 0
        }
    }

    private func preload() {
        guard let e = editing else { return }
        memo = e.memo; amount = abs(e.amount == 0 ? 1 : e.amount)
        payDate = e.date; alreadyPosted = e.cleared
        if e.isShared {
            mode = .trade
            counterpartyID = e.counterpartyID(myID: myID) ?? ""
            iPaid = e.payerID == myID
        } else if let credit = e.category.isCredit {
            mode = credit ? .add : .subtract
            if credit { creditCat = e.category } else { debitCat = e.category }
        }
    }

    /// Returns true on success. Trade/IOU over `payableCapacity` fails (keeps the sheet open + alerts).
    private func save() -> Bool {
        if let e = editing {
            if e.isShared {
                store.proposeSharedEdit(id: e.id, magnitude: amount, iPaid: iPaid, memo: memo, date: payDate)
            } else {
                store.editPersonal(id: e.id, magnitude: amount, memo: memo, date: payDate)
            }
            return true
        }
        switch mode {
        case .add:      store.addPersonal(category: creditCat, magnitude: amount, memo: memo, date: payDate, cleared: alreadyPosted)
        case .subtract: store.addPersonal(category: debitCat, magnitude: amount, memo: memo, date: payDate, cleared: alreadyPosted)
        case .setBalance: store.setBalance(to: target, date: Date())
        case .trade:
            let name = dispatchers.first { $0.id == counterpartyID }?.name ?? counterpartyID
            if !store.addTradeLine(counterpartyID: counterpartyID, counterpartyName: name,
                                   magnitude: amount, iPaid: iPaid, memo: memo, date: payDate) {
                overCapacity = true
                return false
            }
        }
        return true
    }

    private func loadDispatchers() async {
        if !TradeFeedCache.shared.allDispatchers.isEmpty { dispatchers = TradeFeedCache.shared.allDispatchers; return }
        let now = Date(); let end = Calendar.current.date(byAdding: .month, value: 12, to: now) ?? now
        let entries = await RosterStore.shared.entries(from: now, to: end)
        var seen = Set<String>(); var out: [(id: String, name: String)] = []
        for e in entries where e.workerID != myID && seen.insert(e.workerID).inserted {
            out.append((e.workerID, TradeNames.resolved(displayName: nil, rosterName: e.workerName, workerID: e.workerID)))
        }
        dispatchers = out.sorted { $0.name < $1.name }
        TradeFeedCache.shared.allDispatchers = dispatchers
    }
}
