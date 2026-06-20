// EngineTests.swift
// A runnable self-test harness for the trade engine. There's no XCTest target, so
// these are plain assertions invokable from Developer Tools (Settings → Developer →
// "Run engine tests"). Returns the list of failures ([] = all pass). Covers the
// risky, pure logic: min-cost flow, the optimal reciprocal matcher (golden cases,
// balance, determinism, infeasibility), holiday math, and the pickup gate.

import Foundation

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
        Name (ID) Qualification,,Nov,,Nov,,Nov,
        ,,05,,06,,07,
        ,,Thu,,Fri,,Sat,
        ,"Test, T  (999999) D",21,,21,,21,
        ,,L,V,L,V,,
        """
        if let w = try? ScheduleParser().parseAllWorkers(csv: vacCSV).first(where: { $0.id == "999999" }) {
            let v05 = w.shifts.first { $0.id == "2026-11-05" }
            let v06 = w.shifts.first { $0.id == "2026-11-06" }
            let w07 = w.shifts.first { $0.id == "2026-11-07" }
            check(v05?.isOff == true && v05?.leaveCode == "V" && v05?.isVacation == true, "Vacation: 11-05 L|V → off + leaveCode V + isVacation")
            check(v06?.isOff == true && v06?.leaveCode == "V", "Vacation: 11-06 L|V → off + leaveCode V")
            check(w07?.isOff == false && w07?.startHour == 21 && w07?.leaveCode == nil,
                  "Vacation: 11-07 (no annotation) stays a normal working shift")
        } else {
            check(false, "Vacation: parser failed to return worker 999999")
        }

        // MARK: Vacation auto-intent (SPEC S-PARSE-2). A day flipping to vacation auto-
        // sets a SOFT, user-changeable Must-Be-Off + "vacation" note. Sentinel day, cleaned up.
        do {
            let vd = "2099-03-15"
            let store = DayIntentStore.shared
            let wasClean = store.offIntent(forDay: vd) == nil && store.note(forDay: vd) == nil
            let when = Date(timeIntervalSince1970: 4_080_000_000)
            let workShift = Shift(id: vd, date: when, startHour: 5, endHour: 14, role: .dispatcher, desk: "29", leaveCode: nil, isOff: false)
            let vacShift  = Shift(id: vd, date: when, startHour: 0, endHour: 0, role: .off, desk: "", leaveCode: "V", isOff: true)
            let vdiff = ScheduleDiff(added: [], removed: [],
                                     changed: [ScheduleDiff.ShiftChange(old: workShift, new: vacShift)],
                                     unchanged: [])
            _ = store.reconcile(diff: vdiff)
            check(store.offIntent(forDay: vd) == .mustBeOff, "Vacation: auto Must-Be-Off set on flip to vacation")
            check(store.note(forDay: vd)?.message == "vacation", "Vacation: auto note 'vacation' set")
            store.clearIntent(forDay: vd); store.setNote(nil, forDay: vd)   // cleanup
            check(wasClean, "Vacation: sentinel day was clean before the check")
        }

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
        check(sortedPosts.map(\.id) == ["pinnedOld", "old", "newest"], "pin: pinned first, then unpinned OLDEST→newest (E1 thread order)")

        // MARK: Brush completeness (F1). EVERY intent must be paintable — this is the
        // exact guard against "I thought the brush already covered it". A new enum case
        // with no brush fails here.
        // Off-day: brushes must cover ALL OffIntentState cases.
        check(Set(IntentBrushes.off) == Set(OffIntentState.allCases),
              "F1: off-day brushes cover every OffIntentState (\(OffIntentState.allCases.map(\.rawValue)))")
        // Working-day: the three meaningful intents are brushable (wantToWork is an off-day concept).
        check(Set(IntentBrushes.working) == Set([.dontWantToWork, .mustWork, .neutralOpen]),
              "F1: working brushes = Trade-away + Keep + Open (the working-day intents)")
        // Every brush has a non-empty human label (no blank pills).
        check(IntentBrushes.working.allSatisfy { !$0.label.isEmpty } && IntentBrushes.off.allSatisfy { !$0.label.isEmpty },
              "F1: every brush has a label")

        // MARK: A5 — fewest-people ranking (discharges ASSUMED_PRESENT #4). A single-person
        // full-cover tops the list; greedy ranks ahead of circular at equal people count.
        func pa(_ id: String) -> PackageAssignment { PackageAssignment(workerID: id, name: id, giveDayIDs: ["d1"], takeDayIDs: ["d2"]) }
        let solo  = TradePackage(id: "solo-A", methodology: .greedy, assignments: [pa("A")], route: nil, urgency: 0, isOptimal: true)
        let multi = TradePackage(id: "multi",  methodology: .greedy, assignments: [pa("A"), pa("B")], route: nil, urgency: 0)
        let route = NWayRoute(participants: ["me", "A", "B"], legs: [], tier: .matchingIntents, score: 0, usesBookends: false)
        let circ  = TradePackage(id: "circular-1", methodology: .circular, assignments: [pa("A"), pa("B")], route: route, urgency: 0)
        let ranked = TradeRouter.rankPackages([circ, multi, solo])
        check(ranked.first?.id == "solo-A", "A5: single-person full-cover sorts to the very top")
        check(ranked.map(\.peopleCount) == [2, 3, 3], "A5: fewest people first (solo=2, others=3)")
        check(ranked[1].methodology == .greedy && ranked[2].methodology == .circular, "A5: greedy before circular at equal people")

        // MARK: U4 — priority sort (🔥+bookends → 🔥 → bookends-only) + bookends-only top-two-bands cap.
        func pkg(_ id: String, people: Int, fire: Int, book: Int) -> TradePackage {
            let a = (1..<people).map { pa("P\($0)") }   // people-1 counterparties + you = `people`
            return TradePackage(id: id, methodology: .greedy, assignments: a, route: nil,
                                urgency: 0, isOptimal: false, fireCount: fire, bookendTotal: book)
        }
        // All N=2 so the tier ordering is the discriminator.
        let fireBook = pkg("fb", people: 2, fire: 2, book: 3)   // 🔥 + bookends → tier 0
        let fireOnly = pkg("fo", people: 2, fire: 1, book: 0)   // 🔥 only → tier 1
        let bookHi   = pkg("b3", people: 2, fire: 0, book: 3)   // bookends-only, max band
        let bookMid  = pkg("b2", people: 2, fire: 0, book: 2)   // bookends-only, max-1 band
        let bookLo   = pkg("b1", people: 2, fire: 0, book: 1)   // bookends-only, below cap → dropped
        let u4 = TradeRouter.rankPackages([bookLo, bookMid, bookHi, fireOnly, fireBook])
        check(u4.map(\.id).prefix(2).elementsEqual(["fb", "fo"]),
              "U4: 🔥+bookends first, then 🔥-only")
        check(u4.contains { $0.id == "b3" } && u4.contains { $0.id == "b2" },
              "U4: bookends-only top two bands (3 and 2) are kept")
        check(!u4.contains { $0.id == "b1" },
              "U4: bookends-only below max-1 (band 1) is filtered out")
        // N grouping dominates tiers: a fewer-people bookends-only beats a more-people 🔥.
        let nGroup = TradeRouter.rankPackages([pkg("fire3", people: 3, fire: 5, book: 5),
                                               pkg("book2", people: 2, fire: 0, book: 1)])
        check(nGroup.first?.id == "book2", "U4: fewest-people (N) grouping dominates the tier priority")
        // MARK: #4 — a 2-person package is NEVER circular (circular needs ≥3); #4b — earliest-date tiebreak.
        let route2 = NWayRoute(participants: ["me", "A"], legs: [], tier: .matchingIntents, score: 0, usesBookends: false)
        let twoCirc = TradePackage(id: "c2", methodology: .circular, assignments: [pa("A")], route: route2)
        check(!twoCirc.isCircular, "#4: a 2-participant package is not circular (a 2-cycle is a 2-way swap)")
        let route3 = NWayRoute(participants: ["me", "A", "B"], legs: [], tier: .matchingIntents, score: 0, usesBookends: false)
        let threeCirc = TradePackage(id: "c3", methodology: .circular, assignments: [pa("A"), pa("B")], route: route3)
        check(threeCirc.isCircular, "#4: a 3-participant circular IS circular")
        // #4b: equal on N/🔥/bookends, the earlier-dated trade sorts first — even past the alphabetical id tiebreak.
        let earlyPkg = TradePackage(id: "zzz", methodology: .greedy,
                                    assignments: [PackageAssignment(workerID: "A", name: "A", giveDayIDs: ["2026-07-01"], takeDayIDs: ["2026-07-02"])],
                                    route: nil)
        let latePkg = TradePackage(id: "aaa", methodology: .greedy,
                                   assignments: [PackageAssignment(workerID: "B", name: "B", giveDayIDs: ["2026-12-01"], takeDayIDs: ["2026-12-02"])],
                                   route: nil)
        let dateRanked = TradeRouter.rankPackages([latePkg, earlyPkg])
        check(dateRanked.first?.id == "zzz", "#4b: earlier-dated trade sorts first (beats alphabetical id)")

        // Q1: a qual-swap package (0 bookends) is EXEMPT from the bookends-only cap — never hidden.
        var qsPkg = pkg("qs", people: 2, fire: 0, book: 0)
        qsPkg.qualSwap = QualSwapLegData(giveShiftDayID: "d", giveDesk: "50", giveQual: "E",
                                         takerID: "B", takerName: "B",
                                         candidates: [QualSwapCandidate(workerID: "C", name: "C", desk: "10", qual: "D")])
        let qsRank = TradeRouter.rankPackages([pkg("b3", people: 2, fire: 0, book: 3), qsPkg])
        check(qsRank.contains { $0.id == "qs" }, "Q1: a qual-swap package survives the bookends-only cap (exempt)")

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
        // C5: like C1 but values E=1 < D=2 → won't accept the move → excluded.
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
        check(bridges.map(\.workerID) == ["C1"], "S-ENG-4: only the qualified, same-hour, willing bridge (C1) returns")
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

        // MARK: Q2 — bridge→candidate adapter (derives the freed desk's qual).
        let adapterCand = QualSwap.candidate(from: QualSwapShift(workerID: "C9", name: "C9", desk: "50", startHour: 5, quals: ["D", "E"]))
        check(adapterCand.workerID == "C9" && adapterCand.desk == "50" && adapterCand.qual == "E",
              "Q2-adapter: bridge→candidate derives the freed desk's qual (50→E)")

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
        // (b) WEEKLY CAP: a 9h cap with one worked day in the week → +9 = 18 > 9 → fails under .full only.
        let capProfile = TradeProfile(workerID: "cov", displayName: "Cov", openness: "all",
                                      blacklistedWeekdays: [], blacklistedDesks: [], blacklistedShiftTypes: [],
                                      blacklistedRegions: [], seekingDayIDs: [], updatedAt: Date(), maxWeeklyHours: 9)
        check(!TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                         coverMap: covMap, coverQuals: ["D"], coverProfile: capProfile, options: .full).eligible,
              "U1-cap: weekly-cap breach → ineligible under .full")
        check(TradeEligibility.canCover(coverDayID: "2026-07-15", coverDay: d15, desk: "10", startHour: 5,
                                        coverMap: covMap, coverQuals: ["D"], coverProfile: capProfile, options: .physicalOnly).eligible,
              "U1-cap: .physicalOnly ignores the weekly cap")
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

        // MARK: #3 — a separate two-person trade always outranks a three-person circular loop
        // (Intents prefers individual pairwise trades; loops sink below them).
        do {
            let two = TradePackage(id: "two", methodology: .greedy,
                                   assignments: [PackageAssignment(workerID: "A", name: "A", giveDayIDs: ["d"], takeDayIDs: ["e"])], route: nil)
            let loop = TradePackage(id: "loop", methodology: .circular,
                                    assignments: [PackageAssignment(workerID: "A", name: "A", giveDayIDs: ["d"], takeDayIDs: []),
                                                  PackageAssignment(workerID: "B", name: "B", giveDayIDs: ["f"], takeDayIDs: [])],
                                    route: nil, fireCount: 9)
            check(TradeRouter.rankPackages([loop, two]).first?.id == "two",
                  "#3: a two-person trade outranks a three-person loop even when the loop has more 🔥")
        }

        // MARK: D5 — qual-swap packages sort UNDER clean ones for the SAME N (regardless of 🔥/
        // bookend); usual priorities apply WITHIN each group; people-count still dominates.
        do {
            func pkg(_ id: String, peers: [String], fire: Int, qual: Bool) -> TradePackage {
                let a = peers.map { PackageAssignment(workerID: $0, name: $0, giveDayIDs: ["2027-02-01"], takeDayIDs: ["2027-02-02"]) }
                let q: QualSwapLegData? = qual ? QualSwapLegData(giveShiftDayID: "2027-02-01", giveDesk: "50",
                        giveQual: "E", takerID: peers.first ?? "A", takerName: peers.first ?? "A", candidates: []) : nil
                return TradePackage(id: id, methodology: .greedy, assignments: a, route: nil,
                                    fireCount: fire, bookendTotal: 0, qualSwap: q)
            }
            let r1 = TradeRouter.rankPackages([pkg("qual", peers: ["A"], fire: 5, qual: true),
                                               pkg("clean", peers: ["B"], fire: 0, qual: false)])
            check(r1.first?.id == "clean", "D5: clean 2-way sorts above a qual-swap 2-way even with more 🔥")
            let r2 = TradeRouter.rankPackages([pkg("qlow", peers: ["A"], fire: 1, qual: true),
                                               pkg("qhigh", peers: ["C"], fire: 9, qual: true)])
            check(r2.first?.id == "qhigh", "D5: within the qual group, more 🔥 sorts first (usual priorities)")
            let r3 = TradeRouter.rankPackages([pkg("clean3", peers: ["A", "B"], fire: 9, qual: false),
                                               pkg("qual2", peers: ["C"], fire: 0, qual: true)])
            check(r3.first?.id == "qual2", "D5: people-count dominates — a qual 2-way precedes a clean 3-way")
        }

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
            let base = LegFeatures(bookend: false, split: false, mutualFire: false, giverWants: false,
                                   receiverWants: false, timeValue: 0, needsQualBridge: false, hoursStrain: 0)
            var book = base; book.bookend = true
            var split = base; split.split = true
            var fire = base; fire.mutualFire = true
            check(TradeScore.legProb(book) > TradeScore.legProb(base), "H1: a bookend leg is more likely accepted")
            check(TradeScore.legProb(split) < TradeScore.legProb(base), "H1: a split leg is less likely accepted")
            check(TradeScore.legProb(fire) > TradeScore.legProb(base), "H1: a mutual-🔥 leg is more likely accepted")
            check((0...1).contains(TradeScore.legProb(base)), "H1: legProb is a probability in [0,1]")
            // package = product of leg probs; logProb = sum of logs.
            let legs = [book, fire, split]
            let prod = TradeScore.packageProb(legs)
            let viaLog = exp(TradeScore.packageLogProb(legs))
            check(abs(prod - viaLog) < 1e-9, "H1: packageLogProb == log of the product (consistent)")
            // weakest-link: one bad (split) leg tanks the joint probability below all-good.
            check(TradeScore.packageProb([book, fire]) > TradeScore.packageProb([book, fire, split]),
                  "H1: a split leg drags the whole package's joint probability down")
            // admissible prune bound: adding legs never RAISES the log-prob (each log p ≤ 0).
            check(TradeScore.packageLogProb([book]) >= TradeScore.packageLogProb([book, fire]) - 1e-12,
                  "H1: partial-route log-prob is an admissible upper bound (monotone non-increasing)")
            // ECB lever: more points offered → higher acceptance.
            var ecbLo = base; ecbLo.ecbValue = 0.1
            var ecbHi = base; ecbHi.ecbValue = 0.9
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
            check(SearchFilter(engine: .both, maxPeople: 2, requiredWorkerID: nil).filter(pkgs).allSatisfy { $0.peopleCount <= 2 },
                  "A2: maxPeople caps participant count")
            check(SearchFilter(engine: .both, maxPeople: 4, requiredWorkerID: nil).filter(pkgs).count == 3, "A2: maxPeople 4 keeps all")
            check(SearchFilter(engine: .minCost, maxPeople: 4, requiredWorkerID: nil).filter(pkgs).allSatisfy { $0.methodology != .circular },
                  "A2: minCost engine drops circular")
            check(SearchFilter(engine: .nWay, maxPeople: 4, requiredWorkerID: nil).filter(pkgs).allSatisfy { $0.methodology == .circular },
                  "A2: nWay engine keeps only circular")
            let req = SearchFilter(engine: .both, maxPeople: 4, requiredWorkerID: "C").filter(pkgs)
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

            // Intent-first ranking: a 3-person package with MORE mutual intent outranks a 2-person with less.
            func pkg(_ id: String, people: Int, fire: Int) -> TradePackage {
                let others = (1..<people).map { PackageAssignment(workerID: "\(id)-\($0)", name: "n", giveDayIDs: ["d"], takeDayIDs: ["e"]) }
                var p = TradePackage(id: id, methodology: .greedy, assignments: others, route: nil)
                p.fireCount = fire; return p
            }
            let ranked = TradeRouter.rankIntentPackages([pkg("two", people: 2, fire: 1), pkg("three", people: 3, fire: 3)])
            check(ranked.first?.id == "three", "Intents: MOST mutual intent ranks first, even with more people (vs Trade Solutions' fewest-people-first)")

            // H2: person-prior — neutral at no history; +/- with accept/decline; clamped; weights the logit.
            check(PersonPrior.logOdds(accepted: 0, declined: 0) == 0, "H2: no history → neutral prior (0)")
            check(PersonPrior.logOdds(accepted: 5, declined: 0) > 0, "H2: a history of accepting → positive prior")
            check(PersonPrior.logOdds(accepted: 0, declined: 5) < 0, "H2: a history of declining → negative prior")
            check(PersonPrior.logOdds(accepted: 1000, declined: 0) <= 2.0001, "H2: prior is clamped (thin/extreme record can't dominate)")
            var fHi = LegFeatures(bookend: false, split: false, mutualFire: false, giverWants: false,
                                  receiverWants: false, timeValue: 0.5, needsQualBridge: false, hoursStrain: 0)
            var fLo = fHi; fHi.personPrior = 1.5; fLo.personPrior = -1.5
            check(TradeScore.legProb(fHi) > TradeScore.legProb(fLo), "H2: a higher person-prior raises the leg's acceptance probability")

            // H2 tiebreaker: equal intent/people/bookends → the higher partnerPrior package ranks first.
            var pa = pkg("low", people: 2, fire: 2); pa.partnerPrior = -0.5
            var pb = pkg("high", people: 2, fire: 2); pb.partnerPrior = 0.5
            check(TradeRouter.rankIntentPackages([pa, pb]).first?.id == "high", "H2: all else equal, the likelier-to-accept partner ranks first")

            // Cap: intentSolutions surfaces only the top-N highest-scoring (unprofiled/low matches trimmed).
            check(TradeRouter.intentResultCap == 20, "Intents: results capped at the top 20")
            let many = (0..<50).map { pkg("p\($0)", people: 2, fire: $0 % 5) }
            check(Array(TradeRouter.rankIntentPackages(many).prefix(TradeRouter.intentResultCap)).count == 20,
                  "Intents: ranking + cap yields at most 20")

            // TradeScore instrumentation: COMPUTED + monotone, but NOT a ranking input (collects, doesn't decide).
            check(TradeScore.packageScore(legCount: 2, fireCount: 2, bookendTotal: 2, partnerPrior: 0)
                  > TradeScore.packageScore(legCount: 2, fireCount: 0, bookendTotal: 0, partnerPrior: 0),
                  "TradeScore: more 🔥/bookends → higher acceptance log-prob")
            check(TradeScore.packageScore(legCount: 0, fireCount: 0, bookendTotal: 0, partnerPrior: 0) == 0,
                  "TradeScore: empty package → 0 (log 1)")
            // Two packages identical except acceptanceScore must tie to id order — proving the score
            // never changes the ranking (it appears in NEITHER comparator).
            var sLo = pkg("aaa", people: 2, fire: 1); sLo.acceptanceScore = -9
            var sHi = pkg("bbb", people: 2, fire: 1); sHi.acceptanceScore = 0
            check(TradeRouter.rankIntentPackages([sHi, sLo]).first?.id == "aaa",
                  "TradeScore: acceptanceScore does NOT affect ranking (ties fall to id, not score)")

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

        // MARK: E1 — channel reads top-to-bottom (oldest → newest); pinned still first.
        do {
            func post(_ id: String, at: TimeInterval, pinned: Bool? = nil) -> BroadcastPost {
                BroadcastPost(id: id, authorID: "x", authorName: "x", text: "t",
                              createdAt: Date(timeIntervalSince1970: at), expiresAt: Date(timeIntervalSince1970: at + 86400),
                              pinned: pinned)
            }
            let ordered = MessagingStore.sortedForChannel([post("new", at: 300), post("old", at: 100), post("mid", at: 200)])
            check(ordered.map(\.id) == ["old", "mid", "new"], "E1: channel posts read oldest→newest (top to bottom)")
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

        return fails
    }

    private static func balanced(_ a: [OptimalMatcher.Assignment]?) -> Bool {
        guard let a else { return false }
        return a.allSatisfy { $0.giveDayIDs.count == $0.takeDayIDs.count }
    }
}

#endif
