// CloudKitMessagingService.swift
// CloudKit public-DB backend for the broadcast channel + trade-request inbox.
// One record per item, recordName = the model's UUID id; the whole model is
// JSON-encoded into a `payload` String field, with a few flat fields kept
// queryable (authorID / fromID / toID / requestID) for filtered fetches.

import CloudKit
import Foundation

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
        }
    }

    func fetchRequests(involving workerID: String) async -> [TradeRequest] {
        // Public DB: can't OR across fields cheaply, so two filtered queries.
        let to   = await fetch(recordType: RT.request, predicate: NSPredicate(format: "toID == %@", workerID)) as [TradeRequest]
        let from = await fetch(recordType: RT.request, predicate: NSPredicate(format: "fromID == %@", workerID)) as [TradeRequest]
        var seen = Set<String>(), merged: [TradeRequest] = []
        for r in to + from where seen.insert(r.id).inserted { merged.append(r) }
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
