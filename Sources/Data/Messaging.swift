// Messaging.swift
// In-app trade messaging: a self-maintaining BROADCAST CHANNEL (post "trading
// away X", everyone sees it, creator can delete, posts auto-expire) and a 1:1
// TRADE-REQUEST INBOX (send a proposed swap, recipient accepts/declines/counters).
//
// CloudKit public-DB note: you may only modify records YOU created, so a reply is
// a SEPARATE `TradeResponse` record (created by the recipient) rather than a
// mutation of the request. A thread = request + its responses.
//
// Backend is swappable behind `MessagingService` (Local now, CloudKit when iCloud
// sync is on) — same pattern as TradeProfile.

import Foundation
import Observation

// MARK: - Models

/// A post in the shared broadcast channel. Self-maintaining via `expiresAt`.
/// One emoji reaction by one person (B6).
struct Reaction: Sendable, Codable, Hashable {
    let emoji: String
    let userID: String
    let userName: String

    /// PURE — **one reaction per user** (#8a): tapping the same emoji clears it; tapping a different
    /// emoji REPLACES the user's prior one. A user never holds more than one reaction on a thread.
    static func setSingle(_ reactions: [Reaction], emoji: String, userID: String, userName: String) -> [Reaction] {
        let hadSame = reactions.contains { $0.userID == userID && $0.emoji == emoji }
        var others = reactions.filter { $0.userID != userID }   // drop ALL of this user's reactions
        if !hadSame { others.append(Reaction(emoji: emoji, userID: userID, userName: userName)) }
        return others
    }
    /// Counts per emoji, for the reaction chips.
    static func counts(_ reactions: [Reaction]) -> [(emoji: String, count: Int)] {
        Dictionary(grouping: reactions, by: \.emoji).map { ($0.key, $0.value.count) }.sorted { $0.emoji < $1.emoji }
    }
}

struct BroadcastPost: Sendable, Codable, Identifiable, Hashable {
    let id: String            // UUID string (recordName)
    let authorID: String
    let authorName: String
    let text: String
    let createdAt: Date
    let expiresAt: Date
    var channel: String? = nil   // "general"/"trades"/"feedback"; nil = legacy = trades
    var pinned: Bool? = nil       // admin-pinned to the top of its channel (B7). Optional ⇒ old records decode.
    var reactions: [Reaction]? = nil  // emoji reactions (B6). Optional ⇒ old records decode.
    var imageBase64: String? = nil    // attached photo (downscaled JPEG, base64) — rides the payload (B5).

    // EXPLICIT init — freezes the construction symbol so adding new optional fields above
    // doesn't churn the memberwise-init symbol (stale-link prevention; see TradeProfile).
    init(id: String, authorID: String, authorName: String, text: String, createdAt: Date, expiresAt: Date,
         channel: String? = nil, pinned: Bool? = nil, reactions: [Reaction]? = nil, imageBase64: String? = nil) {
        self.id = id; self.authorID = authorID; self.authorName = authorName; self.text = text
        self.createdAt = createdAt; self.expiresAt = expiresAt
        self.channel = channel; self.pinned = pinned; self.reactions = reactions; self.imageBase64 = imageBase64
    }

    var isExpired: Bool { expiresAt < Date() }
    var channelOrDefault: String { channel ?? "trades" }
    var isPinned: Bool { pinned == true }
}

/// A reply on a broadcast post. `isPublic` = everyone sees it; otherwise only the
/// post author and the replier see it (a private reply). Authors reply to their
/// own posts to push updates.
struct BroadcastReply: Sendable, Codable, Identifiable, Hashable {
    let id: String
    let postID: String
    let authorID: String
    let authorName: String
    let text: String
    let isPublic: Bool
    let createdAt: Date
    var editedAt: Date? = nil    // set on edit → shows "edited · time" (B4). Optional ⇒ old records decode.
    var deleted: Bool? = nil     // soft-delete tombstone → renders "[Deleted]" (B4).
    var reactions: [Reaction]? = nil   // emoji reactions (B6). Optional ⇒ old records decode.
    var imageBase64: String? = nil     // attached photo (downscaled JPEG, base64) — replies (#8b).

    // EXPLICIT init — freezes the construction signature (stale-incremental-link fix); new optional
    // fields are set via assignment / passed explicitly, never churning callers' object files.
    init(id: String, postID: String, authorID: String, authorName: String, text: String,
         isPublic: Bool, createdAt: Date, editedAt: Date? = nil, deleted: Bool? = nil,
         reactions: [Reaction]? = nil, imageBase64: String? = nil) {
        self.id = id; self.postID = postID; self.authorID = authorID; self.authorName = authorName
        self.text = text; self.isPublic = isPublic; self.createdAt = createdAt
        self.editedAt = editedAt; self.deleted = deleted; self.reactions = reactions; self.imageBase64 = imageBase64
    }

    var isDeleted: Bool { deleted == true }
}

/// A moderation flag created by an admin to HIDE a post or reply for everyone
/// (CloudKit public DB won't let you delete others' records, but you can publish
/// your own "hide" flag that all clients respect). Delete the underlying record
/// from the CloudKit Console afterward if you want it gone for good.
struct HiddenItem: Sendable, Codable, Identifiable, Hashable {
    let id: String         // recordName, e.g. "hide_<targetID>"
    let targetID: String   // the post/reply id being hidden
    let createdAt: Date
}

enum TradeRequestStatus: String, Codable, Sendable, CaseIterable {
    case pending, accepted, declined, countered, cancelled
    case message   // a plain chat message — does NOT change the trade's accept/decline state

    var label: String {
        switch self {
        case .pending:   return "Pending"
        case .accepted:  return "Accepted"
        case .declined:  return "Declined"
        case .countered: return "Counter-offer"
        case .cancelled: return "Cancelled"
        case .message:   return "Message"
        }
    }
}

/// A 1:1 trade proposal that lands in the recipient's inbox.
struct TradeRequest: Sendable, Codable, Identifiable, Hashable {
    let id: String            // UUID string (recordName)
    let fromID: String
    let fromName: String
    let toID: String
    let toName: String
    let note: String
    let takeDayIDs: [String]   // their work days the sender would take (ISO)
    let giveDayIDs: [String]   // sender's work days the recipient would take (ISO)
    let createdAt: Date
    let expiresAt: Date
    var ecb: Int? = nil        // legacy integer ECB (back-compat; old records). Prefer ecbValue.
    var ecbValue: Double? = nil // ECB offered, supports 0.5 steps (e.g. 13.5 for 1.5× OT). SPEC S-ENG-8.
    var offerID: String? = nil // shared across the broadcast (first accepter wins)
    var chain: [TradeLeg]? = nil // present for multi-person (circular) trades: the full loop
    var qualSwap: QualSwapLegData? = nil // embedded qual-swap leg (Q3/Q5/Q6). Optional ⇒ old records decode.
    var perfectMatch: Bool? = nil        // computed sender-side: hits the recipient's own intents (U6 push).

    // EXPLICIT init — REPLACES the synthesized memberwise init and FREEZES the construction
    // signature, so adding a NEW optional field above won't churn the init symbol (the
    // stale-incremental-link fix). New optional fields are set via assignment after construction.
    init(id: String, fromID: String, fromName: String, toID: String, toName: String,
         note: String, takeDayIDs: [String], giveDayIDs: [String], createdAt: Date, expiresAt: Date,
         ecb: Int? = nil, ecbValue: Double? = nil, offerID: String? = nil,
         chain: [TradeLeg]? = nil, qualSwap: QualSwapLegData? = nil, perfectMatch: Bool? = nil) {
        self.id = id; self.fromID = fromID; self.fromName = fromName; self.toID = toID; self.toName = toName
        self.note = note; self.takeDayIDs = takeDayIDs; self.giveDayIDs = giveDayIDs
        self.createdAt = createdAt; self.expiresAt = expiresAt
        self.ecb = ecb; self.ecbValue = ecbValue; self.offerID = offerID
        self.chain = chain; self.qualSwap = qualSwap; self.perfectMatch = perfectMatch
    }

    var isExpired: Bool { expiresAt < Date() }
    /// The ECB amount to display — new Double field, falling back to the legacy Int.
    var ecbAmount: Double? { ecbValue ?? ecb.map(Double.init) }
    /// A one-way ECB offer = sender gives days, takes nothing back, offers points.
    var isECB: Bool { ecbAmount != nil && takeDayIDs.isEmpty }

    /// ECB is offered in 0.5 steps, 5…25 (SPEC S-ENG-8).
    static func isValidECB(_ v: Double) -> Bool { v >= 5 && v <= 25 && (v * 2).rounded() == v * 2 }
    static func clampECB(_ v: Double) -> Double { min(25, max(5, (v * 2).rounded() / 2)) }
}

/// Formats an ECB amount with no trailing ".0" (9 → "9", 13.5 → "13.5").
func ecbText(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
}

/// One handoff in a multi-person trade — carried in a request so the inbox can show
/// the whole loop (who hands which day to whom), names included for offline display.
struct TradeLeg: Sendable, Codable, Hashable {
    let fromID: String
    let fromName: String
    let toID: String
    let toName: String
    let dayID: String
    var desk: String? = nil
}

// MARK: - Qual-swap leg (Q2/Q3/Q5/Q6)

/// One bridge candidate blasted for a qual-swap leg — a dispatcher working the same
/// day/start-hour who could slide onto the give-desk, freeing their own desk for the taker.
struct QualSwapCandidate: Sendable, Codable, Hashable, Identifiable {
    let workerID: String
    let name: String
    let desk: String       // the desk they'd FREE (their current desk that day)
    let qual: String       // that desk's qual — what the taker must hold to take it
    var id: String { workerID }
}

/// One bridge ACCEPTANCE — the taker sees name + desk + qual (Q6).
struct QualSwapAcceptance: Sendable, Codable, Hashable, Identifiable {
    let workerID: String
    let name: String
    let desk: String
    let qual: String
    let acceptedAt: Date
    var id: String { workerID }
}

/// An embedded qual-swap leg on a `TradeRequest` (Q3/Q5/Q6). Optional on the request so
/// older records still decode. Status is DERIVED (never stored) via the pure reducer.
struct QualSwapLegData: Sendable, Codable, Hashable {
    let giveShiftDayID: String     // ISO day of the give-desk
    let giveDesk: String           // the desk being given (needs giveQual)
    let giveQual: String
    let takerID: String            // the off person who'll take a freed desk
    let takerName: String
    var candidates: [QualSwapCandidate]            // the bridges blasted (selected names)
    var acceptances: [QualSwapAcceptance] = []     // bridges who accepted (first-5 cap)
    var chosenWorkerID: String? = nil              // bridge the taker finalized on (Q5 desk-choice)
    var takerDeclined: Bool? = nil                 // taker declined → invalid
    var expired: Bool? = nil                       // deadline passed with no acceptances

    /// Live leg status (Q3/Q6) — chosen wins, else the pure reducer.
    var status: QualSwapLegStatus {
        if chosenWorkerID != nil { return .finalized }
        return QualSwapLeg.status(acceptedCount: acceptances.count, finalized: false,
                                  declined: takerDeclined == true, expired: expired == true)
    }
    /// Whether another bridge may still accept (first-5 rule).
    var acceptIsOpen: Bool { QualSwapLeg.acceptIsOpen(acceptedCount: acceptances.count) }
    /// The acceptance the taker finalized on, if any.
    var chosenAcceptance: QualSwapAcceptance? {
        chosenWorkerID.flatMap { id in acceptances.first { $0.workerID == id } }
    }

    /// PURE upsert of an acceptance honoring the first-5 cap + per-worker idempotency.
    /// A 6th acceptor (or a duplicate) is ignored — the leg is already filled.
    func addingAcceptance(_ a: QualSwapAcceptance) -> QualSwapLegData {
        guard !acceptances.contains(where: { $0.workerID == a.workerID }) else { return self }
        guard QualSwapLeg.acceptIsOpen(acceptedCount: acceptances.count) else { return self }
        var copy = self
        copy.acceptances.append(a)
        return copy
    }
}

/// A person's role in a qual-swap request — drives which inbox UI they see.
enum QualSwapRole: String, Sendable, CaseIterable {
    case giver    // the request sender (A), giving away the desk
    case taker    // the off person (B) who'll take a freed desk
    case bridge   // a blasted candidate (C) who can slide onto the give-desk
    case none     // not involved in this leg
}

extension QualSwapLegData {
    /// Short status line for the package card / inbox (Q3/Q6).
    var statusText: String {
        switch status {
        case .waiting:    return "Waiting on qual swap"
        case .offersOpen: return "Qual swap: \(acceptances.count) accepted — choose or wait"
        case .offersFull: return "Qual swap: 5 accepted (full) — choose one"
        case .finalized:  return chosenAcceptance.map { "Qual swap: \($0.name) → desk \(giveDesk)" } ?? "Qual swap finalized"
        case .invalid:    return "Invalid — qual swap not filled"
        }
    }
}

extension TradeRequest {
    /// This worker's role in the embedded qual-swap leg (`.none` if no leg / not involved).
    func qualSwapRole(for workerID: String) -> QualSwapRole {
        guard let leg = qualSwap else { return .none }
        if workerID == leg.takerID { return .taker }
        if workerID == fromID { return .giver }
        if leg.candidates.contains(where: { $0.workerID == workerID }) { return .bridge }
        return .none
    }
}

/// A reply to a `TradeRequest`, authored by whoever is responding.
struct TradeResponse: Sendable, Codable, Identifiable, Hashable {
    let id: String
    let requestID: String
    let responderID: String
    let responderName: String
    let status: String         // TradeRequestStatus rawValue
    let note: String
    let createdAt: Date
    var offerID: String? = nil      // copied from the ECB offer so the queue is public
    var acceptedDayIDs: [String]? = nil  // ECB: which shifts this person accepted
    var editedAt: Date? = nil       // chat-message edit marker (B4). Optional ⇒ old records decode.
    var deleted: Bool? = nil        // soft-delete tombstone for a chat message (B4).
    var reactions: [Reaction]? = nil // emoji reactions on a 1:1 chat message (B6).

    // EXPLICIT init — freezes the construction signature (stale-incremental-link fix).
    init(id: String, requestID: String, responderID: String, responderName: String,
         status: String, note: String, createdAt: Date, offerID: String? = nil,
         acceptedDayIDs: [String]? = nil, editedAt: Date? = nil, deleted: Bool? = nil,
         reactions: [Reaction]? = nil) {
        self.id = id; self.requestID = requestID; self.responderID = responderID
        self.responderName = responderName; self.status = status; self.note = note
        self.createdAt = createdAt; self.offerID = offerID; self.acceptedDayIDs = acceptedDayIDs
        self.editedAt = editedAt; self.deleted = deleted; self.reactions = reactions
    }

    var statusValue: TradeRequestStatus { TradeRequestStatus(rawValue: status) ?? .pending }
    var isDeleted: Bool { deleted == true }
}

// MARK: - Service abstraction

protocol MessagingService: Sendable {
    // Broadcast channel
    func postBroadcast(_ post: BroadcastPost) async
    func fetchBroadcasts() async -> [BroadcastPost]
    func deleteBroadcast(id: String) async
    func postReply(_ reply: BroadcastReply) async
    func fetchReplies() async -> [BroadcastReply]
    func deleteReply(id: String) async
    // Moderation
    func hide(id targetID: String) async
    func fetchHidden() async -> Set<String>
    // Trade requests + responses
    func sendRequest(_ request: TradeRequest) async
    func fetchRequests(involving workerID: String) async -> [TradeRequest]
    func deleteRequest(id: String) async
    func sendResponse(_ response: TradeResponse) async
    func fetchResponses() async -> [TradeResponse]
}

/// On-device stand-in (UserDefaults JSON) so the inbox + channel are fully
/// testable with no account. Swapped for CloudKit when iCloud sync is on.
actor LocalMessagingService: MessagingService {
    private enum K {
        static let posts = "batman.msg.broadcasts"
        static let reqs  = "batman.msg.requests"
        static let resps = "batman.msg.responses"
        static let replies = "batman.msg.replies"
        static let hidden = "batman.msg.hidden"
    }

    private var posts: [BroadcastPost]
    private var reqs:  [TradeRequest]
    private var resps: [TradeResponse]
    private var replies: [BroadcastReply]
    private var hiddenIDs: [String]

    init() {
        posts = Self.load(K.posts) ?? []
        reqs  = Self.load(K.reqs)  ?? []
        resps = Self.load(K.resps) ?? []
        replies = Self.load(K.replies) ?? []
        hiddenIDs = Self.load(K.hidden) ?? []
    }

    func postBroadcast(_ post: BroadcastPost) async {
        posts.removeAll { $0.id == post.id }   // upsert (supports edits)
        posts.append(post); Self.save(posts, K.posts)
    }
    func fetchBroadcasts() async -> [BroadcastPost] { posts }
    func deleteBroadcast(id: String) async { posts.removeAll { $0.id == id }; Self.save(posts, K.posts) }
    func postReply(_ reply: BroadcastReply) async {
        replies.removeAll { $0.id == reply.id }   // upsert (supports edit/soft-delete)
        replies.append(reply); Self.save(replies, K.replies)
    }
    func fetchReplies() async -> [BroadcastReply] { replies }
    func deleteReply(id: String) async { replies.removeAll { $0.id == id }; Self.save(replies, K.replies) }
    func hide(id targetID: String) async {
        if !hiddenIDs.contains(targetID) { hiddenIDs.append(targetID); Self.save(hiddenIDs, K.hidden) }
    }
    func fetchHidden() async -> Set<String> { Set(hiddenIDs) }

    func sendRequest(_ request: TradeRequest) async {
        reqs.removeAll { $0.id == request.id }   // upsert (supports qual-swap leg updates)
        reqs.append(request); Self.save(reqs, K.reqs)
    }
    func fetchRequests(involving workerID: String) async -> [TradeRequest] { reqs }
    func deleteRequest(id: String) async { reqs.removeAll { $0.id == id }; Self.save(reqs, K.reqs) }
    func sendResponse(_ response: TradeResponse) async {
        resps.removeAll { $0.id == response.id }   // upsert (supports chat edit/soft-delete)
        resps.append(response); Self.save(resps, K.resps)
    }
    func fetchResponses() async -> [TradeResponse] { resps }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Store facade

@MainActor
@Observable
final class MessagingStore {

    static let shared = MessagingStore()

    private var service: MessagingService

    private(set) var broadcasts: [BroadcastPost] = []
    private(set) var requests: [TradeRequest] = []
    /// Active requests now INVALID vs the current master roster (a day is no longer worked).
    /// Recomputed every `refresh()` — auto-clears when a schedule reverses. (S-VALID)
    private(set) var invalidRequestIDs: Set<String> = []
    private(set) var responses: [TradeResponse] = []
    private(set) var replies: [BroadcastReply] = []
    private(set) var hidden: Set<String> = []

    /// When the user last OPENED the broadcast channel. Drives the UNREAD badge so it
    /// clears on read — the old badge showed total post count and never cleared (A2/S-SYNC-1).
    private static let lastSeenKey = "batman.msg.broadcastsLastSeen"
    var broadcastsLastSeen: Date = (UserDefaults.standard.object(forKey: lastSeenKey) as? Date) ?? .distantPast {
        didSet { UserDefaults.standard.set(broadcastsLastSeen, forKey: Self.lastSeenKey) }
    }

    /// PURE, testable: count of broadcasts newer than `since` that aren't the user's own.
    static func unreadCount(broadcasts: [BroadcastPost], since: Date, excluding myID: String) -> Int {
        broadcasts.filter { $0.createdAt > since && $0.authorID != myID && !$0.isExpired }.count
    }
    /// Unread broadcasts for the dock badge.
    var unreadBroadcastCount: Int {
        Self.unreadCount(broadcasts: broadcasts, since: broadcastsLastSeen, excluding: myID)
    }
    /// Call when the channel opens — clears the unread badge.
    func markBroadcastsSeen() { broadcastsLastSeen = Date() }

    /// Requests the user ARCHIVED (hidden from the active inbox, kept in an Archived
    /// section — distinct from delete which removes them forever). Local-only. B3.
    private static let archivedKey = "batman.msg.archivedRequests"
    private(set) var archivedRequestIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: archivedKey) ?? [])
    func archiveRequest(_ id: String) {
        let firstArchive = !archivedRequestIDs.contains(id)
        archivedRequestIDs.insert(id); persistArchived()
        // #9: a trade is SUCCESSFUL once accepted AND archived — log the metric here (once).
        if firstArchive, let req = requests.first(where: { $0.id == id }), status(of: req) == .accepted {
            MetricsStore.shared.log(.trade)
        }
    }
    func unarchiveRequest(_ id: String) { archivedRequestIDs.remove(id); persistArchived() }
    private func persistArchived() { UserDefaults.standard.set(Array(archivedRequestIDs), forKey: Self.archivedKey) }
    /// PURE, testable: requests NOT archived (the active inbox).
    static func active(_ requests: [TradeRequest], archived: Set<String>) -> [TradeRequest] {
        requests.filter { !archived.contains($0.id) }
    }

    private init() {
        service = SettingsManager.shared.useCloudKit
            ? CloudKitMessagingService()
            : LocalMessagingService()
    }

    func setCloudKit(_ on: Bool) async {
        service = on ? CloudKitMessagingService() : LocalMessagingService()
        await refresh()
    }

    private var myID: String { SettingsManager.shared.username }
    private var myName: String {
        let s = SettingsManager.shared
        return s.displayName.isEmpty ? s.username : s.displayName
    }

    // MARK: Refresh

    func refresh() async {
        let id = myID
        async let b = service.fetchBroadcasts()
        async let r = service.fetchRequests(involving: id)
        async let p = service.fetchResponses()
        async let rep = service.fetchReplies()
        async let hid = service.fetchHidden()
        let (posts, reqs, resps, reps, hides) = await (b, r, p, rep, hid)
        hidden = hides
        // P0: a transient CloudKit error returns []; don't let that wipe a non-empty cache.
        broadcasts = FetchMerge.keepCacheOnEmpty(existing: broadcasts,
            fetched: posts.filter { !$0.isExpired && !hidden.contains($0.id) }.sorted { $0.createdAt > $1.createdAt })
        requests   = FetchMerge.keepCacheOnEmpty(existing: requests,
            fetched: reqs.filter { !$0.isExpired }.sorted { $0.createdAt > $1.createdAt })
        responses  = FetchMerge.keepCacheOnEmpty(existing: responses, fetched: resps.sorted { $0.createdAt < $1.createdAt })
        replies    = FetchMerge.keepCacheOnEmpty(existing: replies, fetched: reps.sorted { $0.createdAt < $1.createdAt })
        // ECB maintenance (sender side): auto-complete ledger on receipt.
        reconcileECBLedger()
        await refreshInvalidRequests()
    }

    /// S-VALID: recompute which active (non-ECB) requests are stale against the live roster.
    /// Auto-clears — a reversed schedule drops the request out on the next refresh.
    func refreshInvalidRequests() async {
        var invalid = Set<String>()
        for req in requests where !req.isECB {
            let stale = await TradeMatcher.staleDays(fromID: req.fromID, toID: req.toID,
                                                     giveDayIDs: req.giveDayIDs, takeDayIDs: req.takeDayIDs)
            if !stale.isEmpty { invalid.insert(req.id) }
        }
        invalidRequestIDs = invalid
    }

    /// Whether this request is currently invalid (a traded day is no longer worked).
    func isInvalid(_ request: TradeRequest) -> Bool { invalidRequestIDs.contains(request.id) }

    /// Replies visible to YOU on a post: public ones, plus private ones you wrote
    /// or that are on your own post — minus anything an admin has hidden.
    func visibleReplies(for post: BroadcastPost) -> [BroadcastReply] {
        replies.filter { $0.postID == post.id && !hidden.contains($0.id) }
            .filter { $0.isPublic || $0.authorID == myID || post.authorID == myID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Admin moderation: hide a post or reply for everyone (filtered on all
    /// devices). The underlying record can be deleted from the CloudKit Console.
    func hide(_ id: String) async {
        await service.hide(id: id)
        hidden.insert(id)
        broadcasts.removeAll { $0.id == id }
        replies.removeAll { $0.id == id }
    }

    func addReply(to post: BroadcastPost, text: String, isPublic: Bool, imageBase64: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || imageBase64 != nil else { return }
        let reply = BroadcastReply(
            id: UUID().uuidString, postID: post.id, authorID: myID, authorName: myName,
            text: trimmed, isPublic: isPublic, createdAt: Date(), imageBase64: imageBase64)
        await service.postReply(reply)
        replies = (replies.filter { $0.id != reply.id } + [reply]).sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Broadcast channel

    func post(text: String, channel: String = "trades", daysValid: Int = 21, imageBase64: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || imageBase64 != nil else { return }   // allow image-only posts
        let now = Date()
        let post = BroadcastPost(
            id: UUID().uuidString, authorID: myID, authorName: myName,
            text: trimmed, createdAt: now,
            expiresAt: Calendar.current.date(byAdding: .day, value: daysValid, to: now) ?? now,
            channel: channel, imageBase64: imageBase64)
        await service.postBroadcast(post)
        // Optimistic: show locally now (don't wait on a server round-trip, which
        // may need queryable indexes before fetch returns).
        broadcasts = ([post] + broadcasts.filter { $0.id != post.id })
            .filter { !$0.isExpired }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Deletes a post and cascades its replies. Works locally + for your own
    /// CloudKit records; deleting OTHER users' CloudKit records may be refused by
    /// CloudKit (public DB lets you delete only what you created — use the Console
    /// or a security role for full cross-user moderation).
    func deletePost(_ id: String) async {
        for r in replies where r.postID == id { await service.deleteReply(id: r.id) }
        await service.deleteBroadcast(id: id)
        replies.removeAll { $0.postID == id }
        broadcasts.removeAll { $0.id == id }
    }

    func deleteReply(_ id: String) async {
        await service.deleteReply(id: id)
        replies.removeAll { $0.id == id }
    }

    /// Edit your own post's text (keeps id/createdAt/expiry/channel/pinned).
    func editPost(_ post: BroadcastPost, newText: String) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let updated = BroadcastPost(
            id: post.id, authorID: post.authorID, authorName: post.authorName,
            text: trimmed, createdAt: post.createdAt, expiresAt: post.expiresAt,
            channel: post.channel, pinned: post.pinned, reactions: post.reactions, imageBase64: post.imageBase64)
        await service.postBroadcast(updated)   // upsert
        broadcasts = broadcasts.map { $0.id == post.id ? updated : $0 }
    }

    /// Admin: pin/unpin a post to the top of its channel (B7). Caller gates to DevAccess.
    func setPinned(_ post: BroadcastPost, _ pinned: Bool) async {
        let updated = BroadcastPost(
            id: post.id, authorID: post.authorID, authorName: post.authorName,
            text: post.text, createdAt: post.createdAt, expiresAt: post.expiresAt,
            channel: post.channel, pinned: pinned, reactions: post.reactions, imageBase64: post.imageBase64)
        await service.postBroadcast(updated)   // upsert
        broadcasts = broadcasts.map { $0.id == post.id ? updated : $0 }
    }

    /// Toggle the current user's emoji reaction on a post (B6).
    func react(to post: BroadcastPost, emoji: String) async {
        let updated = BroadcastPost(
            id: post.id, authorID: post.authorID, authorName: post.authorName,
            text: post.text, createdAt: post.createdAt, expiresAt: post.expiresAt,
            channel: post.channel, pinned: post.pinned,
            reactions: Reaction.setSingle(post.reactions ?? [], emoji: emoji, userID: myID, userName: myName),
            imageBase64: post.imageBase64)
        await service.postBroadcast(updated)   // upsert
        broadcasts = broadcasts.map { $0.id == post.id ? updated : $0 }
    }

    /// Toggle my emoji reaction on a channel REPLY (B6).
    func react(to reply: BroadcastReply, emoji: String) async {
        let updated = BroadcastReply(
            id: reply.id, postID: reply.postID, authorID: reply.authorID, authorName: reply.authorName,
            text: reply.text, isPublic: reply.isPublic, createdAt: reply.createdAt,
            editedAt: reply.editedAt, deleted: reply.deleted,
            reactions: Reaction.setSingle(reply.reactions ?? [], emoji: emoji, userID: myID, userName: myName),
            imageBase64: reply.imageBase64)
        await service.postReply(updated)   // upsert
        replies = replies.map { $0.id == reply.id ? updated : $0 }
    }

    /// Toggle my emoji reaction on a 1:1 chat MESSAGE response (B6).
    func react(to response: TradeResponse, emoji: String) async {
        let updated = TradeResponse(
            id: response.id, requestID: response.requestID, responderID: response.responderID,
            responderName: response.responderName, status: response.status, note: response.note,
            createdAt: response.createdAt, offerID: response.offerID, acceptedDayIDs: response.acceptedDayIDs,
            editedAt: response.editedAt, deleted: response.deleted,
            reactions: Reaction.setSingle(response.reactions ?? [], emoji: emoji, userID: myID, userName: myName))
        await service.sendResponse(updated)   // upsert
        responses = responses.map { $0.id == response.id ? updated : $0 }
    }

    // MARK: Intent-match 🔥 (U6)

    /// PURE: does an incoming request hit one of my marked intents? 🔥 when a day I'd PICK UP
    /// matches my Want-to-Work (off day; ECB only), OR a day TAKEN FROM ME matches my
    /// Trade-Away (working day). Stub until implemented (fail-test target, U6).
    static func intentMatch(pickupDayIDs: [String], takenFromMeDayIDs: [String], isECB: Bool,
                            myWantToWork: Set<String>, mySeeking: Set<String>) -> Bool {
        if isECB, pickupDayIDs.contains(where: { myWantToWork.contains($0) }) { return true }
        if takenFromMeDayIDs.contains(where: { mySeeking.contains($0) }) { return true }
        return false
    }

    /// PURE: computed by the SENDER — does this request hit the RECIPIENT's published intents
    /// (their Trade-Away / Want-to-Work)? Stamped on the record so a CloudKit subscription can
    /// fire a "Perfect Match" push (the recipient's intents aren't on the record, but the sender
    /// can see them in the recipient's published profile). U6.
    static func requestPerfectMatch(give: [String], take: [String], isECB: Bool,
                                    recipientSeeking: Set<String>, recipientWantToWork: Set<String>) -> Bool {
        intentMatch(pickupDayIDs: give, takenFromMeDayIDs: take, isECB: isECB,
                    myWantToWork: recipientWantToWork, mySeeking: recipientSeeking)
    }

    /// 🔥 for an incoming request addressed to me, using my live intents.
    func matchesMyIntents(_ request: TradeRequest) -> Bool {
        guard request.toID == myID else { return false }
        return Self.intentMatch(pickupDayIDs: request.giveDayIDs, takenFromMeDayIDs: request.takeDayIDs,
                                isECB: request.isECB,
                                myWantToWork: DayIntentStore.shared.wantToWorkDayIDs,
                                mySeeking: DayIntentStore.shared.seekingDayIDs)
    }

    /// PURE, testable: posts sorted pinned-first, then newest. (B7)
    static func sortedForChannel(_ posts: [BroadcastPost]) -> [BroadcastPost] {
        posts.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }   // pinned first
            return a.createdAt < b.createdAt                     // E1: then OLDEST first (thread reads top→bottom)
        }
    }

    func isMine(_ post: BroadcastPost) -> Bool { post.authorID == myID }
    func isMine(_ reply: BroadcastReply) -> Bool { reply.authorID == myID }

    /// Edit your own reply (keeps id/createdAt); stamps `editedAt`. B4.
    func editReply(_ reply: BroadcastReply, newText: String) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let updated = BroadcastReply(id: reply.id, postID: reply.postID, authorID: reply.authorID,
                                     authorName: reply.authorName, text: trimmed, isPublic: reply.isPublic,
                                     createdAt: reply.createdAt, editedAt: Date(), deleted: reply.deleted,
                                     reactions: reply.reactions, imageBase64: reply.imageBase64)
        await service.postReply(updated)   // upsert
        replies = replies.map { $0.id == reply.id ? updated : $0 }
    }

    /// Soft-delete your own reply: keep the row as a "[Deleted]" tombstone. B4.
    func softDeleteReply(_ reply: BroadcastReply) async {
        let updated = BroadcastReply(id: reply.id, postID: reply.postID, authorID: reply.authorID,
                                     authorName: reply.authorName, text: "", isPublic: reply.isPublic,
                                     createdAt: reply.createdAt, editedAt: reply.editedAt, deleted: true)
        await service.postReply(updated)
        replies = replies.map { $0.id == reply.id ? updated : $0 }
    }

    // MARK: Trade requests

    func sendRequest(to toID: String, toName: String, note: String,
                     take: [String], give: [String], daysValid: Int = 21,
                     ecb: Int? = nil, ecbValue: Double? = nil, offerID: String? = nil,
                     chain: [TradeLeg]? = nil, qualSwap: QualSwapLegData? = nil) async {
        let now = Date()
        // Sender-side "Perfect Match": does this hit the recipient's published intents? (U6 push)
        let recipient = TradeProfileStore.shared.profile(forWorker: toID)
        let isECB = ecbValue != nil && take.isEmpty
        let perfect = MessagingStore.requestPerfectMatch(
            give: give, take: take, isECB: isECB,
            recipientSeeking: recipient?.seekingDayIDs ?? [],
            recipientWantToWork: recipient?.wantToWorkDayIDs ?? [])
        let req = TradeRequest(
            id: UUID().uuidString, fromID: myID, fromName: myName,
            toID: toID, toName: toName, note: note,
            takeDayIDs: take, giveDayIDs: give, createdAt: now,
            expiresAt: Calendar.current.date(byAdding: .day, value: daysValid, to: now) ?? now,
            ecb: ecb, ecbValue: ecbValue, offerID: offerID, chain: chain, qualSwap: qualSwap,
            perfectMatch: perfect ? true : nil)
        await service.sendRequest(req)
        MetricsStore.shared.log(.proposed)   // H1 #18 global tally
        requests = ([req] + requests.filter { $0.id != req.id })
            .filter { !$0.isExpired }.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Qual-swap leg mutations (Q3/Q5/Q6)

    /// Re-send a request with an updated qual-swap leg (upsert), refreshing the local cache.
    private func updateQualSwapLeg(_ request: TradeRequest, _ leg: QualSwapLegData) async {
        var updated = request
        updated.qualSwap = leg
        await service.sendRequest(updated)
        requests = requests.map { $0.id == request.id ? updated : $0 }
    }

    /// A bridge (the current user) accepts the qual swap — adds their acceptance honoring
    /// the first-5 cap. No-op if they aren't a blasted candidate or the leg is filled.
    func acceptQualSwapBridge(_ request: TradeRequest) async {
        guard let leg = request.qualSwap,
              let cand = leg.candidates.first(where: { $0.workerID == myID }) else { return }
        let acc = QualSwapAcceptance(workerID: myID, name: myName, desk: cand.desk,
                                     qual: cand.qual, acceptedAt: Date())
        await updateQualSwapLeg(request, leg.addingAcceptance(acc))
    }

    /// The taker finalizes on a chosen bridge's offered desk (Q5 desk-choice) → leg locks.
    func finalizeQualSwap(_ request: TradeRequest, chosenWorkerID: String) async {
        guard var leg = request.qualSwap,
              leg.acceptances.contains(where: { $0.workerID == chosenWorkerID }) else { return }
        leg.chosenWorkerID = chosenWorkerID
        await updateQualSwapLeg(request, leg)
    }

    /// The taker declines → the whole package becomes invalid (reason: qual swap).
    func declineQualSwap(_ request: TradeRequest) async {
        guard var leg = request.qualSwap else { return }
        leg.takerDeclined = true
        await updateQualSwapLeg(request, leg)
    }

    func respond(to request: TradeRequest, status: TradeRequestStatus, note: String) async {
        let resp = TradeResponse(
            id: UUID().uuidString, requestID: request.id,
            responderID: myID, responderName: myName,
            status: status.rawValue, note: note, createdAt: Date(),
            offerID: request.offerID)
        await service.sendResponse(resp)
        responses = (responses.filter { $0.id != resp.id } + [resp]).sorted { $0.createdAt < $1.createdAt }
    }

    func cancelRequest(_ id: String) async {
        await service.deleteRequest(id: id)
        requests.removeAll { $0.id == id }
    }

    // MARK: Derived

    func responses(for requestID: String) -> [TradeResponse] {
        responses.filter { $0.requestID == requestID }
    }

    /// The latest decision on a request (newest non-chat response, else pending).
    /// Plain chat messages don't change accept/decline state.
    func status(of request: TradeRequest) -> TradeRequestStatus {
        responses(for: request.id).last { $0.statusValue != .message }?.statusValue ?? .pending
    }

    /// Post a free-form chat message on a request thread (either party, anytime).
    func isMine(_ r: TradeResponse) -> Bool { r.responderID == myID }

    /// Edit your own chat message (a `.message` response); stamps `editedAt`. B4.
    func editMessage(_ r: TradeResponse, newText: String) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let u = TradeResponse(id: r.id, requestID: r.requestID, responderID: r.responderID,
                              responderName: r.responderName, status: r.status, note: trimmed,
                              createdAt: r.createdAt, offerID: r.offerID, acceptedDayIDs: r.acceptedDayIDs,
                              editedAt: Date(), deleted: r.deleted)
        await service.sendResponse(u)
        responses = (responses.filter { $0.id != u.id } + [u]).sorted { $0.createdAt < $1.createdAt }
    }

    /// Soft-delete your own chat message → "[Deleted]" tombstone. B4.
    func softDeleteMessage(_ r: TradeResponse) async {
        let u = TradeResponse(id: r.id, requestID: r.requestID, responderID: r.responderID,
                              responderName: r.responderName, status: r.status, note: "",
                              createdAt: r.createdAt, offerID: r.offerID, acceptedDayIDs: r.acceptedDayIDs,
                              editedAt: r.editedAt, deleted: true)
        await service.sendResponse(u)
        responses = (responses.filter { $0.id != u.id } + [u]).sorted { $0.createdAt < $1.createdAt }
    }

    func postMessage(to request: TradeRequest, text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        await respond(to: request, status: .message, note: t)
    }

    var incoming: [TradeRequest] { requests.filter { $0.toID == myID } }
    var outgoing: [TradeRequest] { requests.filter { $0.fromID == myID } }

    /// Incoming requests still awaiting your reply — drives the inbox badge.
    var pendingIncoming: [TradeRequest] {
        incoming.filter { status(of: $0) == .pending }
    }

    // MARK: ECB broadcast offers (sender side)

    /// Your outgoing ECB broadcasts, grouped by offerID, newest first.
    var ecbOffers: [(offerID: String, requests: [TradeRequest])] {
        let ecb = outgoing.filter { $0.isECB && $0.offerID != nil }
        return Dictionary(grouping: ecb, by: { $0.offerID! })
            .map { ($0.key, $0.value.sorted { $0.toName < $1.toName }) }
            .sorted { ($0.requests.first?.createdAt ?? .distantPast) > ($1.requests.first?.createdAt ?? .distantPast) }
    }

    /// Keep up to 3 accepters queued per shift in case earlier ones fall through.
    static let ecbQueueCap = 3

    /// Distinct shift days in an ECB offer (across all recipients' requests).
    func ecbDays(offerID: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for req in requests where req.offerID == offerID {
            for d in req.giveDayIDs where seen.insert(d).inserted { out.append(d) }
        }
        return out.sorted()
    }

    /// Accepters for ONE shift of an ECB offer, first-come-first-served (one per
    /// responder). Public — derived from response `offerID` + `acceptedDayIDs`.
    func ecbQueue(offerID: String, dayID: String) -> [TradeResponse] {
        var seen = Set<String>()
        return responses
            .filter { $0.offerID == offerID && $0.statusValue == .accepted
                      && ($0.acceptedDayIDs?.contains(dayID) ?? false) }
            .sorted { $0.createdAt < $1.createdAt }
            .filter { seen.insert($0.responderID).inserted }
    }
    func acceptCount(offerID: String, dayID: String) -> Int { ecbQueue(offerID: offerID, dayID: dayID).count }
    func isECBFull(offerID: String, dayID: String) -> Bool { acceptCount(offerID: offerID, dayID: dayID) >= Self.ecbQueueCap }

    /// My 1-based position in a shift's queue (nil if I haven't accepted it).
    func myQueuePosition(offerID: String, dayID: String) -> Int? {
        guard let i = ecbQueue(offerID: offerID, dayID: dayID).firstIndex(where: { $0.responderID == myID }) else { return nil }
        return i + 1
    }

    /// Total acceptances across the offer (any shift) — the public count for the list.
    func acceptCount(offerID: String) -> Int {
        Set(responses.filter { $0.offerID == offerID && $0.statusValue == .accepted }.map(\.responderID)).count
    }

    /// Recipient: accept specific shifts of an ECB offer (employee # auto-included).
    func acceptECB(_ request: TradeRequest, days: [String]) async {
        let note = "Employee #\(myID). Accepting: " + days.map { DayFmt.nice($0) }.joined(separator: ", ")
        let resp = TradeResponse(
            id: UUID().uuidString, requestID: request.id, responderID: myID, responderName: myName,
            status: TradeRequestStatus.accepted.rawValue, note: note, createdAt: Date(),
            offerID: request.offerID, acceptedDayIDs: days)
        await service.sendResponse(resp)
        responses = (responses.filter { $0.id != resp.id } + [resp]).sorted { $0.createdAt < $1.createdAt }
    }

    /// Sender maintenance: auto-complete pending ledger rows when the recipient
    /// posts an "ECB RECEIVED" reply (no shared record needed).
    func reconcileECBLedger() {
        for e in TradeHistoryStore.shared.pending {
            guard let emp = e.employeeID else { continue }
            if responses.contains(where: { $0.responderID == emp && $0.note.localizedCaseInsensitiveContains("received") }) {
                TradeHistoryStore.shared.markComplete(id: e.id, at: Date())
            }
        }
    }

    #if DEBUG
    /// Drop a fake incoming request into your inbox so the accept/decline flow is
    /// testable solo (before anyone else is on CloudKit).
    func seedFakeIncoming() async {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd"
        let d1 = iso.string(from: cal.date(byAdding: .day, value: 3, to: today) ?? today)
        let d2 = iso.string(from: cal.date(byAdding: .day, value: 5, to: today) ?? today)
        let now = Date()
        let req = TradeRequest(
            id: UUID().uuidString, fromID: "TEST001", fromName: "Test Dispatcher",
            toID: myID, toName: myName,
            note: "Want to swap? I'd take your day, you take mine.",
            takeDayIDs: [d1], giveDayIDs: [d2], createdAt: now,
            expiresAt: cal.date(byAdding: .day, value: 21, to: now) ?? now)
        await service.sendRequest(req)
        await refresh()
        WidgetData.update()
    }
    #endif
}
