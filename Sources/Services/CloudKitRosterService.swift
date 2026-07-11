// CloudKitRosterService.swift
// Shares ONE master roster across all users via the CloudKit public database.
// The admin publishes the parsed CSV as a single versioned record (the CSV rides
// along as a CKAsset, so even multi-MB files are fine); every client checks the
// version on launch and downloads + imports it when it's newer than what they
// have. Fetched by fixed recordName, so no queryable index is needed.

import CloudKit
import Foundation

struct RosterPackage: Sendable {
    let version: Date
    let csv: String
}

actor CloudKitRosterService {
    private let db = CKContainer(identifier: CloudKitConfig.containerID).publicCloudDatabase
    private static let recordType = "RosterPackage"
    private static let recordName = "master_roster"

    /// Upload the parsed CSV as the master. Returns the SERVER-assigned modification date on success —
    /// clients compare against this, NOT a client wall-clock, so publisher clock skew can't make a genuinely
    /// new master look "older" than what a client already has.
    func publish(csv: String) async -> Date? {
        let id = CKRecord.ID(recordName: Self.recordName)
        let record: CKRecord
        if let existing = try? await db.record(for: id) {
            record = existing
        } else {
            record = CKRecord(recordType: Self.recordType, recordID: id)
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("master_roster_\(UUID().uuidString).csv")
        do {
            try (csv.data(using: .utf8) ?? Data()).write(to: tmp)
            record["csv"] = CKAsset(fileURL: tmp)
            record["version"] = Date() as CKRecordValue   // kept for human/debug display only
            let saved = try await db.save(record)
            try? FileManager.default.removeItem(at: tmp)
            return saved.modificationDate   // server time — the real comparison key
        } catch {
            print("⚠️ master roster publish failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns the master package only if it's newer than `localVersion`.
    ///
    /// Two-step so the common "nothing changed" check is cheap: first probe ONLY the `version` field
    /// (`desiredKeys` → the multi-MB CSV asset is NOT downloaded); only when it's strictly newer do we
    /// fetch the full record + asset. This makes the check safe to run on every foreground, not just at
    /// launch. A transient/failed fetch returns nil → the caller keeps its current roster (never wiped).
    func fetchIfNewer(localVersion: Date?) async -> RosterPackage? {
        let id = CKRecord.ID(recordName: Self.recordName)
        // Step 1 — metadata-only probe. `desiredKeys: []` fetches NO custom fields (the multi-MB CSV asset
        // is NOT downloaded) but system fields — including the server `modificationDate` — always come back.
        guard let probe = try? await db.records(for: [id], desiredKeys: []),
              let rec = try? probe[id]?.get(),
              let version = rec.modificationDate else { return nil }
        if let local = localVersion, version <= local { return nil }
        // Step 2 — it's newer: fetch the full record and download the CSV asset.
        guard let record = try? await db.record(for: id),
              let asset = record["csv"] as? CKAsset, let url = asset.fileURL,
              let data = try? Data(contentsOf: url),
              let csv = String(data: data, encoding: .utf8) else { return nil }
        return RosterPackage(version: version, csv: csv)
    }
}
