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
        let s = SettingsManager.shared
        // Every subscription is gated by an App-Settings toggle — toggling one off REMOVES it (reconciled by
        // calling setup() again on change). Auto-matches are excluded from the generic request pushes so each
        // event fires exactly one push.

        // AUTO-MATCH — a coworker's radar auto-sent you a match. DYNAMIC alert naming the date + dispatcher.
        // `desiredKeys` ships the ISO day in the push so a tap deep-links to that day's Trade List.
        await gateDynamic(s.notifyAutoMatch, id: "auto-match-\(myID)",
                          recordType: "TradeRequest",
                          predicate: NSPredicate(format: "toID == %@ AND isAutoMatch == 1", myID),
                          locKey: "An Auto-Match has been found for %@ with %@!",
                          locArgs: ["autoMatchDate", "autoMatchPeer"],
                          desiredKeys: ["autoMatchDayISO"])
        // Manual incoming requests / ECB offers (not auto). A perfect match gets the stronger alert.
        await gate(s.notifyTradeRequests, id: "incoming-requests-\(myID)",
                   recordType: "TradeRequest",
                   predicate: NSPredicate(format: "toID == %@ AND perfectMatch == 0 AND isAutoMatch == 0", myID),
                   alert: "New trade request")
        await gate(s.notifyTradeRequests, id: "perfect-match-\(myID)",
                   recordType: "TradeRequest",
                   predicate: NSPredicate(format: "toID == %@ AND perfectMatch == 1 AND isAutoMatch == 0", myID),
                   alert: "🔥 Perfect Match — someone wants to trade a shift you're after")
        // Someone RESPONDED to a request/offer of yours (accept / decline / counter). `notifyID` = you.
        await gate(s.notifyTradeResponses, id: "trade-responses-\(myID)",
                   recordType: "TradeResponse",
                   predicate: NSPredicate(format: "notifyID == %@", myID),
                   alert: "Someone responded to your trade")
        // A SHARED ECB ledger line involving you was created / confirmed / cleared / REMOVED by the other
        // dispatcher — fires on all three so a decline (delete) reaches you too. The app re-syncs on foreground
        // (ContentView scenePhase → ECBAccountingStore.syncOnLaunch), reconciling balance + any conflict flag.
        await gate(s.notifyECB, id: "ecb-line-\(myID)",
                   recordType: "ECBLedgerLine",
                   predicate: NSPredicate(format: "payerID == %@ OR payeeID == %@", myID, myID),
                   alert: "Your ECB ledger was updated",
                   options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
        // Qual-swap: a bridge blast to me, or an update (a bridge accepted / it finalized) on my qual-swap.
        await gate(s.notifyQualSwap, id: "qualswap-bridge-\(myID)",
                   recordType: "TradeRequest",
                   predicate: NSPredicate(format: "candidateIDs CONTAINS %@", myID),
                   alert: "You can help fill a qual swap")
        await gate(s.notifyQualSwap, id: "qualswap-update-\(myID)",
                   recordType: "TradeRequest",
                   predicate: NSPredicate(format: "toID == %@ AND hasQualSwap == 1", myID),
                   alert: "A qual-swap response came in",
                   options: [.firesOnRecordUpdate])
        // Channel posts / @mentions / direct messages — the chat toggles.
        await gate(s.notifyChannelPosts, id: "new-broadcasts",
                   recordType: "BroadcastPost",
                   predicate: NSPredicate(value: true),
                   alert: "New post in the trade channel")
        await gate(s.notifyMentions, id: "mentioned-\(myID)",
                   recordType: "BroadcastPost",
                   predicate: NSPredicate(format: "mentionedIDs CONTAINS %@", myID),
                   alert: "💬 You were mentioned in the trade channel")
        await gate(s.notifyDirectMessages, id: "direct-message-\(myID)",
                   recordType: "DirectMessage",
                   predicate: NSPredicate(format: "toID == %@", myID),
                   alert: "💬 New direct message")
    }

    /// Gate a DYNAMIC (localized) subscription whose alert text is built from record fields via `locArgs`.
    /// iOS substitutes the `locArgs` field values into `locKey` (used directly as the format string).
    private static func gateDynamic(_ on: Bool, id: String, recordType: String, predicate: NSPredicate,
                                    locKey: String, locArgs: [String], desiredKeys: [String] = []) async {
        guard on else { await remove(id: id); return }
        let sub = CKQuerySubscription(recordType: recordType, predicate: predicate,
                                      subscriptionID: id, options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.alertLocalizationKey = locKey
        info.alertLocalizationArgs = locArgs
        info.soundName = "default"
        info.shouldBadge = true
        if !desiredKeys.isEmpty { info.desiredKeys = desiredKeys }   // included in the push for deep-linking
        sub.notificationInfo = info
        do { _ = try await db.save(sub) } catch { /* already exists or transient — fine */ }
    }

    /// Create the subscription when `on`, otherwise remove it — so a user's notification toggle takes
    /// effect immediately. Call `setup()` again after a toggle change to reconcile.
    private static func gate(_ on: Bool, id: String, recordType: String, predicate: NSPredicate,
                             alert: String,
                             options: CKQuerySubscription.Options = [.firesOnRecordCreation]) async {
        if on { await ensure(id: id, recordType: recordType, predicate: predicate, alert: alert, options: options) }
        else  { await remove(id: id) }
    }

    /// Delete a subscription by id (no-op if it doesn't exist).
    private static func remove(id: String) async {
        do { try await db.deleteSubscription(withID: id) }
        catch { /* not present or transient — fine */ }
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
