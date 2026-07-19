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
            version: "v2.4 (Build 2)",
            headline: "A clearer calendar and notifications you control — matches now pop as an orange disc right on the date, holidays and watched days get their own marks, and every trade alert has its own switch (with the auto-match push naming the date and dispatcher, and one tap to jump there).",
            bullets: [
                ReleaseBullet(icon: "☰", color: brand, title: "See your matches for a day",
                    body: "Tap a date and open Trade List to see everyone you could trade with that day — coworkers who'd take a shift you want off, or whose shift you could pick up on a day off."),
                ReleaseBullet(icon: "✎", color: violet, title: "Dial in your trade options",
                    body: "Mark a day Want to Trade or Want to Work, then set exactly how: day-for-day, ECB, or either; the ECB amount and whether it's an IOU paid on a later date; the shift types and quals you'll accept back; specific give-back dates; and a note that shows up on the trade card for everyone."),
                ReleaseBullet(icon: "⟳", color: green, title: "Auto-match off your intents",
                    body: "With Auto-match on, the trade options you set ARE your standing offers — the app sends the swap to matching coworkers for you. When one lands you get a push naming the date and dispatcher — “An Auto-Match has been found for Sat, Sep 6 with …!” — tap it to jump to that day's Trade List."),
                ReleaseBullet(icon: "●", color: orange, title: "Matches jump off the calendar",
                    body: "A day with a possible trade now shows a bold orange disc behind the date — the most visible mark on the calendar, so opportunities are impossible to miss."),
                ReleaseBullet(icon: "★", color: gold, title: "Holidays & high-demand days",
                    body: "High-demand and holiday dates show a star in the top-right corner. And a Midnight shift now counts toward the holiday it works INTO — Labor Day is the Sept 6 MID (into the 7th), not the Sept 7 MID."),
                ReleaseBullet(icon: "!", color: blue, title: "Watched days at a glance",
                    body: "Days you're watching show a blue “!” in the top-left corner — distinct from the match disc, so a watched day with no match still reads clearly."),
                ReleaseBullet(icon: "☰", color: teal, title: "Notifications you control",
                    body: "New on/off switches for auto-matches, trade requests & ECB offers, qual swaps, responses to your trades, and messages. A periodic Match Summary tells you how many matches and suggestions you have per date, in place of a ping for every watched day."),
                ReleaseBullet(icon: "✦", color: gray, title: "Fewer, smarter pings",
                    body: "When several coworkers respond to one offer you get a single alert, not one each — and the “mutual match” / “your offer was sent” pings are gone, since the auto-match push already covers it."),
            ]
        ),

        ReleaseNote(
            version: "v2.4",
            headline: "Match Radar, rebuilt around one simple idea — the app only auto-sends a trade when there's nothing for you to decide, and hands you the rest. Plus 1:1 Direct Messages, a full Dispatcher directory, ECB force-through, and one unified Settings.",
            bullets: [
                ReleaseBullet(icon: "⟳", color: violet, title: "AUTO — only sure things",
                    body: "The Trade Inbox's AUTO tab now auto-sends a trade ONLY when there's no choice to make: a swap you and a coworker BOTH fully want, or an ECB where you shed a shift for points. Everything else no longer goes out on its own."),
                ReleaseBullet(icon: "☰", color: blue, title: "Suggested — you pick the days",
                    body: "Trades the radar found that need a decision now sit under Suggested. Tap one to open both calendars, pick the day(s), and send — it files with your other requests, not as an auto-match."),
                ReleaseBullet(icon: "⇄", color: teal, title: "Method now filters matches",
                    body: "Marking a day Day-for-day, ECB, or Either now decides who you match with. If you want a straight swap and the other person only wants ECB, that's no longer a match — the two have to line up."),
                ReleaseBullet(icon: "✦", color: gold, title: "ECB posts to your ledger",
                    body: "Accepting an ECB trade records it in ECB Accounting automatically — added to the taker, taken from the giver — the moment it's marked received. Offer it now or set a later date and it lands as an IOU."),
                ReleaseBullet(icon: "»", color: green, title: "One Find Trades screen",
                    body: "The old Intents and Trade Solutions tabs are now one Find Trades screen: search a date range, or switch to build from your marked days. Multi-person and qual-swap solutions live here."),
                ReleaseBullet(icon: "▤", color: brand, title: "Clearer trade cards",
                    body: "A trade card shows each person's note for the day, a Day / ECB / Day + ECB badge, and — when several coworkers respond to one offer — lets you choose who you actually trade with."),
                ReleaseBullet(icon: "✉", color: blue, title: "Direct Messages",
                    body: "The trade channel is now “Channels & Messages” — DM any dispatcher one-to-one from the new Messages tab or their Dispatcher card, with photos and reactions, separate from the group channels."),
                ReleaseBullet(icon: "◧", color: teal, title: "Dispatcher directory",
                    body: "Dispatcher is now the default tab in Trades: search the whole directory, filter by qual or committee, expand a card for contact info and quals, and tap Message or Find Trades."),
                ReleaseBullet(icon: "✦", color: gold, title: "ECB force-through & floor",
                    body: "ECB Accounting adds a Force-through so a trade the other side hasn't confirmed still counts in YOUR books (yours only). And Minimum Accepted ECB now blocks a low auto-match from reaching you, not just hides it."),
                ReleaseBullet(icon: "⚙", color: gray, title: "One Settings screen",
                    body: "Trade, App, and Account settings are one screen (opens on Trade), with tighter spacing, clearer ECB and qual-swap controls, and the Colors & Legend key moved into the ⋯ menu."),
            ]
        ),

        ReleaseNote(
            version: "v2.3 (Build 2)",
            headline: "Meet Trade Radar — the app now checks the whole group's shifts and intents for you and stars any day a trade is possible, so matches come to you instead of searching — plus auto-matching that sends your trades for you, alerts to both sides, qual swaps fixed for every qualification, and a refreshed Trade Inbox and history.",
            bullets: [
                ReleaseBullet(icon: "★", color: green, title: "Trade Radar",
                    body: "The app now checks the whole group's shifts and intents for you and puts a green star on any day a trade is possible — a shift you could pick up on a day off, or a coworker who'd take a shift you want off. Tap Watch Day on a date to be alerted when a match shows up."),
                ReleaseBullet(icon: "☰", color: blue, title: "See who you can trade with",
                    body: "Tap a day and open Trade List to see exactly who you can trade with. Tap a person to open both calendars side by side, pick the day(s), and send — the offer shows the alternate days they can counter with."),
                ReleaseBullet(icon: "⟳", color: violet, title: "Auto-match your intents",
                    body: "Mark a day Want to Trade or Want to Work and pick Day, ECB, or Both — those marks ARE your standing offers. With Auto-match on (Trade Settings) the app sends the swap to matching coworkers for you — up to three at once, first to accept wins. Add an optional 1-time date, shift-type, or qual limit on any day's Info tab."),
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
            version: "v2.3 (1)",
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
