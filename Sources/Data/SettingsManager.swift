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

    // ── Qual-swap preference values (Q4) ─────────────────────────────────
    /// Qual code → preference value. HIGHER = more preferred. 0 = blacklisted.
    /// A qual absent from the map = no preference = fully open (highest value).
    var qualValues: [String: Int] {
        didSet { defaults.set(qualValues, forKey: Keys.qualValues) }
    }
    /// Specific desk numbers you'll never qual-swap into (uppercased tokens, e.g. ["64","65"]).
    var qualSwapBlacklistDesks: Set<String> {
        didSet { defaults.set(Array(qualSwapBlacklistDesks), forKey: Keys.qsBlDesks) }
    }

    // ── Relief dispatcher (schedule known only ~45 days out) ─────────────
    /// Relief dispatchers only receive their schedule a limited window out; the master CSV
    /// pads the rest of the year with bogus 0500 AMs. When ON *and* a date is set, all of THIS
    /// user's shifts AFTER `reliefScheduleThrough` are hidden from calendar + trading (filtered
    /// at read-time, so CSV re-uploads can't resurrect them).
    var isReliefDispatcher: Bool {
        didSet { defaults.set(isReliefDispatcher, forKey: Keys.isRelief) }
    }
    var reliefScheduleThrough: Date? {
        didSet { defaults.set(reliefScheduleThrough, forKey: Keys.reliefThrough) }
    }
    /// The effective relief horizon — nil unless toggled ON *and* a date is set.
    var effectiveReliefThrough: Date? { (isReliefDispatcher ? reliefScheduleThrough : nil) }

    /// Overall openness to trades (TradeOpenness rawValue). Default: bookends.
    var tradeOpenness: String {
        didSet { defaults.set(tradeOpenness, forKey: Keys.tradeOpenness) }
    }
    /// Date-range openness overrides that supersede `tradeOpenness` for their span
    /// while they exist. JSON-encoded into defaults.
    var opennessOverrides: [OpennessOverride] {
        didSet { defaults.set(try? JSONEncoder().encode(opennessOverrides), forKey: Keys.opennessOverrides) }
    }

    // ── v2 trade rules ───────────────────────────────────────────────
    /// Weekly-hour caps used as hard limits by the matcher. nil = no cap.
    var maxWeeklyHours: Int? {
        didSet { defaults.set(maxWeeklyHours, forKey: Keys.maxWeeklyHours) }
    }
    var minWeeklyHours: Int? {
        didSet { defaults.set(minWeeklyHours, forKey: Keys.minWeeklyHours) }
    }
    /// When on, the user takes any qualifying pickup regardless of soft prefs.
    var isMercenaryMode: Bool {
        didSet {
            defaults.set(isMercenaryMode, forKey: Keys.isMercenaryMode)
            // Mercenary = "take anything I'm legally available for". The impossible
            // "Not accepting + mercenary" state can't exist — force openness to All. S-ENG-6.
            if isMercenaryMode, tradeOpenness != TradeOpenness.all.rawValue {
                tradeOpenness = TradeOpenness.all.rawValue
            }
        }
    }
    /// Public 140-char status line shown under the user's name in trade views.
    var statusBroadcast: String {
        didSet {
            defaults.set(String(statusBroadcast.prefix(140)), forKey: Keys.statusBroadcast)
            statusUpdatedAt = Date()   // didSet never fires during init, so loads don't bump this (A3 LWW)
        }
    }
    /// When the status last changed locally — the LWW clock for cross-device status sync (A3).
    var statusUpdatedAt: Date? {
        didSet { defaults.set(statusUpdatedAt, forKey: Keys.statusUpdatedAt) }
    }
    /// Dispatch trades distribution list — the To: for the Outlook trade email (G1).
    var tradeEmailDL: String {
        didSet { defaults.set(tradeEmailDL, forKey: Keys.tradeEmailDL) }
    }
    /// The app build whose "What's New" sheet the user has already seen (Z2).
    var lastSeenChangelogBuild: String {
        didSet { defaults.set(lastSeenChangelogBuild, forKey: Keys.lastSeenChangelog) }
    }
    /// Private 2000-char scratch notes — synced privately across YOUR devices (A3).
    var privateNotes: String {
        didSet { defaults.set(String(privateNotes.prefix(2000)), forKey: Keys.privateNotes) }
    }
    /// Last local edit time of `privateNotes` — drives last-write-wins sync (A3).
    var privateNotesUpdatedAt: Date {
        didSet { defaults.set(privateNotesUpdatedAt, forKey: Keys.privateNotesAt) }
    }
    /// User edited the notes locally → clamp + stamp now (caller then publishes).
    func editPrivateNotes(_ text: String) {
        privateNotes = String(text.prefix(2000)); privateNotesUpdatedAt = Date()
    }
    /// A newer remote value arrived → adopt it without re-stamping as a local edit.
    func applyRemotePrivateNotes(_ text: String, at: Date) {
        privateNotes = text; privateNotesUpdatedAt = at
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
        qualValues               = (defaults.dictionary(forKey: Keys.qualValues) as? [String: Int]) ?? [:]
        qualSwapBlacklistDesks   = Set((defaults.array(forKey: Keys.qsBlDesks) as? [String]) ?? [])
        isReliefDispatcher       = defaults.bool(forKey: Keys.isRelief)
        reliefScheduleThrough    = defaults.object(forKey: Keys.reliefThrough) as? Date
        tradeOpenness            = defaults.string(forKey: Keys.tradeOpenness) ?? "bookends"
        opennessOverrides        = (defaults.data(forKey: Keys.opennessOverrides))
            .flatMap { try? JSONDecoder().decode([OpennessOverride].self, from: $0) } ?? []
        useCloudKit              = defaults.bool(forKey: Keys.useCloudKit)
        maxWeeklyHours           = defaults.object(forKey: Keys.maxWeeklyHours) as? Int
        minWeeklyHours           = defaults.object(forKey: Keys.minWeeklyHours) as? Int
        isMercenaryMode          = defaults.bool(forKey: Keys.isMercenaryMode)
        statusBroadcast          = defaults.string(forKey: Keys.statusBroadcast) ?? ""
        statusUpdatedAt          = defaults.object(forKey: Keys.statusUpdatedAt) as? Date
        tradeEmailDL             = defaults.string(forKey: Keys.tradeEmailDL) ?? "DL_dispatch_trades@aa.com"
        lastSeenChangelogBuild   = defaults.string(forKey: Keys.lastSeenChangelog) ?? ""
        privateNotes             = defaults.string(forKey: Keys.privateNotes) ?? ""
        privateNotesUpdatedAt    = (defaults.object(forKey: Keys.privateNotesAt) as? Date) ?? .distantPast
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
        static let qualValues   = "batman.qualValues"
        static let qsBlDesks    = "batman.qualSwapBlacklistDesks"
        static let isRelief     = "batman.isReliefDispatcher"
        static let reliefThrough = "batman.reliefScheduleThrough"
        static let tradeOpenness = "batman.tradeOpenness"
        static let opennessOverrides = "batman.opennessOverrides"
        static let useCloudKit   = "batman.useCloudKit"
        static let maxWeeklyHours = "batman.maxWeeklyHours"
        static let minWeeklyHours = "batman.minWeeklyHours"
        static let isMercenaryMode = "batman.isMercenaryMode"
        static let statusBroadcast = "batman.statusBroadcast"
        static let statusUpdatedAt = "batman.statusUpdatedAt"
        static let tradeEmailDL    = "batman.tradeEmailDL"
        static let lastSeenChangelog = "batman.lastSeenChangelogBuild"
        static let privateNotes  = "batman.privateNotes"
        static let privateNotesAt = "batman.privateNotesAt"
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
