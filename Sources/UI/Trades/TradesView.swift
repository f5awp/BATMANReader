// TradesView.swift
// v2 Trades tab — global status dashboard (🟢🟡🔴💬) + a segmented feed:
//   [ Trade by Intents ]  → TradeRouter.tieredSolutions in 4 tier accordions
//   [ Trade Search ]      → the existing FindCandidatesSection (date-range query)
// Reuses TwoWaySheet, PlanCandidate, MessagingStore, TradeHistoryStore.

import SwiftUI

struct TradesView: View {

    private var messaging = MessagingStore.shared
    private var intents   = DayIntentStore.shared
    private var feedCache = TradeFeedCache.shared

    @State private var segment = 1   // default to Trade Search (middle). S-UIUX U-TRADES-1
    @State private var whatIf = false
    @State private var loading = true   // spinner on first entry so the tab never looks frozen

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The trade-status counters now live in the shared top bar (AppTopBar) on every tab.
                // Badge = number of MUTUAL intent matches (not your raw intent count).
                DXSegmented(selection: $segment, options: [
                    .init(0, feedCache.intentMatchCount > 0 ? "Intents (\(feedCache.intentMatchCount))" : "Intents"),
                    .init(1, "Trade Solutions"),
                    .init(2, "ECB"),
                ], color: { v in [0: AppColor.heat, 1: AppColor.primary, 2: AppColor.success][v] })
                    .padding(.horizontal).padding(.top, 6).padding(.bottom, 8)   // cushion below the top bar

                if segment == 0 {
                    IntentTallyBar(centered: true)   // color-coded per-intent counts — Intents tab only (D2a)
                }

                Divider()

                switch segment {
                case 0: TradeByIntentsFeed(whatIf: $whatIf)
                case 1: FindCandidatesSection(whatIf: $whatIf) { loading = false }   // drop spinner when cold load settles
                default: ECBTradesView()
                }
            }
            .loadingOverlay(loading, label: "Loading trades…")
            .navigationTitle("Trades")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)   // the shared AppTopBar is the header now
            .task {
                await messaging.refresh()
                // Safety net: if the landing segment isn't the one that reports readiness, still
                // drop the spinner after the first frame so it can never get stuck on.
                await Task.yield()
                if segment != 1 { loading = false }
            }
        }
    }
}

// MARK: - Trades segment bar (custom — so the Intents count can be a CIRCLED badge, #3)

/// 4-way selector. The Intents segment shows its matching-factor count in an orange **circle** so
/// it reads clearly as a count (vs "Just 2" where the 2 is part of the name).
struct TradesSegmentBar: View {
    @Binding var segment: Int
    let intentCount: Int
    private let titles = ["Intents", "Trade Solutions", "ECB"]

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
                                .background(Circle().fill(AppColor.heat))
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
    var centered: Bool = false
    private var intents = DayIntentStore.shared

    init(centered: Bool = false) { self.centered = centered }

    var body: some View {
        let wc = intents.workingIntentCounts
        let oc = intents.offIntentCounts
        // All four marked intents, color-matched to the calendar legend: the two MATCHING factors
        // (Want to Trade / Want to Work) plus the two PROTECTIVE ones (Keep working shift = green;
        // Blackout off day = slate). Zero-count categories drop out.
        // §6: same quiet dot-led style as the month header — lowercase labels, small squared colored dots.
        let items: [(label: String, color: Color, count: Int)] = [
            ("trade",    WorkingIntentState.dontWantToWork.brickColor, wc[.dontWantToWork] ?? 0),
            ("work",     OffIntentState.wantToWork.brickColor,         oc[.wantToWork] ?? 0),
            ("keep",     WorkingIntentState.mustWork.brickColor,       wc[.mustWork] ?? 0),
            ("blackout", OffIntentState.mustBeOff.brickColor,          oc[.mustBeOff] ?? 0),
        ].filter { $0.count > 0 }
        if !items.isEmpty {
            HStack(spacing: 10) {
                ForEach(items, id: \.label) { it in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(it.color).frame(width: 8, height: 8)
                        Text("\(it.count) \(it.label)")
                    }
                }
                if !centered { Spacer() }   // left-aligned by default; centered when requested
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .padding(.horizontal).padding(.bottom, 4)
        }
    }
}

// MARK: - Dashboard sheet (4 zones)

struct TradeDashboardSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DXPaletteStripe(height: 4).padding(.horizontal).padding(.top, 8)
                // Trade History = DONE only (schedule-proven / official). Active trades — pending,
                // negotiating, or accepted-but-not-yet-reflected — live in the Trade Inbox instead.
                HistoryZone()
                Spacer(minLength: 0)
            }
            .navigationTitle("Trade History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DXCloseButton { dismiss() } } }
            // Pull the latest trade state + your cross-device history when the board opens (and on pull).
            .task { await MessagingStore.shared.refresh(); await TradeHistoryStore.shared.syncOnLaunch() }
            .refreshable { await MessagingStore.shared.refresh(); await TradeHistoryStore.shared.syncOnLaunch() }
        }
    }
}

// MARK: - Zones

private struct AcceptedZone: View {
    private var messaging = MessagingStore.shared
    private var history   = TradeHistoryStore.shared
    private var myID: String { SettingsManager.shared.username }

    private var accepted: [TradeRequest] {
        messaging.requests.filter { messaging.status(of: $0) == .accepted }
    }

    var body: some View {
        if accepted.isEmpty {
            ZoneEmpty("No accepted trades", "Agreed trades waiting to be entered on the official board show here.")
        } else {
            List(accepted) { req in
                VStack(alignment: .leading, spacing: 8) {
                    RequestRow(request: req, myID: myID)
                    Button {
                        Task { await confirmOfficial(req) }
                    } label: {
                        Label("Done: Confirmed on Official Board", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(AppColor.success).controlSize(.small)
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
    private var myID: String { SettingsManager.shared.username }
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
            List(pending) { RequestRow(request: $0, myID: myID) }.listStyle(.plain)
        }
    }
}

private struct DeniedZone: View {
    private var messaging = MessagingStore.shared
    private var myID: String { SettingsManager.shared.username }
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
            List(denied) { RequestRow(request: $0, myID: myID).opacity(0.7) }.listStyle(.plain)
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
                                .foregroundStyle(AppColor.pending)
                        } else {
                            Text("DONE").font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(BrickPalette.clear.opacity(0.22), in: Capsule())
                                .foregroundStyle(AppColor.success)
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
