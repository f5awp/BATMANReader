// MessagingViews.swift
// The in-app trade Inbox (1:1 requests + replies) and the Broadcast Channel
// (self-maintaining feed). Both presented as sheets from the side dock.

import SwiftUI

// MARK: - Formatting helpers

enum DayFmt {
    static let iso: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static let pretty: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f }()
    static func nice(_ isoDay: String) -> String {
        guard let d = iso.date(from: isoDay) else { return isoDay }
        return pretty.string(from: d)
    }
    static func list(_ ids: [String]) -> String {
        ids.sorted().map(nice).joined(separator: ", ")
    }
}

struct StatusBadge: View {
    let status: TradeRequestStatus
    var body: some View {
        Text(status.label)
            .font(.caption2.bold())
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
    private var color: Color {
        switch status {
        case .pending:   return .orange
        case .accepted:  return .green
        case .declined:  return .red
        case .countered: return .blue
        case .cancelled: return .gray
        case .message:   return .secondary
        }
    }
}

extension TradeRequestStatus {
    var icon: String {
        switch self {
        case .pending:   return "hourglass"
        case .accepted:  return "checkmark.circle.fill"
        case .declined:  return "xmark.circle.fill"
        case .countered: return "arrow.uturn.left.circle.fill"
        case .cancelled: return "slash.circle"
        case .message:   return "bubble.left.fill"
        }
    }
    var tint: Color {
        switch self {
        case .pending:   return .orange
        case .accepted:  return .green
        case .declined:  return .red
        case .countered: return .blue
        case .cancelled: return .gray
        case .message:   return .secondary
        }
    }
}

/// Renders message text as Markdown so **bold**, *italic*, and ~~strike~~ work.
func mdText(_ s: String) -> Text {
    if let a = try? AttributedString(markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        return Text(a)
    }
    return Text(s)
}

/// Wraps the whole draft in a Markdown marker (used by the format buttons).
func mdWrap(_ text: Binding<String>, _ marker: String) {
    let s = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return }
    text.wrappedValue = "\(marker)\(s)\(marker)"
}

/// Call / Text / Email buttons for a dispatcher, from their published profile.
struct ContactButtons: View {
    let profile: TradeProfile

    private var phoneDigits: String? {
        guard let p = profile.phone?.filter({ $0.isNumber || $0 == "+" }), !p.isEmpty else { return nil }
        return p
    }

    var body: some View {
        HStack(spacing: 18) {
            if let p = phoneDigits {
                contact("Call", "phone.fill", "tel:\(p)")
                contact("Text", "message.fill", "sms:\(p)")
            }
            if let e = profile.bestEmail {
                contact("Email", "envelope.fill", "mailto:\(e)")
            }
        }
        .font(.caption)
    }

    private func contact(_ title: String, _ icon: String, _ urlString: String) -> some View {
        Button {
            if let url = URL(string: urlString) { UIApplication.shared.open(url) }
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.borderless)
    }
}

/// B / I / S buttons that wrap the entire draft.
struct FormatBar: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 16) {
            Button { mdWrap($text, "**") } label: { Image(systemName: "bold") }
            Button { mdWrap($text, "*") }  label: { Image(systemName: "italic") }
            Button { mdWrap($text, "~~") } label: { Image(systemName: "strikethrough") }
        }
        .buttonStyle(.borderless).font(.subheadline).foregroundStyle(.secondary)
    }
}

// MARK: - Inbox

struct InboxView: View {
    private var store = MessagingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var filter = 0   // 0 = all, 1 = ECB only

    private var myID: String { SettingsManager.shared.username }

    /// Incoming one-way ECB offers, sorted by most ECB offered.
    private var ecbRequests: [TradeRequest] {
        store.requests.filter { $0.isECB }.sorted { ($0.ecb ?? 0) > ($1.ecb ?? 0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $filter) {
                    Text("All").tag(0)
                    Text("ECB (\(ecbRequests.count))").tag(1)
                }
                .pickerStyle(.segmented).padding()

                if store.requests.isEmpty {
                    ContentUnavailableView("No Trade Requests", systemImage: "tray",
                        description: Text("Swaps you propose or receive show up here."))
                } else if filter == 1 {
                    let incomingECB = store.incoming.filter { $0.isECB }.sorted { ($0.ecb ?? 0) > ($1.ecb ?? 0) }
                    if store.ecbOffers.isEmpty && incomingECB.isEmpty {
                        ContentUnavailableView("No ECB Offers", systemImage: "star.circle",
                            description: Text("One-way ECB trade offers show here, sorted by most ECB offered."))
                    } else {
                        List {
                            if !store.ecbOffers.isEmpty {
                                Section("Your ECB offers · first to accept each shift gets it") {
                                    ForEach(store.ecbOffers, id: \.offerID) { offer in
                                        NavigationLink { ECBOfferView(offerID: offer.offerID) } label: { ECBOfferRow(offer: offer) }
                                    }
                                }
                            }
                            if !incomingECB.isEmpty {
                                Section("Offers to you · highest ECB first") { ForEach(incomingECB) { row($0) } }
                            }
                        }
                    }
                } else {
                    List {
                        if !store.pendingIncoming.isEmpty {
                            Section("Needs your reply") {
                                ForEach(store.pendingIncoming) { row($0) }
                            }
                        }
                        let handledIncoming = store.incoming.filter { store.status(of: $0) != .pending }
                        if !handledIncoming.isEmpty {
                            Section("Incoming") { ForEach(handledIncoming) { row($0) } }
                        }
                        if !store.outgoing.isEmpty {
                            Section("Sent") { ForEach(store.outgoing) { row($0) } }
                        }
                    }
                }
            }
            .navigationTitle("Trade Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.refresh() }
            .refreshable { await store.refresh() }
        }
    }

    private func row(_ req: TradeRequest) -> some View {
        NavigationLink { ThreadView(request: req) } label: { RequestRow(request: req, myID: myID) }
    }
}

// MARK: - ECB offer (sender side: ordered acceptance queue)

struct ECBOfferRow: View {
    let offer: (offerID: String, requests: [TradeRequest])
    private var store = MessagingStore.shared

    var body: some View {
        let first = offer.requests.first
        let count = store.acceptCount(offerID: offer.offerID)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("\(first?.ecb ?? 0) ECB", systemImage: "star.circle.fill")
                    .font(.subheadline.bold()).foregroundStyle(.orange)
                Spacer()
                Text("\(offer.requests.count) sent").font(.caption2).foregroundStyle(.secondary)
            }
            if let f = first, !f.giveDayIDs.isEmpty {
                Text("Shifts: " + DayFmt.list(f.giveDayIDs)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(count == 0 ? "No acceptances yet" : "^[\(count) accepted](inflect: true) · tap to confirm")
                .font(.caption.bold()).foregroundStyle(count > 0 ? .green : .secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Sender's view of one ECB broadcast: a table of shifts, each with a row of
/// numbered dots (the per-shift acceptance queue). Tap a dot to confirm or skip.
struct ECBOfferView: View {
    let offerID: String
    private var store = MessagingStore.shared
    private var history = TradeHistoryStore.shared
    @Environment(\.dismiss) private var dismiss

    private var siblings: [TradeRequest] { store.requests.filter { $0.offerID == offerID } }
    private var ecb: Int { siblings.first?.ecb ?? 0 }
    private var days: [String] { store.ecbDays(offerID: offerID) }

    var body: some View {
        List {
            Section {
                LabeledContent("ECB offered") { Text("\(ecb)").bold() }
                LabeledContent("Sent to") { Text("\(siblings.count)") }
            } footer: {
                Text("Each shift has its own line. Numbered dots are the people who accepted, in order — #1 is next. Tap a dot to confirm that person (then submit their ECB form), or skip them to pass it to the next person in line.")
            }
            Section("Shifts") {
                ForEach(days, id: \.self) { day in shiftRow(day) }
            }
        }
        .navigationTitle("ECB Offer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func shiftRow(_ day: String) -> some View {
        let queue = Array(store.ecbQueue(offerID: offerID, dayID: day).prefix(MessagingStore.ecbQueueCap))
        return HStack(spacing: 10) {
            Text(DayFmt.nice(day)).font(.subheadline.bold()).frame(width: 110, alignment: .leading)
            if queue.isEmpty {
                Text("no accepters").font(.caption).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(queue.enumerated()), id: \.element.id) { idx, r in
                        Menu {
                            Text("\(r.responderName) · Emp #\(r.responderID)")
                            Button { confirm(day: day, r: r) } label: { Label("Confirm — submit ECB form", systemImage: "checkmark.seal.fill") }
                        } label: {
                            Text("\(idx + 1)")
                                .font(.caption.bold()).foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(idx == 0 ? Color.green : Color.blue, in: Circle())
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func confirm(day: String, r: TradeResponse) {
        history.record(TradeHistoryEntry(
            summary: "ECB \(ecb) → \(r.responderName) (Emp #\(r.responderID)) for \(DayFmt.nice(day))",
            participants: [r.responderName], dayIDs: [day], completedAt: Date(),
            pending: true, ecb: ecb, employeeID: r.responderID))
        Task {
            if let req = siblings.first(where: { $0.toID == r.responderID }) {
                await store.respond(to: req, status: .accepted,
                    note: "ECB CONFIRMED for \(DayFmt.nice(day)) — submitting the \(ecb)-ECB form. Confirm receipt in the app once you have it.")
            }
        }
    }
}

struct RequestRow: View {
    let request: TradeRequest
    let myID: String
    private var store = MessagingStore.shared

    init(request: TradeRequest, myID: String) { self.request = request; self.myID = myID }

    var body: some View {
        let mine = request.fromID == myID            // I sent it
        let status = store.status(of: request)
        let needsMe = status == .pending && !mine     // action required from me
        let otherName = mine ? request.toName : request.fromName
        let otherID   = mine ? request.toID : request.fromID
        return HStack(alignment: .top, spacing: 12) {
            Avatar(name: otherName, id: otherID, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(otherName).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(request.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
                Text(mine ? "You proposed a swap" : "Proposed a swap with you")
                    .font(.caption).foregroundStyle(.secondary)
                if let chain = request.chain, !chain.isEmpty {
                    Label("\(chain.count + 1)-way trade · tap to view", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.indigo)
                } else if !(request.giveDayIDs.isEmpty && request.takeDayIDs.isEmpty) {
                    // Your side of the deal, in the same give/get language as the cards.
                    TraderChips(name: "You", color: BrickPalette.mineScheme,
                                giveDays: mine ? request.giveDayIDs : request.takeDayIDs,
                                getDays: mine ? request.takeDayIDs : request.giveDayIDs,
                                maxChips: 3)
                }
                if !request.note.isEmpty {
                    mdText(request.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    StatusBadge(status: status)
                    if let ecb = request.ecb, request.isECB {
                        Label("\(ecb) ECB", systemImage: "star.circle.fill")
                            .font(.caption2.bold()).foregroundStyle(.orange)
                    }
                    if needsMe {
                        Label("Your move", systemImage: "exclamationmark.circle.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ThreadView: View {
    let request: TradeRequest
    private var store = MessagingStore.shared
    @State private var replyNote = ""
    @State private var chatDraft = ""
    @State private var ecbSelectedDays: Set<String> = []
    @State private var staleDays: Set<String> = []
    @State private var otherProfile: TradeProfile?
    @Environment(\.dismiss) private var dismiss

    init(request: TradeRequest) { self.request = request }

    private var myID: String { SettingsManager.shared.username }
    private var isIncoming: Bool { request.toID == myID }
    private var status: TradeRequestStatus { store.status(of: request) }

    var body: some View {
        List {
            if !staleDays.isEmpty {
                Section {
                    Label("Schedule changed — \(DayFmt.list(Array(staleDays))) is no longer worked, so this swap may no longer be valid.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(.orange)
                }
            }
            // The trade as a card — same language as the feed's package card.
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        let kind = request.chain != nil ? "\((request.chain?.count ?? 0) + 1)-way trade"
                            : (request.isECB ? "One-way · ECB" : "1-to-1 swap")
                        Label(kind, systemImage: request.chain != nil ? "arrow.triangle.2.circlepath"
                            : (request.isECB ? "star.circle.fill" : "arrow.left.arrow.right"))
                            .font(.subheadline.bold())
                        Spacer()
                        StatusBadge(status: status)
                    }
                    Divider()
                    if let chain = request.chain, !chain.isEmpty {
                        HandoffChain(chain: chain)
                    } else {
                        // Each party in their color, border = trades away, fill = takes.
                        let fromColor = request.fromID == myID ? BrickPalette.mineScheme : BrickPalette.peerScheme
                        let toColor   = request.toID == myID ? BrickPalette.mineScheme : BrickPalette.peerScheme
                        let fromLabel = request.fromID == myID ? "You" : request.fromName
                        let toLabel   = request.toID == myID ? "You" : request.toName
                        TraderChips(name: fromLabel, color: fromColor,
                                    giveDays: request.giveDayIDs, getDays: request.takeDayIDs)
                        if !(request.takeDayIDs.isEmpty && request.giveDayIDs.isEmpty) {
                            TraderChips(name: toLabel, color: toColor,
                                        giveDays: request.takeDayIDs, getDays: request.giveDayIDs)
                        }
                    }
                    if request.isECB, let ecb = request.ecb {
                        Label("\(ecb) ECB offered", systemImage: "star.circle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    }
                    if !request.note.isEmpty {
                        Text(request.note).font(.subheadline)
                    }
                }
                .padding(DS.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowBackground(Color.clear)
            }

            if let p = otherProfile, (p.phone != nil || p.bestEmail != nil) {
                Section("Contact \(isIncoming ? request.fromName : request.toName)") {
                    ContactButtons(profile: p)
                }
            }

            Section("Conversation") {
                auditRow(icon: "paperplane.fill", tint: .blue,
                         who: request.fromName, what: "proposed this trade", when: request.createdAt,
                         note: request.note)
                ForEach(store.responses(for: request.id).sorted { $0.createdAt < $1.createdAt }) { r in
                    if r.statusValue == .message {
                        // Free-form chat — render as a message, not an audit event.
                        SlackMessageRow(name: r.responderID == myID ? "You" : r.responderName,
                                        authorID: r.responderID, timestamp: r.createdAt, message: r.note,
                                        avatarSize: 26) { EmptyView() }
                    } else {
                        auditRow(icon: r.statusValue.icon, tint: r.statusValue.tint,
                                 who: r.responderID == myID ? "You" : r.responderName,
                                 what: r.statusValue.label.lowercased(), when: r.createdAt, note: r.note)
                    }
                }
            }

            if isIncoming && status != .pending {
                Section {
                    Label("You replied: \(status.label)", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(status == .declined ? .red : .green)
                }
            }

            // ECB queue position (recipient side) — per shift.
            if isIncoming, request.isECB, let offerID = request.offerID, !senderConfirmedECB {
                Section("Your queue position (per shift)") {
                    ForEach(request.giveDayIDs, id: \.self) { d in
                        HStack {
                            Text(DayFmt.nice(d)).font(.subheadline)
                            Spacer()
                            if let pos = store.myQueuePosition(offerID: offerID, dayID: d) {
                                Text("#\(pos)").font(.subheadline.bold())
                                    .foregroundStyle(pos <= MessagingStore.ecbQueueCap ? .green : .orange)
                            } else {
                                Text("not accepted").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // ECB receipt confirmation (recipient side): once the sender confirms
            // and submits the form, you confirm you received the ECB.
            if isIncoming, request.isECB, senderConfirmedECB {
                Section("ECB transfer") {
                    if receivedECB {
                        Label("You confirmed receipt of \(request.ecb ?? 0) ECB.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("\(request.fromName) is submitting the \(request.ecb ?? 0)-ECB form. Confirm once it lands in your account.")
                            .font(.subheadline)
                        Button { confirmReceived() } label: {
                            Label("Confirm ECB received", systemImage: "star.circle.fill")
                        }
                        .buttonStyle(.borderedProminent).tint(.orange)
                    }
                }
            }

            if isIncoming, request.isECB, status == .pending {
                Section("Accept shifts — \(request.ecb ?? 0) ECB each") {
                    ForEach(request.giveDayIDs, id: \.self) { d in
                        Toggle(DayFmt.nice(d), isOn: Binding(
                            get: { ecbSelectedDays.contains(d) },
                            set: { on in if on { ecbSelectedDays.insert(d) } else { ecbSelectedDays.remove(d) } }))
                    }
                    Button { Task { await store.acceptECB(request, days: Array(ecbSelectedDays)); ecbSelectedDays = [] } } label: {
                        Label("Accept selected", systemImage: "checkmark.circle.fill")
                    }
                    .tint(.green).disabled(ecbSelectedDays.isEmpty)
                    Button(role: .destructive) { respond(.declined) } label: { Label("Decline all", systemImage: "xmark.circle") }
                }
            } else if isIncoming && status == .pending {
                Section("Respond") {
                    TextField("Optional note…", text: $replyNote, axis: .vertical)
                    Button { respond(.accepted) } label: { Label("Accept", systemImage: "checkmark.circle.fill") }
                        .tint(.green)
                        .disabled(!staleDays.isEmpty)   // can't accept an invalid swap
                    Button { respond(.countered) } label: { Label("Counter", systemImage: "arrow.uturn.left.circle") }
                    Button(role: .destructive) { respond(.declined) } label: { Label("Decline", systemImage: "xmark.circle") }
                }
            } else if !isIncoming && status == .pending {
                Section {
                    Button(role: .destructive) {
                        Task { await store.cancelRequest(request.id); dismiss() }
                    } label: { Label("Cancel request", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("Swap with \(isIncoming ? request.fromName : request.toName)")
        .navigationBarTitleDisplayMode(.inline)
        // Chat is always available — talk it out regardless of accept/decline state.
        .safeAreaInset(edge: .bottom) {
            SlackComposer(placeholder: "Message \(isIncoming ? request.fromName : request.toName)",
                          text: $chatDraft, showFormatBar: false) {
                let text = chatDraft; chatDraft = ""
                Task { await store.postMessage(to: request, text: text) }
            }
        }
        .task {
            staleDays = await TradeMatcher.staleDays(
                fromID: request.fromID, toID: request.toID,
                giveDayIDs: request.giveDayIDs, takeDayIDs: request.takeDayIDs)
            let otherID = isIncoming ? request.fromID : request.toID
            otherProfile = await TradeProfileStore.shared.fetchProfile(forWorker: otherID)
        }
    }

    /// One chronological audit event: who did what, when, with the note.
    private func auditRow(icon: String, tint: Color, who: String, what: String,
                          when: Date, note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("\(who) \(what)").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(when, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
                if !note.isEmpty {
                    mdText(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The sender posted an "ECB CONFIRMED" response → they're submitting the form.
    private var senderConfirmedECB: Bool {
        store.responses(for: request.id).contains {
            $0.responderID == request.fromID && $0.note.localizedCaseInsensitiveContains("ECB CONFIRMED")
        }
    }
    /// You already confirmed receipt.
    private var receivedECB: Bool {
        store.responses(for: request.id).contains {
            $0.responderID == myID && $0.note.localizedCaseInsensitiveContains("RECEIVED")
        }
    }
    /// The sender filled the offer with someone else.
    private var filledByOther: Bool {
        store.responses(for: request.id).contains {
            $0.responderID == request.fromID && $0.note.localizedCaseInsensitiveContains("filled")
        }
    }

    private func confirmReceived() {
        let ecb = request.ecb ?? 0
        Task {
            await store.respond(to: request, status: .accepted, note: "ECB RECEIVED — got the \(ecb) ECB. Thanks!")
            TradeHistoryStore.shared.record(TradeHistoryEntry(
                summary: "Received \(ecb) ECB from \(request.fromName) for taking \(DayFmt.list(request.giveDayIDs))",
                participants: [request.fromName], dayIDs: request.giveDayIDs,
                completedAt: Date(), pending: false, ecb: ecb))
            WidgetData.update()
        }
    }

    private func respond(_ status: TradeRequestStatus) {
        var note = replyNote.trimmingCharacters(in: .whitespacesAndNewlines)
        // ECB acceptances auto-include your employee # for the official form.
        if request.isECB, status == .accepted {
            let id = SettingsManager.shared.username
            note = "Employee #\(id)." + (note.isEmpty ? "" : " \(note)")
        }
        Task {
            await store.respond(to: request, status: status, note: note)
            replyNote = ""
            WidgetData.update()
            // Stay on the thread so your reply (and its status) is visible.
        }
    }
}

// MARK: - Broadcast Channel

struct ChannelView: View {
    private var store = MessagingStore.shared
    private var dev = DevAccess.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var expanded: Set<String> = []
    @State private var respondedNote: String?
    @State private var editingPost: BroadcastPost?
    @State private var channel = "trades"

    private var myID: String { SettingsManager.shared.username }
    private var isFeedback: Bool { channel == "feedback" }
    private var posts: [BroadcastPost] { store.broadcasts.filter { $0.channelOrDefault == channel } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Channel", selection: $channel) {
                    Text("# trades").tag("trades")
                    Text("# feedback").tag("feedback")
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 6)
                ChannelHeader(name: channel,
                              subtitle: isFeedback ? "Bugs & ideas for the app — the builder reads these"
                                                   : "What you're trading away — everyone sees it")
                Divider()
                if posts.isEmpty {
                    ContentUnavailableView(isFeedback ? "No Feedback Yet" : "No Posts Yet",
                        systemImage: isFeedback ? "exclamationmark.bubble" : "megaphone",
                        description: Text(isFeedback
                            ? "Report a bug or suggest an improvement — start your message with what you did and what happened."
                            : "Post what you're looking to trade away — everyone sees it. Posts expire on their own; delete yours anytime."))
                        .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(posts) { post in
                            postRow(post)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await store.refresh() }
                }
                Divider()
                SlackComposer(placeholder: "Message #\(channel)", text: $draft) {
                    let text = draft; draft = ""
                    Task { await store.post(text: text, channel: channel) }
                }
            }
            .navigationTitle(isFeedback ? "Feedback" : "Trade Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.refresh() }
            .alert("Sent", isPresented: Binding(get: { respondedNote != nil }, set: { if !$0 { respondedNote = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(respondedNote ?? "") }
            .sheet(item: $editingPost) { post in EditPostSheet(post: post) }
        }
    }

    private func postRow(_ post: BroadcastPost) -> some View {
        let isOpen = expanded.contains(post.id)
        let reps = store.visibleReplies(for: post)
        return VStack(alignment: .leading, spacing: 6) {
            SlackMessageRow(name: post.authorName, authorID: post.authorID,
                            timestamp: post.createdAt, message: post.text) {
                postMenu(post)
            }

            if !reps.isEmpty && !isOpen {
                Button { expanded.insert(post.id) } label: {
                    Label("^[\(reps.count) reply](inflect: true)", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.blue).padding(.leading, 46)
            }

            if isOpen {
                HStack(spacing: 8) {
                    Rectangle().fill(.quaternary).frame(width: 2)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(reps) { r in replyRow(r) }
                        BroadcastReplyComposer(isAuthor: store.isMine(post)) { text, isPublic in
                            Task { await store.addReply(to: post, text: text, isPublic: isPublic) }
                        }
                    }
                }
                .padding(.leading, 18)

                actionRow(post)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isOpen { expanded.insert(post.id) }
        }
    }

    @ViewBuilder private func postMenu(_ post: BroadcastPost) -> some View {
        if store.isMine(post) {
            Menu {
                Button { editingPost = post } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { Task { await store.deletePost(post.id) } } label: { Label("Delete", systemImage: "trash") }
                if expanded.contains(post.id) {
                    Button { expanded.remove(post.id) } label: { Label("Collapse", systemImage: "chevron.up") }
                }
            } label: {
                Image(systemName: "ellipsis").font(.caption).foregroundStyle(.secondary).padding(4)
            }
        } else if dev.unlocked {
            Button(role: .destructive) { Task { await store.hide(post.id) } } label: {
                Image(systemName: "eye.slash.fill").font(.caption2)
            }.buttonStyle(.borderless)
        }
    }

    private func replyRow(_ r: BroadcastReply) -> some View {
        SlackMessageRow(name: r.authorID == myID ? "You" : r.authorName, authorID: r.authorID,
                        timestamp: r.createdAt, message: r.text,
                        meta: (r.isPublic ? "public" : "private", r.isPublic ? .blue : .orange),
                        avatarSize: 26) {
            if r.authorID == myID {
                Button(role: .destructive) { Task { await store.deleteReply(r.id) } } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption2)
                }.buttonStyle(.borderless)
            } else if dev.unlocked {
                Button(role: .destructive) { Task { await store.hide(r.id) } } label: {
                    Image(systemName: "eye.slash.fill").font(.caption2)
                }.buttonStyle(.borderless)
            }
        }
    }

    private func actionRow(_ post: BroadcastPost) -> some View {
        HStack(spacing: 14) {
            if !store.isMine(post) {
                Button {
                    Task {
                        await store.sendRequest(
                            to: post.authorID, toName: post.authorName,
                            note: "Re: your channel post — “\(post.text)”. I'm interested.",
                            take: [], give: [])
                        WidgetData.update()
                        respondedNote = "Trade request sent to \(post.authorName). Track it in your Inbox."
                    }
                } label: { Label("Send trade request", systemImage: "arrowshape.turn.up.left.fill").font(.caption) }
                    .buttonStyle(.borderless)
            }
            Spacer()
            Text("Expires \(post.expiresAt, style: .relative)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.leading, 46)
    }
}

/// Compose a reply (or, for the post author, an update) with a public/private choice.
struct BroadcastReplyComposer: View {
    let isAuthor: Bool
    let onSend: (String, Bool) -> Void
    @State private var draft = ""
    @State private var isPublic = true

    var body: some View {
        VStack(spacing: 4) {
            TextField(isAuthor ? "Post an update…" : "Reply…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder).font(.caption)
            HStack {
                Picker("", selection: $isPublic) {
                    Label("Public", systemImage: "globe").tag(true)
                    Label("Private", systemImage: "lock.fill").tag(false)
                }
                .pickerStyle(.segmented).fixedSize()
                FormatBar(text: $draft).padding(.leading, 8)
                Spacer()
                Button {
                    let t = draft; draft = ""
                    onSend(t, isPublic)
                } label: { Text("Send").font(.caption.bold()) }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Edit your own broadcast post (text + Markdown formatting).
struct EditPostSheet: View {
    let post: BroadcastPost
    private var store = MessagingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(post: BroadcastPost) {
        self.post = post
        _draft = State(initialValue: post.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $draft)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                HStack {
                    FormatBar(text: $draft)
                    Spacer()
                    Text("**bold** *italic* ~~strike~~").font(.caption2).foregroundStyle(.tertiary)
                }
                Text("Preview").font(.caption).foregroundStyle(.secondary)
                mdText(draft).font(.subheadline)
                Spacer()
            }
            .padding()
            .navigationTitle("Edit Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await store.editPost(post, newText: draft); dismiss() }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Side dock (floating, on every page)

struct MessagingDock: View {
    @Binding var showInbox: Bool
    @Binding var showChannel: Bool
    private var store = MessagingStore.shared

    init(showInbox: Binding<Bool>, showChannel: Binding<Bool>) {
        _showInbox = showInbox; _showChannel = showChannel
    }

    var body: some View {
        HStack(spacing: 8) {
            // Inbox badge = replies that need YOU (actionable, red).
            dockButton(icon: "tray.full.fill", label: "Inbox",
                       badge: store.pendingIncoming.count, badgeColor: .red) { showInbox = true }
            // Channel badge = active posts (informational, neutral).
            dockButton(icon: "megaphone.fill", label: "Channel",
                       badge: store.broadcasts.count, badgeColor: .blue) { showChannel = true }
        }
    }

    private func dockButton(icon: String, label: String, badge: Int,
                            badgeColor: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(label).font(.caption.weight(.semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.dsBadge).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(badgeColor, in: Capsule())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .shadow(radius: 3, y: 1)
    }
}
