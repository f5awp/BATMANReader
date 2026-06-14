// TradeHistoryStore.swift
// Immutable ledger of trades the user has marked "official on the company board".
// v2: rows leave the Accepted (green) zone and land here once confirmed.
// UserDefaults-backed, same pattern as TradeIntentStore / DayIntentStore.

import Foundation
import Observation

/// One settled trade, archived after the user confirms it on the official board.
struct TradeHistoryEntry: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let summary: String          // human-readable "who swapped what"
    let participants: [String]   // display names involved
    let dayIDs: [String]         // ISO days that moved
    var completedAt: Date
    var pending: Bool = false    // ECB form submitted, awaiting receipt confirmation
    var ecb: Int? = nil
    var employeeID: String? = nil

    init(id: String = UUID().uuidString, summary: String, participants: [String],
         dayIDs: [String], completedAt: Date, pending: Bool = false,
         ecb: Int? = nil, employeeID: String? = nil) {
        self.id = id
        self.summary = summary
        self.participants = participants
        self.dayIDs = dayIDs
        self.completedAt = completedAt
        self.pending = pending
        self.ecb = ecb
        self.employeeID = employeeID
    }
}

@MainActor
@Observable
final class TradeHistoryStore {

    static let shared = TradeHistoryStore()

    /// Newest first.
    private(set) var entries: [TradeHistoryEntry] {
        didSet { persist() }
    }

    private static let key = "batman.v2.tradeHistory"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([TradeHistoryEntry].self, from: data) {
            entries = decoded.sorted { $0.completedAt > $1.completedAt }
        } else {
            entries = []
        }
    }

    /// Append a settled trade to the ledger. `completedAt` is passed in by the
    /// caller (the store does not read the clock, to stay deterministic/testable).
    func record(_ entry: TradeHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
    }

    /// Pending ECB transfers (form submitted, receipt not yet confirmed).
    var pending: [TradeHistoryEntry] { entries.filter(\.pending) }
    var pendingCount: Int { pending.count }

    /// Mark a pending entry complete once the recipient confirms receipt.
    func markComplete(id: String, at date: Date) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].pending = false
        entries[i].completedAt = date
        entries.sort { $0.completedAt > $1.completedAt }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
