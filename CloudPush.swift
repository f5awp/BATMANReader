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
        // Ordinary incoming requests (perfectMatch == 0). A perfect match gets the stronger
        // alert below instead, so exactly one push fires per request.
        await ensure(id: "incoming-requests-\(myID)",
                     recordType: "TradeRequest",
                     predicate: NSPredicate(format: "toID == %@ AND perfectMatch == 0", myID),
                     alert: "New trade request")
        // A request that matches the recipient's own intents → a stronger "Perfect Match" alert (U6).
        await ensure(id: "perfect-match-\(myID)",
                     recordType: "TradeRequest",
                     predicate: NSPredicate(format: "toID == %@ AND perfectMatch == 1", myID),
                     alert: "🔥 Perfect Match — someone wants to trade a shift you're after")
        await ensure(id: "new-broadcasts",
                     recordType: "BroadcastPost",
                     predicate: NSPredicate(value: true),
                     alert: "New post in the trade channel")
        // Blasted qual-swap bridges (in `candidateIDs`) are neither toID nor fromID, so
        // they need their own subscription to be pinged when a blast lands (Q3).
        await ensure(id: "qualswap-bridge-\(myID)",
                     recordType: "TradeRequest",
                     predicate: NSPredicate(format: "candidateIDs CONTAINS %@", myID),
                     alert: "You can help fill a qual swap")
        // Taker side: my qual-swap request was UPDATED (a bridge accepted / it finalized). (Q3/Q6)
        await ensure(id: "qualswap-update-\(myID)",
                     recordType: "TradeRequest",
                     predicate: NSPredicate(format: "toID == %@ AND hasQualSwap == 1", myID),
                     alert: "A qual-swap response came in",
                     options: [.firesOnRecordUpdate])
    }

    private static func ensure(id: String, recordType: String, predicate: NSPredicate, alert: String,
                               options: CKQuerySubscription.Options = [.firesOnRecordCreation]) async {
        let sub = CKQuerySubscription(recordType: recordType, predicate: predicate,
                                      subscriptionID: id, options: options)
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
