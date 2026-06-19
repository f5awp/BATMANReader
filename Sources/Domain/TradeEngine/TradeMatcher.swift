// TradeMatcher.swift
// Trade-matching engine over the SwiftData roster.
//
// Tier 1 — "who can cover my shift": dispatchers who are OFF on the date, are
// QUALIFIED for the desk, and have the mandatory 8-hour rest vs their own
// adjacent shifts. (Mutual swaps build on this next.)

import Foundation

// MARK: - Trade openness

/// How open a dispatcher is to trades — drives which off days they offer.
enum TradeOpenness: String, CaseIterable, Sendable {
    case none     // not accepting any trades — no availability at all
    case bookends // available only on bookend days (edge of a 2+-day off stretch)
    case all      // available on every eligible off day (still respects blacklist)

    var label: String {
        switch self {
        case .none:     return "Not accepting trades"
        case .bookends: return "Open to bookend trades"
        case .all:      return "Open to all trades"
        }
    }

    var symbol: String {
        switch self {
        case .none:     return "nosign"
        case .bookends: return "book"
        case .all:      return "checkmark.seal.fill"
        }
    }
}

/// A temporary openness change for a specific date range that overrides the base
/// openness while it exists. E.g. base "Bookends", but "Open to all" for Jul 1–10.
/// Inclusive ISO day bounds; string compare works for "yyyy-MM-dd".
struct OpennessOverride: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var startDay: String          // ISO "yyyy-MM-dd"
    var endDay: String            // ISO inclusive
    var opennessRaw: String

    var openness: TradeOpenness { TradeOpenness(rawValue: opennessRaw) ?? .all }
    func covers(_ dayID: String) -> Bool { dayID >= startDay && dayID <= endDay }
}

// MARK: - Desk → region / qualification rules

enum DeskRegion: String, Sendable, CaseIterable {
    case domestic   = "Domestic"
    case european   = "European"
    case latin      = "Latin America"
    case pacific    = "Pacific"
    case coordinator = "Coordinator"
}

enum DeskRules {

    /// Region a desk belongs to (line-dispatcher desk numbers per the user; can
    /// change). Non-numeric desks (A#, C#, OJT, RC…) are coordinator/training.
    static func region(forDesk desk: String) -> DeskRegion {
        if let n = Int(desk.trimmingCharacters(in: .whitespaces)) {
            switch n {
            case 46, 47, 93...98:   return .domestic        // explicit domestic desks
            case 48...58:           return .european
            case 60...63, 72...83:  return .latin
            case 64...68:           return .pacific
            default:                return .domestic        // 1–45, 59, 69–71, 84–92, 99+
            }
        }
        return .coordinator
    }

    /// Qualification code a desk requires, or nil if no special gate.
    static func requiredQual(forDesk desk: String) -> String? {
        let d = desk.uppercased().trimmingCharacters(in: .whitespaces)
        if Int(d) != nil {
            switch region(forDesk: d) {
            case .european: return "E"
            case .latin:    return "L"
            case .pacific:  return "P"
            case .domestic: return "D"      // every dispatcher holds D
            case .coordinator: return nil
            }
        }
        if d.hasPrefix("RC") { return nil }                 // route check
        if d.hasPrefix("A")  { return "A" }                 // ATC coordinator
        if d.hasPrefix("C") || d.hasPrefix("I") { return "O" } // ops coordinator
        if d.hasPrefix("R")  { return "R" }                 // regional coordinator
        if d.hasPrefix("S")  { return "S" }                 // chief dispatcher
        return nil                                          // OJT, TR, etc.
    }

    /// Whether a worker holding `quals` may work `desk`.
    static func qualified(quals: [String], forDesk desk: String) -> Bool {
        guard let required = requiredQual(forDesk: desk) else { return true }
        return quals.contains(required)
    }

    /// SINGLE SOURCE OF TRUTH: does giving `desk` to a taker holding `takerQuals`
    /// require a qual swap? True exactly when the taker isn't qualified for the desk.
    /// Every matcher path (trade search, intents, routes) calls this — not its own copy.
    static func qualSwapNeeded(forDesk desk: String, takerQuals: [String]) -> Bool {
        !qualified(quals: takerQuals, forDesk: desk)
    }

    /// Q1: is giving `desk` BLOCKED by qualification — i.e. NONE of the candidate takers
    /// (each a list of quals) is qualified for it? When true, a direct trade is impossible
    /// and only a qual swap (bridge) can unblock it. False if any taker is qualified, or if
    /// there are no takers (that's a coverage gap, not a qual block).
    static func isQualBlocked(forDesk desk: String, candidateTakerQuals: [[String]]) -> Bool {
        guard !candidateTakerQuals.isEmpty else { return false }
        return !candidateTakerQuals.contains { qualified(quals: $0, forDesk: desk) }
    }

    // MARK: Qual-swap preference (Q4)

    /// Preference VALUE of a qual for a person — HIGHER is more preferred.
    /// `0` = blacklisted. A qual ABSENT from the map (or a no-gate desk's nil qual, or a
    /// nil map) = no preference = fully open = the highest value (`Int.max`).
    static func qualValue(_ qual: String?, values: [String: Int]?) -> Int {
        guard let q = qual else { return Int.max }    // no-gate desk = fully open
        return values?[q] ?? Int.max                  // unset qual = highest preference
    }

    /// Q4 acceptance rule: will a person move INTO `newDesk` (giving up `currentDesk`)
    /// for a qual swap? True iff the new desk is NOT a blacklisted desk number, its qual is
    /// NOT blacklisted (value 0), AND its preference value is **equal-or-higher** than their
    /// current desk's qual. Eligibility (do they hold the qual) is checked separately by
    /// `qualified(quals:forDesk:)`.
    static func acceptsQualSwap(into newDesk: String, fromCurrentDesk currentDesk: String,
                                values: [String: Int]?, blacklistDesks: Set<String>? = nil) -> Bool {
        let newDeskU = newDesk.uppercased().trimmingCharacters(in: .whitespaces)
        if blacklistDesks?.contains(newDeskU) == true { return false }   // blacklisted desk number
        let newQual = requiredQual(forDesk: newDesk)
        if let nq = newQual, values?[nq] == 0 { return false }   // blacklisted qual
        return qualValue(newQual, values: values) >= qualValue(requiredQual(forDesk: currentDesk), values: values)
    }
}

// MARK: - Global trade timing rule

/// Single source of truth for trade timing. Per the user: **all** trading globally
/// (not just qual swaps) only ever considers shifts that start at 0500, 1300, or 2100.
enum TradeTiming {
    /// The only start hours (24h) that any trade considers.
    static let validStartHours: Set<Int> = [5, 13, 21]
    static func isTradeable(startHour: Int) -> Bool { validStartHours.contains(startHour) }
}

// MARK: - Qual swaps (same-day desk swap, Q-series)

/// One person's working shift on the swap day — the minimal info the qual-swap
/// finder needs about a potential partner.
struct QualSwapShift: Sendable, Hashable, Identifiable {
    let workerID: String
    let name: String
    let desk: String
    let startHour: Int      // 24h start, so only same-start-hour swaps pair (coverage-neutral)
    let quals: [String]
    var id: String { workerID }
}

enum QualSwap {
    /// Bridge partners (C) that unblock GIVING a desk to a willing-but-unqualified taker.
    ///
    /// Scenario: A gives away `giveDesk` (needs qual X) on a day; the off taker (B) is
    /// willing but lacks X. A bridge C — already working that day — slides onto A's desk,
    /// freeing C's desk for B. A goes off. Coverage and start time stay whole.
    ///
    /// C qualifies iff: starts at the same (tradeable) hour, HOLDS X (can take giveDesk),
    /// is on a desk whose qual the TAKER holds (so the taker can take C's desk), and
    /// ACCEPTS moving onto giveDesk per their preference values (Q4). `excludeIDs` drops
    /// A and B themselves.
    static func bridges(giveDesk: String, takerQuals: [String], startHour: Int,
                        workers: [(shift: QualSwapShift, profile: TradeProfile)],
                        excludeIDs: Set<String>) -> [QualSwapShift] {
        guard TradeTiming.isTradeable(startHour: startHour) else { return [] }
        return workers.compactMap { worker -> QualSwapShift? in
            let c = worker.shift
            guard !excludeIDs.contains(c.workerID) else { return nil }
            guard c.startHour == startHour else { return nil }                              // same start time
            guard DeskRules.qualified(quals: c.quals, forDesk: giveDesk) else { return nil } // C can take give-desk (has X)
            guard DeskRules.qualified(quals: takerQuals, forDesk: c.desk) else { return nil } // taker can take C's desk
            guard worker.profile.acceptsQualSwap(into: giveDesk, fromCurrentDesk: c.desk) else { return nil } // C willing (Q4)
            return c
        }
    }

    /// Adapter: a blastable candidate (the bridge + the desk they'd FREE + that desk's
    /// qual) from a bridge shift — what the taker needs to evaluate the offer (Q2/Q6).
    static func candidate(from shift: QualSwapShift) -> QualSwapCandidate {
        QualSwapCandidate(workerID: shift.workerID, name: shift.name, desk: shift.desk,
                          qual: DeskRules.requiredQual(forDesk: shift.desk) ?? "D")
    }

    /// One auto-discovered 3-party qual-swap solution (Q1): giver A goes off, bridge C slides
    /// onto A's give-desk, off-taker B takes C's freed desk.
    struct Solution: Sendable, Hashable {
        let bridgeID: String; let bridgeName: String
        let bridgeDesk: String; let bridgeQual: String   // C's desk (freed for B) + its qual
        let takerID: String; let takerName: String       // B, who takes C's freed desk
    }

    /// PURE: enumerate qual-swap solutions to unblock giving `giveDesk` on a (tradeable-hour) day.
    /// `workers` are people working that day (shift + profile); `offTakers` are people OFF that day
    /// the CALLER has already gated as willing/eligible (their `canCover` of the bridge's desk is
    /// checked here by qual only — the caller applies the full availability gate). Self is excluded.
    static func solutions(giveDesk: String, giveStartHour: Int, giverID: String,
                          workers: [(shift: QualSwapShift, profile: TradeProfile)],
                          offTakers: [(id: String, name: String, quals: [String])]) -> [Solution] {
        guard TradeTiming.isTradeable(startHour: giveStartHour) else { return [] }
        var out: [Solution] = []
        for w in workers {
            let c = w.shift
            guard c.workerID != giverID, c.startHour == giveStartHour else { continue }
            guard DeskRules.qualified(quals: c.quals, forDesk: giveDesk) else { continue }    // C can take A's desk
            guard w.profile.acceptsQualSwap(into: giveDesk, fromCurrentDesk: c.desk) else { continue }  // C willing (Q4)
            let cQual = DeskRules.requiredQual(forDesk: c.desk) ?? "D"
            for b in offTakers where b.id != giverID && b.id != c.workerID {
                guard DeskRules.qualified(quals: b.quals, forDesk: c.desk) else { continue }  // B can take C's freed desk
                out.append(Solution(bridgeID: c.workerID, bridgeName: c.name,
                                    bridgeDesk: c.desk, bridgeQual: cQual,
                                    takerID: b.id, takerName: b.name))
            }
        }
        return out
    }
}

/// Lifecycle of a qual-swap leg inside a trade package (Q3/Q5/Q6). Drives the card
/// indicator + inbox text. CaseIterable so the UI can be enumerated against it.
enum QualSwapLegStatus: String, Sendable, Codable, CaseIterable {
    case waiting        // blasted; no bridge has accepted yet → "Waiting on qual swap"
    case offersOpen     // ≥1 bridge accepted; first-5 slots remain → taker may pick now or wait
    case offersFull     // first-5 acceptor cap reached; no more bridges can respond
    case finalized      // taker chose a swap → leg locked, trade can complete
    case invalid        // taker declined OR no bridge accepted in time → package dead (reason: qual swap)

    var isTerminal: Bool { self == .finalized || self == .invalid }
}

enum QualSwapLeg {
    /// First-N acceptor cap for a qual-swap blast (ECB-style). The 6th+ sees "already filled".
    static let acceptorCap = 5

    /// Whether another bridge may still accept (first-5 rule).
    static func acceptIsOpen(acceptedCount: Int) -> Bool { acceptedCount < acceptorCap }

    /// Pure reducer: the leg's status from the live signals. `finalized` wins; a taker
    /// decline or a timeout with ZERO acceptances is invalid; otherwise it's waiting /
    /// offers-open / offers-full by acceptance count. Acceptances stand through expiry —
    /// only the taker finalizing or declining (or nobody bridging) resolves the leg.
    static func status(acceptedCount: Int, finalized: Bool, declined: Bool, expired: Bool) -> QualSwapLegStatus {
        if finalized { return .finalized }
        if declined { return .invalid }
        if acceptedCount == 0 { return expired ? .invalid : .waiting }
        return acceptIsOpen(acceptedCount: acceptedCount) ? .offersOpen : .offersFull
    }
}

// MARK: - Match results

/// One day in a candidate's mini-schedule snapshot.
struct DayCell: Sendable, Hashable {
    let weekday: String   // "M","T","W","Th","F","Sa","Su"
    let letter: String    // "A"/"P"/"M" for AM/PM/MID, or "" when off
    let isTarget: Bool    // the day being covered
}

/// A candidate for a MULTI-shift trade request: how many of the requested shifts
/// they can cover, and how many of those are clean bookends for them.
struct PlanCandidate: Sendable, Hashable, Identifiable {
    let workerID: String
    let name: String
    let quals: [String]
    let coveredShiftIDs: Set<String>
    let bookendShiftIDs: Set<String>
    let week: [DayCell]   // ±4 snapshot when a single day is requested; empty otherwise
    var willingness: TradeWillingness = .unknown   // annotated post-match from profiles
    var twoWayCount: Int = 0                        // mutual-intent swaps available (🔥×N)
    var matchCount: Int { coveredShiftIDs.count }
    var bookendCount: Int { bookendShiftIDs.count }
    var id: String { workerID }
}

/// One day in a two-way swap. `bookend` = covering this day keeps the RECEIVER's
/// time off contiguous (bookend for whoever picks it up). `wanted` = the owner
/// has actively marked this day to trade away (mutual intent → 🔥).
struct TwoWayLeg: Sendable, Hashable, Identifiable {
    let dayID: String      // ISO "yyyy-MM-dd"
    let date: Date
    let desk: String
    let startHour: Int
    let bookend: Bool
    let wanted: Bool
    var id: String { dayID }
}

/// Feasible bookend swaps with one dispatcher over a window: the days you'd give
/// them (they cover) and the days you'd take (they're working, you cover).
/// `wanted` legs are ones the owner actively marked to trade away.
struct TwoWayPlan: Sendable {
    let workerID: String
    let name: String
    let iGive: [TwoWayLeg]   // your work days they cover — bookend for THEM
    let iTake: [TwoWayLeg]   // their work days you cover — bookend for YOU
    var isViable: Bool { !iGive.isEmpty && !iTake.isEmpty }
    var mutualWanted: Int { min(iGive.filter(\.wanted).count, iTake.filter(\.wanted).count) }
}

// MARK: - Matcher

@MainActor
enum TradeMatcher {

    private static let minRest: TimeInterval = 8 * 3600
    private static let shiftLength: TimeInterval = 9 * 3600

    /// A blank "open, no relief" profile for `canCover(.physicalOnly)` — that mode reads the
    /// profile only for relief (nil here), so a coarse physical probe needs no real profile.
    private static let physicalProbeProfile = TradeProfile(
        workerID: "", displayName: "", openness: "all", blacklistedWeekdays: [],
        blacklistedDesks: [], blacklistedShiftTypes: [], blacklistedRegions: [],
        seekingDayIDs: [], updatedAt: Date(timeIntervalSince1970: 0))

    /// How far ahead two-way matching looks (badge count + explorer span).
    static let twoWayHorizonMonths = 12

    /// Candidates for a MULTI-shift trade: for the given shifts (your days to give
    /// away), how many each dispatcher can cover (off + qualified + 8h rest) and how
    /// many are bookends for them. Ranked by bookends, then total matches.
    static func candidatesForTrades(shifts: [Shift], excluding selfID: String) async -> [PlanCandidate] {
        guard !shifts.isEmpty else { return [] }
        let cal = Calendar.current
        let days = shifts.map { cal.startOfDay(for: $0.date) }
        guard let minD = days.min(), let maxD = days.max(),
              let lower = cal.date(byAdding: .day, value: -4, to: minD),
              let upper = cal.date(byAdding: .day, value:  4, to: maxD) else { return [] }

        let entries = await RosterStore.shared.entries(from: lower, to: upper)
        var byWorker: [String: [String: RosterEntry]] = [:]
        for e in entries { byWorker[e.workerID, default: [:]][e.day] = e }

        var result: [PlanCandidate] = []
        for (wid, dayMap) in byWorker where wid != selfID {
            guard let meta = dayMap.values.first else { continue }
            var covered = Set<String>()
            for shift in shifts {
                let day = cal.startOfDay(for: shift.date)
                guard let target = dayMap[iso(day)] else { continue }
                // Off + qualified + 8h-rest via the unified predicate (#22-proven). cap/soft are
                // physical-irrelevant here, and relief is applied downstream (ECB .full filter).
                if TradeEligibility.canCover(coverDayID: iso(day), coverDay: day, desk: shift.desk,
                                             startHour: shift.startHour, coverMap: dayMap,
                                             coverQuals: target.quals, coverProfile: physicalProbeProfile,
                                             options: .physicalOnly, cal: cal).eligible {
                    covered.insert(shift.id)
                }
            }

            // Bookend = the picked-up day attaches to the candidate's REAL
            // schedule rather than floating in their time off. Treat every shift
            // they're covering in THIS request as worked, then a covered day is a
            // bookend only if its contiguous in-plan work block contains at least
            // one of their EXISTING worked days (the block is anchored).
            //   • OFF-[ON ON ON]-OFF (whole block in their off time) → none count
            //   • W-O-O (give away the edge, attaches to real work)   → counts
            //   • one day of a 2-day weekend W-[O]-O-W                → counts
            //   • lone OFF-ON-OFF                                     → no count
            let coveredDays = Set(shifts.filter { covered.contains($0.id) }
                                        .map { iso(cal.startOfDay(for: $0.date)) })
            func existingWork(_ d: Date) -> Bool { dayMap[iso(d)].map { !$0.isOff } ?? false }
            func worksInPlan(_ d: Date) -> Bool { coveredDays.contains(iso(d)) || existingWork(d) }
            // Walk the in-plan work block out from `day`; true if it touches real work.
            func anchored(_ day: Date) -> Bool {
                for dir in [-1, 1] {
                    var step = dir, guardCount = 0
                    while let cur = cal.date(byAdding: .day, value: step, to: day),
                          worksInPlan(cur), guardCount < 90 {
                        if existingWork(cur) { return true }
                        step += dir; guardCount += 1
                    }
                }
                return false
            }
            var bookendIDs = Set<String>()
            for shift in shifts where covered.contains(shift.id) {
                if anchored(cal.startOfDay(for: shift.date)) { bookendIDs.insert(shift.id) }
            }

            if !covered.isEmpty {
                var week: [DayCell] = []
                if shifts.count == 1, let only = shifts.first {
                    let day = cal.startOfDay(for: only.date)
                    for offset in -4...4 {
                        let d = cal.date(byAdding: .day, value: offset, to: day) ?? day
                        let e = dayMap[iso(d)]
                        let letter = (e != nil && !e!.isOff) ? typeLetter(e!.startHour) : ""
                        week.append(DayCell(weekday: weekdayLetter(d), letter: letter, isTarget: offset == 0))
                    }
                }
                result.append(PlanCandidate(workerID: wid, name: meta.workerName, quals: meta.quals,
                                            coveredShiftIDs: covered, bookendShiftIDs: bookendIDs, week: week))
            }
        }
        return result.sorted {
            if $0.bookendCount != $1.bookendCount { return $0.bookendCount > $1.bookendCount }
            if $0.matchCount != $1.matchCount { return $0.matchCount > $1.matchCount }
            return $0.name < $1.name
        }
    }

    // MARK: - Two-way swap

    /// Explores all feasible BOOKEND swaps with one dispatcher inside a date
    /// window: their work days you could cover (bookend for you) and your work
    /// days they could cover (bookend for them). `wanted` legs are days the owner
    /// actively marked to trade away. Single-worker roster queries keep it cheap.
    static func twoWayExplore(withWorker workerID: String, name: String,
                              windowStart: Date, windowEnd: Date,
                              mySeeking: Set<String>, theirSeeking: Set<String>,
                              myProfile: TradeProfile, theirProfile: TradeProfile, myID: String,
                              ignoreOwnBlacklist: Bool = false,
                              preloadedMine: [RosterEntry]? = nil,
                              preloadedPeer: [RosterEntry]? = nil) async -> TwoWayPlan {
        let cal = Calendar.current
        // Perf (R-A): when the caller already loaded schedules (looping the whole roster), reuse them
        // instead of re-fetching per peer — avoids ~2×N SwiftData queries across 500+ dispatchers.
        let myEntries: [RosterEntry]
        if let pm = preloadedMine { myEntries = pm } else { myEntries = await RosterStore.shared.schedule(forWorker: myID) }
        let pEntries: [RosterEntry]
        if let pp = preloadedPeer { pEntries = pp } else { pEntries = await RosterStore.shared.schedule(forWorker: workerID) }
        let myMap = Dictionary(myEntries.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let pMap  = Dictionary(pEntries.map  { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let myQuals = myEntries.first?.quals ?? []

        func inWindow(_ d: Date) -> Bool { d >= windowStart && d < windowEnd }

        // You take ← their work days you can cover (off + qualified + rested) that
        // pass YOUR rules (availability/openness/bookend/blacklist/mercenary/cap).
        // You take ← their work days you can cover. The unified predicate applies the
        // hard physical gates + your cap + your rules (soft gates skipped when you're
        // overriding your own restrictions). (U1 — delegates to TradeEligibility.canCover.)
        var iTake: [TwoWayLeg] = []
        for pe in pEntries where !pe.isOff {
            guard let day = dateFromISO(pe.day), inWindow(day) else { continue }
            // Their working shift isn't real past THEIR relief horizon — don't offer it.
            if theirProfile.scheduleUnknown(on: day, cal: cal) { continue }
            let check = TradeEligibility.canCover(
                coverDayID: pe.day, coverDay: day, desk: pe.desk, startHour: pe.startHour,
                coverMap: myMap, coverQuals: myQuals, coverProfile: myProfile,
                options: EligibilityOptions(enforceWeeklyCap: true, applySoftGates: !ignoreOwnBlacklist), cal: cal)
            guard check.eligible else { continue }
            iTake.append(TwoWayLeg(dayID: pe.day, date: day, desk: pe.desk, startHour: pe.startHour,
                                   bookend: check.isBookend, wanted: theirSeeking.contains(pe.day)))
        }

        // You give → your work days they can cover that pass THEIR full rules.
        var iGive: [TwoWayLeg] = []
        for me in myEntries where !me.isOff {
            // Never offer a working day you marked KEEP (SPEC S-ENG-9/10) — a give-side gate.
            if myProfile.keepDayIDs?.contains(me.day) == true { continue }
            guard let day = dateFromISO(me.day), inWindow(day), let pe = pMap[me.day] else { continue }
            // My working shift isn't real past MY relief horizon — don't offer it.
            if myProfile.scheduleUnknown(on: day, cal: cal) { continue }
            let check = TradeEligibility.canCover(
                coverDayID: me.day, coverDay: day, desk: me.desk, startHour: me.startHour,
                coverMap: pMap, coverQuals: pe.quals, coverProfile: theirProfile,
                options: .full, cal: cal)
            guard check.eligible else { continue }
            iGive.append(TwoWayLeg(dayID: me.day, date: day, desk: me.desk, startHour: me.startHour,
                                   bookend: check.isBookend, wanted: mySeeking.contains(me.day)))
        }

        let order: (TwoWayLeg, TwoWayLeg) -> Bool = { ($0.wanted ? 0 : 1, $0.date) < ($1.wanted ? 0 : 1, $1.date) }
        return TwoWayPlan(workerID: workerID, name: name,
                          iGive: iGive.sorted(by: order), iTake: iTake.sorted(by: order))
    }

    /// Drives the 🔥×N one-way badge. N = A + B (any aligned trade move counts —
    /// one-way or two-way):
    ///   A = your give-away days (marked ∪ this search's selection) that THEY would
    ///       take — gated by THEIR openness + blacklist (bookend only required if
    ///       their openness is `.bookends`; `.all` accepts any day).
    ///   B = their marked days YOU would take — gated by YOUR openness + blacklist
    ///       (bookend only required if your openness is `.bookends`).
    /// `myEntries` is passed in so your schedule is fetched once.
    static func goldCount(workerID: String, myGiveShifts: [Shift],
                          theirProfile: TradeProfile, myProfile: TradeProfile,
                          myEntries: [RosterEntry]) async -> Int {
        let cal = Calendar.current
        let pEntries = await RosterStore.shared.schedule(forWorker: workerID)
        let myMap = Dictionary(myEntries.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let pMap  = Dictionary(pEntries.map  { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let today = cal.startOfDay(for: Date())
        guard let horizonEnd = cal.date(byAdding: .month, value: twoWayHorizonMonths, to: today) else { return 0 }
        return goldCountPure(myGiveShifts: myGiveShifts, myMap: myMap, pMap: pMap,
                             theirProfile: theirProfile, myProfile: myProfile,
                             myQuals: myEntries.first?.quals ?? [], today: today, horizonEnd: horizonEnd, cal: cal)
    }

    /// PURE core of `goldCount` (A6 — testable WITHOUT RosterStore). N = A + B:
    ///   A = your give-shifts THEY would take · B = their seeking days YOU would take.
    static func goldCountPure(myGiveShifts: [Shift], myMap: [String: RosterEntry], pMap: [String: RosterEntry],
                              theirProfile: TradeProfile, myProfile: TradeProfile, myQuals: [String],
                              today: Date, horizonEnd: Date, cal: Calendar) -> Int {
        func inHorizon(_ d: Date) -> Bool { d >= today && d < horizonEnd }
        // A — your give-away days THEY would take (their openness + blacklist).
        var a = 0
        var countedGive = Set<String>()
        for s in myGiveShifts {
            let day = cal.startOfDay(for: s.date)
            let key = iso(day)
            guard !countedGive.contains(key), inHorizon(day),
                  let pe = pMap[key], pe.isOff,
                  DeskRules.qualified(quals: pe.quals, forDesk: s.desk),
                  rested(map: pMap, day: day, startHour: s.startHour, cal: cal) else { continue }
            let weekday = cal.component(.weekday, from: day)
            let region  = DeskRules.region(forDesk: s.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: s.startHour).rawValue
            let bookend = anchored(day: day, map: pMap, plan: [key], cal: cal)
            guard theirProfile.wouldPickUp(onDay: key, weekday: weekday, desk: s.desk,
                                           shiftType: type, region: region, isBookend: bookend) else { continue }
            countedGive.insert(key); a += 1
        }
        // B — their marked days YOU would take (your openness + blacklist).
        var b = 0
        for dayID in theirProfile.seekingDayIDs {
            guard let pe = pMap[dayID], !pe.isOff, let me = myMap[dayID], me.isOff,
                  let day = dateFromISO(dayID), inHorizon(day),
                  DeskRules.qualified(quals: myQuals, forDesk: pe.desk),
                  rested(map: myMap, day: day, startHour: pe.startHour, cal: cal) else { continue }
            let weekday = cal.component(.weekday, from: day)
            let region  = DeskRules.region(forDesk: pe.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: pe.startHour).rawValue
            let bookend = anchored(day: day, map: myMap, plan: [dayID], cal: cal)
            guard myProfile.wouldPickUp(onDay: dayID, weekday: weekday, desk: pe.desk,
                                        shiftType: type, region: region, isBookend: bookend) else { continue }
            b += 1
        }
        return a + b
    }

    #if DEBUG
    struct MutualSeed: Sendable {
        let peerID: String
        let peerName: String
        let myGiveDayID: String      // a day YOU work that the peer can bookend-cover
        let theirTakeDayID: String   // a day the PEER works that you can bookend-cover
    }

    /// Scans the roster for a peer with whom a true mutual-bookend swap exists, so
    /// the gold 🔥 path can be exercised in testing. Returns the two days to mark.
    static func findMutualBookendPair(excluding myID: String) async -> MutualSeed? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let upper = cal.date(byAdding: .day, value: 90, to: today) else { return nil }
        let entries = await RosterStore.shared.entries(from: today, to: upper)
        var byWorker: [String: [String: RosterEntry]] = [:]
        for e in entries { byWorker[e.workerID, default: [:]][e.day] = e }
        guard let myMap = byWorker[myID] else { return nil }
        let myQuals = myMap.values.first?.quals ?? []

        for (pid, pMap) in byWorker where pid != myID {
            let pQuals = pMap.values.first?.quals ?? []
            // A peer work day you can cover as a bookend.
            let take = pMap.first { (dayID, pe) in
                guard !pe.isOff, let me = myMap[dayID], me.isOff, let d = dateFromISO(dayID),
                      DeskRules.qualified(quals: myQuals, forDesk: pe.desk),
                      rested(map: myMap, day: d, startHour: pe.startHour, cal: cal),
                      anchored(day: d, map: myMap, plan: [dayID], cal: cal) else { return false }
                return true
            }?.key
            guard let take else { continue }
            // A day you work the peer can cover as a bookend.
            let give = myMap.first { (dayID, me) in
                guard !me.isOff, let pe = pMap[dayID], pe.isOff, let d = dateFromISO(dayID),
                      DeskRules.qualified(quals: pQuals, forDesk: me.desk),
                      rested(map: pMap, day: d, startHour: me.startHour, cal: cal),
                      anchored(day: d, map: pMap, plan: [dayID], cal: cal) else { return false }
                return true
            }?.key
            guard let give else { continue }
            return MutualSeed(peerID: pid, peerName: pMap.values.first?.workerName ?? pid,
                              myGiveDayID: give, theirTakeDayID: take)
        }
        return nil
    }
    #endif

    /// Days in a trade request that are no longer valid against the CURRENT master
    /// roster — i.e. the person who should be working that day no longer is (they
    /// already traded it, bid it away, etc.). Empty set = still fully valid.
    /// `giveDayIDs` must be days the SENDER works; `takeDayIDs` days the RECIPIENT
    /// works.
    static func staleDays(fromID: String, toID: String,
                          giveDayIDs: [String], takeDayIDs: [String]) async -> Set<String> {
        let fromSched = await RosterStore.shared.schedule(forWorker: fromID)
        let toSched   = await RosterStore.shared.schedule(forWorker: toID)
        let fromMap = Dictionary(fromSched.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let toMap   = Dictionary(toSched.map   { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        return staleDaysPure(giveDayIDs: giveDayIDs, takeDayIDs: takeDayIDs, fromMap: fromMap, toMap: toMap)
    }

    /// PURE core (S-VALID, testable): a trade day is STALE/invalid when the giver no
    /// longer works it (now off/vacation/gone) or the taker no longer works their leg.
    static func staleDaysPure(giveDayIDs: [String], takeDayIDs: [String],
                              fromMap: [String: RosterEntry], toMap: [String: RosterEntry]) -> Set<String> {
        var stale = Set<String>()
        for d in giveDayIDs where (fromMap[d]?.isOff ?? true) { stale.insert(d) }  // sender no longer works it
        for d in takeDayIDs where (toMap[d]?.isOff ?? true)   { stale.insert(d) }  // recipient no longer works it
        return stale
    }

    /// A worker's day → "AM 82" type+desk label ("" when off), for the larger
    /// trade calendars.
    static func dayLabels(forWorker workerID: String) async -> [String: String] {
        let entries = await RosterStore.shared.schedule(forWorker: workerID)
        var map: [String: String] = [:]
        for e in entries {
            if e.isOff { map[e.day] = "" }
            else {
                let type = ShiftAvailabilityType.infer(fromStartHour: e.startHour).rawValue
                map[e.day] = e.desk.isEmpty ? type : "\(type) \(e.desk)"
            }
        }
        return map
    }

    /// Worked hours in the Sun–Sat week containing `day` (each shift = 9h).
    static func weeklyWorkedHours(map: [String: RosterEntry], around day: Date, cal: Calendar) -> Int {
        guard let week = cal.dateInterval(of: .weekOfYear, for: day) else { return 0 }
        var hours = 0
        for entry in map.values where !entry.isOff {
            if let d = dateFromISO(entry.day), week.contains(d) { hours += 9 }
        }
        return hours
    }

    /// 8-hour rest before/after a shift on `day` vs the map owner's adjacent shifts.
    private static func rested(map: [String: RosterEntry], day: Date, startHour: Int, cal: Calendar) -> Bool {
        guard let coverStart = cal.date(byAdding: .hour, value: startHour, to: cal.startOfDay(for: day)) else { return false }
        let coverEnd = coverStart.addingTimeInterval(shiftLength)
        if let prev = cal.date(byAdding: .day, value: -1, to: day), let p = map[iso(prev)], !p.isOff {
            let pEnd = (cal.date(byAdding: .hour, value: p.startHour, to: cal.startOfDay(for: prev)) ?? prev).addingTimeInterval(shiftLength)
            if coverStart.timeIntervalSince(pEnd) < minRest { return false }
        }
        if let next = cal.date(byAdding: .day, value: 1, to: day), let n = map[iso(next)], !n.isOff {
            let nStart = cal.date(byAdding: .hour, value: n.startHour, to: cal.startOfDay(for: next)) ?? next
            if nStart.timeIntervalSince(coverEnd) < minRest { return false }
        }
        return true
    }

    /// Whether covering `day` attaches to the map owner's existing work (same
    /// "no floating island" bookend rule as the one-way matcher).
    static func anchored(day: Date, map: [String: RosterEntry], plan: Set<String>, cal: Calendar) -> Bool {
        func existingWork(_ d: Date) -> Bool { map[iso(d)].map { !$0.isOff } ?? false }
        func worksInPlan(_ d: Date) -> Bool { plan.contains(iso(d)) || existingWork(d) }
        for dir in [-1, 1] {
            var step = dir, guardCount = 0
            while let cur = cal.date(byAdding: .day, value: step, to: cal.startOfDay(for: day)),
                  worksInPlan(cur), guardCount < 90 {
                if existingWork(cur) { return true }
                step += dir; guardCount += 1
            }
        }
        return false
    }

    // MARK: - Qual swaps (shared by trade search + intents + routes)

    /// Bridge candidates that could unblock giving `giveDesk` on `giveDayID` to a taker
    /// holding `takerQuals` but lacking the desk's qual. THE single entry point used by
    /// every matcher path. Returns [] when no swap is needed, the start hour isn't
    /// tradeable, or nobody qualifies. Bridges with no published profile default to open.
    static func qualSwapBridges(giveDayID: String, giveDesk: String, giveStartHour: Int,
                                takerID: String, takerQuals: [String],
                                excludeIDs: Set<String>) async -> [QualSwapCandidate] {
        guard qualSwapNeededShared(forDesk: giveDesk, takerQuals: takerQuals),
              TradeTiming.isTradeable(startHour: giveStartHour),
              let date = dateFromISO(giveDayID) else { return [] }
        let working = await RosterStore.shared.dispatchersWorking(on: date)
        let workers: [(QualSwapShift, TradeProfile)] = working.map { e in
            let shift = QualSwapShift(workerID: e.workerID, name: e.workerName, desk: e.desk,
                                      startHour: e.startHour, quals: e.quals)
            let prof = TradeProfileStore.shared.profile(forWorker: e.workerID)
                ?? TradeProfile.defaultForUnpublished(workerID: e.workerID, name: e.workerName)   // A8: missing → Bookends Only
            return (shift, prof)
        }
        var exclude = excludeIDs; exclude.insert(takerID)
        return QualSwap.bridges(giveDesk: giveDesk, takerQuals: takerQuals, startHour: giveStartHour,
                                workers: workers, excludeIDs: exclude).map(QualSwap.candidate(from:))
    }

    /// Build an embedded qual-swap leg for giving `giveDesk` to a taker. nil when no swap
    /// is needed or no bridge qualifies. `chosenCandidateIDs` (Q2 multi-select) limits which
    /// bridges to blast — nil/empty = blast all eligible.
    static func buildQualSwapLeg(giveDayID: String, giveDesk: String, giveStartHour: Int,
                                 giverID: String, takerID: String, takerName: String, takerQuals: [String],
                                 chosenCandidateIDs: Set<String>? = nil) async -> QualSwapLegData? {
        var cands = await qualSwapBridges(giveDayID: giveDayID, giveDesk: giveDesk, giveStartHour: giveStartHour,
                                          takerID: takerID, takerQuals: takerQuals, excludeIDs: [giverID])
        if let chosen = chosenCandidateIDs, !chosen.isEmpty {
            cands = cands.filter { chosen.contains($0.workerID) }
        }
        guard !cands.isEmpty else { return nil }
        let qual = DeskRules.requiredQual(forDesk: giveDesk) ?? "D"
        return QualSwapLegData(giveShiftDayID: giveDayID, giveDesk: giveDesk, giveQual: qual,
                               takerID: takerID, takerName: takerName, candidates: cands)
    }

    /// Thin alias so this @MainActor enum can call the pure SSOT gap check by name.
    private static func qualSwapNeededShared(forDesk desk: String, takerQuals: [String]) -> Bool {
        DeskRules.qualSwapNeeded(forDesk: desk, takerQuals: takerQuals)
    }

    // MARK: - Snapshot helpers

    private static func iso(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    private static func dateFromISO(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s).map { Calendar.current.startOfDay(for: $0) }
    }

    private static func weekdayLetter(_ date: Date) -> String {
        switch Calendar.current.component(.weekday, from: date) {
        case 1:  return "Su"
        case 2:  return "M"
        case 3:  return "T"
        case 4:  return "W"
        case 5:  return "Th"
        case 6:  return "F"
        default: return "Sa"
        }
    }

    private static func typeLetter(_ startHour: Int) -> String {
        switch ShiftAvailabilityType.infer(fromStartHour: startHour) {
        case .am:  return "A"
        case .pm:  return "P"
        case .mid: return "M"
        }
    }
}

// MARK: - Reusable hard-gate helpers for the v2 router
//
// `rested`/`anchored`/`iso`/`dateFromISO` are `private` (file-scoped) above. This
// same-file extension re-exposes them as internal wrappers so `TradeRouter` can
// reuse the exact same gate logic instead of duplicating it.
extension TradeMatcher {
    /// 8-hour rest check vs the map owner's adjacent shifts.
    static func isRested(map: [String: RosterEntry], day: Date, startHour: Int,
                         cal: Calendar = .current) -> Bool {
        rested(map: map, day: day, startHour: startHour, cal: cal)
    }

    /// Whether covering `day` attaches to existing work (no floating island).
    static func isAnchored(day: Date, map: [String: RosterEntry], plan: Set<String>,
                           cal: Calendar = .current) -> Bool {
        anchored(day: day, map: map, plan: plan, cal: cal)
    }

    /// ISO "yyyy-MM-dd" for a date.
    static func isoDay(_ date: Date) -> String { iso(date) }

    /// Parse an ISO "yyyy-MM-dd" day string to a start-of-day Date.
    static func dayDate(fromISO s: String) -> Date? { dateFromISO(s) }

    /// Weekly worked hours around a day (exposed for the unified eligibility predicate).
    static func weeklyHours(map: [String: RosterEntry], around day: Date, cal: Calendar = .current) -> Int {
        weeklyWorkedHours(map: map, around: day, cal: cal)
    }
}

// MARK: - Unified eligibility predicate (U1 — shared by Search / Intents / ECB)

/// Toggles for the unified cover predicate. The hard PHYSICAL gates (off · qualified ·
/// 8h-rest) are ALWAYS applied; these switch on the policy gates.
struct EligibilityOptions: Sendable, Hashable {
    var enforceWeeklyCap: Bool
    var applySoftGates: Bool   // wouldPickUp: openness · blacklist · pills · must-be-off · want-to-work
    /// Active searcher / raw physical capacity — hard gates only.
    static let physicalOnly = EligibilityOptions(enforceWeeklyCap: false, applySoftGates: false)
    /// Full policy — Search two-way, Intents, ECB broadcast filter.
    static let full = EligibilityOptions(enforceWeeklyCap: true, applySoftGates: true)
}

/// Result of a cover check: eligible + whether covering this day is a bookend for the coverer.
struct CoverCheck: Sendable, Hashable {
    let eligible: Bool
    let isBookend: Bool
    static let no = CoverCheck(eligible: false, isBookend: false)
}

/// THE single per-(coverer, day) eligibility test — every matcher path calls this instead
/// of its own inline copy (U1). PURE + synchronous: all roster/profile data is passed in
/// (loaded once per search), so it never fetches and is safe in tight loops at 550-user scale.
@MainActor
enum TradeEligibility {
    /// Can `coverProfile` (off-roster `coverMap`, holding `coverQuals`) cover a shift on
    /// `coverDay`/`desk`/`startHour`? Returns eligibility + the computed bookend flag.
    static func canCover(coverDayID: String, coverDay: Date, desk: String, startHour: Int,
                         coverMap: [String: RosterEntry], coverQuals: [String],
                         coverProfile: TradeProfile, options: EligibilityOptions,
                         cal: Calendar = .current) -> CoverCheck {
        // Relief dispatcher: their schedule isn't real past the horizon, so they can't cover then.
        if coverProfile.scheduleUnknown(on: coverDay, cal: cal) { return .no }
        // Hard PHYSICAL gates (always): coverer is off that day, qualified for the desk, 8h-rested.
        guard let entry = coverMap[coverDayID], entry.isOff,
              DeskRules.qualified(quals: coverQuals, forDesk: desk),
              TradeMatcher.isRested(map: coverMap, day: coverDay, startHour: startHour, cal: cal)
        else { return .no }
        // Bookend = covering this day attaches to the coverer's existing work (no floating island).
        let bookend = TradeMatcher.isAnchored(day: coverDay, map: coverMap, plan: [coverDayID], cal: cal)

        // Hard policy: weekly-hour cap (a 9h shift would push them over).
        if options.enforceWeeklyCap, let cap = coverProfile.maxWeeklyHours,
           TradeMatcher.weeklyHours(map: coverMap, around: coverDay, cal: cal) + 9 > cap {
            return CoverCheck(eligible: false, isBookend: bookend)
        }
        // Soft policy: openness / blacklist / pills / must-be-off / want-to-work, via the SSOT.
        if options.applySoftGates {
            let weekday = cal.component(.weekday, from: coverDay)
            let region  = DeskRules.region(forDesk: desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: startHour).rawValue
            guard coverProfile.wouldPickUp(onDay: coverDayID, weekday: weekday, desk: desk,
                                           shiftType: type, region: region, isBookend: bookend)
            else { return CoverCheck(eligible: false, isBookend: bookend) }
        }
        return CoverCheck(eligible: true, isBookend: bookend)
    }
}
