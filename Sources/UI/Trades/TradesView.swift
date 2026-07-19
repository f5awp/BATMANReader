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

    @State private var segment = 1    // 0 Find Trades · 1 Dispatcher — Dispatcher is the default (leftmost)
    @State private var findMode = 0   // within Find Trades: 0 Date range (default) · 1 Complex Search · 2 ECB
    @State private var whatIf = false
    @State private var loading = true   // spinner on first entry so the tab never looks frozen

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // "Find Trades" merges the old Intents + Trade Solutions + ECB (same engine / one-way points
                // finder, chosen by mode). "Dispatcher" is its own tab — look up one person's swaps.
                DXSegmented(selection: $segment, options: [
                    .init(1, "Dispatcher"),
                    .init(0, "Find Trades", badge: feedCache.intentMatchCount),
                ], color: { _ in AppColor.primary })
                    .padding(.horizontal).padding(.top, 6).padding(.bottom, 8)   // cushion below the top bar

                if segment == 0 {
                    Picker("Find mode", selection: $findMode) {
                        Text("Complex Intents").tag(2)   // leftmost
                        Text("Date Range").tag(0)        // default selection
                        Text("ECB").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.bottom, 6)
                    if findMode == 2 { IntentTallyBar(centered: true) }   // per-intent counts, complex mode only
                }

                Divider()

                if segment == 1 {
                    DispatcherLookupView()
                } else if findMode == 0 {
                    FindCandidatesSection(whatIf: $whatIf) { loading = false }   // drop spinner when cold load settles
                } else if findMode == 1 {
                    ECBTradesView()   // one-way points finder
                } else {
                    TradeByIntentsFeed(whatIf: $whatIf, complexOnly: true)   // 3+ / N-way / qual-swap solutions
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

// MARK: - Dispatcher tab

/// The full dispatcher directory. Tapping a name EXPANDS the row in place (no navigation) into a card
/// with Employee #, Seniority #, phone, email, quals, position & committees, and dispatch/company start
/// dates. Search + sort (A–Z / Seniority) + qual & committee filters live at the top; the PAFCA board is
/// always pinned to the top with their titles shown.
struct DispatcherLookupView: View {
    @State private var dispatchers: [(id: String, name: String)] = []
    @State private var qualsByID: [String: [String]] = [:]
    @State private var query = ""
    @State private var sortBySeniority = false   // false = A–Z, true = seniority order
    @State private var qualFilter: Set<String> = []
    @State private var committeeFilter: Set<String> = []
    @State private var expandedID: String?
    @State private var detailPackage: TradePackage?
    @State private var noSwap: String?
    @State private var cantTrade: String?   // proposing to a robot / not-yet-active dispatcher
    // ONE sheet binding for quals / committees / DM — stacking multiple `.sheet(isPresented:)` on the same
    // view made the filter chips unresponsive (SwiftUI honors only one). An enum item fixes that.
    @State private var activeSheet: DispatcherSheet?
    @State private var busy = false

    /// The sheets this view can present, driven by a single `.sheet(item:)`.
    private enum DispatcherSheet: Identifiable {
        case quals, committees, message(Conversation)
        var id: String {
            switch self {
            case .quals: return "quals"
            case .committees: return "committees"
            case .message(let c): return "msg-\(c.id)"
            }
        }
    }
    private var myID: String { SettingsManager.shared.username }

    /// The qual letters present across the roster — the qual filter's options (real desk-qual codes only).
    private var availableQuals: [String] {
        Set(qualsByID.values.flatMap { $0 }).filter(DispatcherDirectory.isQualCode).sorted()
    }

    /// Search + filters applied, then ordered by the chosen sort (A–Z or Seniority). No pinning.
    private var displayed: [(id: String, name: String)] {
        let base = dispatchers.filter { p in
            if !query.isEmpty,
               !p.name.localizedCaseInsensitiveContains(query),
               !p.id.localizedCaseInsensitiveContains(query) { return false }
            if !qualFilter.isEmpty, qualFilter.isDisjoint(with: qualsByID[p.id] ?? []) { return false }
            if !committeeFilter.isEmpty,
               !committeeFilter.contains(where: { DispatcherDirectory.inCategory(p.id, $0) }) { return false }
            return true
        }
        return sortBySeniority ? DispatcherDirectory.sortedBySeniority(base) : base.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            // TOP: name/ID search, sort selector, qual + committee filters.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(.secondary)
                    TextField("Search name or employee #", text: $query)
                        .textFieldStyle(.plain).autocorrectionDisabled().textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: Capsule())

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        sortChip
                        if !availableQuals.isEmpty { qualFilterChip }
                        committeeFilterChip
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 8)

            Divider()

            List {
                if dispatchers.isEmpty {
                    ContentUnavailableView("Loading roster…", systemImage: "person.2")
                } else if displayed.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(displayed, id: \.id) { p in
                        DispatcherRow(id: p.id, name: p.name, quals: qualsByID[p.id] ?? [],
                                      isMe: p.id == myID,
                                      expanded: expandedID == p.id,
                                      onToggle: { withAnimation(.snappy) { expandedID = expandedID == p.id ? nil : p.id } },
                                      onFindSwap: { Task { await lookUp(p.id, name: p.name) } },
                                      onMessage: { activeSheet = .message(DirectMessageStore.shared.conversation(withID: p.id, name: p.name)) })
                    }
                }
            }
            .listStyle(.plain)
        }
        .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task { await load() }
        .sheet(item: $activeSheet) { which in
            switch which {
            case .quals:
                MultiSelectSheet(title: "Desk quals",
                                 options: availableQuals.map { ($0, "\($0) — \(DispatcherDirectory.qualName($0))") },
                                 selected: $qualFilter, onApply: {})
            case .committees:
                MultiSelectSheet(title: "Position & Committee",
                                 options: DispatcherDirectory.filterCategories.map { ($0, $0) },
                                 selected: $committeeFilter, onApply: {})
            case .message(let conv):
                NavigationStack { ConversationView(conversation: conv) }
                    .presentationDetents([.large])
            }
        }
        .fullScreenCover(item: $detailPackage) { pkg in
            PackageDetailView(package: pkg, onPropose: { p in Task { await propose(p) } }, onExecute: {})
        }
        .alert("No swap with \(noSwap ?? "")", isPresented: Binding(
            get: { noSwap != nil }, set: { if !$0 { noSwap = nil } })) {
            Button("OK", role: .cancel) { noSwap = nil }
        } message: { Text("No feasible day-for-day swap with them across your upcoming shifts.") }
        .alert("Can't trade with \(cantTrade ?? "") right now", isPresented: Binding(
            get: { cantTrade != nil }, set: { if !$0 { cantTrade = nil } })) {
            Button("OK", role: .cancel) { cantTrade = nil }
        } message: { Text("They're not on the app yet, so they can't receive a trade. You'll be able to once they join.") }
    }

    private var sortChip: some View {
        Menu {
            Button { sortBySeniority = false } label: { filterRow("A–Z", on: !sortBySeniority) }
            Button { sortBySeniority = true } label: { filterRow("Seniority", on: sortBySeniority) }
        } label: {
            filterChipLabel(sortBySeniority ? "Seniority" : "A–Z", systemImage: "arrow.up.arrow.down", active: false)
        }.buttonStyle(.plain)
    }

    private var qualFilterChip: some View {
        Button { activeSheet = .quals } label: {
            filterChipLabel(qualFilter.isEmpty ? "Quals" : qualFilter.sorted().joined(separator: "/"),
                            systemImage: "checkmark.seal", active: !qualFilter.isEmpty)
        }.buttonStyle(.plain)
    }

    private var committeeFilterChip: some View {
        Button { activeSheet = .committees } label: {
            filterChipLabel(committeeFilter.isEmpty ? "Committees" : "\(committeeFilter.count) selected",
                            systemImage: "person.3", active: !committeeFilter.isEmpty)
        }.buttonStyle(.plain)
    }

    /// Borderless filter chip (matches the Find Trades bar).
    private func filterChipLabel(_ text: String, systemImage: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.5)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .foregroundStyle(active ? AppColor.primary : .primary)
        .background(active ? AppColor.primary.opacity(0.16) : Color(.secondarySystemBackground), in: Capsule())
    }

    @ViewBuilder private func filterRow(_ title: String, on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func load() async {
        // Fast path: reuse the session cache so the tab opens instantly (no year-of-roster re-fetch).
        // Require BOTH caches — a launch-warmed dispatcher list with no quals must still fetch once.
        if !TradeFeedCache.shared.allDispatchers.isEmpty, !TradeFeedCache.shared.allDispatcherQuals.isEmpty {
            dispatchers = TradeFeedCache.shared.allDispatchers
            qualsByID = TradeFeedCache.shared.allDispatcherQuals
            return
        }
        let now = Date(); let end = Calendar.current.date(byAdding: .month, value: 12, to: now) ?? now
        let entries = await RosterStore.shared.entries(from: now, to: end)
        let me = myID
        let result = await Task.detached(priority: .userInitiated) {
            var seen = Set<String>(); var out: [(id: String, name: String)] = []
            var quals: [String: [String]] = [:]
            for e in entries {   // include self — shown with a "Me" badge (seniority # stays correct)
                _ = me
                if quals[e.workerID] == nil, !e.quals.isEmpty { quals[e.workerID] = e.quals }
                if seen.insert(e.workerID).inserted {
                    out.append((e.workerID, TradeNames.resolved(displayName: nil, rosterName: e.workerName, workerID: e.workerID)))
                }
            }
            return (out.sorted { $0.name < $1.name }, quals)
        }.value
        dispatchers = result.0
        qualsByID = result.1
        TradeFeedCache.shared.allDispatchers = result.0
        TradeFeedCache.shared.allDispatcherQuals = result.1
    }

    private func lookUp(_ id: String, name: String) async {
        busy = true
        let today = Calendar.current.startOfDay(for: Date())
        let mine = ShiftStore.shared.shifts.filter { !$0.isOff && $0.date >= today }
        // Per-peer two-way explorer (no global floor) → up to 10 ranked give-back dates in the detail view.
        let pkg = await TradeRouter.swapPackage(withWorker: id, name: name, forGiveShifts: mine, excluding: myID)
        busy = false
        if let pkg { detailPackage = pkg } else { noSwap = name }
    }

    private func propose(_ pkg: TradePackage) async {
        // Robots / not-yet-active dispatchers can't receive a trade — show a clear message instead of a
        // silent no-op (MessagingStore drops non-active recipients).
        let offline = pkg.assignments.filter { !participantHasProfile($0.workerID) }
        guard offline.isEmpty else {
            cantTrade = offline.map(\.name).joined(separator: ", ")
            detailPackage = nil
            return
        }
        for a in pkg.assignments {
            await MessagingStore.shared.sendRequest(to: a.workerID, toName: a.name,
                note: "Swap proposed from Dispatcher Lookup.", take: a.takeDayIDs, give: a.giveDayIDs, origin: .search)
        }
        WidgetData.update(); detailPackage = nil
    }
}

// MARK: - Dispatcher row (collapsed header + expandable detail card)

private struct DispatcherRow: View {
    let id: String
    let name: String
    let quals: [String]
    var isMe: Bool = false
    let expanded: Bool
    let onToggle: () -> Void
    let onFindSwap: () -> Void
    var onMessage: () -> Void = {}
    @Environment(\.openURL) private var openURL
    /// Seniority number size: caption (~12pt) + 3, scaled per device / Dynamic Type. The 32pt avatar
    /// drives the row height, so this larger badge doesn't grow the row.
    @ScaledMetric(relativeTo: .caption) private var seniorityFont: CGFloat = 15

    private var seniority: Int? { DispatcherDirectory.rank(forWorkerID: id) }
    /// Avatar color grouped by dispatch-start date — same class-date → same color, rotating the wheel down
    /// the list (repeats across the roster are fine). nil ⇒ default per-id color.
    private var avatarColor: Color? {
        guard let g = DispatcherDirectory.dispatchStartGroup(forWorkerID: id) else { return nil }
        return Color(hue: Double(g % 12) / 12.0, saturation: 0.62, brightness: 0.72)
    }
    private var entry: DirectoryEntry? { DispatcherDirectory.entry(forWorkerID: id) }
    private var role: String? { DispatcherDirectory.role(forWorkerID: id) }
    /// The person's own published profile (if any) — overrides the static directory for phone/email.
    private var profile: TradeProfile? { TradeProfileStore.shared.profile(forWorker: id) }
    /// Effective phone: their profile edit wins, then the directory; nil ⇒ show "N/A".
    private var resolvedPhone: String? {
        [profile?.phone, entry?.phone].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    /// Effective email: their profile edit wins, then the directory; nil ⇒ show "N/A".
    private var resolvedEmail: String? {
        [profile?.bestEmail, entry?.email].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private var committees: [String] { DispatcherDirectory.committees(forWorkerID: id) }
    private var isBoard: Bool { DispatcherDirectory.boardRole[id] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Avatar(name: name, id: id, size: 32, color: isMe ? AppColor.primary : avatarColor)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(name + (isMe ? "" : botSuffix(id))).font(.dsCardTitle)   // 🤖 = not on the app
                            if isMe {
                                Text("Me").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(AppColor.primary, in: Capsule())
                            }
                        }
                        if !isMe, let role { roleBadge(role) }   // board title / Shop Steward, shown while collapsed
                    }
                    Spacer()
                    seniorityBadge
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded { detail.padding(.top, 10) }
        }
        .padding(.vertical, 2)
    }

    private var seniorityBadge: some View {
        Group {
            if let s = seniority {
                Text("#\(s)").font(.system(size: seniorityFont, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(AppColor.primary)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(AppColor.primary.opacity(0.12), in: Capsule())
            } else {
                Text("—").font(.system(size: seniorityFont)).foregroundStyle(.tertiary)
            }
        }
        .fixedSize()   // never truncate the number
    }

    private func roleBadge(_ role: String) -> some View {
        // Board titles = blue plate; Shop Steward = red plate; anything else = amber.
        let bg: Color = isBoard ? AppColor.primary : (role == "Shop Steward" ? AppColor.danger : AppColor.pending)
        return Text(role).font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(bg, in: Capsule())
    }

    /// PAFCA position (board title / Shop Steward) + committee memberships, shown at the top of the card.
    @ViewBuilder private var positionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Position & Committee").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                if let role { roleBadge(role) }
                ForEach(committees, id: \.self) { c in
                    Text("\(c) Member").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Their broadcast status, up top (the 🤖 not-on-app indicator sits by the name in the header).
            if let status = participantStatus(id) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "quote.bubble").font(.caption2).foregroundStyle(AppColor.primary)
                    Text(status).font(.subheadline).italic().foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
            }
            // PAFCA position + committees, at the top of the card.
            if role != nil || !committees.isEmpty {
                positionSection
                Divider()
            }
            infoRow("Employee #", id)
            infoRow("Seniority #", seniority.map { "#\($0)" } ?? "Not listed")
            if let p = resolvedPhone {
                infoLink("Phone", p, url: "sms:\(p.filter(\.isNumber))", icon: "message.fill")   // opens Messages
            } else {
                infoRow("Phone", "N/A")
            }
            if let em = resolvedEmail {
                infoLink("Email", em, url: "mailto:\(em)", icon: "envelope.fill")   // opens a new mail draft
            } else {
                infoRow("Email", "N/A")
            }
            if let e = entry {
                infoRow("Dispatch Start", e.dispatchStart)
                infoRow("Company Start", e.companyStart)
            }
            let realQuals = quals.filter(DispatcherDirectory.isQualCode)
            if !realQuals.isEmpty { chipsRow("Quals", realQuals.map { "\($0) · \(DispatcherDirectory.qualName($0))" }) }

            HStack(spacing: 8) {
                Button(action: onFindSwap) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.left.arrow.right")
                        Text(isMe ? "That's you" : "Find Trades")
                    }
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(isMe ? AppColor.neutral : AppColor.primary)
                .disabled(isMe)
                if !isMe {
                    Button(action: onMessage) {
                        HStack(spacing: 5) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                            Text("Message")
                        }
                        .font(.caption.weight(.semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(AppColor.primary)
                    .disabled(!participantHasProfile(id))   // can't DM someone not on the app
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
            Text(value).font(.subheadline).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// A clearly-tappable contact link. Uses a BORDERLESS button (not `Link`) so only this element responds
    /// to taps — a bare `Link` in a List row makes the whole row open it.
    private func infoLink(_ label: String, _ value: String, url: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
            if let u = URL(string: url) {
                Button { openURL(u) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: icon).font(.caption2)
                        Text(value).underline()
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(AppColor.primary)
                }
                .buttonStyle(.borderless)
            } else {
                Text(value).font(.subheadline)
            }
            Spacer(minLength: 0)
        }
    }

    private func chipsRow(_ label: String, _ items: [String]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { t in
                    Text(t).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
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
