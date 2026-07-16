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

    var body: some View {
        TabView {
            DayTradeListPane(target: target)
                .tabItem { Label("Trade List", systemImage: "arrow.left.arrow.right") }
            DayIntentEditor(target: target)
                .tabItem { Label("Info", systemImage: "info.circle") }
        }
    }
}

/// Section A + B for one date, computed on appear via `TradeRouter.dayTradeList`, plus the Watch Day
/// toggle. Read-only in v1 — proposing from a row is Stage 9.
struct DayTradeListPane: View {
    let target: DayEditTarget

    @Environment(\.dismiss) private var dismiss
    private let radar = MatchStore.shared

    @State private var pickups: [TradeRouter.DayTradeRow] = []
    @State private var wantToWork: [TradeRouter.DayTradeRow] = []
    @State private var loading = true

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
                    Text("Get notified the moment a new match appears for this day.")
                }

                if loading {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                } else {
                    Section {
                        if pickups.isEmpty {
                            Text("No shifts you can legally pick up today.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(pickups) { DayTradeRowView(row: $0, showsShift: true) }
                        }
                    } header: {
                        Label("Shifts you can pick up", systemImage: "tray.and.arrow.down")
                    }

                    Section {
                        if wantToWork.isEmpty {
                            Text("Nobody has marked wanting to work this day.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(wantToWork) { DayTradeRowView(row: $0, showsShift: false) }
                        }
                    } header: {
                        Label("Wants to work this day", systemImage: "hand.raised")
                    } footer: {
                        if let t = radar.lastRefreshed {
                            Text("Radar updated \(t.formatted(.relative(presentation: .named)))")
                        }
                    }
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
            .task(id: target.dayID) { await reload(fullRadar: false) }
        }
    }

    /// Recompute this day's lists. `fullRadar` also refreshes the whole calendar star/matches (the manual
    /// refresh button); the initial appear only needs this day's rows.
    private func reload(fullRadar: Bool) async {
        loading = true
        if fullRadar { await radar.recompute() }
        let (p, w) = await TradeRouter.dayTradeList(dayID: target.dayID,
                                                    excluding: SettingsManager.shared.username)
        pickups = p; wantToWork = w; loading = false
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
