// ScheduleDiff.swift
// Compares an old shift list against a freshly-fetched one and
// returns exactly what changed. Used by EventKitManager to surgically
// add/remove calendar events rather than nuke-and-recreate everything.
//
// A shift is considered "changed" if the date is the same but the
// start time, role, or desk changed — this covers the case where a
// trade altered an existing shift rather than removing it.

import Foundation

struct ScheduleDiff {

    // MARK: - Types

    /// A shift whose details changed (e.g. desk reassignment after trade).
    struct ShiftChange {
        let old: Shift
        let new: Shift
    }

    // MARK: - Properties

    let added:     [Shift]        // New shifts not in the previous store
    let removed:   [Shift]        // Shifts that no longer exist
    let changed:   [ShiftChange]  // Same date, different details
    let unchanged: [Shift]        // Identical — no action needed

    var hasChanges: Bool {
        !added.isEmpty || !removed.isEmpty || !changed.isEmpty
    }

    /// Human-readable summary for UI display and Siri dialog.
    var summary: String {
        guard hasChanges else { return "Schedule unchanged." }
        var parts: [String] = []
        if !added.isEmpty   { parts.append("\(added.count) new shift\(added.count == 1 ? "" : "s")") }
        if !removed.isEmpty { parts.append("\(removed.count) removed") }
        if !changed.isEmpty { parts.append("\(changed.count) updated") }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Factory

    /// Computes the diff between `old` (what was in ShiftStore) and
    /// `new` (what was just scraped from the website).
    static func compute(old: [Shift], new: [Shift]) -> ScheduleDiff {
        let oldMap = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newMap = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })

        var added:     [Shift]       = []
        var removed:   [Shift]       = []
        var changed:   [ShiftChange] = []
        var unchanged: [Shift]       = []

        // Walk new shifts — classify each against the old store
        for (id, newShift) in newMap {
            if let oldShift = oldMap[id] {
                if shiftDetailsChanged(old: oldShift, new: newShift) {
                    changed.append(ShiftChange(old: oldShift, new: newShift))
                } else {
                    unchanged.append(newShift)
                }
            } else {
                added.append(newShift)
            }
        }

        // Walk old shifts — anything not in the new map was removed
        for (id, oldShift) in oldMap where newMap[id] == nil {
            removed.append(oldShift)
        }

        return ScheduleDiff(
            added:     added.sorted     { $0.date < $1.date },
            removed:   removed.sorted   { $0.date < $1.date },
            changed:   changed.sorted   { $0.new.date < $1.new.date },
            unchanged: unchanged.sorted { $0.date < $1.date }
        )
    }

    // MARK: - Private

    private static func shiftDetailsChanged(old: Shift, new: Shift) -> Bool {
        old.startHour  != new.startHour  ||
        old.endHour    != new.endHour    ||
        old.role       != new.role       ||
        old.desk       != new.desk       ||
        old.isOff      != new.isOff      ||
        old.leaveCode  != new.leaveCode
    }
}
