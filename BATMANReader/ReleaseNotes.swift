// ReleaseNotes.swift
// DX Trader — release-note data. THIS is the file you edit each version.
// Follow WHATS-NEW-GUIDE.md. The view (WhatsNewView.swift) never changes.

import SwiftUI

struct ReleaseBullet: Identifiable {
    let id = UUID()
    let icon: String      // 1 glyph, e.g. "✦" "⇄" "½" "▶" "◧" "▤" "»"
    let color: Color      // one of ReleaseNotes.palette
    let title: String     // 2-5 words
    let body: String      // 1-2 sentences, plain language
}

struct ReleaseNote: Identifiable {
    let id = UUID()
    let version: String   // "v2.3"
    let headline: String  // one sentence, em-dash style, no marketing fluff
    let bullets: [ReleaseBullet]
}

enum ReleaseNotes {

    // Approved bullet colors (the app's day/intent hues):
    static let violet = Color(red: 0.749, green: 0.353, blue: 0.949)  // #BF5AF2
    static let blue   = Color(red: 0.039, green: 0.518, blue: 1.0)    // #0A84FF
    static let green  = Color(red: 0.188, green: 0.820, blue: 0.345)  // #30D158
    static let gold   = Color(red: 1.0,   green: 0.784, blue: 0.220)  // #FFC838
    static let teal   = Color(red: 0.251, green: 0.784, blue: 0.878)  // #40C8E0
    static let orange = Color(red: 1.0,   green: 0.624, blue: 0.039)  // #FF9F0A
    static let brand  = Color(red: 0.910, green: 0.314, blue: 0.165)  // #E8502A
    static let gray   = Color(red: 0.490, green: 0.490, blue: 0.522)  // #7D7D85

    /// Newest release FIRST. Add each new version at the TOP of this array.
    static let all: [ReleaseNote] = [

        ReleaseNote(
            version: "v2.3 (Build 2)",
            headline: "Meet Trade Radar — the app now checks the whole group's shifts and intents for you and stars any day a trade is possible, so matches come to you instead of searching — plus standing offers that can fill themselves, alerts to both sides, qual swaps fixed for every qualification, and a refreshed Trade Inbox and history.",
            bullets: [
                ReleaseBullet(icon: "★", color: green, title: "Trade Radar",
                    body: "The app now checks the whole group's shifts and intents for you and puts a green star on any day a trade is possible — a shift you could pick up on a day off, or a coworker who'd take a shift you want off. Tap Watch Day on a date to be alerted when a match shows up."),
                ReleaseBullet(icon: "☰", color: blue, title: "See who you can trade with",
                    body: "Tap a day and open Trade List to see exactly who you can trade with. Tap a person to open both calendars side by side, pick the day(s), and send — the offer shows the alternate days they can counter with."),
                ReleaseBullet(icon: "⟳", color: violet, title: "Standing offers",
                    body: "Set a \"give this day to get that day\" offer once and the app keeps watching for a match. With auto-match on (Trade Settings) it sends the trade for you — to up to three coworkers at once when several fit, first to accept wins. Turn it off to just be notified and send yourself."),
                ReleaseBullet(icon: "✧", color: gold, title: "Alerts & safeguards",
                    body: "You're told when a match is found, when someone wants a day you're giving away, or wants a day you want off — and both people get the alert. Once you accept a trade, that day locks so you can't promise it twice, duplicate offers are caught, and your daily summary rolls up anything you haven't handled."),
                ReleaseBullet(icon: "⇄", color: teal, title: "Qual swaps, fixed",
                    body: "Qual swaps now work for every qualification. The green bridge finder and the amber Q correctly cover all desks and quals, so a trade that needs someone to slide onto a desk matches like any other."),
                ReleaseBullet(icon: "✈", color: orange, title: "Carryover vacation toggle",
                    body: "Carryover vacation isn't printed in the posted schedule, so the app can't read it. Tap a day → Info and turn on Carryover Vacation to mark yourself off — the group sees you're unavailable and that day stays out of trades."),
                ReleaseBullet(icon: "▤", color: brand, title: "Trade Inbox & history",
                    body: "The Trade Inbox now splits into Auto-Matches (what the radar found) and Requests (actual offers). Trade History moved into the ⋯ menu. And when you accept a trade, it closes itself and files into History → Done automatically once the BATMAN schedule shows it went through — no manual step."),
                ReleaseBullet(icon: "»", color: gray, title: "Faster & refinements",
                    body: "Trade lists open instantly, and the match check runs in the background across the whole group without slowing the app."),
            ]
        ),

        ReleaseNote(
            version: "v2.3",
            headline: "Rebuilt the match engine around one honest acceptance score — the best trade wins, not just the smallest — plus a full qual-swap workflow, partial accepts, and a guided welcome.",
            bullets: [
                ReleaseBullet(icon: "✦", color: violet, title: "Smarter matching, rebuilt end-to-end",
                    body: "One acceptance score drives construction, curation, and sorting. All-mutual multi-person trades rank as high as they deserve; loops and multi-covers optimize likelihood-to-close, not just headcount."),
                ReleaseBullet(icon: "⇄", color: green, title: "Qual swaps, done properly",
                    body: "The green double-arrow bridge finder ranks bridges by favorability (⚠ on unfavorable), the amber Q picks a bridge per trade, and qual-swaps surface in Trade Solutions with a \"No Qual Swap\" filter."),
                ReleaseBullet(icon: "½", color: teal, title: "Partial accept",
                    body: "On multi-day trades, take just the days that work — pick them right on the twin calendars and counter with those."),
                ReleaseBullet(icon: "▶", color: green, title: "Guided welcome tour",
                    body: "A first-run walkthrough that ends with your preferences — plus Replay tour in Settings."),
                ReleaseBullet(icon: "◧", color: brand, title: "Major visual revamp",
                    body: "The whole app now shares the DX mosaic theme — consistent cards, colors, and type across Home, Trades, Inbox, Channel, and Settings for one cohesive look."),
                ReleaseBullet(icon: "▤", color: violet, title: "Condensed calendar view",
                    body: "An optional continuous month stream (toggle it on) that flows week-to-week without per-month gaps — one pinned weekday header and a floating month tab you can expand for that month's stats."),
                ReleaseBullet(icon: "»", color: gray, title: "Refinements",
                    body: "Faster launch and Welcome; finding-matches and loading animations fit any device and orientation; App Settings tidied and reordered."),
            ]
        ),

        // ── Add v2.4 ABOVE this line, above v2.3 ─────────────────────────

    ]
}
