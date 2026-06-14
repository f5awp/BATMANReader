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
struct BroadcastPost: Sendable, Codable, Identifiable, Hashable {
    let id: String            // UUID string (recordName)
    let authorID: String
    let authorName: String
    let text: String
    let createdAt: Date
    let expiresAt: Date

    var isExpired: Bool { expiresAt < Date() }
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
    var ecb: Int? = nil        // ECB points offered for a one-way (ECB) trade
    var offerID: String? = nil // shared across the broadcast (first accepter wins)
    var chain: [TradeLeg]? = nil // present for multi-person (circular) trades: the full loop

    var isExpired: Bool { expiresAt < Date() }
    /// A one-way ECB offer = sender gives days, takes nothing back, offers points.
    var isECB: Bool { ecb != nil && takeDayIDs.isEmpty }
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

    var statusValue: TradeRequestStatus { TradeRequestStatus(rawValue: status) ?? .pending }
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
    func postReply(_ reply: BroadcastReply) async { replies.append(reply); Self.save(replies, K.replies) }
    func fetchReplies() async -> [BroadcastReply] { replies }
    func deleteReply(id: String) async { replies.removeAll { $0.id == id }; Self.save(replies, K.replies) }
    func hide(id targetID: String) async {
        if !hiddenIDs.contains(targetID) { hiddenIDs.append(targetID); Self.save(hiddenIDs, K.hidden) }
    }
    func fetchHidden() async -> Set<String> { Set(hiddenIDs) }

    func sendRequest(_ request: TradeRequest) async { reqs.append(request); Self.save(reqs, K.reqs) }
    func fetchRequests(involving workerID: String) async -> [TradeRequest] { reqs }
    func deleteRequest(id: String) async { reqs.removeAll { $0.id == id }; Self.save(reqs, K.reqs) }
    func sendResponse(_ response: TradeResponse) async { resps.append(response); Self.save(resps, K.resps) }
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
    private(set) var responses: [TradeResponse] = []
    private(set) var replies: [BroadcastReply] = []
    private(set) var hidden: Set<String> = []

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
        broadcasts = posts.filter { !$0.isExpired && !hidden.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
        requests   = reqs.filter { !$0.isExpired }.sorted { $0.createdAt > $1.createdAt }
        responses  = resps.sorted { $0.createdAt < $1.createdAt }
        replies    = reps.sorted { $0.createdAt < $1.createdAt }
        // ECB maintenance (sender side): auto-complete ledger on receipt.
        reconcileECBLedger()
    }

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

    func addReply(to post: BroadcastPost, text: String, isPublic: Bool) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let reply = BroadcastReply(
            id: UUID().uuidString, postID: post.id, authorID: myID, authorName: myName,
            text: trimmed, isPublic: isPublic, createdAt: Date())
        await service.postReply(reply)
        replies = (replies.filter { $0.id != reply.id } + [reply]).sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Broadcast channel

    func post(text: String, daysValid: Int = 21) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()
        let post = BroadcastPost(
            id: UUID().uuidString, authorID: myID, authorName: myName,
            text: trimmed, createdAt: now,
            expiresAt: Calendar.current.date(byAdding: .day, value: daysValid, to: now) ?? now)
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

    /// Edit your own post's text (keeps id/createdAt/expiry).
    func editPost(_ post: BroadcastPost, newText: String) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let updated = BroadcastPost(
            id: post.id, authorID: post.authorID, authorName: post.authorName,
            text: trimmed, createdAt: post.createdAt, expiresAt: post.expiresAt)
        await service.postBroadcast(updated)   // upsert
        broadcasts = broadcasts.map { $0.id == post.id ? updated : $0 }
    }

    func isMine(_ post: BroadcastPost) -> Bool { post.authorID == myID }

    // MARK: Trade requests

    func sendRequest(to toID: String, toName: String, note: String,
                     take: [String], give: [String], daysValid: Int = 21,
                     ecb: Int? = nil, offerID: String? = nil, chain: [TradeLeg]? = nil) async {
        let now = Date()
        let req = TradeRequest(
            id: UUID().uuidString, fromID: myID, fromName: myName,
            toID: toID, toName: toName, note: note,
            takeDayIDs: take, giveDayIDs: give, createdAt: now,
            expiresAt: Calendar.current.date(byAdding: .day, value: daysValid, to: now) ?? now,
            ecb: ecb, offerID: offerID, chain: chain)
        await service.sendRequest(req)
        requests = ([req] + requests.filter { $0.id != req.id })
            .filter { !$0.isExpired }.sorted { $0.createdAt > $1.createdAt }
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
