// SettingsManager.swift
// Persists user preferences across sessions.
//
// Credentials:
//   • Username → UserDefaults (non-sensitive employee ID)
//   • Password → Keychain   (encrypted, never in plaintext)
//
// To change any setting without Xcode, open the app → Settings tab.
// Hardcoded values below are FALLBACKS used only on first launch.

import Foundation
import Security
import Observation

@MainActor
@Observable
final class SettingsManager {

    static let shared = SettingsManager()

    // ── Fallbacks ────────────────────────────────────────────────────
    // Empty username = "not set up yet" → triggers first-run onboarding so each
    // user enters their OWN employee ID (never inherits someone else's).
    private static let fallbackUsername = ""
    private static let fallbackPassword = ""
    // ────────────────────────────────────────────────────────────────

    private let defaults = UserDefaults.standard

    var username: String {
        didSet { defaults.set(username, forKey: Keys.username) }
    }

    /// Stable Sign in with Apple user identifier (unforgeable). Empty = not signed in.
    var appleUserID: String {
        didSet { defaults.set(appleUserID, forKey: Keys.appleUserID) }
    }

    /// App theme: "system" (follows device day/night), "light", or "dark".
    var appearance: String {
        didSet { defaults.set(appearance, forKey: Keys.appearance) }
    }

    var notificationLeadHours: Int {
        didSet { defaults.set(notificationLeadHours, forKey: Keys.leadHours) }
    }

    var showDebugWebView: Bool {
        didSet { defaults.set(showDebugWebView, forKey: Keys.debugWebView) }
    }

    // ── Shared dispatcher calendar ───────────────────────────────────
    // The EKCalendar identifier for the shared "AA Dispatch" calendar.
    // Setup (done once by the group coordinator):
    //   1. Create a new iCloud calendar called "AA Dispatch"
    //   2. Share it (Calendar.app → calendar → Share → copy link)
    //   3. All dispatchers accept the invitation on their device
    //   4. Each person opens BATMANReader Settings → Shared Calendar
    //      and taps the calendar name to select it
    //
    // BATMANReader writes OFF days only — never shift details — to the
    // shared calendar so everyone can see who's available to trade.
    var sharedCalendarEnabled: Bool {
        didSet { defaults.set(sharedCalendarEnabled, forKey: Keys.sharedCalEnabled) }
    }

    var sharedCalendarIdentifier: String {
        didSet { defaults.set(sharedCalendarIdentifier, forKey: Keys.sharedCalID) }
    }

    /// Composed "Last, First" — derived from firstName/lastName below. Stored so
    /// existing call sites (profiles, messages) keep working unchanged.
    var displayName: String {
        didSet { defaults.set(displayName, forKey: Keys.displayName) }
    }

    /// Entered as two separate fields so users can't free-type anything; the app
    /// composes `displayName` as "Last, First".
    var firstName: String {
        didSet { defaults.set(firstName, forKey: Keys.firstName); recomposeName() }
    }
    var lastName: String {
        didSet { defaults.set(lastName, forKey: Keys.lastName); recomposeName() }
    }

    private func recomposeName() {
        let l = lastName.trimmingCharacters(in: .whitespaces)
        let f = firstName.trimmingCharacters(in: .whitespaces)
        guard !(l.isEmpty && f.isEmpty) else { return }
        displayName = l.isEmpty ? f : (f.isEmpty ? l : "\(l), \(f)")
    }

    // ── Contact info (collected at onboarding for future email/SMS features) ──
    var personalEmail: String { didSet { defaults.set(personalEmail, forKey: Keys.personalEmail) } }
    var aaEmail: String       { didSet { defaults.set(aaEmail, forKey: Keys.aaEmail) } }
    var phone: String         { didSet { defaults.set(phone, forKey: Keys.phone) } }

    /// Weekdays (1 = Sunday … 7 = Saturday) the dispatcher never wants to pick up
    /// a shift on, even when off. Applied when building availability.
    var blacklistedWeekdays: Set<Int> {
        didSet { defaults.set(Array(blacklistedWeekdays).sorted(), forKey: Keys.blacklistedWeekdays) }
    }

    // ── Trade blacklist — things you won't accept in a trade ─────────────
    var blacklistedDesks: Set<String> {          // e.g. ["29", "82"]
        didSet { defaults.set(Array(blacklistedDesks), forKey: Keys.blDesks) }
    }
    var blacklistedShiftTypes: Set<String> {     // "AM" / "PM" / "MID"
        didSet { defaults.set(Array(blacklistedShiftTypes), forKey: Keys.blShiftTypes) }
    }
    var blacklistedRegions: Set<String> {        // DeskRegion rawValues
        didSet { defaults.set(Array(blacklistedRegions), forKey: Keys.blRegions) }
    }

    /// Overall openness to trades (TradeOpenness rawValue). Default: bookends.
    var tradeOpenness: String {
        didSet { defaults.set(tradeOpenness, forKey: Keys.tradeOpenness) }
    }

    // ── v2 trade rules ───────────────────────────────────────────────
    /// Weekly-hour caps used as hard limits by the matcher. nil = no cap.
    var maxWeeklyHours: Int? {
        didSet { defaults.set(maxWeeklyHours, forKey: Keys.maxWeeklyHours) }
    }
    var minWeeklyHours: Int? {
        didSet { defaults.set(minWeeklyHours, forKey: Keys.minWeeklyHours) }
    }
    /// Soft preference: protect contiguous days off (bookend screening). Bypassed
    /// by "What If?" mode. Default true = today's behavior.
    var prioritizeChaining: Bool {
        didSet { defaults.set(prioritizeChaining, forKey: Keys.prioritizeChaining) }
    }
    /// When on, the user takes any qualifying pickup regardless of soft prefs.
    var isMercenaryMode: Bool {
        didSet { defaults.set(isMercenaryMode, forKey: Keys.isMercenaryMode) }
    }
    /// Public 140-char status line shown under the user's name in trade views.
    var statusBroadcast: String {
        didSet { defaults.set(String(statusBroadcast.prefix(140)), forKey: Keys.statusBroadcast) }
    }
    /// Private 2000-char scratch notes — never published.
    var privateNotes: String {
        didSet { defaults.set(String(privateNotes.prefix(2000)), forKey: Keys.privateNotes) }
    }

    /// When on, trade willingness syncs via the CloudKit public DB (real
    /// cross-user). Off = local-only (default until iCloud capability is wired).
    var useCloudKit: Bool {
        didSet { defaults.set(useCloudKit, forKey: Keys.useCloudKit) }
    }

    var password: String {
        get { KeychainHelper.read(key: Keys.password) ?? Self.fallbackPassword }
        set { KeychainHelper.save(key: Keys.password, value: newValue) }
    }

    private init() {
        let savedUsername = defaults.string(forKey: Keys.username)
        username = savedUsername ?? Self.fallbackUsername
        appleUserID = defaults.string(forKey: Keys.appleUserID) ?? ""
        appearance  = defaults.string(forKey: Keys.appearance) ?? "system"

        let savedHours = defaults.integer(forKey: Keys.leadHours)
        notificationLeadHours = savedHours > 0 ? savedHours : 2

        showDebugWebView         = defaults.bool(forKey: Keys.debugWebView)
        sharedCalendarEnabled    = defaults.bool(forKey: Keys.sharedCalEnabled)
        sharedCalendarIdentifier = defaults.string(forKey: Keys.sharedCalID) ?? ""
        displayName              = defaults.string(forKey: Keys.displayName) ?? ""
        firstName                = defaults.string(forKey: Keys.firstName) ?? ""
        lastName                 = defaults.string(forKey: Keys.lastName) ?? ""
        personalEmail            = defaults.string(forKey: Keys.personalEmail) ?? ""
        aaEmail                  = defaults.string(forKey: Keys.aaEmail) ?? ""
        phone                    = defaults.string(forKey: Keys.phone) ?? ""
        blacklistedWeekdays      = Set((defaults.array(forKey: Keys.blacklistedWeekdays) as? [Int]) ?? [])
        blacklistedDesks         = Set((defaults.array(forKey: Keys.blDesks) as? [String]) ?? [])
        blacklistedShiftTypes    = Set((defaults.array(forKey: Keys.blShiftTypes) as? [String]) ?? [])
        blacklistedRegions       = Set((defaults.array(forKey: Keys.blRegions) as? [String]) ?? [])
        tradeOpenness            = defaults.string(forKey: Keys.tradeOpenness) ?? "bookends"
        useCloudKit              = defaults.bool(forKey: Keys.useCloudKit)
        maxWeeklyHours           = defaults.object(forKey: Keys.maxWeeklyHours) as? Int
        minWeeklyHours           = defaults.object(forKey: Keys.minWeeklyHours) as? Int
        prioritizeChaining       = defaults.object(forKey: Keys.prioritizeChaining) as? Bool ?? true
        isMercenaryMode          = defaults.bool(forKey: Keys.isMercenaryMode)
        statusBroadcast          = defaults.string(forKey: Keys.statusBroadcast) ?? ""
        privateNotes             = defaults.string(forKey: Keys.privateNotes) ?? ""
    }

    // MARK: - Keys

    private enum Keys {
        static let username       = "batman.username"
        static let password       = "batman.password"
        static let leadHours      = "batman.notificationLeadHours"
        static let debugWebView   = "batman.showDebugWebView"
        static let sharedCalEnabled = "batman.sharedCalendarEnabled"
        static let sharedCalID    = "batman.sharedCalendarID"
        static let displayName    = "batman.displayName"
        static let blacklistedWeekdays = "batman.blacklistedWeekdays"
        static let blDesks      = "batman.blacklistedDesks"
        static let blShiftTypes = "batman.blacklistedShiftTypes"
        static let blRegions    = "batman.blacklistedRegions"
        static let tradeOpenness = "batman.tradeOpenness"
        static let useCloudKit   = "batman.useCloudKit"
        static let maxWeeklyHours = "batman.maxWeeklyHours"
        static let minWeeklyHours = "batman.minWeeklyHours"
        static let prioritizeChaining = "batman.prioritizeChaining"
        static let isMercenaryMode = "batman.isMercenaryMode"
        static let statusBroadcast = "batman.statusBroadcast"
        static let privateNotes  = "batman.privateNotes"
        static let appleUserID   = "batman.appleUserID"
        static let appearance    = "batman.appearance"
        static let firstName     = "batman.firstName"
        static let lastName      = "batman.lastName"
        static let personalEmail = "batman.personalEmail"
        static let aaEmail       = "batman.aaEmail"
        static let phone         = "batman.phone"
    }
}

// MARK: - Developer access (password-gated, session-only)

/// Unlocks developer tools (debug section + channel moderation). Not persisted —
/// re-enter the password each launch.
@MainActor
@Observable
final class DevAccess {
    static let shared = DevAccess()
    private(set) var unlocked = false
    private let password = "batman2026"   // change before wide release

    @discardableResult
    func unlock(_ entered: String) -> Bool {
        if entered == password { unlocked = true }
        return unlocked
    }
    func lock() { unlocked = false }
}

// MARK: - Keychain helper

enum KeychainHelper {

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.batmanreader",
            kSecAttrAccount as String: key,
            kSecValueData   as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ Keychain save failed for '\(key)': \(status)")
        }
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.batmanreader",
            kSecAttrAccount as String: key,
            kSecReturnData  as String: true,
            kSecMatchLimit  as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.batmanreader",
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
