// TradeIntentsFeed.swift
// The "Trade by Intents" feed (4 tier accordions from TradeRouter.tieredSolutions)
// plus the N-way chain card and the execution-confirmation checkout.

import SwiftUI

// MARK: - Feed result cache (keeps each Trades tab loaded across tab switches)

/// Per-tab snapshot so moving between Intents / Trade Solutions / ECB doesn't destroy results or
/// re-run the engine when nothing changed. A feed restores its snapshot on appear and recomputes only
/// when its input SIGNATURE (intents revision + max-people + What-If + selected days) differs. The
/// `switch segment` in TradesView tears each feed down on every tab change, so without this the
/// (main-actor, heavy) search re-runs every return. (U-PERF.)
@MainActor @Observable
final class TradeFeedCache {
    static let shared = TradeFeedCache()
    private init() {}

    struct Snapshot {
        var signature: Int
        var selectedIDs: Set<String> = []
        var packages: [TradePackage] = []            // ALL-mode results (superset) — only when generated
        var mutualPackages: [TradePackage] = []      // Mutual-mode subset (always computed)
        var allLoaded: Bool = false                  // has the heavier ALL set been generated this search?
        var candidates: [PlanCandidate] = []
        var rosterPeople: [(id: String, name: String)] = []
        var hasSearched: Bool = false
    }
    private var snaps: [String: Snapshot] = [:]
    func snapshot(_ key: String) -> Snapshot? { snaps[key] }
    func save(_ key: String, _ snap: Snapshot) { snaps[key] = snap }
    func clear(_ key: String) { snaps[key] = nil }

    /// Number of MUTUAL intent matches — drives the Intents tab badge. Set by the feed's mutual-mode
    /// searches and the launch background pass; read live by the segment bar (this class is @Observable).
    var intentMatchCount: Int = 0

    /// Full distinct roster (minus self), names resolved — loaded ONCE per session for the
    /// "Look up a dispatcher" dropdown (moved from the former Just 2 tab) so it isn't re-fetched
    /// on every tab return.
    var allDispatchers: [(id: String, name: String)] = []

    /// A stable hash of the inputs that change a feed's results. Days are optional (Intents seeds from
    /// marked intent, not a day picker).
    static func signature(selectedIDs: Set<String> = [], whatIf: Bool) -> Int {
        var h = Hasher()
        h.combine(DayIntentStore.shared.intentsRevision)
        h.combine(SettingsManager.shared.normalMaxPeople)
        h.combine(whatIf)
        for id in selectedIDs.sorted() { h.combine(id) }
        return h.finalize()
    }
}

// MARK: - Feed

struct TradeByIntentsFeed: View {

    @Binding var whatIf: Bool

    @State private var packages: [TradePackage] = []        // ALL-mode results (superset)
    @State private var mutualPackages: [TradePackage] = []  // Mutual subset — both computed once per search
    @State private var loading = true
    @State private var execRoute: NWayRoute?
    @State private var sentMessage: String?
    @State private var detailPackage: TradePackage?
    @State private var pkgSwap: PackageSwapContext?   // Q1: qual-swap package → blast picker
    // A1/A2: Master Filter — shapes the on-demand "I'm Feeling Lucky" search; chips stay visible.
    @State private var searchFilter = SearchFilter()
    @State private var showFilter = false
    @State private var rosterPeople: [(id: String, name: String)] = []
    @State private var searchTask: Task<Void, Never>?   // A1: cancellable Lucky search
    @State private var mutualOnly = true   // Mutual (both sides marked) vs All (also one-sided, active peers)
    @State private var allLoaded = false   // whether the heavier "All" superset has been generated this search
    // Resolved type + desk-qual for every result day, so the Lucky shift-time / qual filters apply here too
    // (same as Trade Solutions). Built per search from the peers' + my schedules.
    @State private var dayType: [String: ShiftAvailabilityType] = [:]   // "workerID|dayID" → that shift's type
    @State private var dayQual: [String: String] = [:]                  // "workerID|dayID" → desk's required qual
    @State private var myDayQual: [String: String] = [:]                // my give-day id → desk's required qual

    /// The result set for the current toggle — Mutual (subset) or All (superset). Both are computed in one
    /// search and cached, so flipping the toggle is an instant state change (no engine re-run).
    private var activePackages: [TradePackage] { mutualOnly ? mutualPackages : packages }
    /// A1/A2: filtered + capped (best-first via the unified rankLess order) view of the results. The Lucky one-time
    /// shift-time / qual overrides are applied here (`criteriaMatch`), matching Trade Solutions.
    private var displayed: [TradePackage] {
        Array(searchFilter.filter(activePackages, selfID: SettingsManager.shared.username)
            .filter(criteriaMatch).prefix(100))
    }

    /// A2: the Lucky shift-time (`receiveTypes`) + desk-qual (`deskQuals`) filters, applied to a result using
    /// the resolved day maps. Empty selections = no narrowing. Mirrors `FindCandidatesSection.criteriaMatch`.
    private func criteriaMatch(_ p: TradePackage) -> Bool {
        let types = searchFilter.receiveTypes
        let quals = searchFilter.deskQuals
        if types.isEmpty && quals.isEmpty { return true }
        let myID = SettingsManager.shared.username
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
            if leg.toID == myID { recvTypes.insert(.infer(fromStartHour: leg.startHour)) }
            if let q = DeskRules.requiredQual(forDesk: leg.desk) { deskQuals.insert(q) }
        }
        if !types.isEmpty, recvTypes.isDisjoint(with: types) { return false }
        if !quals.isEmpty, deskQuals.isDisjoint(with: quals) { return false }
        return true
    }

    /// The deeper-search button label reflects the active one-time criteria (or the default name).
    /// "More: 3+ & loops" = the on-demand heavy search for 3+person / circular options (the normal feed
    /// stays fast at two-person swaps).
    private var luckyTitle: String {
        searchFilter.summary(nameFor: { id in rosterPeople.first { $0.id == id }?.name ?? id })
            .map { "More: \($0)" } ?? "More: 3+ & loops"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !loading {
                    luckyBar
                    // Mutual = both sides marked (true intent matches). All = also one-sided deals where
                    // an ACTIVE peer could take days you marked. Robots/inactives are excluded in both.
                    DXSegmented(selection: $mutualOnly, options: [.init(true, "Mutual"), .init(false, "All")],
                                color: { $0 ? AppColor.heat : AppColor.primary })
                        .padding(.horizontal).padding(.top, 4)
                    // No re-run on toggle: both Mutual + All were computed in one search (instant flip).
                    // Trade size (Max people) is a Lucky-time option — only shown once Lucky is engaged.
                    if searchFilter.isActive {
                        MaxPeoplePicker().padding(.horizontal).padding(.top, 4)
                    }
                }

                if loading {
                    // Animation truly centered in height; Cancel pinned to the bottom (overlay, so it
                    // doesn't pull the animation above center).
                    AnimatedLoader(name: "finding-matches", contentMode: .fit)
                        .containerRelativeFrame(.horizontal) { w, _ in w * 0.92 }
                        .clipped()
                        .padding(.vertical, 56)   // substantial breathing room off the segment bar (top + bottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            Button(role: .cancel) { searchTask?.cancel(); loading = false } label: {
                                Image(systemName: "xmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Cancel")
                            .padding(.bottom, 8)
                        }
                } else if displayed.isEmpty {
                    ContentUnavailableView("No Intent Matches",
                        systemImage: "sparkles",
                        description: Text(activePackages.isEmpty
                            ? (mutualOnly
                               ? "No two-sided intent matches yet — mark days to trade away on Home, and as others mark theirs, matches appear here. Switch to All to see active people who could take the days you marked."
                               : "Mark days to trade away on Home. Tap “More: 3+ & loops” for 3+ person and circular options.")
                            : "No matches fit your current filter — tap the filter to widen it."))
                        .padding(.top, 20)
                } else {
                    sectionHeader("Intent Matches", "Most mutual intent first — your marked days matched with theirs (🔥 = both sides marked)")
                    ForEach(displayed) { pkg in
                        if pkg.usesCompactCard {   // B4-14: 2-person → compact ECB-style card
                            CompactSwapCard(package: pkg,
                                            onPropose: { p in Task { await propose(p) } },
                                            onOpen: { detailPackage = pkg })
                        } else {
                            PackageCard(package: pkg,
                                        onPropose: { Task { await propose(pkg) } },
                                        onExecute: { if let r = pkg.route { execRoute = r } },
                                        onOpen: { detailPackage = pkg })
                        }
                    }
                    TradeFeedKey().padding(.horizontal).padding(.top, 8)
                }
            }
            .padding(.bottom, 24)
        }
        .fullScreenCover(item: $detailPackage) { pkg in
            PackageDetailView(package: pkg,
                              onPropose: { p in Task { await propose(p) } },
                              onExecute: { if let r = pkg.route { execRoute = r } })
                .magnifiable()
        }
        .sheet(item: $execRoute) { ExecutionConfirmationView(route: $0, origin: .intents) }
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
                        take: [], give: [ctx.leg.giveShiftDayID], qualSwap: sendLeg, origin: .intents)
                    WidgetData.update()
                    pkgSwap = nil
                    sentMessage = "Qual-swap request sent. Track it in your Inbox."
                }
            }
        }
        .sheet(isPresented: $showFilter) {
            MasterFilterSheet(filter: $searchFilter, people: rosterPeople,
                              availableQuals: SettingsManager.shared.cachedQuals.sorted(),   // show the Desk-qual filter
                              searchShiftCount: max(1, DayIntentStore.shared.seekingDayIDs.count),   // marked trade-aways
                              onGenerate: { f in runSearch { await reload(generation: f, lucky: true, computeAll: true); cacheSnapshot() } },
                              onReset: { runSearch { await reloadFast() } })
        }
        .task {
            // U-PERF: restore the last results instantly if nothing changed; otherwise run a
            // CANCELLABLE fast search (so the spinner shows a working Cancel and the engine yields).
            if let snap = TradeFeedCache.shared.snapshot(Self.cacheKey),
               snap.signature == TradeFeedCache.signature(whatIf: whatIf) {
                packages = snap.packages; mutualPackages = snap.mutualPackages
                allLoaded = snap.allLoaded
                rosterPeople = snap.rosterPeople; loading = false
            } else {
                runSearch { await reloadFast() }
            }
        }
        // Switching to All generates the heavier superset ONCE (Mutual is already computed); switching
        // back to Mutual is instant. Opening Intents therefore never pays for All unless it's asked for.
        .onChange(of: mutualOnly) { _, isMutual in
            if !isMutual, !allLoaded { runSearch { await reloadAll() } }
        }
        .onChange(of: whatIf) { _, _ in runSearch { await reloadFast() } }
        // C1: recompute on an explicit SAVE (intents revision) — NOT on every edit (was
        // MatchInputsSignature, which re-ran the heavy search on every keystroke). Background
        // reruns stay FAST (2-person) — the heavy 3+/N-Way search only runs via Lucky → Generate.
        .onChange(of: DayIntentStore.shared.intentsRevision) { _, _ in runSearch { await reloadFast() } }
        .onChange(of: SettingsManager.shared.normalMaxPeople) { _, _ in runSearch { await reloadFast() } }
        .onDisappear { searchTask?.cancel() }   // A1: leaving cancels any in-flight Lucky search
        .alert("Package sent", isPresented: Binding(
            get: { sentMessage != nil }, set: { if !$0 { sentMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(sentMessage ?? "") }
    }

    /// A1/A2: the "I'm Feeling Lucky" filter bar — a button to shape the search + visible chips
    /// of the active choices.
    private var luckyBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showFilter = true } label: {
                Label(luckyTitle, systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .tint(searchFilter.isActive ? AppColor.heat : nil)
            if searchFilter.isActive {
                HStack(spacing: 6) {
                    chip("One-time generation — tap to change or reset")
                    Spacer()
                }
                .font(.caption2)
            }
        }
        .padding(.horizontal).padding(.top, 4)
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.title3.bold())
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.top, 4)
    }

    /// A1: run a search, CANCELLING any still-running one first (re-Generate / Reset / SAVE / What-If
    /// supersedes the previous Lucky search instead of racing it).
    private func runSearch(_ work: @escaping () async -> Void) {
        searchTask?.cancel()
        searchTask = Task {
            // B4-10: debounce — coalesce rapid triggers (SAVE + whatIf + max-people can fire together) so
            // the engine starts once for the settled input. A superseded task is cancelled during the
            // sleep and bails; the final trigger still runs (result-neutral for the settled state).
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            await work()
        }
    }

    /// Background/default: fast 2-person generation, and clear any Lucky filter so the
    /// 2-person results aren't hidden by a stale engine/people selection.
    private func reloadFast() async {
        searchFilter = .normal
        // Opening Intents (and background SAVE / What-If reruns) computes ONLY the Mutual set — fast.
        // "All" is generated lazily when the user taps it. If they're CURRENTLY viewing All, keep it fresh.
        await reload(generation: SearchFilter(engine: .both, maxPeople: SettingsManager.shared.normalMaxPeople),
                     computeAll: !mutualOnly)
        if Task.isCancelled { return }
        cacheSnapshot()
    }

    /// Generate the heavier "All" superset on demand (when the user switches to the All tab), keeping the
    /// already-computed Mutual results.
    private func reloadAll() async {
        await reload(generation: SearchFilter(engine: .both, maxPeople: SettingsManager.shared.normalMaxPeople),
                     computeAll: true)
        if Task.isCancelled { return }
        cacheSnapshot()
    }

    /// Cache both result sets (+ whether All was generated) so tab switches / toggles restore instantly.
    private func cacheSnapshot() {
        TradeFeedCache.shared.save(Self.cacheKey, .init(
            signature: TradeFeedCache.signature(whatIf: whatIf),
            packages: packages, mutualPackages: mutualPackages, allLoaded: allLoaded,
            rosterPeople: rosterPeople, hasSearched: true))
    }

    private static let cacheKey = "intents"

    /// `generation` bounds the engine work: `.fast` (2-person, background) or the user's Lucky
    /// criteria (heavy 3+/N-Way, one-time). The display still filters via `searchFilter`.
    private func reload(generation: SearchFilter = .fast, lucky: Bool = false, computeAll: Bool = false) async {
        loading = true
        await TradeProfileStore.shared.refreshOthers()
        let myID = SettingsManager.shared.username
        // Intents uses its OWN engine — a marketplace of intent-for-intent deals involving you. Mutual
        // (both-sides-marked, active accounts) is ALWAYS computed: it's the default view + the badge count.
        let mutualResult = await TradeRouter.intentSolutions(excluding: myID, generation: generation,
                                                            lucky: lucky, mutualOnly: true)
        if Task.isCancelled { return }   // A1: superseded by a newer search — don't clobber its state
        mutualPackages = mutualResult
        // The Intents badge = number of MUTUAL matches.
        TradeFeedCache.shared.intentMatchCount = mutualResult.count
        // "All" (superset — every active peer, incl. one-sided deals) is heavier; only run it when asked
        // for (the All tab or an explicit Lucky generate), so opening Intents never pays for it.
        if computeAll {
            let allResult = await TradeRouter.intentSolutions(excluding: myID, generation: generation,
                                                              lucky: lucky, mutualOnly: false)
            if Task.isCancelled { return }
            packages = allResult
            allLoaded = true
        } else {
            packages = []
            allLoaded = false
        }
        // A2: people for the Connection dropdown — union of the roster, published peers, and anyone
        // already in a result — names resolved (G2a) — so it's never blank with a thin roster.
        let now = Date()
        let end = Calendar.current.date(byAdding: .month, value: 12, to: now) ?? now
        let entries = await RosterStore.shared.entries(from: now, to: end)
        var seen = Set<String>(); var people: [(id: String, name: String)] = []
        func add(_ id: String, _ name: String) {
            guard id != myID, seen.insert(id).inserted else { return }
            people.append((id, TradeNames.resolved(displayName: nil, rosterName: name, workerID: id)))
        }
        // Resolve each working day's type + desk-qual (reusing this window fetch) so the Lucky shift/qual
        // filters can narrow results here just like Trade Solutions.
        var dt: [String: ShiftAvailabilityType] = [:]; var dq: [String: String] = [:]
        for e in entries {
            add(e.workerID, e.workerName)
            if !e.isOff {
                dt["\(e.workerID)|\(e.day)"] = ShiftAvailabilityType.infer(fromStartHour: e.startHour)
                if let q = DeskRules.requiredQual(forDesk: e.desk) { dq["\(e.workerID)|\(e.day)"] = q }
            }
        }
        dayType = dt; dayQual = dq
        myDayQual = Dictionary(uniqueKeysWithValues: ShiftStore.shared.shifts.compactMap { s in
            (!s.isOff ? DeskRules.requiredQual(forDesk: s.desk) : nil).map { (s.id, $0) } })
        for (id, p) in TradeProfileStore.shared.others { add(id, p.displayName) }
        for pkg in (packages.isEmpty ? mutualPackages : packages) { for a in pkg.assignments { add(a.workerID, a.name) } }
        rosterPeople = people.sorted { $0.name < $1.name }
        loading = false
    }

    /// Greedy package: send a cover request to each assigned dispatcher. A qual-swap package
    /// opens the blast picker instead (Q1).
    private func propose(_ pkg: TradePackage) async {
        if let leg = pkg.qualSwap { pkgSwap = PackageSwapContext(leg: leg); return }
        for a in pkg.assignments {
            await MessagingStore.shared.sendRequest(
                to: a.workerID, toName: a.name, note: swapNote(a),
                take: a.takeDayIDs, give: a.giveDayIDs, origin: .intents)
        }
        WidgetData.update()
        let n = pkg.assignments.count
        sentMessage = "Sent to \(n) dispatcher\(n == 1 ? "" : "s"). Track replies in your Inbox."
    }
}

// MARK: - Feed key (explains the chips, flame, and quality pills)

/// Compact "max people in a trade" control shown on the Intents + Trade Solutions feeds (was in
/// Trade Settings). Writes `SettingsManager.normalMaxPeople`; the feed observes it and re-runs.
struct MaxPeoplePicker: View {
    private var settings = SettingsManager.shared
    var body: some View {
        HStack(spacing: 8) {
            Label("Trade size", systemImage: "person.3.fill").font(.caption).foregroundStyle(.secondary)
            DXSegmented(selection: Binding(get: { settings.normalMaxPeople }, set: { settings.normalMaxPeople = $0 }),
                        options: [.init(2, "Pairs"), .init(3, "≤ 3"), .init(4, "≤ 4")])
        }
    }
}

/// A2: the "I'm Feeling Lucky" Master Filter sheet — engine, max-people, force-include person.
/// Choices are shown as chips on the feed; the results are filtered by `SearchFilter.filter`.
struct MasterFilterSheet: View {
    @Binding var filter: SearchFilter
    let people: [(id: String, name: String)]
    var availableQuals: [String] = []
    /// How many shifts the searcher is trading away — the date range must span at least this many days
    /// (you can't receive N days back inside a window shorter than N). Drives the too-short-range prompt.
    var searchShiftCount: Int = 1
    /// One-time HEAVY generation with the chosen criteria (runs 3+ / N-Way).
    var onGenerate: (SearchFilter) -> Void = { _ in }
    /// Back to the section's fast NORMAL generation (2-person only).
    var onReset: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SearchFilter
    @State private var limitDates = false   // gate the date-range pickers

    init(filter: Binding<SearchFilter>, people: [(id: String, name: String)], availableQuals: [String] = [],
         searchShiftCount: Int = 1,
         onGenerate: @escaping (SearchFilter) -> Void = { _ in }, onReset: @escaping () -> Void = {}) {
        _filter = filter; self.people = people; self.availableQuals = availableQuals
        self.searchShiftCount = max(1, searchShiftCount)
        self.onGenerate = onGenerate; self.onReset = onReset
        _draft = State(initialValue: filter.wrappedValue)
        _limitDates = State(initialValue: filter.wrappedValue.dateStart != nil || filter.wrappedValue.dateEnd != nil)
    }

    /// Inclusive day-span of the chosen range (1 when from == to). nil when the range is off.
    private var rangeSpanDays: Int? {
        guard limitDates, let s = draft.dateStart, let e = draft.dateEnd else { return nil }
        let cal = Calendar.current
        let days = (cal.dateComponents([.day], from: cal.startOfDay(for: s), to: cal.startOfDay(for: e)).day ?? 0) + 1
        return max(0, days)
    }
    /// The range is too short to hold every day you'd receive back.
    private var rangeTooShort: Bool { (rangeSpanDays ?? Int.max) < searchShiftCount }

    var body: some View {
        NavigationStack {
            Form {
                // (Search-engine Min-Cost/N-Way/Both toggle retired — every match is a circular loop now,
                //  so the distinction was misleading. Generation always runs "Both"; the "Max people in a
                //  trade" control below is the real knob. "I'm Feeling Lucky" is unaffected.)
                Section("Max people in a trade") {
                    DXSegmented(selection: $draft.maxPeople, options: (1...4).map { .init($0, "\($0)") })
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section("Connection") {
                    Picker("Connection", selection: Binding(
                        get: { draft.requiredWorkerID ?? "" },
                        set: { draft.requiredWorkerID = $0.isEmpty ? nil : $0 })) {
                        Text("Anyone").tag("")
                        ForEach(people, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Text("Only show trades that include this dispatcher.").font(.caption2).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Limit to a date range", isOn: Binding(
                        get: { limitDates },
                        set: { on in
                            limitDates = on
                            if on {
                                if draft.dateStart == nil { draft.dateStart = Date() }
                                if draft.dateEnd == nil { draft.dateEnd = Date() }
                            } else { draft.dateStart = nil; draft.dateEnd = nil }
                        }))
                    if limitDates {
                        DatePicker("From", selection: Binding(get: { draft.dateStart ?? Date() },
                                                              set: { draft.dateStart = $0 }), displayedComponents: .date)
                        DatePicker("To", selection: Binding(get: { draft.dateEnd ?? Date() },
                                                            set: { draft.dateEnd = $0 }), displayedComponents: .date)
                    }
                        if rangeTooShort {
                        Label("Pick a range of at least \(searchShiftCount) day\(searchShiftCount == 1 ? "" : "s") — you're trading \(searchShiftCount) shift\(searchShiftCount == 1 ? "" : "s"), so you need that many days to receive them back.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(AppColor.pending)
                    }
                } header: { Text("Date range") }
                footer: { Text("The window is where you want to trade INTO — every day you'd receive back must fall inside it. A single date finds a single-day trade.") }

                Section {
                    HStack(spacing: 8) {
                        ForEach(ShiftAvailabilityType.allCases, id: \.self) { t in
                            let on = draft.receiveTypes.contains(t)
                            Button {
                                if on { draft.receiveTypes.remove(t) } else { draft.receiveTypes.insert(t) }
                            } label: {
                                Text(t.rawValue).font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(on ? AppColor.primary : Color(.tertiarySystemFill), in: Capsule())
                                    .foregroundStyle(on ? .white : .primary)
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                    }
                } header: { Text("Shift time you'd pick up") }
                footer: { Text("Only show trades where the shifts you'd receive are these types.") }

                if !availableQuals.isEmpty {
                    Section {
                        FlowLayout(spacing: 8) {
                            ForEach(availableQuals, id: \.self) { q in
                                let on = draft.deskQuals.contains(q)
                                Button {
                                    if on { draft.deskQuals.remove(q) } else { draft.deskQuals.insert(q) }
                                } label: {
                                    Text(q).font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(on ? AppColor.primary : Color(.tertiarySystemFill), in: Capsule())
                                        .foregroundStyle(on ? .white : .primary)
                                }.buttonStyle(.plain)
                            }
                        }
                    } header: { Text("Desk qualification") }
                    footer: { Text("Only show trades involving desks that require any of the selected quals.") }
                }
                Section {
                    Picker("Openness", selection: $draft.myOpennessOverride) {
                        Text("Use my setting").tag(TradeOpenness?.none)
                        Text("Bookends only").tag(TradeOpenness?.some(.bookends))
                        Text("Open to all").tag(TradeOpenness?.some(.all))
                    }
                } header: { Text("My openness") } footer: {
                    Text("Search with your openness set to this — just for this search. “Open to all” accepts any pickup that's physically possible (you're off, qualified, rested); “Bookends only” keeps just bookend days. Your blacklist still applies, and your saved setting isn't changed.")
                }
                Section {
                    // One-time HEAVY generation for the chosen criteria (3+ loops included).
                    Button {
                        draft.engine = .both   // toggle retired — always generate the full set; ranker curates
                        filter = draft; onGenerate(draft); dismiss()
                    } label: {
                        Label("Generate matches", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(rangeTooShort)   // too-short window can't hold every received day
                    // Reset back to the fast NORMAL generation (2-person only).
                    Button(role: .destructive) {
                        draft = .normal; filter = .normal; onReset(); dismiss()
                    } label: {
                        Label("Reset to normal", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                    }
                    .disabled(!filter.isActive && !draft.isActive)
                } footer: {
                    Text("Generate runs the heavy 3+ person and circular (N-Way) search once. The normal feed stays fast with two-person trades only.")
                }
            }
            .navigationTitle("More: 3+ & loops")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// The Intents-feed legend — now the shared comprehensive, collapsed-by-default color key.
struct TradeFeedKey: View {
    var body: some View { CollapsibleLegend() }
}

/// The intent-color legend used in the two-way sheet + ECB — the same shared collapsed key.
struct IntentColorKey: View {
    var body: some View { CollapsibleLegend() }
}

/// Stable per-trader calendar color (you are always blue). Same index → same color
/// across the package card and the dual-calendar view.
func traderColor(_ index: Int) -> Color {
    BrickPalette.traderThemes[index % BrickPalette.traderThemes.count]
}

/// One trader's days in THEIR color, matching their calendar: a small color dot +
/// name, then "Gives" (bordered chips = trades away) and "Gets" (filled chips = takes).
struct TraderChips: View {
    let name: String
    let color: Color
    let giveDays: [String]
    let getDays: [String]
    var maxChips = 5
    var id: String? = nil   // when set, shows the person's status in italics (A7/B8)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                DXSeatTile(color: color, size: 13)
                Text(name + (id.map(botSuffix) ?? "")).font(.dsCardTitle).foregroundStyle(color).lineLimit(1)
            }
            if let id, let status = participantStatus(id) {
                Text(status).font(.dsCardMeta).italic().foregroundStyle(.secondary).lineLimit(1)
            }
            if !giveDays.isEmpty { chipRow("Gives", giveDays, filled: false) }
            if !getDays.isEmpty  { chipRow("Gets", getDays, filled: true) }
        }
    }

    private func chipRow(_ lbl: String, _ days: [String], filled: Bool) -> some View {
        HStack(spacing: 5) {
            Text(lbl).font(.dsLabel).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            ForEach(days.prefix(maxChips), id: \.self) { iso in
                Text(SwapChips.chipDay(iso)).font(.dsChip)
                    .foregroundStyle(filled ? .white : color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(filled ? color : Color.clear, in: Capsule())
                    .overlay(Capsule().stroke(color, lineWidth: filled ? 0 : 1.5))
            }
            if days.count > maxChips { Text("+\(days.count - maxChips)").font(.dsBadge).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 13)
    }
}

// MARK: - Handoff chain (for circular trades: who hands which day to whom)

/// One directed handoff in a chain, names included so it renders offline (inbox).
struct HandoffStep: Identifiable, Hashable {
    let id: String
    let fromID: String, fromName: String
    let toID: String, toName: String
    let dayID: String
    var desk: String? = nil
}

/// Renders a multi-person loop as explicit directed handoffs — "You → Denny: Jul 4",
/// "Denny → Dimitry: Jul 8", "Dimitry → You: Jul 12" — so who gives/gets what is
/// unambiguous. Works from route legs (feed) or a request's chain (inbox).
struct HandoffChain: View {
    let steps: [HandoffStep]
    private var myID: String { SettingsManager.shared.username }

    init(steps: [HandoffStep]) { self.steps = steps }
    init(legs: [NWayLeg]) {
        self.steps = legs.map { HandoffStep(id: $0.id, fromID: $0.fromID, fromName: participantName($0.fromID),
                                            toID: $0.toID, toName: participantName($0.toID), dayID: $0.dayID, desk: $0.desk) }
    }
    init(chain: [TradeLeg]) {
        self.steps = chain.enumerated().map { i, l in
            HandoffStep(id: "\(i)|\(l.dayID)", fromID: l.fromID, fromName: l.fromName,
                        toID: l.toID, toName: l.toName, dayID: l.dayID, desk: l.desk) }
    }

    /// F1: positional seat color — non-me participants in first-appearance order across the legs.
    private var orderedPeers: [String] {
        var ids: [String] = []
        for s in steps { for id in [s.fromID, s.toID] where id != myID && !ids.contains(id) { ids.append(id) } }
        return ids
    }
    private func color(_ id: String) -> Color {
        TradeColors.color(forParticipant: id, myID: myID, orderedPeers: orderedPeers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(steps) { s in
                HStack(spacing: 6) {
                    Text(label(s.fromID, s.fromName)).font(.caption.weight(.semibold))
                        .foregroundStyle(color(s.fromID))
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Text(label(s.toID, s.toName)).font(.caption.weight(.semibold))
                        .foregroundStyle(color(s.toID))
                    Spacer(minLength: 6)
                    // Day chip in the GIVER's color (border) — matches that person's calendar.
                    Text(SwapChips.chipDay(s.dayID) + (s.desk.map { " · \($0)" } ?? ""))
                        .font(.dsChip)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(color(s.fromID).opacity(DS.pillFill), in: Capsule())
                        .foregroundStyle(color(s.fromID))
                }
            }
        }
    }

    private func label(_ id: String, _ name: String) -> String { id == myID ? "You" : firstName(name) }
}

// MARK: - Swap day chips (give = blue, get = red) — shared by route & package cards

/// Compact day chips for a swap: which days YOU give (blue) and get (red), matching
/// the calendar color language. Overflow collapses to "+N".
struct SwapChips: View {
    let giveDays: [String]
    let getDays: [String]
    var giveLabel = "You give"
    var getLabel = "You get"
    var labelWidth: CGFloat = 50
    var maxChips = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !giveDays.isEmpty { row(giveLabel, giveDays, BrickPalette.mineScheme) }
            if !getDays.isEmpty  { row(getLabel,  getDays,  BrickPalette.peerScheme) }
        }
    }

    private func row(_ label: String, _ days: [String], _ color: Color) -> some View {
        HStack(spacing: DS.xs + 1) {
            Text(label).font(.dsLabel).foregroundStyle(color)
                .frame(width: labelWidth, alignment: .leading)
            ForEach(days.prefix(maxChips), id: \.self) { iso in
                Text(Self.chipDay(iso))
                    .font(.dsChip)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(color.opacity(DS.pillFill), in: Capsule())
                    .foregroundStyle(color)
            }
            if days.count > maxChips {
                Text("+\(days.count - maxChips)").font(.dsBadge).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Compact card date — `MM/DD` (e.g. "07/16") to save horizontal room on the trade-solution cards.
    static func chipDay(_ iso: String) -> String {
        guard let d = TradeMatcher.dayDate(fromISO: iso) else { return iso }
        let f = DateFormatter(); f.dateFormat = "MM/dd"; return f.string(from: d)
    }
}

// MARK: - Package card (one card per deal)

/// B4-14: compact ECB-style card for two-person swaps — thin (more results per screen), shows the
/// counterparty's name + status snapshot, "You get" / "They get" **once each** (no PackageCard
/// duplication), badges (🔥/📖/Q), and Propose. Tapping opens their schedule. 3+-person and circular
/// keep `PackageCard`. Presentation-only: the same 2-way packages, in the same order (INV-2).
struct CompactSwapCard: View {
    let package: TradePackage
    /// Receives the package to actually propose — with the user's chosen give-back day baked in (they may
    /// have picked a different one from the ranked pool).
    let onPropose: (TradePackage) -> Void
    var onOpen: () -> Void = {}

    private var myID: String { SettingsManager.shared.username }
    private var messaging = MessagingStore.shared
    private var alreadySent: Bool { messaging.alreadyProposed(package) }

    /// The top-ranked give-back (bookend-first). Alternate days are chosen in the DETAIL view (tap the
    /// card) so the card stays a clean, consistent summary. (B6-GIVEBACK.)
    private var effectiveTake: [String] { package.assignments.first?.takeDayIDs ?? [] }
    /// Extra give-back options beyond the top pick — shown as a subtle "+N" so the user knows there are
    /// alternates to choose inside the card.
    private var extraTakeCount: Int {
        guard package.qualSwap == nil, let a = package.assignments.first, a.giveDayIDs.count == 1 else { return 0 }
        return max(0, a.takeOptions.count - 1)
    }

    var body: some View {
        let a = package.assignments.first
        let peerColor = a.map { TradeColors.color(forParticipant: $0.workerID, myID: myID, orderedPeers: [$0.workerID]) } ?? AppColor.neutral
        VStack(alignment: .leading, spacing: 6) {
            // Header: peer name + their status snapshot · badges · Propose.
            HStack(spacing: 8) {
                DXSeatTile(color: peerColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text((a?.name ?? "Swap") + (a.map { botSuffix($0.workerID) } ?? "")).font(.subheadline.weight(.semibold))
                    if let id = a?.workerID, let status = participantStatus(id), !status.isEmpty {
                        Text(status).font(.caption2).italic().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                badges
                Button { onPropose(package) } label: {
                    Label(alreadySent ? "Sent" : "Propose",
                          systemImage: alreadySent ? "checkmark.circle.fill" : "paperplane.fill")
                        .labelStyle(.iconOnly).font(.subheadline)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .tint(alreadySent ? AppColor.success : AppColor.primary)
                .disabled(alreadySent)
                .accessibilityLabel(alreadySent ? "Already sent" : "Propose")
            }
            // You get / Them get — each shown once, TOP give-back only (alternates are chosen in the detail
            // view). "+N" hints at more options. Consistent layout: the pair sits left, Spacer fills the rest.
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    swapLine("You", days: effectiveTake, color: BrickPalette.mineScheme)
                    if extraTakeCount > 0 {
                        Text("+\(extraTakeCount)").font(.caption2.weight(.semibold)).foregroundStyle(AppColor.pending)
                    }
                }
                swapLine("Them", days: a?.giveDayIDs ?? [], color: peerColor)
                Spacer(minLength: 0)
            }
            if package.qualSwap != nil {
                // Clear, always-visible notice (not just the small Q icon) that this match needs a qual swap.
                Label("Qual swap needed — tap to choose a bridge", systemImage: "q.square.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(AppColor.pending)
            }
            if DevAccess.shared.unlocked {
                Text("Match strength \(TradeScore.matchStrength(package.acceptanceScore)) · \(TradeScore.strengthTier(package.acceptanceScore)) · cover \(package.coverageCount)")
                    .font(.dsBadge).foregroundStyle(AppColor.special)
            }
        }
        .dxCard()
        .padding(.horizontal)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 6) {
            if package.qualSwap != nil {
                // Amber Q CAUTION: this solution needs a qual swap — open the card to pick the bridge.
                Image(systemName: "q.square.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(AppColor.pending)
            }
            if package.fireCount > 0 {
                Label("\(package.fireCount)", systemImage: "flame.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(AppColor.heat).labelStyle(.titleAndIcon)
            }
            if package.bookendTotal > 0 {
                Label("\(package.bookendTotal)", systemImage: "book.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(AppColor.success).labelStyle(.titleAndIcon)
            }
        }
    }

    private func swapLine(_ label: String, days: [String], color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(color)
            DXDayChip(text: days.isEmpty ? "—" : days.sorted().map(SwapChips.chipDay).joined(separator: ", "))
        }
    }

}

/// The counterparty's WEEK containing the shift you're giving them, that day highlighted (in their color)
/// with YOUR shift label — so you can see how the pickup lands in their week (bookend vs split). Loads
/// only this peer's schedule lazily (after the feed renders; cached in RosterStore), keeping search fast.
/// Tapping the parent card opens the full calendar. (B4-14 mini-calendar.)
struct TraderWeekStrip: View {
    let workerID: String
    let giveDayIDs: [String]
    let peerColor: Color
    @State private var peerLabels: [String: String] = [:]
    @State private var loaded = false

    private let cal = Calendar.current
    private static let wd = ["Su", "M", "T", "W", "Th", "F", "Sa"]
    private static let isoF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    private var giveSet: Set<String> { Set(giveDayIDs) }
    /// Sun–Sat of the week that holds the earliest give-day.
    private var weekDays: [Date] {
        guard let first = giveDayIDs.min(), let d = TradeMatcher.dayDate(fromISO: first),
              let wk = cal.dateInterval(of: .weekOfYear, for: d) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: wk.start) }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weekDays, id: \.self) { date in
                let key = Self.isoF.string(from: date)
                let isGive = giveSet.contains(key)
                let label = isGive ? myShiftLabel(key) : (peerLabels[key] ?? "")
                VStack(spacing: 1) {
                    Text(Self.wd[cal.component(.weekday, from: date) - 1])
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    Text("\(cal.component(.day, from: date))")
                        .font(.system(size: 11, weight: isGive ? .bold : .regular))
                        .foregroundStyle(isGive ? .white : .primary)
                    Text(label.isEmpty ? "·" : label)
                        .font(.system(size: 8, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(isGive ? .white : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(isGive ? peerColor : Color(.tertiarySystemFill).opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .task { if !loaded { await load() } }
    }

    /// YOUR shift on a give-day (what they'll be working) — read from your own schedule (synchronous).
    private func myShiftLabel(_ dayID: String) -> String {
        guard let s = ShiftStore.shared.shifts.first(where: { $0.id == dayID && !$0.isOff }) else { return "shift" }
        return "\(ShiftAvailabilityType.infer(fromStartHour: s.startHour).rawValue) \(s.desk)"
    }

    private func load() async {
        var m: [String: String] = [:]
        for e in await RosterStore.shared.schedule(forWorker: workerID) where !e.isOff {
            m[e.day] = "\(ShiftAvailabilityType.infer(fromStartHour: e.startHour).rawValue) \(e.desk)"
        }
        peerLabels = m; loaded = true
    }
}

/// Reusable compact participant summary: one "● Name — Jul 16, Jul 22, Jul 29" line per person (the days
/// they GIVE; the swap/loop conveys who receives them). Shared by the feed's `PackageCard` AND the inbox
/// trade card so both read identically (B6-CARD).
struct TradeParticipantLines: View {
    let rows: [(id: String, name: String, isMe: Bool, days: [String])]
    let orderedPeers: [String]

    private var myID: String { SettingsManager.shared.username }
    private func color(_ id: String, _ isMe: Bool) -> Color {
        isMe ? BrickPalette.mineScheme
             : TradeColors.color(forParticipant: id, myID: myID, orderedPeers: orderedPeers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows, id: \.id) { r in
                HStack(spacing: 8) {
                    DXSeatTile(color: color(r.id, r.isMe))
                    Text(r.name).font(.subheadline.weight(.semibold)).foregroundStyle(color(r.id, r.isMe)).lineLimit(1)
                    Text(r.days.isEmpty ? "—" : r.days.map(SwapChips.chipDay).joined(separator: ", "))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(2).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Rows for a directed chain (each participant gives the days on the legs they originate, loop order).
    static func rows(chain legs: [TradeLeg], myID: String) -> [(id: String, name: String, isMe: Bool, days: [String])] {
        var gives: [String: [String]] = [:]; var order: [String] = []
        for leg in legs {
            if gives[leg.fromID] == nil { order.append(leg.fromID) }
            gives[leg.fromID, default: []].append(leg.dayID)
        }
        let mapped = order.map { id in
            let name = legs.first { $0.fromID == id }?.fromName ?? participantName(id)
            return (id: id, name: id == myID ? "You" : name, isMe: id == myID, days: gives[id] ?? [])
        }
        // Each viewer sees THEMSELVES first/on top; the rest stay in loop order. (Colors map by id,
        // so reordering rows for display doesn't change anyone's assigned color.)
        return mapped.filter(\.isMe) + mapped.filter { !$0.isMe }
    }
}

struct PackageCard: View {
    let package: TradePackage
    let onPropose: () -> Void
    let onExecute: () -> Void
    var onOpen: () -> Void = {}

    private var isCircular: Bool { package.isCircular }   // #4: circular only when ≥3 participants
    private var messaging = MessagingStore.shared
    private var alreadySent: Bool { messaging.alreadyProposed(package) }

    private var headline: String {
        tradeTypeLabel(distinctPeople: package.peopleCount)
    }
    private var subtitle: String {
        let days = package.allDayIDs.count
        let kind = isCircular ? "circular loop" : (package.isOptimal ? "fewest people" : "quick match")
        return "\(days) day\(days == 1 ? "" : "s") · \(kind)"
    }
    private var quality: (text: String, color: Color) {
        if isCircular { return ("Circular", AppColor.special) }
        return package.isOptimal ? ("Optimal", AppColor.success) : ("Fast", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header — headline value, metadata, quality + urgency.
            HStack(spacing: 10) {
                Image(systemName: isCircular ? "arrow.triangle.2.circlepath" : "person.2.fill")
                    .font(.title3).foregroundStyle(quality.color)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline).font(.headline)
                    Text(subtitle).font(.dsCardMeta).foregroundStyle(.secondary)
                    // DEV-ONLY: TradeScore acceptance estimate. Hidden from the userbase; never in copy;
                    // does NOT affect ranking. Visible only in developer mode.
                    if DevAccess.shared.unlocked {
                        Text("Match strength \(TradeScore.matchStrength(package.acceptanceScore)) · \(TradeScore.strengthTier(package.acceptanceScore)) · cover \(package.coverageCount)")
                            .font(.dsBadge).foregroundStyle(AppColor.special)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    DXStatusBadge(text: quality.text, color: quality.color)
                    HStack(spacing: 6) {
                        if package.qualSwap != nil {
                            // Q-in-a-box CAUTION (amber): this solution needs a qual swap — open the card to
                            // pick the bridge via the Q button inside (Q1).
                            Label("Qual swap", systemImage: "q.square.fill")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(AppColor.pending)
                        }
                        if package.fireCount > 0 {
                            Label("\(package.fireCount)", systemImage: "flame.fill")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(AppColor.heat)
                        }
                        if package.bookendTotal > 0 {
                            // 📖 = total bookends delivered across all parties (more = more optimal).
                            Label("\(package.bookendTotal)", systemImage: "book.fill")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(AppColor.success)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    if package.urgency >= 3 {
                        Label("Urgent", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(BrickPalette.warning)
                    }
                }
            }

            Divider()

            // B6-CARD: one compact line per participant — "● Name — Jul 16, Jul 22, Jul 29" (the days that
            // person GIVES; whoever's next in the swap/loop receives them). Replaces the tall dual
            // Gives/Gets rows, which repeated every day twice. Same component as the inbox trade card.
            TradeParticipantLines(rows: participantRows, orderedPeers: package.assignments.map(\.workerID))

            Divider()

            // Actions — primary commit + view on schedule.
            HStack {
                // A qual-swap package can't be proposed blindly — you must pick the bridge inside the
                // view first, so its primary button OPENS the card (where the Q button lives).
                Button {
                    if alreadySent { return }
                    if package.qualSwap != nil { onOpen() }
                    else { isCircular ? onExecute() : onPropose() }
                } label: {
                    Label(alreadySent ? "Sent"
                          : (package.qualSwap != nil ? "Choose qual swap" : "Propose"),
                          systemImage: alreadySent ? "checkmark.circle.fill"
                          : (package.qualSwap != nil ? "q.square.fill"
                             : (isCircular ? "arrow.triangle.2.circlepath" : "paperplane.fill")))   // D4: generic
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .tint(alreadySent ? AppColor.success : (package.qualSwap != nil ? AppColor.pending : AppColor.primary))
                .disabled(alreadySent)
                Spacer()
                Button(action: onOpen) {
                    HStack(spacing: 3) {
                        Text("View on schedule").font(.caption.weight(.semibold))
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(AppColor.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .dxCard()
        .padding(.horizontal)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private var myID: String { SettingsManager.shared.username }

    /// One row per participant with the days they GIVE. Reciprocal: You give your give-days, each peer
    /// gives their take-days (= what you get). Circular: each participant gives the days on the legs they
    /// originate, in loop order.
    private var participantRows: [(id: String, name: String, isMe: Bool, days: [String])] {
        if isCircular, let route = package.route {
            var gives: [String: [String]] = [:]; var order: [String] = []
            for leg in route.legs {
                if gives[leg.fromID] == nil { order.append(leg.fromID) }
                gives[leg.fromID, default: []].append(leg.dayID)
            }
            return order.map { id in
                (id: id, name: id == myID ? "You" : participantName(id), isMe: id == myID, days: gives[id] ?? [])
            }
        }
        var rows: [(id: String, name: String, isMe: Bool, days: [String])] = []
        let myGives = package.assignments.flatMap(\.giveDayIDs)
        if !myGives.isEmpty { rows.append((id: "__me", name: "You", isMe: true, days: myGives)) }
        for a in package.assignments {
            rows.append((id: a.workerID, name: a.name, isMe: false, days: a.takeDayIDs))
        }
        return rows
    }
}

// MARK: - Package detail (back-to-back calendars, per-trader tabs)

struct PackageDetailView: View {
    let package: TradePackage
    let onPropose: (TradePackage) -> Void   // receives the (possibly subset) package to actually propose
    let onExecute: () -> Void
    var readOnly: Bool = false   // inbox view: show the calendars, hide the Propose/Execute action

    /// Build a view-only package from an inbox request's chain so the two-calendar view opens
    /// straight from the thread card. startHour is display-irrelevant here (only desk is drawn).
    static func fromChain(_ chain: [TradeLeg]) -> TradePackage {
        let legs = chain.map { NWayLeg(fromID: $0.fromID, toID: $0.toID, dayID: $0.dayID, desk: $0.desk ?? "", startHour: 0) }
        var order: [String] = []
        for l in chain where !order.contains(l.fromID) { order.append(l.fromID) }
        let route = NWayRoute(participants: order, legs: legs, tier: .neutralOptimization,
                              score: 0, usesBookends: false)
        return TradePackage(id: "thread-" + order.joined(separator: ">"),
                            methodology: .circular, assignments: [], route: route)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selectedStep = 0
    @State private var monthIndex = 0
    @State private var schedules: [String: [String: String]] = [:]   // workerID → day labels
    // SELECTION (subset propose): the day-IDs currently included in the proposal. Default = every day the
    // package contains; tapping a chip toggles it. Circular loops aren't subset-selectable (all-or-nothing).
    @State private var selectedDays: Set<String> = []
    @State private var selectionSeeded = false
    @State private var showQualPicker = false

    private let cal = Calendar.current
    private let youColor = BrickPalette.mineScheme
    private let monthOffsets = Array(0...12)
    private static let monthF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f }()
    private var myID: String { SettingsManager.shared.username }
    private var isCircular: Bool { package.isCircular }   // #4: circular only when ≥3 participants
    /// Non-circular, non-inbox packages support subset selection + Propose from this readable view.
    private var selectable: Bool { !isCircular && !readOnly }
    /// This package needs a qual swap (matcher-flagged): the Q button in this view picks the bridge.
    private var qualLeg: QualSwapLegData? { package.qualSwap }
    private var messaging = MessagingStore.shared
    private var alreadySent: Bool { messaging.alreadyProposed(package) }

    // GIVE-BACK CHOICE (2-person): the peer's ranked alternate days I could receive. The "You get" chips
    // become a single-select radio over these; the chosen day is what Propose sends + what the calendar
    // highlights. (B6-GIVEBACK — moved off the card into this view.)
    // GIVE-BACK CHOICE: the day(s) I've chosen to receive. A give-N trade stays give N / get N, but I may
    // pick WHICH N from the peer's ranked alternates. Single-day trades behave like a radio (pick 1).
    @State private var chosenTakes: [String] = []
    // Off (default): tapping a day chip just FOCUSES it on the calendar (view). On: each tap includes/
    // excludes that day from the proposal. Keeps "look at a day" distinct from "pick which days to trade."
    @State private var selectMode = false
    private var takeOpts: [String] {
        (package.assignments.count == 1 && !isCircular) ? (package.assignments.first?.takeOptions ?? []) : []
    }
    /// How many days I must receive back — balanced to what I give this peer (give N ⇒ get N).
    private var takeTargetCount: Int { max(1, package.assignments.first?.giveDayIDs.count ?? 1) }
    /// There's a give-back CHOICE only when the peer offers more eligible days than I need (alternates exist).
    private var hasTakeChoice: Bool { takeOpts.count > takeTargetCount }
    /// The peer's default (best) N give-back days — the seed + the "no custom choice" baseline.
    private var defaultTakes: [String] { package.assignments.first?.takeDayIDs ?? [] }
    /// Rolling multi-select: single-day acts as a radio; give-N caps at N, newest swaps the oldest out.
    private func toggleTake(_ d: String) {
        if takeTargetCount == 1 { chosenTakes = [d]; return }
        if let i = chosenTakes.firstIndex(of: d) { chosenTakes.remove(at: i); return }
        chosenTakes.append(d)
        if chosenTakes.count > takeTargetCount { chosenTakes.removeFirst() }
    }

    /// One tappable step per handoff. Circular = the loop legs; reciprocal = legs
    /// synthesized from each assignment (you→them for your gives, them→you for theirs).
    struct Step: Identifiable {
        let id: String
        let fromID: String, toID: String, dayID: String
        var desk: String? = nil
    }
    private var steps: [Step] {
        if isCircular, let legs = package.route?.legs {
            return legs.map { Step(id: $0.id, fromID: $0.fromID, toID: $0.toID, dayID: $0.dayID, desk: $0.desk) }
        }
        var out: [Step] = []
        for a in package.assignments {
            for d in a.giveDayIDs { out.append(Step(id: "\(myID)>\(a.workerID)@\(d)", fromID: myID, toID: a.workerID, dayID: d)) }
            // With a give-back choice, the take steps follow the CHOSEN days so the calendars track the picks.
            let takeDays = hasTakeChoice ? chosenTakes : a.takeDayIDs
            for d in takeDays { out.append(Step(id: "\(a.workerID)>\(myID)@\(d)", fromID: a.workerID, toID: myID, dayID: d)) }
        }
        return out
    }
    private var participants: [String] {
        if isCircular, let route = package.route { return route.participants }
        var ids = [myID]
        for a in package.assignments where !ids.contains(a.workerID) { ids.append(a.workerID) }
        return ids
    }
    private func colorFor(_ id: String) -> Color {
        TradeColors.color(forParticipant: id, myID: myID, orderedPeers: participants.filter { $0 != myID })   // F1: positional seat color
    }
    private func name(_ id: String) -> String { id == myID ? "You" : participantName(id) }
    private func gives(_ id: String) -> Set<String> { Set(steps.filter { $0.fromID == id }.map(\.dayID)) }
    private func gets(_ id: String) -> Set<String> { Set(steps.filter { $0.toID == id }.map(\.dayID)) }

    private var thisMonthStart: Date {
        cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
    }
    private func monthAnchor(_ offset: Int) -> Date {
        cal.date(byAdding: .month, value: offset, to: thisMonthStart) ?? thisMonthStart
    }
    private func monthOffset(for dayID: String) -> Int {
        guard let d = TradeMatcher.dayDate(fromISO: dayID) else { return 0 }
        let comps = cal.dateComponents([.month], from: thisMonthStart,
                                       to: cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d)
        return max(0, min(monthOffsets.count - 1, comps.month ?? 0))
    }
    private func select(_ i: Int) {
        guard steps.indices.contains(i) else { return }
        selectedStep = i
        monthIndex = monthOffset(for: steps[i].dayID)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // Landscape (wider than tall): calendars go SIDE BY SIDE and the chrome (chip index,
                // legend) collapses so the two calendars scale to fill the screen instead of being
                // squished into an unusable sliver.
                let wide = geo.size.width > geo.size.height
                VStack(spacing: wide ? 6 : 12) {
                    // Compact top row: a small corner X, then the give/get chips right beside it (no
                    // wasted space from a big "Close" button or a verbose title).
                    HStack(alignment: .top, spacing: 10) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color(.tertiarySystemFill)))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Close")
                        chipIndex(wide: wide)
                    }
                    .padding(.horizontal)
                    .padding(.top, 6)

                    HStack {
                        Button { if monthIndex > 0 { monthIndex -= 1 } } label: { Image(systemName: "chevron.left").font(.headline) }
                            .disabled(monthIndex == 0)
                        Spacer()
                        Text(Self.monthF.string(from: monthAnchor(monthIndex))).font(.headline)
                        Spacer()
                        Button { if monthIndex < monthOffsets.count - 1 { monthIndex += 1 } } label: { Image(systemName: "chevron.right").font(.headline) }
                            .disabled(monthIndex >= monthOffsets.count - 1)
                    }
                    .padding(.horizontal)

                    TabView(selection: $monthIndex) {
                        ForEach(monthOffsets, id: \.self) { off in
                            stepCalendars(for: off, wide: wide).tag(off).padding(.horizontal)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    if !readOnly {
                        if selectable {
                            selectableActions
                        } else {   // circular loop — all-or-nothing execute
                            Button { onExecute(); dismiss() } label: {
                                Label("Execute loop", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).padding(.horizontal).padding(.bottom, 8)
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)   // custom compact top row (corner X + chips) instead
            .task { await load() }
            .sheet(isPresented: $showQualPicker) {
                if let leg = qualLeg {
                    QualSwapPickerSheet(
                        giveDeskLabel: "desk \(leg.giveDesk) (\(leg.giveQual))",
                        takerName: leg.takerName, dayLabel: SwapChips.chipDay(leg.giveShiftDayID),
                        candidates: leg.candidates) { chosen in
                            onPropose(subsetPackage(bridgeChosen: chosen))
                            showQualPicker = false
                            dismiss()
                        }
                }
            }
        }
    }

    // MARK: Subset selection + Propose (readable view; qual swap picks a bridge in-place)

    /// Q-caution button (when the matcher flagged this trade as needing a qual swap) + Propose. Propose
    /// sends the SELECTED subset and switches to the accent tint + "Propose selection" once the selection
    /// differs from the full package.
    /// A standing BRIDGE-FIRST request (unbound taker) I already broadcast for THIS trade's give-day — if
    /// present, I don't have to pick a bridge inline; I propose the trade and merge it in my Inbox. (D6.)
    private var hasFoundBridge: Bool {
        guard let leg = qualLeg else { return false }
        return messaging.outgoing.contains {
            $0.qualSwap?.takerID.isEmpty == true && $0.qualSwap?.giveShiftDayID == leg.giveShiftDayID && !$0.isExpired
        }
    }

    @ViewBuilder private var selectableActions: some View {
        VStack(spacing: 8) {
            if qualLeg != nil {
                if hasFoundBridge {
                    // Bridge-first already done for this day → link on propose, no inline pick required.
                    Label("Bridge already requested for this day — propose, then merge it in your Inbox.",
                          systemImage: "link")
                        .font(.caption).foregroundStyle(AppColor.success)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                }
                Button { showQualPicker = true } label: {
                    Label(hasFoundBridge ? "Or choose a different bridge" : "Qual swap — choose a bridge",
                          systemImage: "q.square.fill")
                        .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(AppColor.pending).padding(.horizontal)
            }
            // Give-subset (narrow which of my days to trade). Hidden while a give-back CHOICE is active —
            // there you're picking which days to RECEIVE, and your gives stay whole. Off = tap-to-view.
            if allDays.count > 1 && !hasTakeChoice {
                Toggle(isOn: $selectMode) {
                    Label("Select specific days", systemImage: "checklist")
                        .font(.footnote.weight(.semibold))
                }
                .toggleStyle(.button).tint(AppColor.special).controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }
            // With a give-back choice you must pick exactly N days to receive before proposing.
            if hasTakeChoice && chosenTakes.count != takeTargetCount {
                Text("Pick \(takeTargetCount) day\(takeTargetCount == 1 ? "" : "s") to receive (\(chosenTakes.count)/\(takeTargetCount))")
                    .font(.caption).foregroundStyle(AppColor.pending)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }
            Button { onPropose(subsetPackage()); dismiss() } label: {
                Label(alreadySent ? "Sent" : (isSubset ? "Propose selection" : "Propose"),
                      systemImage: alreadySent ? "checkmark.circle.fill" : "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(alreadySent ? AppColor.success : (isSubset ? AppColor.special : AppColor.primary))   // accent = custom subset
            .disabled((selectMode && selectedDays.isEmpty)
                      || (hasTakeChoice && chosenTakes.count != takeTargetCount)
                      || alreadySent)
            .padding(.horizontal).padding(.bottom, 8)
        }
    }

    private var allDays: Set<String> { Set(steps.map(\.dayID)) }
    /// The days the proposal will include: the whole package unless the user turned on day-selection.
    private var proposalDays: Set<String> { selectMode ? selectedDays : allDays }
    /// True once the user has narrowed below the full package (only possible in select mode).
    private var isSubset: Bool { selectMode && !selectedDays.isEmpty && selectedDays != allDays }

    /// The package to actually propose — the assignments narrowed to the SELECTED days. `bridgeChosen`
    /// (from the Q picker) narrows the qual-swap leg's bridge candidates to the ones the user picked.
    private func subsetPackage(bridgeChosen: Set<String>? = nil) -> TradePackage {
        let sel = proposalDays
        let assigns = package.assignments.map { a in
            // Give-back CHOICE: keep all my gives, receive the days I chose. Otherwise the give-subset
            // toggle narrows both sides by the selected days.
            let take = hasTakeChoice ? chosenTakes : a.takeDayIDs.filter(sel.contains)
            let give = hasTakeChoice ? a.giveDayIDs : a.giveDayIDs.filter(sel.contains)
            return PackageAssignment(workerID: a.workerID, name: a.name,
                                     giveDayIDs: give,
                                     takeDayIDs: take, takeOptions: a.takeOptions)
        }.filter { !$0.giveDayIDs.isEmpty || !$0.takeDayIDs.isEmpty }
        var swap = package.qualSwap
        if let chosen = bridgeChosen, let leg = swap {
            swap = QualSwapLegData(giveShiftDayID: leg.giveShiftDayID, giveDesk: leg.giveDesk,
                                   giveQual: leg.giveQual, takerID: leg.takerID, takerName: leg.takerName,
                                   candidates: leg.candidates.filter { chosen.contains($0.workerID) })
        }
        return TradePackage(id: package.id, methodology: package.methodology,
                            assignments: assigns.isEmpty ? package.assignments : assigns,
                            route: package.route, urgency: package.urgency,
                            isOptimal: package.isOptimal, qualSwap: swap)
    }

    /// Sheet title: a descriptor + counts (dates live in the chips + calendars, not repeated here).
    private var dateTitle: String {
        let g = gives(myID).count, t = gets(myID).count
        if isCircular { return "\(Set(participants).count)-person loop" }
        if g == 0 && t == 0 { return tradeTypeLabel(distinctPeople: Set(participants).count) }
        return "Swap · give \(g), get \(t)"
    }

    /// Compact, fixed-height horizontal index that REPLACES the old growing vertical list — so the
    /// calendars below stay the hero at any trade size. Reciprocal trades show two rows (You give / You
    /// get); circular loops show the loop path in order. Tapping a chip focuses that leg on the calendars.
    @ViewBuilder private func chipIndex(wide: Bool) -> some View {
        let all = Array(steps.enumerated())
        let give = all.filter { $0.element.fromID == myID }
        let get  = all.filter { $0.element.toID == myID }
        Group {
            if isCircular {
                chipRow("Loop", all)
            } else if wide {
                // Landscape: give + get side by side (each slides horizontally) to save vertical space.
                HStack(alignment: .top, spacing: 16) {
                    chipRow("You give", give)
                    if hasTakeChoice { takeOptionRow } else { chipRow("You get", get) }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    chipRow("You give", give)
                    if hasTakeChoice { takeOptionRow } else { chipRow("You get", get) }
                }
            }
        }
    }

    private var peerID: String { package.assignments.first?.workerID ?? "" }

    /// "You get" as a multi-select over the peer's ranked alternate give-back days. You pick exactly N
    /// (= what you give); single-day trades behave like a radio. The chosen days are what Propose sends
    /// and what the calendars highlight.
    private var takeOptionRow: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text("You get").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text("pick \(takeTargetCount)").font(.system(size: 8, weight: .semibold)).foregroundStyle(AppColor.pending)
            }
            .frame(width: 52, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(takeOpts.enumerated()), id: \.element) { i, d in takeOptChip(d, isTop: i == 0) }
                }
            }
        }
    }

    private func takeOptChip(_ d: String, isTop: Bool) -> some View {
        let on = chosenTakes.contains(d)
        let c = colorFor(peerID)
        return Button {
            withAnimation(.snappy) { toggleTake(d) }
            monthIndex = monthOffset(for: d)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: on ? (takeTargetCount > 1 ? "checkmark.circle.fill" : "largecircle.fill.circle")
                                     : (takeTargetCount > 1 ? "circle" : "circle"))
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(on ? c : .secondary)
                Text(SwapChips.chipDay(d)).font(.caption2.weight(.semibold))
                // Only the top-ranked pick is tagged "best"; the rest are unlabeled alternates.
                if isTop {
                    Text("best").font(.system(size: 7, weight: .heavy)).foregroundStyle(AppColor.success)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(on ? c.opacity(0.18) : Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.controlRadius).stroke(on ? c : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    /// Row of day chips. In select mode the chips are TOGGLES (tap = include/exclude) and the count reads
    /// "picked / total"; otherwise tapping a chip just focuses it on the calendar.
    private func chipRow(_ label: String, _ items: [(offset: Int, element: Step)]) -> some View {
        let count = (selectable && selectMode) ? "\(items.filter { selectedDays.contains($0.element.dayID) }.count)/\(items.count)"
                               : "\(items.count)"
        return HStack(alignment: .center, spacing: 6) {
            Text("\(label) \(count)")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.element.id) { i, s in
                        Button { tapChip(i, s) } label: { chip(i, s) }
                            .buttonStyle(.plain)
                    }
                    if items.isEmpty { Text("—").font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    /// Tap: always FOCUS the day on the calendars; only toggle in/out of the proposal when the user has
    /// turned on "Select specific days" (so a plain tap to view never changes what you're proposing).
    private func tapChip(_ i: Int, _ s: Step) {
        withAnimation(.snappy) {
            if selectable && selectMode {
                if selectedDays.contains(s.dayID) { selectedDays.remove(s.dayID) } else { selectedDays.insert(s.dayID) }
            }
            select(i)
        }
    }

    /// One day chip. Focused chip is outlined. In SELECT mode a chip shows a check/hollow circle and dims
    /// when excluded; otherwise it's a plain view chip. Colored by the OTHER party (loop: the giver).
    private func chip(_ i: Int, _ s: Step) -> some View {
        let focused = i == selectedStep
        let picking = selectable && selectMode
        let included = !picking || selectedDays.contains(s.dayID)
        let other = isCircular ? s.fromID : (s.fromID == myID ? s.toID : s.fromID)
        let c = colorFor(other)
        return HStack(spacing: 4) {
            if picking {
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(included ? c : .secondary)
            } else {
                Circle().fill(c).frame(width: 6, height: 6)
            }
            Text(SwapChips.chipDay(s.dayID)).font(.caption2.weight(.semibold))
            if isCircular {   // loop needs "who→who" since a hop may not involve you
                Text("\(shortFirst(s.fromID))→\(shortFirst(s.toID))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .opacity(included ? 1 : 0.5)
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(focused ? c.opacity(0.18) : Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.controlRadius).stroke(focused ? c : .clear, lineWidth: 1.5))
    }

    private func shortFirst(_ id: String) -> String {
        if id == myID { return "You" }
        let n = participantName(id)
        return n.split(whereSeparator: { $0 == "," || $0 == " " }).first.map(String.init) ?? n
    }

    /// The selected leg's two calendars — YOU pinned on top whenever the leg involves you (stable, no
    /// give/get flip); a loop hop between two OTHER people shows that hop's giver→receiver.
    @ViewBuilder private func stepCalendars(for off: Int, wide: Bool) -> some View {
        if steps.indices.contains(selectedStep) {
            let s = steps[selectedStep]
            let involvesMe = s.fromID == myID || s.toID == myID
            let topID = involvesMe ? myID : s.fromID
            let bottomID = involvesMe ? (s.fromID == myID ? s.toID : s.fromID) : s.toID
            if wide {
                // Side by side in landscape → each calendar gets full height and stays readable.
                HStack(alignment: .top, spacing: 12) {
                    personCalendar(topID, off: off, focus: s.dayID)
                    personCalendar(bottomID, off: off, focus: s.dayID)
                }
            } else {
                VStack(spacing: 8) {
                    personCalendar(topID, off: off, focus: s.dayID)
                    Image(systemName: "arrow.down").font(.subheadline).foregroundStyle(.secondary)
                    personCalendar(bottomID, off: off, focus: s.dayID)
                }
            }
        }
    }

    private func personCalendar(_ id: String, off: Int, focus: String) -> some View {
        let isMe = id == myID
        let intentClosure: (String) -> (label: String, color: Color)? = { isMe ? myIntent($0) : peerIntent($0, workerID: id) }
        let topoClosure: (String) -> DayTopology = {
            isMe ? DayIntentStore.shared.topology(forDay: $0) : TwoWaySheet.globalTopology($0)
        }
        let eventClosure: (String) -> String? = {
            isMe ? TwoWaySheet.eventText($0, topology: DayIntentStore.shared.topology(forDay: $0), includePrivate: true)
                 : TwoWaySheet.globalEvent($0)
        }
        return MiniScheduleGrid(
            title: name(id), days: schedules[id] ?? [:], month: monthAnchor(off),
            accent: colorFor(id), giveDays: gives(id), takeDays: gets(id), focusDay: focus,
            intent: intentClosure, topology: topoClosure, eventName: eventClosure, fill: true)
            .frame(maxHeight: .infinity)   // the two calendars split the available height → fit, no scroll
    }

    /// My intent on the "You" calendar (name + color) — Want to Trade Away / Keep / Blackout / Want to
    /// Work — surfaced as the cell's corner dot + the tap popover. "Open" (no real intent) is skipped.
    private func myIntent(_ day: String) -> (label: String, color: Color)? {
        let store = DayIntentStore.shared
        if let w = store.workingIntent(forDay: day), w != .neutralOpen {
            let name = w == .dontWantToWork ? "Want to Trade" : (w == .mustWork ? "Keep" : "Want to Work")
            return (name, w.brickColor)
        }
        if let o = store.offIntent(forDay: day), o != .neutralOpen {
            return (o == .mustBeOff ? "Blackout Day" : "Want to Work", o.brickColor)
        }
        if !store.availability(forDay: day).isEmpty { return ("Want to Work", BrickPalette.availableOff) }
        return nil
    }

    /// A peer's published intent (days they're seeking to trade away).
    private func peerIntent(_ day: String, workerID: String) -> (label: String, color: Color)? {
        let seeks = TradeProfileStore.shared.profile(forWorker: workerID)?.seekingDayIDs ?? []
        return seeks.contains(day) ? ("Wants to Trade", BrickPalette.change) : nil
    }

    private func load() async {
        for id in participants where schedules[id] == nil {
            schedules[id] = await TradeMatcher.dayLabels(forWorker: id)
        }
        // Seed the give-back choice to the peer's default (best) N days before deriving steps.
        if chosenTakes.isEmpty { chosenTakes = defaultTakes }
        // Default selection = every day the package contains (subset-editable when `selectable`).
        if !selectionSeeded {
            selectedDays = Set(steps.map(\.dayID))
            selectionSeeded = true
        }
        select(0)
    }
}

// MARK: - Execution confirmation (checkout)

struct ExecutionConfirmationView: View {
    let route: NWayRoute
    var origin: TradeOrigin = .search   // where the loop was surfaced (Intents feed vs Trade Solutions)

    private var messaging = MessagingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var sent = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(route.legs) { leg in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(participantName(leg.fromID)) → \(participantName(leg.toID))")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(prettyDay(leg.dayID)) · desk \(leg.desk) · \(leg.startHour)00")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle").foregroundStyle(AppColor.special)
                        }
                    }
                } header: {
                    Text("Chain of custody — \(route.participants.count) people, \(route.legs.count) shifts")
                } footer: {
                    Text("Sending notifies every other participant with the full loop. Each confirms in their own inbox; enter it on the official board once all agree.")
                }

                Section {
                    Button {
                        Task { await execute() }
                    } label: {
                        HStack {
                            Spacer()
                            if sending { ProgressView() }
                            else { Label(sent ? "Sent" : "Send proposals to all", systemImage: "paperplane.fill") }
                            Spacer()
                        }
                    }
                    .disabled(sending || sent)
                }
            }
            .navigationTitle("Confirm Trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func execute() async {
        sending = true
        let myID = SettingsManager.shared.username
        let legs = route.legs.map {
            TradeLeg(fromID: $0.fromID, fromName: participantName($0.fromID),
                     toID: $0.toID, toName: participantName($0.toID), dayID: $0.dayID, desk: $0.desk)
        }
        let loopID = UUID().uuidString   // one shared id: the N per-participant requests group into one loop card/thread
        for pid in route.participants where pid != myID {
            await messaging.sendRequest(to: pid, toName: participantName(pid),
                                        note: "",   // #7: the card shows the trade visually; no redundant text
                                        take: [], give: [], chain: legs, origin: origin, loopID: loopID)
        }
        sending = false
        sent = true
    }
}

// MARK: - Helpers

/// "Last, First" / "First Last" → "First", for compact give/get labels.
func firstName(_ name: String) -> String {
    name.components(separatedBy: ",").last?.trimmingCharacters(in: .whitespaces) ?? name
}

func participantName(_ id: String) -> String {
    if id == SettingsManager.shared.username {
        let dn = SettingsManager.shared.displayName
        return dn.isEmpty ? "You" : dn
    }
    // B4-8: published display name → cached roster name → employee # (last resort). `TradeNames.resolved`
    // rejects blank / all-digits / == id so a calendar never shows a bare number when a real name exists.
    return TradeNames.resolved(displayName: TradeProfileStore.shared.profile(forWorker: id)?.displayName,
                               rosterName: RosterStore.shared.name(for: id),
                               workerID: id)
}

func participantStatus(_ id: String) -> String? {
    if id == SettingsManager.shared.username {
        let s = SettingsManager.shared.statusBroadcast
        return s.isEmpty ? nil : s
    }
    let s = TradeProfileStore.shared.profile(forWorker: id)?.statusBroadcast
    return (s?.isEmpty ?? true) ? nil : s
}

/// Is this peer actually ON the app? True only if they're a real signed-in account (their published
/// profile is stamped `accountClaimed`) — NOT merely a legacy/orphan profile record. You are always on.
/// Inactive roster peers still appear in matches (behavior inferred) but can't receive messages.
func participantHasProfile(_ id: String) -> Bool {
    TradeProfileStore.shared.isActiveAccount(id)
}

/// Robot suffix (🤖) for peers not on the app — appended to their NAME in displays so it's obvious
/// they can't be messaged yet. Empty for active users. Display-only; never used as a stored name.
func botSuffix(_ id: String) -> String { participantHasProfile(id) ? "" : " 🤖" }

func prettyDay(_ iso: String) -> String {
    guard let d = TradeMatcher.dayDate(fromISO: iso) else { return iso }
    let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: d)
}

/// Human-readable reciprocal-swap note for a package assignment.
func swapNote(_ a: PackageAssignment) -> String {
    var parts: [String] = []
    if !a.takeDayIDs.isEmpty { parts.append("I take your \(a.takeDayIDs.map(prettyDay).joined(separator: ", "))") }
    if !a.giveDayIDs.isEmpty { parts.append("you take my \(a.giveDayIDs.map(prettyDay).joined(separator: ", "))") }
    return parts.isEmpty ? "Trade proposal." : "Swap: " + parts.joined(separator: "; ") + "."
}

