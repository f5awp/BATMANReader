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
