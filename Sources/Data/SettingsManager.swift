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

    /// Accessibility: show the floating screen-magnifier button (global pinch-to-zoom) for low-vision users.
    var magnifierEnabled: Bool {
        didSet { defaults.set(magnifierEnabled, forKey: Keys.magnifier) }
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
    /// Max people in a trade the NORMAL feed will search for (2 = pairs only, 3, or 4 = unbound).
    /// The score-floor + N-penalty keep small trades on top regardless; this caps the search depth.
    var normalMaxPeople: Int {
        didSet { defaults.set(normalMaxPeople, forKey: Keys.normalMaxPeople) }
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
    /// LWW clock for cross-device TRADE PREFERENCES (openness, blacklists, mercenary, qual values).
    /// Bumped by `markPrefsChanged()` on a real user edit; set to the remote stamp when adopting.
    var prefsUpdatedAt: Date? {
        didSet { defaults.set(prefsUpdatedAt, forKey: Keys.prefsUpdatedAt) }
    }
    /// Call whenever the user edits a trade preference so cross-device sync can last-write-wins.
    func markPrefsChanged() { prefsUpdatedAt = Date() }
    /// The user's own qualifications, cached from the roster so the trade-preferences screens show the
    /// correct region pills INSTANTLY instead of waiting on the async roster load. Refreshed on load.
    var cachedQuals: [String] {
        didSet { defaults.set(cachedQuals, forKey: Keys.cachedQuals) }
    }
    /// Dispatch trades distribution list — the To: for the Outlook trade email (G1).
    var tradeEmailDL: String {
        didSet { defaults.set(tradeEmailDL, forKey: Keys.tradeEmailDL) }
    }
    /// The app build whose "What's New" sheet the user has already seen (Z2).
    var lastSeenChangelogBuild: String {
        didSet { defaults.set(lastSeenChangelogBuild, forKey: Keys.lastSeenChangelog); syncPrefsChanged() }
    }
    /// When the user accepted the in-app terms (the 3-item consent on the welcome walkthrough), and the
    /// app version at acceptance — the on-device consent record. nil = not yet accepted.
    var consentAcceptedAt: Date? {
        didSet { defaults.set(consentAcceptedAt, forKey: Keys.consentAcceptedAt); syncPrefsChanged() }
    }
    var consentVersion: String {
        didSet { defaults.set(consentVersion, forKey: Keys.consentVersion); syncPrefsChanged() }
    }
    /// Record acceptance of the in-app terms (called when all three consent items are agreed + confirmed).
    /// Only stamps the FIRST acceptance so the original consent time is preserved across re-runs of the tour.
    func recordConsent() {
        guard consentAcceptedAt == nil else { return }
        consentAcceptedAt = Date()
        consentVersion = "\(AppInfo.version) (\(AppInfo.build))"
    }
    /// Show the Welcome tour on every launch (default ON). When OFF, it never auto-shows.
    var showWelcomeOnLaunch: Bool {
        didSet { defaults.set(showWelcomeOnLaunch, forKey: Keys.showWelcomeOnLaunch); syncPrefsChanged() }
    }
    /// Show the "What's New" update-notes screen after the welcome and after each app update
    /// (default ON). When OFF, the update screen never pops automatically.
    var showUpdateOnLaunch: Bool {
        didSet { defaults.set(showUpdateOnLaunch, forKey: Keys.showUpdateOnLaunch); syncPrefsChanged() }
    }

    // MARK: - Cross-device app-prefs sync (welcome / update-notes / consent), LWW by `prefsSyncedAt`.
    /// LWW clock for the synced app-prefs blob; bumped whenever a synced flag changes locally.
    var prefsSyncedAt: Date? {
        didSet { defaults.set(prefsSyncedAt, forKey: Keys.prefsSyncedAt) }
    }
    private var suppressPrefsSync = false   // true while adopting a remote blob (so we don't re-publish it)

    /// The device-independent welcome / update-notes / consent flags that follow the user across devices.
    /// (`tourReplayRequested` is a transient trigger and deliberately NOT synced.)
    struct SyncedPrefs: Codable {
        var hasOnboarded: Bool
        var showWelcomeOnLaunch: Bool
        var showUpdateOnLaunch: Bool
        var lastSeenChangelogBuild: String
        var consentAcceptedAt: Date?
        var consentVersion: String
    }
    func exportSyncedPrefs() -> SyncedPrefs {
        SyncedPrefs(hasOnboarded: defaults.bool(forKey: Keys.hasOnboarded),
                    showWelcomeOnLaunch: showWelcomeOnLaunch,
                    showUpdateOnLaunch: showUpdateOnLaunch,
                    lastSeenChangelogBuild: lastSeenChangelogBuild,
                    consentAcceptedAt: consentAcceptedAt,
                    consentVersion: consentVersion)
    }
    func exportSyncedPrefsJSON() -> String? {
        (try? JSONEncoder().encode(exportSyncedPrefs())).flatMap { String(data: $0, encoding: .utf8) }
    }
    /// Adopt a remote prefs blob (remote-newer). Suppresses the change hook so it doesn't re-publish.
    func applyRemoteSyncedPrefs(_ json: String, at date: Date) {
        guard let data = json.data(using: .utf8),
              let p = try? JSONDecoder().decode(SyncedPrefs.self, from: data) else { return }
        suppressPrefsSync = true
        defaults.set(p.hasOnboarded, forKey: Keys.hasOnboarded)   // @AppStorage("hasOnboarded") observes this
        showWelcomeOnLaunch = p.showWelcomeOnLaunch
        showUpdateOnLaunch = p.showUpdateOnLaunch
        lastSeenChangelogBuild = p.lastSeenChangelogBuild
        consentAcceptedAt = p.consentAcceptedAt
        consentVersion = p.consentVersion
        prefsSyncedAt = date
        suppressPrefsSync = false
    }
    /// Call when a synced flag (or `hasOnboarded`, from finishing the tour) changes locally: bump the LWW
    /// clock and push the blob. No-op while adopting a remote blob or during init (didSet doesn't fire then).
    func syncPrefsChanged() {
        guard !suppressPrefsSync else { return }
        prefsSyncedAt = Date()
        Task { await PrivateStateStore.shared.publishLocalPrefs() }
    }
    /// Once-a-day on-device summary of what needs you (pending trades + unread). Default ON.
    var dailyDigestEnabled: Bool {
        didSet { defaults.set(dailyDigestEnabled, forKey: Keys.dailyDigestEnabled) }
    }
    /// Hour of day (0–23) the daily digest fires. Default 8am.
    var dailyDigestHour: Int {
        didSet { defaults.set(dailyDigestHour, forKey: Keys.dailyDigestHour) }
    }
    /// Standing conditional offers auto-match: when ON, a standing offer that becomes fillable alerts you
    /// automatically. Turn OFF to stop those pushes (offers still work — check them manually). Default ON.
    var standingOfferAutoMatch: Bool {
        didSet { defaults.set(standingOfferAutoMatch, forKey: Keys.standingOfferAutoMatch) }
    }
    /// Default ECB points offered on an ECB trade — the starting amount for an ECB offer or auto-match, and
    /// the per-day Info override falls back to this. Clamped to the valid 5–25 (0.5-step) range. Default 9.
    var ecbDefault: Double {
        didSet { defaults.set(ecbDefault, forKey: Keys.ecbDefault); markPrefsChanged() }
    }
    /// Default ACCEPTED ECB — incoming ECB offers below this amount are hidden from you. Local view
    /// filter (not published). Clamped to the 5–25 (0.5-step) range. Default 9.
    var defaultAcceptedECB: Double {
        didSet { defaults.set(defaultAcceptedECB, forKey: Keys.defaultAcceptedECB) }
    }
    /// Whether to surface ECB offers that are IOUs (paid on a later date). Off = hide IOU offers. Default on.
    var considerIOUs: Bool {
        didSet { defaults.set(considerIOUs, forKey: Keys.considerIOUs) }
    }

    // MARK: Chat & message notification preferences (push subscriptions reconcile off these).
    /// Push me when I receive a 1:1 direct message. Default ON.
    var notifyDirectMessages: Bool {
        didSet { defaults.set(notifyDirectMessages, forKey: Keys.notifyDMs) }
    }
    /// Push me on every new post in the broadcast channels. Default ON.
    var notifyChannelPosts: Bool {
        didSet { defaults.set(notifyChannelPosts, forKey: Keys.notifyChannel) }
    }
    /// Push me when I'm @-mentioned in a channel post. Default ON.
    var notifyMentions: Bool {
        didSet { defaults.set(notifyMentions, forKey: Keys.notifyMentions) }
    }

    // MARK: Trade & match notification prefs (server-push subscriptions reconciled by CloudPush.setup()).
    /// Server push when a coworker's radar AUTO-MATCHES one of your days. Default ON.
    var notifyAutoMatch: Bool { didSet { defaults.set(notifyAutoMatch, forKey: Keys.notifyAutoMatch) } }
    /// Server push for a manual incoming trade request / ECB offer / Perfect Match. Default ON.
    var notifyTradeRequests: Bool { didSet { defaults.set(notifyTradeRequests, forKey: Keys.notifyTradeRequests) } }
    /// Server push for a qual-swap request to you (bridge blast) or an update on your qual-swap. Default ON.
    var notifyQualSwap: Bool { didSet { defaults.set(notifyQualSwap, forKey: Keys.notifyQualSwap) } }
    /// Server push when someone RESPONDS to a request/offer of yours (accept / decline / counter). Default ON.
    var notifyTradeResponses: Bool { didSet { defaults.set(notifyTradeResponses, forKey: Keys.notifyTradeResponses) } }
    /// Server push when a SHARED ECB ledger line involving you is created / confirmed / cleared / removed by the
    /// other dispatcher (so your balance stays in sync). Default ON.
    var notifyECB: Bool { didSet { defaults.set(notifyECB, forKey: Keys.notifyECB) } }
    /// Periodic LOCAL summary of auto-match + suggested counts per date (replaces per-watched-day pings). Default ON.
    var matchSummaryEnabled: Bool { didSet { defaults.set(matchSummaryEnabled, forKey: Keys.matchSummaryEnabled) } }
    /// How often (hours) the match summary fires. Default 6.
    var matchSummaryIntervalHours: Int { didSet { defaults.set(matchSummaryIntervalHours, forKey: Keys.matchSummaryInterval) } }
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
        // Magnifier defaults ON (accessibility-first); users can toggle it off in App Settings.
        magnifierEnabled         = defaults.object(forKey: Keys.magnifier) == nil ? true : defaults.bool(forKey: Keys.magnifier)
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
        dailyDigestEnabled       = (defaults.object(forKey: Keys.dailyDigestEnabled) as? Bool) ?? true   // default ON
        dailyDigestHour          = (defaults.object(forKey: Keys.dailyDigestHour) as? Int) ?? 8
        standingOfferAutoMatch   = (defaults.object(forKey: Keys.standingOfferAutoMatch) as? Bool) ?? true   // default ON
        ecbDefault               = (defaults.object(forKey: Keys.ecbDefault) as? Double) ?? 9   // default 9 ECB
        defaultAcceptedECB       = (defaults.object(forKey: Keys.defaultAcceptedECB) as? Double) ?? 9   // default 9
        considerIOUs             = (defaults.object(forKey: Keys.considerIOUs) as? Bool) ?? true   // default ON
        notifyDirectMessages     = (defaults.object(forKey: Keys.notifyDMs) as? Bool) ?? true   // default ON
        notifyChannelPosts       = (defaults.object(forKey: Keys.notifyChannel) as? Bool) ?? true   // default ON
        notifyMentions           = (defaults.object(forKey: Keys.notifyMentions) as? Bool) ?? true   // default ON
        notifyAutoMatch          = (defaults.object(forKey: Keys.notifyAutoMatch) as? Bool) ?? true
        notifyTradeRequests      = (defaults.object(forKey: Keys.notifyTradeRequests) as? Bool) ?? true
        notifyQualSwap           = (defaults.object(forKey: Keys.notifyQualSwap) as? Bool) ?? true
        notifyTradeResponses     = (defaults.object(forKey: Keys.notifyTradeResponses) as? Bool) ?? true
        notifyECB                = (defaults.object(forKey: Keys.notifyECB) as? Bool) ?? true
        matchSummaryEnabled      = (defaults.object(forKey: Keys.matchSummaryEnabled) as? Bool) ?? true
        matchSummaryIntervalHours = (defaults.object(forKey: Keys.matchSummaryInterval) as? Int) ?? 6
        normalMaxPeople          = (defaults.object(forKey: Keys.normalMaxPeople) as? Int) ?? 3   // default: pairs + 3-way
        isMercenaryMode          = defaults.bool(forKey: Keys.isMercenaryMode)
        statusBroadcast          = defaults.string(forKey: Keys.statusBroadcast) ?? ""
        statusUpdatedAt          = defaults.object(forKey: Keys.statusUpdatedAt) as? Date
        prefsUpdatedAt           = defaults.object(forKey: Keys.prefsUpdatedAt) as? Date
        cachedQuals              = (defaults.array(forKey: Keys.cachedQuals) as? [String]) ?? []
        tradeEmailDL             = defaults.string(forKey: Keys.tradeEmailDL) ?? "DL_dispatch_trades@aa.com"
        lastSeenChangelogBuild   = defaults.string(forKey: Keys.lastSeenChangelog) ?? ""
        consentAcceptedAt        = defaults.object(forKey: Keys.consentAcceptedAt) as? Date
        consentVersion           = defaults.string(forKey: Keys.consentVersion) ?? ""
        prefsSyncedAt            = defaults.object(forKey: Keys.prefsSyncedAt) as? Date
        showWelcomeOnLaunch      = defaults.object(forKey: Keys.showWelcomeOnLaunch) == nil ? true : defaults.bool(forKey: Keys.showWelcomeOnLaunch)
        showUpdateOnLaunch       = defaults.object(forKey: Keys.showUpdateOnLaunch) == nil ? true : defaults.bool(forKey: Keys.showUpdateOnLaunch)
        privateNotes             = defaults.string(forKey: Keys.privateNotes) ?? ""
        privateNotesUpdatedAt    = (defaults.object(forKey: Keys.privateNotesAt) as? Date) ?? .distantPast
    }

    // MARK: - Keys

    private enum Keys {
        static let username       = "batman.username"
        static let password       = "batman.password"
        static let leadHours      = "batman.notificationLeadHours"
        static let debugWebView   = "batman.showDebugWebView"
        static let magnifier      = "batman.magnifierEnabled"
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
        static let dailyDigestEnabled = "batman.dailyDigestEnabled"
        static let dailyDigestHour = "batman.dailyDigestHour"
        static let standingOfferAutoMatch = "batman.standingOfferAutoMatch"
        static let ecbDefault   = "batman.ecbDefault"
        static let defaultAcceptedECB = "batman.defaultAcceptedECB"
        static let considerIOUs = "batman.considerIOUs"
        static let notifyDMs     = "batman.notifyDirectMessages"
        static let notifyChannel = "batman.notifyChannelPosts"
        static let notifyMentions = "batman.notifyMentions"
        static let notifyAutoMatch = "batman.notifyAutoMatch"
        static let notifyECB = "batman.notifyECB"
        static let notifyTradeRequests = "batman.notifyTradeRequests"
        static let notifyQualSwap = "batman.notifyQualSwap"
        static let notifyTradeResponses = "batman.notifyTradeResponses"
        static let matchSummaryEnabled = "batman.matchSummaryEnabled"
        static let matchSummaryInterval = "batman.matchSummaryIntervalHours"
        static let normalMaxPeople = "batman.normalMaxPeople"
        static let isMercenaryMode = "batman.isMercenaryMode"
        static let statusBroadcast = "batman.statusBroadcast"
        static let statusUpdatedAt = "batman.statusUpdatedAt"
        static let prefsUpdatedAt = "batman.prefsUpdatedAt"
        static let cachedQuals = "batman.cachedQuals"
        static let tradeEmailDL    = "batman.tradeEmailDL"
        static let lastSeenChangelog = "batman.lastSeenChangelogBuild"
        static let consentAcceptedAt = "batman.consentAcceptedAt"
        static let consentVersion = "batman.consentVersion"
        static let showWelcomeOnLaunch = "batman.showWelcomeOnLaunch"
        static let showUpdateOnLaunch = "batman.showUpdateOnLaunch"
        static let prefsSyncedAt = "batman.prefsSyncedAt"
        static let hasOnboarded = "hasOnboarded"   // matches @AppStorage("hasOnboarded") in the views
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
