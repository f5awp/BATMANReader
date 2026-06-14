// TradeIntentsFeed.swift
// The "Trade by Intents" feed (4 tier accordions from TradeRouter.tieredSolutions)
// plus the N-way chain card and the execution-confirmation checkout.

import SwiftUI

// MARK: - Feed

struct TradeByIntentsFeed: View {

    @Binding var whatIf: Bool

    @State private var packages: [TradePackage] = []
    @State private var tiers: [(tier: SolutionTier, routes: [NWayRoute])] = []
    @State private var loading = true
    @State private var twoWayCandidate: PlanCandidate?
    @State private var execRoute: NWayRoute?
    @State private var sentMessage: String?
    @State private var selectedTier: SolutionTier = .matchingIntents
    @State private var detailPackage: TradePackage?
    @State private var showTierInfo = false

    private func routes(_ tier: SolutionTier) -> [NWayRoute] {
        tiers.first { $0.tier == tier }?.routes ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if whatIf {
                    Label("What If? on — extended matches (toggle in Trade Search)",
                          systemImage: "wand.and.stars")
                        .font(.caption).foregroundStyle(.purple)
                        .padding(.horizontal).padding(.top, 8)
                }

                if !packages.isEmpty {
                    sectionHeader("Packages", "Swap away all your selected days — fewest people first")
                    ForEach(packages) { pkg in
                        PackageCard(package: pkg,
                                    onPropose: { Task { await propose(pkg) } },
                                    onExecute: { if let r = pkg.route { execRoute = r } },
                                    onOpen: { detailPackage = pkg })
                    }
                }

                sectionHeader("Individual swaps", "Browse by match quality")

                if loading {
                    ProgressView("Finding intent matches…")
                        .frame(maxWidth: .infinity).padding(.top, 30)
                } else if tiers.allSatisfy(\.routes.isEmpty) {
                    ContentUnavailableView("No Intent Matches",
                        systemImage: "sparkles",
                        description: Text("Mark days to trade away on Home, or try What If? mode to widen the search."))
                        .padding(.top, 20)
                } else {
                    tierTabs
                    let r = routes(selectedTier)
                    HStack {
                        Text(selectedTier.label).font(.headline)
                        Button { showTierInfo = true } label: {
                            Image(systemName: "info.circle").font(.subheadline)
                        }
                        .accessibilityLabel("What do these tiers mean?")
                        Spacer()
                        Text("^[\(r.count) match](inflect: true)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    Text(tierExplain(selectedTier))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    if r.isEmpty {
                        Text("No matches in this tier.").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                    } else {
                        ForEach(r) { route in
                            RouteCard(route: route,
                                      onOpenSwap: { openSwap(route) },
                                      onExecute: { execRoute = route })
                        }
                    }
                }

                if !loading { TradeFeedKey().padding(.horizontal).padding(.top, 8) }
            }
            .padding(.bottom, 24)
        }
        .fullScreenCover(item: $twoWayCandidate) { TwoWaySheet(candidate: $0) }
        .fullScreenCover(item: $detailPackage) { pkg in
            PackageDetailView(package: pkg,
                              onPropose: { Task { await propose(pkg) } },
                              onExecute: { if let r = pkg.route { execRoute = r } })
        }
        .sheet(item: $execRoute) { ExecutionConfirmationView(route: $0) }
        .sheet(isPresented: $showTierInfo) { TierLegendSheet() }
        .task { await reload() }
        .onChange(of: whatIf) { _, _ in Task { await reload() } }
        .alert("Package sent", isPresented: Binding(
            get: { sentMessage != nil }, set: { if !$0 { sentMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(sentMessage ?? "") }
    }

    /// Segmented tier selector with per-tier match counts.
    private var tierTabs: some View {
        Picker("Tier", selection: $selectedTier) {
            ForEach(SolutionTier.allCases.sorted { $0.order < $1.order }) { t in
                Text("\(tierShort(t)) \(routes(t).count)").tag(t)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    private func tierShort(_ t: SolutionTier) -> String {
        switch t {
        case .matchingIntents:     return "Intents"
        case .intentsAndBookends:  return "Bookends"
        case .neutralOptimization: return "Neutral"
        case .globalPool:          return "All"
        }
    }

    /// One-line plain-English meaning of each match tier, shown under the tabs.
    private func tierExplain(_ t: SolutionTier) -> String {
        switch t {
        case .matchingIntents:
            return "Best matches: you want to give the day away AND they want to pick it up — wanted on both sides."
        case .intentsAndBookends:
            return "Intent matches plus bookend pickups — the day attaches to the edge of their work block, so no one's break gets split."
        case .neutralOptimization:
            return "They didn't ask for these days, but their openness allows the pickup. A clean swap that simply works out."
        case .globalPool:
            return "Every legal swap in the pool, including looser matches. The widest net — use when the cleaner tiers are empty."
        }
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
        tiers = await TradeRouter.tieredSolutions(isWhatIfModeActive: whatIf)
        loading = false
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
        sentMessage = "Sent to \(n) dispatcher\(n == 1 ? "" : "s"). Track replies in your Inbox."
    }

    /// 2-participant routes reopen the rich two-way sheet (it re-explores by ID).
    private func openSwap(_ route: NWayRoute) {
        guard route.participants.count == 2 else { return }
        let peerID = route.participants[1]
        twoWayCandidate = PlanCandidate(workerID: peerID, name: participantName(peerID),
                                        quals: [], coveredShiftIDs: [], bookendShiftIDs: [], week: [])
    }
}

// MARK: - Feed key (explains the chips, flame, and quality pills)

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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name).font(.dsLabel).foregroundStyle(color).lineLimit(1)
            }
            if !giveDays.isEmpty { chipRow("Gives", giveDays, filled: false) }
            if !getDays.isEmpty  { chipRow("Gets", getDays, filled: true) }
        }
    }

    private func chipRow(_ lbl: String, _ days: [String], filled: Bool) -> some View {
        HStack(spacing: 5) {
            Text(lbl).font(.caption2).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
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

/// Renders a circular loop as explicit directed handoffs — "You → Denny: Jul 4",
/// "Denny → Dimitry: Jul 8", "Dimitry → You: Jul 12" — so who gives/gets what is
/// unambiguous in a 3-/4-person chain.
struct HandoffChain: View {
    let legs: [NWayLeg]
    private var myID: String { SettingsManager.shared.username }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(legs) { leg in
                HStack(spacing: 6) {
                    Text(label(leg.fromID)).font(.caption.weight(.semibold))
                        .foregroundStyle(leg.fromID == myID ? BrickPalette.mineScheme : .primary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Text(label(leg.toID)).font(.caption.weight(.semibold))
                        .foregroundStyle(leg.toID == myID ? BrickPalette.mineScheme : .primary)
                    Spacer(minLength: 6)
                    Text("\(SwapChips.chipDay(leg.dayID)) · \(leg.desk)")
                        .font(.dsChip)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.indigo.opacity(DS.pillFill), in: Capsule())
                        .foregroundStyle(.indigo)
                }
            }
        }
    }

    private func label(_ id: String) -> String { id == myID ? "You" : firstName(participantName(id)) }
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

// MARK: - Route card (direct swap vs. circular chain)

struct RouteCard: View {
    let route: NWayRoute
    let onOpenSwap: () -> Void
    let onExecute: () -> Void

    private var myID: String { SettingsManager.shared.username }
    private var peerID: String {
        route.participants.count == 2 ? route.participants[1] : route.participants[0]
    }
    // This swap's actual days, from the legs: from me = you give, to me = you get.
    private var myGive: [String] { route.legs.filter { $0.fromID == myID }.map(\.dayID) }
    private var myGet:  [String] { route.legs.filter { $0.toID == myID }.map(\.dayID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if route.participants.count <= 2 {
                directSwap
            } else {
                chain
            }
        }
        .padding(DS.cardPadding)
        .background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))
        .padding(.horizontal)
    }

    // Direct 1-to-1: avatar + name + status, this swap's give/get days, open the sheet.
    private var directSwap: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Avatar(name: participantName(peerID), id: peerID, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(participantName(peerID)).font(.subheadline.bold())
                        if let status = participantStatus(peerID) {
                            Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if route.tier == .matchingIntents {
                        Label("Mutual intent", systemImage: "flame.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button("Open swap", action: onOpenSwap)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            SwapChips(giveDays: myGive, getDays: myGet)
        }
    }

    // Circular: a row per person showing exactly what THEY give and get, so a
    // 3-/4-way loop is unambiguous (not just your own side).
    private var chain: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.indigo)
                Text("\(route.participants.count)-way trade").font(.subheadline.bold())
                Spacer()
                Button("Execute", action: onExecute)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            // Explicit handoffs make the loop unambiguous: who gives which day to whom.
            HandoffChain(legs: route.legs)
        }
    }
}

// MARK: - Package card (one card per deal)

struct PackageCard: View {
    let package: TradePackage
    let onPropose: () -> Void
    let onExecute: () -> Void
    var onOpen: () -> Void = {}

    private var isCircular: Bool { package.methodology == .circular }

    private var headline: String {
        package.peopleCount == 1 ? "1-person swap" : "\(package.peopleCount)-person swap"
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
                    Text(headline).font(.subheadline.bold())
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    pill(quality.text, quality.color)
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
                        TraderChips(name: a.name, color: traderColor(idx),
                                    giveDays: a.takeDayIDs, getDays: a.giveDayIDs)
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
                    Label(isCircular ? "Execute trade" : "Propose to all",
                          systemImage: isCircular ? "arrow.triangle.2.circlepath" : "paperplane.fill")
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
    @State private var sel = 0                       // selected other-trader tab
    @State private var monthIndex = 0
    @State private var myDays: [String: String] = [:]
    @State private var peerDays: [String: [String: String]] = [:]
    @State private var showIntents = true

    private let cal = Calendar.current
    private let youColor = BrickPalette.mineScheme
    private let themColor = BrickPalette.peerScheme
    private let monthOffsets = Array(0...12)
    private static let monthF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f }()
    private var myID: String { SettingsManager.shared.username }

    private var assignments: [PackageAssignment] { package.assignments }
    private var current: PackageAssignment? { assignments.indices.contains(sel) ? assignments[sel] : nil }

    /// My give-days (blue) and take-days (orange) across the whole package.
    private var myGiveDays: Set<String> { Set(package.assignments.flatMap(\.giveDayIDs)) }
    private var myTakeDays: Set<String> { Set(package.assignments.flatMap(\.takeDayIDs)) }

    private var thisMonthStart: Date {
        cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
    }
    private func monthAnchor(_ offset: Int) -> Date {
        cal.date(byAdding: .month, value: offset, to: thisMonthStart) ?? thisMonthStart
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if assignments.count > 1 {
                    Picker("Trader", selection: $sel) {
                        ForEach(assignments.indices, id: \.self) { i in Text(assignments[i].name).tag(i) }
                    }
                    .pickerStyle(.segmented).padding(.horizontal)
                }

                if package.methodology == .circular, let route = package.route {
                    HandoffChain(legs: route.legs)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                } else if let a = current {
                    swapSummary(a)
                }

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
                        calendars(for: off).tag(off).padding(.horizontal)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                MiniScheduleLegend().padding(.horizontal)

                Button {
                    package.methodology == .greedy ? onPropose() : onExecute()
                    dismiss()
                } label: {
                    Label(package.methodology == .greedy ? "Propose package" : "Execute trade",
                          systemImage: package.methodology == .greedy ? "paperplane.fill" : "arrow.triangle.2.circlepath")
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

    /// The traded dates, used as the sheet title (e.g. "Jul 4 ⇄ Jul 11").
    private var dateTitle: String {
        let g = myGiveDays.sorted().map { SwapChips.chipDay($0) }
        let t = myTakeDays.sorted().map { SwapChips.chipDay($0) }
        if g.isEmpty && t.isEmpty { return "Swap" }
        return g.joined(separator: ", ") + "  ⇄  " + t.joined(separator: ", ")
    }

    /// Both sides spelled out, in each trader's color (matches their calendar).
    @ViewBuilder private func swapSummary(_ a: PackageAssignment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TraderChips(name: "You", color: youColor, giveDays: a.giveDayIDs, getDays: a.takeDayIDs)
            TraderChips(name: a.name, color: traderColor(sel), giveDays: a.takeDayIDs, getDays: a.giveDayIDs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private var isCircular: Bool { package.methodology == .circular }
    private var loopLegs: [NWayLeg] { package.route?.legs ?? [] }
    private func days(_ legs: [NWayLeg]) -> Set<String> { Set(legs.map(\.dayID)) }

    /// Each calendar reads in its OWNER's color: border = they trade away (give),
    /// fill = they take (get). Days come from ALL of that person's legs — including
    /// handoffs to/from a third party — so a circular loop is fully shown per person.
    private var youGive: Set<String> { isCircular ? days(loopLegs.filter { $0.fromID == myID }) : myGiveDays }
    private var youTake: Set<String> { isCircular ? days(loopLegs.filter { $0.toID == myID }) : myTakeDays }
    private func peerGive(_ p: String) -> Set<String> {
        isCircular ? days(loopLegs.filter { $0.fromID == p }) : Set(current?.takeDayIDs ?? [])
    }
    private func peerTake(_ p: String) -> Set<String> {
        isCircular ? days(loopLegs.filter { $0.toID == p }) : Set(current?.giveDayIDs ?? [])
    }

    @ViewBuilder private func calendars(for off: Int) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                MiniScheduleGrid(title: "You", days: myDays, month: monthAnchor(off),
                                 accent: youColor,
                                 giveDays: youGive, takeDays: youTake,
                                 intent: myIntent,
                                 topology: { DayIntentStore.shared.topology(forDay: $0) },
                                 eventName: { TwoWaySheet.eventText($0, topology: DayIntentStore.shared.topology(forDay: $0), includePrivate: true) })
                if let a = current {
                    MiniScheduleGrid(title: a.name, days: peerDays[a.workerID] ?? [:], month: monthAnchor(off),
                                     accent: traderColor(sel),
                                     giveDays: peerGive(a.workerID), takeDays: peerTake(a.workerID),
                                     intent: { peerIntent($0, workerID: a.workerID) },
                                     topology: TwoWaySheet.globalTopology, eventName: TwoWaySheet.globalEvent)
                }
            }
        }
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
        myDays = await TradeMatcher.dayLabels(forWorker: myID)
        for a in assignments where peerDays[a.workerID] == nil {
            peerDays[a.workerID] = await TradeMatcher.dayLabels(forWorker: a.workerID)
        }
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
        let chain = route.legs
            .map { "\(participantName($0.fromID))→\(participantName($0.toID)) [\(prettyDay($0.dayID))]" }
            .joined(separator: ", ")
        for pid in route.participants where pid != myID {
            await messaging.sendRequest(to: pid, toName: participantName(pid),
                                        note: "Circular trade (\(route.participants.count)-way): \(chain)",
                                        take: [], give: [])
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

// MARK: - Tier + mini-schedule legend

/// Explains the four match tiers and the dual mini-schedule color language.
struct TierLegendSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Match tiers") {
                    tierRow("Intents", "flame.fill", .orange,
                            "Wanted on BOTH sides — you want to give the day away and they want to pick it up. The strongest matches; propose these first.")
                    tierRow("Bookends", "book.fill", .blue,
                            "Intent matches plus bookend pickups: the day attaches to the edge of their existing work block, so nobody's break gets split by an isolated day.")
                    tierRow("Neutral", "equal.circle.fill", .secondary,
                            "They didn't specifically ask for these days, but their openness setting allows the pickup. A clean swap that just works out.")
                    tierRow("All", "circle.grid.2x2.fill", .indigo,
                            "Every legal swap in the pool, including looser matches. The widest net — use when the cleaner tiers come up empty.")
                }

                Section("Reading the mini-schedule") {
                    Text("When you open a match, two calendars show the swap on each person's real schedule. You read blue (your schedule); the other person reads red (theirs) — so a swapped shift looks like it belongs to whichever side it lands on:")
                        .font(.subheadline)
                    legendRow(border: BrickPalette.mineScheme, fill: nil,
                              title: "A day you give away",
                              detail: "Blue border (you give). On their calendar the same day is a red fill (they get).")
                    legendRow(border: nil, fill: BrickPalette.mineScheme,
                              title: "A day you pick up",
                              detail: "Blue fill (you get). On their calendar it's a red border (they give).")
                    HStack(spacing: 10) {
                        BrickPalette.change.frame(width: 18, height: 6).clipShape(Capsule())
                        Text("A thick bar along the bottom marks intent (e.g. a day they're seeking). Tap the 🎨 to hide it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                    HStack(spacing: 10) {
                        Circle().fill(BrickPalette.highImpact).frame(width: 16, height: 16)
                        Circle().fill(BrickPalette.personalDay).frame(width: 16, height: 16)
                        Text("Gold = high-impact day, pink = personal day. Tap one to see what it is.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Circle().fill(BrickPalette.mineScheme).frame(width: 18, height: 18)
                        Text("Today (a blue ring when it lands on a gold/pink day). Faint days are the previous/next month.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("What the tiers mean")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func tierRow(_ name: String, _ icon: String, _ tint: Color, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold))
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func legendRow(border: Color?, fill: Color?, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 5)
                .fill((fill ?? Color(.systemGray5)).opacity(fill == nil ? 1 : 0.5))
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(border ?? .clear, lineWidth: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
