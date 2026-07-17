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

    @State private var segment = 0    // 0 Find Trades · 1 ECB
    @State private var findMode = 0   // within Find Trades: 0 Search a date range (default) · 1 From my marked days
    @State private var whatIf = false
    @State private var loading = true   // spinner on first entry so the tab never looks frozen

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // "Find Trades" merges the old Intents + Trade Solutions (same engine, different input). ECB
                // is the one-way points finder. Multi-person loops / N-way / qual-swaps live under Find Trades.
                DXSegmented(selection: $segment, options: [
                    .init(0, "Find Trades", badge: feedCache.intentMatchCount),
                    .init(1, "ECB"),
                ], color: { v in [0: AppColor.primary, 1: AppColor.success][v] })
                    .padding(.horizontal).padding(.top, 6).padding(.bottom, 8)   // cushion below the top bar

                if segment == 0 {
                    Picker("Find mode", selection: $findMode) {
                        Text("Date range").tag(0)
                        Text("Complex Search").tag(1)
                        Text("Dispatcher").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.bottom, 6)
                    if findMode == 1 { IntentTallyBar(centered: true) }   // per-intent counts, complex mode only
                }

                Divider()

                if segment == 1 {
                    ECBTradesView()
                } else if findMode == 0 {
                    FindCandidatesSection(whatIf: $whatIf) { loading = false }   // drop spinner when cold load settles
                } else if findMode == 1 {
                    TradeByIntentsFeed(whatIf: $whatIf, complexOnly: true)   // 3+ / N-way / qual-swap solutions
                } else {
                    DispatcherLookupView()
                }
            }
            .loadingOverlay(loading, label: "Loading trades…")
            .navigationTitle("Trades")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)   // the shared AppTopBar is the header now
            .task {
                await messaging.refresh()
                // Safety net: only the date-range search reports readiness; drop the spinner otherwise.
                await Task.yield()
                if !(segment == 0 && findMode == 0) { loading = false }
            }
            // Switching INTO the search mode re-arms the spinner until FindCandidatesSection reports ready.
            .onChange(of: findMode) { _, m in loading = (segment == 0 && m == 0) }
            .onChange(of: segment) { _, s in if s != 0 || findMode != 0 { loading = false } }
        }
    }
}

// MARK: - Dispatcher Lookup (Find Trades mode)

/// Search the roster and open any dispatcher's best day-for-day swap in the Trade-Solutions calendar view.
struct DispatcherLookupView: View {
    @State private var dispatchers: [(id: String, name: String)] = []
    @State private var query = ""
    @State private var detailPackage: TradePackage?
    @State private var noSwap: String?
    @State private var busy = false
    private var myID: String { SettingsManager.shared.username }

    private var filtered: [(id: String, name: String)] {
        query.isEmpty ? dispatchers : dispatchers.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if dispatchers.isEmpty {
                ContentUnavailableView("Loading roster…", systemImage: "person.2")
            } else {
                ForEach(filtered, id: \.id) { p in
                    Button { Task { await lookUp(p.id, name: p.name) } } label: {
                        HStack(spacing: 10) {
                            Avatar(name: p.name, id: p.id, size: 30)
                            Text(p.name).font(.dsCardTitle)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $query, prompt: "Find a dispatcher")
        .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task { await load() }
        .fullScreenCover(item: $detailPackage) { pkg in
            PackageDetailView(package: pkg, onPropose: { p in Task { await propose(p) } }, onExecute: {})
        }
        .alert("No swap with \(noSwap ?? "")", isPresented: Binding(
            get: { noSwap != nil }, set: { if !$0 { noSwap = nil } })) {
            Button("OK", role: .cancel) { noSwap = nil }
        } message: { Text("No feasible day-for-day swap with them across your upcoming shifts.") }
    }

    private func load() async {
        if !TradeFeedCache.shared.allDispatchers.isEmpty { dispatchers = TradeFeedCache.shared.allDispatchers; return }
        let now = Date(); let end = Calendar.current.date(byAdding: .month, value: 12, to: now) ?? now
        let entries = await RosterStore.shared.entries(from: now, to: end)
        let me = myID
        let out = await Task.detached(priority: .userInitiated) {
            var seen = Set<String>(); var out: [(id: String, name: String)] = []
            for e in entries where e.workerID != me && seen.insert(e.workerID).inserted {
                out.append((e.workerID, TradeNames.resolved(displayName: nil, rosterName: e.workerName, workerID: e.workerID)))
            }
            return out.sorted { $0.name < $1.name }
        }.value
        dispatchers = out
        TradeFeedCache.shared.allDispatchers = out
    }

    private func lookUp(_ id: String, name: String) async {
        busy = true
        let today = Calendar.current.startOfDay(for: Date())
        let mine = ShiftStore.shared.shifts.filter { !$0.isOff && $0.date >= today }
        let pkgs = await TradeRouter.packages(forGiveShifts: mine, excluding: myID)
        busy = false
        if let best = pkgs.first(where: { $0.usesCompactCard && $0.assignments.first?.workerID == id }) { detailPackage = best }
        else { noSwap = name }
    }

    private func propose(_ pkg: TradePackage) async {
        for a in pkg.assignments {
            await MessagingStore.shared.sendRequest(to: a.workerID, toName: a.name,
                note: "Swap proposed from Dispatcher Lookup.", take: a.takeDayIDs, give: a.giveDayIDs, origin: .search)
        }
        WidgetData.update(); detailPackage = nil
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
