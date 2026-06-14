// ScheduleParser.swift
// Parses the ARIS/WorkNet "Expanded Schedule" CSV export into Shift objects.
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

    // Mutable per-worker accumulator used while scanning the grid.
    private final class WorkerAcc {
        let id: String
        let name: String
        let quals: [String]
        var shifts: [Shift] = []
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
        // Rolling 15-month read window: the current full calendar year, plus the
        // prior December and the following Jan–Feb. Days outside it are ignored.
        let windowLower = calendar.date(from: DateComponents(year: now - 1, month: 12, day: 1)) ?? .distantPast
        let windowUpper = calendar.date(from: DateComponents(year: now + 1, month: 3,  day: 1)) ?? .distantFuture  // exclusive

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
                appendShifts(into: &acc.shifts,
                             shiftRow: row, monthRow: monthRow, dayRow: dayRow, weekdayRow: weekdayRow,
                             now: now, windowLower: windowLower, windowUpper: windowUpper,
                             lastYear: &acc.lastYear, yearCache: &yearCache)
            }
            i += 1
        }

        return order.compactMap { id in
            guard let acc = accs[id] else { return nil }
            return ParsedWorker(id: acc.id, name: acc.name, quals: acc.quals, shifts: Self.dedup(acc.shifts))
        }
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

    // MARK: - Row → shifts (day-number row is the alignment spine)

    private func appendShifts(into shifts: inout [Shift],
                              shiftRow: [String],
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

        for index in 0..<dayRow.count {
            guard let day = Int(dayRow[index].trimmed), (1...31).contains(day) else { continue }
            guard let month = Self.monthMap[field(monthRow, index).trimmed.lowercased()] else { continue }

            // Resolve the year from this day's weekday — robust to out-of-order /
            // overlapping strips. Fall back to the last resolved year if absent.
            let weekday = Self.weekdayMap[String(field(weekdayRow, index).trimmed.lowercased().prefix(3))]
            let year = Self.resolveYear(month: month, day: day, weekday: weekday,
                                        near: now, cache: &yearCache) ?? lastYear
            lastYear = year

            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = day
            guard let date = calendar.date(from: comps) else { continue }
            guard date >= windowLower, date < windowUpper else { continue }   // rolling 15-month window
            let id = iso.string(from: date)

            let startToken = field(shiftRow, index).trimmed

            // OFF / blank / non-numeric → day off.
            guard let startHour = Int(startToken) else {
                shifts.append(Shift(id: id, date: date, startHour: 0, endHour: 0,
                                    role: .off, desk: "", leaveCode: nil, isOff: true))
                continue
            }

            // Desk sits in the next column — but only if that column isn't itself a
            // day-number column (guards against the dropped-separator case).
            let deskColumnIsGap = (index + 1 >= dayRow.count) || dayRow[index + 1].trimmed.isEmpty
            let desk = deskColumnIsGap ? field(shiftRow, index + 1).trimmed : ""
            let endHour = (startHour + 9) % 24

            shifts.append(Shift(id: id, date: date,
                                startHour: startHour, endHour: endHour,
                                role: Self.role(forDesk: desk),
                                desk: desk, leaveCode: nil, isOff: false))
        }
    }

    // MARK: - Helpers

    /// Extracts `(id, name, quals)` from a name cell like `Lee, Ervin  (292216) D, L`.
    /// Returns nil for header / annotation / blank cells (no parenthesised ID).
    private static func workerIdentity(_ cell: String) -> (id: String, name: String, quals: [String])? {
        guard let open = cell.firstIndex(of: "("),
              let close = cell[cell.index(after: open)...].firstIndex(of: ")") else { return nil }
        let idStr = String(cell[cell.index(after: open)..<close])
        guard idStr.count >= 4, idStr.allSatisfy(\.isNumber) else { return nil }
        let name  = String(cell[..<open]).trimmingCharacters(in: .whitespaces)
        let quals = String(cell[cell.index(after: close)...])
            .split { $0 == "," || $0 == " " }
            .map(String.init)
            .filter { !$0.isEmpty }
        return (idStr, name, quals)
    }

    /// De-duplicates overlapping strips by date, preferring a working shift over OFF.
    private static func dedup(_ shifts: [Shift]) -> [Shift] {
        var byID: [String: Shift] = [:]
        for shift in shifts {
            if let existing = byID[shift.id] {
                if existing.isOff && !shift.isOff { byID[shift.id] = shift }
            } else {
                byID[shift.id] = shift
            }
        }
        return byID.values.sorted { $0.date < $1.date }
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
