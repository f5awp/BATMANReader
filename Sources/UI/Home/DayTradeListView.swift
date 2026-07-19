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

    /// A day that has already passed can't be traded — no Trade List, and the Info editor is read-only.
    private var pastDay: Bool {
        guard let d = TradeMatcher.dayDate(fromISO: target.dayID) else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        // The Info tab is always present (stable identity, so its editor keeps its in-progress state); the
        // Trade List tab is conditional on the LIVE intent. Because the intent pickers write to the store
        // immediately, changing a Keep/Blackout day to a tradeable intent makes the Trade List tab appear
        // right away — no Save, no dismiss, no re-entering.
        TabView(selection: $tab) {
            DayIntentEditor(target: target, readOnly: pastDay)
                .tabItem { Label("Info", systemImage: "info.circle") }.tag(Tab.info)
            if !protectedDay && !pastDay {
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
    @State private var limitDate = false                    // filter by the flexible day's date(s)
    @State private var dateMode = 0                         // 0 = range · 1 = specific dates
    @State private var dateFrom = Date()
    @State private var dateTo = Date()
    @State private var specificDates: Set<DateComponents> = []
    @State private var shiftFilter: Set<ShiftAvailabilityType> = []   // filter by the shift you'd work
    @State private var qualFilter: Set<String> = []                    // filter by the worked desk's qual
    @State private var dayType: [String: ShiftAvailabilityType] = [:]  // "peerID|dayID" → that shift's type
    @State private var dayQual: [String: String] = [:]                 // "peerID|dayID" → desk's required qual
    @State private var tlSheet: TLFilterSheet?
    private enum TLFilterSheet: Int, Identifiable { case dates, shifts, quals; var id: Int { rawValue } }
    @State private var loadedSig: Int?   // cache key of the last load — skip recompute on tab flips

    /// The inputs that change the results (day + its trade-options). Same signature ⇒ reuse the cached
    /// packages instead of recomputing every time the Trade List tab is re-selected.
    private var loadSignature: Int {
        var h = Hasher()
        h.combine(target.dayID)
        h.combine(DayIntentStore.shared.acceptScope(forDay: target.dayID))
        h.combine(DayIntentStore.shared.tradeKind(forDay: target.dayID))
        return h.finalize()
    }

    /// The days I'd actually WORK in a package (off-day pickup = the promoted take; trade-away = the returns).
    private func workedDays(_ a: PackageAssignment) -> [String] {
        target.isOff ? a.takeDayIDs : (a.takeOptions.isEmpty ? a.takeDayIDs : a.takeOptions)
    }
    /// Quals present among the shown legs — the qual chip's option list.
    private var availableQuals: [String] {
        Set(packages.flatMap { p in p.assignments.flatMap { a in workedDays(a).compactMap { dayQual["\(a.workerID)|\($0)"] } } }).sorted()
    }

    private static let isoF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    /// The allowed ISO days from the filter — a contiguous range OR a set of specific dates. nil = filter off.
    private var allowedDays: Set<String>? {
        guard limitDate else { return nil }
        let cal = Calendar.current
        if dateMode == 1 {
            return Set(specificDates.compactMap { cal.date(from: $0) }.map { Self.isoF.string(from: $0) })
        }
        guard dateFrom <= dateTo else { return nil }
        var out = Set<String>(); var d = cal.startOfDay(for: dateFrom); let end = cal.startOfDay(for: dateTo)
        while d <= end { out.insert(Self.isoF.string(from: d)); d = cal.date(byAdding: .day, value: 1, to: d) ?? end.addingTimeInterval(86_400) }
        return out
    }

    /// Packages after Give-back Date + Shift + Qual filters. Date applies to the FLEXIBLE side (on a working
    /// day that's the return I get; on an off day it's the day I give back). Shift/Qual apply to the leg I'd
    /// work (looked up per peer); a package whose leg-info is unknown is never hidden.
    private var shownPackages: [TradePackage] {
        packages.filter { pkg in
            if let allowed = allowedDays, !allowed.isEmpty {
                let flex = pkg.assignments.flatMap { a -> [String] in
                    target.isOff ? a.giveDayIDs : (a.takeOptions.isEmpty ? a.takeDayIDs : a.takeOptions)
                }
                if !flex.contains(where: allowed.contains) { return false }
            }
            // Shift / Qual apply to the days I'd WORK (both day types), resolved per (peer, day) from the
            // roster. A package passes if ANY worked day matches; unknown-info days never wrongly hide it.
            if !shiftFilter.isEmpty {
                let types = pkg.assignments.flatMap { a in workedDays(a).compactMap { dayType["\(a.workerID)|\($0)"] } }
                if !types.isEmpty, !types.contains(where: shiftFilter.contains) { return false }
            }
            if !qualFilter.isEmpty {
                let quals = pkg.assignments.flatMap { a in workedDays(a).compactMap { dayQual["\(a.workerID)|\($0)"] } }
                if !quals.isEmpty, !quals.contains(where: qualFilter.contains) { return false }
            }
            return true
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
                        Label("Watch Day", systemImage: "bell")
                    }
                } footer: {
                    Text("Flags this day with a blue “!” in its top-left corner so it's easy to spot, and keeps it front-and-center in your daily summary. New and existing matches roll up in your periodic Match Summary (Settings › Notifications). The orange disc on a date means a match already exists there.")
                }

                if !loading { filterBar }
                Section {
                    // Empty text only once loading has settled — the overlay owns the "in flight" state so the
                    // spinner is reliable (the old inline list-row spinner sometimes didn't render).
                    if shownPackages.isEmpty {
                        if !loading {
                            emptyRow(packages.isEmpty
                                     ? (target.isOff ? "No swaps found to pick up this day." : "No swaps found for this day.")
                                     : "No swaps match that date range.")
                        }
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
                } footer: { if !loading { radarStamp } }
            }
            .loadingOverlay(loading, label: "Finding trades…")
            .navigationTitle(prettyDate)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { Task { await reload(fullRadar: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading)
                }
            }
            // Tab-gated + cached: load when the tab is active AND the inputs changed since the last load, so
            // flipping between Info ↔ Trade List reuses the cached results instead of recomputing each time.
            .task(id: "\(target.dayID)-\(isActive)") { if isActive, loadedSig != loadSignature { await reload(fullRadar: false) } }
            // Tap a swap card → the schedule-comparison detail (twin calendars) to pick days + propose.
            .fullScreenCover(item: $detailPackage) { pkg in
                PackageDetailView(package: pkg, onPropose: { p in Task { await propose(p) } }, onExecute: {})
            }
            .sheet(item: $tlSheet) { which in
                switch which {
                case .dates: datesSheet
                case .shifts:
                    MultiSelectSheet(title: "Shift types",
                                     options: ShiftAvailabilityType.allCases.map { ($0.rawValue, $0.rawValue) },
                                     selected: Binding(get: { Set(shiftFilter.map(\.rawValue)) },
                                                       set: { shiftFilter = Set($0.compactMap(ShiftAvailabilityType.init(rawValue:))) }),
                                     onApply: {})
                case .quals:
                    MultiSelectSheet(title: "Desk quals",
                                     options: availableQuals.map { ($0, "\($0) — \(DispatcherDirectory.qualName($0))") },
                                     selected: $qualFilter, onApply: {})
                }
            }
        }
    }

    @ViewBuilder private func emptyRow(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private var dateChipLabel: String {
        guard limitDate else { return "Give-back Date" }
        if dateMode == 1 {
            return specificDates.isEmpty ? "Give-back Date" : "\(specificDates.count) date\(specificDates.count == 1 ? "" : "s")"
        }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return "\(f.string(from: dateFrom))–\(f.string(from: dateTo))"
    }

    /// Unified chip-row filter: Give-back Date · Shift · Qual (Qual only when the pickups span quals).
    @ViewBuilder private var filterBar: some View {
        Section {
            DXFilterChipRow {
                Button { tlSheet = .dates } label: {
                    dxFilterChipLabel(dateChipLabel, systemImage: "calendar", active: limitDate)
                }.buttonStyle(.plain)
                Button { tlSheet = .shifts } label: {
                    dxFilterChipLabel(shiftFilter.isEmpty ? "Shift" : shiftFilter.map(\.rawValue).sorted().joined(separator: "/"),
                                      systemImage: "clock", active: !shiftFilter.isEmpty)
                }.buttonStyle(.plain)
                if !availableQuals.isEmpty {
                    Button { tlSheet = .quals } label: {
                        dxFilterChipLabel(qualFilter.isEmpty ? "Qual" : qualFilter.sorted().joined(separator: "/"),
                                          systemImage: "q.square", active: !qualFilter.isEmpty)
                    }.buttonStyle(.plain)
                }
            }
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
        }
    }

    /// The Give-back Date editor (range OR specific), shown as a sheet from the date chip.
    @ViewBuilder private var datesSheet: some View {
        NavigationStack {
            Form {
                Toggle("Filter by give-back date", isOn: $limitDate.animation())
                if limitDate {
                    Picker("Mode", selection: $dateMode.animation()) {
                        Text("Range").tag(0); Text("Specific dates").tag(1)
                    }.pickerStyle(.segmented)
                    if dateMode == 0 {
                        DatePicker("From", selection: $dateFrom, displayedComponents: .date)
                        DatePicker("To", selection: $dateTo, in: dateFrom..., displayedComponents: .date)
                    } else {
                        MultiDatePicker("Dates", selection: $specificDates, in: Date()...).frame(minHeight: 300)
                    }
                }
            }
            .navigationTitle("Give-back Date").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if limitDate {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear") { limitDate = false; specificDates = [] }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { DXCloseButton { tlSheet = nil } }
            }
        }
        .presentationDetents([.medium, .large])
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
        dayType = [:]; dayQual = [:]
        if fullRadar || !radar.hasComputed { await radar.recompute(scope: .local) }
        let me = SettingsManager.shared.username
        if target.isOff {
            // OFF day = pick up someone's shift on this date: swaps where a peer gives ME this day back. Run the
            // give-away search over my working days, keep 2-person deals that can hand ME this day, and promote
            // it to the shown "You get" so the card reads correctly.
            let today = Calendar.current.startOfDay(for: Date())
            let mine = ShiftStore.shared.shifts.filter { !$0.isOff && $0.date >= today }
            let pkgs = await TradeRouter.packages(forGiveShifts: mine, excluding: me)
            // HARD accept-scope gate for pickups: the engine keys scope to give-days, so an off-day pickup
            // isn't gated there. Apply THIS off day's scope to the shift I'd actually pick up (the peer's
            // shift on this date, from the radar rows): shift-type + qual/desk gate the pickup; the date facet
            // scopes the give-back day(s).
            let scope = DayIntentStore.shared.acceptScope(forDay: target.dayID)
            let pickupByPeer = Dictionary(radar.rows(forDay: target.dayID).pickups.map { ($0.peerID, $0) },
                                          uniquingKeysWith: { a, _ in a })
            packages = pkgs.compactMap { pkg -> TradePackage? in
                guard pkg.usesCompactCard, let a = pkg.assignments.first else { return nil }
                let opts = a.takeOptions.isEmpty ? a.takeDayIDs : a.takeOptions
                guard opts.contains(target.dayID) else { return nil }
                if !scope.isOpen, let row = pickupByPeer[a.workerID] {
                    let type = ShiftAvailabilityType.infer(fromStartHour: row.startHour)
                    guard scope.acceptsLeg(shiftType: type, desk: row.desk) else { return nil }
                    if let dates = scope.dates, !dates.isEmpty, !a.giveDayIDs.contains(where: dates.contains) { return nil }
                }
                return Self.promoteTake(pkg, to: target.dayID)
            }.sorted { $0.rankScore > $1.rankScore }
        } else {
            // WORKING day = trade it away: swaps handing off THIS shift.
            if let shift = ShiftStore.shared.shifts.first(where: { $0.id == target.dayID }), !shift.isOff {
                let pkgs = await TradeRouter.packages(forGiveShifts: [shift], excluding: me)
                packages = pkgs.filter { $0.usesCompactCard }.sorted { $0.rankScore > $1.rankScore }
            } else { packages = [] }
        }
        // Resolve shift-type + desk-qual for every peer's worked days (off-day pickup AND trade-away returns)
        // so the Shift / Qual chips filter both day types. Keyed "peerID|dayID" from the peer's roster.
        var dt: [String: ShiftAvailabilityType] = [:]; var dq: [String: String] = [:]
        for wid in Set(packages.flatMap { $0.assignments.map(\.workerID) }) {
            for e in await RosterStore.shared.schedule(forWorker: wid) where !e.isOff {
                dt["\(wid)|\(e.day)"] = .infer(fromStartHour: e.startHour)
                if let q = DeskRules.requiredQual(forDesk: e.desk) { dq["\(wid)|\(e.day)"] = q }
            }
        }
        dayType = dt; dayQual = dq
        loadedSig = loadSignature   // stamp the cache key so re-activation reuses this result
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
