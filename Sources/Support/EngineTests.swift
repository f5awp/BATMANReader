// EngineTests.swift
// A runnable self-test harness for the trade engine. There's no XCTest target, so
// these are plain assertions invokable from Developer Tools (Settings → Developer →
// "Run engine tests"). Returns the list of failures ([] = all pass). Covers the
// risky, pure logic: min-cost flow, the optimal reciprocal matcher (golden cases,
// balance, determinism, infeasibility), holiday math, and the pickup gate.

import Foundation
import SwiftData

#if DEBUG   // Z1: the self-test harness ships in DEBUG only — excluded from Release/TestFlight builds.

@MainActor
enum TradeEngineTests {

    static func runAll() -> [String] {
        var fails: [String] = []
        func check(_ cond: Bool, _ msg: String) { if !cond { fails.append("❌ \(msg)") } }

        // MARK: Min-cost flow — a tiny known instance.
        do {
            var mcf = MinCostFlow(nodes: 4)
            mcf.addEdge(0, 1, cap: 1, cost: 0)
            mcf.addEdge(1, 2, cap: 1, cost: 5)
            mcf.addEdge(2, 3, cap: 1, cost: 0)
            let (f, c) = mcf.run(from: 0, to: 3)
            check(f == 1 && c == 5, "MCF basic: expected flow 1 cost 5, got \(f)/\(c)")

            // Two parallel paths, cheaper first.
            var m2 = MinCostFlow(nodes: 4)
            m2.addEdge(0, 1, cap: 2, cost: 0)
            m2.addEdge(1, 3, cap: 1, cost: 1)   // cheap
            m2.addEdge(1, 3, cap: 1, cost: 10)  // expensive
            let (f2, c2) = m2.run(from: 0, to: 3)
            check(f2 == 2 && c2 == 11, "MCF two-path: expected flow 2 cost 11, got \(f2)/\(c2)")
        }

        // MARK: Optimal reciprocal matcher.
        let A = OptimalMatcher.Cand(id: "001", name: "A", canTake: ["d1", "d2"], givesBack: ["x1", "x2"])
        let B = OptimalMatcher.Cand(id: "002", name: "B", canTake: ["d1"], givesBack: ["y1"])
        let C = OptimalMatcher.Cand(id: "003", name: "C", canTake: ["d2"], givesBack: ["z1"])

        let one = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [A, B, C])
        check(one?.count == 1, "Optimal: 1-person cover preferred over 2, got \(String(describing: one?.count))")
        check(balanced(one), "Optimal: balanced give==take")

        let split = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [B, C])
        check(split?.count == 2, "Optimal: 2-person split when no single covers both")

        let infeasible = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [B])
        check(infeasible == nil, "Optimal: infeasible (d2 uncoverable) → nil")

        let unbalanced = OptimalMatcher.Cand(id: "001", name: "A", canTake: ["d1", "d2"], givesBack: ["x1"])
        let ub = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [unbalanced])
        check(ub == nil, "Optimal: give 2 / back 1 with one peer is unbalanced → nil")

        let r1 = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [B, C, A])
        let r2 = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [A, C, B])
        check(r1?.map(\.id).sorted() == r2?.map(\.id).sorted(), "Optimal: deterministic across peer order")

        // Contiguity gate (the no-split rule shared by the optimal AND greedy paths):
        // a validator that rejects every assignment must yield NO solution — a
        // break-fragmenting package is never emitted.
        let blocked = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [A, B, C],
                                                         contiguous: { _ in false })
        check(blocked == nil, "Contiguity: rejecting validator → nil (never split a break)")
        let allowed = OptimalMatcher.minPeopleReciprocal(giveDayIDs: ["d1", "d2"], peers: [A, B, C],
                                                         contiguous: { _ in true })
        check(allowed?.count == 1, "Contiguity: permissive validator still returns the 1-person cover")

        // MARK: Holiday math (2026).
        let h = Holidays.map(year: 2026)
        check(h["2026-01-01"] == "New Year's Day", "Holiday: New Year 2026")
        check(h["2026-01-19"] == "Martin Luther King Day", "Holiday: MLK 2026 = 3rd Mon Jan (Jan 19)")
        check(h["2026-02-16"] == "Presidents Day", "Holiday: Presidents 2026 = 3rd Mon Feb")
        check(h["2026-04-03"] == "Good Friday", "Holiday: Good Friday 2026 (Easter Apr 5)")
        check(h["2026-05-25"] == "Memorial Day", "Holiday: Memorial 2026 = last Mon May")
        check(h["2026-09-07"] == "Labor Day", "Holiday: Labor 2026 = 1st Mon Sep")
        check(h["2026-11-26"] == "Thanksgiving Day", "Holiday: Thanksgiving 2026 = 4th Thu Nov")
        check(h["2026-11-27"] == "Day after Thanksgiving", "Holiday: Day-after 2026")
        check(h["2026-12-25"] == "Christmas Day", "Holiday: Christmas 2026")

        // MARK: Pickup gate (wouldPickUp) — bookends + mercenary.
        var prof = TradeProfile(workerID: "001", displayName: "A", openness: "bookends",
                                blacklistedWeekdays: [], blacklistedDesks: [],
                                blacklistedShiftTypes: [], blacklistedRegions: [],
                                seekingDayIDs: [], updatedAt: Date.distantPast)
        check(prof.wouldPickUp(onDay: "2026-07-04", weekday: 7, desk: "29", shiftType: "AM", region: "Domestic", isBookend: false) == false,
              "wouldPickUp: bookends rejects non-bookend")
        check(prof.wouldPickUp(onDay: "2026-07-04", weekday: 7, desk: "29", shiftType: "AM", region: "Domestic", isBookend: true) == true,
              "wouldPickUp: bookends accepts bookend")
        prof.isMercenaryMode = true
        check(prof.wouldPickUp(onDay: "x", weekday: 1, desk: "29", shiftType: "AM", region: "Domestic", isBookend: false) == true,
              "wouldPickUp: mercenary takes any qualifying shift")
        prof.isMercenaryMode = false

        // Blacklist always blocks (even mercenary off).
        var bl = prof
        bl.isMercenaryMode = true
        let blProf = TradeProfile(workerID: "001", displayName: "A", openness: "all",
                                  blacklistedWeekdays: [], blacklistedDesks: ["29"],
                                  blacklistedShiftTypes: [], blacklistedRegions: [],
                                  seekingDayIDs: [], updatedAt: Date.distantPast)
        check(blProf.wouldPickUp(onDay: "x", weekday: 1, desk: "29", shiftType: "AM", region: "Domestic", isBookend: true) == false,
              "wouldPickUp: blacklisted desk blocked")

        // MARK: Intent preservation on master re-import (SPEC S-PARSE-2 / S-TEST-2 #2).
        // The invariant the old `reconcile(withShifts:)` broke: an UNCHANGED day must
        // never be reset; only added/removed/changed days are.
        func day(_ iso: String, off: Bool) -> Shift {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
            let d = f.date(from: iso) ?? Date(timeIntervalSince1970: 0)
            return off ? Shift(id: iso, date: d, startHour: 0, endHour: 0, role: .off, desk: "", leaveCode: nil, isOff: true)
                       : Shift(id: iso, date: d, startHour: 5, endHour: 14, role: .dispatcher, desk: "29", leaveCode: nil, isOff: false)
        }
        // 07-01 unchanged(work); 07-02 work→off (changed); 07-03 unchanged(off); 07-04 added.
        let oldS = [day("2026-07-01", off: false), day("2026-07-02", off: false), day("2026-07-03", off: true)]
        let newS = [day("2026-07-01", off: false), day("2026-07-02", off: true),
                    day("2026-07-03", off: true),  day("2026-07-04", off: false)]
        let (reset, gone) = DayIntentStore.reconcileTargets(diff: .compute(old: oldS, new: newS))
        check(!reset.contains("2026-07-01"), "reconcile: unchanged WORKING day must NOT reset (the wipe bug)")
        check(!reset.contains("2026-07-03"), "reconcile: unchanged OFF day must NOT reset")
        check(reset.contains("2026-07-02"),  "reconcile: flipped day IS reset")
        check(reset.contains("2026-07-04"),  "reconcile: added day IS reset")
        check(gone.isEmpty,                  "reconcile: nothing removed in this diff")
        // Removed day: reset AND note-dropping (gone).
        let (reset2, gone2) = DayIntentStore.reconcileTargets(
            diff: .compute(old: [day("2026-07-01", off: false), day("2026-07-09", off: false)],
                           new: [day("2026-07-01", off: false)]))
        check(!reset2.contains("2026-07-01"), "reconcile: unchanged survives even when another day is removed")
        check(reset2.contains("2026-07-09") && gone2.contains("2026-07-09"), "reconcile: removed day reset + gone")

        // MARK: Vacation parsing (SPEC S-PARSE-1 / S-TEST-2 #1). An "L|V" annotation
        // overrides the printed shift → genuine day OFF carrying leaveCode "V". A day
        // with no annotation stays as printed. Mirrors the real Keriellen Nov data.
        let vacCSV = """
        Name (ID) Qualification,,Nov,,Nov,,Nov,,Nov,
        ,,05,,06,,07,,08,
        ,,Thu,,Fri,,Sat,,Sun,
        ,"Test, T  (999999) D",21,,21,,21,,05,20
        ,,L,V,L,V,,,L,V
        """
        if let w = try? ScheduleParser().parseAllWorkers(csv: vacCSV).first(where: { $0.id == "999999" }) {
            let v05 = w.shifts.first { $0.id == "2026-11-05" }
            let v06 = w.shifts.first { $0.id == "2026-11-06" }
            let w07 = w.shifts.first { $0.id == "2026-11-07" }
            let t08 = w.shifts.first { $0.id == "2026-11-08" }
            check(v05?.isOff == true && v05?.leaveCode == "V" && v05?.isVacation == true, "Vacation: 11-05 L|V (no desk) → off + leaveCode V + isVacation")
            check(v06?.isOff == true && v06?.leaveCode == "V", "Vacation: 11-06 L|V (no desk) → off + leaveCode V")
            check(w07?.isOff == false && w07?.startHour == 21 && w07?.leaveCode == nil,
                  "Vacation: 11-07 (no annotation) stays a normal working shift")
            // A vacation day still prints its base rotation (incl. a desk) — it must stay OFF. (The Build 5
            // "traded back in if a desk is printed" heuristic was reverted; it wrongly flipped real vacations.)
            check(t08?.isOff == true && t08?.leaveCode == "V",
                  "Vacation: 11-08 L|V WITH a desk (no clear home desk in this fixture) → vacation OFF")
        } else {
            check(false, "Vacation: parser failed to return worker 999999")
        }

        // MARK: Vacation resolution (B6-VAC-2LINE) — resolved at INGEST from the stacked shift lines.
        // The export prints a base/vacation-placeholder line (carries L,V or L,w) AND, when picked up, a
        // second WORKED line on the traded-in desk. The worked shift = the NON-vacation line whose desk
        // isn't also a vacation/base desk. A genuine vacation has only the V line (no worked line) → OFF.
        // Oracle values are the user-confirmed real fixture (Documentation/fixtures/expanded_schedule_sample.csv):
        //   Gar 523734 Jul 20-23 → 62/63/63/63 ; Ervin 292216 Jul 26-29 → 20/43/01/34.
        do {
            typealias C = ScheduleParser.DayCandidate
            let dt = Date(timeIntervalSince1970: 1_700_000_000)
            func resolve(_ cands: [C]) -> Shift { ScheduleParser.resolveDay(cands, date: dt, dayID: "d") }
            func work(_ h: Int, _ desk: String, v: Bool) -> C {
                C(startHour: h, desk: desk, isVacationLeave: v, vacationCode: v ? "V" : nil, otherLeaveCode: nil)
            }
            func offC() -> C { C(startHour: nil, desk: "", isVacationLeave: false, vacationCode: nil, otherLeaveCode: nil) }

            // Gar Jul 20: base 24 [V] + worked 62 → 62. Jul 21: worked 63 + base 24 [V] → 63 (order-independent).
            let g20 = resolve([work(5, "24", v: true), work(5, "62", v: false)])
            check(!g20.isOff && g20.desk == "62", "B6-VAC-2LINE: Gar Jul20 picks the worked non-V desk 62 (got \(g20.isOff ? "OFF" : g20.desk))")
            let g21 = resolve([work(5, "63", v: false), work(5, "24", v: true)])
            check(!g21.isOff && g21.desk == "63", "B6-VAC-2LINE: Gar Jul21 picks 63 regardless of line order")

            // Ervin (lines page-split across strips): Jul 26 = 41 [V] + 20 → 20 ; Jul 27 = 43 + 41 [V] → 43.
            let e26 = resolve([work(5, "41", v: true), work(5, "20", v: false)])
            let e27 = resolve([work(5, "43", v: false), work(5, "41", v: true)])
            check(!e26.isOff && e26.desk == "20" && !e27.isOff && e27.desk == "43",
                  "B6-VAC-2LINE: Ervin Jul26→20 (worked) and Jul27→43 (worked), a mix of both stacked lines")

            // Genuine vacation (Gar Jul 7): only the V line has a shift, other line OFF → OFF vacation.
            let gen = resolve([work(5, "39", v: true), offC()])
            check(gen.isOff && gen.isVacation, "B6-VAC-2LINE: a lone V line with no worked line → genuine vacation OFF")

            // Dropped annotation on a duplicate strip: the non-V desk equals the V/base desk → NOT a pickup → OFF.
            let drop = resolve([work(5, "22", v: true), work(5, "22", v: false)])
            check(drop.isOff, "B6-VAC-2LINE: non-V desk == V/base desk is a dropped annotation, not a pickup → OFF")

            // ECB VC ("w") behaves exactly like V.
            let wc = resolve([C(startHour: 5, desk: "24", isVacationLeave: true, vacationCode: "w", otherLeaveCode: nil),
                              work(5, "62", v: false)])
            check(!wc.isOff && wc.desk == "62", "B6-VAC-2LINE: ECB-VC (w) placeholder + worked line → picks the worked desk 62")

            // A normal working day (no vacation anywhere) is untouched.
            let norm = resolve([work(13, "22", v: false), offC()])
            check(!norm.isOff && norm.desk == "22", "B6-VAC-2LINE: a normal working day resolves to its worked desk")
        }

        // B6-AUTOCOMPLETE: a master import flipping my schedule proves a pending trade went through.
        do {
            func req(from: String, to: String, give: [String], take: [String]) -> TradeRequest {
                TradeRequest(id: "r", fromID: from, fromName: from, toID: to, toName: to, note: "",
                             takeDayIDs: take, giveDayIDs: give, createdAt: Date(),
                             expiresAt: Date().addingTimeInterval(9999))
            }
            let r = req(from: "me", to: "x", give: ["D1"], take: ["D2"])
            let legs = TradeProof.myLegs(r, myID: "me")
            check(legs.give == ["D1"] && legs.take == ["D2"], "B6-AUTO: sender legs = give→giveDays, take→takeDays")
            let legsR = TradeProof.myLegs(r, myID: "x")
            check(legsR.give == ["D2"] && legsR.take == ["D1"], "B6-AUTO: recipient legs are mirrored")
            check(TradeProof.proved(give: ["D1"], take: ["D2"], becameOff: ["D1"], becameWorking: ["D2"]),
                  "B6-AUTO: proved when every give→off and take→working")
            check(!TradeProof.proved(give: ["D1"], take: ["D2"], becameOff: ["D1"], becameWorking: []),
                  "B6-AUTO: a PARTIAL match is NOT proved (false-positive guard)")
            check(!TradeProof.proved(give: [], take: [], becameOff: ["D1"], becameWorking: ["D2"]),
                  "B6-AUTO: a request not touching my schedule is never auto-completed")
            let d0 = Date()
            func sh(_ id: String, off: Bool) -> Shift {
                Shift(id: id, date: d0, startHour: off ? 0 : 5, endHour: off ? 0 : 14,
                      role: off ? .off : .dispatcher, desk: off ? "" : "22", leaveCode: nil, isOff: off)
            }
            let diff = ScheduleDiff.compute(old: [sh("D1", off: false), sh("D2", off: true)],
                                            new: [sh("D1", off: true),  sh("D2", off: false)])
            let t = TradeProof.transitions(diff)
            check(t.becameOff.contains("D1") && t.becameWorking.contains("D2"),
                  "B6-AUTO: transitions() reads working→off and off→working from a diff")
            var chainReq = req(from: "me", to: "x", give: [], take: [])
            chainReq.chain = [TradeLeg(fromID: "me", fromName: "me", toID: "x", toName: "x", dayID: "G"),
                              TradeLeg(fromID: "y", fromName: "y", toID: "me", toName: "me", dayID: "T")]
            let cl = TradeProof.myLegs(chainReq, myID: "me")
            check(cl.give == ["G"] && cl.take == ["T"], "B6-AUTO: chain legs mapped by fromID/toID")
        }

        // B6-ECB60: the ECB behavior filter (4101) — only offer a shift to someone who actually WORKED
        // that TYPE in the last 60 days. A MID-only dispatcher is excluded from a PM offer; someone who
        // worked PM recently passes; an empty recent set (robot/inactive) is always excluded.
        do {
            check(TradeMatcher.recentBehaviorAllows(recentTypes: [.pm, .am], coveredTypes: [.pm]),
                  "B6-ECB60: recently worked PM → included for a PM offer")
            check(!TradeMatcher.recentBehaviorAllows(recentTypes: [.mid], coveredTypes: [.pm]),
                  "B6-ECB60: MID-only recent behavior → excluded from a PM offer")
            check(!TradeMatcher.recentBehaviorAllows(recentTypes: [], coveredTypes: [.pm, .am, .mid]),
                  "B6-ECB60: no recent work (robot/inactive) → excluded from any offer")
        }

        // B6-FILTER: the Trade Solutions date-range criterion keeps only solutions whose EVERY moved
        // day (give + get) falls inside the window; a package with any day outside is dropped.
        do {
            func pkg(_ give: [String], _ take: [String]) -> TradePackage {
                TradePackage(id: give.joined() + take.joined(), methodology: .greedy,
                             assignments: [PackageAssignment(workerID: "x", name: "X", giveDayIDs: give, takeDayIDs: take)],
                             route: nil)
            }
            let inWindow  = pkg(["2026-07-10"], ["2026-07-20"])
            let outWindow = pkg(["2026-07-10"], ["2026-08-05"])   // Aug 5 is past the end
            let df = DateFormatter(); df.calendar = Calendar(identifier: .gregorian); df.dateFormat = "yyyy-MM-dd"
            func d(_ iso: String) -> Date { df.date(from: iso) ?? Date() }
            var f = SearchFilter(); f.dateStart = d("2026-07-01"); f.dateEnd = d("2026-07-31")
            let kept = f.filter([inWindow, outWindow], selfID: "")
            check(kept.contains(inWindow) && !kept.contains(outWindow),
                  "B6-FILTER: date range keeps trades whose RECEIVED day is in-window, drops out-of-window receives")
        }

        // (Removed: the old "vacation auto-sets Must-Be-Off + 'vacation' note" checks — that behavior was
        // intentionally dropped in the vacation-leave-code model; reconcile no longer auto-blacks-out
        // vacation days or stamps an auto note.)

        // MARK: Trade-type label SOT (SPEC S-ENG-5 / S-TEST-1). The fix for the
        // "3-way / 2-way" contradiction: one function, distinct-people count, three shapes.
        check(tradeTypeLabel(distinctPeople: 2) == "2-Person Swap", "label: You+Cary ⇒ 2-Person Swap")
        check(tradeTypeLabel(distinctPeople: 3) == "3-Person Swap", "label: 3 ⇒ 3-Person Swap")
        check(tradeTypeLabel(distinctPeople: 1) == "2-Person Swap", "label: floor at 2-Person Swap")
        check(tradeTypeLabel(distinctPeople: 2, isOneWayECB: true) == "1-Way Swap", "label: ECB ⇒ 1-Way Swap")
        check(tradeTypeLabel(distinctPeople: 3, hasQualSwap: true) == "Qual Swap", "label: qual ⇒ Qual Swap")
        check(tradeTypeLabel(distinctPeople: 2, isOneWayECB: true, hasQualSwap: true) == "1-Way Swap",
              "label: ECB precedence over qual")
        for n in 1...6 { for ecb in [false, true] { for q in [false, true] {
            let s = tradeTypeLabel(distinctPeople: n, isOneWayECB: ecb, hasQualSwap: q)
            check(s == "1-Way Swap" || s == "Qual Swap" || s.hasSuffix("-Person Swap"),
                  "label universe: unexpected '\(s)'")
        }}}
        let recipLegs = [TradeLeg(fromID: "A", fromName: "A", toID: "B", toName: "B", dayID: "d1"),
                         TradeLeg(fromID: "B", fromName: "B", toID: "A", toName: "A", dayID: "d2")]
        check(distinctParticipants(in: recipLegs) == 2, "distinctParticipants: 2-person reciprocal ⇒ 2 (the B2 bug)")

        // MARK: Negative-intent gate (SPEC S-ENG-9/10). A Must-Be-Off day is NEVER
        // offered as a pickup — even otherwise-pickable, even under mercenary. June-23 fix.
        var np = TradeProfile(workerID: "001", displayName: "A", openness: "all",
                              blacklistedWeekdays: [], blacklistedDesks: [],
                              blacklistedShiftTypes: [], blacklistedRegions: [],
                              seekingDayIDs: [], updatedAt: Date.distantPast)
        np.mustBeOffDayIDs = ["2026-06-23"]
        check(np.wouldPickUp(onDay: "2026-06-23", weekday: 3, desk: "29", shiftType: "AM", region: "Domestic", isBookend: true) == false,
              "wouldPickUp: Must-Be-Off day never offered (June-23 bug)")
        check(np.wouldPickUp(onDay: "2026-06-24", weekday: 4, desk: "29", shiftType: "AM", region: "Domestic", isBookend: true) == true,
              "wouldPickUp: a non-marked day still offered")
        np.isMercenaryMode = true
        check(np.wouldPickUp(onDay: "2026-06-23", weekday: 3, desk: "29", shiftType: "AM", region: "Domestic", isBookend: false) == false,
              "wouldPickUp: Must-Be-Off beats mercenary")

        // Negative-intent sets derive from intents (these feed the matcher gates). Sentinel days.
        do {
            let store = DayIntentStore.shared
            let kd = "2099-04-01", md = "2099-04-02"
            let clean = store.workingIntent(forDay: kd) == nil && store.offIntent(forDay: md) == nil
            store.setWorkingIntent(.mustWork, forDay: kd)
            store.setOffIntent(.mustBeOff, forDay: md)
            check(store.keepDayIDs.contains(kd), "keepDayIDs: mustWork day present")
            check(store.mustBeOffDayIDs.contains(md), "mustBeOffDayIDs: mustBeOff day present")
            check(!store.seekingDayIDs.contains(kd), "Keep day is NOT a give-away (seeking) day")
            store.clearIntent(forDay: kd); store.clearIntent(forDay: md)   // cleanup
            check(clean, "keep/mustBeOff sentinel days clean before test")
        }

        // MARK: Feed-refresh trigger (SPEC S-ENG-9). The match-inputs signature MUST
        // change when openness / intents change, so the feed recomputes (the "nothing
        // refreshed" bug). Pure — no view needed.
        func sig(_ openness: String, _ off: [String: OffIntentState]) -> MatchInputsSignature {
            MatchInputsSignature(openness: openness, mercenary: false, working: [:], off: off,
                                 availability: [:], blacklistDesks: [], blacklistRegions: [],
                                 blacklistWeekdays: [], blacklistShiftTypes: [])
        }
        check(sig("bookends", [:]) != sig("all", [:]), "match signature changes when openness changes")
        check(sig("bookends", [:]) != sig("bookends", ["2026-06-23": .mustBeOff]),
              "match signature changes when an intent changes")
        check(sig("bookends", [:]) == sig("bookends", [:]), "match signature stable for identical inputs")

        // MARK: Mercenary forces openness to All (SPEC S-ENG-6). "Not accepting +
        // mercenary" cannot coexist. Save/restore the singleton.
        do {
            let s = SettingsManager.shared
            let oldMerc = s.isMercenaryMode, oldOpen = s.tradeOpenness
            s.tradeOpenness = "none"
            s.isMercenaryMode = true
            check(s.tradeOpenness == TradeOpenness.all.rawValue, "mercenary forces openness to All")
            s.isMercenaryMode = oldMerc; s.tradeOpenness = oldOpen   // restore
        }

        // MARK: ECB amount — 0.5 steps, 5…25 (SPEC S-ENG-8 / A4).
        check(TradeRequest.isValidECB(13.5), "ECB: 13.5 valid (1.5× OT)")
        check(TradeRequest.isValidECB(5) && TradeRequest.isValidECB(25), "ECB: bounds 5 and 25 valid")
        check(!TradeRequest.isValidECB(4.5), "ECB: below 5 invalid")
        check(!TradeRequest.isValidECB(25.5), "ECB: above 25 invalid")
        check(!TradeRequest.isValidECB(13.3), "ECB: non-0.5 step invalid")
        check(TradeRequest.clampECB(4) == 5 && TradeRequest.clampECB(30) == 25, "ECB: clamp to 5…25")
        check(TradeRequest.clampECB(13.3) == 13.5, "ECB: clamp rounds to nearest 0.5")
        check(ecbText(9) == "9" && ecbText(13.5) == "13.5", "ecbText: drops trailing .0")

        // MARK: ECB-MODEL — a request's offer helpers drive the proposal card's accept options.
        do {
            func req(take: [String], give: [String], ecb: Double?, kind: TradeKind?) -> TradeRequest {
                var r = TradeRequest(id: "x", fromID: "a", fromName: "A", toID: "b", toName: "B", note: "",
                                     takeDayIDs: take, giveDayIDs: give, createdAt: Date(timeIntervalSince1970: 1),
                                     expiresAt: Date(timeIntervalSince1970: 100), ecbValue: ecb)
                r.offerKind = kind
                return r
            }
            let dayOnly = req(take: ["d1"], give: ["d2"], ecb: nil, kind: .day)
            check(dayOnly.offersDayForDay && !dayOnly.offersECB && !dayOnly.offersChoice, "ECB-MODEL: day-only offers swap, not ECB")
            let ecbOnly = req(take: [], give: ["d2"], ecb: 9, kind: .ecb)
            check(ecbOnly.isECB && ecbOnly.offersECB && !ecbOnly.offersDayForDay && !ecbOnly.offersChoice, "ECB-MODEL: ecb-only is one-way points")
            let both = req(take: ["d1"], give: ["d2"], ecb: 9, kind: .both)
            check(both.offersChoice && both.offersECB && both.offersDayForDay && !both.isECB, "ECB-MODEL: Both offers a real either/or, not a pure ECB")
        }

        // MARK: ECB-LEDGER — one shared trade line moves points on BOTH sides. Once RECEIVED (cleared) it
        // credits the payee (taker) +amount and debits the payer (giver) −amount — no second entry.
        do {
            let giver = "G", taker = "T"
            let cleared = ECBEntry(date: Date(timeIntervalSince1970: 1), amount: 9, category: .trade, memo: "",
                                   cleared: true, payerID: giver, payerName: "G", payeeID: taker, payeeName: "T", state: .confirmed)
            check(ECBAccounting.available([cleared], viewerID: taker) == 9, "ECB-LEDGER: received line credits the taker +amount")
            check(ECBAccounting.available([cleared], viewerID: giver) == -9, "ECB-LEDGER: same line debits the giver −amount")
            var iou = cleared; iou.cleared = false
            check(ECBAccounting.available([iou], viewerID: taker) == 0, "ECB-LEDGER: an un-received IOU isn't in available yet")
            check(ECBAccounting.owed([iou], myID: taker) == 9 && ECBAccounting.owe([iou], myID: giver) == 9, "ECB-LEDGER: an IOU shows as owed/owe until received")
        }

        // MARK: AUTO-MATCH-TAB — an auto-match (origin .intents, ANY method) files under Auto-Matches; a
        // manual ECB Finder offer (origin .ecb) stays in the ECB tab. This split powers the unified section.
        do {
            func req(_ origin: TradeOrigin?, ecb: Double?) -> TradeRequest {
                var r = TradeRequest(id: "x", fromID: "me", fromName: "M", toID: "b", toName: "B", note: "",
                                     takeDayIDs: ecb == nil ? ["d1"] : [], giveDayIDs: ["d2"],
                                     createdAt: Date(timeIntervalSince1970: 1), expiresAt: Date(timeIntervalSince1970: 100),
                                     ecbValue: ecb)
                r.origin = origin
                return r
            }
            check(req(.intents, ecb: nil).isAutoProposed, "AUTO-MATCH-TAB: day-for-day auto-match is auto-proposed")
            check(req(.intents, ecb: 9).isAutoProposed, "AUTO-MATCH-TAB: ECB auto-match folds into Auto-Matches (auto-proposed)")
            check(!req(.ecb, ecb: 9).isAutoProposed, "AUTO-MATCH-TAB: manual ECB Finder offer stays in the ECB tab")
            check(!req(.search, ecb: nil).isAutoProposed, "AUTO-MATCH-TAB: a search proposal is not auto-proposed")
        }

        // MARK: Intents-tab badge count (D2a). activeIntentCount counts non-neutral intents.
        do {
            let store = DayIntentStore.shared
            let d1 = "2099-05-01", d2 = "2099-05-02", d3 = "2099-05-03"
            let base = store.activeIntentCount
            store.setWorkingIntent(.dontWantToWork, forDay: d1)   // trade-away
            store.setOffIntent(.mustBeOff, forDay: d2)            // must-be-off
            store.setWorkingIntent(.neutralOpen, forDay: d3)      // neutral → NOT counted
            check(store.activeIntentCount == base + 2, "activeIntentCount: counts non-neutral only")
            store.clearIntent(forDay: d1); store.clearIntent(forDay: d2); store.clearIntent(forDay: d3)
            check(store.activeIntentCount == base, "activeIntentCount: back to baseline after cleanup")
        }

        // MARK: Channel unread badge (A2/S-SYNC-1). Unread = posts AFTER last-seen, not
        // your own — so it clears on read (old badge showed total count and never cleared).
        func post(_ id: String, author: String, at: Date) -> BroadcastPost {
            BroadcastPost(id: id, authorID: author, authorName: author, text: "hi",
                          createdAt: at, expiresAt: at.addingTimeInterval(86_400))
        }
        let now = Date()
        let t0 = now.addingTimeInterval(-3_000), t1 = now.addingTimeInterval(-2_000),
            t2 = now.addingTimeInterval(-1_000)
        let posts = [post("a", author: "peer", at: t0), post("b", author: "peer", at: t2),
                     post("c", author: "me", at: t2)]
        check(MessagingStore.unreadCount(broadcasts: posts, since: t1, excluding: "me") == 1,
              "unread: only peer posts newer than last-seen count (not mine, not old)")
        check(MessagingStore.unreadCount(broadcasts: posts, since: t2, excluding: "me") == 0,
              "unread: marking seen at latest clears the badge")
        check(MessagingStore.unreadCount(broadcasts: posts, since: .distantPast, excluding: "me") == 2,
              "unread: both peer posts unread before any read")

        // MARK: Character counter logic (F3). near-limit at ≥90%, over past limit.
        let empty = CharLimit.state("", limit: 50)
        check(empty.used == 0 && empty.remaining == 50 && !empty.nearLimit && !empty.over, "charlimit: empty")
        let mid = CharLimit.state(String(repeating: "x", count: 25), limit: 50)
        check(mid.remaining == 25 && !mid.nearLimit, "charlimit: half is not near-limit")
        let near = CharLimit.state(String(repeating: "x", count: 46), limit: 50)
        check(near.nearLimit && !near.over, "charlimit: 46/50 is near-limit, not over")
        let over = CharLimit.state(String(repeating: "x", count: 51), limit: 50)
        check(over.over && over.remaining == -1, "charlimit: 51/50 is over")

        // MARK: Status-by-name lookup (A7/B8). Empty status → nil; set → returned.
        do {
            let s = SettingsManager.shared
            let old = s.statusBroadcast
            s.statusBroadcast = ""
            check(participantStatus(s.username) == nil, "participantStatus: empty → nil (no clutter)")
            s.statusBroadcast = "Taking weekend PMs"
            check(participantStatus(s.username) == "Taking weekend PMs", "participantStatus: returns set status")
            s.statusBroadcast = old
        }

        // MARK: Inbox archive filter (B3). active() excludes archived; delete is separate.
        func req(_ id: String) -> TradeRequest {
            TradeRequest(id: id, fromID: "a", fromName: "A", toID: "b", toName: "B", note: "",
                         takeDayIDs: [], giveDayIDs: [], createdAt: Date(), expiresAt: Date().addingTimeInterval(86_400))
        }
        let reqs = [req("r1"), req("r2"), req("r3")]
        let activeSet = MessagingStore.active(reqs, archived: ["r2"])
        check(activeSet.map(\.id) == ["r1", "r3"], "inbox: active() hides archived, keeps the rest")
        check(MessagingStore.active(reqs, archived: []).count == 3, "inbox: nothing archived → all active")

        // MARK: Reply edit/delete model (B4). edited stamps a date; soft-delete tombstones.
        var rep = BroadcastReply(id: "x", postID: "p", authorID: "me", authorName: "Me",
                                 text: "hello", isPublic: true, createdAt: Date())
        check(rep.editedAt == nil && !rep.isDeleted, "reply: fresh reply not edited/deleted")
        rep.editedAt = Date()
        check(rep.editedAt != nil, "reply: edited stamps editedAt")
        rep.deleted = true
        check(rep.isDeleted, "reply: soft-delete sets isDeleted (renders [Deleted])")

        // MARK: Pinned posts sort to top (B7). Pinned-first, then newest.
        func bp(_ id: String, at: Date, pinned: Bool) -> BroadcastPost {
            BroadcastPost(id: id, authorID: "x", authorName: "X", text: id, createdAt: at,
                          expiresAt: at.addingTimeInterval(86_400), channel: "trades", pinned: pinned)
        }
        let n = Date()
        let sortedPosts = MessagingStore.sortedForChannel([
            bp("old", at: n.addingTimeInterval(-300), pinned: false),
            bp("newest", at: n, pinned: false),
            bp("pinnedOld", at: n.addingTimeInterval(-600), pinned: true),
        ])
        check(sortedPosts.first?.id == "pinnedOld", "pin: a pinned (even old) post sorts to the very top")
        check(sortedPosts.map(\.id) == ["pinnedOld", "newest", "old"], "pin: pinned first, then unpinned NEWEST→oldest (latest at top)")

        // MARK: Brush completeness (F1). EVERY intent must be paintable — this is the
        // exact guard against "I thought the brush already covered it". A new enum case
        // with no brush fails here.
        // Off-day: the actionable intents are brushable; "Open" (neutralOpen) is the cleared state (eraser).
        check(Set(IntentBrushes.off) == Set([.mustBeOff, .wantToWork]),
              "F1: off-day brushes = Blackout + Want-to-Work (Open = cleared state, not a brush)")
        // Working-day: Trade-away + Keep are brushable; "Open" (neutralOpen) is the cleared state (eraser).
        check(Set(IntentBrushes.working) == Set([.dontWantToWork, .mustWork]),
              "F1: working brushes = Trade-away + Keep (Open = cleared state, not a brush)")
        // Every brush has a non-empty human label (no blank pills).
        check(IntentBrushes.working.allSatisfy { !$0.label.isEmpty } && IntentBrushes.off.allSatisfy { !$0.label.isEmpty },
              "F1: every brush has a label")

        // MARK: #4 — a 2-person package is NEVER circular (circular needs ≥3). (U-OBJ: the A5/U4/Q1
        // ranking assertions moved into runRankerTests/runFinalizeTests/runNPenaltyTests with the
        // single score-first ranker; #4b date tiebreak ported to runRankerTests.)
        func pa(_ id: String) -> PackageAssignment { PackageAssignment(workerID: id, name: id, giveDayIDs: ["d1"], takeDayIDs: ["d2"]) }
        let route2 = NWayRoute(participants: ["me", "A"], legs: [], tier: .matchingIntents, score: 0, usesBookends: false)
        let twoCirc = TradePackage(id: "c2", methodology: .circular, assignments: [pa("A")], route: route2)
        check(!twoCirc.isCircular, "#4: a 2-participant package is not circular (a 2-cycle is a 2-way swap)")
        let route3 = NWayRoute(participants: ["me", "A", "B"], legs: [], tier: .matchingIntents, score: 0, usesBookends: false)
        let threeCirc = TradePackage(id: "c3", methodology: .circular, assignments: [pa("A"), pa("B")], route: route3)
        check(threeCirc.isCircular, "#4: a 3-participant circular IS circular")

        // MARK: A6 — mutual-intent (🔥) match end-to-end (discharges ASSUMED_PRESENT #5).
        // I work k1 (give), off k2; peer off k1, works k2 (gives k2). Both openness .all.
        do {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let horizon = cal.date(byAdding: .month, value: 12, to: today)!
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let day1 = cal.date(byAdding: .day, value: 30, to: today)!
            let day2 = cal.date(byAdding: .day, value: 37, to: today)!
            let k1 = f.string(from: day1), k2 = f.string(from: day2)
            func entry(_ w: String, _ day: String, off: Bool) -> RosterEntry {
                RosterEntry(workerID: w, workerName: w, quals: ["D"], day: day,
                            startHour: off ? 0 : 5, desk: off ? "" : "29", isOff: off)
            }
            let myMap = [k1: entry("me", k1, off: false), k2: entry("me", k2, off: true)]
            let pMap  = [k1: entry("p", k1, off: true),   k2: entry("p", k2, off: false)]
            let giveShift = Shift(id: k1, date: day1, startHour: 5, endHour: 14, role: .dispatcher, desk: "29", leaveCode: nil, isOff: false)
            func prof(_ id: String, seeking: Set<String>) -> TradeProfile {
                TradeProfile(workerID: id, displayName: id, openness: "all",
                             blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [], blacklistedRegions: [],
                             seekingDayIDs: seeking, updatedAt: .distantPast)
            }
            var meP = prof("me", seeking: [k1]); let them = prof("p", seeking: [k2])
            let n = TradeMatcher.goldCountPure(myGiveShifts: [giveShift], myMap: myMap, pMap: pMap,
                                               theirProfile: them, myProfile: meP, myQuals: ["D"],
                                               today: today, horizonEnd: horizon, cal: cal)
            check(n == 2, "A6: a true mutual swap surfaces (they take k1 + I take k2) = 2, got \(n)")
            meP.mustBeOffDayIDs = [k2]
            let n2 = TradeMatcher.goldCountPure(myGiveShifts: [giveShift], myMap: myMap, pMap: pMap,
                                                theirProfile: them, myProfile: meP, myQuals: ["D"],
                                                today: today, horizonEnd: horizon, cal: cal)
            check(n2 == 1, "A6: Must-Be-Off on k2 removes the B match → 1, got \(n2)")
        }

        // MARK: B6-QUAL — region qualification gate (grays out regions in Trade Settings).
        check(DeskRules.isQualified(quals: ["D"], forRegion: .domestic), "B6-QUAL: everyone qualifies for Domestic (D)")
        check(!DeskRules.isQualified(quals: ["D"], forRegion: .european), "B6-QUAL: no E → not qualified for European")
        check(DeskRules.isQualified(quals: ["D", "E"], forRegion: .european), "B6-QUAL: holding E → qualified for European")
        check(DeskRules.isQualified(quals: ["D", "L"], forRegion: .latin), "B6-QUAL: holding L → qualified for Latin America")
        check(!DeskRules.isQualified(quals: ["D", "E"], forRegion: .coordinator), "B6-QUAL: no coordinator qual → not qualified")
        check(DeskRules.isQualified(quals: ["D", "R"], forRegion: .coordinator), "B6-QUAL: a coordinator qual (R) → qualified")

        // MARK: OPS-QUAL — master data spells the Ops-Coordinator qual "Ops"; the engine gates on "O".
        // Canonicalizing at parse is what makes C-desk (Ops) shifts tradeable at all (the OC05 bug).
        do {
            // The exact master identity tails from the fixture.
            check(ScheduleParser.canonicalizeQuals(["D", "E", "J", "L", "Ops"]) == ["D", "E", "J", "L", "O"],
                  "OPS-QUAL: 'Ops' → 'O'; D/E/J/L kept")
            check(ScheduleParser.canonicalizeQuals(["A", "D", "I", "MAXPAY", "Ops"]) == ["A", "D", "I", "O"],
                  "OPS-QUAL: pay-status 'MAXPAY' dropped; 'I' (IROPS) + 'Ops'→'O' kept")
            check(ScheduleParser.canonicalizeQuals(["NO", "QUALIFICATIONS"]).isEmpty,
                  "OPS-QUAL: 'NO QUALIFICATIONS' legend → no quals")
            check(ScheduleParser.canonicalizeQuals(["D", "Z", "MAX", "MAXX"]) == ["D"],
                  "OPS-QUAL: retired 'Z' + pay 'MAX'/'MAXX' dropped, 'D' kept")
            // Desk gates: C-desk needs O, I-desk (IROPS) needs I — a canonicalized Ops holder covers C, IROPS covers I.
            check(DeskRules.requiredQual(forDesk: "C6") == "O", "OPS-QUAL: C-desk requires 'O'")
            check(DeskRules.requiredQual(forDesk: "I1") == "I", "OPS-QUAL: I-desk (I1) requires 'I' (IROPS)")
            check(DeskRules.requiredQual(forDesk: "I2") == "I", "OPS-QUAL: I-desk (I2) requires 'I' (IROPS)")
            // A C-desk at 0500 IS a real dispatch shift (this is the OC05 case — timing was never the blocker).
            check(TradeTiming.isDispatchShift(desk: "C6", startHour: 5), "OPS-QUAL: C6 @ 0500 is a tradeable dispatch shift")
            // OJT / TR are training assignments, never coverable dispatch work → never tradeable.
            check(!TradeTiming.isDispatchShift(desk: "OJT", startHour: 5), "OPS-QUAL: OJT is training — not a tradeable shift")
            check(!TradeTiming.isDispatchShift(desk: "TR", startHour: 13), "OPS-QUAL: TR is training — not a tradeable shift")
            let mitch = ScheduleParser.canonicalizeQuals(["D", "E", "J", "L", "Ops"])
            check(DeskRules.qualified(quals: mitch, forDesk: "C6"),
                  "OPS-QUAL: an Ops (→O) dispatcher is now qualified for a C-desk — OC05 is tradeable")
            check(DeskRules.isQualified(quals: ["D", "I"], forRegion: .coordinator),
                  "OPS-QUAL: IROPS ('I') counts as a coordinator qual")
        }

        // MARK: INBOX-CODEC — loopID + origin survive the CloudKit JSON payload round-trip (TRADE-INBOX Stage 1).
        // The whole TradeRequest is JSON-encoded into the `payload` field, so any Codable stored property rides
        // along. This proves the "3-way landed in Misc" bug was NOT a codec drop (it was a legacy nil-origin record).
        do {
            func mkReq(_ id: String) -> TradeRequest {
                TradeRequest(id: id, fromID: "a", fromName: "A", toID: "b", toName: "B", note: "",
                             takeDayIDs: [], giveDayIDs: [], createdAt: Date(timeIntervalSince1970: 1),
                             expiresAt: Date(timeIntervalSince1970: 100))
            }
            var r = mkReq("req1"); r.origin = .search; r.loopID = "loop-xyz"
            if let data = try? JSONEncoder().encode(r),
               let back = try? JSONDecoder().decode(TradeRequest.self, from: data) {
                check(back.origin == .search, "INBOX-CODEC: origin survives the JSON payload round-trip")
                check(back.loopID == "loop-xyz", "INBOX-CODEC: loopID survives the JSON payload round-trip")
                check(back.groupKey == "loop-xyz", "INBOX-CODEC: groupKey == loopID when set")
            } else {
                check(false, "INBOX-CODEC: TradeRequest failed to round-trip through JSON")
            }
            check(mkReq("solo").groupKey == "solo", "INBOX-CODEC: groupKey falls back to id when loopID is nil")

            // MATCH-ALT: §9b alternates survive the JSON payload round-trip, and an old record (no alt keys)
            // decodes to nil — the frozen-init/optional back-compat guarantee for the synced schema.
            var alt = mkReq("alt"); alt.altGiveDayIDs = ["2026-08-05"]; alt.altTakeDayIDs = ["2026-08-12", "2026-08-19"]
            alt.standingOfferID = "offer-42"
            if let data = try? JSONEncoder().encode(alt),
               let back = try? JSONDecoder().decode(TradeRequest.self, from: data) {
                check(back.altGiveDayIDs == ["2026-08-05"], "MATCH-ALT: altGiveDayIDs survives round-trip")
                check(back.altTakeDayIDs == ["2026-08-12", "2026-08-19"], "MATCH-ALT: altTakeDayIDs survives round-trip")
                check(back.standingOfferID == "offer-42", "MATCH-ALT: standingOfferID survives round-trip")
            } else {
                check(false, "MATCH-ALT: TradeRequest with alternates failed to round-trip")
            }
            check(mkReq("noalt").altGiveDayIDs == nil && mkReq("noalt").altTakeDayIDs == nil,
                  "MATCH-ALT: a record without alternates decodes to nil (old-record back-compat)")
        }

        // MARK: INBOX-ORIGIN — inbox tab routing (TRADE-INBOX Stage 2). Intents→0, Search→1, ECB→2,
        // qual-swap/bridge/legacy→3 (Qual Swap). Confirms a circular loop (origin .search) files under Search.
        do {
            let me = "me"
            func req(_ id: String, from: String = "me", to: String = "b", origin: TradeOrigin? = nil,
                     ecbValue: Double? = nil, take: [String] = [], qual: QualSwapLegData? = nil) -> TradeRequest {
                var r = TradeRequest(id: id, fromID: from, fromName: "F", toID: to, toName: "T", note: "",
                                     takeDayIDs: take, giveDayIDs: ["2026-07-15"], createdAt: Date(timeIntervalSince1970: 1),
                                     expiresAt: Date(timeIntervalSince1970: 100), ecbValue: ecbValue, qualSwap: qual)
                r.origin = origin
                return r
            }
            check(TradeInboxTab.index(for: req("i", origin: .intents), myID: me) == 0, "INBOX-ORIGIN: Intents swap → Intents(0)")
            check(TradeInboxTab.index(for: req("s", origin: .search), myID: me) == 1, "INBOX-ORIGIN: Solutions/loop → Search(1)")
            check(TradeInboxTab.index(for: req("e", origin: .ecb, ecbValue: 9), myID: me) == 2, "INBOX-ORIGIN: ECB → ECB(2)")
            check(TradeInboxTab.index(for: req("m", origin: nil), myID: me) == 3, "INBOX-ORIGIN: legacy nil-origin → Qual Swap(3)")
            check(TradeInboxTab.index(for: req("b", from: "x", to: "y", origin: .search), myID: me) == 3, "INBOX-ORIGIN: bridge blast (not core party) → Qual Swap(3)")
        }

        // MARK: INBOX-DEDUPE — a circular loop's N legs collapse to one card; singles untouched (TRADE-INBOX Stage 3).
        do {
            func legReq(_ id: String, loop: String?) -> TradeRequest {
                var r = TradeRequest(id: id, fromID: "me", fromName: "F", toID: "t\(id)", toName: "T", note: "",
                                     takeDayIDs: [], giveDayIDs: ["2026-07-15"], createdAt: Date(timeIntervalSince1970: 1),
                                     expiresAt: Date(timeIntervalSince1970: 100))
                r.loopID = loop
                return r
            }
            let loopLegs = [legReq("r2", loop: "L1"), legReq("r1", loop: "L1")]        // same loop, 2 legs
            let deduped = MessagingStore.dedupeLoops(loopLegs)
            check(deduped.count == 1, "INBOX-DEDUPE: two legs of one loop collapse to a single card")
            check(deduped.first?.id == "r1", "INBOX-DEDUPE: representative is the lowest id (deterministic)")
            let singles = MessagingStore.dedupeLoops([legReq("a", loop: nil), legReq("b", loop: nil)])
            check(singles.count == 2, "INBOX-DEDUPE: plain (nil-loopID) requests are NOT merged")
            let mixed = MessagingStore.dedupeLoops([legReq("x", loop: "L2"), legReq("y", loop: "L2"), legReq("z", loop: nil)])
            check(mixed.count == 2, "INBOX-DEDUPE: one loop + one single → 2 cards")

            // Broadcast fan-out: 3 legs to 3 peers sharing ONE offerID collapse to a single owner card.
            func bcastLeg(_ id: String, offer: String?) -> TradeRequest {
                var r = TradeRequest(id: id, fromID: "me", fromName: "F", toID: "peer\(id)", toName: "T", note: "",
                                     takeDayIDs: ["2026-07-20"], giveDayIDs: ["2026-07-15"],
                                     createdAt: Date(timeIntervalSince1970: 1), expiresAt: Date(timeIntervalSince1970: 100),
                                     offerID: offer)
                return r
            }
            let bcast = MessagingStore.dedupeLoops([bcastLeg("c", offer: "OFR"), bcastLeg("a", offer: "OFR"), bcastLeg("b", offer: "OFR")])
            check(bcast.count == 1, "INBOX-DEDUPE: 3 broadcast legs (shared offerID) collapse to ONE owner card")
            check(bcast.first?.id == "a", "INBOX-DEDUPE: broadcast representative is the lowest id")
            let bcastMixed = MessagingStore.dedupeLoops([bcastLeg("p", offer: "O1"), bcastLeg("q", offer: "O1"), bcastLeg("r", offer: nil)])
            check(bcastMixed.count == 2, "INBOX-DEDUPE: a broadcast + a plain request → 2 cards")
        }

        // MARK: INBOX-LOOPSTATUS — a loop's aggregate status across legs (TRADE-INBOX Stage 4).
        do {
            check(MessagingStore.loopStatus([.pending, .countered]) == .countered, "INBOX-LOOPSTATUS: any counter → Replied")
            check(MessagingStore.loopStatus([.pending, .accepted]) == .pending, "INBOX-LOOPSTATUS: any pending (no counter) → Pending")
            check(MessagingStore.loopStatus([.accepted, .accepted]) == .accepted, "INBOX-LOOPSTATUS: all accepted → Accepted")
            check(MessagingStore.loopStatus([.accepted, .declined]) == .declined, "INBOX-LOOPSTATUS: any decline kills the loop → Declined")
            check(MessagingStore.loopStatus([.countered, .declined]) == .declined, "INBOX-LOOPSTATUS: declined outranks countered")
            check(MessagingStore.loopStatus([]) == .pending, "INBOX-LOOPSTATUS: empty → Pending")
        }

        // MARK: INBOX-UNREAD — a loop shows "new" when someone else responds after last-seen (TRADE-INBOX Stage 6).
        do {
            func resp(_ id: String, who: String, at t: TimeInterval, status: String = "message") -> TradeResponse {
                TradeResponse(id: id, requestID: "r", responderID: who, responderName: who, status: status,
                              note: "hi", createdAt: Date(timeIntervalSince1970: t))
            }
            let rs = [resp("1", who: "them", at: 50), resp("2", who: "me", at: 60)]
            check(MessagingStore.hasNewActivity(responses: rs, since: Date(timeIntervalSince1970: 40), myID: "me"),
                  "INBOX-UNREAD: a newer response from someone else → new")
            check(!MessagingStore.hasNewActivity(responses: rs, since: Date(timeIntervalSince1970: 55), myID: "me"),
                  "INBOX-UNREAD: only my own response after last-seen → NOT new")
            check(!MessagingStore.hasNewActivity(responses: [resp("3", who: "me", at: 90)], since: nil, myID: "me"),
                  "INBOX-UNREAD: my own messages never mark unread")
            check(MessagingStore.hasNewActivity(responses: [resp("4", who: "them", at: 90)], since: nil, myID: "me"),
                  "INBOX-UNREAD: never-seen + other's response → new")
        }

        // MARK: INBOX-THREAD — responses across a loop's legs merge into one chronological thread (TRADE-INBOX Stage 7).
        do {
            func r(_ id: String, req: String, at t: TimeInterval) -> TradeResponse {
                TradeResponse(id: id, requestID: req, responderID: "x", responderName: "X", status: "message",
                              note: "m", createdAt: Date(timeIntervalSince1970: t))
            }
            // Two legs of one loop (legA, legB) + an unrelated leg (legC).
            let all = [r("b", req: "legB", at: 30), r("a", req: "legA", at: 10), r("c", req: "legC", at: 20)]
            let merged = MessagingStore.responsesForLoop(all, legIDs: ["legA", "legB"])
            check(merged.count == 2, "INBOX-THREAD: only this loop's legs are gathered (legC excluded)")
            check(merged.map(\.id) == ["a", "b"], "INBOX-THREAD: merged thread is chronological across legs")
        }

        // MARK: INBOX-COUNTER-PKG — a counter carries a structured package that survives sync (TRADE-INBOX Stage 8).
        do {
            let resp = TradeResponse(id: "c1", requestID: "r", responderID: "them", responderName: "T",
                                     status: TradeRequestStatus.countered.rawValue, note: "Counter",
                                     createdAt: Date(timeIntervalSince1970: 1),
                                     acceptedDayIDs: ["2026-07-15", "2026-07-17"])
            if let d = try? JSONEncoder().encode(resp),
               let back = try? JSONDecoder().decode(TradeResponse.self, from: d) {
                check(back.acceptedDayIDs == ["2026-07-15", "2026-07-17"], "INBOX-COUNTER-PKG: counter package survives the JSON round-trip")
                check(back.statusValue == .countered, "INBOX-COUNTER-PKG: countered status preserved")
            } else {
                check(false, "INBOX-COUNTER-PKG: TradeResponse failed to round-trip")
            }
        }

        // MARK: MATCH-MODEL — TradeKind resolution + AcceptScope/TradeKind survive the profile round-trip;
        // an absent field decodes (back-compat), and an unset AcceptScope is OPEN. (Match Radar Stage 1)
        do {
            // Kind intersection: both=passthrough; equal=self; disjoint=nil.
            check(TradeKind.both.resolve(with: .ecb) == .ecb, "MATCH-MODEL: both ∩ ecb → ecb")
            check(TradeKind.day.resolve(with: .both) == .day, "MATCH-MODEL: day ∩ both → day")
            check(TradeKind.day.resolve(with: .day) == .day, "MATCH-MODEL: day ∩ day → day")
            check(TradeKind.day.resolve(with: .ecb) == nil, "MATCH-MODEL: day ∩ ecb → no match")
            check(AcceptScope().isOpen, "MATCH-MODEL: default AcceptScope is open")
            check(!AcceptScope(shiftTypes: [.pm]).isOpen, "MATCH-MODEL: a shift-type filter is not open")
            var p = TradeProfile(workerID: "w", displayName: "W", openness: "all",
                                 blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                                 blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date(timeIntervalSince1970: 1))
            p.tradeKindByDay = ["2026-08-07": .both]
            p.acceptScopeByDay = ["2026-08-07": AcceptScope(shiftTypes: [.pm], quals: ["L"])]
            if let d = try? JSONEncoder().encode(p), let back = try? JSONDecoder().decode(TradeProfile.self, from: d) {
                check(back.tradeKindByDay?["2026-08-07"] == .both, "MATCH-MODEL: tradeKindByDay round-trips")
                check(back.acceptScopeByDay?["2026-08-07"]?.shiftTypes == [.pm], "MATCH-MODEL: acceptScopeByDay round-trips")
            } else { check(false, "MATCH-MODEL: TradeProfile with radar fields failed to round-trip") }
        }

        // MARK: MATCH-KIND — an ECB-only day is excluded from a day-for-day swap; day/both/absent allowed.
        // (Match Radar Stage 2 — inert until kinds are set, since absent defaults to .both.)
        check(TradeMatcher.allowsDayForDaySwap(nil), "MATCH-KIND: absent kind → allows swap (default .both)")
        check(TradeMatcher.allowsDayForDaySwap(.both), "MATCH-KIND: .both allows swap")
        check(TradeMatcher.allowsDayForDaySwap(.day), "MATCH-KIND: .day allows swap")
        check(!TradeMatcher.allowsDayForDaySwap(.ecb), "MATCH-KIND: .ecb-only excluded from day-for-day swap")

        // MARK: MATCH-KIND-2SIDED — the pills gate matching on BOTH sides. The routed method is resolve()
        // of the giver's kind and the taker's kind: disjoint (Day vs ECB) → NO match; else the intersection
        // routes to the swap list (day/both) and/or the ECB list (ecb/both). Mirrors twoWayExploreCore.
        func route(_ giver: TradeKind, _ taker: TradeKind) -> (swap: Bool, ecb: Bool) {
            guard let r = giver.resolve(with: taker) else { return (false, false) }
            return (r != .ecb, r != .day)
        }
        check(route(.day, .ecb) == (false, false), "MATCH-KIND-2SIDED: giver Day + taker ECB → NOT a match")
        check(route(.ecb, .day) == (false, false), "MATCH-KIND-2SIDED: giver ECB + taker Day → NOT a match")
        check(route(.day, .both) == (true, false), "MATCH-KIND-2SIDED: Day + Both → day-for-day only")
        check(route(.ecb, .both) == (false, true), "MATCH-KIND-2SIDED: ECB + Both → ECB only")
        check(route(.both, .both) == (true, true), "MATCH-KIND-2SIDED: Both + Both → either method")
        check(route(.day, .day) == (true, false), "MATCH-KIND-2SIDED: Day + Day → day-for-day")

        // MARK: MATCH-SPLIT (v4) — classifyGives buckets my give days into AUTO (4-mutual / ECB-only) vs
        // Suggested (3-/2-mutual). "Does the app need me to pick days?" No → AUTO; yes → Suggested.
        do {
            typealias DP = TradeRouter.DayPair
            let s1 = TradeRouter.classifyGives(["X"], takes: ["Y"], myWantToWork: ["Y"], kindOfGive: ["X": .both])
            check(s1.autoSwaps == [DP(give: "X", take: "Y")] && s1.suggested.isEmpty && s1.autoECB.isEmpty,
                  "MATCH-SPLIT: 4-mutual (return I also want) → AUTO swap")
            let s2 = TradeRouter.classifyGives(["X"], takes: ["Y"], myWantToWork: [], kindOfGive: ["X": .both])
            check(s2.suggested == ["X"] && s2.autoSwaps.isEmpty, "MATCH-SPLIT: return I didn't mark → Suggested (manual)")
            let s3 = TradeRouter.classifyGives(["X"], takes: [], myWantToWork: [], kindOfGive: ["X": .ecb])
            check(s3.autoECB == ["X"] && s3.suggested.isEmpty, "MATCH-SPLIT: ECB-only give → AUTO ECB")
            let s4 = TradeRouter.classifyGives(["X"], takes: [], myWantToWork: [], kindOfGive: ["X": .day])
            check(s4.isEmpty, "MATCH-SPLIT: day-only give, no return → no trade (dropped)")
            let s5 = TradeRouter.classifyGives(["X"], takes: [], myWantToWork: [], kindOfGive: ["X": .both])
            check(s5.suggested == ["X"], "MATCH-SPLIT: Both give, no return → Suggested (manual ECB)")
            let s6 = TradeRouter.classifyGives(["A", "B"], takes: ["Y"], myWantToWork: ["Y"], kindOfGive: ["A": .both, "B": .ecb])
            check(s6.autoSwaps.count == 1 && s6.autoECB == ["B"] && s6.suggested.isEmpty,
                  "MATCH-SPLIT: each give lands in exactly ONE bucket (A→swap, B→ECB)")
        }

        // MARK: MATCH-STAR / MATCH-DETERMINISM — radar per-peer contribution (Match Radar Stage 3).
        do {
            func leg(_ d: String, wanted: Bool) -> TwoWayLeg {
                TwoWayLeg(dayID: d, date: Date(timeIntervalSince1970: 1), desk: "30", startHour: 5,
                          bookend: false, wanted: wanted)
            }
            let plan = TwoWayPlan(workerID: "p", name: "P",
                                  iGive: [leg("g1", wanted: true), leg("g2", wanted: false)],
                                  iTake: [leg("t1", wanted: true), leg("t2", wanted: false)])
            let c = TradeRouter.radarPeerContribution(plan: plan)
            check(c.pickupDays == ["t1"], "MATCH-STAR: peer's MARKED day I can cover → pickup (star); unmarked excluded")
            check(c.mutualGive == ["g1"], "MATCH-STAR: mutual give = my marked give-days they'd take")
            check(c.mutualTake == ["t1"], "MATCH-STAR: mutual take = peer's marked days I'd take")
            let c2 = TradeRouter.radarPeerContribution(plan: plan)
            check(c.pickupDays == c2.pickupDays && c.mutualGive == c2.mutualGive,
                  "MATCH-DETERMINISM: same plan → identical contribution")
            // No marks either side → no star, no mutual.
            let empty = TradeRouter.radarPeerContribution(plan: TwoWayPlan(workerID: "p", name: "P",
                                                                           iGive: [leg("x", wanted: false)],
                                                                           iTake: [leg("y", wanted: false)]))
            check(empty.pickupDays.isEmpty && empty.mutualGive.isEmpty, "MATCH-STAR: unmarked plan → no star / no mutual")
        }

        // MARK: MATCH-DAYLIST — a day's pickup rows sort by tier (intent→bookend→split), then name. (Stage 4)
        do {
            func row(_ id: String, tier: Int) -> TradeRouter.DayTradeRow {
                TradeRouter.DayTradeRow(peerID: id, peerName: id, desk: "30", startHour: 5, kind: .both, note: nil, tier: tier)
            }
            let sorted = TradeRouter.sortDayRows([row("split", tier: 2), row("intent", tier: 0), row("book", tier: 1)])
            check(sorted.map(\.peerID) == ["intent", "book", "split"], "MATCH-DAYLIST: tier order intent→bookend→split")
            let tie = TradeRouter.sortDayRows([row("Zed", tier: 1), row("Abe", tier: 1)])
            check(tie.map(\.peerID) == ["Abe", "Zed"], "MATCH-DAYLIST: same tier → name tiebreak")
        }

        // MARK: MATCH-SEEN — "newly gained a pickup" = new pickups minus what was already seen/known. (Stage 5)
        do {
            let gained = MatchStore.newlyGainedDays(old: ["2026-08-01", "2026-08-02"], new: ["2026-08-02", "2026-08-09"])
            check(gained == ["2026-08-09"], "MATCH-SEEN: only the not-yet-seen pickup day is 'newly gained'")
            check(MatchStore.newlyGainedDays(old: ["2026-08-09"], new: ["2026-08-09"]).isEmpty,
                  "MATCH-SEEN: an already-seen pickup does not re-notify")
        }

        // MARK: MATCH-SCOPE — per-give-day accept-scope prunes returns you wouldn't take. (Stage 8)
        do {
            var amOnly = AcceptScope(); amOnly.shiftTypes = [.am]
            check(amOnly.accepts(shiftType: .am, desk: "30", dayID: "2026-08-01"), "MATCH-SCOPE: AM scope accepts AM")
            check(!amOnly.accepts(shiftType: .pm, desk: "30", dayID: "2026-08-01"), "MATCH-SCOPE: AM scope rejects PM")
            check(AcceptScope().accepts(shiftType: .pm, desk: "1", dayID: "x"), "MATCH-SCOPE: open scope accepts anything")
            let scopes = ["2026-08-05": amOnly]
            check(!AcceptScope.acceptsUnderAny(scopes, giveDayIDs: ["2026-08-05"], shiftType: .pm, desk: "30", dayID: "d"),
                  "MATCH-SCOPE: sole scoped give rejects a PM return")
            check(AcceptScope.acceptsUnderAny(scopes, giveDayIDs: ["2026-08-05"], shiftType: .am, desk: "30", dayID: "d"),
                  "MATCH-SCOPE: sole scoped give accepts an AM return")
            check(AcceptScope.acceptsUnderAny(scopes, giveDayIDs: ["2026-08-05", "2026-08-06"], shiftType: .pm, desk: "30", dayID: "d"),
                  "MATCH-SCOPE: an unscoped give day is open → no prune")
            check(AcceptScope.acceptsUnderAny(nil, giveDayIDs: ["x"], shiftType: .pm, desk: "1", dayID: "d"),
                  "MATCH-SCOPE: no scopes → inert (accepts everything)")
        }

        // MARK: MATCH-STANDING — a standing offer is met only when a peer takes a give AND offers a get. (Build 6)
        do {
            let offer = StandingOffer(id: "o1", giveDayIDs: ["2026-08-01"], getDayIDs: ["2026-08-10"],
                                      kind: .both, note: "", active: true, createdAt: Date(timeIntervalSince1970: 1))
            let hit = TradeRouter.standingMatch(offer: offer, peerID: "p", peerName: "P",
                                                peerWouldTake: ["2026-08-01"], peerOffersToMe: ["2026-08-10"])
            check(hit?.giveDayIDs == ["2026-08-01"] && hit?.getDayIDs == ["2026-08-10"],
                  "MATCH-STANDING: both sides satisfied → a match")
            check(TradeRouter.standingMatch(offer: offer, peerID: "p", peerName: "P",
                                            peerWouldTake: ["2026-08-01"], peerOffersToMe: []) == nil,
                  "MATCH-STANDING: peer takes my give but offers no get → no match")
            check(TradeRouter.standingMatch(offer: offer, peerID: "p", peerName: "P",
                                            peerWouldTake: [], peerOffersToMe: ["2026-08-10"]) == nil,
                  "MATCH-STANDING: peer offers a get but won't take my give → no match")
            var paused = offer; paused.active = false
            check(TradeRouter.standingMatch(offer: paused, peerID: "p", peerName: "P",
                                            peerWouldTake: ["2026-08-01"], peerOffersToMe: ["2026-08-10"]) == nil,
                  "MATCH-STANDING: a paused offer never matches")

            // MATCH-BROADCAST: fan-out ranks by acceptance prior (desc), ties by peerID, caps at N.
            func sm(_ p: String) -> StandingMatch { StandingMatch(offerID: "o", peerID: p, peerName: p, giveDayIDs: ["g"], getDayIDs: ["t"]) }
            let ranked = TradeRouter.rankStandingMatches([sm("low"), sm("high"), sm("mid")],
                                                         priors: ["high": 2.0, "mid": 1.0, "low": 0.0], cap: 3)
            check(ranked.map(\.peerID) == ["high", "mid", "low"], "MATCH-BROADCAST: ranked by acceptance prior desc")
            check(TradeRouter.rankStandingMatches([sm("a"), sm("b"), sm("c"), sm("d")], priors: [:], cap: 3).count == 3,
                  "MATCH-BROADCAST: capped at 3")
            // First-accept-wins aggregate for the owner's one broadcast card: one accept wins; else still-live.
            check(MessagingStore.broadcastStatus([.pending, .accepted, .cancelled]) == .accepted,
                  "MATCH-BROADCAST: any accepted leg → card shows accepted (first wins)")
            check(MessagingStore.broadcastStatus([.pending, .declined]) == .pending,
                  "MATCH-BROADCAST: still-live beats a declined leg")
            check(MessagingStore.broadcastStatus([.declined, .cancelled]) == .declined,
                  "MATCH-BROADCAST: all settled → declined over cancelled")
            // The concurrent-scan chunker must cover every peer exactly once, in order (no loss/dup).
            check(TradeRouter.chunk(Array(1...10)).flatMap { $0 } == Array(1...10),
                  "MATCH-CHUNK: chunks cover all items in order")
            check(TradeRouter.chunk([Int]()).isEmpty, "MATCH-CHUNK: empty input → no chunks")
        }

        // MARK: TRADE-DEDUPE — the duplicate key is direction-agnostic (A→B == B→A for the same days).
        do {
            let ab = MessagingStore.tradeKey("A", "B", dayIDs: ["2026-08-01", "2026-08-10"])
            let ba = MessagingStore.tradeKey("B", "A", dayIDs: ["2026-08-10", "2026-08-01"])
            check(ab == ba, "TRADE-DEDUPE: A→B and B→A over the same days share one key (reciprocal caught)")
            check(ab != MessagingStore.tradeKey("A", "C", dayIDs: ["2026-08-01", "2026-08-10"]),
                  "TRADE-DEDUPE: a different counterparty is a different key")
            check(ab != MessagingStore.tradeKey("A", "B", dayIDs: ["2026-08-02"]),
                  "TRADE-DEDUPE: different days are a different key")
        }

        // MARK: CARRYOVER-SNAPSHOT — carryover-vacation days survive the intent snapshot round-trip;
        // an older snapshot without the key still decodes (back-compat). (#4 Stage 1)
        do {
            let snap = DayIntentStore.IntentSnapshot(working: [:], off: [:], topologies: [:], notes: [:],
                                                     availability: [:], wanted: nil, manualOff: [],
                                                     carryover: ["2026-08-07"])
            if let data = try? JSONEncoder().encode(snap),
               let back = try? JSONDecoder().decode(DayIntentStore.IntentSnapshot.self, from: data) {
                check(back.carryover == ["2026-08-07"], "CARRYOVER-SNAPSHOT: carryover set round-trips")
            } else { check(false, "CARRYOVER-SNAPSHOT: snapshot failed to round-trip") }
            // Older JSON with no `carryover` key → decodes with nil (back-compat).
            let legacy = "{\"working\":{},\"off\":{},\"topologies\":{},\"notes\":{},\"availability\":{},\"manualOff\":[]}"
            let decoded = try? JSONDecoder().decode(DayIntentStore.IntentSnapshot.self, from: Data(legacy.utf8))
            check(decoded != nil && decoded?.carryover == nil, "CARRYOVER-SNAPSHOT: legacy snapshot (no key) still decodes")
        }

        // MARK: CARRYOVER-PROFILE — the published field round-trips on TradeProfile; a profile without it decodes. (#4 Stage 2)
        do {
            var p = TradeProfile(workerID: "w", displayName: "W", openness: "all",
                                 blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                                 blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date(timeIntervalSince1970: 1))
            p.carryoverVacationDayIDs = ["2026-08-07"]
            if let data = try? JSONEncoder().encode(p),
               let back = try? JSONDecoder().decode(TradeProfile.self, from: data) {
                check(back.carryoverVacationDayIDs == ["2026-08-07"], "CARRYOVER-PROFILE: carryoverVacationDayIDs round-trips")
            } else { check(false, "CARRYOVER-PROFILE: TradeProfile failed to round-trip") }
        }

        // MARK: CARRYOVER-PEER — a peer on carryover vacation is excluded as a coverer that day. (#4 Stage 4)
        do {
            var prof = TradeProfile(workerID: "p", displayName: "P", openness: "all",
                                    blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                                    blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date(timeIntervalSince1970: 1))
            check(!prof.isOnCarryoverVacation("2026-08-07"), "CARRYOVER-PEER: not on carryover before flag")
            prof.carryoverVacationDayIDs = ["2026-08-07"]
            check(prof.isOnCarryoverVacation("2026-08-07"), "CARRYOVER-PEER: flagged day reads as carryover vacation")
            check(!prof.isOnCarryoverVacation("2026-08-08"), "CARRYOVER-PEER: other days unaffected")
            // The canCover guard uses exactly this predicate (a carryover day → .no), so a peer on carryover
            // vacation is never offered a pickup that day.
        }

        // MARK: B6-BLACKOUT — a blacked-out weekday blocks a pickup (arbitrary days, not just weekends).
        do {
            let prof = TradeProfile(workerID: "z", displayName: "Z", openness: "all",
                                    blacklistedWeekdays: [4], blacklistedDesks: [], blacklistedShiftTypes: [],
                                    blacklistedRegions: [], seekingDayIDs: [], updatedAt: .distantPast)
            check(!prof.passesBlacklist(weekday: 4, desk: "29", shiftType: "AM", region: "Domestic"),
                  "B6-BLACKOUT: a blacked-out weekday (Wed=4) is rejected by the matcher")
            check(prof.passesBlacklist(weekday: 3, desk: "29", shiftType: "AM", region: "Domestic"),
                  "B6-BLACKOUT: a non-blacked-out weekday passes")
            // Display parity: the calendar tints a WORKING shift only via desk/type/region — the weekday
            // dimension is opt-in via the `weekdays` set, so HomeCalendar passes [] for working days (a
            // blacked-out weekday only bites off-day pickups). With weekdays:[] a clean working day → no tint.
            check(!Blackout.isBlacklisted(desk: "29", startHour: 5, weekday: 4,
                                          desks: [], shiftTypes: [], regions: [], weekdays: []),
                  "B6-BLACKOUT: working-day tint ignores the weekday dimension (weekdays: [])")
            check(Blackout.isBlacklisted(desk: "29", startHour: 5, weekday: 4,
                                         desks: [], shiftTypes: [], regions: [], weekdays: [4]),
                  "B6-BLACKOUT: off-day path (weekdays passed) still flags a blacked-out weekday")
        }

        // MARK: B6-ECB — ECB accounting pure core (signed amount, available vs projected, cap, IOU, decode).
        do {
            let d = Date(timeIntervalSince1970: 1_700_000_000)
            func personal(_ amt: Double, _ cat: ECBCategory, cleared: Bool) -> ECBEntry {
                ECBEntry(date: d, amount: amt, category: cat, cleared: cleared)
            }
            func trade(_ mag: Double, payer: String, payee: String, _ state: ECBLineState, cleared: Bool) -> ECBEntry {
                ECBEntry(date: d, amount: mag, category: .trade, cleared: cleared, payerID: payer, payeeID: payee, state: state)
            }
            // signedAmount: personal passthrough; shared → payee +, payer −.
            check(ECBAccounting.signedAmount(for: "me", personal(9, .overtime, cleared: true)) == 9, "B6-ECB: personal line passes its signed amount through")
            check(ECBAccounting.signedAmount(for: "me", trade(5, payer: "you", payee: "me", .confirmed, cleared: true)) == 5, "B6-ECB: shared line credits the payee (+)")
            check(ECBAccounting.signedAmount(for: "me", trade(5, payer: "me", payee: "you", .confirmed, cleared: true)) == -5, "B6-ECB: shared line debits the payer (−)")
            // available = agreed + CLEARED only; projected = agreed (cleared or scheduled); pending-confirm excluded from both.
            let ledger = [personal(9, .overtime, cleared: true),                            // +9 available
                          personal(-4, .withdrawal, cleared: false),                        // −4 scheduled only
                          ECBEntry(date: d, amount: 2.5, category: .adjustment, cleared: true), // +2.5 available
                          trade(5, payer: "you", payee: "me", .confirmed, cleared: true),    // +5 available
                          trade(3, payer: "you", payee: "me", .confirmed, cleared: false),   // +3 scheduled only
                          trade(7, payer: "you", payee: "me", .pendingIncoming, cleared: false)] // awaiting confirm → neither
            check(ECBAccounting.available(ledger, viewerID: "me") == 16.5, "B6-ECB: available = 9 + 2.5 + 5 (cleared only) = 16.5")
            check(ECBAccounting.projected(ledger, viewerID: "me") == 15.5, "B6-ECB: projected = 16.5 − 4 + 3 (agreed incl. scheduled) = 15.5")
            check(ECBAccounting.pendingConfirmations(ledger, myID: "me").count == 1, "B6-ECB: one shared line awaits my confirmation")
            // 144 cap: can't CLEAR a positive delta that pushes available over 144.
            check(ECBAccounting.wouldExceedCap(available: 140, clearing: 5), "B6-ECB: clearing +5 at 140 exceeds the 144 cap")
            check(!ECBAccounting.wouldExceedCap(available: 140, clearing: 4), "B6-ECB: clearing +4 at 140 is fine (=144)")
            check(!ECBAccounting.wouldExceedCap(available: 200, clearing: -10), "B6-ECB: a withdrawal never trips the cap")
            // IOU capacity = available + net scheduled (you can only promise what you have or will have).
            let capLedger = [personal(10, .holidayPay, cleared: false),   // scheduled deposit +10
                             personal(6, .overtime, cleared: true)]       // cleared +6
            check(ECBAccounting.payableCapacity(capLedger, myID: "me") == 16, "B6-ECB: payable = cleared 6 + scheduled 10 = 16")
            // owe / owed = outstanding (agreed, uncleared) shared lines; cleared ones drop off.
            let iouLedger = [trade(4, payer: "me", payee: "you", .confirmed, cleared: false),  // I owe 4
                             trade(2, payer: "you", payee: "me", .confirmed, cleared: false),  // owed 2 to me
                             trade(9, payer: "me", payee: "you", .confirmed, cleared: true)]    // cleared → neither
            check(ECBAccounting.owe(iouLedger, myID: "me") == 4, "B6-ECB: owe = agreed uncleared I pay = 4")
            check(ECBAccounting.owed(iouLedger, myID: "me") == 2, "B6-ECB: owed = agreed uncleared others pay me = 2")
            // Setting balance produces the correct delta.
            check(ECBAccounting.adjustmentAmount(current: 16.5, target: 20) == 3.5, "B6-ECB: set-balance delta 16.5→20 = +3.5")
            // INV-3: a minimal (legacy-shaped) entry decodes with defaults (incl. cleared=false).
            let legacyJSON = #"{"id":"x","date":0,"amount":6,"category":"overtime"}"#.data(using: .utf8)!
            if let back = try? JSONDecoder().decode(ECBEntry.self, from: legacyJSON) {
                check(back.state == .confirmed && back.payerID == nil && back.memo == "" && back.cleared == false,
                      "B6-ECB: legacy entry decodes with defaults (INV-3)")
            } else { check(false, "B6-ECB: legacy entry failed to decode") }
        }

        // MARK: B6-INTENTS — the robot/active-account gate applies ONLY in Mutual mode.
        // Regression: gating BOTH modes on isActiveAccount zeroed the feed when no peer had claimed an
        // account. All (mutualOnly=false) must include an unclaimed peer; Mutual (true) must exclude it.
        check(TradeRouter.peerEligibleForIntents(isActiveAccount: false, mutualOnly: false),
              "B6-INTENTS: unclaimed peer IS eligible in All mode")
        check(!TradeRouter.peerEligibleForIntents(isActiveAccount: false, mutualOnly: true),
              "B6-INTENTS: unclaimed peer is EXCLUDED in Mutual mode")
        check(TradeRouter.peerEligibleForIntents(isActiveAccount: true, mutualOnly: true),
              "B6-INTENTS: a claimed account is eligible in Mutual mode")

        // MARK: D1 — bookends is the DEFAULT/fallback openness (discharges #3). Verified by
        // code that onboarding never writes tradeOpenness and load() defaults to "bookends";
        // here we lock the resolution fallback.
        check((TradeOpenness(rawValue: "garbage") ?? .bookends) == .bookends, "D1: unknown openness → bookends")
        let freshProf = TradeProfile(workerID: "x", displayName: "x", openness: "",
                                     blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [], blacklistedRegions: [],
                                     seekingDayIDs: [], updatedAt: .distantPast)
        check(freshProf.opennessLevel == .bookends, "D1: empty/new openness resolves to .bookends")

        // MARK: B4 chat-message edit/delete model (discharges ASSUMED_PRESENT #9).
        var msg = TradeResponse(id: "m1", requestID: "r", responderID: "me", responderName: "Me",
                                status: TradeRequestStatus.message.rawValue, note: "hi", createdAt: Date())
        check(msg.editedAt == nil && !msg.isDeleted, "chat: fresh message not edited/deleted")
        msg.editedAt = Date()
        check(msg.editedAt != nil, "chat: edit stamps editedAt")
        msg.deleted = true
        check(msg.isDeleted, "chat: soft-delete sets isDeleted (renders [Deleted])")

        // MARK: #10 — vacation is a SOFT exclusion, not a hard gate (your rule: "still
        // allowed to trade into it"). A vacation day is an OFF day flagged for display;
        // there is NO separate "unavailable for trades" state, so peers aren't hard-blocked.
        let vacOff = Shift(id: "2099-06-01", date: Date(timeIntervalSince1970: 4_086_000_000),
                           startHour: 0, endHour: 0, role: .off, desk: "", leaveCode: "V", isOff: true)
        check(vacOff.isOff && vacOff.isVacation, "#10: vacation = an OFF day flagged vacation (no hard unavailable state)")

        // MARK: #11 — per-intent counts drive the color-coded tier bubbles (D2a). Sentinel days.
        do {
            let s = DayIntentStore.shared
            let a = "2099-07-01", b = "2099-07-02", c = "2099-07-03"
            let baseW = s.workingIntentCounts[.dontWantToWork] ?? 0
            let baseO = s.offIntentCounts[.mustBeOff] ?? 0
            s.setWorkingIntent(.dontWantToWork, forDay: a)
            s.setWorkingIntent(.dontWantToWork, forDay: b)
            s.setOffIntent(.mustBeOff, forDay: c)
            check((s.workingIntentCounts[.dontWantToWork] ?? 0) == baseW + 2, "#11: trade-away tally counts both days")
            check((s.offIntentCounts[.mustBeOff] ?? 0) == baseO + 1, "#11: must-be-off tally counts its day")
            s.clearIntent(forDay: a); s.clearIntent(forDay: b); s.clearIntent(forDay: c)
        }

        // MARK: A3 — last-write-wins merge for private-notes sync (#6). Pure core; the
        // CloudKit round-trip itself needs a 2-device device check (in USER_TEST_LIST).
        let older = Date(timeIntervalSince1970: 1_000), newer = Date(timeIntervalSince1970: 2_000)
        check(LWW.pick(local: "L", localAt: older, remote: "R", remoteAt: newer) == "R", "A3: newer remote wins")
        check(LWW.pick(local: "L", localAt: newer, remote: "R", remoteAt: older) == "L", "A3: newer local wins")
        check(LWW.pick(local: "L", localAt: newer, remote: "R", remoteAt: newer) == "L", "A3: tie keeps local")

        // MARK: S-ENG-10 — Want-to-Work OVERRIDES the bookend requirement (one-sided),
        // but NOT blacklist or Must-Be-Off.
        let d = "2026-09-10"
        func wp(blacklistDesk: Bool = false, wantToWork: Bool = false, mustBeOff: Bool = false) -> TradeProfile {
            var p = TradeProfile(workerID: "x", displayName: "x", openness: "bookends",
                                 blacklistedWeekdays: [], blacklistedDesks: blacklistDesk ? ["29"] : [],
                                 blacklistedShiftTypes: [], blacklistedRegions: [],
                                 seekingDayIDs: [], updatedAt: .distantPast)
            if wantToWork { p.wantToWorkDayIDs = [d] }
            if mustBeOff { p.mustBeOffDayIDs = [d] }
            return p
        }
        func take(_ p: TradeProfile, bookend: Bool) -> Bool {
            p.wouldPickUp(onDay: d, weekday: 5, desk: "29", shiftType: "AM", region: "Domestic", isBookend: bookend)
        }
        check(take(wp(), bookend: false) == false, "S-ENG-10: under bookends, a non-bookend day is rejected by default")
        check(take(wp(wantToWork: true), bookend: false) == true, "S-ENG-10: Want-to-Work makes a non-bookend day eligible")
        check(take(wp(blacklistDesk: true, wantToWork: true), bookend: false) == false, "S-ENG-10: Want-to-Work does NOT override the blacklist")
        check(take(wp(wantToWork: true, mustBeOff: true), bookend: true) == false, "S-ENG-10: Must-Be-Off still wins over Want-to-Work")

        // MARK: S-VALID — a trade day is invalid when a participant no longer works it.
        func re(_ w: String, _ day: String, off: Bool) -> RosterEntry {
            RosterEntry(workerID: w, workerName: w, quals: ["D"], day: day, startHour: off ? 0 : 5, desk: off ? "" : "29", isOff: off)
        }
        // Sender gives g1 (still works it) + g2 (now OFF → stale). Taker takes t1 (still works).
        let fromMap = ["g1": re("f", "g1", off: false), "g2": re("f", "g2", off: true)]
        let toMap   = ["t1": re("t", "t1", off: false)]
        let stale = TradeMatcher.staleDaysPure(giveDayIDs: ["g1", "g2"], takeDayIDs: ["t1"], fromMap: fromMap, toMap: toMap)
        check(stale == ["g2"], "S-VALID: only the no-longer-worked give day is stale/invalid")
        let noStale = TradeMatcher.staleDaysPure(giveDayIDs: ["g1"], takeDayIDs: ["t1"], fromMap: fromMap, toMap: toMap)
        check(noStale.isEmpty, "S-VALID: a fully-worked trade is valid (no stale days)")
        let staleGone = TradeMatcher.staleDaysPure(giveDayIDs: ["gX"], takeDayIDs: [], fromMap: fromMap, toMap: toMap)
        check(staleGone == ["gX"], "S-VALID: a day no longer in the schedule at all is stale")

        // MARK: H1 — Home metrics helpers (pure).
        check(Metrics.successPercent(accepted: 3, proposed: 4) == 75, "H1: success % = accepted/proposed")
        check(Metrics.successPercent(accepted: 0, proposed: 0) == 0, "H1: no proposals → 0% (no divide-by-zero)")
        let nowD = Date()
        let calM = Calendar.current
        let thisMonth = nowD
        let lastYear = calM.date(byAdding: .year, value: -1, to: nowD)!
        let events = [thisMonth, thisMonth, lastYear]
        check(Metrics.searchCount(events, period: .allTime, now: nowD) == 3, "H1: all-time counts every search")
        check(Metrics.searchCount(events, period: .month, now: nowD) == 2, "H1: month counts only this month")
        check(Metrics.searchCount(events, period: .year, now: nowD) == 2, "H1: year excludes last year's search")

        // (A1 "others' intents" layer removed per #2 — was unrequested UI; tests dropped with it.)

        // MARK: C4 — people search + pin-to-top (pure).
        let people = [("1", "Alice"), ("2", "Bob"), ("3", "Albert")]
        let byName = PeopleFilter.arrange(people, query: "al", pinned: [], id: { $0.0 }, name: { $0.1 })
        check(byName.map(\.1) == ["Alice", "Albert"], "C4: name filter is case-insensitive substring")
        let pinned = PeopleFilter.arrange(people, query: "", pinned: ["2"], id: { $0.0 }, name: { $0.1 })
        check(pinned.map(\.1) == ["Bob", "Alice", "Albert"], "C4: pinned person sorts to top, rest keep order")
        let noMatch = PeopleFilter.arrange(people, query: "zzz", pinned: [], id: { $0.0 }, name: { $0.1 })
        check(noMatch.isEmpty, "C4: no name match → empty")

        // MARK: B6/#8a — ONE reaction per user (setSingle): replace on a different emoji, clear on same.
        var rx: [Reaction] = []
        rx = Reaction.setSingle(rx, emoji: "👍", userID: "me", userName: "Me")
        check(rx.count == 1, "8a: first reaction added")
        rx = Reaction.setSingle(rx, emoji: "❤️", userID: "me", userName: "Me")
        check(rx.count == 1 && rx.first?.emoji == "❤️", "8a: a different emoji REPLACES (still 1 per user)")
        rx = Reaction.setSingle(rx, emoji: "❤️", userID: "me", userName: "Me")
        check(rx.isEmpty, "8a: tapping the same emoji again clears it")
        rx = Reaction.setSingle(rx, emoji: "👍", userID: "me", userName: "Me")
        rx = Reaction.setSingle(rx, emoji: "🔥", userID: "you", userName: "You")
        check(rx.count == 2, "8a: different users keep their own single reactions")
        let counts = Reaction.counts(rx)
        check(counts.contains(where: { $0.emoji == "👍" && $0.count == 1 }) && counts.contains(where: { $0.emoji == "🔥" && $0.count == 1 }),
              "8a: counts group by emoji")

        // MARK: Q4 — qual-swap acceptance via preference VALUES (higher = better, 0 = blacklist, unset = open/max).
        // Desk regions: 1–47 = Domestic(D), 48–58 = Euro(E), 60–63/72–83 = Latin(L), 64–68 = Pacific(P).
        // Someone currently on Domestic desk 10 (qual D). Values: E best, D middle, P worst.
        let prefHi: [String: Int] = ["E": 3, "D": 2, "P": 1]
        check(DeskRules.acceptsQualSwap(into: "50", fromCurrentDesk: "10", values: prefHi),
              "Q4: into a higher-valued qual (E>D) is accepted")
        check(!DeskRules.acceptsQualSwap(into: "64", fromCurrentDesk: "10", values: prefHi),
              "Q4: into a lower-valued qual (P<D) is rejected")
        check(DeskRules.acceptsQualSwap(into: "11", fromCurrentDesk: "10", values: prefHi),
              "Q4: equal qual is accepted")
        // value 0 = blacklisted, rejected even though the move would otherwise compare.
        check(!DeskRules.acceptsQualSwap(into: "50", fromCurrentDesk: "10", values: ["D": 2, "E": 0]),
              "Q4: a qual set to 0 is blacklisted → rejected")
        // Unset qual = highest preference → accepted from a ranked current desk.
        check(DeskRules.acceptsQualSwap(into: "50", fromCurrentDesk: "10", values: ["D": 2]),
              "Q4: an unset qual is treated as highest preference → accepted")
        // nil map = fully open → any non-blacklisted move accepted.
        check(DeskRules.acceptsQualSwap(into: "64", fromCurrentDesk: "10", values: nil),
              "Q4: a nil value map is fully open → accepted")
        // Desk-number blacklist hard-blocks even when the qual value would accept.
        check(!DeskRules.acceptsQualSwap(into: "50", fromCurrentDesk: "10", values: prefHi, blacklistDesks: ["50"]),
              "Q4: a blacklisted desk number is rejected regardless of qual value")
        // Profile convenience mirrors the pure rule.
        var qp = TradeProfile(workerID: "q", displayName: "Q", openness: "all",
                              blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                              blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date())
        qp.qualValues = prefHi
        check(qp.acceptsQualSwap(into: "50", fromCurrentDesk: "10"), "Q4: profile accepts E over D")
        check(!qp.acceptsQualSwap(into: "64", fromCurrentDesk: "10"), "Q4: profile rejects P below D")
        qp.qualSwapBlacklistDesks = ["50"]
        check(!qp.acceptsQualSwap(into: "50", fromCurrentDesk: "10"), "Q4: profile rejects blacklisted desk number")

        // MARK: S-ENG-4 — qual-swap BRIDGE discovery (3-party unblock, pure).
        // A gives Euro desk 50 (needs E). Off taker B is willing but holds only [D,L] (no E).
        // Find a bridge C working the same day at start hour 5 who HOLDS E (can take 50) and is
        // on a desk whose qual B holds (so B can take C's desk), and who ACCEPTS moving onto 50.
        func bridgeProf(_ id: String, _ values: [String: Int]) -> TradeProfile {
            var p = TradeProfile(workerID: id, displayName: id, openness: "all",
                                 blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                                 blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date())
            p.qualValues = values; return p
        }
        let takerQuals = ["D", "L"]
        // C1: Domestic desk 10 (D), holds [D,E], start 5, values E>D → accepts moving to 50. VALID.
        let c1 = QualSwapShift(workerID: "C1", name: "C1", desk: "10", startHour: 5, quals: ["D", "E"])
        // C2: same as C1 but start hour 13 → excluded (different start time).
        let c2 = QualSwapShift(workerID: "C2", name: "C2", desk: "10", startHour: 13, quals: ["D", "E"])
        // C3: Pacific desk 64 (P), holds [P,E], start 5 → B can't take desk 64 (no P) → excluded.
        let c3 = QualSwapShift(workerID: "C3", name: "C3", desk: "64", startHour: 5, quals: ["P", "E"])
        // C4: Domestic desk 11 (D), holds only [D], start 5 → can't take Euro desk 50 → excluded.
        let c4 = QualSwapShift(workerID: "C4", name: "C4", desk: "11", startHour: 5, quals: ["D"])
        // C5: like C1 but values E=1 < D=2 → moving onto 50 is UNfavorable. NEW (D6): still listed, but
        // flagged `favorable == false` (a stretch ask) rather than dropped.
        let c5 = QualSwapShift(workerID: "C5", name: "C5", desk: "10", startHour: 5, quals: ["D", "E"])
        let workers: [(QualSwapShift, TradeProfile)] = [
            (c1, bridgeProf("C1", ["E": 3, "D": 2])),
            (c2, bridgeProf("C2", ["E": 3, "D": 2])),
            (c3, bridgeProf("C3", ["E": 3, "P": 2])),
            (c4, bridgeProf("C4", ["D": 2])),
            (c5, bridgeProf("C5", ["E": 1, "D": 2])),
        ]
        let bridges = QualSwap.bridges(giveDesk: "50", takerQuals: takerQuals, startHour: 5,
                                       workers: workers, excludeIDs: ["A", "B"])
        // C1 (favorable) + C5 (unfavorable) both qualify + same-hour + B can take their desk; C2 (hour),
        // C3 (B can't take Pacific 64), C4 (no E) are dropped. Favorable sorts first. (D6.)
        check(bridges.map(\.workerID) == ["C1", "C5"], "S-ENG-4: favorable (C1) + unfavorable (C5) bridges return, favorable first")
        check(bridges.first(where: { $0.workerID == "C1" })?.favorable == true
                && bridges.first(where: { $0.workerID == "C5" })?.favorable == false,
              "S-ENG-4: C1 flagged favorable, C5 flagged unfavorable")
        // Excluded IDs (A, B) never appear even if working that day.
        let withExcluded = QualSwap.bridges(giveDesk: "50", takerQuals: takerQuals, startHour: 5,
            workers: workers + [(QualSwapShift(workerID: "B", name: "B", desk: "10", startHour: 5, quals: ["D", "E"]),
                                 bridgeProf("B", ["E": 3, "D": 2]))],
            excludeIDs: ["A", "B"])
        check(!withExcluded.contains(where: { $0.workerID == "B" }), "S-ENG-4: excluded parties never bridge")
        // Global timing gate: a non-tradeable start hour yields nothing even with a perfect bridge.
        check(QualSwap.bridges(giveDesk: "50", takerQuals: takerQuals, startHour: 7,
                               workers: [(QualSwapShift(workerID: "C1", name: "C1", desk: "10", startHour: 7, quals: ["D", "E"]),
                                          bridgeProf("C1", ["E": 3, "D": 2]))],
                               excludeIDs: []).isEmpty,
              "S-ENG-4: start hour outside {5,13,22} yields no bridges (global timing rule)")

        // MARK: Q3/Q6 — qual-swap leg state machine (pure reducer).
        check(QualSwapLeg.status(acceptedCount: 0, finalized: false, declined: false, expired: false) == .waiting,
              "Q-leg: no acceptances yet → waiting")
        check(QualSwapLeg.status(acceptedCount: 1, finalized: false, declined: false, expired: false) == .offersOpen,
              "Q-leg: ≥1 acceptance, slots remain → offersOpen")
        check(QualSwapLeg.status(acceptedCount: 5, finalized: false, declined: false, expired: false) == .offersFull,
              "Q-leg: first-5 cap reached → offersFull")
        check(QualSwapLeg.status(acceptedCount: 3, finalized: true, declined: false, expired: false) == .finalized,
              "Q-leg: taker finalized → finalized (wins over open offers)")
        check(QualSwapLeg.status(acceptedCount: 2, finalized: false, declined: true, expired: false) == .invalid,
              "Q-leg: taker declined → invalid even with acceptances")
        check(QualSwapLeg.status(acceptedCount: 0, finalized: false, declined: false, expired: true) == .invalid,
              "Q-leg: no bridge accepted in time → invalid")
        check(QualSwapLeg.status(acceptedCount: 2, finalized: false, declined: false, expired: true) == .offersOpen,
              "Q-leg: acceptances stand through expiry (taker can still finalize)")
        check(QualSwapLeg.acceptIsOpen(acceptedCount: 4) && !QualSwapLeg.acceptIsOpen(acceptedCount: 5),
              "Q-leg: first-5 acceptor cap (5th fills, 6th closed)")
        check(QualSwapLegStatus.allCases.count == 5, "Q-leg: status universe is exactly 5 cases (UI completeness guard)")

        // MARK: Q3/Q5/Q6 — embedded qual-swap leg data (first-5 cap, idempotency, derived status).
        let qsCands = (1...7).map { QualSwapCandidate(workerID: "C\($0)", name: "C\($0)", desk: "1\($0)", qual: "D") }
        var qleg = QualSwapLegData(giveShiftDayID: "2026-07-01", giveDesk: "50", giveQual: "E",
                                   takerID: "B", takerName: "B", candidates: qsCands)
        check(qleg.status == .waiting, "Q-leg-data: fresh leg is waiting")
        for i in 1...6 {
            qleg = qleg.addingAcceptance(QualSwapAcceptance(workerID: "C\(i)", name: "C\(i)", desk: "1\(i)", qual: "D", acceptedAt: Date()))
        }
        check(qleg.acceptances.count == 5, "Q-leg-data: first-5 acceptor cap holds (6th ignored)")
        check(qleg.status == .offersFull, "Q-leg-data: 5 acceptances → offersFull")
        let beforeDup = qleg.acceptances.count
        qleg = qleg.addingAcceptance(QualSwapAcceptance(workerID: "C1", name: "C1", desk: "11", qual: "D", acceptedAt: Date()))
        check(qleg.acceptances.count == beforeDup, "Q-leg-data: duplicate acceptance ignored (idempotent)")
        qleg.chosenWorkerID = "C2"
        check(qleg.status == .finalized && qleg.chosenAcceptance?.workerID == "C2", "Q-leg-data: chosen bridge → finalized")
        var qleg2 = QualSwapLegData(giveShiftDayID: "d", giveDesk: "50", giveQual: "E",
                                    takerID: "B", takerName: "B", candidates: qsCands)
        qleg2.takerDeclined = true
        check(qleg2.status == .invalid, "Q-leg-data: taker decline → invalid")

        // MARK: Q3 — role classifier + status text (drives inbox UI).
        let legForRole = QualSwapLegData(giveShiftDayID: "d", giveDesk: "50", giveQual: "E",
                                         takerID: "B", takerName: "B",
                                         candidates: [QualSwapCandidate(workerID: "C1", name: "C1", desk: "10", qual: "D")])
        let reqRole = TradeRequest(id: "r1", fromID: "A", fromName: "A", toID: "B", toName: "B",
                                   note: "", takeDayIDs: [], giveDayIDs: ["d"], createdAt: Date(), expiresAt: Date(),
                                   qualSwap: legForRole)
        check(reqRole.qualSwapRole(for: "A") == .giver, "Q-role: sender is giver")
        check(reqRole.qualSwapRole(for: "B") == .taker, "Q-role: leg taker is taker")
        check(reqRole.qualSwapRole(for: "C1") == .bridge, "Q-role: blasted candidate is bridge")
        check(reqRole.qualSwapRole(for: "Z") == .none, "Q-role: uninvolved worker is none")
        check(TradeRequest(id: "r2", fromID: "A", fromName: "A", toID: "B", toName: "B", note: "",
                           takeDayIDs: [], giveDayIDs: [], createdAt: Date(), expiresAt: Date()).qualSwapRole(for: "A") == .none,
              "Q-role: no leg → none")
        check(QualSwapRole.allCases.count == 4, "Q-role: role universe is exactly 4 cases")
        check(legForRole.statusText == "Waiting on qual swap", "Q-status: fresh leg text")

        // MARK: A3 #12 — status cross-device resolution is last-write-wins.
        let early = Date(timeIntervalSince1970: 1_000)
        let late  = Date(timeIntervalSince1970: 2_000)
        check(LWW.pick(local: "old status", localAt: early, remote: "new status", remoteAt: late) == "new status",
              "A3-status: a newer remote status wins on a fresh device")
        check(LWW.pick(local: "my latest", localAt: late, remote: "stale", remoteAt: early) == "my latest",
              "A3-status: a newer local edit is kept over a stale remote")

        // MARK: H1 #18 — global metrics aggregation (pure, team-wide).
        let now18 = Date(timeIntervalSince1970: 1_700_000_000)
        let evNow = now18
        let evOld = Date(timeIntervalSince1970: 1_600_000_000)
        let ev: [MetricEvent] = [
            MetricEvent(id: "1", workerID: "A", kind: .search, createdAt: evNow),
            MetricEvent(id: "2", workerID: "B", kind: .search, createdAt: evNow),
            MetricEvent(id: "3", workerID: "A", kind: .proposed, createdAt: evNow),
            MetricEvent(id: "4", workerID: "C", kind: .trade, createdAt: evNow),
            MetricEvent(id: "5", workerID: "C", kind: .trade, createdAt: evOld),   // out of month/year
        ]
        let g = Metrics.global(ev, period: .month, now: now18)
        check(g.searches == 2 && g.proposed == 1 && g.trades == 1,
              "H1-global: month aggregation counts only this month's events by kind")
        let gAll = Metrics.global(ev, period: .allTime, now: now18)
        check(gAll.trades == 2, "H1-global: all-time includes every period")
        check(Metrics.successPercent(accepted: g.trades, proposed: g.proposed) == 100,
              "H1-global: success% from global trade/proposed counts")

        // MARK: U6 — inbox intent-match 🔥 (pure).
        // ECB offer of a day I marked Want-to-Work → 🔥.
        check(MessagingStore.intentMatch(pickupDayIDs: ["2026-08-01"], takenFromMeDayIDs: [], isECB: true,
                                          myWantToWork: ["2026-08-01"], mySeeking: []),
              "U6: ECB pickup of a Want-to-Work day → 🔥")
        // Same pickup but NON-ECB → want-to-work doesn't apply → no 🔥.
        check(!MessagingStore.intentMatch(pickupDayIDs: ["2026-08-01"], takenFromMeDayIDs: [], isECB: false,
                                          myWantToWork: ["2026-08-01"], mySeeking: []),
              "U6: want-to-work only counts for ECB")
        // A day taken from me that I marked Trade-Away → 🔥 (any request type).
        check(MessagingStore.intentMatch(pickupDayIDs: [], takenFromMeDayIDs: ["2026-08-05"], isECB: false,
                                          myWantToWork: [], mySeeking: ["2026-08-05"]),
              "U6: taking my Trade-Away day → 🔥")
        // No overlap → no 🔥.
        check(!MessagingStore.intentMatch(pickupDayIDs: ["2026-09-09"], takenFromMeDayIDs: ["2026-09-10"], isECB: true,
                                          myWantToWork: ["2026-08-01"], mySeeking: ["2026-08-05"]),
              "U6: no intent overlap → no 🔥")
        // Sender-side "Perfect Match" uses the RECIPIENT's published intents.
        check(MessagingStore.requestPerfectMatch(give: [], take: ["2026-08-05"], isECB: false,
                                                 recipientSeeking: ["2026-08-05"], recipientWantToWork: []),
              "U6: perfect match when the request takes the recipient's Trade-Away day")
        check(!MessagingStore.requestPerfectMatch(give: ["2026-08-05"], take: [], isECB: false,
                                                  recipientSeeking: [], recipientWantToWork: ["2026-08-05"]),
              "U6: want-to-work pickup only perfect-matches for ECB, not a plain swap")

        // MARK: Q2 — bridges derive the freed desk's qual + favorability (D6).
        // Give a Latin desk (72 → L). C9 holds L (can bridge), sits on Euro desk 50. `takerQuals: nil` =
        // bridge-first (green button) → no taker-can-take check.
        let favBridges = QualSwap.bridges(
            giveDesk: "72", takerQuals: nil, startHour: 5,
            workers: [(QualSwapShift(workerID: "C9", name: "C9", desk: "50", startHour: 5, quals: ["D", "E", "L"]),
                       bridgeProf("C9", ["L": 3, "E": 2]))],   // Latin(3) > Euro(2) → favorable
            excludeIDs: [])
        check(favBridges.first?.desk == "50" && favBridges.first?.qual == "E",
              "Q2: bridge frees desk 50 → derives qual E")
        check(favBridges.first?.favorable == true, "Q2: Latin pref (3) ≥ Euro (2) → favorable")
        // Unfavorable (Latin ranked BELOW their Euro desk) is INCLUDED with the flag, not dropped.
        let unfavBridges = QualSwap.bridges(
            giveDesk: "72", takerQuals: nil, startHour: 5,
            workers: [(QualSwapShift(workerID: "C8", name: "C8", desk: "50", startHour: 5, quals: ["D", "E", "L"]),
                       bridgeProf("C8", ["L": 1, "E": 3]))],   // Latin(1) < Euro(3) → unfavorable
            excludeIDs: [])
        check(unfavBridges.count == 1 && unfavBridges.first?.favorable == false,
              "Q2: unfavorable bridge (Latin<Euro pref) is listed but flagged unfavorable")
        // User rule: a bridge whose FREED desk needs the SAME qual as the give-desk is useless — an
        // unqualified taker who can't work the give-desk can't work the freed desk either. A Latin
        // give-desk (72) bridged by freeing ANOTHER Latin desk (73) must be excluded, even bridge-first.
        check(QualSwap.bridges(giveDesk: "72", takerQuals: nil, startHour: 5,
              workers: [(QualSwapShift(workerID: "CL", name: "CL", desk: "73", startHour: 5, quals: ["D", "L"]),
                         bridgeProf("CL", ["L": 3]))],
              excludeIDs: []).isEmpty,
              "Q2: a same-qual freed desk (Latin 72 ← Latin 73) is NOT a valid bridge (user rule)")

        // MARK: Q1 — shared qual-gap SSOT (used by trade search + intents + routes).
        check(DeskRules.qualSwapNeeded(forDesk: "50", takerQuals: ["D"]),
              "Q1-gap: taker lacking Euro qual → swap needed for desk 50")
        check(!DeskRules.qualSwapNeeded(forDesk: "50", takerQuals: ["D", "E"]),
              "Q1-gap: taker holding Euro qual → no swap needed")
        check(!DeskRules.qualSwapNeeded(forDesk: "10", takerQuals: ["D"]),
              "Q1-gap: domestic desk needs only D → no swap")
        check(!DeskRules.qualSwapNeeded(forDesk: "OJT", takerQuals: []),
              "Q1-gap: no-gate desk → no swap")
        // Desks 46, 47, 93–98 are DOMESTIC (qual D) — explicit + guarded.
        check(["46", "47", "93", "94", "95", "96", "97", "98"].allSatisfy { DeskRules.region(forDesk: $0) == .domestic },
              "DESK: 46, 47, 93–98 are domestic")
        check(["46", "98"].allSatisfy { DeskRules.requiredQual(forDesk: $0) == "D" },
              "DESK: those domestic desks require qual D")
        // Q1 qual-BLOCKED: a Euro desk where no candidate taker holds E → blocked (needs a bridge).
        check(DeskRules.isQualBlocked(forDesk: "50", candidateTakerQuals: [["D"], ["D", "L"]]),
              "Q1-block: Euro desk with no E-qualified taker is qual-blocked")
        check(!DeskRules.isQualBlocked(forDesk: "50", candidateTakerQuals: [["D"], ["D", "E"]]),
              "Q1-block: a qualified taker present → not blocked")
        check(!DeskRules.isQualBlocked(forDesk: "50", candidateTakerQuals: []),
              "Q1-block: no takers at all is a coverage gap, not a qual block")

        // MARK: Q1 — 3-party qual-swap solution assembly (pure).
        // A gives Euro desk 50 (needs E). Bridge C1 works Domestic 10 (holds D+E), willing (E≥D).
        // Off-taker B1 holds D → can take C1's freed desk 10. Expect one solution (C1 frees 10, B1).
        let c1solo = QualSwapShift(workerID: "C1", name: "C1", desk: "10", startHour: 5, quals: ["D", "E"])
        let c2pac  = QualSwapShift(workerID: "C2", name: "C2", desk: "64", startHour: 5, quals: ["P"])      // no E → can't take 50
        let c3hr   = QualSwapShift(workerID: "C3", name: "C3", desk: "10", startHour: 13, quals: ["D", "E"]) // wrong hour
        let sols = QualSwap.solutions(
            giveDesk: "50", giveStartHour: 5, giverID: "A",
            workers: [(c1solo, bridgeProf("C1", ["E": 3, "D": 2])),
                      (c2pac, bridgeProf("C2", ["P": 1])),
                      (c3hr, bridgeProf("C3", ["E": 3, "D": 2]))],
            offTakers: [("B1", "B1", ["D"]), ("B2", "B2", ["L"])])   // B2 lacks D → can't take desk 10
        check(sols.count == 1 && sols.first?.bridgeID == "C1" && sols.first?.takerID == "B1"
              && sols.first?.bridgeDesk == "10",
              "Q1-solution: one valid (bridge C1 frees desk 10 → taker B1) solution assembled")

        // MARK: U1 — unified eligibility predicate (TradeEligibility.canCover).
        // Coverer is OFF Wed 2026-07-15; works Tue 07-14 (so covering 15 anchors → bookend).
        func rEntry(_ day: String, off: Bool, desk: String = "10", start: Int = 5, quals: [String] = ["D"]) -> RosterEntry {
            RosterEntry(workerID: "cov", workerName: "Cov", quals: quals, day: day, startHour: start, desk: desk, isOff: off)
        }
        let covMap: [String: RosterEntry] = [
            "2026-07-14": rEntry("2026-07-14", off: false),   // worked → anchor neighbor
            "2026-07-15": rEntry("2026-07-15", off: true),    // the off day we'd cover
            "2026-07-16": rEntry("2026-07-16", off: true),
        ]
        let d15 = DateComponents(calendar: .current, year: 2026, month: 7, day: 15).date!
        let openProfile = TradeProfile(workerID: "cov", displayName: "Cov", openness: "all",
                                       blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                                       blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date())
        // Physical-only: off + qualified (D for desk 10) + rested → eligible, and it's a bookend (anchors to 07-14).
        let cov1 = TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                             coverMap: covMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly)
        check(cov1.eligible && cov1.isBookend, "U1: off+qualified+rested coverer is eligible and bookended")
        // Not off that day → ineligible.
        var workingMap = covMap; workingMap["2026-07-15"] = rEntry("2026-07-15", off: false)
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                         coverMap: workingMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly).eligible,
              "U1: a coverer who isn't off that day is ineligible")
        // Not qualified (Euro desk 50 needs E, coverer holds only D) → ineligible.
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "50", startHour: 5,
                                         coverMap: covMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly).eligible,
              "U1: an unqualified coverer is ineligible")
        // Soft gates: a profile that blacklists desk 10 is rejected under .full but allowed under .physicalOnly.
        let blProfile = TradeProfile(workerID: "cov", displayName: "Cov", openness: "all",
                                     blacklistedWeekdays: [], blacklistedDesks: ["10"], blacklistedShiftTypes: [],
                                     blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date())
        check(TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                        coverMap: covMap, coverQuals: ["D"], coverProfile: blProfile, options: .physicalOnly).eligible,
              "U1: physicalOnly ignores blacklist (searcher ungated)")
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                         coverMap: covMap, coverQuals: ["D"], coverProfile: blProfile, options: .full).eligible,
              "U1: full applies soft gates — blacklisted desk rejected")
        // Option presets are distinct.
        check(EligibilityOptions.physicalOnly.applySoftGates == false && EligibilityOptions.full.applySoftGates,
              "U1: option presets differ on soft gates")

        // MARK: U1-regression — the gate matrix (hand-reasoned oracles locking the §U merge, #22).
        // (a) REST: prev day worked 1300 (ends 2200) → only 7h before a 0500 cover → not rested.
        var restMap = covMap
        restMap["2026-07-14"] = rEntry("2026-07-14", off: false, start: 13)
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                         coverMap: restMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly).eligible,
              "U1-rest: <8h rest (2200→0500) → ineligible")
        // (c) BOOKEND: an ISOLATED off day (no adjacent work) → eligible but NOT a bookend.
        let isoMap = ["2026-07-15": rEntry("2026-07-15", off: true)]
        let isoChk = TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                               coverMap: isoMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly)
        check(isoChk.eligible && !isoChk.isBookend, "U1-bookend: isolated off day → eligible, NOT a bookend")
        // (d) SOFT GATE: openness=none → wouldPickUp false → fails under .full, passes .physicalOnly.
        let noneProfile = TradeProfile(workerID: "cov", displayName: "Cov", openness: "none",
                                       blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                                       blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date())
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                         coverMap: covMap, coverQuals: ["D"], coverProfile: noneProfile, options: .full).eligible,
              "U1-soft: openness=none → ineligible under .full")
        check(TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                        coverMap: covMap, coverQuals: ["D"], coverProfile: noneProfile, options: .physicalOnly).eligible,
              "U1-soft: .physicalOnly ignores openness")

        // MARK: U1-dispatch — only genuine dispatch shifts trade. A training (TRN) desk or an
        // irregular start hour is NEVER coverable, regardless of off/qualified/rested. (User: a
        // permanent-TRN peer like Lee Roper is "not a dispatch shift" → not available for trading.)
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "TRN", startHour: 5,
                                         coverMap: covMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly).eligible,
              "U1-dispatch: a training (TRN) desk is never coverable — not a dispatch shift")
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 7,
                                         coverMap: covMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly).eligible,
              "U1-dispatch: an irregular start hour (0700) is never coverable")
        check(TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                        coverMap: covMap, coverQuals: ["D"], coverProfile: openProfile, options: .physicalOnly).eligible,
              "U1-dispatch: a regular 0500 dispatch desk still covers (regression)")
        check(!TradeTiming.isDispatchShift(desk: "TRN", startHour: 5), "U1-dispatch: isDispatchShift false for TRN desk")
        check(!TradeTiming.isDispatchShift(desk: "10", startHour: 7), "U1-dispatch: isDispatchShift false for irregular hour")
        check(TradeTiming.isDispatchShift(desk: "10", startHour: 13), "U1-dispatch: isDispatchShift true for 1300 dispatch")

        // MARK: Daily digest copy — plural-correct summary sentence; friendly zero-state.
        check(NotificationManager.digestBody(pending: 0, unread: 0) == "Nothing needs you right now — tap to browse your matches.",
              "digest: zero state")
        check(NotificationManager.digestBody(pending: 1, unread: 0) == "You have 1 pending trade. Tap to review.",
              "digest: singular pending")
        check(NotificationManager.digestBody(pending: 3, unread: 2) == "You have 3 pending trades and 2 unread messages. Tap to review.",
              "digest: both, pluralized")
        check(NotificationManager.digestBody(pending: 0, unread: 0, matches: 1) == "You have 1 trade match you haven't watched. Tap to review.",
              "digest: singular unwatched match")
        check(NotificationManager.digestBody(pending: 1, unread: 0, matches: 4) == "You have 1 pending trade and 4 trade matches you haven't watched. Tap to review.",
              "digest: pending + unwatched matches, pluralized")
        check(NotificationManager.digestBody(pending: 0, unread: 0, matches: 0, invalid: 2) == "You have 2 trades to fix (a day changed). Tap to review.",
              "digest: invalid trades surfaced")

        // MARK: U-RECV — a day I RECEIVE back must be a clean bookend for me (attaches to my work) or a
        // day I explicitly marked want-to-work; a random mid-week island is dropped. Bookends rank first.
        // (User: rank bookends higher even when my openness is open-to-everything.)
        do {
            func rleg(_ id: String, _ day: Int, bookend: Bool) -> TwoWayLeg {
                let date = DateComponents(calendar: .current, year: 2026, month: 9, day: day).date!
                return TwoWayLeg(dayID: id, date: date, desk: "29", startHour: 5, bookend: bookend, wanted: false)
            }
            let island = rleg("2026-09-15", 15, bookend: false)   // Mitchell's random mid-week Sep 15
            let clean1 = rleg("2026-09-07", 7,  bookend: true)
            let clean2 = rleg("2026-09-22", 22, bookend: true)
            // Bookends Only → the island is DROPPED; clean bookends kept, soonest-first.
            let strict = TradeRouter.cleanReceiveLegs([island, clean2, clean1], wantToWork: [], bookendsOnly: true)
            check(strict.map(\.dayID) == ["2026-09-07", "2026-09-22"],
                  "U-RECV: Bookends-Only excludes the non-bookend island")
            // Open-to-all → the island is KEPT but sorted LAST (bookends preferred).
            let open = TradeRouter.cleanReceiveLegs([island, clean2, clean1], wantToWork: [], bookendsOnly: false)
            check(open.map(\.dayID) == ["2026-09-07", "2026-09-22", "2026-09-15"],
                  "U-RECV: open-to-all keeps the island but ranks bookends first")
            // A want-to-work day I marked is kept even under Bookends Only.
            let kept = TradeRouter.cleanReceiveLegs([island], wantToWork: ["2026-09-15"], bookendsOnly: true)
            check(kept.map(\.dayID) == ["2026-09-15"],
                  "U-RECV: a want-to-work day I marked is kept even if it isn't a bookend")
            // Ranking: an all-clean package outranks a dirtier one (hands me an island) even with MORE coverage.
            var dirtyPkg = TradePackage(id: "dirty", methodology: .greedy, assignments: [], route: nil)
            dirtyPkg.coverageCount = 4; dirtyPkg.dirtyReceives = 1
            var cleanPkg = TradePackage(id: "clean", methodology: .greedy, assignments: [], route: nil)
            cleanPkg.coverageCount = 3; cleanPkg.dirtyReceives = 0
            check(TradeRouter.rankLess(cleanPkg, dirtyPkg),
                  "U-RECV: an all-clean package ranks above a dirtier one even with less coverage")
        }

        // MARK: A8 — a peer with NO published profile defaults to Bookends Only (conservative):
        // never offered a non-bookend (split-the-weekend) pickup until they opt into broader trading.
        do {
            let unpub = TradeProfile.defaultForUnpublished(workerID: "999", name: "Nobody")
            check(unpub.openness == TradeOpenness.bookends.rawValue, "A8: unpublished profile defaults to Bookends Only")
            let openPub = TradeProfile(workerID: "888", displayName: "Open", openness: TradeOpenness.all.rawValue,
                                       blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                                       blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date.distantPast)
            check(openPub.openness == TradeOpenness.all.rawValue, "A8: an explicitly-published Open profile stays Open (only MISSING profiles default)")
            let isoSplit = ["2026-07-15": rEntry("2026-07-15", off: true)]   // isolated off day → non-bookend (split)
            check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                             coverMap: isoSplit, coverQuals: ["D"], coverProfile: unpub, options: .full).eligible,
                  "A8: profileless (bookends) receiver REJECTS a non-bookend split pickup")
            check(TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                            coverMap: covMap, coverQuals: ["D"], coverProfile: unpub, options: .full).eligible,
                  "A8: profileless (bookends) receiver ACCEPTS a bookend pickup")
            check(TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                            coverMap: isoSplit, coverQuals: ["D"], coverProfile: openPub, options: .full).eligible,
                  "A8: an Open profile still accepts the split (proves the default is what changes behavior)")
        }

        // MARK: D1/F1 — POSITIONAL trade colors: you = blue, then seat-by-seat red → orange → green.
        do {
            let me = "me", p1 = "A", p2 = "B", p3 = "C"
            let order = [p1, p2, p3]   // the non-me participants in seat order
            check(TradeColors.color(forParticipant: me, myID: me, orderedPeers: order) == BrickPalette.mineScheme, "F1: you are always blue")
            check(TradeColors.color(forParticipant: p1, myID: me, orderedPeers: order) == BrickPalette.traderThemes[0], "F1: 2nd person = seat-1 color (red)")
            check(TradeColors.color(forParticipant: p2, myID: me, orderedPeers: order) == BrickPalette.traderThemes[1], "F1: 3rd person = seat-2 color (orange)")
            check(TradeColors.color(forParticipant: p3, myID: me, orderedPeers: order) == BrickPalette.traderThemes[2], "F1: 4th person = seat-3 color (green)")
            check(BrickPalette.traderThemes[0] == BrickPalette.peerScheme, "F1: seat-1 (2nd person) is red")
            check(BrickPalette.traderThemes.count >= 3, "F1: palette has ≥ red/orange/green")
        }

        // MARK: G2a — peer name resolution (the IMG-42 "660615" bug). Prefer a real
        // displayName → real roster name → employee #; a numeric "name" is never preferred.
        do {
            check(TradeNames.resolved(displayName: "Lee, Ervin", rosterName: "660615", workerID: "660615") == "Lee, Ervin",
                  "G2a: a real displayName wins over a numeric roster name")
            check(TradeNames.resolved(displayName: nil, rosterName: "Khuu, Julie", workerID: "555") == "Khuu, Julie",
                  "G2a: falls back to a real roster name when no displayName")
            check(TradeNames.resolved(displayName: "660615", rosterName: "Mitchell, Kristi", workerID: "660615") == "Mitchell, Kristi",
                  "G2a: a numeric displayName is rejected in favor of a real roster name")
            check(TradeNames.resolved(displayName: nil, rosterName: nil, workerID: "660615") == "660615",
                  "G2a: with no real name, falls back to the employee #")
            check(TradeNames.resolved(displayName: "  ", rosterName: "660615", workerID: "660615") == "660615",
                  "G2a: blank/numeric everywhere → employee # (nothing real to show)")
        }

        // MARK: D4 (revised) — a single generic "Propose" label for every count (user pref).
        check(proposeButtonTitle(count: 1, name: "Cary") == "Propose", "D4: always generic 'Propose' (1)")
        check(proposeButtonTitle(count: 4, name: "Cary") == "Propose", "D4: always generic 'Propose' (many)")

        // MARK: G2c — peer's FULL intent palette on the two-way calendar (was only trade-away).
        // Precedence: must-be-off → keep → trade-away (seeking) → want-to-work; else nil.
        do {
            let mbo = "2027-01-01", keep = "2027-01-02", seek = "2027-01-03", wtw = "2027-01-04", none = "2027-01-05"
            let sk: Set<String> = [seek], ww: Set<String> = [wtw], mb: Set<String> = [mbo], kp: Set<String> = [keep]
            check(PeerIntentColor.forDay(mbo, seeking: sk, wantToWork: ww, mustBeOff: mb, keep: kp) == OffIntentState.mustBeOff.brickColor, "G2c: must-be-off day → locked-off color")
            check(PeerIntentColor.forDay(keep, seeking: sk, wantToWork: ww, mustBeOff: mb, keep: kp) == WorkingIntentState.mustWork.brickColor, "G2c: keep day → keep color")
            check(PeerIntentColor.forDay(seek, seeking: sk, wantToWork: ww, mustBeOff: mb, keep: kp) == WorkingIntentState.dontWantToWork.brickColor, "G2c: trade-away day → change color")
            check(PeerIntentColor.forDay(wtw, seeking: sk, wantToWork: ww, mustBeOff: mb, keep: kp) == OffIntentState.wantToWork.brickColor, "G2c: want-to-work day → available color")
            check(PeerIntentColor.forDay(none, seeking: sk, wantToWork: ww, mustBeOff: mb, keep: kp) == nil, "G2c: an unmarked day has no peer-intent tint")
            // Precedence: a day in BOTH must-be-off and seeking shows must-be-off (strongest).
            check(PeerIntentColor.forDay(mbo, seeking: [mbo], wantToWork: [], mustBeOff: [mbo], keep: []) == OffIntentState.mustBeOff.brickColor,
                  "G2c: must-be-off outranks trade-away when a day is in both")
        }

        // (U-OBJ: retired #3 "pairwise always beats a loop" — it contradicts the intent-aware
        // N-penalty; and D5 "clean sorts above qual-swap by hard tier" — the qual-bridge drag now
        // lives INSIDE the score. Ported to runNPenaltyTests ❻ and runObjectiveTests ❹.)

        // MARK: G4 — import-success audit. Flags name-less workers (the "660615" malformed
        // import), missing-self, duplicate IDs, empty parse; clean import → ok with no warnings.
        do {
            let clean = ImportAudit.validate(workers: [("001", "Lee, Ervin"), ("002", "Khuu, Julie")], selfID: "001")
            check(clean.ok && clean.warnings.isEmpty && clean.workerCount == 2, "G4: a clean import passes with no warnings")
            let nameless = ImportAudit.validate(workers: [("660615", "660615"), ("002", "Khuu, Julie")], selfID: "002")
            check(!nameless.ok && nameless.namelessWorkers.contains("660615"), "G4: a worker named like its employee # is flagged nameless")
            let noSelf = ImportAudit.validate(workers: [("001", "Lee, Ervin")], selfID: "999")
            check(!noSelf.ok && !noSelf.selfFound, "G4: the importer's own ID missing is flagged")
            let dupes = ImportAudit.validate(workers: [("001", "A"), ("001", "A2")], selfID: "001")
            check(!dupes.ok && dupes.duplicateIDs.contains("001"), "G4: duplicate employee IDs are flagged")
            let empty = ImportAudit.validate(workers: [], selfID: "001")
            check(!empty.ok && empty.workerCount == 0, "G4: an empty parse is flagged (wrong file format)")
        }

        // MARK: H1 — unified acceptance-likelihood score (log-joint). legProb is a sigmoid of
        // weighted features; package = product (weakest-link); pruning bound is admissible.
        do {
            func leg(_ book: Bool, take: Bool, trade: Bool) -> LegFeatures {
                LegFeatures(wantToTake: take, wantToTrade: trade, bookend: book, timeValue: 0, needsQualBridge: false)
            }
            let dualBook = leg(true, take:true, trade:true), dualSplit = leg(false, take:true, trade:true)
            let singleBook = leg(true, take:true, trade:false), singleSplit = leg(false, take:true, trade:false)
            let noBook = leg(true, take:false, trade:false), noSplit = leg(false, take:false, trade:false)
            // Intent tiers: dual > single > none (same bookend).
            check(TradeScore.legProb(dualBook) > TradeScore.legProb(singleBook), "H1: dual want > single want")
            check(TradeScore.legProb(singleBook) > TradeScore.legProb(noBook), "H1: single want > no intent")
            // Bookend beats split within a tier.
            check(TradeScore.legProb(dualBook) > TradeScore.legProb(dualSplit), "H1: bookend > split (same intent)")
            // DUAL intent OVERRIDES a split: dual+split outranks no-intent+bookend.
            check(TradeScore.legProb(dualSplit) > TradeScore.legProb(noBook), "H1: dual intent overrides a split (dual+split > no-intent bookend)")
            // But a SINGLE want does NOT beat a clean no-intent trade.
            check(TradeScore.legProb(noBook) > TradeScore.legProb(singleSplit), "H1: no-intent bookend > single+split (single doesn't override)")
            check((0...1).contains(TradeScore.legProb(noSplit)), "H1: legProb is a probability in [0,1]")
            // package = product; weakest-link.
            check(TradeScore.packageProb([dualBook, noSplit]) < TradeScore.packageProb([dualBook, dualBook]),
                  "H1: one weak leg drags the package down (weakest-link)")
            check(abs(TradeScore.packageProb([dualBook, dualSplit]) - exp(TradeScore.packageLogProb([dualBook, dualSplit]))) < 1e-9,
                  "H1: packageProb == exp(packageLogProb)")
            // U-N2 (intent-aware penalty): a unanimous 3-way pays only peopleEdge, so it now
            // OUTRANKS a 2-person split — the owner's N-penalty requirement (flip of the old rule).
            check(TradeScore.packageLogProb(Array(repeating: dualBook, count: 3)) > TradeScore.packageLogProb(Array(repeating: dualSplit, count: 2)),
                  "U-N2: a unanimous 3-way now outranks a 2-person split (intent-aware penalty)")
            // admissible bound: adding legs never RAISES the log-prob.
            check(TradeScore.packageLogProb([dualBook]) >= TradeScore.packageLogProb([dualBook, dualBook]) - 1e-12,
                  "H1: partial-route log-prob is an admissible upper bound")
            // ECB lever: more points offered → higher acceptance.
            var ecbLo = noBook; ecbLo.ecbValue = 0.1
            var ecbHi = noBook; ecbHi.ecbValue = 0.9
            check(TradeScore.legProb(ecbHi) > TradeScore.legProb(ecbLo), "H1: more ECB offered → higher acceptance")
        }

        // MARK: G3 — a circular route's desirability drops when a leg SPLITS its receiver's
        // time off (non-bookend); all-bookend routes score highest.
        check(TradeScore.routeDesirability(legBookends: [true, true, true], legFires: [false, false, false])
              > TradeScore.routeDesirability(legBookends: [true, false, true], legFires: [false, false, false]),
              "G3: a split leg lowers the route's desirability vs all-bookend")
        check(TradeScore.routeDesirability(legBookends: [true, true], legFires: [true, true])
              > TradeScore.routeDesirability(legBookends: [true, true], legFires: [false, false]),
              "G3: mutual-🔥 legs raise the route's desirability")
        check(TradeScore.routeDesirability(legBookends: [], legFires: []) == 0, "G3: empty route → logprob 0")

        // MARK: A2 — Master Filter (pure): engine selector, max-people cap, force-include person.
        do {
            func pkg(_ id: String, peers: [String], circular: Bool) -> TradePackage {
                let a = peers.map { PackageAssignment(workerID: $0, name: $0, giveDayIDs: ["d"], takeDayIDs: ["e"]) }
                return TradePackage(id: id, methodology: circular ? .circular : .greedy, assignments: a, route: nil)
            }
            let pkgs = [pkg("solo", peers: ["A"], circular: false),       // 2 people
                        pkg("tri", peers: ["A", "B"], circular: true),     // 3 people
                        pkg("quad", peers: ["A", "B", "C"], circular: true)] // 4 people
            check(SearchFilter(engine: .both, maxPeople: 2, requiredWorkerID: nil).filter(pkgs, selfID: "").allSatisfy { $0.peopleCount <= 2 },
                  "A2: maxPeople caps participant count")
            check(SearchFilter(engine: .both, maxPeople: 4, requiredWorkerID: nil).filter(pkgs, selfID: "").count == 3, "A2: maxPeople 4 keeps all")
            check(SearchFilter(engine: .minCost, maxPeople: 4, requiredWorkerID: nil).filter(pkgs, selfID: "").allSatisfy { $0.methodology != .circular },
                  "A2: minCost engine drops circular")
            check(SearchFilter(engine: .nWay, maxPeople: 4, requiredWorkerID: nil).filter(pkgs, selfID: "").allSatisfy { $0.methodology == .circular },
                  "A2: nWay engine keeps only circular")
            let req = SearchFilter(engine: .both, maxPeople: 4, requiredWorkerID: "C").filter(pkgs, selfID: "")
            check(!req.isEmpty && req.allSatisfy { $0.assignments.contains { a in a.workerID == "C" } },
                  "A2: required person → only solutions containing them")
            check(Set(SearchFilter.Engine.allCases.map(\.rawValue)) == ["minCost", "nWay", "both"], "A2: engine CaseIterable universe guard")

            // A2b: Lucky button state — default is NOT active; any narrowing IS; summary shows only non-defaults.
            check(!SearchFilter.normal.isActive, "A2b: default filter is not active (shows everything)")
            check(SearchFilter(engine: .nWay, maxPeople: 4, requiredWorkerID: nil).isActive, "A2b: a narrowed engine is active")
            check(SearchFilter(engine: .both, maxPeople: 3, requiredWorkerID: nil).isActive, "A2b: a lowered max-people is active")
            check(SearchFilter.normal.summary(nameFor: { $0 }) == nil, "A2b: default filter has no summary")
            let sum = SearchFilter(engine: .nWay, maxPeople: 3, requiredWorkerID: "C").summary(nameFor: { _ in "Cary" })
            check(sum == "N-Way · ≤3 · with Cary", "A2b: summary lists only the non-default selections")
            check(SearchFilter(engine: .both, maxPeople: 4, requiredWorkerID: "C").summary(nameFor: { _ in "Cary" }) == "with Cary",
                  "A2b: summary omits defaulted engine/people, keeps the required person")

            // U-PERF: the fast BACKGROUND scope must stay 2-person / minCost — these thresholds GATE the
            // expensive 3+ multi-cover (maxPeople >= 3) and N-Way circular (engine != minCost) in packages().
            check(SearchFilter.fast.maxPeople == 2, "U-PERF: fast generation caps at 2 people (no 3+ multi-cover)")
            check(SearchFilter.fast.engine == .minCost, "U-PERF: fast generation is minCost (no N-Way circular DFS)")
            check(SearchFilter.fast.maxPeople < 3 && SearchFilter.fast.engine == .minCost,
                  "U-PERF: fast scope fails BOTH heavy-step gates (3+ and N-Way) — background stays cheap")
        }

        // MARK: INTENTS MARKETPLACE — pure deal assembler + intent-first ranking (distinct from packages).
        do {
            // Both sides marked → mutual deal, every leg counts toward intent score.
            let both = TradeRouter.assembleIntentDeal(.init(
                myGiveMarked: ["A1", "A2"], myGivePref: [],
                theirGiveMarked: ["B1", "B2"], theirGivePref: []))
            check(both?.gives == ["A1", "A2"] && both?.takes == ["B1", "B2"] && both?.mutualMarked == 4,
                  "Intents: both-sides-marked deal counts all 4 legs as mutual intent")

            // PEER-seeded: I marked NO give, but the peer marked a day I'd take → still a deal,
            // balanced with my pref give. This is the marketplace difference vs packages().
            let peerSeeded = TradeRouter.assembleIntentDeal(.init(
                myGiveMarked: [], myGivePref: ["P1"],
                theirGiveMarked: ["B1"], theirGivePref: []))
            check(peerSeeded?.gives == ["P1"] && peerSeeded?.takes == ["B1"] && peerSeeded?.mutualMarked == 1,
                  "Intents: a peer's marked day seeds a deal even when I marked no give (mutual=1, their side only)")

            // Neither side marked → NOT in the marketplace (pure availability is not an intent match).
            check(TradeRouter.assembleIntentDeal(.init(
                myGiveMarked: [], myGivePref: ["P1"], theirGiveMarked: [], theirGivePref: ["Q1"])) == nil,
                  "Intents: no marked intent on either side → no marketplace deal")

            // Unbalanced → trims to k = min, keeping MARKED legs first (they're ordered ahead of pref).
            let unbal = TradeRouter.assembleIntentDeal(.init(
                myGiveMarked: ["A1"], myGivePref: ["P1", "P2"],
                theirGiveMarked: ["B1"], theirGivePref: []))
            check(unbal?.gives == ["A1"] && unbal?.takes == ["B1"] && unbal?.mutualMarked == 2,
                  "Intents: balances to k=min and keeps the marked legs (drops surplus pref gives)")

            // U-OBJ: "MOST mutual intent ranks first" and the partnerPrior tiebreak now EMERGE from the
            // unified score (ported to runNPenaltyTests ❻ and runObjectiveTests H2), not a dead ranker.

            // H2: person-prior — neutral at no history; +/- with accept/decline; clamped; weights the logit.
            check(PersonPrior.logOdds(accepted: 0, declined: 0) == 0, "H2: no history → neutral prior (0)")
            check(PersonPrior.logOdds(accepted: 5, declined: 0) > 0, "H2: a history of accepting → positive prior")
            check(PersonPrior.logOdds(accepted: 0, declined: 5) < 0, "H2: a history of declining → negative prior")
            check(PersonPrior.logOdds(accepted: 1000, declined: 0) <= 2.0001, "H2: prior is clamped (thin/extreme record can't dominate)")
            var fHi = LegFeatures(wantToTake: false, wantToTrade: false, bookend: true, timeValue: 0.5, needsQualBridge: false)
            var fLo = fHi; fHi.personPrior = 1.5; fLo.personPrior = -1.5
            check(TradeScore.legProb(fHi) > TradeScore.legProb(fLo), "H2: a higher person-prior raises the leg's acceptance probability")

            // Safety ceiling constant (the finalize ceiling test in runFinalizeTests exercises the cap).
            check(TradeRouter.intentResultCap == 60, "Intents: safety ceiling is 60")

            // finalize (unified gate): AVERAGE-leg-quality floor (normal 0.32 / Lucky 0.07), then
            // coverage-first ranking, with a top-N empty-feed fallback. acceptanceScore is now 0…1.
            func fpkg(_ id: String, _ prob: Double, coverage: Int = 0) -> TradePackage {
                var p = TradePackage(id: id, methodology: .greedy,
                                     assignments: [PackageAssignment(workerID: "w", name: "n", giveDayIDs: ["d"], takeDayIDs: ["e"])],
                                     route: nil)
                p.acceptanceScore = prob; p.coverageCount = coverage; return p
            }
            let hi = fpkg("hi", 0.9), midp = fpkg("mid", 0.2), lop = fpkg("lo", 0.02)
            check(TradeRouter.finalize([midp, lop, hi], lucky: false).map(\.id) == ["hi"],
                  "finalize: normal floor (0.32) keeps only ≥0.32 avg-quality")
            check(TradeRouter.finalize([midp, lop, hi], lucky: true).map(\.id) == ["hi", "mid"],
                  "finalize: Lucky floor (0.07) admits more")
            // (U-OBJ: empty-feed fallback + coverage-weighted ordering now verified in runFinalizeTests,
            // where rankScore is set from real coverage — the in-place versions passed only by id-tie luck.)

            // packageQuality: covering more DAYS (more legs) with one person doesn't lower quality; more
            // PEOPLE does. (This is what un-buried the full-cover.)
            let cleanLeg = LegFeatures(wantToTake: true, wantToTrade: true, bookend: true,
                                       timeValue: 1, needsQualBridge: false)
            let q2legs = TradeScore.packageQuality(Array(repeating: cleanLeg, count: 2), people: 2)
            let q6legs = TradeScore.packageQuality(Array(repeating: cleanLeg, count: 6), people: 2)
            check(abs(q2legs - q6legs) < 0.0001, "packageQuality: more days (legs) with one person → same quality")
            // U-N2: for a fully-mutual package the people penalty is only the ~0.5%/person peopleEdge…
            let q4p3 = TradeScore.packageQuality(Array(repeating: cleanLeg, count: 4), people: 3)
            check(q4p3 < q2legs, "packageQuality: more people still strictly lowers (peopleEdge)")
            check(q4p3 / q2legs > 0.99, "packageQuality: an ALL-MUTUAL package is ~people-invariant (U-N2)")
            // …but NON-mutual legs still pay the real people penalty.
            let noneLeg = LegFeatures(wantToTake: false, wantToTrade: false, bookend: true,
                                      timeValue: 1, needsQualBridge: false)
            check(TradeScore.packageQuality(Array(repeating: noneLeg, count: 4), people: 3)
                  < 0.9 * TradeScore.packageQuality(Array(repeating: noneLeg, count: 2), people: 2),
                  "packageQuality: NON-mutual legs still pay the real people penalty")

            // Giver-side bookend: a peer's mid-week give (island off) is NOT clean; an edge day is.
            func rEntry(_ day: String, _ off: Bool) -> RosterEntry {
                RosterEntry(workerID: "R", workerName: "R", quals: ["D"], day: day, startHour: 5, desk: "10", isOff: off)
            }
            // Off Sun 13 · work Mon14–Fri18 · off Sat19
            let rDays: [(String, Bool)] = [("2026-09-13", true), ("2026-09-14", false), ("2026-09-15", false),
                                           ("2026-09-16", false), ("2026-09-17", false), ("2026-09-18", false), ("2026-09-19", true)]
            let rMap = Dictionary(rDays.map { ($0.0, rEntry($0.0, $0.1)) }, uniquingKeysWith: { a, _ in a })
            check(!TradeMatcher.isCleanGiveAway(day: TradeMatcher.dayDate(fromISO: "2026-09-15")!, map: rMap, cal: Calendar.current),
                  "give-bookend: a mid-week give (both neighbors worked → island off) is NOT clean")
            check(TradeMatcher.isCleanGiveAway(day: TradeMatcher.dayDate(fromISO: "2026-09-18")!, map: rMap, cal: Calendar.current),
                  "give-bookend: an edge give (neighbor off) IS clean")

            // A1 best-first seeding: highest score first, then soonest day (give-day IDs sort chronologically).
            check(TradeRouter.bestFirstSeeds([("2026-07-10", 0.5), ("2026-07-04", 3.5), ("2026-07-02", 0.5)])
                  == ["2026-07-04", "2026-07-02", "2026-07-10"],
                  "A1: best-first seeds order by score desc, then sooner date")
            check(TradeRouter.bestFirstSeeds([("2026-07-09", 2.0), ("2026-07-03", 2.0)]) == ["2026-07-03", "2026-07-09"],
                  "A1: equal score → the sooner day seeds first")
            // A1 seedScore folds urgency (dominant) + TradeScore (timeValue/qual friction refine ties).
            check(TradeRouter.seedScore(urgency: 3, daysUntil: 0, qualGatedDesk: false)
                  > TradeRouter.seedScore(urgency: 0, daysUntil: 0, qualGatedDesk: false),
                  "A1: higher urgency → higher seed score (urgency dominates)")
            check(TradeRouter.seedScore(urgency: 2, daysUntil: 1, qualGatedDesk: false)
                  > TradeRouter.seedScore(urgency: 2, daysUntil: 30, qualGatedDesk: false),
                  "A1: same urgency, sooner day → higher seed score (TradeScore timeValue)")
            check(TradeRouter.seedScore(urgency: 2, daysUntil: 5, qualGatedDesk: false)
                  > TradeRouter.seedScore(urgency: 2, daysUntil: 5, qualGatedDesk: true),
                  "A1: a qual-gated desk lowers the seed score (TradeScore qual friction)")

        }

        // MARK: #9 — Reddit-style reply threading (pure pre-order tree + subtree collapse).
        do {
            func rep(_ id: String, _ parent: String?, _ t: Double) -> BroadcastReply {
                BroadcastReply(id: id, postID: "P", authorID: "a", authorName: "A", text: id,
                               isPublic: true, createdAt: Date(timeIntervalSince1970: t), parentReplyID: parent)
            }
            // a (root) → b (child of a) → d (child of b); c is a 2nd root after a. Siblings oldest-first.
            let flat = [rep("c", nil, 30), rep("a", nil, 10), rep("d", "b", 25), rep("b", "a", 20)]
            let tree = ReplyThread.flatten(flat)
            check(tree.map(\.reply.id) == ["a", "b", "d", "c"], "#9: pre-order walk (parent then descendants), roots oldest-first")
            check(tree.map(\.depth) == [0, 1, 2, 0], "#9: nesting depth tracks the tree level")

            // Orphan (parent missing) surfaces at top level, never dropped.
            let orphan = ReplyThread.flatten([rep("x", "ghost", 5)])
            check(orphan.map(\.reply.id) == ["x"] && orphan.first?.depth == 0, "#9: a reply with a missing parent surfaces at top level")

            // Cycle safety: a↔b mutually parent each other → terminates, each emitted once.
            let cyclic = ReplyThread.flatten([rep("a", "b", 1), rep("b", "a", 2)])
            check(cyclic.count == 2, "#9: mutual-parent cycle terminates (each reply once)")

            // Subtree collapse: hiding a hides b and d, not c.
            check(ReplyThread.subtreeIDs(of: "a", in: flat) == ["b", "d"], "#9: subtreeIDs returns all descendants for per-comment collapse")
        }

        // MARK: E1 — channel shows newest at the top (newest → oldest); pinned still first.
        do {
            func post(_ id: String, at: TimeInterval, pinned: Bool? = nil) -> BroadcastPost {
                BroadcastPost(id: id, authorID: "x", authorName: "x", text: "t",
                              createdAt: Date(timeIntervalSince1970: at), expiresAt: Date(timeIntervalSince1970: at + 86400),
                              pinned: pinned)
            }
            let ordered = MessagingStore.sortedForChannel([post("new", at: 300), post("old", at: 100), post("mid", at: 200)])
            check(ordered.map(\.id) == ["new", "mid", "old"], "E1: channel posts show newest→oldest (latest at the top)")
            let withPin = MessagingStore.sortedForChannel([post("old", at: 100), post("pinNew", at: 500, pinned: true)])
            check(withPin.first?.id == "pinNew", "E1: a pinned post stays first regardless of age")
        }

        // MARK: B2 — merge an accepted qual-swap bridge into its base trade (one request).
        do {
            let now = Date()
            func req(_ id: String, give: [String], qual: QualSwapLegData?) -> TradeRequest {
                TradeRequest(id: id, fromID: "me", fromName: "Me", toID: "B", toName: "B", note: "",
                             takeDayIDs: [], giveDayIDs: give, createdAt: now, expiresAt: now.addingTimeInterval(86400),
                             qualSwap: qual)
            }
            let bridgeLeg = QualSwapLegData(giveShiftDayID: "2027-03-01", giveDesk: "50", giveQual: "E",
                                            takerID: "B", takerName: "B", candidates: [])
            let base = req("base", give: ["2027-03-01"], qual: nil)
            let bridge = req("bridge", give: ["2027-03-01"], qual: bridgeLeg)
            check(TradeMerge.canMerge(base: base, bridge: bridge), "B2: clean base + bridge sharing the give-day can merge")
            check(!TradeMerge.canMerge(base: req("b2", give: ["2027-03-09"], qual: nil), bridge: bridge),
                  "B2: cannot merge when the give-day doesn't match")
            check(!TradeMerge.canMerge(base: bridge, bridge: bridge), "B2: a base that already has a qual-swap can't merge again")
            let merged = TradeMerge.merge(base: base, bridge: bridge)
            check(merged.qualSwap == bridgeLeg && merged.giveDayIDs == base.giveDayIDs && merged.id != base.id,
                  "B2: merged request carries the bridge's qual-swap + base's days, with a new id")
            check(TradeMerge.merge(base: merged, bridge: bridge).id == merged.id, "B2: merging an already-merged request is a no-op")

            // B2 lifecycle (pure parts): findBase locates the mergeable clean base; active() drops the
            // archived originals and keeps the merged record — the inbox shows ONE card after merge.
            check(TradeMerge.findBase(for: bridge, in: [base, req("other", give: ["2027-03-09"], qual: nil)])?.id == "base",
                  "B2: findBase locates the clean base sharing the give-day")
            check(TradeMerge.findBase(for: bridge, in: [req("other", give: ["2027-03-09"], qual: nil)]) == nil,
                  "B2: findBase returns nil when no base shares the give-day")
            let archivedAfter: Set<String> = [base.id, bridge.id]   // what mergeRequests archives
            let activeAfter = MessagingStore.active([base, bridge, merged], archived: archivedAfter)
            check(activeAfter.map(\.id) == [merged.id], "B2: after merge, only the merged request stays active (originals archived)")
        }

        // MARK: B1 — detect a qual-gated (international) desk in the selection, which enables the
        // glowing "Qual Swap" button.
        check(DeskRules.hasQualGatedSelection(desks: ["50", "10"]), "B1: a qual-gated desk (50) enables qual-swap")
        check(!DeskRules.hasQualGatedSelection(desks: ["10", "29"]), "B1: only domestic desks → qual-swap disabled")
        check(!DeskRules.hasQualGatedSelection(desks: []), "B1: empty selection → disabled")

        // MARK: C1 — the trade recompute is gated on an explicit SAVE (a revision bump), not on
        // every intent edit, so the search isn't re-run constantly.
        do {
            let store = DayIntentStore.shared
            let before = store.intentsRevision
            store.markIntentsSaved()
            check(store.intentsRevision == before + 1, "C1: markIntentsSaved bumps the recompute revision")
            store.markIntentsSaved()
            check(store.intentsRevision == before + 2, "C1: each SAVE advances the revision")
        }

        // MARK: C1 phase-2 — dirty tracking + Discard buffer (Save-or-Discard guard).
        do {
            let store = DayIntentStore.shared
            let day = "2099-01-02"   // a far-future test day that no real schedule touches
            store.setWorkingIntent(nil, forDay: day)   // clean slate for this day
            store.markIntentsSaved()                    // baseline: day has no intent, flag clear
            check(!store.hasUnsavedChanges, "C1.2: a fresh SAVE clears the unsaved-changes flag")

            store.setWorkingIntent(.dontWantToWork, forDay: day)
            check(store.hasUnsavedChanges, "C1.2: editing an intent sets the unsaved-changes flag")
            check(store.workingIntent(forDay: day) == .dontWantToWork, "C1.2: the edit is visible before saving")

            store.discardChanges()
            check(!store.hasUnsavedChanges, "C1.2: Discard clears the unsaved-changes flag")
            check(store.workingIntent(forDay: day) == nil, "C1.2: Discard reverts the edit to the saved baseline")

            // Save then edit then discard reverts only to the SAVED value, not all the way to empty.
            store.setWorkingIntent(.mustWork, forDay: day)
            store.markIntentsSaved()
            store.setWorkingIntent(.dontWantToWork, forDay: day)
            store.discardChanges()
            check(store.workingIntent(forDay: day) == .mustWork, "C1.2: Discard reverts to the last SAVED value")
            store.setWorkingIntent(nil, forDay: day); store.markIntentsSaved()   // cleanup
        }

        // MARK: Relief dispatcher — schedule unknown past the horizon (pure).
        let reliefDate = DateComponents(calendar: .current, year: 2026, month: 8, day: 7).date!
        let beforeRelief = DateComponents(calendar: .current, year: 2026, month: 8, day: 7).date!  // inclusive
        let afterRelief  = DateComponents(calendar: .current, year: 2026, month: 8, day: 8).date!
        check(!TradeProfile.isPastRelief(day: beforeRelief, reliefThrough: reliefDate),
              "Relief: the horizon date itself is still known (inclusive)")
        check(TradeProfile.isPastRelief(day: afterRelief, reliefThrough: reliefDate),
              "Relief: the day after the horizon is unknown")
        check(!TradeProfile.isPastRelief(day: afterRelief, reliefThrough: nil),
              "Relief: a non-relief dispatcher (nil horizon) is never past relief")
        // canCover rejects covering a day past the coverer's relief horizon (schedule not real).
        var reliefProf = openProfile; reliefProf.reliefThrough = reliefDate
        check(!TradeEligibility.canCover(coverDayID: TradeMatcher.isoDay(afterRelief), coverDay: afterRelief,
                                         desk: "10", startHour: 5, coverMap: ["\(TradeMatcher.isoDay(afterRelief))": rEntry(TradeMatcher.isoDay(afterRelief), off: true)],
                                         coverQuals: ["D"], coverProfile: reliefProf, options: .physicalOnly).eligible,
              "Relief: canCover rejects a day past the coverer's relief horizon")

        // MARK: #1 — a fully rest-blocked off day has NO legal shift → auto-X (can't mark Want-to-Work).
        func shiftOn(_ day: Int, _ start: Int) -> Shift {
            let d = DateComponents(calendar: .current, year: 2026, month: 8, day: day).date!
            return Shift(id: "s\(day)", date: d, startHour: start, endHour: (start + 9) % 24,
                         role: .dispatcher, desk: "10", leaveCode: nil, isOff: false)
        }
        let offDay = DateComponents(calendar: .current, year: 2026, month: 8, day: 15).date!
        // Surrounded: MID the day before (2100→0600) + AM the day after (0500) blocks AM/PM/MID on the 15th.
        let blockedShifts = [shiftOn(14, 21), shiftOn(16, 5)]
        check(!AvailabilityManager.hasAnyLegalShift(forOffDay: offDay, workedShifts: blockedShifts),
              "#1: a fully rest-blocked off day has no legal shift")
        check(AvailabilityManager.hasAnyLegalShift(forOffDay: offDay, workedShifts: []),
              "#1: an unconstrained off day has legal shifts")

        // MARK: R-A — the match universe is the ROSTER, profiles layer on top (fixes "only 3 dispatchers").
        func mkProf(_ id: String, _ openness: String) -> TradeProfile {
            TradeProfile(workerID: id, displayName: id, openness: openness, blacklistedWeekdays: [],
                         blacklistedDesks: [], blacklistedShiftTypes: [], blacklistedRegions: [],
                         seekingDayIDs: [], updatedAt: Date())
        }
        let rosterUni: [(id: String, name: String, quals: [String])] =
            [("A", "A", ["D"]), ("B", "B", ["D"]), ("C", "C", ["D"]), ("me", "Me", ["D"])]
        let profsUni = ["A": mkProf("A", "all"), "B": mkProf("B", "none")]   // C has NO profile
        let uni = MatchUniverse.candidates(roster: rosterUni, profiles: profsUni, selfID: "me")
        check(uni.contains { $0.workerID == "C" && $0.willingness == .unknown },
              "R-A: a roster worker with NO profile is in the universe as .unknown")
        check(uni.contains { $0.workerID == "A" && $0.willingness == .willing },
              "R-A: an opted-in peer is .willing")
        check(!uni.contains { $0.workerID == "B" },
              "R-A: a declined (openness=none) peer is excluded by default")
        check(!uni.contains { $0.workerID == "me" }, "R-A: self is never a candidate")
        let uniWhatIf = MatchUniverse.candidates(roster: rosterUni, profiles: profsUni, selfID: "me", includeDeclined: true)
        check(uniWhatIf.contains { $0.workerID == "B" && $0.willingness == .declined },
              "R-A: What-If includes declined peers")

        // MARK: P0 — an empty fetch (transient CloudKit error) must NOT wipe a non-empty cache.
        check(FetchMerge.keepCacheOnEmpty(existing: [1, 2, 3], fetched: [Int]()) == [1, 2, 3],
              "P0: an empty fetch keeps the existing non-empty cache (no wipe)")
        check(FetchMerge.keepCacheOnEmpty(existing: [1], fetched: [9, 8]) == [9, 8],
              "P0: a non-empty fetch replaces the cache normally")
        check(FetchMerge.keepCacheOnEmpty(existing: [Int](), fetched: [Int]()) == [],
              "P0: empty→empty stays empty (fresh account)")

        // MARK: P0 — old records still decode after new optional fields (data-wipe guard, img 32).
        func decodes<T: Decodable>(_ type: T.Type, _ json: String) -> Bool {
            guard let data = json.data(using: .utf8) else { return false }
            return (try? JSONDecoder().decode(type, from: data)) != nil
        }
        check(decodes(BroadcastPost.self, #"{"id":"p1","authorID":"A","authorName":"A","text":"hi","createdAt":0,"expiresAt":0}"#),
              "P0: a v1 BroadcastPost (no channel/pinned/reactions/image) still decodes")
        check(decodes(BroadcastReply.self, #"{"id":"r1","postID":"p1","authorID":"A","authorName":"A","text":"hi","isPublic":true,"createdAt":0}"#),
              "P0: a v1 BroadcastReply still decodes")
        check(decodes(TradeResponse.self, #"{"id":"x1","requestID":"q1","responderID":"A","responderName":"A","status":"pending","note":"","createdAt":0}"#),
              "P0: a v1 TradeResponse still decodes")
        check(decodes(TradeRequest.self, #"{"id":"q1","fromID":"A","fromName":"A","toID":"B","toName":"B","note":"","takeDayIDs":[],"giveDayIDs":[],"createdAt":0,"expiresAt":0}"#),
              "P0: a v1 TradeRequest (no qualSwap/perfectMatch) still decodes")
        check(decodes(TradeProfile.self, #"{"workerID":"A","displayName":"A","openness":"all","blacklistedWeekdays":[],"blacklistedDesks":[],"blacklistedShiftTypes":[],"blacklistedRegions":[],"seekingDayIDs":[],"updatedAt":0}"#),
              "P0: a v1 TradeProfile (no qualValues/reliefThrough) still decodes")

        // MARK: B4-14 — compact ECB-style card gate (2-person only; 3+/circular keep PackageCard).
        do {
            func pa2(_ id: String) -> PackageAssignment {
                PackageAssignment(workerID: id, name: id, giveDayIDs: ["2026-07-01"], takeDayIDs: ["2026-07-02"])
            }
            let two = TradePackage(id: "t2", methodology: .greedy, assignments: [pa2("A")], route: nil)
            let three = TradePackage(id: "t3", methodology: .greedy, assignments: [pa2("A"), pa2("B")], route: nil)
            let r3 = NWayRoute(participants: ["me", "A", "B"], legs: [], tier: .matchingIntents, score: 0, usesBookends: false)
            let circ3 = TradePackage(id: "c3", methodology: .circular, assignments: [pa2("A"), pa2("B")], route: r3)
            let qsLeg = QualSwapLegData(giveShiftDayID: "2026-07-01", giveDesk: "82", giveQual: "L",
                                        takerID: "A", takerName: "A", candidates: [])
            let qs2 = TradePackage(id: "qs2", methodology: .greedy,
                                   assignments: [PackageAssignment(workerID: "A", name: "A", giveDayIDs: ["2026-07-01"], takeDayIDs: [])],
                                   route: nil, qualSwap: qsLeg)
            check(two.usesCompactCard, "B4-14: a two-person swap uses the compact card")
            check(qs2.usesCompactCard, "B4-14: a 2-way qual-swap uses the compact card")
            check(!three.usesCompactCard, "B4-14: a 3-person package keeps PackageCard")
            check(!circ3.usesCompactCard, "B4-14: a circular (3) package keeps PackageCard")
        }

        // MARK: B4-2 — intent snapshot round-trips (marks + notes + topology survive cross-device sync).
        do {
            let snap = DayIntentStore.IntentSnapshot(
                working: ["2026-07-01": .dontWantToWork, "2026-07-02": .mustWork],
                off: ["2026-07-03": .wantToWork, "2026-07-04": .mustBeOff],
                topologies: ["2026-07-05": .personalMilestone],
                notes: ["2026-07-01": DayNote(dayID: "2026-07-01", message: "swap wk", reason: .personalEvent)],
                availability: ["2026-07-03": [.am, .pm]],
                manualOff: ["2026-07-04"])
            let enc = try? JSONEncoder().encode(snap)
            check(enc != nil, "B4-2: intent snapshot encodes")
            let back = enc.flatMap { try? JSONDecoder().decode(DayIntentStore.IntentSnapshot.self, from: $0) }
            check(back == snap, "B4-2: intent snapshot round-trips (marks + notes + topology intact)")
        }

        // MARK: B4-4 — "Blackout weekends" only ever touches Sat(7)+Sun(1).
        do {
            check(WeekendBlackout.apply(on: true, to: [3]) == [1, 3, 7], "B4-4: on adds Sat+Sun, keeps existing")
            check(WeekendBlackout.apply(on: false, to: [1, 3, 7]) == [3], "B4-4: off removes only Sat+Sun, keeps others")
            check(WeekendBlackout.isOn([1, 7, 4]) && !WeekendBlackout.isOn([1, 4]), "B4-4: isOn requires BOTH weekend days")
        }

        // MARK: B4-5 — hard-blacklist profileless peers to their recent behavior (region + type + weekend).
        do {
            let asOf = TradeMatcher.dayDate(fromISO: "2026-03-02")!   // a Monday
            func e(_ day: String, off: Bool = false, hour: Int = 5, desk: String = "10") -> RosterEntry {
                RosterEntry(workerID: "W", workerName: "W", quals: ["D"], day: day, startHour: hour, desk: desk, isOff: off)
            }
            let amType = ShiftAvailabilityType.infer(fromStartHour: 5).rawValue
            let reg10 = DeskRules.region(forDesk: "10").rawValue
            // 6 weekday AM/desk-10 shifts, no weekends → weekend blacklist expected.
            let weekdays = ["2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20", "2026-02-23"].map { e($0) }
            let inf = InferredPrefs.from(entries: weekdays + [e("2026-02-10", off: true), e("2025-01-01")], asOf: asOf)
            check(inf?.shiftTypes == [amType], "B4-5: infers only worked shift types (AM); off/old excluded")
            check(inf?.regions == [reg10], "B4-5: infers only worked regions")
            check(inf?.worksWeekend == false, "B4-5: no Sat/Sun in window → worksWeekend false")
            check(InferredPrefs.from(entries: [e("2026-02-20")], asOf: asOf) == nil, "B4-5: < 6 shifts → nil (no over-restriction)")
            // A worker WITH a weekend shift (Sat 2026-02-21).
            let withWknd = InferredPrefs.from(entries: weekdays + [e("2026-02-21")], asOf: asOf)
            check(withWknd?.worksWeekend == true, "B4-5: a Sat shift → worksWeekend true")
            // Default profile: complement blacklisted + weekends blacklisted when they don't work them.
            let prof = TradeProfile.defaultForUnpublished(workerID: "W", name: "W",
                        inferredShiftTypes: [amType], inferredRegions: [reg10], blacklistWeekends: true)
            check(!prof.blacklistedShiftTypes.contains(amType)
                  && prof.blacklistedShiftTypes.count == ShiftAvailabilityType.allCases.count - 1,
                  "B4-5: inferred default blacklists every shift type EXCEPT worked")
            check(prof.blacklistedWeekdays == [1, 7], "B4-5: blacklistWeekends → Sun+Sat blacklisted")
            let plain = TradeProfile.defaultForUnpublished(workerID: "W", name: "W")
            check(plain.blacklistedShiftTypes.isEmpty && plain.blacklistedRegions.isEmpty && plain.blacklistedWeekdays.isEmpty,
                  "B4-5: plain A8 default unchanged")
        }

        // MARK: B4-3 — Blackout blacklist predicate (paints blacklisted shifts on the calendar).
        do {
            let amType = ShiftAvailabilityType.infer(fromStartHour: 5).rawValue
            let region82 = DeskRules.region(forDesk: "82").rawValue
            check(Blackout.isBlacklisted(desk: "82", startHour: 5, weekday: 3, desks: ["82"], shiftTypes: [], regions: [], weekdays: []),
                  "B4-3: a blacklisted desk is blacked out")
            check(Blackout.isBlacklisted(desk: "10", startHour: 5, weekday: 7, desks: [], shiftTypes: [], regions: [], weekdays: [7]),
                  "B4-3: a blacklisted weekday is blacked out")
            check(Blackout.isBlacklisted(desk: "10", startHour: 5, weekday: 3, desks: [], shiftTypes: [amType], regions: [], weekdays: []),
                  "B4-3: a blacklisted shift type is blacked out")
            check(Blackout.isBlacklisted(desk: "82", startHour: 5, weekday: 3, desks: [], shiftTypes: [], regions: [region82], weekdays: []),
                  "B4-3: a blacklisted region is blacked out")
            check(!Blackout.isBlacklisted(desk: "10", startHour: 5, weekday: 3, desks: ["82"], shiftTypes: ["ZZ"], regions: ["ZZ"], weekdays: []),
                  "B4-3: a shift matching NO blacklist dimension is not blacked out")
        }

        // MARK: B6-LABEL — working protect = "Keep" (green), off protect = "Blackout" (slate). (Supersedes
        // B4-1's shared "Blackout" label: the working keep is now visually + verbally distinct from blocked.)
        check(WorkingIntentState.mustWork.label == "Keep", "B6-LABEL: working-protect day label reads 'Keep'")
        check(OffIntentState.mustBeOff.label == "Blackout", "B6-LABEL: off-protect (must-be-off) day label reads 'Blackout'")
        // Cases/keys are unchanged (no data migration) — raw values must stay stable.
        check(WorkingIntentState.mustWork.rawValue == "mustWork", "B4-1: mustWork raw value unchanged (no migration)")
        check(OffIntentState.mustBeOff.rawValue == "mustBeOff", "B4-1: mustBeOff raw value unchanged (no migration)")

        // MARK: Z2 — changelog show-once.
        check(ChangeLog.shouldShow(currentBuild: "12", lastSeen: "11"), "Z2: a newer build shows the changelog")
        check(!ChangeLog.shouldShow(currentBuild: "12", lastSeen: "12"), "Z2: same build → no re-show")
        check(ChangeLog.shouldShow(currentBuild: "1", lastSeen: ""), "Z2: first launch shows it")
        check(!ChangeLog.shouldShow(currentBuild: "", lastSeen: ""), "Z2: empty build → never show (no crash)")

        // MARK: #9 — "successful" = accepted AND archived; totals (You vs Company) per period.
        check(Metrics.isSuccessful(accepted: true, archived: true), "#9: accepted+archived = successful")
        check(!Metrics.isSuccessful(accepted: true, archived: false), "#9: accepted but not archived ≠ successful")
        check(!Metrics.isSuccessful(accepted: false, archived: true), "#9: archived but not accepted ≠ successful")
        let mNow = Date(timeIntervalSince1970: 1_700_000_000)
        let mEvents = [
            MetricEvent(id: "t1", workerID: "me", kind: .trade, createdAt: mNow),
            MetricEvent(id: "t2", workerID: "B",  kind: .trade, createdAt: mNow),
            MetricEvent(id: "t3", workerID: "C",  kind: .trade, createdAt: Date(timeIntervalSince1970: 1_600_000_000)),
        ]
        check(Metrics.count(mEvents, kind: .trade, period: .allTime, now: mNow) == 3, "#9: company all-time total")
        check(Metrics.count(mEvents, kind: .trade, period: .month, now: mNow) == 2, "#9: month total scopes by period")
        check(Metrics.count(mEvents, kind: .trade, period: .allTime, now: mNow, workerID: "me") == 1, "#9: YOUR total filters to you")

        // MARK: G1 — Outlook/email trade announcement (pure body + mailto).
        let emBody = TradeEmail.body(giver: "Me", taker: "Cary", giveDays: ["Jul 4"],
                                     takeDays: ["Jul 6"], blackoutDays: ["Jul 10", "Jul 11"])
        check(emBody.contains("Me ⇄ Cary") && emBody.contains("Me gives Jul 4")
              && emBody.contains("Cary gives Jul 6")
              && emBody.contains("Blackout days (unavailable): Jul 10, Jul 11"),
              "G1: email body has the trade + Must-Be-Off blackout days")
        check(!TradeEmail.body(giver: "A", taker: "B", giveDays: [], takeDays: [], blackoutDays: []).contains("Blackout"),
              "G1: no blackout line when there are none")
        check(TradeEmail.mailtoURL(dl: "DL_dispatch_trades@aa.com", subject: "s", body: emBody) != nil,
              "G1: a mailto URL builds when the DL is set")
        check(TradeEmail.mailtoURL(dl: "", subject: "s", body: "b") == nil,
              "G1: no DL → no URL")
        // #7: Trade Solutions DL email has blackout days; ECB email states the ECB count, NO blackout.
        check(TradeEmail.dispatchBody(giver: "Me", giveDays: ["Jul 4"], blackoutDays: ["Jul 10"]).contains("Blackout days"),
              "#7: dispatch trade email includes blackout days")
        let ecbB = TradeEmail.ecbBody(giver: "Me", giveDays: ["Jul 4"], ecb: 9)
        check(ecbB.contains("9 ECB") && !ecbB.contains("Blackout"),
              "#7: ECB email states the ECB count and has NO blackout days")
        check(TradeEmail.outlookURL(dl: "DL_dispatch_trades@aa.com", subject: "s", body: "b") != nil,
              "#7: Outlook compose URL builds")

        // MARK: Global trade timing — only 0500/1300/2100 are tradeable.
        check(TradeTiming.isTradeable(startHour: 5) && TradeTiming.isTradeable(startHour: 13) && TradeTiming.isTradeable(startHour: 21),
              "TIMING: 0500/1300/2100 are tradeable")
        check(!TradeTiming.isTradeable(startHour: 22) && !TradeTiming.isTradeable(startHour: 6) && !TradeTiming.isTradeable(startHour: 0),
              "TIMING: other start hours are not tradeable")

        // MARK: #5 — bookend display: an ISOLATED give-day (no adjacent existing work for
        // the receiver) is NOT a bookend; TwoWaySheet.legCard must only show the "bookend"
        // tag when leg.bookend is true (was printed unconditionally).
        do {
            let cal = Calendar.current
            func entry(_ iso: String, off: Bool) -> RosterEntry {
                RosterEntry(workerID: "P", workerName: "P", quals: [], day: iso,
                            startHour: off ? 0 : 13, desk: "29", isOff: off)
            }
            func d(_ iso: String) -> Date { TradeMatcher.dayDate(fromISO: iso) ?? Date.distantPast }
            // Receiver works Jul 4 & Jul 6; off otherwise. Giving them Jul 5 anchors (between two
            // work days) → bookend. Giving them Jul 18 (isolated) → NOT a bookend.
            let map: [String: RosterEntry] = [
                "2026-07-04": entry("2026-07-04", off: false),
                "2026-07-06": entry("2026-07-06", off: false),
            ]
            check(TradeMatcher.anchored(day: d("2026-07-05"), map: map, plan: ["2026-07-05"], cal: cal),
                  "#5: a day adjacent to existing work IS a bookend")
            check(!TradeMatcher.anchored(day: d("2026-07-18"), map: map, plan: ["2026-07-18"], cal: cal),
                  "#5: an isolated give-day is NOT a bookend (Jun-18 mislabel bug)")
        }

        // MARK: NET-BOOKEND — a bookend must NOT count when trading a day away adjacently in the
        // SAME trade breaks it at the same time. Pickup of Jul 5 anchors ONLY because Jul 4 (or Jul 6)
        // is worked; if Jul 4 is given away in this same package, Jul 5 becomes an isolated island → the
        // net-aware `removed` set demotes it.
        do {
            let cal = Calendar.current
            func entry(_ iso: String, off: Bool) -> RosterEntry {
                RosterEntry(workerID: "M", workerName: "M", quals: [], day: iso,
                            startHour: off ? 0 : 13, desk: "29", isOff: off)
            }
            func d(_ iso: String) -> Date { TradeMatcher.dayDate(fromISO: iso) ?? Date.distantPast }
            // I work Jul 4 & Jul 5 (a 2-day block), off around them. Picking up… well, take the reverse
            // case: Jul 5 anchored to Jul 4's work.
            let map: [String: RosterEntry] = [
                "2026-07-04": entry("2026-07-04", off: false),
                "2026-07-05": entry("2026-07-05", off: false),
            ]
            // Base: Jul 6 pickup anchors because Jul 5 is worked (contiguous block Jul 4-5-6).
            check(TradeMatcher.anchored(day: d("2026-07-06"), map: map, plan: ["2026-07-06"], cal: cal),
                  "NET-BOOKEND: base — Jul 6 pickup anchors to the Jul 4-5 work block")
            // Give away BOTH Jul 4 and Jul 5 in the same trade → Jul 6 pickup is now an isolated island.
            check(!TradeMatcher.anchored(day: d("2026-07-06"), map: map, plan: ["2026-07-06"],
                                         removed: ["2026-07-04", "2026-07-05"], cal: cal),
                  "NET-BOOKEND: an adjacent give-away in the same trade breaks the bookend → demoted")
            // Removing only the far day (Jul 4) still leaves Jul 5 as the anchor → still a bookend.
            check(TradeMatcher.anchored(day: d("2026-07-06"), map: map, plan: ["2026-07-06"],
                                        removed: ["2026-07-04"], cal: cal),
                  "NET-BOOKEND: a give-away that doesn't touch the anchor leaves the bookend intact")
        }

        // MARK: R-B — cross-device profile round-trip. The CloudKit publish/fetch path
        // JSON-encodes the whole TradeProfile into one `payload`; status + intents MUST
        // survive encode→decode (else peers see blank status / no uploaded intents).
        do {
            var p = TradeProfile(workerID: "001", displayName: "Me", openness: "all",
                                 blacklistedWeekdays: [2], blacklistedDesks: ["29"],
                                 blacklistedShiftTypes: ["AM"], blacklistedRegions: ["Domestic"],
                                 seekingDayIDs: ["2026-07-04", "2026-07-05"], updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 statusBroadcast: "Open to bookends this month")
            p.wantToWorkDayIDs = ["2026-07-10"]
            p.mustBeOffDayIDs = ["2026-07-20"]
            p.keepDayIDs = ["2026-07-22"]
            guard let data = try? JSONEncoder().encode(p),
                  let back = try? JSONDecoder().decode(TradeProfile.self, from: data) else {
                check(false, "R-B: profile failed to encode/decode through the payload codec"); return fails
            }
            check(back.statusBroadcast == "Open to bookends this month", "R-B: statusBroadcast survives round-trip")
            check(back.seekingDayIDs == ["2026-07-04", "2026-07-05"], "R-B: seekingDayIDs (give-away intents) survive")
            check(back.wantToWorkDayIDs == ["2026-07-10"], "R-B: wantToWorkDayIDs survive")
            check(back.mustBeOffDayIDs == ["2026-07-20"], "R-B: mustBeOffDayIDs survive")
            check(back.keepDayIDs == ["2026-07-22"], "R-B: keepDayIDs survive")
        }

        // U-OBJ redesign — new adversarial blocks (EngineTestsAdditions.swift).
        #if DEBUG
        fails += runNPenaltyTests() + runObjectiveTests() + runPruningBoundTests()
               + runRankerTests() + runFinalizeTests() + runOptimalMatcherTests()
               + runDirectMessageTests()
        #endif

        return fails
    }

    /// B6-SYNC — verifies the ATOMIC roster import (generation tag + pointer swap). Kept SEPARATE from the
    /// pure synchronous `runAll()` because it's async and touches SwiftData (an in-memory `RosterShift`
    /// store + `RosterModelActor`). Discharges the ASSUMED_PRESENT B6-SYNC "no cross-generation duplicates"
    /// item that the RunCodeSnippet harness couldn't (it can't build the `@ModelActor` init out-of-module).
    ///
    /// Run from Developer Tools, or:  `print(await TradeEngineTests.rosterAtomicityFailures())`
    static func rosterAtomicityFailures() async -> [String] {
        var fails: [String] = []
        func check(_ cond: Bool, _ msg: String) { if !cond { fails.append("❌ " + msg) } }

        let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: RosterShift.self, configurations: cfg) else {
            return ["❌ ROSTER-ATOMIC: could not build an in-memory RosterShift container"]
        }
        let act = RosterModelActor(modelContainer: container)

        func worker(_ id: String, _ desk: String) -> ParsedWorker {
            let d = Date(timeIntervalSince1970: 1_700_000_000)
            let s = Shift(id: "\(id)-2026-07-10", date: d, startHour: 13, endHour: 22,
                          role: .dispatcher, desk: desk, leaveCode: nil, isOff: false)
            return ParsedWorker(id: id, name: "W\(id)", quals: ["D"], shifts: [s])
        }
        let genA = Date(timeIntervalSince1970: 1000)
        let genB = Date(timeIntervalSince1970: 2000)

        do {
            // Generation A becomes the live roster.
            try await act.insertGeneration([worker("1", "29"), worker("2", "30")], version: genA)
            let aRows = try await act.totalRows(generation: genA)
            check(aRows == 2, "ROSTER-ATOMIC: gen A has 2 rows (got \(aRows))")

            // MID-IMPORT: generation B rows land while readers are still pinned to gen A. The reader must
            // see the COMPLETE old generation, never a mix — this is the core atomicity guarantee.
            try await act.insertGeneration([worker("1", "99"), worker("2", "98")], version: genB)
            let aStill = try await act.totalRows(generation: genA)
            check(aStill == 2, "ROSTER-ATOMIC: gen A untouched while gen B mid-insert (got \(aStill))")
            let deskA = (try await act.schedule(forWorker: "1", generation: genA)).first?.desk
            check(deskA == "29", "ROSTER-ATOMIC: pre-swap reader sees OLD desk 29 (got \(deskA ?? "nil"))")

            // Swap complete → clean up the old generation.
            try await act.deleteOtherGenerations(keeping: genB)
            let bRows = try await act.totalRows(generation: genB)
            check(bRows == 2, "ROSTER-ATOMIC: gen B has 2 rows — NO cross-gen dupes (got \(bRows))")
            let aAfter = try await act.totalRows(generation: genA)
            check(aAfter == 0, "ROSTER-ATOMIC: gen A swept after cleanup (got \(aAfter))")
            let deskB = (try await act.schedule(forWorker: "1", generation: genB)).first?.desk
            check(deskB == "99", "ROSTER-ATOMIC: post-swap reader sees NEW desk 99 (got \(deskB ?? "nil"))")

            // Sentinel/migration invariant: rows written with the epoch default are visible to the epoch
            // reader (the seamless-upgrade path — pre-field rows stay visible with no wipe).
            let epoch = Date(timeIntervalSince1970: 0)
            try await act.insertGeneration([worker("9", "12")], version: epoch)
            let epochRows = try await act.totalRows(generation: epoch)
            check(epochRows == 1, "ROSTER-ATOMIC: epoch-default rows visible to the epoch reader (got \(epochRows))")
        } catch {
            fails.append("❌ ROSTER-ATOMIC: threw \(error)")
        }
        return fails
    }

    private static func balanced(_ a: [OptimalMatcher.Assignment]?) -> Bool {
        guard let a else { return false }
        return a.allSatisfy { $0.giveDayIDs.count == $0.takeDayIDs.count }
    }
}

#endif
