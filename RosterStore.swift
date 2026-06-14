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

    /// On launch: if a newer master roster exists in CloudKit, download + import
    /// it. Returns the row count imported (0 if nothing new). Safe to call always.
    @discardableResult
    func syncMasterIfNewer() async -> Int {
        guard SettingsManager.shared.useCloudKit else { return 0 }
        guard let pkg = await cloud.fetchIfNewer(localVersion: localMasterVersion) else { return 0 }
        let csv = pkg.csv
        guard let workers = try? await Task.detached(priority: .utility, operation: {
            try ScheduleParser().parseAllWorkers(csv: csv)
        }).value, workers.count > 1 else { return 0 }
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
        }
        return rows
    }

    /// Imports a full roster in the background. Returns the row count loaded.
    @discardableResult
    func importRoster(_ workers: [ParsedWorker]) async -> Int {
        do {
            try await actor.replaceRoster(with: workers)
            return (try? await actor.totalRows()) ?? 0
        } catch {
            print("⚠️ RosterStore: import failed: \(error)")
            return 0
        }
    }

    func loadedWorkerCount() async -> Int {
        (try? await actor.workerCount()) ?? 0
    }

    func dispatchersOff(on date: Date) async -> [RosterEntry] {
        (try? await actor.dispatchersOff(onDay: Self.iso(date))) ?? []
    }

    func dispatchersWorking(on date: Date) async -> [RosterEntry] {
        (try? await actor.dispatchersWorking(onDay: Self.iso(date))) ?? []
    }

    func schedule(forWorker workerID: String) async -> [RosterEntry] {
        (try? await actor.schedule(forWorker: workerID)) ?? []
    }

    func entries(from lower: Date, to upper: Date) async -> [RosterEntry] {
        (try? await actor.entries(from: lower, to: upper)) ?? []
    }

    private static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
