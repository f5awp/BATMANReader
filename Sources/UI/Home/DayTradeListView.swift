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

    var body: some View {
        TabView(selection: $tab) {
            // Info is the default (left); Trade List is second (right) — for both working and off days.
            DayIntentEditor(target: target)
                .tabItem { Label("Info", systemImage: "info.circle") }.tag(Tab.info)
            // Tab-gated: the Trade List only computes/loads once its tab is actually selected.
            DayTradeListPane(target: target, isActive: tab == .tradeList)
                .tabItem { Label("Trade List", systemImage: "arrow.left.arrow.right") }.tag(Tab.tradeList)
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
    @State private var loading = true
    @State private var selectedCandidate: PlanCandidate?   // tapped person → 2-way calendar

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
                    // OFF day → people looking to have this day off (shifts I could pick up).
                    Section {
                        if pickups.isEmpty {
                            emptyRow("Nobody working this day has marked it to trade away.")
                        } else {
                            ForEach(pickups) { personCard($0, showsShift: true) }
                        }
                    } header: {
                        Label("Shifts you can pick up", systemImage: "tray.and.arrow.down")
                    } footer: { radarStamp }
                } else {
                    // WORKING day → people looking to work this day (they'd take my shift).
                    Section {
                        if wantToWork.isEmpty {
                            emptyRow("Nobody has marked wanting to work this day.")
                        } else {
                            ForEach(wantToWork) { personCard($0, showsShift: false) }
                        }
                    } header: {
                        Label("Wants to work this day", systemImage: "hand.raised")
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
                            initialTake: target.isOff ? [target.dayID] : [])
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
        let r = radar.rows(forDay: target.dayID)
        pickups = r.pickups; wantToWork = r.wantToWork; loading = false
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
