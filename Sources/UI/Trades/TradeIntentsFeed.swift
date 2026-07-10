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
        var packages: [TradePackage] = []            // ALL-mode results (superset)
        var mutualPackages: [TradePackage] = []      // Mutual-mode subset (both cached so the toggle is instant)
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

    /// The result set for the current toggle — Mutual (subset) or All (superset). Both are computed in one
    /// search and cached, so flipping the toggle is an instant state change (no engine re-run).
    private var activePackages: [TradePackage] { mutualOnly ? mutualPackages : packages }
    /// A1/A2: filtered + capped (best-first via rankPackages order) view of the results.
    private var displayed: [TradePackage] { Array(searchFilter.filter(activePackages).prefix(100)) }

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
                    Picker("Match type", selection: $mutualOnly) {
                        Text("Mutual").tag(true)
                        Text("All").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.top, 4)
                    // No re-run on toggle: both Mutual + All were computed in one search (instant flip).
                    // Trade size (Max people) is a Lucky-time option — only shown once Lucky is engaged.
                    if searchFilter.isActive {
                        MaxPeoplePicker().padding(.horizontal).padding(.top, 4)
                    }
                }

                if loading {
                    VStack(spacing: 14) {
                        ProgressView("Finding intent matches…")
                        Button(role: .cancel) { searchTask?.cancel(); loading = false } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 30)
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
                                            onPropose: { Task { await propose(pkg) } },
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
                              onPropose: { Task { await propose(pkg) } },
                              onExecute: { if let r = pkg.route { execRoute = r } })
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
                              onGenerate: { f in runSearch { await reload(generation: f, lucky: true) } },
                              onReset: { runSearch { await reloadFast() } })
        }
        .task {
            // U-PERF: restore the last results instantly if nothing changed; otherwise run a
            // CANCELLABLE fast search (so the spinner shows a working Cancel and the engine yields).
            if let snap = TradeFeedCache.shared.snapshot(Self.cacheKey),
               snap.signature == TradeFeedCache.signature(whatIf: whatIf) {
                packages = snap.packages; mutualPackages = snap.mutualPackages
                rosterPeople = snap.rosterPeople; loading = false
            } else {
                runSearch { await reloadFast() }
            }
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
        // Step 4: normal feed searches up to the user's N-max toggle (default 3) — the floor +
        // N-penalty keep small trades on top. (Reverses the old 2-way-only U-PERF gate.)
        await reload(generation: SearchFilter(engine: .both, maxPeople: SettingsManager.shared.normalMaxPeople))
        // U-PERF: cache BOTH result sets so a tab switch OR a Mutual/All toggle restores them without
        // re-running the engine.
        if Task.isCancelled { return }
        TradeFeedCache.shared.save(Self.cacheKey, .init(
            signature: TradeFeedCache.signature(whatIf: whatIf),
            packages: packages, mutualPackages: mutualPackages, rosterPeople: rosterPeople, hasSearched: true))
    }

    private static let cacheKey = "intents"

    /// `generation` bounds the engine work: `.fast` (2-person, background) or the user's Lucky
    /// criteria (heavy 3+/N-Way, one-time). The display still filters via `searchFilter`.
    private func reload(generation: SearchFilter = .fast, lucky: Bool = false) async {
        loading = true
        await TradeProfileStore.shared.refreshOthers()
        let myID = SettingsManager.shared.username
        // Intents uses its OWN engine — a marketplace of intent-for-intent deals involving you, scored by
        // the real packageLogProb. Compute BOTH modes in ONE search: All (superset, every peer) and Mutual
        // (both-sides-marked, active accounts). The toggle then just picks which cached set to show.
        let allResult = await TradeRouter.intentSolutions(excluding: myID, generation: generation,
                                                          lucky: lucky, mutualOnly: false)
        if Task.isCancelled { return }   // A1: superseded by a newer search — don't clobber its state
        let mutualResult = await TradeRouter.intentSolutions(excluding: myID, generation: generation,
                                                            lucky: lucky, mutualOnly: true)
        if Task.isCancelled { return }
        packages = allResult
        mutualPackages = mutualResult
        // The Intents badge = number of MUTUAL matches.
        TradeFeedCache.shared.intentMatchCount = mutualResult.count
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
        for e in entries { add(e.workerID, e.workerName) }
        for (id, p) in TradeProfileStore.shared.others { add(id, p.displayName) }
        for pkg in packages { for a in pkg.assignments { add(a.workerID, a.name) } }
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
            Picker("Trade size", selection: Binding(
                get: { settings.normalMaxPeople }, set: { settings.normalMaxPeople = $0 })) {
                Text("Pairs").tag(2)
                Text("≤ 3").tag(3)
                Text("≤ 4").tag(4)
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }
}

/// A2: the "I'm Feeling Lucky" Master Filter sheet — engine, max-people, force-include person.
/// Choices are shown as chips on the feed; the results are filtered by `SearchFilter.filter`.
struct MasterFilterSheet: View {
    @Binding var filter: SearchFilter
    let people: [(id: String, name: String)]
    /// One-time HEAVY generation with the chosen criteria (runs 3+ / N-Way).
    var onGenerate: (SearchFilter) -> Void = { _ in }
    /// Back to the section's fast NORMAL generation (2-person only).
    var onReset: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SearchFilter

    init(filter: Binding<SearchFilter>, people: [(id: String, name: String)],
         onGenerate: @escaping (SearchFilter) -> Void = { _ in }, onReset: @escaping () -> Void = {}) {
        _filter = filter; self.people = people; self.onGenerate = onGenerate; self.onReset = onReset
        _draft = State(initialValue: filter.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Search engine") {
                    Picker("Engine", selection: $draft.engine) {
                        Text("Min-Cost").tag(SearchFilter.Engine.minCost)
                        Text("N-Way").tag(SearchFilter.Engine.nWay)
                        Text("Both").tag(SearchFilter.Engine.both)
                    }.pickerStyle(.segmented)
                    Text("Min-Cost = fewest-people swaps · N-Way = circular loops · Both = everything (capped for speed).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("Max people in a trade") {
                    Picker("Max people", selection: $draft.maxPeople) {
                        ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                    }.pickerStyle(.segmented)
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
                    // One-time HEAVY generation for the chosen criteria (3+ / N-Way included).
                    Button {
                        filter = draft; onGenerate(draft); dismiss()
                    } label: {
                        Label("Generate matches", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 10, height: 10)
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

    static func chipDay(_ iso: String) -> String {
        guard let d = TradeMatcher.dayDate(fromISO: iso) else { return iso }
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
    }
}

// MARK: - Package card (one card per deal)

/// B4-14: compact ECB-style card for two-person swaps — thin (more results per screen), shows the
/// counterparty's name + status snapshot, "You get" / "They get" **once each** (no PackageCard
/// duplication), badges (🔥/📖/Q), and Propose. Tapping opens their schedule. 3+-person and circular
/// keep `PackageCard`. Presentation-only: the same 2-way packages, in the same order (INV-2).
struct CompactSwapCard: View {
    let package: TradePackage
    let onPropose: () -> Void
    var onOpen: () -> Void = {}

    private var myID: String { SettingsManager.shared.username }

    var body: some View {
        let a = package.assignments.first
        let peerColor = a.map { TradeColors.color(forParticipant: $0.workerID, myID: myID, orderedPeers: [$0.workerID]) } ?? AppColor.neutral
        VStack(alignment: .leading, spacing: 6) {
            // Header: peer name + their status snapshot · badges · Propose.
            HStack(spacing: 8) {
                Circle().fill(peerColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text((a?.name ?? "Swap") + (a.map { botSuffix($0.workerID) } ?? "")).font(.subheadline.weight(.semibold))
                    if let id = a?.workerID, let status = participantStatus(id), !status.isEmpty {
                        Text(status).font(.caption2).italic().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                badges
                Button(action: onPropose) {
                    Label("Propose", systemImage: "paperplane.fill").labelStyle(.iconOnly).font(.subheadline)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityLabel("Propose")
            }
            // You get / They get — on ONE line (ECB-card style), each shown once.
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                swapLine("You get", days: a?.takeDayIDs ?? [], color: BrickPalette.mineScheme)
                swapLine("They get", days: a?.giveDayIDs ?? [], color: peerColor)
                Spacer(minLength: 0)
            }
            if DevAccess.shared.unlocked {
                Text(String(format: "TradeScore: %.0f%% · cover %d", package.acceptanceScore * 100, package.coverageCount))
                    .font(.dsBadge).foregroundStyle(AppColor.special)
            }
        }
        .padding(.horizontal, DS.cardPadding).padding(.vertical, 8)
        .background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))
        .padding(.horizontal)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 6) {
            if package.qualSwap != nil {
                Image(systemName: "q.square.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(AppColor.special)
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
            Text(days.isEmpty ? "—" : DayFmt.list(days)).font(.caption)
                .lineLimit(1).minimumScaleFactor(0.75)
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
                    Circle().fill(color(r.id, r.isMe)).frame(width: 9, height: 9)
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
                        Text(String(format: "TradeScore: %.0f%% · cover %d", package.acceptanceScore * 100, package.coverageCount))
                            .font(.dsBadge).foregroundStyle(AppColor.special)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    pill(quality.text, quality.color)
                    HStack(spacing: 6) {
                        if package.qualSwap != nil {
                            // Q-in-a-box: this solution needs a qual swap (Q1).
                            Label("Qual swap", systemImage: "q.square.fill")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(AppColor.special)
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
                Button {
                    isCircular ? onExecute() : onPropose()
                } label: {
                    Label("Propose", systemImage: isCircular ? "arrow.triangle.2.circlepath" : "paperplane.fill")   // D4: generic
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
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
        .padding(DS.cardPadding)
        .background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))
        .padding(.horizontal)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased())
            .font(.dsBadge)
            .padding(.horizontal, DS.s).padding(.vertical, 3)
            .background(color.opacity(DS.pillFill), in: Capsule())
            .foregroundStyle(color)
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
    let onPropose: () -> Void
    let onExecute: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selectedStep = 0
    @State private var monthIndex = 0
    @State private var schedules: [String: [String: String]] = [:]   // workerID → day labels
    @State private var showIntents = true

    private let cal = Calendar.current
    private let youColor = BrickPalette.mineScheme
    private let monthOffsets = Array(0...12)
    private static let monthF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f }()
    private var myID: String { SettingsManager.shared.username }
    private var isCircular: Bool { package.isCircular }   // #4: circular only when ≥3 participants

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
            for d in a.takeDayIDs { out.append(Step(id: "\(a.workerID)>\(myID)@\(d)", fromID: a.workerID, toID: myID, dayID: d)) }
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
                    if !wide { chipIndex }

                    HStack {
                        Button { if monthIndex > 0 { monthIndex -= 1 } } label: { Image(systemName: "chevron.left").font(.headline) }
                            .disabled(monthIndex == 0)
                        Spacer()
                        Text(Self.monthF.string(from: monthAnchor(monthIndex))).font(.headline)
                        Button { withAnimation { showIntents.toggle() } } label: {
                            Image(systemName: showIntents ? "paintpalette.fill" : "paintpalette")
                                .foregroundStyle(showIntents ? Color.accentColor : .secondary)
                        }
                        .accessibilityLabel(showIntents ? "Hide intent colors" : "Show intent colors")
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

                    if !wide { MiniScheduleLegend().padding(.horizontal) }

                    Button {
                        isCircular ? onExecute() : onPropose()
                        dismiss()
                    } label: {
                        Label("Propose", systemImage: isCircular ? "arrow.triangle.2.circlepath" : "paperplane.fill")   // D4: generic
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).padding(.horizontal).padding(.bottom, 8)
                }
            }
            .navigationTitle(dateTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await load() }
        }
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
    private var chipIndex: some View {
        let all = Array(steps.enumerated())
        return VStack(alignment: .leading, spacing: 6) {
            if isCircular {
                chipRow("Loop", all)
            } else {
                chipRow("You give", all.filter { $0.element.fromID == myID })
                chipRow("You get",  all.filter { $0.element.toID == myID })
            }
        }
        .padding(.horizontal)
    }

    private func chipRow(_ label: String, _ items: [(offset: Int, element: Step)]) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(label) \(items.count)")
                .font(.dsLabel).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.element.id) { i, s in
                        Button { withAnimation(.snappy) { select(i) } } label: { chip(i, s) }
                            .buttonStyle(.plain)
                    }
                    if items.isEmpty { Text("—").font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    /// One day chip, colored by the OTHER party (loop: the giver). Selected chip is outlined.
    private func chip(_ i: Int, _ s: Step) -> some View {
        let on = i == selectedStep
        let other = isCircular ? s.fromID : (s.fromID == myID ? s.toID : s.fromID)
        let c = colorFor(other)
        return HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(SwapChips.chipDay(s.dayID)).font(.dsChip)
            if isCircular {   // loop needs "who→who" since a hop may not involve you
                Text("\(shortFirst(s.fromID))→\(shortFirst(s.toID))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(on ? c.opacity(0.18) : Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.controlRadius).stroke(on ? c : .clear, lineWidth: 1.5))
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
        let intentClosure: (String) -> Color? = { isMe ? myIntent($0) : peerIntent($0, workerID: id) }
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

    /// My intents on the "You" calendar (hidden when the overlay toggle is off). Standardized to a
    /// single bottom bar covering EVERY intent — working, off-day intent, AND off-day availability
    /// (AM/PM/MID pickup) — so off-day marks are no longer invisible here.
    private func myIntent(_ day: String) -> Color? {
        guard showIntents else { return nil }
        if let w = DayIntentStore.shared.workingIntent(forDay: day) { return w.brickColor }
        if let o = DayIntentStore.shared.offIntent(forDay: day) { return o.brickColor }
        if !DayIntentStore.shared.availability(forDay: day).isEmpty { return BrickPalette.availableOff }
        return nil
    }

    /// A peer's published intent (days they're seeking to trade away) as a corner chip.
    private func peerIntent(_ day: String, workerID: String) -> Color? {
        guard showIntents else { return nil }
        let seeks = TradeProfileStore.shared.profile(forWorker: workerID)?.seekingDayIDs ?? []
        return seeks.contains(day) ? BrickPalette.change : nil
    }

    private func load() async {
        for id in participants where schedules[id] == nil {
            schedules[id] = await TradeMatcher.dayLabels(forWorker: id)
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
        for pid in route.participants where pid != myID {
            await messaging.sendRequest(to: pid, toName: participantName(pid),
                                        note: "",   // #7: the card shows the trade visually; no redundant text
                                        take: [], give: [], chain: legs, origin: origin)
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

