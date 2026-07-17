// DirectMessages.swift
// A PROPER 1:1 direct-message platform — its OWN schema, distinct from the trade
// inbox (`TradeRequest`/`TradeResponse`). A conversation is a thread between two
// dispatchers; messages hang off it (text, photo, emoji reactions, edit/soft-delete).
//
// Backend is swappable behind `DirectMessageService` — Local (UserDefaults JSON) for
// no-account testing, CloudKit (public DB) when iCloud sync is on. Mirrors the
// Messaging.swift pattern so both share the `Reaction` model + FetchMerge behavior.
//
// CloudKit note: two record types — `DMConversation` and `DirectMessage`. Each stores
// the whole model JSON-encoded in a `payload` field, with a few flat queryable fields
// (participantIDs / toID / senderID / conversationID). New record types must be
// deployed in the CloudKit Console before sync works (see CLOUDKIT_DEPLOY.md).

import CloudKit
import Foundation
import Observation

// MARK: - Models

/// A 1:1 direct-message conversation. Its `id` is DETERMINISTIC from the two participant IDs
/// (`dm_<lowerID>_<higherID>`) so both people share ONE thread record — no duplicate threads.
struct Conversation: Sendable, Codable, Identifiable, Hashable {
    let id: String
    let participantIDs: [String]      // exactly two, sorted ascending
    let participantNames: [String]    // parallel to participantIDs (best-known names at creation)
    let createdAt: Date
    var lastMessageAt: Date
    var lastMessagePreview: String

    // EXPLICIT init — freezes the construction signature so adding fields later doesn't churn callers.
    init(id: String, participantIDs: [String], participantNames: [String],
         createdAt: Date, lastMessageAt: Date, lastMessagePreview: String) {
        self.id = id; self.participantIDs = participantIDs; self.participantNames = participantNames
        self.createdAt = createdAt; self.lastMessageAt = lastMessageAt
        self.lastMessagePreview = lastMessagePreview
    }

    /// The canonical id for a 1:1 between two workers (order-independent) — the single source of truth
    /// both devices agree on, so A→B and B→A resolve to the same thread record.
    static func canonicalID(_ a: String, _ b: String) -> String {
        let pair = [a, b].sorted()
        return "dm_\(pair[0])_\(pair[1])"
    }
    /// The OTHER participant's id, given mine.
    func otherID(myID: String) -> String { participantIDs.first { $0 != myID } ?? myID }
    /// The OTHER participant's name, given mine (falls back to the stored name / first).
    func otherName(myID: String) -> String {
        guard let idx = participantIDs.firstIndex(where: { $0 != myID }),
              idx < participantNames.count else { return participantNames.first ?? "" }
        return participantNames[idx]
    }
    func involves(_ workerID: String) -> Bool { participantIDs.contains(workerID) }
}

/// One message in a conversation. Its own schema — NOT a `TradeResponse`. Carries the same chat
/// capabilities as the trade chat (reactions, image, edit/soft-delete) so the UI feels consistent.
struct DirectMessage: Sendable, Codable, Identifiable, Hashable {
    let id: String
    let conversationID: String
    let senderID: String
    let senderName: String
    let toID: String            // recipient (1:1) — flat + queryable, drives the "new DM" push subscription
    let text: String
    let createdAt: Date
    var editedAt: Date? = nil
    var deleted: Bool? = nil
    var reactions: [Reaction]? = nil
    var imageBase64: String? = nil

    // EXPLICIT init — freezes the construction signature (stale-incremental-link fix).
    init(id: String, conversationID: String, senderID: String, senderName: String, toID: String,
         text: String, createdAt: Date, editedAt: Date? = nil, deleted: Bool? = nil,
         reactions: [Reaction]? = nil, imageBase64: String? = nil) {
        self.id = id; self.conversationID = conversationID; self.senderID = senderID
        self.senderName = senderName; self.toID = toID; self.text = text; self.createdAt = createdAt
        self.editedAt = editedAt; self.deleted = deleted; self.reactions = reactions
        self.imageBase64 = imageBase64
    }

    var isDeleted: Bool { deleted == true }
}

// MARK: - Pure logic (harness-testable)

/// PURE helpers for the DM platform — deterministic id, unread counting, conversation ordering.
/// Kept free of I/O so the trade-engine harness can assert on them.
enum DMLogic {
    /// A one-line preview for a conversation row from a message (image-only → "📷 Photo"; deleted → "").
    static func preview(_ m: DirectMessage) -> String {
        if m.isDeleted { return "" }
        let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return m.imageBase64 != nil ? "📷 Photo" : "" }
        return t
    }

    /// Conversations ordered newest-activity first (the inbox list order).
    static func sorted(_ conversations: [Conversation]) -> [Conversation] {
        conversations.sorted { $0.lastMessageAt > $1.lastMessageAt }
    }

    /// Whether a conversation has messages from the OTHER person newer than when I last opened it.
    static func hasUnread(messages: [DirectMessage], convID: String, since: Date?, myID: String) -> Bool {
        let cutoff = since ?? .distantPast
        return messages.contains {
            $0.conversationID == convID && $0.senderID != myID && !$0.isDeleted && $0.createdAt > cutoff
        }
    }

    /// Total conversations with unread activity — for the dock/tab badge.
    static func unreadCount(conversations: [Conversation], messages: [DirectMessage],
                            lastSeen: [String: Date], myID: String) -> Int {
        conversations.reduce(0) { acc, c in
            acc + (hasUnread(messages: messages, convID: c.id, since: lastSeen[c.id], myID: myID) ? 1 : 0)
        }
    }
}

// MARK: - Service abstraction

protocol DirectMessageService: Sendable {
    func upsertConversation(_ c: Conversation) async
    func fetchConversations(involving workerID: String) async -> [Conversation]
    func sendMessage(_ m: DirectMessage) async
    func fetchMessages(involving workerID: String) async -> [DirectMessage]
    func deleteMessage(id: String) async
}

/// On-device stand-in (UserDefaults JSON) so DMs are fully testable with no account.
actor LocalDirectMessageService: DirectMessageService {
    private enum K {
        static let convos = "batman.dm.conversations"
        static let msgs   = "batman.dm.messages"
    }
    private var convos: [Conversation]
    private var msgs: [DirectMessage]

    init() {
        convos = Self.load(K.convos) ?? []
        msgs   = Self.load(K.msgs)   ?? []
    }

    func upsertConversation(_ c: Conversation) async {
        convos.removeAll { $0.id == c.id }
        convos.append(c); Self.save(convos, K.convos)
    }
    func fetchConversations(involving workerID: String) async -> [Conversation] {
        convos.filter { $0.involves(workerID) }
    }
    func sendMessage(_ m: DirectMessage) async {
        msgs.removeAll { $0.id == m.id }   // upsert (edit / soft-delete / reactions)
        msgs.append(m); Self.save(msgs, K.msgs)
    }
    func fetchMessages(involving workerID: String) async -> [DirectMessage] {
        msgs.filter { $0.senderID == workerID || $0.toID == workerID }
    }
    func deleteMessage(id: String) async { msgs.removeAll { $0.id == id }; Self.save(msgs, K.msgs) }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// CloudKit public-DB backend. Conversation is fetched by `participantIDs CONTAINS me`; messages by
/// `toID == me OR senderID == me`. Whole model JSON-encoded into `payload`; flat fields kept queryable.
actor CloudKitDirectMessageService: DirectMessageService {
    private let db = CKContainer(identifier: CloudKitConfig.containerID).publicCloudDatabase
    private enum RT { static let convo = "DMConversation"; static let message = "DirectMessage" }

    func upsertConversation(_ c: Conversation) async {
        await save(recordType: RT.convo, id: c.id, model: c) { r in
            r["participantIDs"] = c.participantIDs as CKRecordValue
        }
    }
    func fetchConversations(involving workerID: String) async -> [Conversation] {
        await fetch(recordType: RT.convo, predicate: NSPredicate(format: "participantIDs CONTAINS %@", workerID))
    }
    func sendMessage(_ m: DirectMessage) async {
        await save(recordType: RT.message, id: m.id, model: m) { r in
            r["conversationID"] = m.conversationID as CKRecordValue
            r["senderID"] = m.senderID as CKRecordValue
            r["toID"] = m.toID as CKRecordValue   // drives the per-recipient "new DM" push subscription
        }
    }
    func fetchMessages(involving workerID: String) async -> [DirectMessage] {
        let to   = await fetch(recordType: RT.message, predicate: NSPredicate(format: "toID == %@", workerID)) as [DirectMessage]
        let from = await fetch(recordType: RT.message, predicate: NSPredicate(format: "senderID == %@", workerID)) as [DirectMessage]
        var seen = Set<String>(); var merged: [DirectMessage] = []
        for m in to + from where seen.insert(m.id).inserted { merged.append(m) }
        return merged
    }
    func deleteMessage(id: String) async {
        do { _ = try await db.deleteRecord(withID: CKRecord.ID(recordName: id)) }
        catch { print("⚠️ DM delete failed: \(error.localizedDescription)") }
    }

    private func save<T: Encodable>(recordType: String, id: String, model: T,
                                    setFields: (CKRecord) -> Void) async {
        guard let data = try? JSONEncoder().encode(model),
              let json = String(data: data, encoding: .utf8) else { return }
        let recordID = CKRecord.ID(recordName: id)
        let record: CKRecord
        if let existing = try? await db.record(for: recordID) { record = existing }
        else { record = CKRecord(recordType: recordType, recordID: recordID) }
        record["payload"] = json as CKRecordValue
        setFields(record)
        do { _ = try await db.save(record) }
        catch { print("⚠️ CloudKit \(recordType) save failed: \(error.localizedDescription)") }
    }

    private func fetch<T: Decodable>(recordType: String, predicate: NSPredicate) async -> [T] {
        var out: [T] = []
        let query = CKQuery(recordType: recordType, predicate: predicate)
        do {
            var page = try await db.records(matching: query, resultsLimit: CKQueryOperation.maximumResults)
            while true {
                for (_, result) in page.matchResults {
                    if let record = try? result.get(),
                       let json = record["payload"] as? String,
                       let data = json.data(using: .utf8),
                       let model = try? JSONDecoder().decode(T.self, from: data) {
                        out.append(model)
                    }
                }
                guard let cursor = page.queryCursor else { break }
                page = try await db.records(continuingMatchFrom: cursor, resultsLimit: CKQueryOperation.maximumResults)
            }
        } catch {
            print("⚠️ CloudKit \(recordType) fetch failed: \(error.localizedDescription)")
        }
        return out
    }
}

// MARK: - Store facade

@MainActor
@Observable
final class DirectMessageStore {

    static let shared = DirectMessageStore()

    private var service: DirectMessageService

    private(set) var conversations: [Conversation] = []
    private(set) var messages: [DirectMessage] = []

    /// Set when a send is blocked because the recipient isn't on the app yet. The UI shows an alert.
    var blockedRecipient: String? = nil

    private init() {
        service = SettingsManager.shared.useCloudKit
            ? CloudKitDirectMessageService()
            : LocalDirectMessageService()
    }

    func setCloudKit(_ on: Bool) async {
        service = on ? CloudKitDirectMessageService() : LocalDirectMessageService()
        await refresh()
    }

    private var myID: String { SettingsManager.shared.username }
    private var myName: String {
        let s = SettingsManager.shared
        return s.displayName.isEmpty ? s.username : s.displayName
    }

    // MARK: Unread tracking (per-conversation last-opened)

    private static let lastSeenKey = "batman.dm.lastSeen"
    private static let readStateAtKey = "batman.dm.lastSeenUpdatedAt"
    private(set) var lastSeen: [String: Date] = {
        (UserDefaults.standard.dictionary(forKey: lastSeenKey) as? [String: Date]) ?? [:]
    }()
    /// Last local change to the read-state — drives cross-device LWW sync (like radar/intents state).
    private(set) var readStateUpdatedAt: Date =
        (UserDefaults.standard.object(forKey: readStateAtKey) as? Date) ?? .distantPast

    /// Call when a conversation opens — clears its unread dot AND syncs the read-state to your other devices.
    func markSeen(_ convID: String) {
        lastSeen[convID] = Date()
        UserDefaults.standard.set(lastSeen, forKey: Self.lastSeenKey)
        readStateUpdatedAt = Date()
        UserDefaults.standard.set(readStateUpdatedAt, forKey: Self.readStateAtKey)
        Task { await PrivateStateStore.shared.publishLocalDMReadState() }
    }

    /// Export the per-conversation last-opened map (ISO-1970 seconds) for cross-device sync.
    func exportReadStateJSON() -> String? {
        guard let data = try? JSONEncoder().encode(lastSeen.mapValues { $0.timeIntervalSince1970 }) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Adopt a remote read-state, MERGING per-conversation (newest-read wins) so reading on ANY device clears
    /// the unread dot everywhere. Bumps the local clock to the newer of the two.
    func applyRemoteReadState(_ json: String, at date: Date) {
        guard let data = json.data(using: .utf8),
              let remote = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        var merged = lastSeen
        for (k, v) in remote {
            let d = Date(timeIntervalSince1970: v)
            merged[k] = merged[k].map { max($0, d) } ?? d
        }
        lastSeen = merged
        UserDefaults.standard.set(lastSeen, forKey: Self.lastSeenKey)
        readStateUpdatedAt = max(readStateUpdatedAt, date)
        UserDefaults.standard.set(readStateUpdatedAt, forKey: Self.readStateAtKey)
    }
    func hasUnread(_ conv: Conversation) -> Bool {
        DMLogic.hasUnread(messages: messages, convID: conv.id, since: lastSeen[conv.id], myID: myID)
    }
    /// Conversations with unread activity — for the "Channels & Messages" tab badge.
    var totalUnread: Int {
        DMLogic.unreadCount(conversations: conversations, messages: messages, lastSeen: lastSeen, myID: myID)
    }

    // MARK: Refresh

    func refresh() async {
        let id = myID
        async let c = service.fetchConversations(involving: id)
        async let m = service.fetchMessages(involving: id)
        let (convos, msgs) = await (c, m)
        // Don't let a transient CloudKit empty-fetch wipe a good cache (mirrors MessagingStore).
        conversations = FetchMerge.keepCacheOnEmpty(existing: conversations, fetched: DMLogic.sorted(convos))
        messages      = FetchMerge.keepCacheOnEmpty(existing: messages,
            fetched: msgs.sorted { $0.createdAt < $1.createdAt })
    }

    // MARK: Reads

    /// Messages in a conversation, oldest→newest.
    func messages(in convID: String) -> [DirectMessage] {
        messages.filter { $0.conversationID == convID }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The existing conversation with a peer, if any (by canonical id).
    func existingConversation(withID peerID: String) -> Conversation? {
        conversations.first { $0.id == Conversation.canonicalID(myID, peerID) }
    }

    // MARK: Writes

    /// Find-or-create the 1:1 conversation with a peer and return it (does NOT send a message).
    /// Only creates locally/optimistically; the record is persisted on the first message send.
    @discardableResult
    func conversation(withID peerID: String, name peerName: String) -> Conversation {
        if let existing = existingConversation(withID: peerID) { return existing }
        let ids = [myID, peerID].sorted()
        let names = ids.map { $0 == myID ? myName : peerName }
        let now = Date()
        let conv = Conversation(id: Conversation.canonicalID(myID, peerID),
                                participantIDs: ids, participantNames: names,
                                createdAt: now, lastMessageAt: now, lastMessagePreview: "")
        conversations = DMLogic.sorted([conv] + conversations.filter { $0.id != conv.id })
        return conv
    }

    /// Send a message to a peer (creating the conversation record on first send). Blocks if the
    /// recipient isn't an active account (can't receive) — sets `blockedRecipient` for the UI.
    func send(toID peerID: String, name peerName: String, text: String, imageBase64: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || imageBase64 != nil else { return }
        guard TradeProfileStore.shared.isActiveAccount(peerID) else { blockedRecipient = peerName; return }

        let conv = conversation(withID: peerID, name: peerName)
        let msg = DirectMessage(id: UUID().uuidString, conversationID: conv.id,
                                senderID: myID, senderName: myName, toID: peerID,
                                text: trimmed, createdAt: Date(), imageBase64: imageBase64)
        // Optimistic local append.
        messages = (messages.filter { $0.id != msg.id } + [msg]).sorted { $0.createdAt < $1.createdAt }
        let updatedConv = Conversation(id: conv.id, participantIDs: conv.participantIDs,
                                       participantNames: conv.participantNames, createdAt: conv.createdAt,
                                       lastMessageAt: msg.createdAt, lastMessagePreview: DMLogic.preview(msg))
        conversations = DMLogic.sorted([updatedConv] + conversations.filter { $0.id != conv.id })
        markSeen(conv.id)   // my own send is "read"

        await service.upsertConversation(updatedConv)
        await service.sendMessage(msg)
    }

    /// Toggle my emoji reaction on a message.
    func react(to msg: DirectMessage, emoji: String) async {
        let updated = DirectMessage(id: msg.id, conversationID: msg.conversationID, senderID: msg.senderID,
                                    senderName: msg.senderName, toID: msg.toID, text: msg.text,
                                    createdAt: msg.createdAt, editedAt: msg.editedAt, deleted: msg.deleted,
                                    reactions: Reaction.setSingle(msg.reactions ?? [], emoji: emoji,
                                                                  userID: myID, userName: myName),
                                    imageBase64: msg.imageBase64)
        messages = messages.map { $0.id == msg.id ? updated : $0 }
        await service.sendMessage(updated)
    }

    /// Edit my own message (stamps `editedAt`).
    func edit(_ msg: DirectMessage, newText: String) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, msg.senderID == myID else { return }
        let updated = DirectMessage(id: msg.id, conversationID: msg.conversationID, senderID: msg.senderID,
                                    senderName: msg.senderName, toID: msg.toID, text: trimmed,
                                    createdAt: msg.createdAt, editedAt: Date(), deleted: msg.deleted,
                                    reactions: msg.reactions, imageBase64: msg.imageBase64)
        messages = messages.map { $0.id == msg.id ? updated : $0 }
        await service.sendMessage(updated)
    }

    /// Soft-delete my own message (tombstone → renders "[Deleted]").
    func softDelete(_ msg: DirectMessage) async {
        guard msg.senderID == myID else { return }
        let updated = DirectMessage(id: msg.id, conversationID: msg.conversationID, senderID: msg.senderID,
                                    senderName: msg.senderName, toID: msg.toID, text: msg.text,
                                    createdAt: msg.createdAt, editedAt: msg.editedAt, deleted: true,
                                    reactions: msg.reactions, imageBase64: msg.imageBase64)
        messages = messages.map { $0.id == msg.id ? updated : $0 }
        await service.sendMessage(updated)
    }
}
