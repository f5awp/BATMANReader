// Holidays.swift
// System-wide high-demand days (airline peak-travel holidays). These are computed
// per year — including floating holidays and Good Friday (via the Computus / Easter
// algorithm) — and are always treated as DayTopology.highDemand by the calendar
// and the trade engine, unless the user has set their own topology on that date.

import Foundation

@MainActor
enum Holidays {

    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = Calendar(identifier: .gregorian)
        return f
    }()
    private static let cal = Calendar(identifier: .gregorian)
    private static var cache: [Int: [String: String]] = [:]

    /// ISO day → holiday name for a given year.
    static func map(year: Int) -> [String: String] {
        if let c = cache[year] { return c }
        let m = compute(year: year)
        cache[year] = m
        return m
    }

    /// Whether the given ISO day is a high-demand holiday.
    static func isHighDemand(_ dayID: String) -> Bool {
        guard let date = isoF.date(from: dayID) else { return false }
        let year = cal.component(.year, from: date)
        return map(year: year)[dayID] != nil
    }

    /// The holiday name for a day, if any.
    static func name(forDay dayID: String) -> String? {
        guard let date = isoF.date(from: dayID) else { return nil }
        let year = cal.component(.year, from: date)
        return map(year: year)[dayID]
    }

    // MARK: - Computation

    private static func compute(year: Int) -> [String: String] {
        var out: [String: String] = [:]
        func add(_ date: Date?, _ name: String) {
            if let d = date { out[isoF.string(from: d)] = name }
        }
        func fixed(_ month: Int, _ day: Int) -> Date? {
            cal.date(from: DateComponents(year: year, month: month, day: day))
        }
        // n-th `weekday` of `month` (Sun=1 … Sat=7); n = -1 for the last one.
        func nth(_ n: Int, _ weekday: Int, _ month: Int) -> Date? {
            cal.date(from: DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: n))
        }

        add(fixed(1, 1),        "New Year's Day")
        add(nth(3, 2, 1),       "Martin Luther King Day")   // 3rd Monday, Jan
        add(nth(3, 2, 2),       "Presidents Day")           // 3rd Monday, Feb
        add(goodFriday(year: year), "Good Friday")
        add(nth(-1, 2, 5),      "Memorial Day")             // last Monday, May
        add(fixed(7, 4),        "Independence Day")
        add(nth(1, 2, 9),       "Labor Day")                // 1st Monday, Sep
        let thanksgiving = nth(4, 5, 11)                    // 4th Thursday, Nov
        add(thanksgiving,       "Thanksgiving Day")
        add(thanksgiving.flatMap { cal.date(byAdding: .day, value: 1, to: $0) }, "Day after Thanksgiving")
        add(fixed(12, 25),      "Christmas Day")
        return out
    }

    /// Good Friday = Easter Sunday − 2 days. Easter via the Anonymous Gregorian
    /// (Computus) algorithm.
    private static func goodFriday(year y: Int) -> Date? {
        let a = y % 19, b = y / 100, c = y % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        guard let easter = cal.date(from: DateComponents(year: y, month: month, day: day)) else { return nil }
        return cal.date(byAdding: .day, value: -2, to: easter)
    }
}
