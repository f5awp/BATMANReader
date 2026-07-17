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
    var mentionedIDs: [String]? = nil // worker IDs @-mentioned in `text` — mirrored to a queryable CKRecord
                                      // field so a per-user "you were mentioned" push subscription can fire (B4).

    // EXPLICIT init — freezes the construction symbol so adding new optional fields above
    // doesn't churn the memberwise-init symbol (stale-link prevention; see TradeProfile).
    init(id: String, authorID: String, authorName: String, text: String, createdAt: Date, expiresAt: Date,
         channel: String? = nil, pinned: Bool? = nil, reactions: [Reaction]? = nil, imageBase64: String? = nil,
         mentionedIDs: [String]? = nil) {
        self.id = id; self.authorID = authorID; self.authorName = authorName; self.text = text
        self.createdAt = createdAt; self.expiresAt = expiresAt
        self.channel = channel; self.pinned = pinned; self.reactions = reactions; self.imageBase64 = imageBase64
        self.mentionedIDs = mentionedIDs
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
    var parentReplyID: String? = nil   // #9 Reddit threading: nil = top-level reply to the post;
                                       // otherwise a reply to another reply. Optional ⇒ old records decode.

    // EXPLICIT init — freezes the construction signature (stale-incremental-link fix); new optional
    // fields are set via assignment / passed explicitly, never churning callers' object files.
    init(id: String, postID: String, authorID: String, authorName: String, text: String,
         isPublic: Bool, createdAt: Date, editedAt: Date? = nil, deleted: Bool? = nil,
         reactions: [Reaction]? = nil, imageBase64: String? = nil, parentReplyID: String? = nil) {
        self.id = id; self.postID = postID; self.authorID = authorID; self.authorName = authorName
        self.text = text; self.isPublic = isPublic; self.createdAt = createdAt
        self.editedAt = editedAt; self.deleted = deleted; self.reactions = reactions
        self.imageBase64 = imageBase64; self.parentReplyID = parentReplyID
    }

    var isDeleted: Bool { deleted == true }
}

/// One reply positioned in a Reddit-style thread tree (its nesting `depth` drives indentation).
struct ThreadedReply: Identifiable, Sendable, Hashable {
    let reply: BroadcastReply
    let depth: Int
    var id: String { reply.id }
}

/// PURE thread-tree builder (#9). Flattens the flat reply list into a Reddit-style **pre-order** walk
/// — each reply immediately followed by its descendants — with siblings ordered **oldest→newest** (E1).
/// A reply whose parent is missing surfaces at the top level; cycles are broken by a visited set.
enum ReplyThread {
    static func flatten(_ replies: [BroadcastReply]) -> [ThreadedReply] {
        let byParent = Dictionary(grouping: replies) { $0.parentReplyID ?? "" }
        var out: [ThreadedReply] = []
        var visited = Set<String>()
        func emit(parentKey: String, depth: Int) {
            for k in (byParent[parentKey] ?? []).sorted(by: { $0.createdAt < $1.createdAt }) where !visited.contains(k.id) {
                visited.insert(k.id)
                out.append(ThreadedReply(reply: k, depth: depth))
                emit(parentKey: k.id, depth: depth + 1)
            }
        }
        emit(parentKey: "", depth: 0)   // explicit roots (parentReplyID nil/empty)
        // Anything still unvisited — an orphan (missing parent) or a member of a parent CYCLE — surfaces
        // at the top level so a reply is never silently dropped.
        for u in replies.sorted(by: { $0.createdAt < $1.createdAt }) where !visited.contains(u.id) {
            visited.insert(u.id)
            out.append(ThreadedReply(reply: u, depth: 0))
            emit(parentKey: u.id, depth: 1)
        }
        return out
    }

    /// IDs of `reply` and all its descendants — for per-comment collapse (hide a subtree).
    static func subtreeIDs(of replyID: String, in replies: [BroadcastReply]) -> Set<String> {
        let byParent = Dictionary(grouping: replies) { $0.parentReplyID ?? "" }
        var ids: Set<String> = []
        func walk(_ pid: String) {
            for k in byParent[pid] ?? [] where !ids.contains(k.id) { ids.insert(k.id); walk(k.id) }
        }
        walk(replyID)
        return ids
    }
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
/// Where a request originated, so the inbox can file it into Intents / Search / ECB / Misc.
/// Optional on the record (old requests decode as nil → Misc). Rides in the JSON payload,
/// so no CloudKit schema change is needed.
enum TradeOrigin: String, Codable, Sendable { case intents, search, ecb, manual }

/// Which inbox tab a request files under. PURE (harness-testable) — the single source of truth the
/// inbox view calls. Tabs: 0 Intents · 1 Search · 2 ECB · 3 Qual Swap (the renamed "Misc" catch-all,
/// which also absorbs bridge blasts and legacy `.manual`/nil-origin records).
nonisolated enum TradeInboxTab {
    static let intents = 0, search = 1, ecb = 2, qualSwap = 3
    static func index(for r: TradeRequest, myID: String) -> Int {
        if r.isECB { return ecb }
        if r.qualSwap != nil { return qualSwap }                       // qual-swap taker/giver
        if !(r.fromID == myID || r.toID == myID) { return qualSwap }   // qual-swap bridge blast (I'm a candidate)
        switch r.inboxOrigin {
        case .intents: return intents
        case .search:  return search
        case .ecb:     return ecb
        case .manual:  return qualSwap   // legacy/unknown → the Qual Swap catch-all
        }
    }
}

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
    var origin: TradeOrigin? = nil       // inbox filing (intents/search/ecb/manual). Optional ⇒ old records → Misc.
    var loopID: String? = nil            // shared across the N per-participant requests of ONE circular-loop send;
                                         // nil for a plain 2-way/single request. Set post-construction (frozen init).
    // Match Radar §9b — ALTERNATES the sender is also open to, so the recipient can counter with a different
    // day than the one proposed. Same orientation as the primary fields (altGive = other of MY days you'd
    // take; altTake = other of YOUR days I'd take). Optional ⇒ old records decode; set post-construction.
    var altGiveDayIDs: [String]? = nil
    var altTakeDayIDs: [String]? = nil
    // Match Radar: the standing offer this request fulfills (if any), so the offer auto-closes on accept.
    var standingOfferID: String? = nil
    // Match Radar ECB: the offered method. `.both` lets the acceptor choose day-for-day OR ECB points in ONE
    // card; `.ecb`/`.day`/nil behave as before. Set post-construction (frozen init). Optional ⇒ old records decode.
    var offerKind: TradeKind? = nil
    // Match Radar ECB: when the ECB will be paid — a FUTURE date makes it an IOU (posted then, not now).
    var ecbAvailableDate: Date? = nil

    /// Where this request files in the inbox. ECB always wins; otherwise the stored origin, else Misc.
    var inboxOrigin: TradeOrigin { isECB ? .ecb : (origin ?? .manual) }

    /// An auto-match the radar sent/received (any method — Day, Both, or ECB). Files under the Auto-Matches
    /// section, NOT the manual Requests tabs. Manual ECB Finder offers keep origin `.ecb`, so they stay in ECB.
    var isAutoProposed: Bool { origin == .intents }

    /// Grouping key: a circular loop's N per-participant requests share one `loopID` and collapse to a
    /// single inbox card / merged thread; a plain (2-way / single) request groups on its own id.
    var groupKey: String {
        if let loopID { return loopID }
        if !isECB, let offerID { return offerID }   // standing-offer broadcast legs collapse into ONE card
        return id
    }

    /// A leg of a standing-offer broadcast (shared non-ECB offerID) — the owner sees all N legs as one card.
    var isBroadcastLeg: Bool { offerID != nil && !isECB }

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

    /// The acceptor may take this as ECB points — a pure one-way ECB, or a `.both` dual offer.
    var offersECB: Bool { isECB || offerKind == .ecb || offerKind == .both }
    /// The acceptor may take this as a day-for-day swap — there's a reciprocal day to give back.
    var offersDayForDay: Bool { !takeDayIDs.isEmpty && offerKind != .ecb }
    /// A genuine either/or: the acceptor chooses day-for-day OR ECB in one card.
    var offersChoice: Bool { offersECB && offersDayForDay }
    /// This ECB is an IOU — paid on a future date rather than on acceptance.
    var isECBIOU: Bool { (ecbAvailableDate.map { $0 > Date() }) ?? false }

    /// ECB is offered in 0.5 steps, 5…25 (SPEC S-ENG-8).
    static func isValidECB(_ v: Double) -> Bool { v >= 5 && v <= 25 && (v * 2).rounded() == v * 2 }
    static func clampECB(_ v: Double) -> Double { min(25, max(5, (v * 2).rounded() / 2)) }
}

/// B2: compose an accepted qual-swap **bridge** request into its **base** trade so the two become
/// one request (a qual swap is structurally a normal trade + a middle-man leg on the same day).
/// Pure → harness-tested; the messaging lifecycle (archive originals, save the merged record) is
/// layered on top by `MessagingStore`.
enum TradeMerge {
    /// Mergeable iff the base is a CLEAN trade (no qual-swap yet), the bridge HAS a qual-swap, they're
    /// distinct, and the bridge's give-day is one of the base's give-days (same day in play).
    static func canMerge(base: TradeRequest, bridge: TradeRequest) -> Bool {
        guard base.qualSwap == nil, let leg = bridge.qualSwap, base.id != bridge.id else { return false }
        return base.giveDayIDs.contains(leg.giveShiftDayID)
    }
    /// The combined request: the base trade carrying the bridge's qual-swap leg, under a new id.
    /// A no-op (returns `base`) when `!canMerge` — so merging twice is idempotent.
    static func merge(base: TradeRequest, bridge: TradeRequest) -> TradeRequest {
        guard canMerge(base: base, bridge: bridge) else { return base }
        return TradeRequest(id: "merged-\(base.id)-\(bridge.id)", fromID: base.fromID, fromName: base.fromName,
                            toID: base.toID, toName: base.toName,
                            note: base.note.isEmpty ? "Trade incl. a qual swap" : base.note + " (incl. qual swap)",
                            takeDayIDs: base.takeDayIDs, giveDayIDs: base.giveDayIDs,
                            createdAt: base.createdAt, expiresAt: base.expiresAt,
                            ecb: base.ecb, ecbValue: base.ecbValue, offerID: base.offerID,
                            chain: base.chain, qualSwap: bridge.qualSwap, perfectMatch: base.perfectMatch)
    }

    /// PURE: the clean base request a `bridge` (qual-swap) can merge into, if any — searched among the
    /// candidates (e.g. the active inbox). Drives whether the "Merge with base trade" button shows.
    static func findBase(for bridge: TradeRequest, in candidates: [TradeRequest]) -> TradeRequest? {
        candidates.first { canMerge(base: $0, bridge: bridge) }
    }
}

/// B6-AUTOCOMPLETE: prove that a proposed trade actually went through by reading the MASTER schedule.
/// When a new master flips MY schedule to match a pending trade (my give-days now OFF, my take-days now
/// worked), the trade completed on the board even if I never pressed Accept. PURE → harness-tested; the
/// messaging lifecycle (mark accepted, archive, log the stat, record history) is layered on in the store.
enum TradeProof {
    /// The days THIS request moves on MY schedule: `give` = days I hand away (working → OFF), `take` = days
    /// I pick up (OFF → working). Uses the chain for multi-person loops, else the 2-way from/to role.
    static func myLegs(_ r: TradeRequest, myID: String) -> (give: Set<String>, take: Set<String>) {
        if let chain = r.chain, !chain.isEmpty {
            return (Set(chain.filter { $0.fromID == myID }.map { $0.dayID }),
                    Set(chain.filter { $0.toID == myID }.map { $0.dayID }))
        }
        if myID == r.fromID { return (Set(r.giveDayIDs), Set(r.takeDayIDs)) }
        if myID == r.toID   { return (Set(r.takeDayIDs), Set(r.giveDayIDs)) }
        return ([], [])
    }

    /// Days that flipped working→OFF and OFF→working in a schedule diff (the master-import transitions).
    static func transitions(_ diff: ScheduleDiff) -> (becameOff: Set<String>, becameWorking: Set<String>) {
        var off = Set<String>(), work = Set<String>()
        for c in diff.changed {
            if !c.old.isOff && c.new.isOff { off.insert(c.new.id) }
            if c.old.isOff && !c.new.isOff { work.insert(c.new.id) }
        }
        for s in diff.removed where !s.isOff { off.insert(s.id) }   // a working day that vanished = now off
        for s in diff.added   where !s.isOff { work.insert(s.id) }  // a brand-new working day
        return (off, work)
    }

    /// PROVED iff the request touches my schedule AND every one of my give-days flipped to OFF and every
    /// take-day flipped to working in THIS import. Requiring ALL my legs (never a subset) is the
    /// false-positive guard — a stray admin edit won't match a full multi-day, directional leg set.
    static func proved(give: Set<String>, take: Set<String>,
                       becameOff: Set<String>, becameWorking: Set<String>) -> Bool {
        guard !(give.isEmpty && take.isEmpty) else { return false }
        return give.isSubset(of: becameOff) && take.isSubset(of: becameWorking)
    }
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
    /// Whether moving onto the give-desk is an equal-or-better qual preference for this bridge (Q4). Default
    /// `true` so older records / non-annotated candidates behave as favorable. `false` → UI warns (a stretch).
    var favorable: Bool = true
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
    var imageBase64: String? = nil   // attached photo on a 1:1 chat message (downscaled JPEG, base64) — #28.
    var acceptedKind: TradeKind? = nil // Match Radar: the method the taker chose accepting a Both offer (day/ecb),
                                       // so the giver sees each responder's pick. Set post-init; optional ⇒ old records decode.
    var notifyID: String? = nil        // the counterparty to push ("someone responded to your request") —
                                       // mirrored to a flat, queryable CKRecord field. Set post-init; optional ⇒ old records decode.

    // EXPLICIT init — freezes the construction signature (stale-incremental-link fix).
    init(id: String, requestID: String, responderID: String, responderName: String,
         status: String, note: String, createdAt: Date, offerID: String? = nil,
         acceptedDayIDs: [String]? = nil, editedAt: Date? = nil, deleted: Bool? = nil,
         reactions: [Reaction]? = nil, imageBase64: String? = nil) {
        self.id = id; self.requestID = requestID; self.responderID = responderID
        self.responderName = responderName; self.status = status; self.note = note
        self.createdAt = createdAt; self.offerID = offerID; self.acceptedDayIDs = acceptedDayIDs
        self.editedAt = editedAt; self.deleted = deleted; self.reactions = reactions
        self.imageBase64 = imageBase64
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
    /// Set when a send is denied because the recipient has no active profile (not on the app). The UI
    /// observes this to show a "can't message" alert, then clears it.
    var blockedRecipient: String? = nil

    /// Set when a proposal is blocked because an equivalent trade already exists (either direction). The UI
    /// observes this to show a "duplicate — check your inbox" alert, then clears it.
    var duplicateNotice: String? = nil

    /// Set when a send/accept is blocked because a day is already committed to an accepted trade. The UI
    /// shows a "you already traded that day — offer another" alert, then clears it.
    var committedNotice: String? = nil

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

    // MARK: Per-trade "new activity" tracking (TRADE-INBOX Stage 6)
    /// When the user last OPENED each trade loop (keyed by `groupKey`). A counter/message/accept from
    /// someone else after this marks the loop "new" until reopened. Local per-device.
    private static let tradeSeenKey = "batman.msg.tradeLastSeen"
    private(set) var tradeLastSeen: [String: Date] = {
        (UserDefaults.standard.dictionary(forKey: tradeSeenKey) as? [String: Date]) ?? [:]
    }()
    /// Call when a trade thread opens — clears its "new" dot.
    func markTradeSeen(_ groupKey: String) {
        tradeLastSeen[groupKey] = Date()
        UserDefaults.standard.set(tradeLastSeen, forKey: Self.tradeSeenKey)
    }
    /// PURE, testable: is there a response from SOMEONE ELSE newer than `since`?
    static func hasNewActivity(responses: [TradeResponse], since: Date?, myID: String) -> Bool {
        let cutoff = since ?? .distantPast
        return responses.contains { $0.createdAt > cutoff && $0.responderID != myID && $0.statusValue != .cancelled }
    }
    /// Whether a loop (all legs sharing `groupKey`) has activity from others since it was last seen.
    func loopHasNewActivity(_ groupKey: String) -> Bool {
        let legIDs = Set(requests.filter { $0.groupKey == groupKey }.map(\.id))
        let rs = responses.filter { legIDs.contains($0.requestID) }
        return Self.hasNewActivity(responses: rs, since: tradeLastSeen[groupKey], myID: myID)
    }

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

    /// PURE, testable: collapse a circular loop's N per-participant requests (same `loopID`) to ONE
    /// representative card. A plain request (no `loopID`) groups on its own id, so it's untouched — as
    /// are ECB and qual-swap requests (no `loopID`). Representative = lowest `id` per group (deterministic,
    /// stable across refreshes). Input order is otherwise preserved (first appearance of each group wins).
    static func dedupeLoops(_ requests: [TradeRequest]) -> [TradeRequest] {
        var repByGroup: [String: TradeRequest] = [:]
        for r in requests {
            if let cur = repByGroup[r.groupKey] { if r.id < cur.id { repByGroup[r.groupKey] = r } }
            else { repByGroup[r.groupKey] = r }
        }
        var seen = Set<String>(); var out: [TradeRequest] = []
        for r in requests where !seen.contains(r.groupKey) {
            seen.insert(r.groupKey)
            out.append(repByGroup[r.groupKey] ?? r)
        }
        return out
    }

    /// PURE, testable: the single status to show for a whole circular loop, given each leg's status. A loop
    /// completes only when EVERY leg accepts; any decline/cancel kills it; a counter needs attention.
    /// Precedence (most→least urgent to surface): declined > cancelled > countered(Replied) > pending > accepted.
    static func loopStatus(_ legStatuses: [TradeRequestStatus]) -> TradeRequestStatus {
        if legStatuses.contains(.declined)  { return .declined }
        if legStatuses.contains(.cancelled) { return .cancelled }
        if legStatuses.contains(.countered) { return .countered }
        if legStatuses.contains(.pending)   { return .pending }
        return legStatuses.isEmpty ? .pending : .accepted   // all legs accepted
    }

    /// PURE, testable: the status to show for a first-accept-wins BROADCAST (a standing-offer fan-out). Unlike
    /// a loop, ONE accept wins the whole offer; still-live beats settled. Precedence:
    /// accepted > countered > pending > declined > cancelled.
    static func broadcastStatus(_ legStatuses: [TradeRequestStatus]) -> TradeRequestStatus {
        if legStatuses.contains(.accepted)  { return .accepted }   // first-accept-wins
        if legStatuses.contains(.countered) { return .countered }
        if legStatuses.contains(.pending)   { return .pending }
        if legStatuses.contains(.declined)  { return .declined }
        return legStatuses.isEmpty ? .pending : .cancelled
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
        await reconcileMirrorDuplicates()  // both sides auto-sent the same swap → collapse to one
        await refreshInvalidRequests()
    }

    /// When BOTH parties auto-match the same swap at once, A→B and B→A can both be written before either
    /// syncs (past the send-time dedup guard). This collapses each such mirror pair to ONE pending request —
    /// deterministically keeping the one whose SENDER id sorts first, so every device agrees and cancels the
    /// same duplicate. (Direction-agnostic `tradeKey`; non-ECB pending only.)
    func reconcileMirrorDuplicates() async {
        var byKey: [String: [TradeRequest]] = [:]
        for r in Self.active(requests, archived: archivedRequestIDs) where !r.isECB && status(of: r) == .pending {
            byKey[Self.tradeKey(r.fromID, r.toID, dayIDs: Set(r.giveDayIDs + r.takeDayIDs)), default: []].append(r)
        }
        for (_, group) in byKey where group.count > 1 {
            guard let keep = group.min(by: { $0.fromID < $1.fromID }) else { continue }
            for r in group where r.id != keep.id && (r.fromID == myID || r.toID == myID) {
                if r.fromID == myID { await service.deleteRequest(id: r.id); requests.removeAll { $0.id == r.id } }
                else { await respond(to: r, status: .cancelled, note: "Consolidated — this matches a trade already in progress.") }
            }
        }
    }

    /// GIVER PICKS among the up-to-3 takers of a day-for-day / Both broadcast: cancel every OTHER leg of the
    /// same `offerID` (pending bids that lost, or a competing accept), leaving `picked` as the trade that goes
    /// through. Owner-side (I own every leg). A solo (1-recipient) offer has no `offerID`, so it just
    /// auto-finalizes on the taker's accept — no pick needed. (ECB uses its own per-shift queue in ECBOfferView.)
    func finalizeBroadcastPick(_ picked: TradeRequest) async {
        guard picked.fromID == myID, let offerID = picked.offerID else { return }
        for leg in requests where leg.offerID == offerID && leg.fromID == myID && leg.id != picked.id {
            let st = status(of: leg)
            guard st == .pending || st == .accepted else { continue }
            await respond(to: leg, status: .cancelled, note: "You chose another dispatcher for this trade.")
        }
    }

    /// The takers who have ACCEPTED a broadcast I sent (their bids), each with the method they chose — so the
    /// giver can compare and pick. Keyed to one `offerID`. Empty for a non-broadcast or if no one has accepted.
    func broadcastBids(offerID: String) -> [(leg: TradeRequest, kind: TradeKind?)] {
        requests.filter { $0.offerID == offerID && $0.fromID == myID && status(of: $0) == .accepted }
            .map { leg in
                let kind = responses.first { $0.requestID == leg.id && $0.statusValue == .accepted }?.acceptedKind
                return (leg, kind)
            }
            .sorted { $0.leg.toName < $1.leg.toName }
    }

    /// S-VALID: recompute which active (non-ECB) requests are stale against the live roster.
    /// Auto-clears — a reversed schedule drops the request out on the next refresh.
    func refreshInvalidRequests() async {
        var invalid = Set<String>()
        var staleByReq: [String: Set<String>] = [:]
        for req in requests where !req.isECB {
            let stale = await TradeMatcher.staleDays(fromID: req.fromID, toID: req.toID,
                                                     giveDayIDs: req.giveDayIDs, takeDayIDs: req.takeDayIDs)
            if !stale.isEmpty { invalid.insert(req.id); staleByReq[req.id] = stale }
        }
        // Notify BOTH sides (each device runs this) about a trade of THEIRS that JUST became invalid — naming
        // the day that changed. Runs per user, so the giver and the taker each get their own alert.
        let newlyInvalid = invalid.subtracting(invalidRequestIDs)
        var alerts: [(peer: String, day: String)] = []
        for req in requests where newlyInvalid.contains(req.id) && (req.fromID == myID || req.toID == myID) {
            let st = status(of: req)
            guard st == .pending || st == .countered || st == .accepted else { continue }   // only live trades
            guard let day = staleByReq[req.id]?.sorted().first else { continue }
            alerts.append((peer: req.fromID == myID ? req.toName : req.fromName, day: day))
        }
        invalidRequestIDs = invalid
        if !alerts.isEmpty { await NotificationManager.shared.notifyTradesInvalid(alerts) }
    }

    /// Whether this request is currently invalid (a traded day is no longer worked).
    func isInvalid(_ request: TradeRequest) -> Bool { invalidRequestIDs.contains(request.id) }

    /// Active trades of MINE that are invalid (a day changed) and still need action — for the daily digest.
    var actionableInvalidCount: Int {
        Self.active(requests, archived: archivedRequestIDs)
            .filter { ($0.fromID == myID || $0.toID == myID) && invalidRequestIDs.contains($0.id) }
            .count
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

    /// `parentReplyID` nests this under another reply (Reddit threading, #9); nil = top-level reply.
    func addReply(to post: BroadcastPost, text: String, isPublic: Bool,
                  imageBase64: String? = nil, parentReplyID: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || imageBase64 != nil else { return }
        let reply = BroadcastReply(
            id: UUID().uuidString, postID: post.id, authorID: myID, authorName: myName,
            text: trimmed, isPublic: isPublic, createdAt: Date(), imageBase64: imageBase64,
            parentReplyID: parentReplyID)
        await service.postReply(reply)
        replies = (replies.filter { $0.id != reply.id } + [reply]).sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Broadcast channel

    func post(text: String, channel: String = "trades", daysValid: Int = 21, imageBase64: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || imageBase64 != nil else { return }   // allow image-only posts
        let now = Date()
        let mentioned = Mentions.mentionedIDs(in: trimmed).filter { $0 != myID }  // don't ping yourself
        let post = BroadcastPost(
            id: UUID().uuidString, authorID: myID, authorName: myName,
            text: trimmed, createdAt: now,
            expiresAt: Calendar.current.date(byAdding: .day, value: daysValid, to: now) ?? now,
            channel: channel, imageBase64: imageBase64,
            mentionedIDs: mentioned.isEmpty ? nil : mentioned)
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
            reactions: Reaction.setSingle(response.reactions ?? [], emoji: emoji, userID: myID, userName: myName),
            imageBase64: response.imageBase64)
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
            return a.createdAt > b.createdAt                     // then NEWEST first (latest posts at the top)
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
                     chain: [TradeLeg]? = nil, qualSwap: QualSwapLegData? = nil,
                     origin: TradeOrigin = .manual, loopID: String? = nil,
                     altGive: [String]? = nil, altTake: [String]? = nil, standingOfferID: String? = nil,
                     offerKind: TradeKind? = nil, ecbAvailableDate: Date? = nil) async {
        let now = Date()
        // Sender-side "Perfect Match": does this hit the recipient's published intents? (U6 push)
        let recipient = TradeProfileStore.shared.profile(forWorker: toID)
        // GATE: only a REAL signed-in account (profile stamped `accountClaimed`) can receive anything —
        // a legacy/orphan profile record does NOT count. Deny + surface to the UI (they still appear in
        // matches; behavior is just inferred).
        guard toID == myID || recipient?.accountClaimed == true else {
            blockedRecipient = toName
            return
        }
        let isECB = ecbValue != nil && take.isEmpty
        // Duplicate guard: for a fresh two-way proposal (not a counter/loop leg, not ECB), block it if an
        // active trade for the SAME days between the same two people already exists in EITHER direction —
        // so when both sides of a match try to propose, the second is caught instead of creating a twin.
        if loopID == nil, !isECB, !(take.isEmpty && give.isEmpty),
           let dup = existingActiveTrade(with: toID, dayIDs: Set(take + give)) {
            duplicateNotice = dup.fromID == myID
                ? "You already have a pending trade with \(toName) for these days — check your inbox."
                : "\(toName) already proposed this trade — reply to it in your inbox instead of sending a duplicate."
            return
        }
        // Same-day lock: can't give OR take a day already committed to an accepted trade — offer another day.
        if loopID == nil, !isECB {
            let committed = committedDayIDs()
            if let clash = Set(take + give).sorted().first(where: committed.contains) {
                committedNotice = "You already traded \(DayFmt.nice(clash)) — offer a different day."
                return
            }
        }
        let perfect = MessagingStore.requestPerfectMatch(
            give: give, take: take, isECB: isECB,
            recipientSeeking: recipient?.seekingDayIDs ?? [],
            recipientWantToWork: recipient?.wantToWorkDayIDs ?? [])
        var req = TradeRequest(
            id: UUID().uuidString, fromID: myID, fromName: myName,
            toID: toID, toName: toName, note: note,
            takeDayIDs: take, giveDayIDs: give, createdAt: now,
            expiresAt: Calendar.current.date(byAdding: .day, value: daysValid, to: now) ?? now,
            ecb: ecb, ecbValue: ecbValue, offerID: offerID, chain: chain, qualSwap: qualSwap,
            perfectMatch: perfect ? true : nil)
        req.origin = origin   // keep the caller's origin (inboxOrigin still files ECB under the ECB tab); this
                              // preserves .intents on an auto-match ECB so it lands in Auto-Matches, not manual ECB
        req.loopID = loopID                   // set for circular-loop legs so the N requests group as one
        // §9b: carry alternates (drop any that duplicate the primary selection, and empties → nil).
        let ag = (altGive ?? []).filter { !give.contains($0) }
        let at = (altTake ?? []).filter { !take.contains($0) }
        req.altGiveDayIDs = ag.isEmpty ? nil : ag
        req.altTakeDayIDs = at.isEmpty ? nil : at
        req.standingOfferID = standingOfferID
        req.offerKind = offerKind
        req.ecbAvailableDate = ecbAvailableDate
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

    /// B2: fuse an accepted qual-swap `bridge` into its clean `base` trade — one request supersedes
    /// the two. Saves the merged record and ARCHIVES both originals (reversible; not deleted, so no
    /// CloudKit cross-user delete and no split-brain accept state). Returns the merged request, or nil
    /// if they aren't mergeable.
    @discardableResult
    func mergeRequests(base: TradeRequest, bridge: TradeRequest) async -> TradeRequest? {
        guard TradeMerge.canMerge(base: base, bridge: bridge) else { return nil }
        let merged = TradeMerge.merge(base: base, bridge: bridge)
        await service.sendRequest(merged)
        requests = (requests.filter { $0.id != merged.id } + [merged]).sorted { $0.createdAt < $1.createdAt }
        archiveRequest(base.id)
        archiveRequest(bridge.id)
        return merged
    }

    /// H2: a partner's learned acceptance PRIOR (logit) from their accept/decline responses — feeds
    /// the Intents ranking tiebreaker so partners who historically say yes float up.
    func partnerAcceptanceLogOdds(_ workerID: String) -> Double {
        var accepted = 0, declined = 0
        for r in responses where r.responderID == workerID {
            switch r.statusValue {
            case .accepted: accepted += 1
            case .declined: declined += 1
            default:        break
            }
        }
        return PersonPrior.logOdds(accepted: accepted, declined: declined)
    }

    /// H2 (bulk): ONE pass over `responses` → every responder's acceptance prior (logit). Built once
    /// per search and threaded through scoring, so the per-leg prior is an O(1) dictionary lookup
    /// instead of re-scanning ALL responses per leg per package (the `legFeatures` × packages hot path).
    /// Workers with no history are simply absent → the caller defaults them to a neutral 0. (U-PERF.)
    func acceptancePriorMap() -> [String: Double] {
        var tally: [String: (acc: Int, dec: Int)] = [:]
        for r in responses {
            switch r.statusValue {
            case .accepted: tally[r.responderID, default: (0, 0)].acc += 1
            case .declined: tally[r.responderID, default: (0, 0)].dec += 1
            default:        break
            }
        }
        return tally.mapValues { PersonPrior.logOdds(accepted: $0.acc, declined: $0.dec) }
    }

    /// The clean active base a qual-swap `bridge` can merge into (nil = none / not mergeable). Linkable once
    /// a bridge has COMMITTED — finalized OR ≥1 acceptance. A bridge-FIRST request (no taker yet) never
    /// finalizes, so an acceptance is enough to fuse it into a base A→B trade on the same give-day. (D6.)
    func mergeBase(for bridge: TradeRequest) -> TradeRequest? {
        guard let leg = bridge.qualSwap, leg.status == .finalized || !leg.acceptances.isEmpty else { return nil }
        return TradeMerge.findBase(for: bridge, in: Self.active(requests, archived: archivedRequestIDs))
    }

    /// The taker declines → the whole package becomes invalid (reason: qual swap).
    func declineQualSwap(_ request: TradeRequest) async {
        guard var leg = request.qualSwap else { return }
        leg.takerDeclined = true
        await updateQualSwapLeg(request, leg)
    }

    /// PARTIAL ACCEPT (D7): accept only SOME of the offered days by countering back to the sender with the
    /// kept legs (perspective-flipped: their give = my take, their take = my give). Marks the original
    /// `.countered` and sends the trimmed counter, which the sender accepts to finalize.
    func counterWithSubset(_ request: TradeRequest, keepDays: Set<String>) async {
        // §9b: the counter pool includes the sender's ALTERNATES, so I can counter with a day they offered
        // as an alternative rather than only the one they picked. (sender's TAKE ∪ altTake = my give pool;
        // sender's GIVE ∪ altGive = my take pool.)
        let givePool = request.takeDayIDs + (request.altTakeDayIDs ?? [])
        let takePool = request.giveDayIDs + (request.altGiveDayIDs ?? [])
        let myGive = givePool.filter(keepDays.contains)   // sender's TAKE = my give
        let myTake = takePool.filter(keepDays.contains)   // sender's GIVE = my take
        guard !myGive.isEmpty || !myTake.isEmpty else { return }
        // Carry the qual-swap leg only if its give-day survived the trim.
        let leg = request.qualSwap.flatMap { keepDays.contains($0.giveShiftDayID) ? $0 : nil }
        // Structured package on the .countered response (renders as a package card in the thread),
        // and link the reciprocal counter-request into the SAME group (loopID) so the whole negotiation
        // is ONE card + one merged thread (TRADE-INBOX Stage 8).
        await respond(to: request, status: .countered,
                      note: "Counter — accepting \(DayFmt.list(Array(keepDays))).",
                      acceptedDayIDs: Array(keepDays))
        await sendRequest(to: request.fromID, toName: request.fromName,
                          note: "Counter: I can do these days.",
                          take: myTake, give: myGive, qualSwap: leg,
                          origin: request.inboxOrigin, loopID: request.groupKey)
    }

    func respond(to request: TradeRequest, status: TradeRequestStatus, note: String,
                 imageBase64: String? = nil, acceptedDayIDs: [String]? = nil) async {
        // Never persist a note-less counter — it renders as a blank "counter-offer" row (TRADE-INBOX Stage 7).
        // Accept/decline legitimately carry no note (they show as a status line), so this guards `.countered` only.
        if status == .countered, note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, imageBase64 == nil { return }
        // Same-day lock: can't accept/counter a trade whose day I already committed to another accepted trade.
        if status == .accepted || status == .countered, let clash = committedConflictDay(request) {
            committedNotice = "You already traded \(DayFmt.nice(clash)) — this trade is no longer possible. Offer a different day."
            return
        }
        var resp = TradeResponse(
            id: UUID().uuidString, requestID: request.id,
            responderID: myID, responderName: myName,
            status: status.rawValue, note: note, createdAt: Date(),
            offerID: request.offerID, acceptedDayIDs: acceptedDayIDs, imageBase64: imageBase64)
        if status == .accepted, request.offersDayForDay { resp.acceptedKind = .day }   // taker chose the swap
        // A DECISION response (accept/decline/counter) pushes the request's owner: the counterparty relative to
        // me. Plain chat (.message) doesn't — the thread's new-activity dot covers that.
        // COALESCE: only the FIRST responder in a group (a broadcast offer / loop shares one groupKey) pushes
        // the owner — later responders are visible in-app but don't re-buzz. CloudKit can't collapse background
        // pushes server-side, so we suppress the trigger at the source instead. (Simultaneous responders that
        // haven't synced each other's response yet may both push — an acceptable edge case.)
        if status != .message {
            let owner = (request.fromID == myID) ? request.toID : request.fromID
            let legIDs = Set(requests.filter { $0.groupKey == request.groupKey }.map(\.id))
            let priorResponse = responses.contains {
                legIDs.contains($0.requestID) && $0.responderID != myID
                    && $0.statusValue != .message && $0.statusValue != .cancelled
            }
            resp.notifyID = priorResponse ? nil : owner
        }
        await service.sendResponse(resp)
        responses = (responses.filter { $0.id != resp.id } + [resp]).sorted { $0.createdAt < $1.createdAt }
        // B6-ECB: an ECB offer accepted via the generic path also auto-posts (de-duped by requestID). An IOU
        // (future available-date) posts on that date; otherwise now.
        if status == .accepted, request.isECB, let amt = request.ecbAmount {
            ECBAccountingStore.shared.autoInsertAcceptedTrade(
                requestID: request.id, payerID: request.fromID, payerName: request.fromName,
                payeeID: myID, payeeName: myName, amount: amt,
                date: request.isECBIOU ? (request.ecbAvailableDate ?? Date()) : Date())
        }
    }

    func cancelRequest(_ id: String) async {
        await service.deleteRequest(id: id)
        requests.removeAll { $0.id == id }
    }

    /// B6-AUTOCOMPLETE: after a master-schedule import, auto-complete any ACTIVE trade the new schedule
    /// proves went through (my give-days now OFF + take-days now worked) — even if I never pressed Accept.
    /// Marks it accepted (synced), archives it (fires the successful-trade metric), and records it in the
    /// cross-device history. Only ever pending/countered → completed; declined trades are left alone.
    func autoCompleteProvenTrades(diff: ScheduleDiff) async {
        guard !myID.isEmpty else { return }
        let (becameOff, becameWorking) = TradeProof.transitions(diff)
        guard !becameOff.isEmpty || !becameWorking.isEmpty else { return }
        for req in Self.active(requests, archived: archivedRequestIDs) {
            let st = status(of: req)
            guard st == .pending || st == .countered || st == .accepted else { continue }  // never resurrect declined/cancelled
            let legs = TradeProof.myLegs(req, myID: myID)
            guard TradeProof.proved(give: legs.give, take: legs.take,
                                    becameOff: becameOff, becameWorking: becameWorking) else { continue }
            if st != .accepted {
                await respond(to: req, status: .accepted,
                              note: "Auto-confirmed — the master schedule now shows this trade went through.")
            }
            archiveRequest(req.id)   // status is accepted now → logs the successful-trade metric (once)
            let dayIDs = req.chain?.map { $0.dayID } ?? (req.giveDayIDs + req.takeDayIDs)
            let names = req.chain.map { Array(Set($0.flatMap { [$0.fromName, $0.toName] })) } ?? [req.fromName, req.toName]
            TradeHistoryStore.shared.record(TradeHistoryEntry(
                id: "trade-\(req.id)",   // deterministic → record() de-dupes, never double-posts
                summary: "\(req.fromName) ⇄ \(req.toName)", participants: names,
                dayIDs: dayIDs, completedAt: Date()))
        }
    }

    // MARK: Derived

    func responses(for requestID: String) -> [TradeResponse] {
        responses.filter { $0.requestID == requestID }
    }

    /// All responses across EVERY leg of a loop (grouped by `groupKey`), so a circular trade shows ONE
    /// merged conversation — counters + messages from every participant, in order. For a plain (single)
    /// request this is identical to `responses(for:)`. (TRADE-INBOX Stage 7)
    func responses(forLoop groupKey: String) -> [TradeResponse] {
        let legIDs = Set(requests.filter { $0.groupKey == groupKey }.map(\.id))
        return Self.responsesForLoop(responses, legIDs: legIDs)
    }
    /// PURE, testable core of the merged-thread fetch.
    static func responsesForLoop(_ responses: [TradeResponse], legIDs: Set<String>) -> [TradeResponse] {
        responses.filter { legIDs.contains($0.requestID) }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The latest decision on a request (newest non-chat response, else pending).
    /// Plain chat messages don't change accept/decline state.
    func status(of request: TradeRequest) -> TradeRequestStatus {
        responses(for: request.id).last { $0.statusValue != .message }?.statusValue ?? .pending
    }

    /// PURE, testable: a DIRECTION-AGNOSTIC key for "the same trade" — the unordered participant pair + the
    /// set of days in play. A→B give G/take T and B→A give T/take G collapse to the same key.
    static func tradeKey(_ a: String, _ b: String, dayIDs: Set<String>) -> String {
        [a, b].sorted().joined(separator: "~") + "|" + dayIDs.sorted().joined(separator: ",")
    }

    /// Days locked by an ACCEPTED trade I'm part of — I can't give OR take them in any other trade. Optionally
    /// exclude one group (so an accepted trade never flags itself).
    func committedDayIDs(excludingGroup group: String? = nil) -> Set<String> {
        var days = Set<String>()
        for r in requests where (r.fromID == myID || r.toID == myID) && status(of: r) == .accepted {
            if let group, r.groupKey == group { continue }
            days.formUnion(r.giveDayIDs); days.formUnion(r.takeDayIDs)
        }
        return days
    }

    /// A day in `request` already committed to a DIFFERENT accepted trade (nil = clear) — drives the card
    /// "you already traded this day" indicator + the accept/send blocks.
    func committedConflictDay(_ request: TradeRequest) -> String? {
        let committed = committedDayIDs(excludingGroup: request.groupKey)
        return Set(request.giveDayIDs + request.takeDayIDs).sorted().first(where: committed.contains)
    }

    /// Standing-offer IDs whose linked trade has been ACCEPTED — so the offer can auto-close.
    func acceptedStandingOfferIDs() -> Set<String> {
        Set(requests.compactMap { r in
            guard let oid = r.standingOfferID else { return nil }
            return status(of: r) == .accepted ? oid : nil
        })
    }

    /// An ACTIVE (pending/countered), non-ECB trade for `dayIDs` between me and `peerID`, either direction.
    func existingActiveTrade(with peerID: String, dayIDs: Set<String>) -> TradeRequest? {
        let key = Self.tradeKey(myID, peerID, dayIDs: dayIDs)
        return Self.active(requests, archived: archivedRequestIDs).first { r in
            guard !r.isECB else { return false }
            let st = status(of: r)
            guard st == .pending || st == .countered else { return false }
            return Self.tradeKey(r.fromID, r.toID, dayIDs: Set(r.giveDayIDs + r.takeDayIDs)) == key
        }
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
                              editedAt: Date(), deleted: r.deleted, imageBase64: r.imageBase64)
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

    func postMessage(to request: TradeRequest, text: String, imageBase64: String? = nil) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || imageBase64 != nil else { return }   // allow image-only chat messages
        await respond(to: request, status: .message, note: t, imageBase64: imageBase64)
    }

    // A request I SENT is never "incoming" — even a self-addressed standing bridge request (fromID == toID
    // == me). Otherwise it lands in BOTH incoming and outgoing, the same id renders in two List sections,
    // and SwiftUI drops the duplicate → the sent qual-swap request shows nowhere in my inbox.
    var incoming: [TradeRequest] { requests.filter { $0.toID == myID && $0.fromID != myID } }
    var outgoing: [TradeRequest] { requests.filter { $0.fromID == myID } }

    /// D6 anti-spam: give-day (and qual-swap give) IDs I've ALREADY proposed to `peerID` in an active
    /// (not declined / not expired) outgoing request — so a card/Propose for the same peer+day reads
    /// "Sent" instead of re-blasting them.
    func proposedGiveDays(to peerID: String) -> Set<String> {
        var out = Set<String>()
        for r in outgoing where r.toID == peerID && !r.isExpired && status(of: r) != .declined {
            out.formUnion(r.giveDayIDs)
            if let leg = r.qualSwap { out.insert(leg.giveShiftDayID) }
        }
        return out
    }
    /// True when I've already proposed this package's swap to its peer (same taker + an overlapping
    /// give-day). Drives the greyed "Sent" button — you can't re-spam the same person for the same day.
    func alreadyProposed(_ pkg: TradePackage) -> Bool {
        guard let a = pkg.assignments.first, !a.giveDayIDs.isEmpty else { return false }
        return !Set(a.giveDayIDs).isDisjoint(with: proposedGiveDays(to: a.workerID))
    }

    /// Incoming requests still awaiting your reply — drives the inbox badge.
    var pendingIncoming: [TradeRequest] {
        incoming.filter { status(of: $0) == .pending }
    }

    // MARK: ECB broadcast offers (sender side)

    /// Your outgoing ECB broadcasts, grouped by offerID, newest first.
    var ecbOffers: [(offerID: String, requests: [TradeRequest])] {
        // Manual ECB Finder offers only — auto-match ECB lives in the Auto-Matches section (not two places).
        let ecb = outgoing.filter { $0.isECB && $0.offerID != nil && !$0.isAutoProposed }
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
        var resp = TradeResponse(
            id: UUID().uuidString, requestID: request.id, responderID: myID, responderName: myName,
            status: TradeRequestStatus.accepted.rawValue, note: note, createdAt: Date(),
            offerID: request.offerID, acceptedDayIDs: days)
        resp.acceptedKind = .ecb   // taker chose ECB — so a multi-taker giver sees this pick
        await service.sendResponse(resp)
        responses = (responses.filter { $0.id != resp.id } + [resp]).sorted { $0.createdAt < $1.createdAt }
        // B6-ECB: accepting an ECB offer auto-posts a CONFIRMED shared ledger line (sender pays accepter).
        // An IOU (future available-date) posts on THAT date; otherwise it posts now.
        if let amt = request.ecbAmount {
            ECBAccountingStore.shared.autoInsertAcceptedTrade(
                requestID: request.id, payerID: request.fromID, payerName: request.fromName,
                payeeID: myID, payeeName: myName, amount: amt,
                date: request.isECBIOU ? (request.ecbAvailableDate ?? Date()) : Date())
        }
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
        // Giver side: when the taker posts "ECB RECEIVED", auto-clear the shared ledger line so the points
        // move on BOTH ledgers (−amount for me the payer, +amount for the taker) without a manual step.
        for r in requests where r.isECB {
            if responses.contains(where: { $0.requestID == r.id && $0.note.localizedCaseInsensitiveContains("received") }) {
                ECBAccountingStore.shared.markReceived(requestID: r.id)
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
