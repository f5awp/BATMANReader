// TradesView.swift
// v2 Trades tab — global status dashboard (🟢🟡🔴💬) + a segmented feed:
//   [ Trade by Intents ]  → TradeRouter.tieredSolutions in 4 tier accordions
//   [ Trade Search ]      → the existing FindCandidatesSection (date-range query)
// Reuses TwoWaySheet, PlanCandidate, MessagingStore, TradeHistoryStore.

import SwiftUI

struct TradesView: View {

    private var messaging = MessagingStore.shared
    private var history   = TradeHistoryStore.shared

    @State private var segment = 0
    @State private var showDashboard = false
    @State private var whatIf = false

    private var counts: DashboardCounts {
        DashboardCounts.from(requests: messaging.requests,
                             responses: messaging.responses,
                             unread: messaging.pendingIncoming.count)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusAnchorButton(counts: counts) { showDashboard = true }
                    .padding(.horizontal).padding(.vertical, 8)

                Picker("", selection: $segment) {
                    Text("Trade by Intents").tag(0)
                    Text("Trade Search").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.bottom, 8)

                Divider()

                if segment == 0 {
                    TradeByIntentsFeed(whatIf: $whatIf)
                } else {
                    FindCandidatesSection(whatIf: $whatIf)
                }
            }
            .navigationTitle("Trades")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showDashboard) { TradeDashboardSheet() }
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
            .background(.bar, in: RoundedRectangle(cornerRadius: 12))
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
            ZoneEmpty("No history yet", "Trades you mark official are archived here as a permanent ledger.")
        } else {
            List(history.entries) { e in
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.summary).font(.subheadline)
                    Text("\(e.participants.joined(separator: " · ")) — \(e.completedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
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
