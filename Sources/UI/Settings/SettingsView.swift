// SettingsView.swift
// The unified in-app Settings — three tabs: Trade · App · Account.
//   Trade   → TradeSettingsSections (Match Radar / Openness / Trade Acceptance / Qual Swap / Relief)
//   App     → version+sync, theme, accessibility, calendar sync, notifications, information, dev, support
//   Account → profile (status/quals/notes), account identity, contact, terms
// Both entry points open this: the Home gear defaults to Trade, the app menu to App.

import SwiftUI
import EventKit
import UniformTypeIdentifiers

struct SettingsView: View {

    enum SettingsTab: Hashable { case trade, app, account }

    @Bindable private var settings = SettingsManager.shared
    private let store    = ShiftStore.shared
    private let ekManager = EventKitManager.shared

    @State private var tab: SettingsTab
    @State private var showClearConfirm   = false
    @State private var debugMessage: String?
    @State private var calendarResetMessage: String?
    @State private var showDebugPrompt = false
    @State private var debugPwDraft = ""
    @State private var checkingCloudKit = false
    @AppStorage("tourReplayRequested") private var tourReplayRequested = false   // "Replay tour" one-off trigger
    @State private var rosterProbe: String?   // dev: roster date-span + last-60d readout
    @State private var showImporter = false   // dev: manual master schedule CSV import
    @State private var importResult: String?
    @State private var importError: String?
    private var dev = DevAccess.shared
    @Environment(\.dismiss) private var dismiss

    init(initialTab: SettingsTab = .app) { _tab = State(initialValue: initialTab) }

    /// The navigation title reflects the active tab: "Trade Settings" / "App Settings" / "Account Settings".
    private var tabTitle: String {
        switch tab {
        case .trade:   return "Trade Settings"
        case .app:     return "App Settings"
        case .account: return "Account Settings"
        }
    }

    /// Trailing affordance for tappable (non-navigation) DXIconRow rows.
    private var settingsChevron: some View {
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }

    var body: some View {
        NavigationStack {
            Form {
                DXSegmented(selection: $tab, options: [
                    .init(.trade, "Trade"), .init(.app, "App"), .init(.account, "Account"),
                ])
                .listRowBackground(Color.clear)

                switch tab {
                case .trade:   TradeSettingsSections()
                case .app:     appTab
                case .account: accountTab
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(tabTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DXCloseButton { dismiss() } } }
            .alert("Roster probe", isPresented: Binding(get: { rosterProbe != nil }, set: { if !$0 { rosterProbe = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(rosterProbe ?? "") }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                          allowsMultipleSelection: false) { handleImport($0) }
            .alert("Import Error", isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(importError ?? "") }
            .alert("Schedule Imported", isPresented: Binding(
                get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(importResult ?? "") }
            .alert("Trade profiles", isPresented: Binding(
                get: { debugMessage != nil }, set: { if !$0 { debugMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(debugMessage ?? "") }
            .alert("Calendar Reset", isPresented: Binding(
                get: { calendarResetMessage != nil }, set: { if !$0 { calendarResetMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(calendarResetMessage ?? "") }
            .alert("Developer Access", isPresented: $showDebugPrompt) {
                SecureField("Password", text: $debugPwDraft)
                Button("Unlock") { dev.unlock(debugPwDraft); debugPwDraft = "" }
                Button("Cancel", role: .cancel) { debugPwDraft = "" }
            } message: { Text("Enter the developer password.") }
            .confirmationDialog("Clear all stored shift data?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { Task { @MainActor in ShiftStore.shared.clear() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes all shifts, calendar events (personal and shared), and notifications. Run Fetch again to reload.")
            }
        }
    }

    // MARK: - App tab

    @ViewBuilder private var appTab: some View {
        // Version + sync group.
        Section {
            DXIconRow(icon: "info.circle", tint: AppColor.neutral, title: "Version") {
                Text("\(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
            }
            DXIconRow(icon: "arrow.triangle.2.circlepath", tint: AppColor.neutral, title: "Last Schedule Sync") {
                Text(Self.syncedText).foregroundStyle(.secondary)
            }
            DXIconRow(icon: "arrow.clockwise.icloud", tint: AppColor.neutral, title: "Last trade-data refresh") {
                Text(Self.tradeDataText).foregroundStyle(.secondary)
            }
        }

        // Theme.
        Section {
            DXIconRow(icon: "circle.lefthalf.filled", tint: AppColor.special, title: "Theme") {
                Picker("", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { a in Text(a.label).tag(a.rawValue) }
                }.labelsHidden()
            }
        } header: {
            infoHeader("Theme", "“Automatic” follows your device's light/dark (day-night) setting.")
        }

        // Accessibility.
        Section {
            DXIconRow(icon: "plus.magnifyingglass", tint: AppColor.special, title: "Screen magnifier") {
                Toggle("", isOn: $settings.magnifierEnabled).labelsHidden().tint(AppColor.success)
            }
        } header: {
            infoHeader("Accessibility", "Shows a floating magnifier button (drag it anywhere). Tap it, then pinch with two fingers to zoom and drag with two fingers to pan — one finger still taps and scrolls normally.")
        }

        // Calendar Sync — iCloud trade sync + personal calendar.
        Section {
            Toggle("Sync trades via iCloud", isOn: Binding(
                get: { settings.useCloudKit },
                set: { on in
                    settings.useCloudKit = on
                    Task {
                        await TradeProfileStore.shared.setCloudKit(on)
                        await MessagingStore.shared.setCloudKit(on)
                        await DirectMessageStore.shared.setCloudKit(on)
                    }
                }))
        } header: {
            infoHeader("Calendar Sync · iCloud", "When on, your trade willingness (openness, blacklist, days you want to trade away) is shared with other dispatchers via iCloud so matches are real cross-user. Requires being signed into iCloud. Off = local only.")
        }
        Section {
            LabeledContent("Calendar access") {
                Text(calendarStatusText).foregroundStyle(ekManager.isAuthorized ? AppColor.success : AppColor.danger)
            }
            LabeledContent("Writes to") { Text(ekManager.personalCalendarName).foregroundStyle(.secondary) }
            Button(role: .destructive) {
                Task { @MainActor in
                    if !EventKitManager.shared.isAuthorized { _ = await EventKitManager.shared.requestPermission() }
                    guard EventKitManager.shared.isAuthorized else {
                        calendarResetMessage = "Full calendar access is needed to remove events. Enable it in iOS Settings → Privacy & Security → Calendars → \(AppGuide.appName) (Full Access), then try again."
                        return
                    }
                    let removed = EventKitManager.shared.removeAllEvents()
                    let readOnly = EventKitManager.shared.lastResetReadOnly
                    let added = EventKitManager.shared.resyncPersonalEvents(for: ShiftStore.shared.shifts)
                    var msg = "Removed \(removed) event\(removed == 1 ? "" : "s") (including duplicates) and re-added \(added) shift\(added == 1 ? "" : "s") cleanly."
                    if readOnly > 0 {
                        msg += " \(readOnly) duplicate\(readOnly == 1 ? "" : "s") sit in a read-only calendar the app can't edit — delete those manually in the Calendar app."
                    }
                    calendarResetMessage = msg
                }
            } label: {
                Label("Reset app calendar events", systemImage: "calendar.badge.exclamationmark")
            }
        } header: {
            infoHeader("Calendar Sync · Personal Calendar", "Your shifts are added to '\(ekManager.personalCalendarName)' automatically on every fetch; traded shifts are removed automatically. Use Reset if you see duplicate events. Using Google Calendar? Add your Google account in iOS Settings → Calendar — your shifts sync into it through Apple Calendar, no separate setup here.")
        }

        // Notifications — chat & messages first (grouped at the top), then the shift lead-time.
        Section {
            DXIconRow(icon: "bubble.left.and.bubble.right.fill", tint: AppColor.primary, title: "Direct messages") {
                Toggle("", isOn: $settings.notifyDirectMessages).labelsHidden().tint(AppColor.success)
            }
            DXIconRow(icon: "megaphone.fill", tint: AppColor.special, title: "Channel posts") {
                Toggle("", isOn: $settings.notifyChannelPosts).labelsHidden().tint(AppColor.success)
            }
            DXIconRow(icon: "at", tint: AppColor.heat, title: "@mentions") {
                Toggle("", isOn: $settings.notifyMentions).labelsHidden().tint(AppColor.success)
            }
        } header: {
            infoHeader("Chat & Message Notifications", "Choose which conversations push you: a 1:1 direct message, any new post in the channels, or only when you're @-mentioned. Off = no push for that kind (requires iCloud sync on).")
        }
        .onChange(of: settings.notifyDirectMessages) { _, _ in Task { await CloudPush.setup() }; publishPrefs() }
        .onChange(of: settings.notifyChannelPosts) { _, _ in Task { await CloudPush.setup() }; publishPrefs() }
        .onChange(of: settings.notifyMentions) { _, _ in Task { await CloudPush.setup() }; publishPrefs() }

        // Trade & match server pushes.
        Section {
            DXIconRow(icon: "sparkle.magnifyingglass", tint: AppColor.success, title: "Auto-matches found") {
                Toggle("", isOn: $settings.notifyAutoMatch).labelsHidden().tint(AppColor.success)
            }
            DXIconRow(icon: "arrow.left.arrow.right", tint: AppColor.primary, title: "Trade requests & ECB offers") {
                Toggle("", isOn: $settings.notifyTradeRequests).labelsHidden().tint(AppColor.success)
            }
            DXIconRow(icon: "q.square.fill", tint: AppColor.special, title: "Qual-swap requests") {
                Toggle("", isOn: $settings.notifyQualSwap).labelsHidden().tint(AppColor.success)
            }
            DXIconRow(icon: "checkmark.bubble.fill", tint: AppColor.pending, title: "Responses to your trades") {
                Toggle("", isOn: $settings.notifyTradeResponses).labelsHidden().tint(AppColor.success)
            }
        } header: {
            infoHeader("Trade Notifications", "Server pushes (arrive even when the app is closed, needs iCloud sync on): a coworker's radar auto-matching one of your days, a manual request / ECB offer to you, a qual-swap request, and when someone accepts/declines/counters a trade of yours.")
        }
        .onChange(of: settings.notifyAutoMatch) { _, _ in Task { await CloudPush.setup() }; publishPrefs() }
        .onChange(of: settings.notifyTradeRequests) { _, _ in Task { await CloudPush.setup() }; publishPrefs() }
        .onChange(of: settings.notifyQualSwap) { _, _ in Task { await CloudPush.setup() }; publishPrefs() }
        .onChange(of: settings.notifyTradeResponses) { _, _ in Task { await CloudPush.setup() }; publishPrefs() }

        // Periodic match summary (local).
        Section {
            DXIconRow(icon: "bell.badge.fill", tint: AppColor.heat, title: "Match summary") {
                Toggle("", isOn: $settings.matchSummaryEnabled).labelsHidden().tint(AppColor.success)
            }
            if settings.matchSummaryEnabled {
                Stepper("Every \(settings.matchSummaryIntervalHours)h",
                        value: $settings.matchSummaryIntervalHours, in: 1...24)
            }
        } header: {
            infoHeader("Match Summary", "A periodic on-device summary of how many auto-matches and suggested trades you have per date — instead of a ping for every watched day. Set how often it fires.")
        }
        .onChange(of: settings.matchSummaryEnabled) { _, _ in Task { await MatchStore.shared.recompute(scope: .local) }; publishPrefs() }
        .onChange(of: settings.matchSummaryIntervalHours) { _, _ in Task { await MatchStore.shared.recompute(scope: .local) }; publishPrefs() }

        Section {
            Stepper("Lead time: \(settings.notificationLeadHours)h before shift",
                    value: $settings.notificationLeadHours, in: 1...12)
        } header: {
            infoHeader("Shift Reminders", "A notification fires this many hours before each shift starts. Alarms are set separately via Shortcuts.")
        }
        .onChange(of: settings.notificationLeadHours) { _, _ in
            Task { await NotificationManager.shared.scheduleAll(for: ShiftStore.shared.shifts) }
            publishPrefs()
        }

        // Information — welcome / update notes, update history + replay tour, daily summary.
        Section {
            DXIconRow(icon: "hand.wave", tint: AppColor.primary, title: "Show Welcome on launch") {
                Toggle("", isOn: $settings.showWelcomeOnLaunch).labelsHidden().tint(AppColor.success)
            }
            DXIconRow(icon: "sparkles", tint: AppColor.special, title: "Show update notes on launch") {
                Toggle("", isOn: $settings.showUpdateOnLaunch).labelsHidden().tint(AppColor.success)
            }
            Button { tourReplayRequested = true; dismiss() } label: {
                DXIconRow(icon: "play.circle", tint: AppColor.primary, title: "Replay tour") { settingsChevron }
            }.buttonStyle(.plain)
            NavigationLink { VersionHistoryView() } label: {
                DXIconRow(icon: "clock.arrow.circlepath", tint: AppColor.neutral, title: "Update history") { EmptyView() }
            }
            DXIconRow(icon: "bell.badge", tint: AppColor.heat, title: "Daily summary notification") {
                Toggle("", isOn: $settings.dailyDigestEnabled).labelsHidden().tint(AppColor.success)
            }
            if settings.dailyDigestEnabled {
                Picker(selection: $settings.dailyDigestHour) {
                    ForEach(0..<24, id: \.self) { h in Text(Self.hourLabel(h)).tag(h) }
                } label: { Label("Time", systemImage: "clock") }
            }
        } header: {
            infoHeader("Information", "The welcome tour appears on first launch (replay it anytime). “What's New” appears after the tour and each update. The daily summary sends one on-device notification a day with pending trades and unread messages.")
        }
        .onChange(of: settings.dailyDigestEnabled) { _, _ in rescheduleDigest(); publishPrefs() }
        .onChange(of: settings.dailyDigestHour) { _, _ in rescheduleDigest(); publishPrefs() }

        developerSections
        supportSection
    }

    // MARK: - Account tab

    @ViewBuilder private var accountTab: some View {
        ProfileSections()   // Status · Qualifications · Private notes

        Section {
            DXIconRow(icon: "person.fill", tint: AppColor.primary, title: "Employee ID") {
                Text(settings.username.isEmpty ? "—" : settings.username).foregroundStyle(.secondary)
            }
            DXIconRow(icon: "person.text.rectangle", tint: AppColor.primary, title: "First Name") {
                TextField("First", text: $settings.firstName)
                    .multilineTextAlignment(.trailing).autocorrectionDisabled()
            }
            DXIconRow(icon: "person.text.rectangle", tint: AppColor.primary, title: "Last Name") {
                TextField("Last", text: $settings.lastName)
                    .multilineTextAlignment(.trailing).autocorrectionDisabled()
            }
            DXIconRow(icon: "applelogo", tint: AppColor.primary, title: "Account") {
                if settings.appleUserID.isEmpty {
                    Text("Not signed in").foregroundStyle(.secondary)
                } else {
                    Label("Signed in", systemImage: "checkmark.seal.fill").foregroundStyle(AppColor.success)
                }
            }
        } header: {
            infoHeader("Your Account", "Your employee ID is locked to your Apple ID and can't be changed here. Contact the admin if it's wrong.")
        }

        Section {
            DXIconRow(icon: "envelope", tint: AppColor.primary, title: "Personal Email") {
                TextField("optional", text: $settings.personalEmail)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            DXIconRow(icon: "envelope.badge", tint: AppColor.primary, title: "AA Email") {
                TextField("optional", text: $settings.aaEmail)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            DXIconRow(icon: "phone", tint: AppColor.primary, title: "Phone") {
                TextField("optional", text: $settings.phone)
                    .multilineTextAlignment(.trailing).keyboardType(.phonePad)
            }
        } header: {
            infoHeader("Contact", "Shown on your Dispatcher card so coworkers can reach you (tap-to-mail / tap-to-message). Editing here updates it everywhere.")
        }

        if let accepted = settings.consentAcceptedAt {
            Section {
                VStack(spacing: 2) {
                    Text("Terms accepted \(accepted.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                    if !settings.consentVersion.isEmpty {
                        Text("Version \(settings.consentVersion)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
    }

    // MARK: - Developer + support (App tab)

    @ViewBuilder private var developerSections: some View {
        #if DEBUG
        Section {
          if dev.unlocked {
            Toggle(isOn: $settings.showDebugWebView) { Label("Show web view while fetching", systemImage: "safari") }
            Button(role: .destructive) {
                Task { @MainActor in
                    EventKitManager.shared.removeAllEvents()
                    AvailabilityManager.shared.clearAll()
                }
            } label: { Label("Clear calendar events", systemImage: "calendar.badge.minus") }
            Button {
                Task { @MainActor in
                    let pure = TradeEngineTests.runAll()
                    let roster = await TradeEngineTests.rosterAtomicityFailures()
                    let fails = pure + roster
                    debugMessage = fails.isEmpty ? "✅ All engine tests passed (incl. roster atomic-import)."
                                                 : "Engine test failures:\n" + fails.joined(separator: "\n")
                }
            } label: { Label("Run engine tests", systemImage: "checkmark.shield.fill") }
            Button {
                Task { @MainActor in
                    let n = await TradeProfileStore.shared.seedFromRoster()
                    debugMessage = n == 0 ? "No profiles seeded — import the roster CSV first (with upcoming dates)."
                                          : "Seeded \(n) test trade profiles."
                }
            } label: { Label("Seed test trade profiles", systemImage: "person.3.sequence.fill") }
            Button(role: .destructive) {
                Task { @MainActor in await TradeProfileStore.shared.resetPeers(); debugMessage = "Cleared test trade profiles." }
            } label: { Label("Clear test trade profiles", systemImage: "person.3.fill") }
            Button {
                Task { @MainActor in await MessagingStore.shared.seedFakeIncoming(); debugMessage = "Added a test incoming trade request — check the Inbox." }
            } label: { Label("Add test incoming request", systemImage: "tray.and.arrow.down.fill") }
            Button {
                Task { @MainActor in
                    checkingCloudKit = true
                    let result = await TradeProfileStore.shared.checkCloudKit()
                    checkingCloudKit = false
                    debugMessage = result
                }
            } label: { Label(checkingCloudKit ? "Checking CloudKit…" : "Check CloudKit", systemImage: "checkmark.icloud.fill") }
            .disabled(checkingCloudKit)
            Button {
                Task { @MainActor in
                    if let seed = await TradeProfileStore.shared.seedGuaranteedMutual() {
                        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                        let pretty = DateFormatter(); pretty.dateFormat = "EEE, MMM d"
                        let dateStr = f.date(from: seed.giveDay).map { pretty.string(from: $0) } ?? seed.giveDay
                        debugMessage = "Mutual match seeded with \(seed.name). In Find Candidates, SELECT \(dateStr) and tap Find — \(seed.name) shows 🔥×1."
                    } else {
                        debugMessage = "Couldn't build a mutual bookend match from the loaded roster."
                    }
                }
            } label: { Label("Seed guaranteed gold match", systemImage: "flame.fill") }
          } else {
            Button { showDebugPrompt = true } label: { Label("Unlock developer tools", systemImage: "lock.fill") }
          }
        } header: {
            infoHeader("Developer Tools", "“Clear calendar events” removes every event this app wrote without deleting your imported schedule. Re-import to rewrite them.")
        }
        #endif

        Section {
            if dev.unlocked {
                Button(role: .destructive) { dev.lock() } label: { Label("Lock developer access", systemImage: "lock.open.fill") }
                Button { Task { rosterProbe = await Self.probeRoster() } } label: { Label("Roster date-span probe", systemImage: "calendar.badge.clock") }
                Button { showImporter = true } label: { Label("Import schedule CSV", systemImage: "square.and.arrow.down") }
                Button(role: .destructive) { showClearConfirm = true } label: { Label("Clear stored schedule", systemImage: "trash") }
            } else {
                Button { showDebugPrompt = true } label: { Label("Developer access", systemImage: "lock.fill") }
            }
        } header: {
            infoHeader("Developer", "Unlocks moderation in the broadcast channel (delete any post or reply), the roster probe, and manual master schedule import.")
        }
    }

    @ViewBuilder private var supportSection: some View {
        Section {
            VStack(spacing: 14) {
                Text("Built by a dispatcher, for dispatchers.").font(.headline).multilineTextAlignment(.center)
                Text("If it's saved you a few headaches and you'd like to buy me a coffee, it's deeply appreciated but never expected.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Link(destination: URL(string: "https://account.venmo.com/u/Ervin-Lee")!) {
                    Image("VenmoQR").resizable().scaledToFit().frame(maxWidth: 220).padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 1))
                }
                .accessibilityLabel("Donate via Venmo")
                Text("Tap to open Venmo, or scan with your camera").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8).listRowBackground(Color.clear)
        }
    }

    /// Section header with an (i) info bubble (replaces footers).
    private func infoHeader(_ title: String, _ info: String) -> some View {
        HStack(spacing: 6) { Text(title); InfoBubble(text: info) }
    }

    // MARK: - Computed helpers

    /// Last schedule fetch, formatted for the App-info group.
    private static var syncedText: String {
        guard let date = ShiftStore.shared.lastFetchDate else { return "Not synced yet" }
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }
    /// Last trade-data (radar) refresh — "when you last pulled."
    private static var tradeDataText: String {
        guard let date = MatchStore.shared.lastRefreshed else { return "Not synced yet" }
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }
    /// 12-hour label for the digest time picker (e.g. "8 AM", "1 PM").
    private static func hourLabel(_ h: Int) -> String {
        let ampm = h < 12 ? "AM" : "PM"
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve) \(ampm)"
    }

    /// Stamp the cross-device prefs clock and republish so the user's OTHER devices adopt changed settings.
    private func publishPrefs() {
        settings.markPrefsChanged()
        Task { await TradeProfileStore.shared.publishMine() }
    }

    /// Re-schedule the daily digest with the latest counts + current settings.
    private func rescheduleDigest() {
        let m = MessagingStore.shared
        let c = DashboardCounts.from(requests: m.requests, responses: m.responses,
                                     unread: m.pendingIncoming.count,
                                     pendingLedger: TradeHistoryStore.shared.pendingCount)
        Task {
            await NotificationManager.shared.scheduleDailyDigest(
                enabled: settings.dailyDigestEnabled, hour: settings.dailyDigestHour,
                pending: c.pending, unread: c.unread)
        }
    }

    /// DEV-only manual import of a schedule/roster CSV.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result { importError = error.localizedDescription }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let csv = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            importError = "Could not read the file as text."
            return
        }
        let username = settings.username
        Task {
            do {
                let workers = try await Task.detached { try ScheduleParser().parseAllWorkers(csv: csv) }.value
                var lines: [String] = []
                let mine = workers.first(where: { $0.id == username }) ?? (workers.count == 1 ? workers.first : nil)
                if let mine {
                    let diff = await ShiftStore.shared.save(mine.shifts)
                    await AvailabilityManager.shared.buildFromSchedule()
                    await NotificationManager.shared.scheduleAll(for: mine.shifts)
                    let restored = EventKitManager.shared.resyncPersonalEvents(for: mine.shifts)
                    lines.append("\(mine.shifts.filter { !$0.isOff }.count) of your working shifts imported. \(diff.summary)")
                    if restored > 0 { lines.append("\(restored) calendar events restored.") }
                }
                if workers.count > 1 {
                    let rows = await RosterStore.shared.importRoster(workers)
                    lines.append("Roster: \(workers.count) dispatchers loaded for matching (\(rows) rows).")
                    let report = ImportAudit.validate(workers: workers.map { ($0.id, $0.name) }, selfID: username)
                    lines.append(report.ok ? "Import check: looks good ✓"
                                           : "⚠️ Import check: " + report.warnings.joined(separator: " "))
                    if DevAccess.shared.unlocked {
                        let ok = await RosterStore.shared.publishMaster(csv: csv)
                        lines.append(ok ? "Published as MASTER roster — all users get this on their next launch."
                                        : "(Not published as master — turn on iCloud Trade Sync first.)")
                    }
                }
                if lines.isEmpty {
                    importError = "Couldn't find your employee ID (\(username)) in this file, and there's no roster to load."
                } else {
                    importResult = lines.joined(separator: "\n")
                }
                WidgetData.update()
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    /// DEV: confirm the roster's actual date span + whether the last-60-day window contains data.
    static func probeRoster() async -> String {
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = cal.startOfDay(for: Date())
        let all = await RosterStore.shared.entries(from: today.addingTimeInterval(-500 * 86_400),
                                                   to: today.addingTimeInterval(500 * 86_400))
        guard !all.isEmpty else { return "Roster is EMPTY (0 rows). Sync/import the master first." }
        let dates = all.compactMap { f.date(from: $0.day) }
        let minS = dates.min().map { f.string(from: $0) } ?? "?"
        let maxS = dates.max().map { f.string(from: $0) } ?? "?"
        let lo = today.addingTimeInterval(-60 * 86_400)
        let recent = all.filter { let d = f.date(from: $0.day); return d != nil && d! >= lo && d! <= today }
        let worked = recent.filter { !$0.isOff }
        let weekend = worked.filter { let d = f.date(from: $0.day)!; let w = cal.component(.weekday, from: d); return w == 1 || w == 7 }
        let workers = Set(worked.map { $0.workerID }).count
        return """
        rows: \(all.count)
        span: \(minS) … \(maxS)
        today: \(f.string(from: today))
        last 60d: \(recent.count) entries
        worked: \(worked.count) (weekend: \(weekend.count))
        workers worked ≥1: \(workers)
        """
    }

    private var calendarStatusText: String {
        switch ekManager.authorizationStatus {
        case .fullAccess:    return "Authorized ✓"
        case .denied:        return "Denied — enable in Settings"
        case .restricted:    return "Restricted"
        case .notDetermined: return "Not requested yet"
        default:             return "Unknown"
        }
    }
}
