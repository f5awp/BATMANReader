// DirectMessageViews.swift
// The Messages side of "Channels & Messages": a 1:1 conversation list + chat thread,
// plus a compose sheet to start a new conversation. Built on the dedicated DM platform
// (DirectMessageStore) — NOT the trade inbox. Reuses the shared chat chrome (DXChatBubble,
// SlackComposer, ReactionChips, ExpandableImage) so it feels consistent with the channels.

import PhotosUI
import SwiftUI

// MARK: - Conversation list (Messages tab)

/// Lists the user's DM threads, newest-activity first, with unread dots. Embedded inside
/// ChannelView's NavigationStack (the "Channels & Messages" screen).
struct ConversationListView: View {
    private var store = DirectMessageStore.shared
    @State private var showCompose = false

    private var myID: String { SettingsManager.shared.username }

    var body: some View {
        Group {
            if store.conversations.isEmpty {
                ContentUnavailableView("No Messages Yet", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start a direct message with a dispatcher — from here or the Dispatcher tab."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(DMLogic.sorted(store.conversations)) { conv in
                        NavigationLink { ConversationView(conversation: conv) } label: {
                            ConversationRow(conversation: conv, unread: store.hasUnread(conv))
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.plain)
                .refreshable { await store.refresh(); await TradeProfileStore.shared.refreshOthers() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { showCompose = true } label: {
                Label("New Message", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(AppColor.primary)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
        }
        .task { await store.refresh(); await TradeProfileStore.shared.refreshOthers() }
        .sheet(isPresented: $showCompose) { NewConversationSheet() }
    }
}

/// One conversation row: avatar, other person's name (+ 🤖 if inactive), latest-message preview, time, unread dot.
struct ConversationRow: View {
    let conversation: Conversation
    let unread: Bool
    private var myID: String { SettingsManager.shared.username }

    var body: some View {
        let otherID = conversation.otherID(myID: myID)
        let name = participantName(otherID)
        HStack(spacing: 10) {
            Avatar(name: name, id: otherID, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name + botSuffix(otherID)).font(.dsCardTitle).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(DayFmt.relative(conversation.lastMessageAt)).font(.caption2).foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    Text(conversation.lastMessagePreview.isEmpty ? "No messages yet" : conversation.lastMessagePreview)
                        .font(.subheadline)
                        .foregroundStyle(unread ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if unread { Circle().fill(AppColor.primary).frame(width: 9, height: 9) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Conversation (1:1 chat thread)

struct ConversationView: View {
    let conversation: Conversation
    private var store = DirectMessageStore.shared
    @State private var draft = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var pendingImage: UIImage?
    @State private var editing: DirectMessage?
    @State private var editDraft = ""

    private var myID: String { SettingsManager.shared.username }
    private var otherID: String { conversation.otherID(myID: myID) }
    private var otherName: String { participantName(otherID) }
    private var quickEmojis: [String] { ["👍", "❤️", "😂", "🙏", "👀"] }

    var body: some View {
        VStack(spacing: 0) {
            if let status = participantStatus(otherID) {
                HStack(spacing: 6) {
                    Image(systemName: "quote.bubble").font(.caption2).foregroundStyle(AppColor.primary)
                    Text(status).font(.caption).italic().foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
                Divider()
            }
            messageList
        }
        .navigationTitle(otherName)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { composer }
        .task { store.markSeen(conversation.id); await store.refresh() }
        .onChange(of: store.messages.count) { store.markSeen(conversation.id) }
        .alert("Edit message", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Message", text: $editDraft)
            Button("Save") { if let m = editing { Task { await store.edit(m, newText: editDraft) } }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        }
        .alert("Can't message \(store.blockedRecipient ?? "") right now",
               isPresented: Binding(get: { store.blockedRecipient != nil },
                                    set: { if !$0 { store.blockedRecipient = nil } })) {
            Button("OK", role: .cancel) { store.blockedRecipient = nil }
        } message: { Text("They're not on the app yet, so they can't receive messages. You'll be able to once they join.") }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.messages(in: conversation.id)) { m in
                        messageBubble(m).id(m.id)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .onChange(of: store.messages.count) {
                if let last = store.messages(in: conversation.id).last {
                    withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = store.messages(in: conversation.id).last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func messageBubble(_ m: DirectMessage) -> some View {
        let mine = m.senderID == myID
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            DXChatBubble(text: m.isDeleted ? "[Deleted]" : m.text, mine: mine)
                .contextMenu {
                    if !m.isDeleted {
                        ForEach(quickEmojis, id: \.self) { e in
                            Button { Task { await store.react(to: m, emoji: e) } } label: { Text(e) }
                        }
                        if mine {
                            Divider()
                            Button { editing = m; editDraft = m.text } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { Task { await store.softDelete(m) } } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            if !m.isDeleted, let b64 = m.imageBase64, let ui = PostImage.decode(b64) {
                ExpandableImage(image: ui, maxHeight: 180).frame(maxWidth: 240)
            }
            if !m.isDeleted {
                ReactionChips(reactions: m.reactions ?? []) { e in Task { await store.react(to: m, emoji: e) } }
            }
            if m.editedAt != nil && !m.isDeleted { Text("edited").font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            if let img = pendingImage {
                HStack(spacing: 8) {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("Photo attached").font(.caption2).foregroundStyle(.tertiary)
                    Button { pendingImage = nil; pickerItem = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "photo").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.leading, 12)
                SlackComposer(placeholder: "Message \(otherName)", text: $draft, showFormatBar: false,
                              canSendWhenEmpty: pendingImage != nil) {
                    let text = draft; draft = ""
                    let img = pendingImage; pendingImage = nil; pickerItem = nil
                    Task {
                        let b64 = img.flatMap { PostImage.encode($0) }
                        await store.send(toID: otherID, name: otherName, text: text, imageBase64: b64)
                    }
                }
            }
        }
        .background(.bar)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { if let data = try? await item.loadTransferable(type: Data.self) { pendingImage = UIImage(data: data) } }
        }
    }
}

// MARK: - Compose (start a new conversation)

/// Searchable list of dispatchers to start a DM with. Only ACTIVE accounts can receive messages, so
/// inactive (🤖) dispatchers are shown disabled with a hint.
struct NewConversationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var people: [(id: String, name: String)] = []
    @State private var openConv: Conversation?
    private var myID: String { SettingsManager.shared.username }

    private var filtered: [(id: String, name: String)] {
        people.filter { p in
            query.isEmpty
                || p.name.localizedCaseInsensitiveContains(query)
                || p.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                .padding(.horizontal).padding(.vertical, 8)
                Divider()
                List {
                    if people.isEmpty {
                        ContentUnavailableView("Loading roster…", systemImage: "person.2")
                    } else {
                        ForEach(filtered, id: \.id) { p in
                            let active = participantHasProfile(p.id)
                            Button {
                                openConv = DirectMessageStore.shared.conversation(withID: p.id, name: p.name)
                            } label: {
                                HStack(spacing: 10) {
                                    Avatar(name: p.name, id: p.id, size: 34)
                                    Text(p.name + botSuffix(p.id)).font(.subheadline)
                                    Spacer()
                                    if !active {
                                        Text("Not on the app").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!active)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DXCloseButton { dismiss() } } }
            .navigationDestination(item: $openConv) { conv in ConversationView(conversation: conv) }
            .task { await load() }
        }
    }

    private func load() async {
        if !TradeFeedCache.shared.allDispatchers.isEmpty {
            people = TradeFeedCache.shared.allDispatchers.filter { $0.id != myID }.sorted { $0.name < $1.name }
            return
        }
        let now = Date(); let end = Calendar.current.date(byAdding: .month, value: 12, to: now) ?? now
        let entries = await RosterStore.shared.entries(from: now, to: end)
        let me = myID
        var seen = Set<String>(); var out: [(id: String, name: String)] = []
        for e in entries where e.workerID != me && seen.insert(e.workerID).inserted {
            out.append((e.workerID, TradeNames.resolved(displayName: nil, rosterName: e.workerName, workerID: e.workerID)))
        }
        people = out.sorted { $0.name < $1.name }
    }
}
