// TradesView.swift
// v2 Trades tab — global status dashboard (🟢🟡🔴💬) + a segmented feed:
//   [ Trade by Intents ]  → TradeRouter.tieredSolutions in 4 tier accordions
//   [ Trade Search ]      → the existing FindCandidatesSection (date-range query)
// Reuses TwoWaySheet, PlanCandidate, MessagingStore, TradeHistoryStore.

import SwiftUI

struct TradesView: View {

    private var messaging = MessagingStore.shared
    private var history   = TradeHistoryStore.shared
    private var intents   = DayIntentStore.shared

    @State private var segment = 1   // default to Trade Search (middle). S-UIUX U-TRADES-1
    @State private var showDashboard = false
    @State private var whatIf = false
    @State private var showTradeSettings = false
    @State private var showAppSettings = false

    private var counts: DashboardCounts {
        DashboardCounts.from(requests: messaging.requests,
                             responses: messaging.responses,
                             unread: messaging.pendingIncoming.count,
                             pendingLedger: history.pendingCount)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusHeaderBar()
                StatusAnchorButton(counts: counts) { showDashboard = true }
                    .padding(.horizontal).padding(.vertical, 8)

                TradesSegmentBar(segment: $segment, intentCount: intents.tradeIntentCount)
                    .padding(.horizontal).padding(.bottom, 8)

                IntentTallyBar()   // color-coded per-intent counts (D2a)

                Divider()

                switch segment {
                case 0: TradeByIntentsFeed(whatIf: $whatIf)
                case 1: FindCandidatesSection(whatIf: $whatIf)
                case 2: JustTwoSection()
                default: ECBTradesView()
                }
            }
            .navigationTitle("Trades")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showTradeSettings = true } label: { Label("Trade Settings", systemImage: "arrow.left.arrow.right") }
                        Button { showAppSettings = true } label: { Label("App Settings", systemImage: "gearshape") }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showDashboard) { TradeDashboardSheet() }
            .sheet(isPresented: $showTradeSettings) { TradeSettingsSheet() }
            .sheet(isPresented: $showAppSettings) { SettingsView() }
            .task { await messaging.refresh() }
        }
    }
}

// MARK: - Status anchor button (the four live counters)

struct StatusAnchorButton: View {
    let counts: DashboardCounts
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                badge(counts.accepted, BrickPalette.clear, "checkmark.seal.fill", "Accepted")
                badge(counts.pending, BrickPalette.caution, "clock.fill", "Pending")
                badge(counts.denied, BrickPalette.critical, "xmark.octagon.fill", "Denied")
                badge(counts.unread, BrickPalette.info, "bubble.left.fill", "Unread")
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))
        }
        .buttonStyle(.plain)
    }

    private func badge(_ n: Int, _ tint: Color, _ symbol: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            Text("\(n)").font(.headline.monospacedDigit())
                .foregroundStyle(n > 0 ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(n)")
    }
}

// MARK: - Trades segment bar (custom — so the Intents count can be a CIRCLED badge, #3)

/// 4-way selector. The Intents segment shows its matching-factor count in an orange **circle** so
/// it reads clearly as a count (vs "Just 2" where the 2 is part of the name).
struct TradesSegmentBar: View {
    @Binding var segment: Int
    let intentCount: Int
    private let titles = ["Intents", "Trade Solutions", "Just 2", "ECB"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(titles.indices, id: \.self) { i in
                Button { segment = i } label: {
                    HStack(spacing: 5) {
                        Text(titles[i])
                            .font(.subheadline.weight(segment == i ? .semibold : .regular))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        if i == 0 && intentCount > 0 {
                            Text("\(intentCount)")
                                .font(.caption2.bold()).monospacedDigit().foregroundStyle(.white)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Circle().fill(.orange))
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(segment == i ? Color(.secondarySystemFill) : .clear, in: Capsule())
                    .contentShape(Capsule())
                    .foregroundStyle(segment == i ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.bar, in: Capsule())
    }
}

// MARK: - Intent tally bar (the two MATCHING factors — Want-to-Trade + Want-to-Work, #3)

/// A thin row of color-coded count chips — one per active intent category — so you can
/// see your marked intents at a glance. Counts come from `DayIntentStore` (pure).
struct IntentTallyBar: View {
    private var intents = DayIntentStore.shared
    var body: some View {
        let wc = intents.workingIntentCounts
        let oc = intents.offIntentCounts
        // Only the two MATCHING factors (#3) — protective intents (Keep / Must-Be-Off) aren't shown here.
        let items: [(label: String, color: Color, count: Int)] = [
            ("Want to Trade", WorkingIntentState.dontWantToWork.brickColor, wc[.dontWantToWork] ?? 0),
            ("Want to Work",  OffIntentState.wantToWork.brickColor,         oc[.wantToWork] ?? 0),
        ].filter { $0.count > 0 }
        if !items.isEmpty {
            HStack(spacing: 10) {
                ForEach(items, id: \.label) { it in
                    HStack(spacing: 4) {
                        Circle().fill(it.color).frame(width: 7, height: 7)
                        Text("\(it.count)").font(.caption2.weight(.bold)).monospacedDigit()
                        Text(it.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal).padding(.bottom, 4)
        }
    }
}

// MARK: - Dashboard sheet (4 zones)

struct TradeDashboardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Accepted").tag(0)
                    Text("Pending").tag(1)
                    Text("Denied").tag(2)
                    Text("History").tag(3)
                }
                .pickerStyle(.segmented).padding()

                switch tab {
                case 0: AcceptedZone()
                case 1: PendingZone()
                case 2: DeniedZone()
                default: HistoryZone()
                }
                Spacer(minLength: 0)
            }
            .navigationTitle("Trade Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Zones

private struct AcceptedZone: View {
    private var messaging = MessagingStore.shared
    private var history   = TradeHistoryStore.shared

    private var accepted: [TradeRequest] {
        messaging.requests.filter { messaging.status(of: $0) == .accepted }
    }

    var body: some View {
        if accepted.isEmpty {
            ZoneEmpty("No accepted trades", "Agreed trades waiting to be entered on the official board show here.")
        } else {
            List(accepted) { req in
                VStack(alignment: .leading, spacing: 8) {
                    TradeRequestSummary(req: req)
                    Button {
                        Task { await confirmOfficial(req) }
                    } label: {
                        Label("Done: Confirmed on Official Board", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
        }
    }

    private func confirmOfficial(_ req: TradeRequest) async {
        let entry = TradeHistoryEntry(
            summary: tradeSummary(req),
            participants: [req.fromName, req.toName],
            dayIDs: req.giveDayIDs + req.takeDayIDs,
            completedAt: Date())
        history.record(entry)
        await messaging.cancelRequest(req.id)   // clears it out of the active list
    }
}

private struct PendingZone: View {
    private var messaging = MessagingStore.shared
    private var pending: [TradeRequest] {
        messaging.requests.filter {
            let s = messaging.status(of: $0)
            return s == .pending || s == .countered
        }
    }
    var body: some View {
        if pending.isEmpty {
            ZoneEmpty("Nothing pending", "Outbound proposals and circular-trade confirmations awaiting a reply show here.")
        } else {
            List(pending) { TradeRequestSummary(req: $0) }.listStyle(.plain)
        }
    }
}

private struct DeniedZone: View {
    private var messaging = MessagingStore.shared
    private var denied: [TradeRequest] {
        messaging.requests.filter {
            let s = messaging.status(of: $0)
            return s == .declined || s == .cancelled
        }
    }
    var body: some View {
        if denied.isEmpty {
            ZoneEmpty("No denied trades", "Rejected or expired proposals show here so you know instantly.")
        } else {
            List(denied) { TradeRequestSummary(req: $0).opacity(0.7) }.listStyle(.plain)
        }
    }
}

private struct HistoryZone: View {
    private var history = TradeHistoryStore.shared
    var body: some View {
        if history.entries.isEmpty {
            ZoneEmpty("No history yet", "Settled trades — and pending ECB transfers — are recorded here.")
        } else {
            List(history.entries) { e in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(e.summary).font(.subheadline)
                        Spacer()
                        if e.pending {
                            Text("PENDING").font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(BrickPalette.caution.opacity(0.25), in: Capsule())
                                .foregroundStyle(.orange)
                        } else {
                            Text("DONE").font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(BrickPalette.clear.opacity(0.22), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                    Text("\(e.participants.joined(separator: " · ")) — \(e.completedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                    if e.pending {
                        Button { history.markComplete(id: e.id, at: Date()) } label: {
                            Label("Mark transfer complete", systemImage: "checkmark.seal.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Shared small views

private struct TradeRequestSummary: View {
    let req: TradeRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(req.fromName) ⇄ \(req.toName)").font(.subheadline.bold())
            if !req.note.isEmpty {
                Text(req.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !(req.giveDayIDs.isEmpty && req.takeDayIDs.isEmpty) {
                Text(tradeSummary(req)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ZoneEmpty: View {
    let title: String; let message: String
    init(_ title: String, _ message: String) { self.title = title; self.message = message }
    var body: some View {
        ContentUnavailableView(title, systemImage: "tray", description: Text(message))
    }
}

/// "I take 2; you take 1" style summary of the moved days.
func tradeSummary(_ req: TradeRequest) -> String {
    var parts: [String] = []
    if !req.takeDayIDs.isEmpty { parts.append("you take \(req.takeDayIDs.count)") }
    if !req.giveDayIDs.isEmpty { parts.append("they take \(req.giveDayIDs.count)") }
    return parts.isEmpty ? "—" : "Swap: " + parts.joined(separator: "; ")
}
