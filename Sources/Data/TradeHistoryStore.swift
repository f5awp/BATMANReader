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
    private static let searchKey = "batman.v2.searchLog"
    private static let clockKey = "batman.v2.tradeHistoryUpdatedAt"

    /// Timestamps of trade searches the user has run — drives the Home metrics header (H1).
    private(set) var searchLog: [Date] {
        didSet { if let d = try? JSONEncoder().encode(searchLog) { UserDefaults.standard.set(d, forKey: Self.searchKey) } }
    }

    /// LWW clock for cross-device history sync (private DB). Bumped on every genuine LOCAL mutation.
    private var historyUpdatedAt: Date
    private let privateCloud = CloudKitPrivateStateService()

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([TradeHistoryEntry].self, from: data) {
            entries = decoded.sorted { $0.completedAt > $1.completedAt }
        } else {
            entries = []
        }
        searchLog = (UserDefaults.standard.data(forKey: Self.searchKey))
            .flatMap { try? JSONDecoder().decode([Date].self, from: $0) } ?? []
        historyUpdatedAt = (UserDefaults.standard.object(forKey: Self.clockKey) as? Date) ?? .distantPast
    }

    /// Record a trade search (H1). Caller passes the time so the store stays testable.
    func recordSearch(at date: Date) { searchLog.append(date); MetricsStore.shared.log(.search) }
    /// Admin: clear the metrics baseline.
    func resetMetrics() { searchLog = []; UserDefaults.standard.set(Date(), forKey: "batman.v2.metricsResetAt") }
    /// Completed (non-pending) trades — the "accepted" numerator for success %.
    var completedCount: Int { entries.filter { !$0.pending }.count }

    /// Append a settled trade to the ledger. `completedAt` is passed in by the
    /// caller (the store does not read the clock, to stay deterministic/testable).
    func record(_ entry: TradeHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        // NOTE (#9): success is NOT logged here — a recorded/completed trade isn't "successful" until
        // it's ACCEPTED *and* ARCHIVED. The `.trade` metric fires from MessagingStore.archiveRequest.
        publishHistory()   // cross-device: your status board now matches on all your devices
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
        publishHistory()
    }

    // MARK: - Cross-device sync (private DB, LWW) — same shape as ECBAccountingStore's personal blob.

    /// Bump the clock and push the ledger to the user's private CloudKit record (fire-and-forget).
    func publishHistory() {
        historyUpdatedAt = Date()
        UserDefaults.standard.set(historyUpdatedAt, forKey: Self.clockKey)
        guard SettingsManager.shared.useCloudKit else { return }
        let json = historyJSON(); let at = historyUpdatedAt
        Task { await privateCloud.publishTradeHistory(json, updatedAt: at) }
    }

    /// On launch / dashboard open: adopt the remote ledger when it's newer (LWW). A transient empty/failed
    /// fetch returns nil → we keep local (INV-4: an outage never wipes your status board). If local is
    /// newer, push it up.
    func syncOnLaunch() async {
        guard SettingsManager.shared.useCloudKit else { return }
        if let remote = await privateCloud.fetchTradeHistory(), remote.updatedAt > historyUpdatedAt,
           let decoded = try? JSONDecoder().decode([TradeHistoryEntry].self, from: Data(remote.json.utf8)) {
            entries = decoded.sorted { $0.completedAt > $1.completedAt }   // remote newer → adopt
            historyUpdatedAt = remote.updatedAt
            UserDefaults.standard.set(historyUpdatedAt, forKey: Self.clockKey)
        } else if historyUpdatedAt > .distantPast {
            let json = historyJSON(); let at = historyUpdatedAt
            Task { await privateCloud.publishTradeHistory(json, updatedAt: at) }   // local newer → push
        }
    }

    private func historyJSON() -> String {
        (try? JSONEncoder().encode(entries)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - ECB Accounting (B6-ECB)

/// A ledger line category. Personal categories carry their sign implicitly (credit/debit); a `.trade`
/// line is SHARED with another dispatcher (payer/payee) and its sign is computed per viewer; `.adjustment`
/// carries an explicit signed delta.
enum ECBCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case overtime, holidayPay, otherCredit
    case withdrawal, vacationUse, otherDebit
    case adjustment
    case trade
    var id: String { rawValue }
    var label: String {
        switch self {
        case .overtime:    return "Overtime"
        case .holidayPay:  return "Holiday Pay"
        case .otherCredit: return "Other (add)"
        case .withdrawal:  return "Withdrawal"
        case .vacationUse: return "Vacation use"
        case .otherDebit:  return "Other (subtract)"
        case .adjustment:  return "Adjustment"
        case .trade:       return "ECB trade"
        }
    }
    var symbol: String {
        switch self {
        case .overtime:    return "clock.badge.checkmark"
        case .holidayPay:  return "gift.fill"
        case .otherCredit: return "plus.circle.fill"
        case .withdrawal:  return "banknote.fill"
        case .vacationUse: return "beach.umbrella.fill"
        case .otherDebit:  return "minus.circle.fill"
        case .adjustment:  return "slider.horizontal.3"
        case .trade:       return "arrow.left.arrow.right"
        }
    }
    /// true = inherently a credit (+), false = a debit (−), nil = sign carried explicitly (trade/adjustment).
    var isCredit: Bool? {
        switch self {
        case .overtime, .holidayPay, .otherCredit: return true
        case .withdrawal, .vacationUse, .otherDebit: return false
        case .adjustment, .trade: return nil
        }
    }
    static let creditCases: [ECBCategory] = [.overtime, .holidayPay, .otherCredit]
    static let debitCases:  [ECBCategory] = [.withdrawal, .vacationUse, .otherDebit]
}

/// Confirmation state of a line. Personal lines are always `.confirmed`. A shared `.trade` line proposed
/// by me is `.pendingOutgoing` (awaiting the counterparty); one proposed to me is `.pendingIncoming`.
enum ECBLineState: String, Codable, Sendable { case confirmed, pendingOutgoing, pendingIncoming }

/// One ECB ledger line. Personal lines: `amount` is SIGNED (+add / −subtract). Shared `.trade` lines:
/// `amount` is a POSITIVE magnitude — `payerID` loses it, `payeeID` gains it (sign computed per viewer).
/// INT-3: every new field is optional/defaulted so old records still decode.
struct ECBEntry: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var date: Date                         // the EFFECTIVE / pay date — when this hits the balance
    var amount: Double
    var category: ECBCategory
    var memo: String = ""
    /// Has this actually posted? Adds/subtracts/IOUs only happen on pay days, so a line is SCHEDULED
    /// (pending) until the user taps "mark cleared" (or the taker taps "mark received" for an IOU).
    /// `cleared` counts toward the Available (capped) balance; uncleared counts only toward Projected.
    var cleared: Bool = false
    var payerID: String? = nil
    var payerName: String? = nil
    var payeeID: String? = nil
    var payeeName: String? = nil
    var state: ECBLineState = .confirmed   // AGREEMENT on a shared line (orthogonal to `cleared`)
    var tradeRequestID: String? = nil      // set when auto-posted from an accepted in-app ECB trade
    var updatedAt: Date = .distantPast

    init(id: String = UUID().uuidString, date: Date, amount: Double, category: ECBCategory,
         memo: String = "", cleared: Bool = false, payerID: String? = nil, payerName: String? = nil,
         payeeID: String? = nil, payeeName: String? = nil, state: ECBLineState = .confirmed,
         tradeRequestID: String? = nil, updatedAt: Date = .distantPast) {
        self.id = id; self.date = date; self.amount = amount; self.category = category; self.memo = memo
        self.cleared = cleared
        self.payerID = payerID; self.payerName = payerName; self.payeeID = payeeID; self.payeeName = payeeName
        self.state = state; self.tradeRequestID = tradeRequestID; self.updatedAt = updatedAt
    }

    // Custom decode so a record missing any non-required field still decodes to its default (INV-3
    // decode-back-compat — Swift's SYNTHESIZED decoder ignores property defaults and would throw).
    enum CodingKeys: String, CodingKey {
        case id, date, amount, category, memo, cleared, payerID, payerName, payeeID, payeeName, state, tradeRequestID, updatedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        amount = try c.decode(Double.self, forKey: .amount)
        category = try c.decode(ECBCategory.self, forKey: .category)
        memo = try c.decodeIfPresent(String.self, forKey: .memo) ?? ""
        cleared = try c.decodeIfPresent(Bool.self, forKey: .cleared) ?? false
        payerID = try c.decodeIfPresent(String.self, forKey: .payerID)
        payerName = try c.decodeIfPresent(String.self, forKey: .payerName)
        payeeID = try c.decodeIfPresent(String.self, forKey: .payeeID)
        payeeName = try c.decodeIfPresent(String.self, forKey: .payeeName)
        state = try c.decodeIfPresent(ECBLineState.self, forKey: .state) ?? .confirmed
        tradeRequestID = try c.decodeIfPresent(String.self, forKey: .tradeRequestID)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    var isShared: Bool { category == .trade }
    /// Agreed by both parties (or a personal line) — eligible to count once cleared.
    var isAgreed: Bool { state == .confirmed }
    /// Scheduled = agreed but not yet posted (a future pay-day / unreceived IOU).
    var isScheduled: Bool { isAgreed && !cleared }
    /// The other dispatcher's id/name for a shared line, from `viewer`'s perspective.
    func counterpartyID(myID: String) -> String? { myID == payerID ? payeeID : payerID }
    func counterpartyName(myID: String) -> String? { myID == payerID ? payeeName : payerName }
}

/// PURE ECB accounting math — the single source of truth for balances/sign/cap. No view, no store.
enum ECBAccounting {
    /// The company cap: your AVAILABLE (cleared) balance can never exceed this.
    static let maxBalance: Double = 144

    /// Signed amount from `viewerID`'s perspective. Personal → `amount` (already signed). Shared trade →
    /// +magnitude if viewer is the payee, −magnitude if the payer, 0 if neither.
    static func signedAmount(for viewerID: String, _ e: ECBEntry) -> Double {
        guard e.isShared else { return e.amount }
        if viewerID == e.payeeID { return abs(e.amount) }
        if viewerID == e.payerID { return -abs(e.amount) }
        return 0
    }
    /// AVAILABLE (cleared) balance = agreed + posted lines only. This is the number capped at 144.
    static func available(_ entries: [ECBEntry], viewerID: String) -> Double {
        entries.filter { $0.isAgreed && $0.cleared }.reduce(0) { $0 + signedAmount(for: viewerID, $1) }
    }
    /// PROJECTED balance = available + everything scheduled (agreed pay-day adds/withdraws + landing IOUs).
    /// Excludes lines still awaiting the counterparty's confirmation.
    static func projected(_ entries: [ECBEntry], viewerID: String) -> Double {
        entries.filter { $0.isAgreed }.reduce(0) { $0 + signedAmount(for: viewerID, $1) }
    }
    /// Shared lines awaiting MY confirmation (the counterparty proposed them).
    static func pendingConfirmations(_ entries: [ECBEntry], myID: String) -> [ECBEntry] {
        entries.filter { $0.isShared && $0.state == .pendingIncoming && ($0.payerID == myID || $0.payeeID == myID) }
    }
    /// The signed delta line to record when the user SETS their available balance to `target`.
    static func adjustmentAmount(current: Double, target: Double) -> Double { target - current }

    /// ECB you'll PAY others — agreed-but-uncleared shared lines where you're the payer (IOUs out).
    static func owe(_ entries: [ECBEntry], myID: String) -> Double {
        entries.filter { $0.isShared && $0.isAgreed && !$0.cleared && $0.payerID == myID }
            .reduce(0) { $0 + abs($1.amount) }
    }
    /// ECB others will PAY you — agreed-but-uncleared shared lines where you're the payee (IOUs in).
    static func owed(_ entries: [ECBEntry], myID: String) -> Double {
        entries.filter { $0.isShared && $0.isAgreed && !$0.cleared && $0.payeeID == myID }
            .reduce(0) { $0 + abs($1.amount) }
    }

    /// Would clearing `delta` (signed) push the AVAILABLE balance over the 144 cap? Only positive deltas
    /// can breach it. Used to block "mark cleared" until the user withdraws.
    static func wouldExceedCap(available: Double, clearing delta: Double) -> Bool {
        delta > 0 && available + delta > maxBalance + 0.0001
    }

    /// How much you can still promise on an OUTGOING trade/IOU: your available (cleared) balance plus
    /// scheduled deposits not yet committed to other outgoing IOUs. Enforces "IOU only up to your
    /// scheduled future deposits" (plus anything already cleared).
    static func payableCapacity(_ entries: [ECBEntry], myID: String) -> Double {
        let scheduled = entries.filter { $0.isScheduled }.reduce(0.0) { $0 + signedAmount(for: myID, $1) }
        return max(0, available(entries, viewerID: myID) + scheduled)
    }
}

/// The user's ECB ledger. Local-persisted (UserDefaults); personal lines sync across the user's own
/// devices (private DB) and shared `.trade` lines sync between the two dispatchers (public DB) — wired in
/// the sync stage. Same `@Observable`+UserDefaults shape as `TradeHistoryStore`.
@MainActor
@Observable
final class ECBAccountingStore {
    static let shared = ECBAccountingStore()

    private(set) var entries: [ECBEntry] { didSet { persist() } }
    private static let key = "batman.v2.ecbLedger"
    private static let clockKey = "batman.v2.ecbLedgerUpdatedAt"
    private var personalUpdatedAt: Date
    private let ecbCloud = CloudKitECBService()
    private let privateCloud = CloudKitPrivateStateService()
    private var myID: String { SettingsManager.shared.username }
    private var myName: String { let n = SettingsManager.shared.displayName; return n.isEmpty ? myID : n }

    private init() {
        entries = (UserDefaults.standard.data(forKey: Self.key))
            .flatMap { try? JSONDecoder().decode([ECBEntry].self, from: $0) } ?? []
        personalUpdatedAt = (UserDefaults.standard.object(forKey: Self.clockKey) as? Date) ?? .distantPast
    }

    // MARK: Derived
    /// Cleared, capped-at-144 balance (what you can use right now).
    var available: Double { ECBAccounting.available(entries, viewerID: myID) }
    /// Available + everything scheduled (agreed pay-day adds/withdraws + landing IOUs).
    var projected: Double { ECBAccounting.projected(entries, viewerID: myID) }
    var pendingConfirmations: [ECBEntry] { ECBAccounting.pendingConfirmations(entries, myID: myID) }
    /// Outstanding IOUs you'll pay / others will pay you (agreed, not yet cleared).
    var owe: Double { ECBAccounting.owe(entries, myID: myID) }
    var owed: Double { ECBAccounting.owed(entries, myID: myID) }
    /// How much you can still promise on an outgoing trade/IOU (cleared + uncommitted scheduled deposits).
    var payableCapacity: Double { ECBAccounting.payableCapacity(entries, myID: myID) }
    /// Register order — newest first, deterministic tiebreak by id.
    var register: [ECBEntry] {
        entries.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id > $1.id }
    }

    // MARK: Personal mutations (always agreed; private)
    /// Add a personal credit/debit line. `magnitude` is unsigned; the category decides the sign. Defaults
    /// SCHEDULED (`cleared == false`) — adds/subtracts post on a pay day; the user marks it cleared then.
    func addPersonal(category: ECBCategory, magnitude: Double, memo: String, date: Date, cleared: Bool = false) {
        let credit = category.isCredit ?? true
        entries.append(ECBEntry(date: date, amount: (credit ? 1 : -1) * abs(magnitude),
                                category: category, memo: memo, cleared: cleared))
        publishPersonal()
    }
    /// "Set my available balance to X" → a CLEARED Adjustment line carrying the delta (a correction to
    /// what's posted right now, so it counts immediately toward Available).
    func setBalance(to target: Double, date: Date) {
        let delta = ECBAccounting.adjustmentAmount(current: available, target: target)
        guard abs(delta) > 0.0001 else { return }
        entries.append(ECBEntry(date: date, amount: delta, category: .adjustment,
                                memo: "Balance set to \(ecbText(target))", cleared: true))
        publishPersonal()
    }
    /// Mark a scheduled line as posted (pay day happened / IOU received). Blocked if it would push the
    /// AVAILABLE balance over 144 — the user must add a withdrawal first. Returns false when blocked.
    @discardableResult
    func markCleared(id: String, _ cleared: Bool = true) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return false }
        if cleared {
            let delta = ECBAccounting.signedAmount(for: myID, entries[i])
            if ECBAccounting.wouldExceedCap(available: available, clearing: delta) { return false }
        }
        entries[i].cleared = cleared; entries[i].updatedAt = Date()
        if entries[i].isShared { publishShared(entries[i]) } else { publishPersonal() }
        return true
    }
    /// Edit a personal line (shared lines route through the confirmation path instead).
    func editPersonal(id: String, magnitude: Double, memo: String, date: Date) {
        guard let i = entries.firstIndex(where: { $0.id == id }), !entries[i].isShared else { return }
        let credit = entries[i].category.isCredit ?? (entries[i].amount >= 0)
        entries[i].amount = (credit ? 1 : -1) * abs(magnitude)
        entries[i].memo = memo; entries[i].date = date
        publishPersonal()
    }

    // MARK: Shared trade lines (need counterparty confirmation)
    /// Manually log a trade with another dispatcher. `iPaid` → I'm the payer (I lose ECB). Creates a
    /// SCHEDULED, `.pendingOutgoing` line that appears in the counterparty's Inbox to confirm; it clears
    /// when the taker marks it received. When I'm the payer, the amount can't exceed `payableCapacity`
    /// (cleared + scheduled deposits) — you can only IOU what you have or will have. Returns false if over.
    @discardableResult
    func addTradeLine(counterpartyID: String, counterpartyName: String, magnitude: Double,
                      iPaid: Bool, memo: String, date: Date) -> Bool {
        if iPaid && abs(magnitude) > payableCapacity + 0.0001 { return false }
        let e = ECBEntry(date: date, amount: abs(magnitude), category: .trade, memo: memo, cleared: false,
                         payerID: iPaid ? myID : counterpartyID, payerName: iPaid ? myName : counterpartyName,
                         payeeID: iPaid ? counterpartyID : myID, payeeName: iPaid ? counterpartyName : myName,
                         state: .pendingOutgoing, updatedAt: Date())
        entries.append(e)
        publishShared(e)
        return true
    }
    /// Auto-post a CONFIRMED (mutually-agreed) shared line when an in-app ECB offer is accepted (sender
    /// pays the taker). SCHEDULED (uncleared) — it posts on a pay day; the taker marks it received.
    /// De-duped by `tradeRequestID` so a re-accept can't double-post.
    func autoInsertAcceptedTrade(requestID: String, payerID: String, payerName: String,
                                 payeeID: String, payeeName: String, amount: Double, date: Date) {
        guard !entries.contains(where: { $0.tradeRequestID == requestID }) else { return }
        let e = ECBEntry(date: date, amount: abs(amount), category: .trade, memo: "Shift-trade ECB",
                         cleared: false, payerID: payerID, payerName: payerName,
                         payeeID: payeeID, payeeName: payeeName, state: .confirmed,
                         tradeRequestID: requestID, updatedAt: Date())
        entries.append(e)
        publishShared(e)
    }
    /// Edit a confirmed shared line → re-proposes it (`.pendingOutgoing`); the counterparty re-confirms.
    func proposeSharedEdit(id: String, magnitude: Double, iPaid: Bool, memo: String, date: Date) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].isShared,
              let cp = entries[i].counterpartyID(myID: myID) else { return }
        let cpName = entries[i].counterpartyName(myID: myID) ?? cp
        entries[i].amount = abs(magnitude)
        entries[i].payerID = iPaid ? myID : cp; entries[i].payerName = iPaid ? myName : cpName
        entries[i].payeeID = iPaid ? cp : myID; entries[i].payeeName = iPaid ? cpName : myName
        entries[i].memo = memo; entries[i].date = date
        entries[i].state = .pendingOutgoing; entries[i].updatedAt = Date()
        publishShared(entries[i])
    }

    /// Confirm an incoming shared line (I'm the counterparty) → it now counts on both ledgers.
    func confirm(id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = .confirmed; entries[i].updatedAt = Date()
        publishShared(entries[i])
    }
    /// Decline / delete an incoming shared line → removed on both ledgers.
    func decline(id: String) {
        guard let e = entries.first(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        retractShared(e)
    }
    /// Delete a line. Personal → immediate. Shared confirmed → re-proposes removal (counterparty confirms).
    func delete(id: String) {
        guard let e = entries.first(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        if e.isShared { retractShared(e) } else { publishPersonal() }
    }

    // MARK: Sync — personal lines → private DB (your devices); shared trade lines → public DB (both parties)
    func publishPersonal() {
        personalUpdatedAt = Date()
        UserDefaults.standard.set(personalUpdatedAt, forKey: Self.clockKey)
        guard SettingsManager.shared.useCloudKit else { return }
        let json = personalBlobJSON(); let at = personalUpdatedAt
        Task { await privateCloud.publishECB(json, updatedAt: at) }
    }
    func publishShared(_ e: ECBEntry) {
        guard SettingsManager.shared.useCloudKit, e.isShared else { return }
        Task { await ecbCloud.publish(e) }
    }
    func retractShared(_ e: ECBEntry) {
        guard SettingsManager.shared.useCloudKit, e.isShared else { return }
        Task { await ecbCloud.delete(id: e.id) }
    }

    /// On launch: adopt shared lines from the public DB (cloud is source of truth; empty fetch never wipes,
    /// INV-4) and the personal blob from the private DB (LWW). Union so an optimistic just-created shared
    /// line isn't lost before it round-trips.
    func syncOnLaunch() async {
        guard SettingsManager.shared.useCloudKit else { return }
        let localShared = entries.filter { $0.isShared }
        let remoteShared = await ecbCloud.fetch(involving: myID)
        let shared = FetchMerge.keepCacheOnEmpty(existing: localShared, fetched: remoteShared)
        var personal = entries.filter { !$0.isShared }
        if let remote = await privateCloud.fetchECB(), remote.updatedAt > personalUpdatedAt,
           let decoded = try? JSONDecoder().decode([ECBEntry].self, from: Data(remote.json.utf8)) {
            personal = decoded
            personalUpdatedAt = remote.updatedAt
            UserDefaults.standard.set(personalUpdatedAt, forKey: Self.clockKey)
        } else if personalUpdatedAt > .distantPast {
            let json = personalBlobJSON(); let at = personalUpdatedAt
            Task { await privateCloud.publishECB(json, updatedAt: at) }   // local newer → push
        }
        var byID = Dictionary(localShared.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in shared { byID[e.id] = e }   // cloud wins per id
        entries = personal + Array(byID.values)
    }

    private func personalBlobJSON() -> String {
        (try? JSONEncoder().encode(entries.filter { !$0.isShared }))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
