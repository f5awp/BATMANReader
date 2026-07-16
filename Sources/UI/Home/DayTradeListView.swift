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

    @State private var pickups: [TradeRouter.DayTradeRow] = []
    @State private var wantToWork: [TradeRouter.DayTradeRow] = []
    @State private var packages: [TradePackage] = []       // working day: real ranked swap packages
    @State private var detailPackage: TradePackage?         // tapped card → schedule-comparison detail
    @State private var loading = true
    @State private var selectedCandidate: PlanCandidate?   // tapped person → 2-way calendar (off-day pickups)
    @State private var fShifts: Set<ShiftAvailabilityType> = []   // shift-type filter (AM/PM/MID)
    @State private var fQuals: Set<String> = []                   // qual filter (desk's required qual)
    @State private var limitReturn = false                       // H6: filter by the return date I want back
    @State private var returnFrom = Date()
    @State private var returnTo = Date()

    private static let isoF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    /// The active return-date range (working days only, when the filter is on and valid).
    private var returnRange: ClosedRange<Date>? {
        guard limitReturn, !target.isOff, returnFrom <= returnTo else { return nil }
        return returnFrom...returnTo
    }

    /// The list shown for this day (off → pickups, working → who-could-work).
    private var activeRows: [TradeRouter.DayTradeRow] { target.isOff ? pickups : wantToWork }
    private func shiftOf(_ r: TradeRouter.DayTradeRow) -> ShiftAvailabilityType { .infer(fromStartHour: r.startHour) }
    private func qualOf(_ r: TradeRouter.DayTradeRow) -> String? { DeskRules.requiredQual(forDesk: r.desk) }
    private var availShifts: [ShiftAvailabilityType] {
        ShiftAvailabilityType.allCases.filter { s in activeRows.contains { shiftOf($0) == s } }
    }
    private var availQuals: [String] { Set(activeRows.compactMap { qualOf($0) }).sorted() }
    private func passesFilter(_ r: TradeRouter.DayTradeRow) -> Bool {
        (fShifts.isEmpty || fShifts.contains(shiftOf(r)))
            && (fQuals.isEmpty || (qualOf(r).map { fQuals.contains($0) } ?? false))
    }
    private var shownRows: [TradeRouter.DayTradeRow] {
        var rows = activeRows.filter(passesFilter)
        if let range = returnRange {   // H6: only people who could give me a return day in the range
            let peers = radar.peersWithReturnDay(fromISO: Self.isoF.string(from: range.lowerBound),
                                                 toISO: Self.isoF.string(from: range.upperBound))
            rows = rows.filter { peers.contains($0.peerID) }
        }
        return rows
    }
    /// Working-day swap packages, filtered by the return-date range (H6) — a package qualifies if any of the
    /// peer's return options fall in the range. Already rank-sorted at load.
    private var shownPackages: [TradePackage] {
        guard let range = returnRange else { return packages }
        let from = Self.isoF.string(from: range.lowerBound), to = Self.isoF.string(from: range.upperBound)
        return packages.filter { pkg in
            pkg.assignments.flatMap { $0.takeOptions.isEmpty ? $0.takeDayIDs : $0.takeOptions }
                .contains { $0 >= from && $0 <= to }
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
                } else if target.isOff {
                    if availShifts.count > 1 || !availQuals.isEmpty { filterBar }
                    Section {
                        if shownRows.isEmpty {
                            emptyRow(activeRows.isEmpty ? "Nobody working this day has marked it to trade away."
                                                       : "No one matches these filters.")
                        } else {
                            ForEach(shownRows) { personCard($0, showsShift: true) }
                        }
                    } header: {
                        Label("Shifts you can pick up", systemImage: "tray.and.arrow.down")
                    } footer: { radarStamp }
                } else {
                    filterBar   // return-date range (H6)
                    Section {
                        if shownPackages.isEmpty {
                            emptyRow(packages.isEmpty ? "No swaps found for this day."
                                                      : "No swaps have a return date in that range.")
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
                        Label("Who could work this day", systemImage: "hand.raised")
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
            // Tap a person → the two-way calendar, seeded with this day (their shift on an off day, mine on
            // a working day) so both parties' alternates are visible.
            .sheet(item: $selectedCandidate) { cand in
                TwoWaySheet(candidate: cand,
                            initialGive: target.isOff ? [] : [target.dayID],
                            initialTake: target.isOff ? [target.dayID] : [],
                            returnRange: returnRange)   // H6: limit their return dates to my chosen range
            }
            // Working-day swap card → the schedule-comparison detail (twin calendars) to pick days + propose.
            .fullScreenCover(item: $detailPackage) { pkg in
                PackageDetailView(package: pkg, onPropose: { p in Task { await propose(p) } }, onExecute: {})
            }
        }
    }

    /// A tappable person, styled as an app card (ECB / qual-swap format) → opens the 2-way calendar.
    @ViewBuilder private func personCard(_ row: TradeRouter.DayTradeRow, showsShift: Bool) -> some View {
        Button {
            selectedCandidate = PlanCandidate(workerID: row.peerID, name: row.peerName, quals: [],
                                              coveredShiftIDs: [], bookendShiftIDs: [], week: [])
        } label: {
            DayTradeRowView(row: row, showsShift: showsShift)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dxCard()
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder private func emptyRow(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    /// Shift-type + qual filter chips (only the values actually present in this day's list appear).
    @ViewBuilder private var filterBar: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(availShifts, id: \.self) { s in
                        filterChip(s.rawValue, on: fShifts.contains(s), tint: AppColor.primary) {
                            if fShifts.contains(s) { fShifts.remove(s) } else { fShifts.insert(s) }
                        }
                    }
                    ForEach(availQuals, id: \.self) { q in
                        filterChip(q, on: fQuals.contains(q), tint: AppColor.special) {
                            if fQuals.contains(q) { fQuals.remove(q) } else { fQuals.insert(q) }
                        }
                    }
                    if !fShifts.isEmpty || !fQuals.isEmpty {
                        Button { fShifts = []; fQuals = [] } label: {
                            Label("Clear", systemImage: "xmark.circle.fill").font(.caption)
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            // H6: on a working day, narrow to people who could give me a return day in a date range — and the
            // two-way opens showing only those return dates.
            if !target.isOff {
                Toggle("Filter by return date", isOn: $limitReturn.animation())
                if limitReturn {
                    DatePicker("From", selection: $returnFrom, displayedComponents: .date)
                    DatePicker("To", selection: $returnTo, in: returnFrom..., displayedComponents: .date)
                }
            }
        } header: { Text("Filter") }
    }

    private func filterChip(_ label: String, on: Bool, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.dsBadge)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(on ? tint.opacity(DS.pillFill) : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? tint : Color.secondary)
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var radarStamp: some View {
        if let t = radar.lastRefreshed {
            Text("Radar updated \(t.formatted(.relative(presentation: .named)))")
        }
    }

    /// Load this day's rows from the precomputed index. A cold start (never computed) or the manual refresh
    /// runs ONE recompute; otherwise it's an instant O(1) lookup.
    private func reload(fullRadar: Bool) async {
        loading = true
        if fullRadar || !radar.hasComputed { await radar.recompute(scope: .local) }
        if target.isOff {
            // OFF day = pickups (covering someone's shift): the broad eligible pool, tier-sorted.
            let r = radar.rows(forDay: target.dayID)
            pickups = r.pickups.sorted { $0.tier != $1.tier ? $0.tier > $1.tier : $0.peerName < $1.peerName }
            wantToWork = []; packages = []
        } else {
            // WORKING day = trade it away: real ranked 2-person swap packages (same engine as Trade Solutions),
            // rendered as CompactSwapCards. Falls back to nothing if no swap exists.
            let me = SettingsManager.shared.username
            if let shift = ShiftStore.shared.shifts.first(where: { $0.id == target.dayID }), !shift.isOff {
                let pkgs = await TradeRouter.packages(forGiveShifts: [shift], excluding: me)
                packages = pkgs.filter { $0.usesCompactCard }.sorted { $0.rankScore > $1.rankScore }
            } else { packages = [] }
            pickups = []; wantToWork = []
        }
        loading = false
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
