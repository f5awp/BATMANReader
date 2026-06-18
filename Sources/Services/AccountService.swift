// AccountService.swift
// Ties an employee ID to ONE Sign in with Apple user id, so nobody can claim
// someone else's identity. The claim lives in the CloudKit public DB at a fixed
// recordName ("claim_<employeeID>") — fetched by id, so no query index needed.

import CloudKit
import Foundation

enum ClaimResult: Sendable {
    case ok                  // claimed (or already yours)
    case takenByAnother      // someone else's Apple ID already owns this employee ID
    case error               // network/CloudKit problem — try again
}

actor AccountService {
    private let db = CKContainer(identifier: CloudKitConfig.containerID).publicCloudDatabase
    private static let recordType = "AccountClaim"

    /// Claim `employeeID` for `appleUserID`. Succeeds if unclaimed or already
    /// owned by this Apple ID; refuses if a different Apple ID owns it.
    func claim(employeeID: String, appleUserID: String, displayName: String) async -> ClaimResult {
        let id = CKRecord.ID(recordName: "claim_\(employeeID)")
        do {
            if let existing = try? await db.record(for: id) {
                let owner = existing["appleUserID"] as? String ?? ""
                if owner != appleUserID { return .takenByAnother }
                existing["displayName"] = displayName as CKRecordValue
                _ = try await db.save(existing)
                return .ok
            }
            let rec = CKRecord(recordType: Self.recordType, recordID: id)
            rec["employeeID"]  = employeeID as CKRecordValue
            rec["appleUserID"] = appleUserID as CKRecordValue
            rec["displayName"] = displayName as CKRecordValue
            _ = try await db.save(rec)
            return .ok
        } catch {
            print("⚠️ AccountClaim failed: \(error.localizedDescription)")
            return .error
        }
    }

    /// The Apple user id that owns `employeeID`, or nil if unclaimed/unknown.
    func owner(of employeeID: String) async -> String? {
        let id = CKRecord.ID(recordName: "claim_\(employeeID)")
        guard let rec = try? await db.record(for: id) else { return nil }
        return rec["appleUserID"] as? String
    }
}
