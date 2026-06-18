// TradeIntentStore.swift
// Your own, locally-stored trade intent: the WORKING days you actively want to
// give away ("actively seeking"), markable across the whole year in My
// Availability. Together with your openness + blacklist (SettingsManager) this
// is the trade profile that will be published to other dispatchers once cloud
// sync is enabled. Kept local + free until then.

import Foundation
import Observation

@MainActor
@Observable
final class TradeIntentStore {

    static let shared = TradeIntentStore()

    /// Shift IDs (ISO "yyyy-MM-dd" day strings) of WORKING days you want to trade
    /// away. Persisted locally; this set is what cloud sync will broadcast.
    var seekingDayIDs: Set<String> {
        didSet { persist() }
    }

    private static let key = "batman.tradeSeekingDayIDs"

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        seekingDayIDs = Set(saved)
    }

    func isSeeking(_ id: String) -> Bool { seekingDayIDs.contains(id) }

    func toggle(_ id: String) {
        if seekingDayIDs.contains(id) { seekingDayIDs.remove(id) }
        else { seekingDayIDs.insert(id) }
    }

    /// Drops marks for days that are now in the past or no longer worked (e.g.
    /// the schedule changed). Keeps the set self-cleaning across the year.
    func pruneExpired(using shifts: [Shift]) {
        let today = Calendar.current.startOfDay(for: Date())
        let valid = Set(shifts.filter { !$0.isOff && $0.date >= today }.map { $0.id })
        let next  = seekingDayIDs.intersection(valid)
        if next != seekingDayIDs { seekingDayIDs = next }
    }

    private func persist() {
        UserDefaults.standard.set(Array(seekingDayIDs), forKey: Self.key)
    }
}
