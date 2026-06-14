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
        case .all:      return "Open to all trades & ECB"
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

// MARK: - Desk → region / qualification rules

enum DeskRegion: String, Sendable {
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
            case 48...58:           return .european
            case 60...63, 72...83:  return .latin
            case 64...68:           return .pacific
            default:                return .domestic        // 1–47, 59, 69–71
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
                guard let target = dayMap[iso(day)], target.isOff,
                      DeskRules.qualified(quals: target.quals, forDesk: shift.desk),
                      let prevDay = cal.date(byAdding: .day, value: -1, to: day),
                      let nextDay = cal.date(byAdding: .day, value:  1, to: day),
                      let coverStart = cal.date(byAdding: .hour, value: shift.startHour, to: day)
                else { continue }
                let coverEnd = coverStart.addingTimeInterval(shiftLength)

                if let p = dayMap[iso(prevDay)], !p.isOff {
                    let pEnd = (cal.date(byAdding: .hour, value: p.startHour, to: prevDay) ?? prevDay).addingTimeInterval(shiftLength)
                    if coverStart.timeIntervalSince(pEnd) < minRest { continue }
                }
                if let n = dayMap[iso(nextDay)], !n.isOff {
                    let nStart = cal.date(byAdding: .hour, value: n.startHour, to: nextDay) ?? nextDay
                    if nStart.timeIntervalSince(coverEnd) < minRest { continue }
                }

                covered.insert(shift.id)
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
                              myProfile: TradeProfile, myID: String,
                              ignoreOwnBlacklist: Bool = false) async -> TwoWayPlan {
        let cal = Calendar.current
        let myEntries = await RosterStore.shared.schedule(forWorker: myID)
        let pEntries  = await RosterStore.shared.schedule(forWorker: workerID)
        let myMap = Dictionary(myEntries.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let pMap  = Dictionary(pEntries.map  { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let myQuals = myEntries.first?.quals ?? []

        func inWindow(_ d: Date) -> Bool { d >= windowStart && d < windowEnd }

        // You take ← their work days you can cover (off + qualified + rested + not
        // blacklisted) that are a bookend for YOU.
        var iTake: [TwoWayLeg] = []
        for pe in pEntries where !pe.isOff {
            guard let day = dateFromISO(pe.day), inWindow(day),
                  let me = myMap[pe.day], me.isOff,
                  DeskRules.qualified(quals: myQuals, forDesk: pe.desk),
                  rested(map: myMap, day: day, startHour: pe.startHour, cal: cal) else { continue }
            let weekday = cal.component(.weekday, from: day)
            let region  = DeskRules.region(forDesk: pe.desk).rawValue
            let type    = ShiftAvailabilityType.infer(fromStartHour: pe.startHour).rawValue
            // Active-outbound override: the blacklist OWNER doing a manual search
            // can choose to see (and override) their own blocked slots.
            if !ignoreOwnBlacklist {
                if myProfile.blacklistedWeekdays.contains(weekday) { continue }
                if myProfile.blacklistedDesks.contains(pe.desk) { continue }
                if myProfile.blacklistedShiftTypes.contains(type) { continue }
                if myProfile.blacklistedRegions.contains(region) { continue }
            }
            // Hard: my weekly-hour cap — covering this shift can't blow my limit.
            if let cap = SettingsManager.shared.maxWeeklyHours,
               weeklyWorkedHours(map: myMap, around: day, cal: cal) + 9 > cap { continue }
            guard anchored(day: day, map: myMap, plan: [pe.day], cal: cal) else { continue }
            iTake.append(TwoWayLeg(dayID: pe.day, date: day, desk: pe.desk, startHour: pe.startHour,
                                   bookend: true, wanted: theirSeeking.contains(pe.day)))
        }

        // You give → your work days they can cover that are a bookend for THEM.
        var iGive: [TwoWayLeg] = []
        for me in myEntries where !me.isOff {
            guard let day = dateFromISO(me.day), inWindow(day),
                  let pe = pMap[me.day], pe.isOff,
                  DeskRules.qualified(quals: pe.quals, forDesk: me.desk),
                  rested(map: pMap, day: day, startHour: me.startHour, cal: cal) else { continue }
            guard anchored(day: day, map: pMap, plan: [me.day], cal: cal) else { continue }
            iGive.append(TwoWayLeg(dayID: me.day, date: day, desk: me.desk, startHour: me.startHour,
                                   bookend: true, wanted: mySeeking.contains(me.day)))
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
        let myQuals = myEntries.first?.quals ?? []

        let today = cal.startOfDay(for: Date())
        guard let horizonEnd = cal.date(byAdding: .month, value: twoWayHorizonMonths, to: today) else { return 0 }
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
            guard theirProfile.acceptsPickup(weekday: weekday, desk: s.desk, shiftType: type, region: region) else { continue }
            if theirProfile.opennessLevel != .all,
               !anchored(day: day, map: pMap, plan: [key], cal: cal) { continue }
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
            guard myProfile.acceptsPickup(weekday: weekday, desk: pe.desk, shiftType: type, region: region) else { continue }
            if myProfile.opennessLevel != .all,
               !anchored(day: day, map: myMap, plan: [dayID], cal: cal) { continue }
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

        var stale = Set<String>()
        for d in giveDayIDs where (fromMap[d]?.isOff ?? true) { stale.insert(d) }  // sender no longer works it
        for d in takeDayIDs where (toMap[d]?.isOff ?? true)   { stale.insert(d) }  // recipient no longer works it
        return stale
    }

    /// A worker's day → "A"/"P"/"M" (or "" when off) map, for the mini-schedule glance.
    static func dayLetters(forWorker workerID: String) async -> [String: String] {
        let entries = await RosterStore.shared.schedule(forWorker: workerID)
        var map: [String: String] = [:]
        for e in entries { map[e.day] = e.isOff ? "" : typeLetter(e.startHour) }
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
    private static func anchored(day: Date, map: [String: RosterEntry], plan: Set<String>, cal: Calendar) -> Bool {
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
}
