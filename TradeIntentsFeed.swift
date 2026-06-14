// TradeIntentsFeed.swift
// The "Trade by Intents" feed (4 tier accordions from TradeRouter.tieredSolutions)
// plus the N-way chain card and the execution-confirmation checkout.

import SwiftUI

// MARK: - Feed

struct TradeByIntentsFeed: View {

    @Binding var whatIf: Bool

    @State private var tiers: [(tier: SolutionTier, routes: [NWayRoute])] = []
    @State private var loading = true
    @State private var twoWayCandidate: PlanCandidate?
    @State private var execRoute: NWayRoute?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if whatIf {
                    Label("What If? on — extended matches (toggle in Trade Search)",
                          systemImage: "wand.and.stars")
                        .font(.caption).foregroundStyle(.purple)
                        .padding(.horizontal).padding(.top, 8)
                }

                if loading {
                    ProgressView("Finding intent matches…")
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else if tiers.allSatisfy(\.routes.isEmpty) {
                    ContentUnavailableView("No Intent Matches",
                        systemImage: "sparkles",
                        description: Text("Mark days to trade away on Home, or try What If? mode to widen the search."))
                        .padding(.top, 40)
                } else {
                    ForEach(tiers, id: \.tier) { group in
                        if !group.routes.isEmpty {
                            DisclosureGroup {
                                ForEach(group.routes) { route in
                                    RouteCard(route: route,
                                              onOpenSwap: { openSwap(route) },
                                              onExecute: { execRoute = route })
                                        .padding(.vertical, 4)
                                }
                            } label: {
                                HStack {
                                    Text(group.tier.label).font(.headline)
                                    Spacer()
                                    Text("\(group.routes.count)")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .sheet(item: $twoWayCandidate) { TwoWaySheet(candidate: $0) }
        .sheet(item: $execRoute) { ExecutionConfirmationView(route: $0) }
        .task { await reload() }
        .onChange(of: whatIf) { _, _ in Task { await reload() } }
    }

    private func reload() async {
        loading = true
        await TradeProfileStore.shared.refreshOthers()
        tiers = await TradeRouter.tieredSolutions(isWhatIfModeActive: whatIf)
        loading = false
    }

    /// 2-participant routes reopen the rich two-way sheet (it re-explores by ID).
    private func openSwap(_ route: NWayRoute) {
        guard route.participants.count == 2 else { return }
        let peerID = route.participants[1]
        twoWayCandidate = PlanCandidate(workerID: peerID, name: participantName(peerID),
                                        quals: [], coveredShiftIDs: [], bookendShiftIDs: [], week: [])
    }
}

// MARK: - Route card (direct swap vs. circular chain)

struct RouteCard: View {
    let route: NWayRoute
    let onOpenSwap: () -> Void
    let onExecute: () -> Void

    @State private var miniDays: [MiniDay] = []

    private var peerID: String {
        route.participants.count == 2 ? route.participants[1] : route.participants[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if route.participants.count <= 2 {
                directSwap
            } else {
                chain
            }
        }
        .padding(12)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .task {
            // Direct 1-to-1 cards keep a mini-schedule of the peer's next 2 weeks.
            if route.participants.count <= 2 { miniDays = await Self.loadMini(workerID: peerID) }
        }
    }

    // Direct 1-to-1: name + status + a mini-schedule + open the two-way sheet.
    private var directSwap: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(participantName(peerID)).font(.subheadline.bold())
                    if let status = participantStatus(peerID) {
                        Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
            if !miniDays.isEmpty { miniSchedule }
        }
    }

    private var miniSchedule: some View {
        HStack(spacing: 3) {
            ForEach(miniDays) { d in
                VStack(spacing: 1) {
                    Text(d.weekday).font(.system(size: 8)).foregroundStyle(.secondary)
                    Text(d.letter.isEmpty ? "·" : d.letter)
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(d.letter.isEmpty ? Color.clear : Color.accentColor.opacity(0.18),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    /// The peer's next 14 days as weekday + shift letter.
    static func loadMini(workerID: String) async -> [MiniDay] {
        let letters = await TradeMatcher.dayLetters(forWorker: workerID)
        let cal = Calendar.current
        let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd"
        let wf = DateFormatter(); wf.dateFormat = "EEEEE"   // single-letter weekday
        let today = cal.startOfDay(for: Date())
        return (0..<14).compactMap { off in
            guard let d = cal.date(byAdding: .day, value: off, to: today) else { return nil }
            let key = iso.string(from: d)
            return MiniDay(id: key, weekday: wf.string(from: d), letter: letters[key] ?? "")
        }
    }

    // Circular: A ➔ B ➔ C with names + statuses, no mini-schedule.
    private var chain: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.indigo)
                Text("\(route.participants.count)-way trade").font(.subheadline.bold())
                Spacer()
                Button("Execute", action: onExecute)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            ForEach(Array(route.participants.enumerated()), id: \.offset) { idx, pid in
                HStack(spacing: 6) {
                    Image(systemName: idx == 0 ? "person.fill" : "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(participantName(pid)).font(.caption.weight(.semibold))
                        if let status = participantStatus(pid) {
                            Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

/// One day in a route card's mini-schedule strip.
struct MiniDay: Identifiable, Hashable {
    let id: String       // ISO day
    let weekday: String  // single-letter
    let letter: String   // shift letter or ""
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
