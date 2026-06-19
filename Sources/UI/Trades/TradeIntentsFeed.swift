// TradeIntentsFeed.swift
// The "Trade by Intents" feed (4 tier accordions from TradeRouter.tieredSolutions)
// plus the N-way chain card and the execution-confirmation checkout.

import SwiftUI

// MARK: - Feed

struct TradeByIntentsFeed: View {

    @Binding var whatIf: Bool

    @State private var packages: [TradePackage] = []   // unfiltered search results
    @State private var loading = true
    @State private var execRoute: NWayRoute?
    @State private var sentMessage: String?
    @State private var detailPackage: TradePackage?
    @State private var pkgSwap: PackageSwapContext?   // Q1: qual-swap package → blast picker
    // A1/A2: Master Filter — shapes the on-demand "I'm Feeling Lucky" search; chips stay visible.
    @State private var searchFilter = SearchFilter()
    @State private var showFilter = false
    @State private var rosterPeople: [(id: String, name: String)] = []

    /// A1/A2: filtered + capped (best-first via rankPackages order) view of the results.
    private var displayed: [TradePackage] { Array(searchFilter.filter(packages).prefix(100)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if whatIf {
                    Label("What If? on — extended matches (toggle in Trade Search)",
                          systemImage: "wand.and.stars")
                        .font(.caption).foregroundStyle(.purple)
                        .padding(.horizontal).padding(.top, 8)
                }

                if !loading { luckyBar }

                if loading {
                    ProgressView("Finding intent matches…")
                        .frame(maxWidth: .infinity).padding(.top, 30)
                } else if displayed.isEmpty {
                    ContentUnavailableView("No Intent Matches",
                        systemImage: "sparkles",
                        description: Text(packages.isEmpty
                            ? "Mark days to trade away on Home, or try What If? mode to widen the search."
                            : "No matches fit your current filter — tap the filter to widen it."))
                        .padding(.top, 20)
                } else {
                    sectionHeader("Trade Solutions", "From your marked days — fewest people first, then 🔥 and bookends")
                    ForEach(displayed) { pkg in
                        PackageCard(package: pkg,
                                    onPropose: { Task { await propose(pkg) } },
                                    onExecute: { if let r = pkg.route { execRoute = r } },
                                    onOpen: { detailPackage = pkg })
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
        .sheet(item: $execRoute) { ExecutionConfirmationView(route: $0) }
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
                        take: [], give: [ctx.leg.giveShiftDayID], qualSwap: sendLeg)
                    WidgetData.update()
                    pkgSwap = nil
                    sentMessage = "Qual-swap request sent. Track it in your Inbox."
                }
            }
        }
        .sheet(isPresented: $showFilter) { MasterFilterSheet(filter: $searchFilter, people: rosterPeople) }
        .task { await reload() }
        .onChange(of: whatIf) { _, _ in Task { await reload() } }
        // Recompute whenever any matching input changes (openness / mercenary / intents /
        // availability / blacklist) — fixes "changed my settings but nothing refreshed". S-ENG-9.
        .onChange(of: MatchInputsSignature.current) { _, _ in Task { await reload() } }
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
                Label("I'm Feeling Lucky", systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            HStack(spacing: 6) {
                chip(searchFilter.engine == .both ? "Both engines"
                     : (searchFilter.engine == .minCost ? "Min-Cost" : "N-Way"))
                chip("≤ \(searchFilter.maxPeople) people")
                if let rid = searchFilter.requiredWorkerID {
                    chip("must include " + (rosterPeople.first { $0.id == rid }?.name ?? rid))
                }
                Spacer()
            }
            .font(.caption2)
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

    private func reload() async {
        loading = true
        await TradeProfileStore.shared.refreshOthers()
        let myID = SettingsManager.shared.username
        packages = await TradeRouter.packages(excluding: myID)
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
                take: a.takeDayIDs, give: a.giveDayIDs)
        }
        WidgetData.update()
        let n = pkg.assignments.count
        sentMessage = "Sent to \(n) dispatcher\(n == 1 ? "" : "s"). Track replies in your Inbox."
    }
}

// MARK: - Feed key (explains the chips, flame, and quality pills)

/// A2: the "I'm Feeling Lucky" Master Filter sheet — engine, max-people, force-include person.
/// Choices are shown as chips on the feed; the results are filtered by `SearchFilter.filter`.
struct MasterFilterSheet: View {
    @Binding var filter: SearchFilter
    let people: [(id: String, name: String)]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Search engine") {
                    Picker("Engine", selection: $filter.engine) {
                        Text("Min-Cost").tag(SearchFilter.Engine.minCost)
                        Text("N-Way").tag(SearchFilter.Engine.nWay)
                        Text("Both").tag(SearchFilter.Engine.both)
                    }.pickerStyle(.segmented)
                    Text("Min-Cost = fewest-people swaps · N-Way = circular loops · Both = everything (capped for speed).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("Max people in a trade") {
                    Picker("Max people", selection: $filter.maxPeople) {
                        ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section("Connection") {
                    Picker("Connection", selection: Binding(
                        get: { filter.requiredWorkerID ?? "" },
                        set: { filter.requiredWorkerID = $0.isEmpty ? nil : $0 })) {
                        Text("Anyone").tag("")
                        ForEach(people, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Text("Only show trades that include this dispatcher.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("I'm Feeling Lucky")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// A compact legend at the bottom of the Intents feed, mirroring the trade-calendar key.
struct TradeFeedKey: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Key").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                chip("You give", BrickPalette.mineScheme)
                chip("You get", BrickPalette.peerScheme)
                Label("Mutual intent", systemImage: "flame.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                pill("Optimal", .green); Text("fewest people").font(.caption2).foregroundStyle(.secondary)
                pill("Fast", .secondary); Text("quick match").font(.caption2).foregroundStyle(.secondary)
                pill("Circular", .indigo); Text("loop").font(.caption2).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.cardPadding)
        .background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))
    }

    private func chip(_ label: String, _ color: Color) -> some View {
        HStack(spacing: DS.xs) {
            Capsule().fill(color.opacity(DS.pillFill)).frame(width: 16, height: 13)
                .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 0.5))
            Text(label).font(.caption2)
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased())
            .font(.dsBadge)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(DS.pillFill), in: Capsule())
            .foregroundStyle(color)
    }
}

/// #5: intent-color legend — the SAME hues the calendar uses for each intent, plus the
/// 🔥 (mutual want) / 📖 (bookend) markers. Reused by the two-way sheet and ECB so a
/// dispatcher can read what each color means in-context.
struct IntentColorKey: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Key").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { swatches }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        swatch("Trade away", WorkingIntentState.dontWantToWork.brickColor)
                        swatch("Want to work", OffIntentState.wantToWork.brickColor)
                    }
                    HStack(spacing: 12) {
                        swatch("Keep", WorkingIntentState.mustWork.brickColor)
                        swatch("Must be off", OffIntentState.mustBeOff.brickColor)
                        markers
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.cardPadding)
        .background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))
    }

    @ViewBuilder private var swatches: some View {
        swatch("Trade away", WorkingIntentState.dontWantToWork.brickColor)
        swatch("Want to work", OffIntentState.wantToWork.brickColor)
        swatch("Keep", WorkingIntentState.mustWork.brickColor)
        swatch("Must be off", OffIntentState.mustBeOff.brickColor)
        markers
    }

    private var markers: some View {
        HStack(spacing: 10) {
            Text("🔥 mutual").font(.caption2)
            Text("📖 bookend").font(.caption2)
        }
        .foregroundStyle(.secondary)
    }

    private func swatch(_ label: String, _ color: Color) -> some View {
        HStack(spacing: DS.xs) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 16, height: 13)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.3), lineWidth: 0.5))
            Text(label).font(.caption2)
        }
    }
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
                Text(name).font(.dsCardTitle).foregroundStyle(color).lineLimit(1)
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
        if isCircular { return ("Circular", .indigo) }
        return package.isOptimal ? ("Optimal", .green) : ("Fast", .secondary)
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
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    pill(quality.text, quality.color)
                    HStack(spacing: 6) {
                        if package.qualSwap != nil {
                            // Q-in-a-box: this solution needs a qual swap (Q1).
                            Label("Qual swap", systemImage: "q.square.fill")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(.purple)
                        }
                        if package.fireCount > 0 {
                            Label("\(package.fireCount)", systemImage: "flame.fill")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                        }
                        if package.bookendTotal > 0 {
                            // 📖 = total bookends delivered across all parties (more = more optimal).
                            Label("\(package.bookendTotal)", systemImage: "book.fill")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
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

            if isCircular, let route = package.route {
                // Circular loop: show the directed handoffs, not reciprocal pairs.
                HandoffChain(legs: route.legs)
            } else {
                // Reciprocal: each pairing in its traders' colors (border = trades
                // away, fill = takes) — the same colors as the calendars.
                ForEach(Array(package.assignments.enumerated()), id: \.element.id) { idx, a in
                    VStack(alignment: .leading, spacing: 8) {
                        TraderChips(name: "You", color: BrickPalette.mineScheme,
                                    giveDays: a.giveDayIDs, getDays: a.takeDayIDs)
                        TraderChips(name: a.name, color: TradeColors.color(forParticipant: a.workerID, myID: SettingsManager.shared.username, orderedPeers: package.assignments.map(\.workerID)),
                                    giveDays: a.takeDayIDs, getDays: a.giveDayIDs, id: a.workerID)   // D1/F1: stable per-worker color
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if idx < package.assignments.count - 1 { Divider() }
                }
            }

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
                    .foregroundStyle(.blue)
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
            VStack(spacing: 12) {
                stepsList

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
                        stepCalendars(for: off).tag(off).padding(.horizontal)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                MiniScheduleLegend().padding(.horizontal)

                Button {
                    isCircular ? onExecute() : onPropose()
                    dismiss()
                } label: {
                    Label("Propose", systemImage: isCircular ? "arrow.triangle.2.circlepath" : "paperplane.fill")   // D4: generic
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).padding(.horizontal).padding(.bottom, 8)
            }
            .navigationTitle(dateTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await load() }
        }
    }

    /// Your traded dates, used as the sheet title (e.g. "Jul 4 ⇄ Jul 11").
    private var dateTitle: String {
        let g = gives(myID).sorted().map { SwapChips.chipDay($0) }
        let t = gets(myID).sorted().map { SwapChips.chipDay($0) }
        if g.isEmpty && t.isEmpty { return tradeTypeLabel(distinctPeople: Set(participants).count) }
        return g.joined(separator: ", ") + "  ⇄  " + t.joined(separator: ", ")
    }

    /// Tappable handoff steps — tap one to jump the calendars to those two people
    /// and that date. Works for any size (the top calendar isn't always yours).
    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                Button { withAnimation(.snappy) { select(i) } } label: { stepRow(i, s) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private func stepRow(_ i: Int, _ s: Step) -> some View {
        let on = i == selectedStep
        return HStack(spacing: 6) {
            Text(name(s.fromID)).foregroundStyle(colorFor(s.fromID)).font(.caption.weight(.semibold)).lineLimit(1)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
            Text(name(s.toID)).foregroundStyle(colorFor(s.toID)).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 6)
            Text(SwapChips.chipDay(s.dayID) + (s.desk.map { " · \($0)" } ?? ""))
                .font(.dsChip).foregroundStyle(.indigo)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(on ? Color.indigo.opacity(0.12) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: DS.rowRadius))
        .overlay(RoundedRectangle(cornerRadius: DS.rowRadius).stroke(on ? Color.indigo : .clear, lineWidth: 1.5))
    }

    /// The two people in the selected step, stacked (giver above, receiver below),
    /// each in their own color with the step's day focused.
    @ViewBuilder private func stepCalendars(for off: Int) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                if steps.indices.contains(selectedStep) {
                    let s = steps[selectedStep]
                    personCalendar(s.fromID, off: off, focus: s.dayID)
                    Image(systemName: "arrow.down").font(.headline).foregroundStyle(.secondary)
                    personCalendar(s.toID, off: off, focus: s.dayID)
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
            intent: intentClosure, topology: topoClosure, eventName: eventClosure)
    }

    /// My intents on the "You" calendar (hidden when the overlay toggle is off).
    private func myIntent(_ day: String) -> Color? {
        guard showIntents else { return nil }
        if let w = DayIntentStore.shared.workingIntent(forDay: day) { return w.brickColor }
        if let o = DayIntentStore.shared.offIntent(forDay: day) { return o.brickColor }
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
                            Image(systemName: "arrow.right.circle").foregroundStyle(.indigo)
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
                                        take: [], give: [], chain: legs)
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
    return TradeProfileStore.shared.profile(forWorker: id)?.displayName ?? id
}

func participantStatus(_ id: String) -> String? {
    if id == SettingsManager.shared.username {
        let s = SettingsManager.shared.statusBroadcast
        return s.isEmpty ? nil : s
    }
    let s = TradeProfileStore.shared.profile(forWorker: id)?.statusBroadcast
    return (s?.isEmpty ?? true) ? nil : s
}

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

