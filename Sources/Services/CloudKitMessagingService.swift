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
            // Queryable list field so the per-user "you were mentioned" push subscription can fire.
            if let mentioned = post.mentionedIDs, !mentioned.isEmpty {
                r["mentionedIDs"] = mentioned as CKRecordValue
            }
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

    /// On launch: reconcile private notes AND intents (each newer-wins). The two are independent —
    /// intents must sync even when no notes record exists yet (B4-2 bug fix).
    func syncOnLaunch() async {
        guard SettingsManager.shared.useCloudKit else { return }
        await syncNotesOnLaunch()
        await syncIntentsOnLaunch()   // B4-2 — ALWAYS runs, regardless of the notes record
        await syncPrefsOnLaunch()     // welcome / update-notes / consent flags across the user's devices
        await syncRadarOnLaunch()     // Match Radar watch/seen across the user's devices
    }

    /// Reconcile standing conditional offers across the user's devices (newer wins, by updatedAt).
    func syncStandingOffersOnLaunch() async {
        guard SettingsManager.shared.useCloudKit else { return }
        let store = StandingOfferStore.shared
        guard let remote = await cloud.fetchStanding() else {
            if let json = store.exportJSON(), store.updatedAt > .distantPast {
                await cloud.publishStanding(json, updatedAt: store.updatedAt)
            }
            return
        }
        if remote.updatedAt > store.updatedAt {
            store.applyRemote(remote.json, at: remote.updatedAt)
        } else if store.updatedAt > remote.updatedAt, let json = store.exportJSON() {
            await cloud.publishStanding(json, updatedAt: store.updatedAt)
        }
    }

    /// Push the local standing offers up (called after any edit).
    func publishLocalStandingOffers() async {
        guard SettingsManager.shared.useCloudKit, let json = StandingOfferStore.shared.exportJSON() else { return }
        await cloud.publishStanding(json, updatedAt: StandingOfferStore.shared.updatedAt)
    }

    /// Reconcile Match Radar watch/seen state across the user's devices (newer wins, by radarStateUpdatedAt).
    func syncRadarOnLaunch() async {
        guard SettingsManager.shared.useCloudKit else { return }
        let store = MatchStore.shared
        guard let remote = await cloud.fetchRadar() else {
            if let json = store.exportRadarJSON(), store.radarStateUpdatedAt > .distantPast {
                await cloud.publishRadar(json, updatedAt: store.radarStateUpdatedAt)
            }
            return
        }
        if remote.updatedAt > store.radarStateUpdatedAt {
            store.applyRemoteRadar(remote.json, at: remote.updatedAt)            // remote newer → adopt
        } else if store.radarStateUpdatedAt > remote.updatedAt, let json = store.exportRadarJSON() {
            await cloud.publishRadar(json, updatedAt: store.radarStateUpdatedAt) // local newer → push
        }
    }

    /// Push the local radar watch/seen state up (called after the user toggles Watch Day).
    func publishLocalRadar() async {
        guard SettingsManager.shared.useCloudKit, let json = MatchStore.shared.exportRadarJSON() else { return }
        await cloud.publishRadar(json, updatedAt: MatchStore.shared.radarStateUpdatedAt)
    }

    /// Reconcile the welcome/update/consent flags across the user's devices (newer wins, by prefsSyncedAt).
    func syncPrefsOnLaunch() async {
        guard SettingsManager.shared.useCloudKit else { return }
        let s = SettingsManager.shared
        let localAt = s.prefsSyncedAt ?? .distantPast
        guard let remote = await cloud.fetchPrefs() else {
            if s.prefsSyncedAt != nil, let json = s.exportSyncedPrefsJSON() {
                await cloud.publishPrefs(json, updatedAt: localAt)   // seed the record if we have local prefs
            }
            return
        }
        if remote.updatedAt > localAt {
            s.applyRemoteSyncedPrefs(remote.json, at: remote.updatedAt)   // remote newer → adopt
        } else if localAt > remote.updatedAt, let json = s.exportSyncedPrefsJSON() {
            await cloud.publishPrefs(json, updatedAt: localAt)           // local newer → push
        }
    }

    /// Push the local welcome/update/consent flags (called from `SettingsManager.syncPrefsChanged()`).
    func publishLocalPrefs() async {
        guard SettingsManager.shared.useCloudKit,
              let json = SettingsManager.shared.exportSyncedPrefsJSON() else { return }
        await cloud.publishPrefs(json, updatedAt: SettingsManager.shared.prefsSyncedAt ?? Date())
    }

    /// Reconcile local vs remote private notes (newer wins).
    private func syncNotesOnLaunch() async {
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

    /// B4-2: reconcile the full intent set (marks + notes/reasons/topology) across the user's devices,
    /// LWW by `intentsUpdatedAt`. Adopt refuses if there are unsaved local edits (INV-9).
    func syncIntentsOnLaunch() async {
        guard SettingsManager.shared.useCloudKit else { return }
        let store = DayIntentStore.shared
        guard let remote = await cloud.fetchIntents() else {
            if let json = store.exportSnapshotJSON(), store.intentsUpdatedAt > .distantPast {
                await cloud.publishIntents(json, updatedAt: store.intentsUpdatedAt)
            }
            return
        }
        if remote.updatedAt > store.intentsUpdatedAt {
            _ = store.applyRemoteSnapshot(remote.json, at: remote.updatedAt)   // remote newer → adopt
        } else if store.intentsUpdatedAt > remote.updatedAt, let json = store.exportSnapshotJSON() {
            await cloud.publishIntents(json, updatedAt: store.intentsUpdatedAt)   // local newer → push
        }
    }

    /// Push the local intents up (call after the user SAVES intents).
    func publishLocalIntents() async {
        guard SettingsManager.shared.useCloudKit, let json = DayIntentStore.shared.exportSnapshotJSON() else { return }
        await cloud.publishIntents(json, updatedAt: DayIntentStore.shared.intentsUpdatedAt)
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

    /// B4-2: intents blob lives on the SAME private_state record, in its own fields (no index — fetched
    /// by fixed record name). Requires the `intents`/`intentsUpdatedAt` fields deployed (see CLOUDKIT_DEPLOY.md).
    func publishIntents(_ json: String, updatedAt: Date) async {
        let record: CKRecord
        if let existing = try? await db.record(for: id) { record = existing }
        else { record = CKRecord(recordType: Self.recordType, recordID: id) }
        record["intents"] = json as CKRecordValue
        record["intentsUpdatedAt"] = updatedAt as CKRecordValue
        do { _ = try await db.save(record) }
        catch { print("⚠️ intents publish failed: \(error.localizedDescription)") }
    }

    func fetchIntents() async -> (json: String, updatedAt: Date)? {
        guard let record = try? await db.record(for: id),
              let json = record["intents"] as? String,
              let updatedAt = record["intentsUpdatedAt"] as? Date else { return nil }
        return (json, updatedAt)
    }

    /// B6-ECB: the user's PERSONAL ECB ledger lines (adds/subtracts/adjustments) — private, cross-device
    /// only. Rides the same private_state record in its own fields (needs `ecbLedger`/`ecbLedgerUpdatedAt`
    /// deployed). Shared trade lines are NOT here — they live in the public `ECBLedgerLine` record.
    func publishECB(_ json: String, updatedAt: Date) async {
        let record: CKRecord
        if let existing = try? await db.record(for: id) { record = existing }
        else { record = CKRecord(recordType: Self.recordType, recordID: id) }
        record["ecbLedger"] = json as CKRecordValue
        record["ecbLedgerUpdatedAt"] = updatedAt as CKRecordValue
        do { _ = try await db.save(record) }
        catch { print("⚠️ ECB ledger publish failed: \(error.localizedDescription)") }
    }

    func fetchECB() async -> (json: String, updatedAt: Date)? {
        guard let record = try? await db.record(for: id),
              let json = record["ecbLedger"] as? String,
              let updatedAt = record["ecbLedgerUpdatedAt"] as? Date else { return nil }
        return (json, updatedAt)
    }

    /// The user's TRADE HISTORY / status-board ledger (settled + pending trades) — private, cross-device
    /// only. Rides the same private_state record in its own fields (needs `tradeHistory`/
    /// `tradeHistoryUpdatedAt` deployed in the CloudKit Console).
    func publishTradeHistory(_ json: String, updatedAt: Date) async {
        let record: CKRecord
        if let existing = try? await db.record(for: id) { record = existing }
        else { record = CKRecord(recordType: Self.recordType, recordID: id) }
        record["tradeHistory"] = json as CKRecordValue
        record["tradeHistoryUpdatedAt"] = updatedAt as CKRecordValue
        do { _ = try await db.save(record) }
        catch { print("⚠️ trade-history publish failed: \(error.localizedDescription)") }
    }

    func fetchTradeHistory() async -> (json: String, updatedAt: Date)? {
        guard let record = try? await db.record(for: id),
              let json = record["tradeHistory"] as? String,
              let updatedAt = record["tradeHistoryUpdatedAt"] as? Date else { return nil }
        return (json, updatedAt)
    }

    /// App prefs (welcome / update-notes / consent flags) — private, cross-device only. Rides the same
    /// private_state record in its own fields (needs `appPrefs` / `appPrefsUpdatedAt` deployed in the
    /// CloudKit Console — see CLOUDKIT_DEPLOY.md).
    func publishPrefs(_ json: String, updatedAt: Date) async {
        let record: CKRecord
        if let existing = try? await db.record(for: id) { record = existing }
        else { record = CKRecord(recordType: Self.recordType, recordID: id) }
        record["appPrefs"] = json as CKRecordValue
        record["appPrefsUpdatedAt"] = updatedAt as CKRecordValue
        do { _ = try await db.save(record) }
        catch { print("⚠️ app-prefs publish failed: \(error.localizedDescription)") }
    }

    func fetchPrefs() async -> (json: String, updatedAt: Date)? {
        guard let record = try? await db.record(for: id),
              let json = record["appPrefs"] as? String,
              let updatedAt = record["appPrefsUpdatedAt"] as? Date else { return nil }
        return (json, updatedAt)
    }

    /// Match Radar watch/seen state — private, cross-device only. Rides the same private_state record in its
    /// own fields (needs `radar` / `radarUpdatedAt` deployed in the CloudKit Console — see CLOUDKIT_DEPLOY.md).
    func publishRadar(_ json: String, updatedAt: Date) async {
        let record: CKRecord
        if let existing = try? await db.record(for: id) { record = existing }
        else { record = CKRecord(recordType: Self.recordType, recordID: id) }
        record["radar"] = json as CKRecordValue
        record["radarUpdatedAt"] = updatedAt as CKRecordValue
        do { _ = try await db.save(record) }
        catch { print("⚠️ radar-state publish failed: \(error.localizedDescription)") }
    }

    func fetchRadar() async -> (json: String, updatedAt: Date)? {
        guard let record = try? await db.record(for: id),
              let json = record["radar"] as? String,
              let updatedAt = record["radarUpdatedAt"] as? Date else { return nil }
        return (json, updatedAt)
    }

    /// Standing conditional offers — private, cross-device only. Rides the same private_state record in its
    /// own fields (needs `standingOffers` / `standingOffersUpdatedAt` deployed in the CloudKit Console).
    func publishStanding(_ json: String, updatedAt: Date) async {
        let record: CKRecord
        if let existing = try? await db.record(for: id) { record = existing }
        else { record = CKRecord(recordType: Self.recordType, recordID: id) }
        record["standingOffers"] = json as CKRecordValue
        record["standingOffersUpdatedAt"] = updatedAt as CKRecordValue
        do { _ = try await db.save(record) }
        catch { print("⚠️ standing-offers publish failed: \(error.localizedDescription)") }
    }

    func fetchStanding() async -> (json: String, updatedAt: Date)? {
        guard let record = try? await db.record(for: id),
              let json = record["standingOffers"] as? String,
              let updatedAt = record["standingOffersUpdatedAt"] as? Date else { return nil }
        return (json, updatedAt)
    }
}

// MARK: - ECB shared-line sync (B6-ECB) — public DB, visible to both dispatchers.

/// One record per SHARED ECB trade/IOU line, fetched by `payerID == me OR payeeID == me`. JSON `payload`
/// + flat queryable `payerID` / `payeeID` / `state` (deploy required). Mirrors the metrics service shape.
actor CloudKitECBService {
    private let db = CKContainer(identifier: CloudKitConfig.containerID).publicCloudDatabase
    private let rt = "ECBLedgerLine"

    func publish(_ e: ECBEntry) async {
        guard let data = try? JSONEncoder().encode(e), let json = String(data: data, encoding: .utf8) else { return }
        let recordID = CKRecord.ID(recordName: e.id)
        let rec: CKRecord
        if let existing = try? await db.record(for: recordID) { rec = existing }
        else { rec = CKRecord(recordType: rt, recordID: recordID) }
        rec["payload"] = json as CKRecordValue
        rec["payerID"] = (e.payerID ?? "") as CKRecordValue
        rec["payeeID"] = (e.payeeID ?? "") as CKRecordValue
        rec["state"]   = e.state.rawValue as CKRecordValue
        do { _ = try await db.save(rec) } catch { print("⚠️ ECB line publish failed: \(error.localizedDescription)") }
    }

    func delete(id: String) async {
        do { _ = try await db.deleteRecord(withID: CKRecord.ID(recordName: id)) }
        catch { print("⚠️ ECB line delete failed: \(error.localizedDescription)") }
    }

    func fetch(involving myID: String) async -> [ECBEntry] {
        let payer = await query(NSPredicate(format: "payerID == %@", myID))
        let payee = await query(NSPredicate(format: "payeeID == %@", myID))
        var seen = Set<String>(); var out: [ECBEntry] = []
        for e in payer + payee where seen.insert(e.id).inserted { out.append(e) }
        return out
    }

    private func query(_ predicate: NSPredicate) async -> [ECBEntry] {
        var out: [ECBEntry] = []
        let q = CKQuery(recordType: rt, predicate: predicate)
        do {
            var page = try await db.records(matching: q, resultsLimit: CKQueryOperation.maximumResults)
            while true {
                for (_, result) in page.matchResults {
                    if let rec = try? result.get(), let json = rec["payload"] as? String,
                       let data = json.data(using: .utf8),
                       let e = try? JSONDecoder().decode(ECBEntry.self, from: data) { out.append(e) }
                }
                guard let cursor = page.queryCursor else { break }
                page = try await db.records(continuingMatchFrom: cursor, resultsLimit: CKQueryOperation.maximumResults)
            }
        } catch { print("⚠️ ECB line fetch failed: \(error.localizedDescription)") }
        return out
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
