// CloudKitMessagingService.swift
// CloudKit public-DB backend for the broadcast channel + trade-request inbox.
// One record per item, recordName = the model's UUID id; the whole model is
// JSON-encoded into a `payload` String field, with a few flat fields kept
// queryable (authorID / fromID / toID / requestID) for filtered fetches.

import CloudKit
import Foundation
import Observation

actor CloudKitMessagingService: MessagingService {

    private let db = CKContainer(identifier: CloudKitConfig.containerID).publicCloudDatabase

    private enum RT {
        static let post     = "BroadcastPost"
        static let request  = "TradeRequest"
        static let response = "TradeResponse"
        static let reply    = "BroadcastReply"
        static let hide     = "ModerationHide"
    }

    // MARK: - Broadcast

    func postBroadcast(_ post: BroadcastPost) async {
        await save(recordType: RT.post, id: post.id, model: post) { r in
            r["authorID"]  = post.authorID as CKRecordValue
            r["createdAt"] = post.createdAt as CKRecordValue
        }
    }

    func fetchBroadcasts() async -> [BroadcastPost] {
        await fetch(recordType: RT.post, predicate: NSPredicate(value: true))
    }

    func deleteBroadcast(id: String) async { await delete(id) }

    func postReply(_ reply: BroadcastReply) async {
        await save(recordType: RT.reply, id: reply.id, model: reply) { r in
            r["postID"]   = reply.postID as CKRecordValue
            r["authorID"] = reply.authorID as CKRecordValue
        }
    }

    func fetchReplies() async -> [BroadcastReply] {
        await fetch(recordType: RT.reply, predicate: NSPredicate(value: true))
    }

    func deleteReply(id: String) async { await delete(id) }

    // MARK: - Moderation

    func hide(id targetID: String) async {
        let item = HiddenItem(id: "hide_\(targetID)", targetID: targetID, createdAt: Date())
        await save(recordType: RT.hide, id: item.id, model: item) { r in
            r["targetID"] = targetID as CKRecordValue
        }
    }

    func fetchHidden() async -> Set<String> {
        let items: [HiddenItem] = await fetch(recordType: RT.hide, predicate: NSPredicate(value: true))
        return Set(items.map { $0.targetID })
    }

    // MARK: - Trade requests

    func sendRequest(_ request: TradeRequest) async {
        await save(recordType: RT.request, id: request.id, model: request) { r in
            r["fromID"] = request.fromID as CKRecordValue
            r["toID"]   = request.toID as CKRecordValue
            // Flat, queryable list of qual-swap bridge IDs so blasted bridges (who are
            // neither `fromID` nor `toID`) can discover the request (Q3 bridge discovery).
            if let cands = request.qualSwap?.candidates, !cands.isEmpty {
                r["candidateIDs"] = cands.map(\.workerID) as CKRecordValue
            }
            // Flat queryable flag so a subscription can fire a "Perfect Match" push (U6).
            r["perfectMatch"] = (request.perfectMatch == true ? 1 : 0) as CKRecordValue
            // Flag so the taker's record-UPDATE subscription fires on qual-swap responses (Q3/Q6).
            r["hasQualSwap"] = (request.qualSwap != nil ? 1 : 0) as CKRecordValue
        }
    }

    func fetchRequests(involving workerID: String) async -> [TradeRequest] {
        // Public DB: can't OR across fields cheaply, so separate filtered queries —
        // requests addressed TO me, FROM me, or where I'm a blasted qual-swap bridge.
        let to    = await fetch(recordType: RT.request, predicate: NSPredicate(format: "toID == %@", workerID)) as [TradeRequest]
        let from  = await fetch(recordType: RT.request, predicate: NSPredicate(format: "fromID == %@", workerID)) as [TradeRequest]
        let bridge = await fetch(recordType: RT.request, predicate: NSPredicate(format: "candidateIDs CONTAINS %@", workerID)) as [TradeRequest]
        var seen = Set<String>(), merged: [TradeRequest] = []
        for r in to + from + bridge where seen.insert(r.id).inserted { merged.append(r) }
        return merged
    }

    func deleteRequest(id: String) async { await delete(id) }

    // MARK: - Responses

    func sendResponse(_ response: TradeResponse) async {
        await save(recordType: RT.response, id: response.id, model: response) { r in
            r["requestID"]   = response.requestID as CKRecordValue
            r["responderID"] = response.responderID as CKRecordValue
        }
    }

    func fetchResponses() async -> [TradeResponse] {
        await fetch(recordType: RT.response, predicate: NSPredicate(value: true))
    }

    // MARK: - Generic helpers

    private func save<T: Encodable>(recordType: String, id: String, model: T,
                                    setFields: (CKRecord) -> Void) async {
        guard let data = try? JSONEncoder().encode(model),
              let json = String(data: data, encoding: .utf8) else { return }
        let recordID = CKRecord.ID(recordName: id)
        let record: CKRecord
        if let existing = try? await db.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
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

    private func delete(_ id: String) async {
        do { _ = try await db.deleteRecord(withID: CKRecord.ID(recordName: id)) }
        catch { print("⚠️ CloudKit delete failed: \(error.localizedDescription)") }
    }
}

// MARK: - Private-state sync (A3 / S-SYNC-2) — private notes across YOUR own devices.

/// Syncs the user's private notes across their own devices via last-write-wins.
/// Merge decision uses the pure `LWW` helper (unit-tested); this orchestrates fetch/publish.
@MainActor
@Observable
final class PrivateStateStore {
    static let shared = PrivateStateStore()
    private let cloud = CloudKitPrivateStateService()

    /// On launch: reconcile local vs remote private notes (newer wins).
    func syncOnLaunch() async {
        guard SettingsManager.shared.useCloudKit else { return }
        let s = SettingsManager.shared
        guard let remote = await cloud.fetch() else {
            if !s.privateNotes.isEmpty { await cloud.publish(notes: s.privateNotes, updatedAt: s.privateNotesUpdatedAt) }
            return
        }
        if remote.updatedAt > s.privateNotesUpdatedAt {
            s.applyRemotePrivateNotes(remote.notes, at: remote.updatedAt)   // remote newer → adopt
        } else if s.privateNotesUpdatedAt > remote.updatedAt {
            await cloud.publish(notes: s.privateNotes, updatedAt: s.privateNotesUpdatedAt)   // local newer → push
        }
    }

    /// Push the local private notes up (call after the user edits them).
    func publishLocal() async {
        guard SettingsManager.shared.useCloudKit else { return }
        let s = SettingsManager.shared
        await cloud.publish(notes: s.privateNotes, updatedAt: s.privateNotesUpdatedAt)
    }
}

/// Uses the CloudKit PRIVATE database (never public) so notes stay private.
actor CloudKitPrivateStateService {
    private let db = CKContainer(identifier: CloudKitConfig.containerID).privateCloudDatabase
    private static let recordType = "PrivateState"
    private static let recordName = "private_state"
    private var id: CKRecord.ID { CKRecord.ID(recordName: Self.recordName) }

    func publish(notes: String, updatedAt: Date) async {
        let record: CKRecord
        if let existing = try? await db.record(for: id) { record = existing }
        else { record = CKRecord(recordType: Self.recordType, recordID: id) }
        record["privateNotes"] = notes as CKRecordValue
        record["updatedAt"]    = updatedAt as CKRecordValue
        do { _ = try await db.save(record) }
        catch { print("⚠️ private-state publish failed: \(error.localizedDescription)") }
    }

    func fetch() async -> (notes: String, updatedAt: Date)? {
        guard let record = try? await db.record(for: id),
              let notes = record["privateNotes"] as? String,
              let updatedAt = record["updatedAt"] as? Date else { return nil }
        return (notes, updatedAt)
    }
}

// MARK: - Global metrics (H1 #18) — team-wide event log on the public DB.

/// Append-only event log (search / proposed / trade) so the Home header can show GLOBAL totals,
/// not just this device's. Events are JSON in a `payload` field (no per-field schema beyond it).
actor CloudKitMetricsService {
    private let db = CKContainer(identifier: CloudKitConfig.containerID).publicCloudDatabase
    private let rt = "MetricEvent"

    func record(_ event: MetricEvent) async {
        guard let data = try? JSONEncoder().encode(event),
              let json = String(data: data, encoding: .utf8) else { return }
        let rec = CKRecord(recordType: rt, recordID: CKRecord.ID(recordName: event.id))
        rec["payload"] = json as CKRecordValue
        do { _ = try await db.save(rec) }
        catch { print("⚠️ metric record failed: \(error.localizedDescription)") }
    }

    func fetchAll() async -> [MetricEvent] {
        var out: [MetricEvent] = []
        let q = CKQuery(recordType: rt, predicate: NSPredicate(value: true))
        do {
            var page = try await db.records(matching: q, resultsLimit: CKQueryOperation.maximumResults)
            while true {
                for (_, result) in page.matchResults {
                    if let rec = try? result.get(), let json = rec["payload"] as? String,
                       let data = json.data(using: .utf8),
                       let m = try? JSONDecoder().decode(MetricEvent.self, from: data) { out.append(m) }
                }
                guard let cursor = page.queryCursor else { break }
                page = try await db.records(continuingMatchFrom: cursor, resultsLimit: CKQueryOperation.maximumResults)
            }
        } catch { print("⚠️ metric fetch failed: \(error.localizedDescription)") }
        return out
    }
}

// MARK: - Global metrics store

@MainActor
@Observable
final class MetricsStore {
    static let shared = MetricsStore()
    private let cloud = CloudKitMetricsService()
    private(set) var globalEvents: [MetricEvent] = []

    /// Pull the team-wide event log (call on the Home header's appearance).
    func refresh() async { globalEvents = await cloud.fetchAll() }

    /// Log a team metric event (fire-and-forget) + optimistic local append. No-op without CloudKit.
    func log(_ kind: MetricEvent.Kind) {
        guard SettingsManager.shared.useCloudKit else { return }
        let e = MetricEvent(id: UUID().uuidString, workerID: SettingsManager.shared.username,
                            kind: kind, createdAt: Date())
        globalEvents.append(e)
        Task { await cloud.record(e) }
    }
}
