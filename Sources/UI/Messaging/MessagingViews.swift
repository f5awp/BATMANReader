// MessagingViews.swift
// The in-app trade Inbox (1:1 requests + replies) and the Broadcast Channel
// (self-maintaining feed). Both presented as sheets from the side dock.

import SwiftUI
import PhotosUI

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
        store.requests.filter { $0.isECB }.sorted { ($0.ecbAmount ?? 0) > ($1.ecbAmount ?? 0) }
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
                    let incomingECB = store.incoming.filter { $0.isECB }.sorted { ($0.ecbAmount ?? 0) > ($1.ecbAmount ?? 0) }
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
                    let arch = store.archivedRequestIDs
                    List {
                        let pending = MessagingStore.active(store.pendingIncoming, archived: arch)
                        if !pending.isEmpty {
                            Section("Needs your reply") { ForEach(pending) { row($0) } }
                        }
                        let handledIncoming = MessagingStore.active(store.incoming, archived: arch)
                            .filter { store.status(of: $0) != .pending }
                        if !handledIncoming.isEmpty {
                            Section("Incoming") { ForEach(handledIncoming) { row($0) } }
                        }
                        let sent = MessagingStore.active(store.outgoing, archived: arch)
                        if !sent.isEmpty {
                            Section("Sent") { ForEach(sent) { row($0) } }
                        }
                        let archived = store.requests.filter { arch.contains($0.id) }
                        if !archived.isEmpty {
                            Section("Archived") { ForEach(archived) { row($0) } }
                        }
                    }
                }
            }
            .navigationTitle("Trade Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.refresh(); await TradeProfileStore.shared.refreshOthers() }   // load peers so status renders (A7/B8 / audit #7)
            .refreshable { await store.refresh(); await TradeProfileStore.shared.refreshOthers() }
        }
    }

    private func row(_ req: TradeRequest) -> some View {
        NavigationLink { ThreadView(request: req) } label: { RequestRow(request: req, myID: myID) }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { Task { await store.cancelRequest(req.id) } } label: {
                    Label("Delete", systemImage: "trash")   // gone forever
                }
                if store.archivedRequestIDs.contains(req.id) {
                    Button { store.unarchiveRequest(req.id) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }.tint(.blue)
                } else {
                    Button { store.archiveRequest(req.id) } label: { Label("Archive", systemImage: "archivebox") }.tint(.gray)
                }
            }
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
                Label("\(ecbText(first?.ecbAmount ?? 0)) ECB", systemImage: "star.circle.fill")
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
    private var ecb: Double { siblings.first?.ecbAmount ?? 0 }
    private var days: [String] { store.ecbDays(offerID: offerID) }

    var body: some View {
        List {
            Section {
                LabeledContent("ECB offered") { Text(ecbText(ecb)).bold() }
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
            summary: "ECB \(ecbText(ecb)) → \(r.responderName) (Emp #\(r.responderID)) for \(DayFmt.nice(day))",
            participants: [r.responderName], dayIDs: [day], completedAt: Date(),
            pending: true, ecb: Int(ecb.rounded()), employeeID: r.responderID))
        Task {
            if let req = siblings.first(where: { $0.toID == r.responderID }) {
                await store.respond(to: req, status: .accepted,
                    note: "ECB CONFIRMED for \(DayFmt.nice(day)) — submitting the \(ecbText(ecb))-ECB form. Confirm receipt in the app once you have it.")
            }
        }
    }
}

/// B5 image helper: downscale + JPEG-compress + base64 so a photo rides the message JSON payload
/// (stays well under CloudKit's ~1MB record limit). Pure-ish (UIKit image ops); decode is the inverse.
enum PostImage {
    static func encode(_ image: UIImage, maxDimension: CGFloat = 1024, quality: CGFloat = 0.5) -> String? {
        func data(_ dim: CGFloat, _ q: CGFloat) -> Data? { downscale(image, maxDimension: dim).jpegData(compressionQuality: q) }
        if let d = data(maxDimension, quality), d.count < 700_000 { return d.base64EncodedString() }
        if let d = data(768, 0.4), d.count < 700_000 { return d.base64EncodedString() }   // try harder once
        return nil   // too big even compressed → skip rather than blow the record limit
    }
    static func decode(_ base64: String) -> UIImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }
    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let m = max(image.size.width, image.size.height)
        guard m > maxDimension else { return image }
        let scale = maxDimension / m
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// Reusable emoji-reaction strip (B6): existing reactions as count chips + a quick-react menu.
/// `onTap(emoji)` toggles the caller's reaction. Used on channel replies and 1:1 chat messages.
struct ReactionChips: View {
    let reactions: [Reaction]
    let onTap: (String) -> Void
    private static let quick = ["👍", "❤️", "✅", "⚠️", "🔥", "🙏"]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Reaction.counts(reactions), id: \.emoji) { r in
                Button { onTap(r.emoji) } label: {
                    Text("\(r.emoji) \(r.count)").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }.buttonStyle(.plain)
            }
            Menu {
                ForEach(Self.quick, id: \.self) { e in Button(e) { onTap(e) } }
            } label: {
                Image(systemName: "face.smiling").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
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
                HStack(alignment: .top) {
                    NameWithStatus(id: otherID, name: otherName)
                    Spacer()
                    Text(request.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
                Text(mine ? "You proposed a swap" : "Proposed a swap with you")
                    .font(.caption).foregroundStyle(.secondary)
                if let chain = request.chain, !chain.isEmpty {
                    Label("\(tradeTypeLabel(distinctPeople: distinctParticipants(in: chain))) · tap to view", systemImage: "arrow.triangle.2.circlepath")
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
                    // S-VALID: a traded day is no longer worked → this request is invalid.
                    if store.isInvalid(request) {
                        Label("Invalid", systemImage: "exclamationmark.octagon.fill")
                            .font(.caption2.bold()).foregroundStyle(BrickPalette.critical)
                    }
                    if let ecb = request.ecbAmount, request.isECB {
                        Label("\(ecbText(ecb)) ECB", systemImage: "star.circle.fill")
                            .font(.caption2.bold()).foregroundStyle(.orange)
                    }
                    // 🔥 the incoming request hits one of my own marked intents (U6).
                    if !mine, store.matchesMyIntents(request) {
                        Label("Matches your intent", systemImage: "flame.fill")
                            .font(.caption2.weight(.bold)).foregroundStyle(.orange)
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
    @State private var editingMessage: TradeResponse?
    @State private var editMsgDraft = ""
    @Environment(\.dismiss) private var dismiss

    init(request: TradeRequest) { self.request = request }

    private var myID: String { SettingsManager.shared.username }
    private var isIncoming: Bool { request.toID == myID }
    private var status: TradeRequestStatus { store.status(of: request) }

    var body: some View {
        List {
            if !staleDays.isEmpty {
                Section {
                    Label("Action needed — \(DayFmt.list(Array(staleDays))) is no longer worked, so this trade is INVALID. Delete or archive it.",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.subheadline.weight(.bold)).foregroundStyle(BrickPalette.critical)
                        .listRowBackground(BrickPalette.critical.opacity(0.12))
                }
            }
            // The trade as a card — same language as the feed's package card.
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        let people = request.chain.map(distinctParticipants(in:)) ?? 2
                        let kind = tradeTypeLabel(distinctPeople: people, isOneWayECB: request.isECB)
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
                                    giveDays: request.giveDayIDs, getDays: request.takeDayIDs,
                                    id: request.fromID == myID ? nil : request.fromID)
                        if !(request.takeDayIDs.isEmpty && request.giveDayIDs.isEmpty) {
                            TraderChips(name: toLabel, color: toColor,
                                        giveDays: request.takeDayIDs, getDays: request.giveDayIDs,
                                        id: request.toID == myID ? nil : request.toID)
                        }
                    }
                    if request.isECB, let ecb = request.ecbAmount {
                        Label("\(ecbText(ecb)) ECB offered", systemImage: "star.circle.fill")
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

            qualSwapSection

            Section {
                Button { openDispatchDraft(subject: "", body: "") } label: {
                    Label("New email to dispatch DL", systemImage: "envelope")
                }
            } footer: {
                Text("Opens a blank new message in Outlook addressed to \(SettingsManager.shared.tradeEmailDL).")
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
                        VStack(alignment: .leading, spacing: 4) {
                            SlackMessageRow(name: r.responderID == myID ? "You" : r.responderName,
                                            authorID: r.responderID, timestamp: r.createdAt,
                                            message: r.isDeleted ? "[Deleted]" : r.note,
                                            meta: r.editedAt != nil ? ("edited", .secondary) : nil,
                                            avatarSize: 26) {
                                if !r.isDeleted && r.responderID == myID {
                                    Button { editingMessage = r; editMsgDraft = r.note } label: {
                                        Image(systemName: "pencil").font(.caption2)
                                    }.buttonStyle(.borderless)
                                    Button(role: .destructive) { Task { await store.softDeleteMessage(r) } } label: {
                                        Image(systemName: "trash").font(.caption2)
                                    }.buttonStyle(.borderless)
                                }
                            }
                            if !r.isDeleted {
                                ReactionChips(reactions: r.reactions ?? []) { e in Task { await store.react(to: r, emoji: e) } }
                                    .padding(.leading, 34)
                            }
                        }
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
                        Label("You confirmed receipt of \(ecbText(request.ecbAmount ?? 0)) ECB.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("\(request.fromName) is submitting the \(ecbText(request.ecbAmount ?? 0))-ECB form. Confirm once it lands in your account.")
                            .font(.subheadline)
                        Button { confirmReceived() } label: {
                            Label("Confirm ECB received", systemImage: "star.circle.fill")
                        }
                        .buttonStyle(.borderedProminent).tint(.orange)
                    }
                }
            }

            if isIncoming, request.isECB, status == .pending {
                Section("Accept shifts — \(ecbText(request.ecbAmount ?? 0)) ECB each") {
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
        .alert("Edit message", isPresented: Binding(get: { editingMessage != nil }, set: { if !$0 { editingMessage = nil } })) {
            TextField("Message", text: $editMsgDraft)
            Button("Save") { if let m = editingMessage { Task { await store.editMessage(m, newText: editMsgDraft) } }; editingMessage = nil }
            Button("Cancel", role: .cancel) { editingMessage = nil }
        }
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

    /// Color indicator for a qual-swap leg status (Q3).
    private func qualSwapTint(_ s: QualSwapLegStatus) -> Color {
        switch s {
        case .waiting:                 return .orange
        case .offersOpen, .offersFull: return .blue
        case .finalized:               return .green
        case .invalid:                 return BrickPalette.critical
        }
    }

    /// Qual-swap leg (Q3/Q5/Q6): role-aware — bridge accepts, taker chooses/declines,
    /// everyone else sees the contingent status.
    @ViewBuilder private var qualSwapSection: some View {
        if let leg = request.qualSwap {
            let role = request.qualSwapRole(for: myID)
            Section {
                HStack {
                    Image(systemName: leg.status == .invalid ? "exclamationmark.octagon.fill" : "person.2.badge.gearshape.fill")
                        .foregroundStyle(qualSwapTint(leg.status))
                    Text(leg.statusText).font(.subheadline.weight(.semibold))
                }
                Text("Desk \(leg.giveDesk) needs qual \(leg.giveQual); \(leg.takerName) will take whichever desk a bridge frees up.")
                    .font(.caption).foregroundStyle(.secondary)

                // BRIDGE (C): accept / already-filled.
                if role == .bridge {
                    let iAccepted = leg.acceptances.contains { $0.workerID == myID }
                    if iAccepted {
                        Label("You accepted this qual swap.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else if leg.acceptIsOpen && !leg.status.isTerminal {
                        if let cand = leg.candidates.first(where: { $0.workerID == myID }) {
                            Text("You'd move onto desk \(leg.giveDesk) (\(leg.giveQual)); your desk \(cand.desk) (\(cand.qual)) goes to \(leg.takerName).")
                                .font(.caption)
                        }
                        Button { Task { await store.acceptQualSwapBridge(request) } } label: {
                            Label("Accept qual swap", systemImage: "checkmark.circle.fill")
                        }.tint(.green)
                    } else {
                        Label("Qual swap already filled.", systemImage: "lock.fill").foregroundStyle(.secondary)
                    }
                }

                // TAKER (B): live acceptances + choose + decline.
                if role == .taker {
                    Text("\(leg.acceptances.count) of \(leg.candidates.count) asked have accepted.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(leg.acceptances) { a in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name).font(.subheadline.weight(.semibold))
                                Text("frees desk \(a.desk) (\(a.qual))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if leg.chosenWorkerID == a.workerID {
                                Label("Chosen", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            } else if !leg.status.isTerminal {
                                Button("Choose") { Task { await store.finalizeQualSwap(request, chosenWorkerID: a.workerID) } }
                                    .buttonStyle(.borderedProminent).tint(.green)
                            }
                        }
                    }
                    if leg.acceptances.isEmpty && !leg.status.isTerminal {
                        Text("Waiting for a bridge to accept…").font(.caption).foregroundStyle(.secondary)
                    }
                    if !leg.status.isTerminal {
                        Button(role: .destructive) { Task { await store.declineQualSwap(request) } } label: {
                            Label("Decline — cancels the trade", systemImage: "xmark.circle")
                        }
                    }
                }

                // GIVER (A) / uninvolved party: read-only contingent state.
                if (role == .giver || role == .none), !leg.status.isTerminal {
                    Label("This trade is contingent on the qual swap.", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Qual swap")
            }
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
        let ecb = request.ecbAmount ?? 0
        Task {
            await store.respond(to: request, status: .accepted, note: "ECB RECEIVED — got the \(ecbText(ecb)) ECB. Thanks!")
            TradeHistoryStore.shared.record(TradeHistoryEntry(
                summary: "Received \(ecbText(ecb)) ECB from \(request.fromName) for taking \(DayFmt.list(request.giveDayIDs))",
                participants: [request.fromName], dayIDs: request.giveDayIDs,
                completedAt: Date(), pending: false, ecb: Int(ecb.rounded())))
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
    @State private var editingReply: BroadcastReply?
    @State private var editReplyDraft = ""
    @State private var channel = "trades"
    @State private var pickerItem: PhotosPickerItem?   // B5: photo attach
    @State private var pendingImage: UIImage?

    private var myID: String { SettingsManager.shared.username }
    private var posts: [BroadcastPost] {
        MessagingStore.sortedForChannel(store.broadcasts.filter { $0.channelOrDefault == channel })
    }

    /// Per-channel copy. Unknown channels fall back to the trade board. E1.
    private var channelMeta: (title: String, subtitle: String, emptyTitle: String, emptyDesc: String, icon: String) {
        switch channel {
        case "general":
            return ("General", "Anything dispatch — chat with the group", "No Messages Yet",
                    "Say hello, ask a question, share an update — everyone sees it.", "bubble.left.and.bubble.right")
        case "feedback":
            return ("Feedback", "Bugs & ideas for the app — the builder reads these", "No Feedback Yet",
                    "Report a bug or suggest an improvement — start with what you did and what happened.", "exclamationmark.bubble")
        default:
            return ("Trade Channel", "What you're trading away — everyone sees it", "No Posts Yet",
                    "Post what you're looking to trade away — everyone sees it. Posts expire on their own.", "megaphone")
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Channel", selection: $channel) {
                    Text("# general").tag("general")
                    Text("# trades").tag("trades")
                    Text("# feedback").tag("feedback")
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 6)
                ChannelHeader(name: channel, subtitle: channelMeta.subtitle)
                    .onAppear { store.markBroadcastsSeen() }   // clears the unread badge (A2)
                Divider()
                if posts.isEmpty {
                    ContentUnavailableView(channelMeta.emptyTitle, systemImage: channelMeta.icon,
                        description: Text(channelMeta.emptyDesc))
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
                    .refreshable { await store.refresh(); await TradeProfileStore.shared.refreshOthers() }
                }
                Divider()
                HStack(spacing: 8) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Photo", systemImage: "photo").font(.caption)
                    }
                    if let img = pendingImage {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 6))
                        Button { pendingImage = nil; pickerItem = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.top, 4)
                .onChange(of: pickerItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) { pendingImage = UIImage(data: data) }
                    }
                }
                SlackComposer(placeholder: "Message #\(channel)", text: $draft) {
                    let text = draft; draft = ""
                    let img = pendingImage; pendingImage = nil; pickerItem = nil
                    Task {
                        let b64 = img.flatMap { PostImage.encode($0) }
                        await store.post(text: text, channel: channel, imageBase64: b64)
                    }
                }
            }
            .navigationTitle(channelMeta.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.refresh(); await TradeProfileStore.shared.refreshOthers() }   // E2: load peers so statuses render
            .alert("Sent", isPresented: Binding(get: { respondedNote != nil }, set: { if !$0 { respondedNote = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(respondedNote ?? "") }
            .sheet(item: $editingPost) { post in EditPostSheet(post: post) }
            .alert("Edit reply", isPresented: Binding(get: { editingReply != nil }, set: { if !$0 { editingReply = nil } })) {
                TextField("Reply", text: $editReplyDraft)
                Button("Save") { if let r = editingReply { Task { await store.editReply(r, newText: editReplyDraft) } }; editingReply = nil }
                Button("Cancel", role: .cancel) { editingReply = nil }
            }
        }
    }

    /// E2: the author's published status — mine from Settings, peers from the loaded profiles.
    private func authorStatus(_ id: String) -> String? {
        let raw = (id == SettingsManager.shared.username)
            ? SettingsManager.shared.statusBroadcast
            : (TradeProfileStore.shared.profile(forWorker: id)?.statusBroadcast ?? "")
        let t = raw.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func postRow(_ post: BroadcastPost) -> some View {
        let isOpen = expanded.contains(post.id)
        let reps = store.visibleReplies(for: post)
        return VStack(alignment: .leading, spacing: 6) {
            if post.isPinned {
                Label("Pinned", systemImage: "pin.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.orange).padding(.leading, 46)
            }
            SlackMessageRow(name: post.authorName, authorID: post.authorID,
                            timestamp: post.createdAt, message: post.text) {
                postMenu(post)
            }
            // E2: the author's published status (with emoji) under their name.
            if let s = authorStatus(post.authorID) {
                Text(s).font(.caption2).italic().foregroundStyle(.secondary).lineLimit(2).padding(.leading, 46)
            }
            if let b64 = post.imageBase64, let ui = PostImage.decode(b64) {
                Image(uiImage: ui).resizable().scaledToFit()
                    .frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.leading, 46)
            }
            reactionsBar(post)

            if !reps.isEmpty && !isOpen {
                Button { expanded.insert(post.id) } label: {
                    Label("^[\(reps.count) reply](inflect: true)", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.blue).padding(.leading, 46)
            }

            if isOpen {
                HStack(spacing: 8) {
                    // Reddit-style threadline — a tappable rail that collapses the thread.
                    Capsule().fill(Color.accentColor.opacity(0.35)).frame(width: 2.5)
                        .contentShape(Rectangle())
                        .onTapGesture { expanded.remove(post.id) }
                    VStack(alignment: .leading, spacing: 2) {
                        if !reps.isEmpty {
                            Button { expanded.remove(post.id) } label: {
                                Label("Hide ^[\(reps.count) reply](inflect: true)", systemImage: "chevron.up")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        ForEach(reps) { r in replyRow(r) }
                        BroadcastReplyComposer(isAuthor: store.isMine(post)) { text, isPublic, image in
                            Task { await store.addReply(to: post, text: text, isPublic: isPublic, imageBase64: image) }
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
            if isOpen { expanded.remove(post.id) } else { expanded.insert(post.id) }   // #10: tap toggles
        }
    }

    @ViewBuilder private func postMenu(_ post: BroadcastPost) -> some View {
        let mine = store.isMine(post)
        if mine || dev.unlocked {
            Menu {
                if mine {
                    Button { editingPost = post } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { Task { await store.deletePost(post.id) } } label: { Label("Delete", systemImage: "trash") }
                }
                if dev.unlocked {   // admin: pin to top of channel (B7)
                    Button { Task { await store.setPinned(post, !post.isPinned) } } label: {
                        Label(post.isPinned ? "Unpin" : "Pin to top", systemImage: post.isPinned ? "pin.slash" : "pin")
                    }
                    if !mine {
                        Button(role: .destructive) { Task { await store.hide(post.id) } } label: { Label("Hide", systemImage: "eye.slash") }
                    }
                }
                if expanded.contains(post.id) {
                    Button { expanded.remove(post.id) } label: { Label("Collapse", systemImage: "chevron.up") }
                }
            } label: {
                Image(systemName: "ellipsis").font(.caption).foregroundStyle(.secondary).padding(4)
            }
        }
    }

    private static let quickEmojis = ["👍", "❤️", "✅", "⚠️", "🔥", "🙏"]

    /// Emoji reaction chips + a quick-react menu (B6).
    @ViewBuilder private func reactionsBar(_ post: BroadcastPost) -> some View {
        HStack(spacing: 6) {
            ForEach(Reaction.counts(post.reactions ?? []), id: \.emoji) { r in
                Button { Task { await store.react(to: post, emoji: r.emoji) } } label: {
                    Text("\(r.emoji) \(r.count)").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }.buttonStyle(.plain)
            }
            Menu {
                ForEach(Self.quickEmojis, id: \.self) { e in
                    Button(e) { Task { await store.react(to: post, emoji: e) } }
                }
            } label: {
                Image(systemName: "face.smiling").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, 46)
    }

    private func replyRow(_ r: BroadcastReply) -> some View {
        let metaText = (r.isPublic ? "public" : "private") + (r.editedAt != nil ? " · edited" : "")
        return VStack(alignment: .leading, spacing: 4) {
            SlackMessageRow(name: r.authorID == myID ? "You" : r.authorName, authorID: r.authorID,
                            timestamp: r.createdAt, message: r.isDeleted ? "[Deleted]" : r.text,
                            meta: (metaText, r.isPublic ? .blue : .orange),
                            avatarSize: 26) {
                if r.isDeleted {
                    EmptyView()
                } else if r.authorID == myID {
                    Button { editingReply = r; editReplyDraft = r.text } label: {
                        Image(systemName: "pencil").font(.caption2)
                    }.buttonStyle(.borderless)
                    Button(role: .destructive) { Task { await store.softDeleteReply(r) } } label: {
                        Image(systemName: "trash").font(.caption2)
                    }.buttonStyle(.borderless)
                } else if dev.unlocked {
                    Button(role: .destructive) { Task { await store.hide(r.id) } } label: {
                        Image(systemName: "eye.slash.fill").font(.caption2)
                    }.buttonStyle(.borderless)
                }
            }
            if !r.isDeleted, let b64 = r.imageBase64, let ui = PostImage.decode(b64) {
                Image(uiImage: ui).resizable().scaledToFit()
                    .frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 34)
            }
            if !r.isDeleted {
                ReactionChips(reactions: r.reactions ?? []) { e in Task { await store.react(to: r, emoji: e) } }
                    .padding(.leading, 34)
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

/// Compose a reply (or, for the post author, an update): premium field, public/private,
/// photo attach, and a send ICON. (#8b)
struct BroadcastReplyComposer: View {
    let isAuthor: Bool
    let onSend: (String, Bool, String?) -> Void
    @State private var draft = ""
    @State private var isPublic = true
    @State private var pickerItem: PhotosPickerItem?
    @State private var pendingImage: UIImage?

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let img = pendingImage {
                HStack(spacing: 8) {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                    Button { pendingImage = nil; pickerItem = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            TextField(isAuthor ? "Post an update…" : "Reply…", text: $draft, axis: .vertical)
                .font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .lineLimit(1...4)
            HStack(spacing: 12) {
                Picker("", selection: $isPublic) {
                    Label("Public", systemImage: "globe").tag(true)
                    Label("Private", systemImage: "lock.fill").tag(false)
                }
                .pickerStyle(.segmented).fixedSize()
                FormatBar(text: $draft)
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "photo").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let t = draft, img = pendingImage
                    draft = ""; pendingImage = nil; pickerItem = nil
                    onSend(t, isPublic, img.flatMap { PostImage.encode($0) })
                } label: {
                    Image(systemName: "paperplane.circle.fill").font(.title2)
                        .foregroundStyle(canSend ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.vertical, 4)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { if let data = try? await item.loadTransferable(type: Data.self) { pendingImage = UIImage(data: data) } }
        }
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
            // Channel badge = UNREAD posts (clears on open). A2/S-SYNC-1.
            dockButton(icon: "megaphone.fill", label: "Channel",
                       badge: store.unreadBroadcastCount, badgeColor: .blue) { showChannel = true }
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
