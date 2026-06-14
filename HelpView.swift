// HelpView.swift
// In-app instructions — shown from onboarding ("How it works") and from
// Settings ("How to use BATMAN Reader"), so users can revisit anytime.

import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                section("Getting set up", "person.crop.circle.badge.checkmark", [
                    "Enter your real Employee ID and a display name — that's how trades are matched to you.",
                    "Keep iCloud Trade Sync ON so you see others, the channel, and your schedule from the master."
                ])

                section("Your schedule", "calendar", [
                    "Your schedule loads automatically from the dispatch master — no file to import.",
                    "The admin posts an updated master about 3× a day (once a shift). Just open the app to get the latest; the Schedule tab shows a scrolling month calendar with today highlighted."
                ])

                section("Find Candidates (who can take your shifts)", "person.2.badge.gearshape", [
                    "Availability tab → Find Candidates → tap the day(s) you want to give away → Find.",
                    "📖 green = a clean bookend (won't chop up their time off).",
                    "🔥 gold ×N = the strongest matches — you each have days the other wants and can work.",
                    "“?” means that person hasn't set a trade profile yet."
                ])

                section("Two-way swaps", "arrow.triangle.swap", [
                    "Tap the blue → on anyone to open the swap explorer.",
                    "See your schedules side-by-side, the days you'd give vs. take, and ‘Propose a swap’ to send it to their inbox."
                ])

                section("Mark days you want to trade away", "hand.raised", [
                    "My Availability → ‘Days I want to trade away’ → tap your working days across the year.",
                    "Set your Openness (bookends / all) and Blacklist (shift types, regions, desks, weekdays) so you only get offers you'd accept."
                ])

                section("Trade Inbox", "tray.full", [
                    "The 🗂️ icon (top-right) opens your inbox.",
                    "Each request shows whether it's waiting on you or them. Accept, Counter, or Decline — the other person sees your reply."
                ])

                section("Trade Channel", "megaphone", [
                    "The 📣 icon opens the broadcast channel — post what you're trying to trade away; everyone sees it.",
                    "Tap a post to expand, reply publicly or privately, and react. Use **bold**, *italic*, ~~strike~~. Edit or delete your own posts; they expire on their own."
                ])

                section("Reminders & widgets", "bell.badge", [
                    "Settings sets how many hours before a shift you're reminded.",
                    "Add the Next Shift and Trade Requests widgets to your Home Screen.",
                    "Ask Siri / Shortcuts: “Turn on shift alerts”, “Tomorrow's alarm time”, and more."
                ])

                section("How trades actually update", "info.circle", [
                    "Trades you arrange here are agreements — the official change still happens in ARIS/WorkNet.",
                    "Once the admin posts the next master, everyone's schedules (including yours) refresh automatically. You never re-import per trade."
                ])
            }
            .navigationTitle("How to Use")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func section(_ title: String, _ symbol: String, _ points: [String]) -> some View {
        Section {
            ForEach(points, id: \.self) { p in
                Label {
                    Text(.init(p)).font(.subheadline)   // .init parses Markdown
                } icon: {
                    Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary)
                }
            }
        } header: {
            Label(title, systemImage: symbol)
        }
    }
}

// MARK: - Tester guide (in-app)

/// The tester walkthrough, in the app for quick reference. Mirrors TESTING_GUIDE.md.
struct TesterGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Test it like a dispatcher: do the normal things, then **try to break it**. Report anything wrong, confusing, or broken in the **# feedback** channel (tap 📣, switch to # feedback).")
                        .font(.subheadline)
                }

                section("First run", "person.crop.circle.badge.checkmark", [
                    "Sign in with Apple, enter your **real Employee ID** + name.",
                    "**Break it:** wrong ID; an ID already used by someone; kill the app mid-setup; airplane mode while signing in." ])

                section("Schedule & intents", "calendar", [
                    "Confirm your shifts, days off, and today look right; tap the ⓘ key.",
                    "**Mark Intents** → mark shifts Trade away / Keep; set AM/PM/MID availability on days off.",
                    "Long-press a day for the editor (reason, significant day, public/private note).",
                    "**Break it:** mark/undo fast; mark a day already marked differently; 50-char notes." ])

                section("Openness", "dial.min", [
                    "Set Accepting: All / Bookends / Not accepting (calendar stays neutral for All & Bookends).",
                    "Add a date-range override; toggle Mercenary mode.",
                    "**Break it:** overlapping overrides; blacklist everything (expect no matches)." ])

                section("Trades", "arrow.left.arrow.right", [
                    "**Search:** pick days to trade away → Find; review Packages + Individual takers.",
                    "**Intents tabs:** every tier is a real two-way swap; one-way trades are in ECB.",
                    "Open a swap — **tap each step** to jump to that leg's two people; check who gives/gets what.",
                    "**Break it:** does the loop come back to you? do the dates match the calendars?" ])

                section("ECB (one-way)", "star.circle", [
                    "Pick shifts you want taken, set the ECB, Request all; accept per shift, reply with employee #.",
                    "**Break it:** two people accept the same shift; skip the #1 accepter; cancel mid-queue." ])

                section("Inbox & chat", "tray.full", [
                    "Each request shows the trade as a card (give/get in colors, or the full loop).",
                    "Accept / Counter / Decline — and **message back and forth** to talk it out.",
                    "**Break it:** long messages; reply to your own; go offline then back." ])

                section("Reminders, widgets, Siri", "bell.badge", [
                    "Set lead time; confirm a shift reminder fires; add the widgets.",
                    "Ask Siri: \"Do I work tomorrow in BATMAN Watcher\", \"Who can trade with me…\".",
                    "**Break it:** ask Siri before fetching a schedule." ])

                section("General", "exclamationmark.triangle", [
                    "Rotate the device; switch light/dark; bump Dynamic Type (Accessibility) — text should scale.",
                    "Background the app, reopen; lose/regain network.",
                    "Anything that looks wrong, confusing, or ugly → post it in **# feedback**." ])
            }
            .navigationTitle("Tester Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func section(_ title: String, _ symbol: String, _ points: [String]) -> some View {
        Section {
            ForEach(points, id: \.self) { p in
                Label {
                    Text(.init(p)).font(.subheadline)
                } icon: {
                    Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary)
                }
            }
        } header: {
            Label(title, systemImage: symbol)
        }
    }
}
