// RosterStore.swift
// Owns the SwiftData container for the full dispatcher roster and provides a
// simple async API. Heavy work (bulk import, fetches) runs on a background
// ModelActor so the main thread stays responsive; results cross back as
// Sendable `RosterEntry` value snapshots.

import Foundation
import SwiftData

// MARK: - Background model actor

@ModelActor
actor RosterModelActor {

    /// Replaces the entire roster with the given workers. Batched saves keep
    /// memory bounded during the (large) bulk insert.
    func replaceRoster(with workers: [ParsedWorker]) throws {
        try modelContext.delete(model: RosterShift.self)

        // The parser already bounds shifts to the rolling 15-month window.
        var inserted = 0
        for worker in workers {
            for shift in worker.shifts {
                modelContext.insert(RosterShift(
                    workerID:   worker.id,
                    workerName: worker.name,
                    quals:      worker.quals,
                    day:        shift.id,
                    date:       shift.date,
                    startHour:  shift.startHour,
                    desk:       shift.desk,
                    isOff:      shift.isOff
                ))
                inserted += 1
                if inserted % 5_000 == 0 { try modelContext.save() }
            }
        }
        try modelContext.save()
    }

    func totalRows() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<RosterShift>())
    }

    func workerCount() throws -> Int {
        // Distinct worker IDs. The roster is modest (~582); fetching the id
        // column and de-duplicating is cheap and avoids a GROUP BY.
        var desc = FetchDescriptor<RosterShift>()
        desc.propertiesToFetch = [\.workerID]
        return Set(try modelContext.fetch(desc).map(\.workerID)).count
    }

    /// Everyone OFF on the given ISO day.
    func dispatchersOff(onDay day: String) throws -> [RosterEntry] {
        let predicate = #Predicate<RosterShift> { $0.day == day && $0.isOff }
        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).map(Self.snapshot)
    }

    /// Everyone WORKING on the given ISO day.
    func dispatchersWorking(onDay day: String) throws -> [RosterEntry] {
        let predicate = #Predicate<RosterShift> { $0.day == day && !$0.isOff }
        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).map(Self.snapshot)
    }

    /// Every worker's entries within [lower, upper] — one query used to build the
    /// per-candidate mini-schedule snapshots.
    func entries(from lower: Date, to upper: Date) throws -> [RosterEntry] {
        let predicate = #Predicate<RosterShift> { $0.date >= lower && $0.date <= upper }
        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).map(Self.snapshot)
    }

    /// A single worker's full schedule (for cross-checking mutual swaps).
    func schedule(forWorker workerID: String) throws -> [RosterEntry] {
        let predicate = #Predicate<RosterShift> { $0.workerID == workerID }
        var desc = FetchDescriptor(predicate: predicate)
        desc.sortBy = [SortDescriptor(\.day)]
        return try modelContext.fetch(desc).map(Self.snapshot)
    }

    private static func snapshot(_ r: RosterShift) -> RosterEntry {
        RosterEntry(workerID: r.workerID, workerName: r.workerName, quals: r.quals,
                    day: r.day, startHour: r.startHour, desk: r.desk, isOff: r.isOff)
    }
}

// MARK: - Main-actor facade

@MainActor
final class RosterStore {
    static let shared = RosterStore()

    let container: ModelContainer
    private let actor: RosterModelActor
    private let cloud = CloudKitRosterService()

    /// Version stamp of the master roster currently imported on this device.
    private var localMasterVersion: Date? {
        get { UserDefaults.standard.object(forKey: "batman.rosterMasterVersion") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "batman.rosterMasterVersion") }
    }

    /// Set while a full-roster rewrite is mid-flight; cleared only on success. If it's still set at the
    /// next launch, the last import was interrupted (crash/kill) and the on-disk roster may be partial.
    private var importInProgress: Bool {
        get { UserDefaults.standard.bool(forKey: "batman.rosterImportInProgress") }
        set { UserDefaults.standard.set(newValue, forKey: "batman.rosterImportInProgress") }
    }

    /// B4-8: synchronous worker-id → roster-name cache so views (calendars, package detail, handoff
    /// chain) can resolve a real name instead of showing the employee number. Warmed by every roster
    /// fetch below. `name(for:)` is the read; callers still route through `TradeNames.resolved` for the
    /// blank/all-digits failsafe.
    private var nameCache: [String: String] = [:]
    func name(for workerID: String) -> String? { nameCache[workerID] }
    private func cacheNames(_ entries: [RosterEntry]) {
        for e in entries where nameCache[e.workerID] == nil { nameCache[e.workerID] = e.workerName }
    }
    /// Per-worker full-schedule cache (mini-calendar week strips fetch this per card). Cleared on import.
    private var scheduleCache: [String: [RosterEntry]] = [:]

    private init() {
        // The roster is LOCAL per-device data. Explicitly opt out of SwiftData's
        // automatic CloudKit mirroring — the iCloud entitlement would otherwise
        // enable it, and CloudKit sync requires every attribute be optional or
        // defaulted (which RosterShift's are not). Only TradeProfile/messages go
        // to CloudKit, via their own CKContainer services.
        let config = ModelConfiguration(cloudKitDatabase: .none)
        do {
            container = try ModelContainer(for: RosterShift.self, configurations: config)
        } catch {
            // A corrupt or schema-incompatible on-disk store would otherwise crash
            // the app on launch (blank screen / "won't load"). Never brick: wipe the
            // store + its WAL/SHM sidecars and rebuild — the roster re-syncs from the
            // master. Fall back to in-memory if even that fails, so the app launches.
            let store = config.url
            let dir = store.deletingLastPathComponent()
            for name in [store.lastPathComponent, store.lastPathComponent + "-wal", store.lastPathComponent + "-shm"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
            if let rebuilt = try? ModelContainer(for: RosterShift.self, configurations: config) {
                container = rebuilt
            } else {
                let mem = ModelConfiguration(isStoredInMemoryOnly: true)
                container = (try? ModelContainer(for: RosterShift.self, configurations: mem))
                    ?? { fatalError("Roster ModelContainer unrecoverable: \(error)") }()
            }
        }
        actor = RosterModelActor(modelContainer: container)

        // Self-heal an interrupted import: if the flag is still set, the on-disk roster may be truncated.
        // Forget our version so the next `syncMasterIfNewer` re-pulls and rebuilds the whole roster cleanly.
        if importInProgress {
            print("⚠️ RosterStore: previous roster import was interrupted — forcing a clean re-pull.")
            localMasterVersion = nil
        }
    }

    /// Publish a parsed CSV as the shared master roster — every user picks it up.
    /// Caller must gate this to the admin (developer access). Returns success.
    @discardableResult
    func publishMaster(csv: String) async -> Bool {
        guard SettingsManager.shared.useCloudKit else { return false }
        guard let version = await cloud.publish(csv: csv) else { return false }
        localMasterVersion = version   // we already have this content locally
        return true
    }

    /// Re-entrancy guard: launch + foreground + onboarding can all fire this; a second call while one
    /// import is running would double-work (and, if ever called off the main actor, race). Serialize.
    private var isSyncingMaster = false

    /// If a newer master roster exists in CloudKit, download + import it. Returns the row count imported
    /// (0 if nothing new / unchanged / failed). Safe to call on launch AND foreground — the version probe
    /// is cheap and a failed/empty fetch keeps the current roster.
    @discardableResult
    func syncMasterIfNewer() async -> Int {
        guard SettingsManager.shared.useCloudKit else { return 0 }
        guard !isSyncingMaster else { return 0 }
        isSyncingMaster = true
        defer { isSyncingMaster = false }

        guard let pkg = await cloud.fetchIfNewer(localVersion: localMasterVersion) else { return 0 }
        let csv = pkg.csv
        guard let workers = try? await Task.detached(priority: .utility, operation: {
            try ScheduleParser().parseAllWorkers(csv: csv)
        }).value else {
            print("⚠️ RosterStore: master parse threw — keeping existing roster, will retry next launch.")
            return 0
        }
        // A well-formed master has the whole department. ≤1 worker means a malformed/partial CSV — refuse
        // it (don't advance the version, so we retry) and surface it instead of silently shipping garbage.
        guard workers.count > 1 else {
            print("⚠️ RosterStore: master parsed to \(workers.count) worker(s) — treating as malformed, NOT importing.")
            return 0
        }
        let rows = await importRoster(workers)
        localMasterVersion = pkg.version

        // Derive THIS user's personal schedule from the master (their row), so a
        // new user just sets their employee ID and gets their schedule + alerts
        // automatically — no per-user import, no per-trade re-import.
        let myID = SettingsManager.shared.username
        if !myID.isEmpty, let mine = workers.first(where: { $0.id == myID }) {
            _ = await ShiftStore.shared.save(mine.shifts)
            await AvailabilityManager.shared.buildFromSchedule()
            await NotificationManager.shared.scheduleAll(for: mine.shifts)
        } else if !myID.isEmpty {
            // Our own row is absent from the new master (new hire not yet added, ID typo, or removed). Keep
            // the existing personal schedule rather than wiping it, but flag it so it's diagnosable.
            print("⚠️ RosterStore: employee \(myID) not found in the new master — kept existing personal schedule.")
        }
        return rows
    }

    /// Imports a full roster in the background. Returns the row count loaded.
    @discardableResult
    func importRoster(_ workers: [ParsedWorker]) async -> Int {
        importInProgress = true            // mark the rewrite in-flight (heals on next launch if interrupted)
        do {
            try await actor.replaceRoster(with: workers)
            nameCache.removeAll(); scheduleCache.removeAll()   // roster changed → drop stale caches
            let rows = (try? await actor.totalRows()) ?? 0
            importInProgress = false        // clean commit
            return rows
        } catch {
            print("⚠️ RosterStore: import failed: \(error)")
            // Leave the flag set → next launch forces a clean re-pull rather than trusting a partial store.
            return 0
        }
    }

    func loadedWorkerCount() async -> Int {
        (try? await actor.workerCount()) ?? 0
    }

    func dispatchersOff(on date: Date) async -> [RosterEntry] {
        let r = (try? await actor.dispatchersOff(onDay: Self.iso(date))) ?? []
        cacheNames(r); return r
    }

    func dispatchersWorking(on date: Date) async -> [RosterEntry] {
        let r = (try? await actor.dispatchersWorking(onDay: Self.iso(date))) ?? []
        cacheNames(r); return r
    }

    func schedule(forWorker workerID: String) async -> [RosterEntry] {
        if let cached = scheduleCache[workerID] { return cached }
        let r = (try? await actor.schedule(forWorker: workerID)) ?? []
        cacheNames(r)
        if !r.isEmpty { scheduleCache[workerID] = r }
        return r
    }

    func entries(from lower: Date, to upper: Date) async -> [RosterEntry] {
        let r = (try? await actor.entries(from: lower, to: upper)) ?? []
        cacheNames(r); return r
    }

    private static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
