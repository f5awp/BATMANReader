// HelpView.swift
// In-app instructions — shown from onboarding ("How it works") and from
// Settings ("How to use BATMAN Reader"), so users can revisit anytime.

import SwiftUI

// MARK: - Welcome (startup) — purpose + engineer-level tour + version history

/// The startup welcome: a hero pitch, what-it-does pillars, "What's New" for this build, and links
/// into the deep "How it works" tour and the version history. Shown on launch; reopenable from Settings.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: () -> Void = {}

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    purpose
                    pillars
                    methodology
                    scoringTable
                    whatsNew
                    deepLinks
                }
                .padding(20)
            }
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Got it") { onDismiss(); dismiss() }
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(
                    LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18))
            Text("Welcome to \(AppGuide.appName)").font(.title.bold())
            Text(AppGuide.tagline).font(.headline).foregroundStyle(.secondary)
            if !AppInfo.version.isEmpty {
                Text("Version \(AppInfo.version) (build \(AppInfo.build))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var purpose: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AppGuide.purpose, id: \.self) { p in
                Text(p).font(.subheadline).foregroundStyle(.primary)
            }
        }
    }

    private var pillars: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What it does").font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(AppGuide.pillars, id: \.title) { pillar in
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: pillar.symbol).font(.title3).foregroundStyle(.blue)
                        Text(pillar.title).font(.subheadline.weight(.semibold))
                        Text(pillar.blurb).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    /// Operator-facing "how it works" walkthrough — Intents, matching, scoring, blacklisting,
    /// proposing, ECB, and Apple integration, in plain terms.
    private var methodology: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How it works").font(.headline)
            ForEach(AppGuide.methodology) { topic in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: topic.symbol).font(.title3).foregroundStyle(.blue)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(topic.title).font(.subheadline.weight(.semibold))
                        Text(topic.body).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Two compact tables: the trade types the engine builds, and what raises/lowers a match's rank.
    private var scoringTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How scoring & matches work").font(.headline)

            // Trade types
            VStack(alignment: .leading, spacing: 0) {
                tableHeader("Trade type", "What it is")
                ForEach(Array(AppGuide.matchTypes.enumerated()), id: \.offset) { i, row in
                    tableRow(row.type, row.detail, shaded: i.isMultiple(of: 2))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))

            // Scoring signals
            VStack(alignment: .leading, spacing: 0) {
                tableHeader("Signal", "Effect on rank")
                ForEach(Array(AppGuide.scoringSignals.enumerated()), id: \.offset) { i, row in
                    tableRow(row.signal, row.effect, sub: row.meaning, shaded: i.isMultiple(of: 2))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))

            Text("*A split (breaking up a weekend) is forgiven when BOTH people marked the day — a wanted split can still appear; a no-intent split is filtered out.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func tableHeader(_ a: String, _ b: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(a).font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
            Text(b).font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private func tableRow(_ a: String, _ b: String, sub: String? = nil, shaded: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(a).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let sub {
                    Text(sub).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(b).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(shaded ? Color(.secondarySystemBackground).opacity(0.4) : .clear)
    }

    private var whatsNew: some View {
        // SINGLE SOURCE: the "what's new" preview reads the latest entry of AppGuide.versionHistory —
        // the same data the Version-history page renders — so the changelog can never drift between a
        // simplistic copy and the detailed one. The full, build-by-build history is one tap below.
        VStack(alignment: .leading, spacing: 10) {
            if let current = AppGuide.versionHistory.first {
                Text(current.version).font(.headline)
                Text(current.headline).font(.subheadline).foregroundStyle(.secondary)
                ForEach(current.points.prefix(4), id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles").font(.caption).foregroundStyle(.green).padding(.top, 2)
                        Text(item).font(.subheadline)
                    }
                }
            }
        }
    }

    private var deepLinks: some View {
        VStack(spacing: 0) {
            NavigationLink {
                MechanismsView()
            } label: {
                rowLabel("How it works — under the hood", "Every system, explained at engineer depth", "gearshape.2.fill", .indigo)
            }
            Divider().padding(.leading, 52)
            NavigationLink {
                VersionHistoryView()
            } label: {
                rowLabel("Version history", "The full arc of work, build by build", "clock.arrow.circlepath", .teal)
            }
        }
        .padding(.vertical, 4)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func rowLabel(_ title: String, _ subtitle: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// The engineer-level "how it works" tour — one expandable section per subsystem.
struct MechanismsView: View {
    var body: some View {
        List {
            Section {
                Text("How \(AppGuide.appName) works under the hood — the real algorithms and data flow, named.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(AppGuide.mechanisms) { m in
                Section {
                    ForEach(m.details, id: \.self) { d in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "chevron.forward").font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
                            Text(d).font(.subheadline)
                        }
                    }
                } header: {
                    Label(m.title, systemImage: m.symbol)
                } footer: {
                    Text(m.summary)
                }
            }
        }
        .navigationTitle("How it works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The curated version history — milestones build by build, to show the scope of work.
struct VersionHistoryView: View {
    var body: some View {
        List {
            ForEach(AppGuide.versionHistory) { rel in
                Section {
                    ForEach(rel.points, id: \.self) { p in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Color.blue).frame(width: 6, height: 6).padding(.top, 6)
                            Text(p).font(.subheadline)
                        }
                    }
                } header: {
                    Text(rel.version)
                } footer: {
                    Text(rel.headline)
                }
            }
        }
        .navigationTitle("Version history")
        .navigationBarTitleDisplayMode(.inline)
    }
}

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
                    "**Search:** pick days to trade away → Find; review Packages + Individual Swaps.",
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
