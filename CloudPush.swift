// CloudPush.swift
// Registers CloudKit query subscriptions on the public database so users get a
// push when a trade request arrives for them or a new channel post appears.
// CloudKit delivers the alert itself (notificationInfo.alertBody) — no payload
// handling needed for v1. Requires the aps-environment entitlement + the
// remote-notification background mode (both set).

import CloudKit
import UIKit

@MainActor
enum CloudPush {
    private static let db = CKContainer(identifier: CloudKitConfig.containerID).publicCloudDatabase

    /// Registers for remote notifications and ensures our subscriptions exist.
    /// Safe to call on every launch — CloudKit dedupes by subscriptionID.
    static func setup() async {
        guard SettingsManager.shared.useCloudKit else { return }
        UIApplication.shared.registerForRemoteNotifications()

        let myID = SettingsManager.shared.username
        await ensure(id: "incoming-requests-\(myID)",
                     recordType: "TradeRequest",
                     predicate: NSPredicate(format: "toID == %@", myID),
                     alert: "New trade request")
        await ensure(id: "new-broadcasts",
                     recordType: "BroadcastPost",
                     predicate: NSPredicate(value: true),
                     alert: "New post in the trade channel")
    }

    private static func ensure(id: String, recordType: String, predicate: NSPredicate, alert: String) async {
        let sub = CKQuerySubscription(recordType: recordType, predicate: predicate,
                                      subscriptionID: id, options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.alertBody = alert
        info.soundName = "default"
        info.shouldBadge = true
        sub.notificationInfo = info
        // Re-saving an existing subscription id just errors; ignore (idempotent).
        do { _ = try await db.save(sub) }
        catch { /* already exists or transient — fine */ }
    }
}
