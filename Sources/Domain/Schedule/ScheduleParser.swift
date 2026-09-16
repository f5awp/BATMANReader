// ScheduleParser.swift
// Parses the ARIS/WorkNet "Expanded Schedule" CSV export into Shift objects.
//
// G4: ImportAudit — a PURE post-import sanity check. After any roster/schedule import we validate
// the parsed workers and surface a pass/warn report, so a malformed/partial import (e.g. rows with
// no name → the "660615" display bug) is caught and reported instead of silently shipping bad data.

import Foundation

/// Result of `ImportAudit.validate` — advisory (never blocks the import).
struct ImportReport {
    var ok: Bool
    var workerCount: Int
    var namelessWorkers: [String]   // employee IDs whose parsed name is missing/blank/numeric/==id
    var duplicateIDs: [String]
    var selfFound: Bool
    var warnings: [String]          // human-readable messages for the import banner
}

enum ImportAudit {
    /// Validate the parsed (id, name) list against `selfID`. Pure → fully harness-tested.
    static func validate(workers: [(id: String, name: String)], selfID: String) -> ImportReport {
        var nameless: [String] = []
        var seen = Set<String>(), dupes = Set<String>()
        for w in workers {
            let n = w.name.trimmingCharacters(in: .whitespaces)
            if n.isEmpty || n == w.id || TradeNames.isAllDigits(n) { nameless.append(w.id) }   // reuse G2a's "real name" rule
            if !seen.insert(w.id).inserted { dupes.insert(w.id) }
        }
        let selfFound = workers.contains { $0.id == selfID }
        var warnings: [String] = []
        if workers.isEmpty { warnings.append("No dispatchers were parsed — the file may be the wrong format.") }
        if !nameless.isEmpty { warnings.append("\(nameless.count) dispatcher(s) imported with no name (showing employee #). Check the report's name column.") }
        if !dupes.isEmpty { warnings.append("\(dupes.count) duplicate employee ID(s) in the import.") }
        if !selfFound && !selfID.isEmpty { warnings.append("Your employee ID (\(selfID)) wasn't found in this import.") }
        return ImportReport(ok: warnings.isEmpty, workerCount: workers.count,
                            namelessWorkers: nameless, duplicateIDs: Array(dupes),
                            selfFound: selfFound, warnings: warnings)
    }
}
//
// The CSV is a visual calendar GRID, not a row-per-shift table:
//   • Each month-strip begins with a header row ("Name (ID) Qualification, ,Jan, ,Jan,…"),
//     followed by a day-number row (" , ,01, ,02,…"), a weekday row, then one row
//     per worker.
//   • Each WORKING day occupies two columns: [start, desk]. An OFF day is "OFF".
//   • The export occasionally drops a separator, so columns are NOT a fixed
//     2-per-day stride. The dropped column is dropped from EVERY row of the strip
//     together, so we align each value to the day-number row by shared column INDEX.
//   • Strips are NOT always in chronological order and the tail can contain
//     overlapping/duplicate strips. So we do NOT track year via month rollover —
//     instead we resolve each day's YEAR from its own weekday (a date + weekday is
//     unique to a year near the present), then de-duplicate by date.
//
// A worker row's name cell looks like `Lee, Ervin  (292216) D, L` — name, the
// employee ID in parentheses, then that person's qualification codes.

import Foundation

enum ScheduleParserError: LocalizedError {
    case empty
    case workerNotFound
    case noShiftsParsed

    var errorDescription: String? {
        switch self {
        case .empty:          return "No CSV content was provided."
        case .workerNotFound: return "Could not find your row in the report. Check the employee ID in Settings."
        case .noShiftsParsed: return "Found your row but parsed no shifts — the report format may have changed."
        }
    }
}

/// One dispatcher parsed from the roster, with their identity and full schedule.
struct ParsedWorker: Identifiable {
    let id: String          // employee ID, e.g. "292216"
    let name: String        // "Lee, Ervin"
    let quals: [String]     // ["D", "L"] — qualification codes
    let shifts: [Shift]     // de-duplicated, sorted ascending (includes OFF days)
}

final class ScheduleParser {

    private static let headerKey = "Name (ID) Qualification"

    private static let monthMap: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
    ]

    private static let weekdayMap: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7
    ]

    /// One printed shift-line's value for a single day, before resolution. The expanded schedule prints
    /// TWO stacked shift lines per worker (a base/vacation-placeholder line and an actually-worked line),
    /// each with its own `L,V`/`L,w` annotation row. Overlapping strips repeat these. We collect EVERY
    /// copy per day, then `resolveDay` picks the truth. (S-PARSE-1 / B6-VAC-2LINE.)
    struct DayCandidate: Equatable {
        let startHour: Int?       // nil ⇒ OFF / blank
        let desk: String
        let isVacationLeave: Bool // this line carries L,V or L,w for this day
        let vacationCode: String? // "V" or "w" when isVacationLeave
        let otherLeaveCode: String? // a non-vacation leave code (S/R/…) recorded but inert
    }

    // Mutable per-worker accumulator used while scanning the grid.
    private final class WorkerAcc {
        let id: String
        let name: String
        let quals: [String]
        /// dayID → (date, all printed candidates from every line & every overlapping strip).
        var dayCands: [String: (date: Date, cands: [DayCandidate])] = [:]
        var lastYear: Int
        init(id: String, name: String, quals: [String], year: Int) {
            self.id = id; self.name = name; self.quals = quals; self.lastYear = year
        }
    }

    // MARK: - Public API

    /// Parses EVERY dispatcher out of the expanded-schedule CSV (the full roster).
    func parseAllWorkers(csv: String) throws -> [ParsedWorker] {
        guard !csv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScheduleParserError.empty
        }

        let rows = csv
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { Self.parseCSVLine($0) }

        let calendar = Calendar.current
        let now = calendar.component(.year, from: Date())
        // Rolling read window ANCHORED TO TODAY (not the calendar year) so it always slides
        // forward with cushion: the prior 6 months of history plus the next 24 months. A newly
        // posted annual schedule can run ~16 months out, so a forward cushion of 2 years keeps the
        // whole thing in range no matter what month the master is uploaded. Days outside it are ignored.
        let today = calendar.startOfDay(for: Date())
        let windowLower = calendar.date(byAdding: .month, value: -6, to: today) ?? .distantPast
        let windowUpper = calendar.date(byAdding: .month, value: 24, to: today) ?? .distantFuture  // exclusive

        var monthRow:   [String] = []
        var dayRow:     [String] = []
        var weekdayRow: [String] = []
        var yearCache:  [String: Int] = [:]

        var accs:  [String: WorkerAcc] = [:]
        var order: [String] = []

        var i = 0
        while i < rows.count {
            let row = rows[i]

            // A new month-strip: capture its month / day / weekday header rows.
            if field(row, 0).trimmed == Self.headerKey {
                monthRow   = row
                dayRow     = (i + 1 < rows.count) ? rows[i + 1] : []
                weekdayRow = (i + 2 < rows.count) ? rows[i + 2] : []
                i += 1
                continue
            }

            // A worker shift row — its name cell carries "(employeeID)".
            // (The 2nd "OFF" line and annotation rows have an empty name cell.)
            if !dayRow.isEmpty, let who = Self.workerIdentity(field(row, 1)) {
                let acc: WorkerAcc
                if let existing = accs[who.id] {
                    acc = existing
                } else {
                    acc = WorkerAcc(id: who.id, name: who.name, quals: who.quals, year: now)
                    accs[who.id] = acc
                    order.append(who.id)
                }
                // Gather this worker's annotation sub-rows (empty name cell, not a strip
                // header). They carry leave codes ("L" + code) aligned to the SAME day
                // spine. See SPEC_STRUCTURAL.md S-PARSE-1.
                var annRows: [[String]] = []
                var j = i + 1
                while j < rows.count {
                    let r = rows[j]
                    if field(r, 0).trimmed == Self.headerKey { break }
                    if Self.workerIdentity(field(r, 1)) != nil { break }
                    annRows.append(r); j += 1
                }
                collectCandidates(into: &acc.dayCands,
                                  shiftRow: row, subRows: annRows,
                                  monthRow: monthRow, dayRow: dayRow, weekdayRow: weekdayRow,
                                  now: now, windowLower: windowLower, windowUpper: windowUpper,
                                  lastYear: &acc.lastYear, yearCache: &yearCache)
            }
            i += 1
        }

        return order.compactMap { id in
            guard let acc = accs[id] else { return nil }
            let shifts = acc.dayCands
                .map { (dayID, v) in Self.resolveDay(v.cands, date: v.date, dayID: dayID) }
                .sorted { $0.date < $1.date }
            return ParsedWorker(id: acc.id, name: acc.name, quals: acc.quals, shifts: shifts)
        }
    }

    /// THE single source of truth for a day's real shift, given every printed candidate (both stacked
    /// lines, across all overlapping strips). Rule discovered from real data (Gar 523734 Jul 20-23, Ervin
    /// 292216 Jul 26-29, both user-confirmed):
    ///   • A `V`/`w` line is the VACATION PLACEHOLDER (base rotation) — never proof of work.
    ///   • A **worked pickup** = a non-vacation desk that isn't ALSO a vacation/base desk that day → the
    ///     shift actually worked (on a foreign desk), even on a vacation day.
    ///   • Otherwise, if any vacation line exists → OFF (genuine vacation). A day where the only non-`V`
    ///     desk equals a `V` desk (a dropped annotation on a duplicate strip) stays OFF — safe.
    ///   • No vacation anywhere → the normal printed shift (or OFF).
    /// This subsumes the old dedup / mergeDuplicate / resolveVacations pipeline. PURE / fixture-tested.
    static func resolveDay(_ cands: [DayCandidate], date: Date, dayID: String) -> Shift {
        let reals = cands.filter { $0.startHour != nil }
        func off(_ leave: String?) -> Shift {
            Shift(id: dayID, date: date, startHour: 0, endHour: 0, role: .off, desk: "",
                  leaveCode: leave, isOff: true)
        }
        guard !reals.isEmpty else {
            let leave = cands.compactMap { $0.vacationCode }.first ?? cands.compactMap { $0.otherLeaveCode }.first
            return off(leave)
        }
        let vDesks = Set(reals.filter { $0.isVacationLeave }.map { $0.desk })
        let pickups = reals.filter { !$0.isVacationLeave && !vDesks.contains($0.desk) }
        if let chosen = Self.dominant(pickups) {
            let sh = chosen.startHour ?? 0
            return Shift(id: dayID, date: date, startHour: sh, endHour: (sh + 9) % 24,
                         role: Self.role(forDesk: chosen.desk), desk: chosen.desk,
                         leaveCode: chosen.otherLeaveCode, isOff: false)   // a clean worked shift (leave placeholder dropped)
        }
        // No pickup → genuine vacation if any vacation line printed a shift; else plain OFF.
        if reals.contains(where: { $0.isVacationLeave }) {
            return off(reals.first(where: { $0.isVacationLeave })?.vacationCode ?? "V")
        }
        // No vacation involved at all — a normal working day.
        if let chosen = Self.dominant(reals) {
            let sh = chosen.startHour ?? 0
            return Shift(id: dayID, date: date, startHour: sh, endHour: (sh + 9) % 24,
                         role: Self.role(forDesk: chosen.desk), desk: chosen.desk,
                         leaveCode: chosen.otherLeaveCode, isOff: false)
        }
        return off(nil)
    }

    /// The most-supported candidate (by desk frequency), deterministic tiebreak on desk string, so
    /// overlapping duplicate strips resolve identically every run.
    private static func dominant(_ cands: [DayCandidate]) -> DayCandidate? {
        guard !cands.isEmpty else { return nil }
        var count: [String: Int] = [:]
        for c in cands { count[c.desk, default: 0] += 1 }
        let bestDesk = count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first!.key
        return cands.first { $0.desk == bestDesk }
    }

    /// Parses a single worker's schedule (convenience over `parseAllWorkers`).
    func parse(csv: String, targetWorkerID: String) throws -> [Shift] {
        let workers = try parseAllWorkers(csv: csv)
        guard let worker = workers.first(where: { $0.id == targetWorkerID }) else {
            throw ScheduleParserError.workerNotFound
        }
        guard !worker.shifts.isEmpty else { throw ScheduleParserError.noShiftsParsed }
        return worker.shifts
    }

    // MARK: - Row → per-day candidates (day-number row is the alignment spine)

    /// Collects EVERY printed candidate for each day in this strip: the worker's primary shift line PLUS any
    /// stacked second shift line (the export prints a base/vacation-placeholder line and a worked line),
    /// each paired with its OWN annotation rows. `resolveDay` later picks the real shift across all copies.
    private func collectCandidates(into dayCands: inout [String: (date: Date, cands: [DayCandidate])],
                                   shiftRow: [String],
                                   subRows: [[String]],
                                   monthRow: [String],
                                   dayRow: [String],
                                   weekdayRow: [String],
                                   now: Int,
                                   windowLower: Date,
                                   windowUpper: Date,
                                   lastYear: inout Int,
                                   yearCache: inout [String: Int]) {

        let calendar = Calendar.current
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"

        // Day columns of THIS strip — used to classify each sub-row as a SHIFT line (has OFF / a start hour)
        // vs an ANNOTATION line (has "L"). A worker block is [shiftA][annA…][shiftB][annB…]; each annotation
        // row belongs to the shift line directly above it.
        let dayCols = (0..<dayRow.count).filter { (Int(dayRow[$0].trimmed).map { (1...31).contains($0) }) ?? false }
        func isAnnRow(_ r: [String]) -> Bool { dayCols.contains { field(r, $0).trimmed == "L" } }
        func isShiftRow(_ r: [String]) -> Bool {
            dayCols.contains { let v = field(r, $0).trimmed; return v.uppercased() == "OFF" || Int(v) != nil }
        }
        var lines: [(row: [String], anns: [[String]])] = [(shiftRow, [])]
        for r in subRows {
            if isAnnRow(r) { lines[lines.count - 1].anns.append(r) }
            else if isShiftRow(r) { lines.append((r, [])) }
            // else: fully-empty spacer → ignore.
        }

        for index in 0..<dayRow.count {
            guard let day = Int(dayRow[index].trimmed), (1...31).contains(day) else { continue }
            guard let month = Self.monthMap[field(monthRow, index).trimmed.lowercased()] else { continue }

            // Resolve the year from this day's weekday — robust to out-of-order / overlapping strips.
            let weekday = Self.weekdayMap[String(field(weekdayRow, index).trimmed.lowercased().prefix(3))]
            let year = Self.resolveYear(month: month, day: day, weekday: weekday,
                                        near: now, cache: &yearCache) ?? lastYear
            lastYear = year

            var comps = DateComponents(); comps.year = year; comps.month = month; comps.day = day
            guard let date = calendar.date(from: comps) else { continue }
            guard date >= windowLower, date < windowUpper else { continue }   // rolling 15-month window
            let id = iso.string(from: date)

            // Desk sits in the next column, unless that column is itself a day column (dropped separator).
            let deskColumnIsGap = (index + 1 >= dayRow.count) || dayRow[index + 1].trimmed.isEmpty

            var entry = dayCands[id] ?? (date, [])
            entry.date = date
            for line in lines {
                let startToken = field(line.row, index).trimmed
                let startHour = Int(startToken)
                let desk = deskColumnIsGap ? field(line.row, index + 1).trimmed : ""
                // This line's leave code for this day, from ITS OWN annotation rows.
                var vacationCode: String? = nil
                var otherLeave: String? = nil
                for ann in line.anns where field(ann, index).trimmed == "L" {
                    let code = field(ann, index + 1).trimmed
                    guard !code.isEmpty else { continue }
                    if Shift.vacationLeaveCodes.contains(code) { vacationCode = code } else { otherLeave = code }
                    break
                }
                entry.cands.append(DayCandidate(startHour: startHour, desk: desk,
                                                isVacationLeave: vacationCode != nil,
                                                vacationCode: vacationCode, otherLeaveCode: otherLeave))
            }
            dayCands[id] = entry
        }
    }

    // MARK: - Helpers

    /// Extracts `(id, name, quals)` from a name cell like `Lee, Ervin  (292216) D, L`.
    /// Returns nil for header / annotation / blank cells (no parenthesised ID).
    /// Canonicalizes the raw qualification tokens from the master schedule into the codes the trade
    /// engine actually gates on. The master spells some quals out ("Ops") and mixes in pay-status and
    /// legend noise; the engine's desk rules key on single letters. This is the ONE place quals are
    /// cleaned, so both the roster and the user's own `cachedQuals` see canonical codes.
    ///   • Ops → O            (Ops Coordinator; the desk rule requires "O")
    ///   • I → I              (IROPS — a special Ops-Coordinator selection; its own qual/desk gate)
    ///   • D/E/L/P/A/R/S kept (region + coordinator quals used verbatim by the desk rules)
    ///   • J (OJT Trainer), F (training-complete marker) kept — valid quals, gate no desk
    ///   • MAX/MAXPAY/MAXX (pay status), NO/QUALIFICATIONS ("NO QUALIFICATIONS" legend), Z (retired
    ///     Flight Keys SME) dropped — not real trading quals
    ///   • anything unrecognized is kept verbatim, so a future qual is never silently lost
    static func canonicalizeQuals(_ raw: [String]) -> [String] {
        let drop: Set<String> = ["MAX", "MAXPAY", "MAXX", "NO", "QUALIFICATIONS", "Z"]
        var out: [String] = []
        var seen = Set<String>()
        for token in raw {
            let t = token.uppercased()
            if drop.contains(t) { continue }
            let canonical = (t == "OPS") ? "O" : t
            if seen.insert(canonical).inserted { out.append(canonical) }
        }
        return out
    }

    private static func workerIdentity(_ cell: String) -> (id: String, name: String, quals: [String])? {
        guard let open = cell.firstIndex(of: "("),
              let close = cell[cell.index(after: open)...].firstIndex(of: ")") else { return nil }
        let idStr = String(cell[cell.index(after: open)..<close])
        guard idStr.count >= 4, idStr.allSatisfy(\.isNumber) else { return nil }
        let name  = String(cell[..<open]).trimmingCharacters(in: .whitespaces)
        let rawQuals = String(cell[cell.index(after: close)...])
            .split { $0 == "," || $0 == " " }
            .map(String.init)
            .filter { !$0.isEmpty }
        return (idStr, name, canonicalizeQuals(rawQuals))
    }

    /// Finds the year (nearest to `now`) in which `month/day` falls on `weekday`.
    private static func resolveYear(month: Int, day: Int, weekday: Int?,
                                    near now: Int, cache: inout [String: Int]) -> Int? {
        guard let weekday else { return nil }
        let key = "\(month)-\(day)-\(weekday)"
        if let cached = cache[key] { return cached }

        let calendar = Calendar.current
        for offset in [0, 1, -1, 2, -2, 3, -3] {
            var c = DateComponents()
            c.year = now + offset; c.month = month; c.day = day
            if let d = calendar.date(from: c), calendar.component(.weekday, from: d) == weekday {
                cache[key] = now + offset
                return now + offset
            }
        }
        return nil
    }

    /// Classifies a desk code into a role — used only for UI colouring/badges.
    private static func role(forDesk desk: String) -> ShiftRole {
        let d = desk.uppercased()
        if d.isEmpty            { return .dispatcher }
        if d.hasPrefix("OJT")   { return .ojt }
        if d.hasPrefix("RC")    { return .routeCheck }
        if d.hasPrefix("A")     { return .atc }                  // ATC coordinator desks A1–A6
        if d.hasPrefix("C") || d.hasPrefix("I") { return .ops }  // Ops coordinator desks
        return .dispatcher
    }

    private func field(_ row: [String], _ index: Int) -> String {
        (index >= 0 && index < row.count) ? row[index] : ""
    }

    /// Minimal RFC-4180 line parser: handles quoted fields with embedded commas
    /// (e.g. `"Lee, Ervin  (292216) D, L"`) and escaped double-quotes.
    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: idx)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\"")   // escaped quote
                        idx = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",":  fields.append(current); current = ""
                default:   current.append(ch)
                }
            }
            idx = line.index(after: idx)
        }
        fields.append(current)
        return fields
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
