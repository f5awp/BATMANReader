// RosterShift.swift
// SwiftData model holding ONE (dispatcher, date) row of the full roster.
// This is the parse-once / query-many backbone for trade matching: the whole
// roster (~582 dispatchers × ~396 days) is loaded once, then queried by date.

import Foundation
import SwiftData

@Model
final class RosterShift {
    // Indexes that make the matching queries fast: by date, by worker, and the
    // common "who is off on date X" lookup.
    #Index<RosterShift>([\.day], [\.workerID], [\.day, \.isOff])

    var workerID: String        // employee ID, e.g. "292216"
    var workerName: String      // "Lee, Ervin"
    var quals: [String]         // ["D", "L", …]
    var day: String             // ISO "yyyy-MM-dd" — indexed query key
    var date: Date
    var startHour: Int          // 0 when off
    var desk: String            // "29", "OJT", "RC1", "" when off
    var isOff: Bool
    /// Which import "generation" this row belongs to (the master version it was written under). Readers
    /// filter to the single live generation (`RosterStore.readerGeneration`), so a mid-import insert of a
    /// NEW generation is invisible until the pointer swaps — the atomic-swap import (no delete-first).
    /// Defaults to the Unix epoch, which is exactly the value lightweight migration assigns to rows that
    /// existed before this field, so the pre-upgrade roster stays visible with no wipe. (The `@Model` macro
    /// can't take `.distantPast` as a default — it needs a fully-qualified expression.) Must stay in sync
    /// with `RosterStore.readerGeneration`'s default.
    var importedVersion: Date = Date(timeIntervalSince1970: 0)

    init(workerID: String, workerName: String, quals: [String],
         day: String, date: Date, startHour: Int, desk: String, isOff: Bool,
         importedVersion: Date = Date(timeIntervalSince1970: 0)) {
        self.workerID   = workerID
        self.workerName = workerName
        self.quals      = quals
        self.day        = day
        self.date       = date
        self.startHour  = startHour
        self.desk       = desk
        self.isOff      = isOff
        self.importedVersion = importedVersion
    }
}

/// Sendable value snapshot of a roster row — safe to pass across actor boundaries
/// (unlike the `@Model` instances, which are bound to their context).
struct RosterEntry: Sendable, Hashable, Identifiable {
    let workerID: String
    let workerName: String
    let quals: [String]
    let day: String
    let startHour: Int
    let desk: String
    let isOff: Bool

    var id: String { "\(workerID)-\(day)" }
}
