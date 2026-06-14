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
        }
    }
    var tint: Color {
        switch self {
        case .pending:   return .orange
        case .accepted:  return .green
        case .declined:  return .red
        case .countered: return .blue
        case .cancelled: return .gray
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

    private var myID: String { SettingsManager.shared.username }

    var body: some View {
        NavigationStack {
            Group {
                if store.requests.isEmpty {
                    ContentUnavailableView("No Trade Requests", systemImage: "tray",
                        description: Text("Swaps you propose or receive show up here."))
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

struct RequestRow: View {
    let request: TradeRequest
    let myID: String
    private var store = MessagingStore.shared

    init(request: TradeRequest, myID: String) { self.request = request; self.myID = myID }

    var body: some View {
        let mine = request.fromID == myID            // I sent it
        let status = store.status(of: request)
        let needsMe = status == .pending && !mine     // action required from me
        let waiting: String = {
            if status == .pending { return mine ? "Awaiting their reply" : "Awaiting your reply" }
            return mine ? "They replied" : "You replied"
        }()
        return HStack(spacing: 10) {
            Image(systemName: status.icon)
                .font(.title3).foregroundStyle(status.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(mine ? "To \(request.toName)" : "From \(request.fromName)")
                    .font(.subheadline).bold()
                Text("\(waiting) · \(status.label)")
                    .font(.caption).foregroundStyle(needsMe ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if !request.note.isEmpty {
                    Text(request.note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if needsMe {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ThreadView: View {
    let request: TradeRequest
    private var store = MessagingStore.shared
    @State private var replyNote = ""
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
            Section("Proposal") {
                LabeledContent("From", value: request.fromName)
                LabeledContent("To", value: request.toName)
                if !request.takeDayIDs.isEmpty {
                    leg("\(request.fromName) takes", DayFmt.list(request.takeDayIDs))
                }
                if !request.giveDayIDs.isEmpty {
                    leg("\(request.toName) takes", DayFmt.list(request.giveDayIDs))
                }
                if !request.note.isEmpty {
                    Text(request.note).font(.subheadline)
                }
                HStack { Spacer(); StatusBadge(status: status) }
            }

            if let p = otherProfile, (p.phone != nil || p.bestEmail != nil) {
                Section("Contact \(isIncoming ? request.fromName : request.toName)") {
                    ContactButtons(profile: p)
                }
            }

            let replies = store.responses(for: request.id)
            if !replies.isEmpty {
                Section("Replies") {
                    ForEach(replies) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(r.responderID == myID ? "You" : r.responderName).font(.caption.bold())
                                Spacer()
                                StatusBadge(status: r.statusValue)
                            }
                            if !r.note.isEmpty { Text(r.note).font(.subheadline) }
                            Text(r.createdAt, style: .relative)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
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

            if isIncoming && status == .pending {
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
        .task {
            staleDays = await TradeMatcher.staleDays(
                fromID: request.fromID, toID: request.toID,
                giveDayIDs: request.giveDayIDs, takeDayIDs: request.takeDayIDs)
            let otherID = isIncoming ? request.fromID : request.toID
            otherProfile = await TradeProfileStore.shared.fetchProfile(forWorker: otherID)
        }
    }

    private func leg(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline)
        }
    }

    private func respond(_ status: TradeRequestStatus) {
        Task {
            await store.respond(to: request, status: status, note: replyNote.trimmingCharacters(in: .whitespacesAndNewlines))
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

    private var myID: String { SettingsManager.shared.username }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                composer
                Divider()
                if store.broadcasts.isEmpty {
                    ContentUnavailableView("No Posts Yet", systemImage: "megaphone",
                        description: Text("Post what you're looking to trade away — everyone sees it. Posts expire on their own; delete yours anytime."))
                        .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.broadcasts) { post in postRow(post) }
                    }
                    .listStyle(.plain)
                    .refreshable { await store.refresh() }
                }
            }
            .navigationTitle("Trade Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.refresh() }
            .alert("Sent", isPresented: Binding(get: { respondedNote != nil }, set: { if !$0 { respondedNote = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(respondedNote ?? "") }
            .sheet(item: $editingPost) { post in EditPostSheet(post: post) }
        }
    }

    private var composer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                TextField("Trading away…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let text = draft
                    draft = ""
                    Task { await store.post(text: text) }
                } label: { Image(systemName: "paperplane.fill") }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                FormatBar(text: $draft)
                Spacer()
                Text("**bold** *italic* ~~strike~~").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func postRow(_ post: BroadcastPost) -> some View {
        let isOpen = expanded.contains(post.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(post.authorName).font(.subheadline.bold())
                Spacer()
                Text(post.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            mdText(post.text)
                .font(.subheadline)
                .lineLimit(isOpen ? nil : 2)
            if isOpen {
                let reps = store.visibleReplies(for: post)
                if !reps.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(reps) { r in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: r.isPublic ? "globe" : "lock.fill")
                                    .font(.system(size: 9)).foregroundStyle(r.isPublic ? .blue : .orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(r.authorID == myID ? "You" : r.authorName).font(.caption.bold())
                                        Text(r.isPublic ? "public" : "private")
                                            .font(.caption2).foregroundStyle(r.isPublic ? .blue : .orange)
                                        Text(r.createdAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    mdText(r.text).font(.caption)
                                }
                                Spacer(minLength: 0)
                                if r.authorID == myID {
                                    Button(role: .destructive) {
                                        Task { await store.deleteReply(r.id) }
                                    } label: { Image(systemName: "xmark.circle.fill").font(.caption2) }
                                        .buttonStyle(.borderless)
                                } else if dev.unlocked {
                                    Button(role: .destructive) {
                                        Task { await store.hide(r.id) }
                                    } label: { Image(systemName: "eye.slash.fill").font(.caption2) }
                                        .buttonStyle(.borderless)
                                }
                            }
                            .padding(6)
                            .background((r.isPublic ? Color.blue : Color.orange).opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.leading, 6).padding(.top, 2)
                }

                BroadcastReplyComposer(isAuthor: store.isMine(post)) { text, isPublic in
                    Task { await store.addReply(to: post, text: text, isPublic: isPublic) }
                }

                HStack(spacing: 14) {
                    if store.isMine(post) {
                        Button { editingPost = post } label: {
                            Label("Edit", systemImage: "pencil").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            Task { await store.deletePost(post.id) }
                        } label: { Label("Delete", systemImage: "trash").font(.caption) }
                            .buttonStyle(.borderless)
                    } else {
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
                    // Dev moderation — available on EVERY post when unlocked.
                    if dev.unlocked {
                        Button(role: .destructive) {
                            Task { await store.hide(post.id) }
                        } label: { Label("Hide (dev)", systemImage: "eye.slash.fill").font(.caption) }
                            .buttonStyle(.borderless)
                            .tint(.red)
                    }
                    Spacer()
                    Text("Expires \(post.expiresAt, style: .relative)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isOpen { expanded.remove(post.id) } else { expanded.insert(post.id) }
        }
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
        HStack(spacing: 10) {
            dockButton(system: "tray.full.fill", badge: store.pendingIncoming.count) { showInbox = true }
            dockButton(system: "megaphone.fill", badge: 0) { showChannel = true }
        }
    }

    private func dockButton(system: String, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.body)
                .frame(width: 40, height: 40)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().stroke(.quaternary, lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Color.red, in: Circle())
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .shadow(radius: 3, y: 1)
    }
}
