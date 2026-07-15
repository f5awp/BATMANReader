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

extension MessagingStore {
    /// Maps a trade's status to a (label, color) for `DXStatusBadge`. Kept here (not in the design-kit
    /// file) so re-importing `DXMosaicIntegration.swift` can't drop it. `.message` isn't a decision state.
    static func dxBadge(_ s: TradeRequestStatus) -> (String, Color) {
        switch s {
        case .accepted:             return ("Accepted", AppColor.success)
        case .pending:              return ("Pending",  AppColor.pending)
        case .countered:            return ("Replied",  AppColor.primary)
        case .declined, .cancelled: return ("Declined", AppColor.danger)
        case .message:              return ("", AppColor.neutral)
        }
    }
}

struct StatusBadge: View {
    let status: TradeRequestStatus
    var body: some View {
        // Mosaic glazed badge (one place → every Inbox / Trade-Status / thread call site).
        let (text, color) = MessagingStore.dxBadge(status)
        DXStatusBadge(text: text.isEmpty ? status.label : text, color: color)
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
        case .pending:   return AppColor.pending
        case .accepted:  return AppColor.success
        case .declined:  return AppColor.danger
        case .countered: return AppColor.primary
        case .cancelled: return AppColor.neutral
        case .message:   return .secondary
        }
    }
}

/// Renders message text as Markdown so **bold**, *italic*, and ~~strike~~ work — and highlights
/// @mentions (@everyone + any active dispatcher's name) in the accent color.
func mdText(_ s: String) -> Text {
    guard var a = try? AttributedString(markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return Text(s) }
    Mentions.highlight(&a, names: Mentions.channelNames())
    return Text(a)
}

/// @mention support for the channel + chat. Names can contain spaces/commas ("Lee, Ervin"), so mentions
/// are inserted via a picker (not fragile inline parsing) and matched for highlighting against the known
/// set of active-dispatcher names + "everyone". Pure + testable.
enum Mentions {
    /// The mention-able names: "everyone" + every ACTIVE (published-profile) dispatcher's resolved name.
    static func channelNames() -> [String] {
        ["everyone"] + TradeProfileStore.shared.others.keys.map { participantName($0) }
    }

    /// Insert "@name " into `text`, adding a separating space only when needed.
    static func insert(_ name: String, into text: String) -> String {
        let sep = (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n")) ? "" : " "
        return text + sep + "@\(name) "
    }

    /// The set of names actually @-mentioned in `text` (matched against the known name list, "everyone"
    /// first, longest-first so "Lee, Ervin" wins over a shorter partial). Drives highlighting + (future) push.
    static func mentioned(in text: String, names: [String]) -> Set<String> {
        var found: Set<String> = []
        for name in names.sorted(by: { $0.count > $1.count }) where text.contains("@\(name)") {
            found.insert(name)
        }
        return found
    }

    /// Resolve the @-mentions in `text` to the worker IDs of the active dispatchers named. "@everyone" is
    /// ignored here — every dispatcher already gets the blanket "new channel post" push, so a per-user
    /// mention push is only needed for specifically-named people. Pure (reads the published-profile roster).
    static func mentionedIDs(in text: String) -> [String] {
        let hits = mentioned(in: text, names: channelNames())
        guard !hits.isEmpty else { return [] }
        var ids: Set<String> = []
        for id in TradeProfileStore.shared.others.keys where hits.contains(participantName(id)) {
            ids.insert(id)
        }
        return Array(ids)
    }

    /// Color every "@name" run in `attr` with the accent, longest names first so a full name isn't
    /// clipped by a shorter partial match.
    static func highlight(_ attr: inout AttributedString, names: [String]) {
        for name in names.sorted(by: { $0.count > $1.count }) {
            let token = "@\(name)"
            var cursor = attr.startIndex
            while cursor < attr.endIndex, let r = attr[cursor...].range(of: token) {
                attr[r].foregroundColor = AppColor.primary
                attr[r].inlinePresentationIntent = .stronglyEmphasized
                cursor = r.upperBound
            }
        }
    }
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
    private var ecb = ECBAccountingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var filter = 0   // 0 Intents · 1 Search · 2 ECB · 3 Misc

    private var myID: String { SettingsManager.shared.username }

    /// Incoming one-way ECB offers, sorted by most ECB offered.
    private var ecbRequests: [TradeRequest] {
        store.requests.filter { $0.isECB }.sorted { ($0.ecbAmount ?? 0) > ($1.ecbAmount ?? 0) }
    }

    /// Which tab a request files under (0 Intents · 1 Search · 2 ECB · 3 Qual Swap). Delegates to the
    /// pure `TradeInboxTab.index` (single source of truth, harness-tested).
    private func tabIndex(for r: TradeRequest) -> Int { TradeInboxTab.index(for: r, myID: myID) }
    private func inTab(_ r: TradeRequest) -> Bool { tabIndex(for: r) == filter }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DXSegmented(selection: $filter, options: [
                    .init(0, "Intents"), .init(1, "Search"),
                    .init(2, "ECB (\(ecbRequests.count))"), .init(3, "Qual Swap"),
                ], color: { v in [0: AppColor.heat, 1: AppColor.primary, 2: AppColor.success, 3: AppColor.special][v] })
                .padding()

                DXPaletteStripe(height: 4).padding(.horizontal)

                if filter == 2 { ecbTab } else { requestList }
            }
            .navigationTitle("Trade Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DXCloseButton { dismiss() } } }
            .task { await store.refresh(); await TradeProfileStore.shared.refreshOthers(); await ecb.syncOnLaunch() }   // load peers so status renders (A7/B8 / audit #7) + ECB confirmations
            .refreshable { await store.refresh(); await TradeProfileStore.shared.refreshOthers(); await ecb.syncOnLaunch() }
        }
    }

    /// ECB tab: outgoing offers as tappable folders, incoming offers, and ledger-line confirmations.
    @ViewBuilder private var ecbTab: some View {
        let incomingECB = store.incoming.filter { $0.isECB }.sorted { ($0.ecbAmount ?? 0) > ($1.ecbAmount ?? 0) }
        if store.ecbOffers.isEmpty && incomingECB.isEmpty && ecb.pendingConfirmations.isEmpty {
            ContentUnavailableView("No ECB Offers", systemImage: "star.circle",
                description: Text("One-way ECB trade offers show here, sorted by most ECB offered."))
        } else {
            List {
                if !ecb.pendingConfirmations.isEmpty {
                    Section("ECB confirmations") { ForEach(ecb.pendingConfirmations) { ecbConfirmRow($0) } }
                }
                if !store.ecbOffers.isEmpty {
                    Section("Your ECB offers · tap to see who you sent it to") {
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
    }

    /// Intents / Search / Misc tabs: the usual sectioned request list, filtered to the active tab.
    @ViewBuilder private var requestList: some View {
        let arch = store.archivedRequestIDs
        // Dedupe circular-loop legs to ONE representative card per loop (TRADE-INBOX Stage 3).
        let pending = MessagingStore.dedupeLoops(MessagingStore.active(store.pendingIncoming, archived: arch).filter(inTab))
        let handledIncoming = MessagingStore.dedupeLoops(MessagingStore.active(store.incoming, archived: arch)
            .filter { store.status(of: $0) != .pending && inTab($0) })
        let sent = MessagingStore.dedupeLoops(MessagingStore.active(store.outgoing, archived: arch).filter(inTab))
        let archived = MessagingStore.dedupeLoops(store.requests.filter { arch.contains($0.id) && inTab($0) })
        if pending.isEmpty && handledIncoming.isEmpty && sent.isEmpty && archived.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "tray", description: Text(emptyMessage))
        } else {
            List {
                if !pending.isEmpty { Section("Needs your reply") { ForEach(pending) { row($0) } } }
                if !handledIncoming.isEmpty { Section("Incoming") { ForEach(handledIncoming) { row($0) } } }
                if !sent.isEmpty { Section("Sent") { ForEach(sent) { row($0) } } }
                if !archived.isEmpty { Section("Archived") { ForEach(archived) { row($0) } } }
            }
        }
    }

    private var emptyTitle: String {
        switch filter { case 0: return "No Intent Trades"; case 1: return "No Search Trades"; default: return "No Qual Swaps" }
    }
    private var emptyMessage: String {
        switch filter {
        case 0:  return "Swaps you send or receive from the Intents feed show here."
        case 1:  return "Swaps from Trade Solutions searches show here."
        default: return "Qual-swap trades and bridge requests show here."
        }
    }

    /// A shared ECB line the counterparty logged, awaiting my confirm. Confirm → posts on both ledgers.
    @ViewBuilder private func ecbConfirmRow(_ e: ECBEntry) -> some View {
        let iReceive = e.payeeID == myID
        let other = e.counterpartyName(myID: myID) ?? "A dispatcher"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "banknote").foregroundStyle(AppColor.pending)
                Text("\(other) logged an ECB trade")
                    .font(.subheadline.weight(.semibold))
            }
            Text("\(iReceive ? "You receive" : "You pay") \(ecbText(abs(e.amount))) ECB\(e.memo.isEmpty ? "" : " · \(e.memo)")")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { ecb.confirm(id: e.id) } label: {
                    Label("Confirm", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.small)
                Button(role: .destructive) { ecb.decline(id: e.id) } label: {
                    Label("Decline", systemImage: "xmark.circle").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func row(_ req: TradeRequest) -> some View {
        NavigationLink { ThreadView(request: req) } label: { RequestRow(request: req, myID: myID) }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { Task { await store.cancelRequest(req.id) } } label: {
                    Label("Delete", systemImage: "trash")   // gone forever
                }
                if store.archivedRequestIDs.contains(req.id) {
                    Button { store.unarchiveRequest(req.id) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }.tint(AppColor.primary)
                } else {
                    Button { store.archiveRequest(req.id) } label: { Label("Archive", systemImage: "archivebox") }.tint(AppColor.neutral)
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
                    .font(.subheadline.bold()).foregroundStyle(AppColor.pending)
                Spacer()
                Text("\(offer.requests.count) sent").font(.caption2).foregroundStyle(.secondary)
            }
            if let f = first, !f.giveDayIDs.isEmpty {
                Text("Shifts: " + DayFmt.list(f.giveDayIDs)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(count == 0 ? "No acceptances yet" : "^[\(count) accepted](inflect: true) · tap to confirm")
                .font(.caption.bold()).foregroundStyle(count > 0 ? AppColor.success : .secondary)
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
            } footer: {
                Text("Each shift has its own line. Numbered dots are the people who accepted, in order — #1 is next. Tap a dot to confirm that person (then submit their ECB form), or skip them to pass it to the next person in line.")
            }
            Section("Sent to \(siblings.count) · tap a name to see their card") {
                ForEach(siblings) { recipientRow($0) }
            }
            Section("Shifts") {
                ForEach(days, id: \.self) { day in shiftRow(day) }
            }
        }
        .navigationTitle("ECB Offer")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One recipient you sent this offer to: name, their response so far, and a tap into the exact
    /// card they received (the 1:1 ECB thread).
    private func recipientRow(_ req: TradeRequest) -> some View {
        NavigationLink { ThreadView(request: req) } label: {
            HStack(spacing: 10) {
                Avatar(name: req.toName, id: req.toID, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(req.toName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(recipientStatusText(req)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(status: store.status(of: req))
            }
        }
    }
    private func recipientStatusText(_ req: TradeRequest) -> String {
        switch store.status(of: req) {
        case .accepted:  return "Accepted"
        case .declined:  return "Declined"
        case .countered: return "Replied"
        case .cancelled: return "Cancelled"
        default:         return "No response yet"
        }
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
                                .background(idx == 0 ? AppColor.success : AppColor.primary, in: Circle())
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
        // For a circular loop, the card shows the AGGREGATE of every leg's status (Stage 4); a plain
        // request shows its own status.
        let status: TradeRequestStatus = request.loopID == nil
            ? store.status(of: request)
            : MessagingStore.loopStatus(store.requests.filter { $0.groupKey == request.groupKey }.map { store.status(of: $0) })
        let needsMe = status == .pending && !mine     // action required from me
        let otherName = mine ? request.toName : request.fromName
        let otherID   = mine ? request.toID : request.fromID
        return HStack(alignment: .top, spacing: 12) {
            DXSeatTile(color: TradeColors.color(forParticipant: otherID, myID: myID, orderedPeers: [otherID]), size: 40)
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
                        .font(.caption2.weight(.semibold)).foregroundStyle(AppColor.special)
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
                            .font(.caption2.bold()).foregroundStyle(AppColor.pending)
                    }
                    // 🔥 the incoming request hits one of my own marked intents (U6).
                    if !mine, store.matchesMyIntents(request) {
                        Label("Matches your intent", systemImage: "flame.fill")
                            .font(.caption2.weight(.bold)).foregroundStyle(AppColor.heat)
                    }
                    if needsMe {
                        Label("Your move", systemImage: "exclamationmark.circle.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(AppColor.pending)
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
    @State private var acceptDays: Set<String> = []   // D7: which offered days I'll accept (partial accept)
    @State private var staleDays: Set<String> = []
    @State private var otherProfile: TradeProfile?
    @State private var editingMessage: TradeResponse?
    @State private var editMsgDraft = ""
    @State private var pickerItem: PhotosPickerItem?   // #28: photo attach on 1:1 chat
    @State private var pendingImage: UIImage?
    @State private var showCalendars = false           // 4100a: multi-person card → two-calendar view
    @Environment(\.dismiss) private var dismiss

    init(request: TradeRequest) { self.request = request }

    private var myID: String { SettingsManager.shared.username }
    private var isIncoming: Bool { request.toID == myID }
    private var status: TradeRequestStatus { store.status(of: request) }

    // The trade card, extracted so the List body stays inside the type-checker's budget.
    @ViewBuilder private var tradeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(cardKind, systemImage: cardIcon).font(.subheadline.bold())
                Spacer()
                StatusBadge(status: status)
            }
            Divider()
            if let chain = request.chain, !chain.isEmpty {
                TradeParticipantLines(rows: TradeParticipantLines.rows(chain: chain, myID: myID),
                                      orderedPeers: chain.map(\.fromID))
                Label("Tap to view everyone's calendars", systemImage: "calendar")
                    .font(.caption.weight(.semibold)).foregroundStyle(AppColor.primary)
            } else {
                TradeParticipantLines(rows: twoWayRows, orderedPeers: [request.fromID, request.toID])
            }
            if request.isECB, let ecb = request.ecbAmount {
                Label("\(ecbText(ecb)) ECB offered", systemImage: "star.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(AppColor.pending)
            }
            if !request.note.isEmpty { Text(request.note).font(.subheadline) }
        }
    }
    private var cardKind: String {
        let people = request.chain.map(distinctParticipants(in:)) ?? 2
        return tradeTypeLabel(distinctPeople: people, isOneWayECB: request.isECB)
    }
    private var cardIcon: String {
        request.chain != nil ? "arrow.triangle.2.circlepath" : (request.isECB ? "star.circle.fill" : "arrow.left.arrow.right")
    }
    private var twoWayRows: [(id: String, name: String, isMe: Bool, days: [String])] {
        var r: [(id: String, name: String, isMe: Bool, days: [String])] = [
            (id: request.fromID, name: request.fromID == myID ? "You" : request.fromName,
             isMe: request.fromID == myID, days: request.giveDayIDs)
        ]
        if !(request.takeDayIDs.isEmpty && request.giveDayIDs.isEmpty) {
            r.append((id: request.toID, name: request.toID == myID ? "You" : request.toName,
                      isMe: request.toID == myID, days: request.takeDayIDs))
        }
        return r
    }
    // D7: all day-IDs in the offer (both sides) — the pool you can partially accept.
    private var allTradeDays: Set<String> { Set(request.giveDayIDs + request.takeDayIDs) }
    private var sortedTradeDays: [String] { allTradeDays.sorted() }

    /// Reskin helper: a List section rendered as ONE app-style card (`.dxCard()`) on a clear row — so the
    /// detail reads as the app's cards rather than a grouped iOS Form. (D7-SKIN.)
    @ViewBuilder private func cardSection<Content: View>(_ header: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if let header { Text(header).font(.subheadline.weight(.semibold)) }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dxCard()
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// The incoming-pending action card: pick days (partial accept), note, Accept/Counter/Decline.
    @ViewBuilder private var respondCard: some View {
        if allTradeDays.count > 1 {
            Text("Days to accept").font(.subheadline.weight(.semibold))
            ForEach(sortedTradeDays, id: \.self) { d in
                Button {
                    if acceptDays.contains(d) { acceptDays.remove(d) } else { acceptDays.insert(d) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: acceptDays.contains(d) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(acceptDays.contains(d) ? AppColor.success : .secondary)
                        Text(DayFmt.nice(d)).foregroundStyle(.primary)
                        Spacer()
                        Text(request.giveDayIDs.contains(d) ? "you get" : "you give")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Divider()
        }
        TextField("Optional note…", text: $replyNote, axis: .vertical).textFieldStyle(.roundedBorder)
        let acceptingAll = acceptDays == allTradeDays || allTradeDays.count <= 1
        Button { acceptingAll ? respond(.accepted) : counter(acceptDays) } label: {
            Label(acceptingAll ? "Accept" : "Counter with \(acceptDays.count) day\(acceptDays.count == 1 ? "" : "s")",
                  systemImage: acceptingAll ? "checkmark.circle.fill" : "arrow.uturn.left.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(AppColor.success)
        .disabled(!staleDays.isEmpty || acceptDays.isEmpty)
        HStack {
            Button { respond(.countered) } label: { Label("Message", systemImage: "bubble.left").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
            Button(role: .destructive) { respond(.declined) } label: { Label("Decline", systemImage: "xmark.circle").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).tint(AppColor.danger)
        }
    }

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
                tradeCard
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dxCard()
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { if request.chain?.isEmpty == false { showCalendars = true } }
            }
            .sheet(isPresented: $showCalendars) {
                if let chain = request.chain, !chain.isEmpty {
                    PackageDetailView(package: PackageDetailView.fromChain(chain), onPropose: { _ in }, onExecute: {}, readOnly: true)
                        .magnifiable()
                }
            }

            qualSwapSection

            cardSection {
                Button { openDispatchDraft(subject: "", body: "") } label: {
                    Label("New email to dispatch DL", systemImage: "envelope").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).foregroundStyle(AppColor.primary)
                Text("Opens a blank message in Outlook to \(SettingsManager.shared.tradeEmailDL).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let p = otherProfile, (p.phone != nil || p.bestEmail != nil) {
                cardSection("Contact \(isIncoming ? request.fromName : request.toName)") {
                    ContactButtons(profile: p)
                }
            }

            Section("Conversation") {
                auditRow(icon: "paperplane.fill", tint: AppColor.primary,
                         who: request.fromName, what: "proposed this trade", when: request.createdAt,
                         note: request.note)
                ForEach(store.responses(for: request.id).sorted { $0.createdAt < $1.createdAt }) { r in
                    if r.statusValue == .message {
                        // Free-form chat → iMessage-style bubble (§4): mine trailing/blue, theirs leading.
                        let mine = r.responderID == myID
                        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                            DXChatBubble(text: r.isDeleted ? "[Deleted]" : r.note, mine: mine)
                                .contextMenu {
                                    if !r.isDeleted && mine {
                                        Button { editingMessage = r; editMsgDraft = r.note } label: { Label("Edit", systemImage: "pencil") }
                                        Button(role: .destructive) { Task { await store.softDeleteMessage(r) } } label: { Label("Delete", systemImage: "trash") }
                                    }
                                }
                            if !r.isDeleted, let b64 = r.imageBase64, let ui = PostImage.decode(b64) {
                                ExpandableImage(image: ui, maxHeight: 180).frame(maxWidth: 240)   // B4-11: tap to zoom
                            }
                            if !r.isDeleted {
                                ReactionChips(reactions: r.reactions ?? []) { e in Task { await store.react(to: r, emoji: e) } }
                            }
                            if r.editedAt != nil { Text("edited").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
                        .listRowSeparator(.hidden)
                    } else {
                        auditRow(icon: r.statusValue.icon, tint: r.statusValue.tint,
                                 who: r.responderID == myID ? "You" : r.responderName,
                                 what: r.statusValue.label.lowercased(), when: r.createdAt, note: r.note)
                    }
                }
            }

            if isIncoming && status != .pending {
                cardSection {
                    Label("You replied: \(status.label)", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(status == .declined ? AppColor.danger : AppColor.success)
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
                                    .foregroundStyle(pos <= MessagingStore.ecbQueueCap ? AppColor.success : AppColor.pending)
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
                            .foregroundStyle(AppColor.success)
                    } else {
                        Text("\(request.fromName) is submitting the \(ecbText(request.ecbAmount ?? 0))-ECB form. Confirm once it lands in your account.")
                            .font(.subheadline)
                        Button { confirmReceived() } label: {
                            Label("Confirm ECB received", systemImage: "star.circle.fill")
                        }
                        .buttonStyle(.borderedProminent).tint(AppColor.pending)
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
                    .tint(AppColor.success).disabled(ecbSelectedDays.isEmpty)
                    Button(role: .destructive) { respond(.declined) } label: { Label("Decline all", systemImage: "xmark.circle") }
                }
            } else if isIncoming && status == .pending {
                cardSection { respondCard }
            } else if !isIncoming && status == .pending {
                cardSection {
                    Button(role: .destructive) {
                        Task { await store.cancelRequest(request.id); dismiss() }
                    } label: { Label("Cancel request", systemImage: "trash").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).tint(AppColor.danger)
                }
            }
        }
        .scrollContentBackground(.hidden)   // drop the grouped-grey chrome; cards float on the app background
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Swap with \(isIncoming ? request.fromName : request.toName)")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Edit message", isPresented: Binding(get: { editingMessage != nil }, set: { if !$0 { editingMessage = nil } })) {
            TextField("Message", text: $editMsgDraft)
            Button("Save") { if let m = editingMessage { Task { await store.editMessage(m, newText: editMsgDraft) } }; editingMessage = nil }
            Button("Cancel", role: .cancel) { editingMessage = nil }
        }
        // Chat is always available — talk it out regardless of accept/decline state.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
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
                    Task { if let data = try? await item.loadTransferable(type: Data.self) { pendingImage = UIImage(data: data) } }
                }
                SlackComposer(placeholder: "Message \(isIncoming ? request.fromName : request.toName)",
                              text: $chatDraft, showFormatBar: false,
                              canSendWhenEmpty: pendingImage != nil) {
                    let text = chatDraft; chatDraft = ""
                    let img = pendingImage; pendingImage = nil; pickerItem = nil
                    Task {
                        let b64 = img.flatMap { PostImage.encode($0) }
                        await store.postMessage(to: request, text: text, imageBase64: b64)
                    }
                }
            }
        }
        .task {
            if acceptDays.isEmpty { acceptDays = allTradeDays }   // D7: default = accept every offered day
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
        case .waiting:                 return AppColor.pending
        case .offersOpen, .offersFull: return AppColor.primary
        case .finalized:               return AppColor.success
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
                        Label("You accepted this qual swap.", systemImage: "checkmark.seal.fill").foregroundStyle(AppColor.success)
                    } else if leg.acceptIsOpen && !leg.status.isTerminal {
                        if let cand = leg.candidates.first(where: { $0.workerID == myID }) {
                            Text("You'd move onto desk \(leg.giveDesk) (\(leg.giveQual)); your desk \(cand.desk) (\(cand.qual)) goes to \(leg.takerName).")
                                .font(.caption)
                        }
                        Button { Task { await store.acceptQualSwapBridge(request) } } label: {
                            Label("Accept qual swap", systemImage: "checkmark.circle.fill")
                        }.tint(AppColor.success)
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
                                Label("Chosen", systemImage: "checkmark.seal.fill").foregroundStyle(AppColor.success)
                            } else if !leg.status.isTerminal {
                                Button("Choose") { Task { await store.finalizeQualSwap(request, chosenWorkerID: a.workerID) } }
                                    .buttonStyle(.borderedProminent).tint(AppColor.success)
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

                // B2: once a bridge is finalized, the giver can fuse this qual swap with their clean
                // base trade on the same day into ONE request.
                if role == .giver, let base = store.mergeBase(for: request) {
                    Button {
                        Task {
                            await store.mergeRequests(base: base, bridge: request)
                            dismiss()   // both originals archived; the merged card is in the inbox
                        }
                    } label: {
                        Label("Merge with base trade", systemImage: "arrow.triangle.merge")
                    }
                    .tint(AppColor.special)
                    Text("Combines this qual swap with your clean trade on \(prettyDay(leg.giveShiftDayID)) into a single request.")
                        .font(.caption2).foregroundStyle(.secondary)
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

    /// D7 partial accept — counter back to the sender with only the selected days.
    private func counter(_ days: Set<String>) {
        Task {
            await store.counterWithSubset(request, keepDays: days)
            replyNote = ""
            WidgetData.update()
            dismiss()   // the trimmed counter is now in the sender's inbox
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
    @State private var collapsedReplies: Set<String> = []   // #9: per-comment subtree collapse
    @State private var replyingTo: String? = nil            // #9: reply ID an inline composer targets
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

    /// Who you can @-mention: every ACTIVE (published-profile) dispatcher, by resolved name.
    private var mentionPeople: [(id: String, name: String)] {
        TradeProfileStore.shared.others.keys
            .map { (id: $0, name: participantName($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
                DXSegmented(selection: $channel, options: [
                    .init("general", "# general"), .init("trades", "# trades"), .init("feedback", "# feedback"),
                ], color: { v in ["general": AppColor.primary, "trades": AppColor.special, "feedback": AppColor.pending][v] })
                .padding(.horizontal).padding(.top, 6).padding(.bottom, 7)
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
            }
            // B4-13: pin the composer in a bottom inset — stable identity OUTSIDE the scrolling List so
            // tapping the Photo picker presents cleanly instead of re-laying-out the channel (which
            // collapsed expanded threads + swallowed the tap). Mirrors ThreadView's working composer.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Image(systemName: "photo").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let img = pendingImage {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 30, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Button { pendingImage = nil; pickerItem = nil } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            Text("Photo attached").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.top, 6)
                    SlackComposer(placeholder: "Message #\(channel)", text: $draft,
                                  mentionPeople: mentionPeople, sendTint: AppColor.heat) {   // §5: channel accent
                        let text = draft; draft = ""
                        let img = pendingImage; pendingImage = nil; pickerItem = nil
                        Task {
                            let b64 = img.flatMap { PostImage.encode($0) }
                            await store.post(text: text, channel: channel, imageBase64: b64)
                        }
                    }
                }
                .background(.bar)
                .onChange(of: pickerItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) { pendingImage = UIImage(data: data) }
                    }
                }
            }
            .navigationTitle(channelMeta.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DXCloseButton { dismiss() } } }
            .task { await store.refresh(); await TradeProfileStore.shared.refreshOthers() }   // E2: load peers so statuses render
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
                    .font(.caption2.weight(.semibold)).foregroundStyle(AppColor.heat).padding(.leading, 46)
            }
            SlackMessageRow(name: post.authorName, authorID: post.authorID,
                            timestamp: post.createdAt, message: post.text,
                            status: authorStatus(post.authorID)) {   // E2: status to the LEFT of the name
                postMenu(post)
            }
            if let b64 = post.imageBase64, let ui = PostImage.decode(b64) {
                ExpandableImage(image: ui, maxHeight: 220, cornerRadius: 10)   // B4-11: tap to zoom
                    .padding(.leading, 46)
            }
            reactionsBar(post)

            if !reps.isEmpty && !isOpen {
                Button { expanded.insert(post.id) } label: {
                    // Reddit-style collapse chevron: ▸ to expand.
                    Label("^[\(reps.count) reply](inflect: true)", systemImage: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain).foregroundStyle(AppColor.primary).padding(.leading, 46)
            }

            if isOpen {
                HStack(spacing: 8) {
                    // Reddit-style threadline — a tappable rail that collapses the whole thread.
                    Capsule().fill(Color.accentColor.opacity(0.35)).frame(width: 2.5)
                        .contentShape(Rectangle())
                        .onTapGesture { expanded.remove(post.id) }
                    VStack(alignment: .leading, spacing: 4) {
                        if !reps.isEmpty {
                            Button { expanded.remove(post.id) } label: {
                                Label("Hide ^[\(reps.count) reply](inflect: true)", systemImage: "chevron.up")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        threadedReplies(post: post, reps: reps)
                        // Top-level reply to the post (parentReplyID nil).
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

    /// #9: the post's replies rendered as a Reddit-style nested tree — pre-order, indented per depth,
    /// with per-comment Reply + collapse. Descendants of a collapsed comment are hidden.
    @ViewBuilder private func threadedReplies(post: BroadcastPost, reps: [BroadcastReply]) -> some View {
        let tree = ReplyThread.flatten(reps)
        let hiddenByCollapse = collapsedReplies.reduce(into: Set<String>()) { acc, id in
            acc.formUnion(ReplyThread.subtreeIDs(of: id, in: reps))
        }
        ForEach(tree.filter { !hiddenByCollapse.contains($0.reply.id) }) { tr in
            threadedReplyRow(tr, post: post, reps: reps)
        }
    }

    private func threadedReplyRow(_ tr: ThreadedReply, post: BroadcastPost, reps: [BroadcastReply]) -> some View {
        let depth = min(tr.depth, 6)                                  // cap indentation on deep chains
        let childCount = ReplyThread.subtreeIDs(of: tr.reply.id, in: reps).count
        let isCollapsed = collapsedReplies.contains(tr.reply.id)
        return HStack(alignment: .top, spacing: 5) {
            // One threadline rail per nesting level — tap a rail to collapse this comment's subtree.
            ForEach(0..<depth, id: \.self) { _ in
                Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                replyRow(tr.reply)
                HStack(spacing: 14) {
                    Button { replyingTo = (replyingTo == tr.reply.id ? nil : tr.reply.id) } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left").font(.caption2.weight(.semibold))
                    }
                    if childCount > 0 {
                        Button {
                            if isCollapsed { collapsedReplies.remove(tr.reply.id) } else { collapsedReplies.insert(tr.reply.id) }
                        } label: {
                            Label(isCollapsed ? "Show ^[\(childCount) reply](inflect: true)" : "Hide",
                                  systemImage: isCollapsed ? "chevron.right" : "chevron.down").font(.caption2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 32)
                if replyingTo == tr.reply.id {
                    BroadcastReplyComposer(isAuthor: store.isMine(post)) { text, isPublic, image in
                        Task { await store.addReply(to: post, text: text, isPublic: isPublic, imageBase64: image, parentReplyID: tr.reply.id) }
                        replyingTo = nil
                    }
                }
            }
        }
    }

    private func replyRow(_ r: BroadcastReply) -> some View {
        let metaText = (r.isPublic ? "public" : "private") + (r.editedAt != nil ? " · edited" : "")
        return VStack(alignment: .leading, spacing: 4) {
            SlackMessageRow(name: r.authorID == myID ? "You" : r.authorName, authorID: r.authorID,
                            timestamp: r.createdAt, message: r.isDeleted ? "[Deleted]" : r.text,
                            meta: (metaText, r.isPublic ? AppColor.primary : AppColor.pending),
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
                ExpandableImage(image: ui, maxHeight: 180)   // B4-11: tap to zoom
                    .padding(.leading, 34)
            }
            if !r.isDeleted {
                ReactionChips(reactions: r.reactions ?? []) { e in Task { await store.react(to: r, emoji: e) } }
                    .padding(.leading, 34)
            }
        }
    }

    private func actionRow(_ post: BroadcastPost) -> some View {
        // The old "Send trade request" shortcut was removed — it fired an EMPTY request (no days) at the
        // poster, which was vague and duplicated the real trade flow. Reply in-thread or propose a real
        // trade from Trades instead.
        HStack(spacing: 14) {
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
    @State private var showPicker = false   // B4-13: drive the picker via the isPresented modifier

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
                DXSegmented(selection: $isPublic, options: [.init(true, "Public"), .init(false, "Private")])
                    .fixedSize()
                FormatBar(text: $draft)
                Button { showPicker = true } label: {
                    Image(systemName: "photo").font(.subheadline).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    let t = draft, img = pendingImage
                    draft = ""; pendingImage = nil; pickerItem = nil
                    onSend(t, isPublic, img.flatMap { PostImage.encode($0) })
                } label: {
                    Image(systemName: "paperplane.circle.fill").font(.title2)
                        .foregroundStyle(canSend ? AppColor.heat : .secondary)   // §5 channel accent
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.vertical, 4)
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
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

// MARK: - Side dock
// `MessagingDock` now lives in `DXMessagingDock.swift` (glazed `.dxControlTile()` buttons).
// The former flat-tile version was removed here to avoid a duplicate declaration.
