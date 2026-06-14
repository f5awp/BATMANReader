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
