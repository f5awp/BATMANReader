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

    /// Upload the parsed CSV as the master. Returns the version stamp on success.
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
        let version = Date()
        do {
            try (csv.data(using: .utf8) ?? Data()).write(to: tmp)
            record["csv"] = CKAsset(fileURL: tmp)
            record["version"] = version as CKRecordValue
            _ = try await db.save(record)
            try? FileManager.default.removeItem(at: tmp)
            return version
        } catch {
            print("⚠️ master roster publish failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns the master package only if it's newer than `localVersion`.
    func fetchIfNewer(localVersion: Date?) async -> RosterPackage? {
        let id = CKRecord.ID(recordName: Self.recordName)
        guard let record = try? await db.record(for: id),
              let version = record["version"] as? Date else { return nil }
        if let local = localVersion, version <= local { return nil }
        guard let asset = record["csv"] as? CKAsset, let url = asset.fileURL,
              let data = try? Data(contentsOf: url),
              let csv = String(data: data, encoding: .utf8) else { return nil }
        return RosterPackage(version: version, csv: csv)
    }
}
