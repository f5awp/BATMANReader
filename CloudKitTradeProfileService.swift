// CloudKitTradeProfileService.swift
// The real cross-user backend: each dispatcher publishes their TradeProfile to
// the CloudKit PUBLIC database (free, serverless) so everyone can read everyone's
// willingness. Drop-in replacement for LocalTradeProfileService — same protocol,
// so no call sites change.
//
// Storage shape: one record per dispatcher, recordName = "profile_<employeeID>"
// (so publishing overwrites your own deterministically). The whole profile is
// JSON-encoded into a single `payload` String field — this avoids per-field
// CloudKit schema wrangling; `updatedAt` is stored separately for future
// incremental sync. Matching still fetches all + filters locally.

import CloudKit
import Foundation

actor CloudKitTradeProfileService: TradeProfileService {

    private let db = CKContainer(identifier: CloudKitConfig.containerID).publicCloudDatabase
    private static let recordType = "TradeProfile"

    private func recordID(_ workerID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "profile_\(workerID)")
    }

    // MARK: - Publish

    func publish(_ profile: TradeProfile) async {
        guard let payload = try? JSONEncoder().encode(profile),
              let json = String(data: payload, encoding: .utf8) else { return }

        // Fetch-then-update so re-publishing your own record doesn't conflict.
        let id = recordID(profile.workerID)
        let record: CKRecord
        if let existing = try? await db.record(for: id) {
            record = existing
        } else {
            record = CKRecord(recordType: Self.recordType, recordID: id)
        }
        record["workerID"]  = profile.workerID as CKRecordValue
        record["updatedAt"] = profile.updatedAt as CKRecordValue
        record["payload"]   = json as CKRecordValue

        do { _ = try await db.save(record) }
        catch { print("⚠️ CloudKit publish failed: \(error.localizedDescription)") }
    }

    // MARK: - Fetch

    func fetchAll() async -> [TradeProfile] {
        var profiles: [TradeProfile] = []
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        do {
            var page = try await db.records(matching: query, resultsLimit: CKQueryOperation.maximumResults)
            while true {
                for (_, result) in page.matchResults {
                    if let record = try? result.get(), let p = Self.decode(record) { profiles.append(p) }
                }
                guard let cursor = page.queryCursor else { break }
                page = try await db.records(continuingMatchFrom: cursor, resultsLimit: CKQueryOperation.maximumResults)
            }
        } catch {
            print("⚠️ CloudKit fetchAll failed: \(error.localizedDescription)")
        }
        return profiles
    }

    func profile(forWorker workerID: String) async -> TradeProfile? {
        guard let record = try? await db.record(for: recordID(workerID)) else { return nil }
        return Self.decode(record)
    }

    // MARK: - Helpers

    private static func decode(_ record: CKRecord) -> TradeProfile? {
        guard let json = record["payload"] as? String,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TradeProfile.self, from: data)
    }

    #if DEBUG
    /// Account status + a write/read-by-id round-trip (no custom query, so it
    /// isolates "is CloudKit working" from "are query indexes set up").
    func diagnose() async -> String {
        let container = CKContainer(identifier: CloudKitConfig.containerID)
        let statusLine: String
        do {
            switch try await container.accountStatus() {
            case .available:             statusLine = "iCloud signed in ✓"
            case .noAccount:             return "No iCloud account — sign into iCloud in Settings, then retry."
            case .restricted:            return "iCloud is restricted on this device."
            case .couldNotDetermine:     return "Couldn't determine iCloud account status."
            case .temporarilyUnavailable: return "iCloud temporarily unavailable — try again shortly."
            @unknown default:            statusLine = "iCloud status: unknown."
            }
        } catch { return "Account status error: \(error.localizedDescription)" }

        let id = CKRecord.ID(recordName: "diag_profile")
        let rec = CKRecord(recordType: Self.recordType, recordID: id)
        rec["payload"] = "{}" as CKRecordValue
        rec["workerID"] = "diag" as CKRecordValue
        rec["updatedAt"] = Date() as CKRecordValue
        do { _ = try await db.save(rec) }
        catch { return "\(statusLine)\nWrite FAILED: \(error.localizedDescription)" }
        do {
            _ = try await db.record(for: id)
            _ = try? await db.deleteRecord(withID: id)
            return "\(statusLine)\nWrite + read OK ✓ — CloudKit is working. (Cross-user lists also need the Queryable indexes in the Console — ignore this if you've already added them.)"
        } catch { return "\(statusLine)\nRead FAILED: \(error.localizedDescription)" }
    }
    #endif
}
