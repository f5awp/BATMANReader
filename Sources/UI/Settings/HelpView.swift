// HelpView.swift
// In-app instructions — shown from onboarding ("How it works") and from
// Settings ("How to use BATMAN Reader"), so users can revisit anytime.

import SwiftUI

// MARK: - Reusable trade-preferences form (onboarding + first-run walkthrough)

/// The essential Trade Settings, embeddable in onboarding flows — same controls as Trade Settings, and
/// every change publishes immediately. Used by `WelcomeView` (page 3) and the `WelcomeWalkthrough` finale.
struct WelcomeTradePrefs: View {
    @Bindable private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section {
                Text("Set these so you only get trades you'd actually take. You can change everything anytime in Trade Settings.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Picker("Accepting", selection: openness) {
                    ForEach(TradeOpenness.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Mercenary mode (take any qualifying shift)", isOn: mercenary)
            } header: { Text("Openness") } footer: {
                Text("Bookends-only offers you a pickup only when it attaches to your existing days off.")
            }
            Section("Status (optional, public)") {
                TextField("e.g. Open to bookends this month", text: $settings.statusBroadcast, axis: .vertical)
                    .lineLimit(1...3)
            }
            Section {
                pillFlow(ShiftAvailabilityType.allCases.map(\.rawValue),
                         isOn: { settings.blacklistedShiftTypes.contains($0) },
                         enabled: { _ in true },
                         toggle: { toggleSet(&settings.blacklistedShiftTypes, $0) },
                         label: { $0 })
            } header: { Text("Blacklisted shift types") } footer: { Text("Tap a type to stop being offered those shifts.") }
            Section {
                pillFlow(DeskRegion.allCases.map(\.rawValue),
                         isOn: { settings.blacklistedRegions.contains($0) },
                         enabled: { DeskRules.isQualified(quals: settings.cachedQuals, forRegion: DeskRegion(rawValue: $0) ?? .domestic) },
                         toggle: { toggleSet(&settings.blacklistedRegions, $0) },
                         label: { $0 })
            } header: { Text("Blacklisted regions") } footer: { Text("Grayed regions need a qualification you don't hold.") }
            Section {
                pillFlow(TradeSettingsSheet.weekdayPills.map { String($0.day) },
                         isOn: { settings.blacklistedWeekdays.contains(Int($0) ?? 0) },
                         enabled: { _ in true },
                         toggle: { toggleSet(&settings.blacklistedWeekdays, Int($0) ?? 0) },
                         label: { d in TradeSettingsSheet.weekdayPills.first { String($0.day) == d }?.letter ?? d })
            } header: { Text("Blackout days") } footer: {
                Text("More options — desks, qual-swap values, relief — live in Trade Settings.")
            }
        }
        .scrollContentBackground(.hidden)
        .task {
            guard settings.cachedQuals.isEmpty, !settings.username.isEmpty else { return }
            for _ in 0..<20 {
                let q = await RosterStore.shared.schedule(forWorker: settings.username).first?.quals ?? []
                if !q.isEmpty { settings.cachedQuals = q; return }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func pillFlow(_ values: [String], isOn: @escaping (String) -> Bool,
                          enabled: @escaping (String) -> Bool, toggle: @escaping (String) -> Void,
                          label: @escaping (String) -> String) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(values, id: \.self) { v in
                BlacklistPill(label: label(v), selected: isOn(v), enabled: enabled(v)) { toggle(v) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
    }
    private func publishPrefs() { settings.markPrefsChanged(); Task { await TradeProfileStore.shared.publishMine() } }
    private func toggleSet<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
        publishPrefs()
    }
    private var openness: Binding<TradeOpenness> {
        Binding(get: { TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends },
                set: { level in
                    settings.tradeOpenness = level.rawValue
                    DayIntentStore.shared.applyOpenness(level, shifts: ShiftStore.shared.shifts)
                    publishPrefs()
                })
    }
    private var mercenary: Binding<Bool> {
        Binding(get: { settings.isMercenaryMode },
                set: { on in
                    settings.isMercenaryMode = on
                    let level = TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends
                    DayIntentStore.shared.applyMercenary(on, openness: level, shifts: ShiftStore.shared.shifts)
                    publishPrefs()
                })
    }
}

// MARK: - Welcome (startup) — purpose + engineer-level tour + version history

/// The startup welcome: a hero pitch, what-it-does pillars, "What's New" for this build, and links
/// into the deep "How it works" tour and the version history. Shown on launch; reopenable from Settings.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: () -> Void = {}

    /// Three-step welcome: 0 = who we are / first steps · 1 = "What's New in Build 6" · 2 = set trade preferences.
    @State private var page = 0
    @Bindable private var settings = SettingsManager.shared
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case 0:  welcomePage
                case 1:  whatsNewPage
                default: preferencesPage
                }
            }
            .navigationTitle(page == 0 ? "Welcome" : (page == 1 ? "What's New" : "Your trade preferences"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if page > 0 {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { withAnimation { page -= 1 } } label: { Label("Back", systemImage: "chevron.left") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    switch page {
                    case 0:  Button("What's New →") { withAnimation { page = 1 } }
                    case 1:  Button("Set preferences →") { withAnimation { page = 2 } }
                    default: DXCloseButton { onDismiss(); dismiss() }
                    }
                }
            }
        }
    }

    // MARK: Page 0 — welcome
    private var welcomePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                purpose
                firstSteps        // lead with what to DO
                pillars
                // The deep methodology + scoring detail live at the BOTTOM — reference, not the pitch.
                methodology
                scoringTable
                deepLinks
                // Let people stop seeing this on every launch. When off it still appears after an update.
                Toggle(isOn: $settings.showWelcomeOnLaunch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show this on every launch").font(.subheadline.weight(.semibold))
                        Text("Turn off to only see it after an update. Re-enable in App Settings anytime.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(20)
        }
    }

    // MARK: Page 1 — What's New in Build 6 (what changed + why it matters)
    private var whatsNewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("What's New in v2.2", systemImage: "sparkles")
                        .font(.title2.bold()).labelStyle(.titleAndIcon).foregroundStyle(AppColor.primary)
                    Text("The biggest changes in this update — exactly what changed and why it matters.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(AppGuide.build6Highlights) { highlightCard($0) }
            }
            .padding(20)
        }
    }

    private func highlightCard(_ h: AppGuide.Build6Highlight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(h.title, systemImage: h.symbol)
                .font(.headline).labelStyle(.titleAndIcon).foregroundStyle(AppColor.primary)
            highlightLine("What changed", h.what)
            highlightLine("Why it matters", h.why)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
    private func highlightLine(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Page 2 — set trade preferences (the essentials from Trade Settings, right in onboarding)
    private var preferencesPage: some View {
        Form {
            Section {
                Text("Set these so you only get trades you'd actually take. You can change everything anytime in Trade Settings.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Picker("Accepting", selection: openness) {
                    ForEach(TradeOpenness.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Mercenary mode (take any qualifying shift)", isOn: mercenary)
            } header: { Text("Openness") } footer: {
                Text("Bookends-only offers you a pickup only when it attaches to your existing days off.")
            }
            Section("Status (optional, public)") {
                TextField("e.g. Open to bookends this month", text: $settings.statusBroadcast, axis: .vertical)
                    .lineLimit(1...3)
            }
            Section {
                pillFlow(ShiftAvailabilityType.allCases.map(\.rawValue),
                         isOn: { settings.blacklistedShiftTypes.contains($0) },
                         enabled: { _ in true },
                         toggle: { toggleSet(&settings.blacklistedShiftTypes, $0) },
                         label: { $0 })
            } header: { Text("Blacklisted shift types") } footer: { Text("Tap a type to stop being offered those shifts.") }
            Section {
                pillFlow(DeskRegion.allCases.map(\.rawValue),
                         isOn: { settings.blacklistedRegions.contains($0) },
                         // Read the @Observable cache DIRECTLY (not a one-shot @State copy) so the regions
                         // un-gray the instant quals resolve, even if that's after this page appeared.
                         enabled: { DeskRules.isQualified(quals: settings.cachedQuals, forRegion: DeskRegion(rawValue: $0) ?? .domestic) },
                         toggle: { toggleSet(&settings.blacklistedRegions, $0) },
                         label: { $0 })
            } header: { Text("Blacklisted regions") } footer: { Text("Grayed regions need a qualification you don't hold.") }
            Section {
                pillFlow(TradeSettingsSheet.weekdayPills.map { String($0.day) },
                         isOn: { settings.blacklistedWeekdays.contains(Int($0) ?? 0) },
                         enabled: { _ in true },
                         toggle: { toggleSet(&settings.blacklistedWeekdays, Int($0) ?? 0) },
                         label: { d in TradeSettingsSheet.weekdayPills.first { String($0.day) == d }?.letter ?? d })
            } header: { Text("Blackout days") } footer: {
                Text("More options — desks, qual-swap values, relief — live in Trade Settings.")
            }
        }
        .scrollContentBackground(.hidden)   // §11: drop the grouped-list chrome background
        .task {
            // Ensure the qual cache is populated — the region gating reads `settings.cachedQuals` directly
            // (reactively), so the moment quals land the regions un-gray, no matter when the roster resolves.
            guard settings.cachedQuals.isEmpty, !settings.username.isEmpty else { return }
            for _ in 0..<20 {
                let q = await RosterStore.shared.schedule(forWorker: settings.username).first?.quals ?? []
                if !q.isEmpty { settings.cachedQuals = q; return }
                try? await Task.sleep(nanoseconds: 400_000_000)   // ~8s max
            }
        }
    }

    /// A wrapping row of BlacklistPills, generic over the value's string key.
    private func pillFlow(_ values: [String], isOn: @escaping (String) -> Bool,
                          enabled: @escaping (String) -> Bool, toggle: @escaping (String) -> Void,
                          label: @escaping (String) -> String) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(values, id: \.self) { v in
                BlacklistPill(label: label(v), selected: isOn(v), enabled: enabled(v)) { toggle(v) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
    }

    private func publishPrefs() { settings.markPrefsChanged(); Task { await TradeProfileStore.shared.publishMine() } }
    private func toggleSet<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
        publishPrefs()
    }
    private var openness: Binding<TradeOpenness> {
        Binding(get: { TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends },
                set: { level in
                    settings.tradeOpenness = level.rawValue
                    DayIntentStore.shared.applyOpenness(level, shifts: ShiftStore.shared.shifts)
                    publishPrefs()
                })
    }
    private var mercenary: Binding<Bool> {
        Binding(get: { settings.isMercenaryMode },
                set: { on in
                    settings.isMercenaryMode = on
                    let level = TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends
                    DayIntentStore.shared.applyMercenary(on, openness: level, shifts: ShiftStore.shared.shifts)
                    publishPrefs()
                })
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            DXMosaicHero(title: AppGuide.appName, subtitle: "DISPATCH SHIFT TRADING")
            Text(AppGuide.tagline).font(.headline).foregroundStyle(.secondary)
            if !AppInfo.version.isEmpty {
                Text("Version \(AppInfo.version) (build \(AppInfo.build))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shortened intro — one line. The full "why" + methodology now live lower down / behind the links.
    private var purpose: some View {
        Text(AppGuide.purpose.first ?? "")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The lead content: a numbered checklist of the first things to do after joining.
    private var firstSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your first steps").font(.headline)
            ForEach(Array(AppGuide.firstSteps.enumerated()), id: \.element.id) { i, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(i + 1)")
                        .font(.footnote.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(AppColor.primary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Label(step.title, systemImage: step.symbol)
                            .font(.subheadline.weight(.semibold)).labelStyle(.titleAndIcon)
                        Text(step.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pillars: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What it does").font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(AppGuide.pillars.enumerated()), id: \.element.title) { i, pillar in
                    let tint = [AppColor.primary, AppColor.special, AppColor.success, AppColor.vacation][i % 4]
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: pillar.symbol)
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                            .frame(width: 26, height: 26)
                            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    Image(systemName: topic.symbol).font(.title3).foregroundStyle(AppColor.primary)
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

    private var deepLinks: some View {
        VStack(spacing: 0) {
            NavigationLink {
                MechanismsView()
            } label: {
                rowLabel("How it works — under the hood", "Every system, explained at engineer depth", "gearshape.2.fill", AppColor.special)
            }
            Divider().padding(.leading, 52)
            NavigationLink {
                VersionHistoryView()
            } label: {
                rowLabel("Version history", "The full arc of work, build by build", "clock.arrow.circlepath", AppColor.vacation)
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
/// Card-based (matches the welcome "What's New" page) for clearer contrast than a plain list.
/// The full release history, from `ReleaseNotes.all` (the What's New source of truth). The current-release
/// popup is the standalone `WhatsNewView`; this is the scrollable archive reached from Settings.
struct VersionHistoryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(ReleaseNotes.all.enumerated()), id: \.element.id) { i, rel in
                    releaseCard(rel, isLatest: i == 0)
                }
            }
            .padding(20)
        }
        .navigationTitle("Version history")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func releaseCard(_ rel: ReleaseNote, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label(rel.version, systemImage: isLatest ? "sparkles" : "shippingbox.fill")
                    .font(.headline).labelStyle(.titleAndIcon).foregroundStyle(AppColor.primary)
                Text(rel.headline).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ForEach(rel.bullets) { b in
                HStack(alignment: .top, spacing: 10) {
                    Text(b.icon).font(.subheadline.weight(.bold)).foregroundStyle(b.color)
                        .frame(width: 18, alignment: .center)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(b.body).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isLatest ? AppColor.primary.opacity(0.5) : .clear, lineWidth: 1.5))
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { DXCloseButton { dismiss() } } }
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
                    "Ask Siri: \"Do I work tomorrow in \(AppGuide.appName)\", \"Who can trade with me…\".",
                    "**Break it:** ask Siri before fetching a schedule." ])

                section("General", "exclamationmark.triangle", [
                    "Rotate the device; switch light/dark; bump Dynamic Type (Accessibility) — text should scale.",
                    "Background the app, reopen; lose/regain network.",
                    "Anything that looks wrong, confusing, or ugly → post it in **# feedback**." ])
            }
            .navigationTitle("Tester Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DXCloseButton { dismiss() } } }
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
