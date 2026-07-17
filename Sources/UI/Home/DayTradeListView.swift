// DayTradeListView.swift
// Match Radar (DX-MATCH-RADAR-SPEC v3.1) — the day detail you get by tapping a day in Main View. Two
// tabs: TRADE LIST (default) = every legal trade for THIS date (shifts you can pick up + who wants to
// work it) plus the Watch Day toggle; INFO = the existing full intent/reason/note editor. The date is
// implicit (it's the day you tapped), so neither tab repeats it as an input.

import SwiftUI

/// The 2-tab container. Trade List is first (the default), Info second. Each tab owns its own
/// NavigationStack, so their toolbars never collide.
struct DayDetailSheet: View {
    let target: DayEditTarget
    enum Tab { case info, tradeList }
    @State private var tab: Tab

    init(target: DayEditTarget, initialTab: Tab = .info) {
        self.target = target
        _tab = State(initialValue: initialTab)
    }

    /// Keep (mustWork) and Blackout (mustBeOff) days are protected — you're not trading them, so there's no
    /// Trade List; show just the Info editor.
    private var protectedDay: Bool {
        DayIntentStore.shared.workingIntent(forDay: target.dayID) == .mustWork
            || DayIntentStore.shared.offIntent(forDay: target.dayID) == .mustBeOff
    }

    var body: some View {
        // The Info tab is always present (stable identity, so its editor keeps its in-progress state); the
        // Trade List tab is conditional on the LIVE intent. Because the intent pickers write to the store
        // immediately, changing a Keep/Blackout day to a tradeable intent makes the Trade List tab appear
        // right away — no Save, no dismiss, no re-entering.
        TabView(selection: $tab) {
            DayIntentEditor(target: target)
                .tabItem { Label("Info", systemImage: "info.circle") }.tag(Tab.info)
            if !protectedDay {
                // Tab-gated: the Trade List only computes/loads once its tab is actually selected.
                DayTradeListPane(target: target, isActive: tab == .tradeList)
                    .tabItem { Label("Trade List", systemImage: "arrow.left.arrow.right") }.tag(Tab.tradeList)
            }
        }
    }
}

/// Section A/B for one date, served O(1) from `MatchStore`'s precomputed day index (a cold start triggers
/// one recompute with a spinner). Tap a person → the 2-way calendar.
struct DayTradeListPane: View {
    let target: DayEditTarget
    let isActive: Bool

    @Environment(\.dismiss) private var dismiss
    private let radar = MatchStore.shared

    @State private var packages: [TradePackage] = []       // real ranked swap packages (both directions)
    @State private var detailPackage: TradePackage?         // tapped card → schedule-comparison detail
    @State private var loading = true
    @State private var limitDate = false                    // filter by the flexible day's date range
    @State private var dateFrom = Date()
    @State private var dateTo = Date()

    private static let isoF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    /// The active date range (when the filter is on and valid).
    private var dateRange: ClosedRange<Date>? {
        guard limitDate, dateFrom <= dateTo else { return nil }
        return dateFrom...dateTo
    }
    /// The two-way seed range (working days limit the return/take dates; off days don't seed a range).
    private var returnRange: ClosedRange<Date>? { target.isOff ? nil : dateRange }

    /// Packages after the date filter, applied to the FLEXIBLE side: on a working day that's the return I get
    /// (their days); on an off day it's the day I give back (my days) — since the day I pick up is fixed.
    private var shownPackages: [TradePackage] {
        guard let range = dateRange else { return packages }
        let from = Self.isoF.string(from: range.lowerBound), to = Self.isoF.string(from: range.upperBound)
        return packages.filter { pkg in
            pkg.assignments.flatMap { a -> [String] in
                target.isOff ? a.giveDayIDs : (a.takeOptions.isEmpty ? a.takeDayIDs : a.takeOptions)
            }.contains { $0 >= from && $0 <= to }
        }
    }

    private var prettyDate: String {
        guard let d = TradeMatcher.dayDate(fromISO: target.dayID) else { return target.dayID }
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f.string(from: d)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: Binding(
                        get: { radar.isWatched(target.dayID) },
                        set: { radar.setWatched(target.dayID, $0) })) {
                        Label("Watch Day", systemImage: "star")
                    }
                } footer: {
                    Text("Get an alert when a new shift you can pick up appears on this day — checked each time you open the app.")
                }

                if loading {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                } else {
                    filterBar
                    Section {
                        if shownPackages.isEmpty {
                            emptyRow(packages.isEmpty
                                     ? (target.isOff ? "No swaps found to pick up this day." : "No swaps found for this day.")
                                     : "No swaps match that date range.")
                        } else {
                            ForEach(shownPackages) { pkg in
                                CompactSwapCard(package: pkg,
                                                onPropose: { p in Task { await propose(p) } },
                                                onOpen: { detailPackage = pkg })
                                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                                    .listRowBackground(Color.clear)
                            }
                        }
                    } header: {
                        Label(target.isOff ? "Shifts you can pick up" : "Who could work this day",
                              systemImage: target.isOff ? "tray.and.arrow.down" : "hand.raised")
                    } footer: { radarStamp }
                }
            }
            .navigationTitle(prettyDate)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { Task { await reload(fullRadar: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading)
                }
            }
            // Tab-gated: only load when the Trade List tab is active (keyed so it fires on activation + day change).
            .task(id: "\(target.dayID)-\(isActive)") { if isActive { await reload(fullRadar: false) } }
            // Tap a swap card → the schedule-comparison detail (twin calendars) to pick days + propose.
            .fullScreenCover(item: $detailPackage) { pkg in
                PackageDetailView(package: pkg, onPropose: { p in Task { await propose(p) } }, onExecute: {})
            }
        }
    }

    @ViewBuilder private func emptyRow(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    /// A single date-range filter (no empty chip box). Narrows to swaps whose flexible day falls in the range.
    @ViewBuilder private var filterBar: some View {
        Section {
            Toggle(target.isOff ? "Filter by give-back date" : "Filter by return date", isOn: $limitDate.animation())
            if limitDate {
                DatePicker("From", selection: $dateFrom, displayedComponents: .date)
                DatePicker("To", selection: $dateTo, in: dateFrom..., displayedComponents: .date)
            }
        } header: { Text("Filter") }
    }

    @ViewBuilder private var radarStamp: some View {
        if let t = radar.lastRefreshed {
            Text("Radar updated \(t.formatted(.relative(presentation: .named)))")
        }
    }

    /// Build the ranked swap packages for this day (same engine as Trade Solutions). A cold radar start runs
    /// one recompute; then packages() explores the reciprocal swaps.
    private func reload(fullRadar: Bool) async {
        loading = true
        if fullRadar || !radar.hasComputed { await radar.recompute(scope: .local) }
        let me = SettingsManager.shared.username
        if target.isOff {
            // OFF day = pick up someone's shift on this date: swaps where a peer gives ME this day back. Run the
            // give-away search over my working days, keep 2-person deals that can hand ME this day, and promote
            // it to the shown "You get" so the card reads correctly.
            let today = Calendar.current.startOfDay(for: Date())
            let mine = ShiftStore.shared.shifts.filter { !$0.isOff && $0.date >= today }
            let pkgs = await TradeRouter.packages(forGiveShifts: mine, excluding: me)
            packages = pkgs.compactMap { pkg -> TradePackage? in
                guard pkg.usesCompactCard, let a = pkg.assignments.first else { return nil }
                let opts = a.takeOptions.isEmpty ? a.takeDayIDs : a.takeOptions
                guard opts.contains(target.dayID) else { return nil }
                return Self.promoteTake(pkg, to: target.dayID)
            }.sorted { $0.rankScore > $1.rankScore }
        } else {
            // WORKING day = trade it away: swaps handing off THIS shift.
            if let shift = ShiftStore.shared.shifts.first(where: { $0.id == target.dayID }), !shift.isOff {
                let pkgs = await TradeRouter.packages(forGiveShifts: [shift], excluding: me)
                packages = pkgs.filter { $0.usesCompactCard }.sorted { $0.rankScore > $1.rankScore }
            } else { packages = [] }
        }
        loading = false
    }

    /// A copy of a 2-person package with `day` promoted to the shown give-back ("You get"), preserving scores.
    private static func promoteTake(_ pkg: TradePackage, to day: String) -> TradePackage {
        guard let a = pkg.assignments.first else { return pkg }
        let a2 = PackageAssignment(workerID: a.workerID, name: a.name, giveDayIDs: a.giveDayIDs,
                                   takeDayIDs: [day], takeOptions: a.takeOptions)
        var p2 = TradePackage(id: pkg.id, methodology: pkg.methodology, assignments: [a2], route: pkg.route,
                              urgency: pkg.urgency, isOptimal: pkg.isOptimal, fireCount: pkg.fireCount,
                              bookendTotal: pkg.bookendTotal, qualSwap: pkg.qualSwap,
                              partnerPrior: pkg.partnerPrior, acceptanceScore: pkg.acceptanceScore,
                              coverageCount: pkg.coverageCount)
        p2.rankScore = pkg.rankScore
        return p2
    }

    /// Propose a swap package straight from the trade list — files under Requests (manual, origin .search).
    private func propose(_ pkg: TradePackage) async {
        for a in pkg.assignments {
            await MessagingStore.shared.sendRequest(
                to: a.workerID, toName: a.name, note: "Swap proposed from your trade list.",
                take: a.takeDayIDs, give: a.giveDayIDs, origin: .search)
        }
        WidgetData.update()
        dismiss()
    }
}

/// One row: peer name, optional shift (desk + AM/PM/MID), and a kind chip (Day / ECB / Both).
private struct DayTradeRowView: View {
    let row: TradeRouter.DayTradeRow
    let showsShift: Bool

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: row.peerName, id: row.peerID, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.peerName).font(.dsCardTitle)
                if showsShift, !row.desk.isEmpty {
                    Text("\(Self.timeLabel(row.startHour)) · desk \(row.desk)")
                        .font(.dsCardMeta).foregroundStyle(.secondary)
                }
                if let note = row.note, !note.isEmpty {
                    Label(note, systemImage: "quote.bubble")
                        .font(.dsCardMeta).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            KindChip(kind: row.kind)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }

    static func timeLabel(_ h: Int) -> String {
        switch h {
        case 5:  return "AM"
        case 13: return "PM"
        case 21: return "MID"
        default: return String(format: "%02d:00", h)
        }
    }
}

/// Small chip naming the trade kind a peer will accept for this day.
struct KindChip: View {
    let kind: TradeKind
    private var label: String { kind == .day ? "Day" : (kind == .ecb ? "ECB" : "Any") }
    private var tint: Color { kind == .ecb ? AppColor.special : AppColor.primary }
    var body: some View {
        Text(label)
            .font(.dsBadge)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(DS.pillFill),
                        in: RoundedRectangle(cornerRadius: DS.pillRadius, style: .continuous))
            .foregroundStyle(tint)
    }
}
