// TradeProfile.swift
// The cross-user "willingness" layer — the only data that must be shared between
// dispatchers (the airline roster gives schedules + quals locally; this gives
// INTENT). Built from each person's openness + blacklist + the working days they
// want to trade away.
//
// The backend is swappable behind `TradeProfileService`:
//   • `LocalTradeProfileService`   — on-device, free, works today (no account)
//   • `CloudKitTradeProfileService`— public-DB broadcast, added once enrolled
// Nothing in the app depends on which backend is active.

import Foundation
import Observation

/// Shared CloudKit configuration. The container id must EXACTLY match the one
/// checked in Signing & Capabilities → iCloud → CloudKit Containers.
enum CloudKitConfig {
    static let containerID = "iCloud.com.ervinlee.batmanreader"
}

/// Thread-safe "do this once" gate (used to resume a continuation exactly once).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - Willingness category

/// How willing a candidate is to COVER your shift (one-way), derived from their
/// published profile. The gold 🔥 highlight is separate (mutual-intent count).
enum TradeWillingness: Sendable, Hashable {
    case willing    // opted in and accepts at least one of the shifts
    case unknown    // no published profile yet (hasn't adopted/opted in) → "?"
    case declined   // opted in but won't take any of these — excluded from display

    /// Sort priority (lower = shown first).
    var rank: Int {
        switch self {
        case .willing: return 0
        case .unknown: return 1
        case .declined: return 2
        }
    }
}

// MARK: - Model

/// One dispatcher's published trade intent. Sendable + Codable so it can cross
/// actors and serialize to UserDefaults today / CloudKit later.
struct TradeProfile: Sendable, Hashable, Codable, Identifiable {
    let workerID: String                    // employee ID — the match key
    let displayName: String
    let openness: String                    // TradeOpenness rawValue
    let blacklistedWeekdays: Set<Int>       // 1 = Sun … 7 = Sat
    let blacklistedDesks: Set<String>
    let blacklistedShiftTypes: Set<String>  // "AM" / "PM" / "MID"
    let blacklistedRegions: Set<String>     // DeskRegion rawValues
    let seekingDayIDs: Set<String>          // working days they actively want to give away
    let updatedAt: Date
    // Contact (optional; group shares these). Optional so older records still decode.
    var personalEmail: String? = nil
    var aaEmail: String? = nil
    var phone: String? = nil
    // v2 trade rules (all optional so older records still decode).
    var statusBroadcast: String? = nil
    var maxWeeklyHours: Int? = nil
    var minWeeklyHours: Int? = nil
    var prioritizeChaining: Bool? = nil
    var isMercenaryMode: Bool? = nil

    var id: String { workerID }
    var bestEmail: String? {
        let p = personalEmail?.trimmingCharacters(in: .whitespaces) ?? ""
        let a = aaEmail?.trimmingCharacters(in: .whitespaces) ?? ""
        return !p.isEmpty ? p : (a.isEmpty ? nil : a)
    }
    var opennessLevel: TradeOpenness { TradeOpenness(rawValue: openness) ?? .bookends }

    /// Whether this person would CONSIDER picking up a shift with these traits —
    /// i.e. they're accepting trades and it isn't on their blacklist. (Physical
    /// ability — off + qualified + rested — is checked separately by the matcher;
    /// the per-day bookends-only nuance of `.bookends` is applied there too.)
    func acceptsPickup(weekday: Int, desk: String, shiftType: String, region: String) -> Bool {
        guard opennessLevel != .none else { return false }
        if blacklistedWeekdays.contains(weekday) { return false }
        if blacklistedDesks.contains(desk) { return false }
        if blacklistedShiftTypes.contains(shiftType) { return false }
        if blacklistedRegions.contains(region) { return false }
        return true
    }

    /// Classify a candidate's willingness to COVER the shifts they can physically
    /// take. `.bookends` openness only accepts their bookend days; `.all` accepts
    /// any. No profile → `.unknown`; accepts none → `.declined`; else `.willing`.
    static func classify(coveredShifts: [Shift], bookendIDs: Set<String>,
                         profile: TradeProfile?) -> TradeWillingness {
        guard let profile else { return .unknown }
        let cal = Calendar.current
        let accepts = coveredShifts.contains { s in
            let weekday = cal.component(.weekday, from: s.date)
            let region  = DeskRules.region(forDesk: s.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: s.startHour).rawValue
            let opennessOK = profile.opennessLevel == .all || bookendIDs.contains(s.id)
            return opennessOK && profile.acceptsPickup(weekday: weekday, desk: s.desk,
                                                        shiftType: type, region: region)
        }
        return accepts ? .willing : .declined
    }
}

// MARK: - Service abstraction

/// The swappable backend. Local today, CloudKit public DB once enrolled.
protocol TradeProfileService: Sendable {
    func publish(_ profile: TradeProfile) async
    func fetchAll() async -> [TradeProfile]
    func profile(forWorker workerID: String) async -> TradeProfile?
}

/// On-device stand-in: persists profiles to UserDefaults. Lets the entire
/// matching pipeline + UI be built and tested with no account or sync. `seed`
/// injects synthetic peer profiles for local testing of one-way / two-way flows.
actor LocalTradeProfileService: TradeProfileService {
    private static let key = "batman.localTradeProfiles"
    private var cache: [String: TradeProfile]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: TradeProfile].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func publish(_ profile: TradeProfile) async {
        cache[profile.workerID] = profile
        save()
    }

    func fetchAll() async -> [TradeProfile] { Array(cache.values) }

    func profile(forWorker workerID: String) async -> TradeProfile? { cache[workerID] }

    /// Add peer profiles without overwriting real ones (test scaffolding).
    func seed(_ profiles: [TradeProfile]) async {
        for p in profiles where cache[p.workerID] == nil { cache[p.workerID] = p }
        save()
    }

    /// Wipe all stored profiles (test scaffolding).
    func reset() async {
        cache = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Main-actor facade

/// Owns the active backend, builds + publishes YOUR profile from local prefs,
/// and caches everyone else's for the matcher/UI.
@MainActor
@Observable
final class TradeProfileStore {

    static let shared = TradeProfileStore()

    /// Active backend — CloudKit public DB when iCloud sync is on, else local.
    private var service: TradeProfileService

    /// Other dispatchers' profiles, keyed by employee ID. Empty until refreshed.
    private(set) var others: [String: TradeProfile] = [:]

    private init() {
        service = SettingsManager.shared.useCloudKit
            ? CloudKitTradeProfileService()
            : LocalTradeProfileService()
    }

    /// Switch the backend when the iCloud-sync toggle changes, then re-publish
    /// your profile and refresh everyone else's from the new source.
    func setCloudKit(_ on: Bool) async {
        service = on ? CloudKitTradeProfileService() : LocalTradeProfileService()
        await publishMine()
        await refreshOthers()
    }

    /// Your current profile, assembled from settings + seeking marks.
    func myProfile() -> TradeProfile {
        let s = SettingsManager.shared
        return TradeProfile(
            workerID:              s.username,
            displayName:           s.displayName.isEmpty ? s.username : s.displayName,
            openness:              s.tradeOpenness,
            blacklistedWeekdays:   s.blacklistedWeekdays,
            blacklistedDesks:      s.blacklistedDesks,
            blacklistedShiftTypes: s.blacklistedShiftTypes,
            blacklistedRegions:    s.blacklistedRegions,
            seekingDayIDs:         DayIntentStore.shared.seekingDayIDs,
            updatedAt:             Date(),
            personalEmail:         s.personalEmail.isEmpty ? nil : s.personalEmail,
            aaEmail:               s.aaEmail.isEmpty ? nil : s.aaEmail,
            phone:                 s.phone.isEmpty ? nil : s.phone,
            statusBroadcast:       s.statusBroadcast.isEmpty ? nil : s.statusBroadcast,
            maxWeeklyHours:        s.maxWeeklyHours,
            minWeeklyHours:        s.minWeeklyHours,
            prioritizeChaining:    s.prioritizeChaining,
            isMercenaryMode:       s.isMercenaryMode
        )
    }

    /// Push your latest profile to the backend.
    func publishMine() async {
        await service.publish(myProfile())
    }

    /// Refresh the local cache of everyone else's profiles.
    func refreshOthers() async {
        let all  = await service.fetchAll()
        let myID = SettingsManager.shared.username
        others = Dictionary(uniqueKeysWithValues:
            all.filter { $0.workerID != myID }.map { ($0.workerID, $0) })
    }

    func profile(forWorker workerID: String) -> TradeProfile? { others[workerID] }

    /// Cached profile if present, else fetch the single record from the backend
    /// (used by the inbox/two-way to show a person's contact info).
    func fetchProfile(forWorker workerID: String) async -> TradeProfile? {
        if let p = others[workerID] { return p }
        if let p = await service.profile(forWorker: workerID) {
            others[p.workerID] = p
            return p
        }
        return nil
    }

    #if DEBUG
    /// Seed synthetic peer profiles so one-way/two-way flows can be exercised
    /// before CloudKit exists.
    func seedPeers(_ profiles: [TradeProfile]) async {
        if let local = service as? LocalTradeProfileService {
            await local.seed(profiles)
            await refreshOthers()
        }
    }

    /// Build synthetic peer profiles from the loaded roster (varied openness +
    /// some actively-seeking days) so willingness filtering is demonstrable now.
    /// Returns the number of peer profiles seeded.
    @discardableResult
    func seedFromRoster() async -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let upper = cal.date(byAdding: .day, value: 120, to: today) else { return 0 }
        let entries = await RosterStore.shared.entries(from: today, to: upper)
        guard !entries.isEmpty else { return 0 }

        var byWorker: [String: [RosterEntry]] = [:]
        for e in entries { byWorker[e.workerID, default: []].append(e) }

        let myID = SettingsManager.shared.username
        var profiles: [TradeProfile] = []
        var i = 0
        for (wid, es) in byWorker where wid != myID {
            i += 1
            // Vary openness: every 5th declines, else alternate all/bookends.
            let openness: TradeOpenness = (i % 5 == 0) ? .none : (i % 2 == 0 ? .all : .bookends)
            // Every 3rd actively seeks to give away a few of their working days.
            var seeking = Set<String>()
            if i % 3 == 0 {
                seeking = Set(es.filter { !$0.isOff }.prefix(3).map { $0.day })
            }
            profiles.append(TradeProfile(
                workerID: wid, displayName: es.first?.workerName ?? wid,
                openness: openness.rawValue,
                blacklistedWeekdays: [], blacklistedDesks: [],
                blacklistedShiftTypes: [], blacklistedRegions: [],
                seekingDayIDs: seeking, updatedAt: Date()))
        }
        await seedPeers(profiles)
        return profiles.count
    }

    /// Build a guaranteed mutual-bookend match: marks one of YOUR work days and
    /// seeds a peer who wants a day you can cover — so 🔥×1 shows up. Returns the
    /// peer's name, or nil if the roster has no qualifying pair.
    func seedGuaranteedMutual() async -> (name: String, giveDay: String)? {
        let myID = SettingsManager.shared.username
        guard let seed = await TradeMatcher.findMutualBookendPair(excluding: myID) else { return nil }
        TradeIntentStore.shared.seekingDayIDs.insert(seed.myGiveDayID)
        let peer = TradeProfile(
            workerID: seed.peerID, displayName: seed.peerName, openness: TradeOpenness.all.rawValue,
            blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [], blacklistedRegions: [],
            seekingDayIDs: [seed.theirTakeDayID], updatedAt: Date())
        await service.publish(peer)
        await publishMine()
        await refreshOthers()
        return (seed.peerName, seed.myGiveDayID)
    }

    /// Run a CloudKit health check (account + write/read round-trip). Uses a
    /// continuation race so a hung CloudKit call is ABANDONED at the timeout
    /// instead of blocking forever (a TaskGroup would await the hung child).
    func checkCloudKit() async -> String {
        guard let ck = service as? CloudKitTradeProfileService else {
            return "iCloud Trade Sync is OFF — turn it on in Settings first, then re-check."
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let once = OnceFlag()
            Task {
                let result = await ck.diagnose()
                if once.set() { cont.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if once.set() {
                    cont.resume(returning: "CloudKit timed out (12s) — the call never returned. Almost always: the container isn't in THIS build's provisioning profile. Fix: delete the app from the device, then rebuild/reinstall from Xcode so the profile regenerates with the container. Also confirm you're signed into iCloud.")
                }
            }
        }
    }

    /// Clear all peer profiles (test scaffolding).
    func resetPeers() async {
        if let local = service as? LocalTradeProfileService {
            await local.reset()
            await publishMine()        // keep your own profile present
            await refreshOthers()
        }
    }
    #endif
}
