// SettingsView.swift
// In-app settings — credentials, notifications, shared calendar, debug.
// Everything here persists without needing Xcode.

import SwiftUI
import EventKit
import UniformTypeIdentifiers

struct SettingsView: View {

    @Bindable private var settings = SettingsManager.shared
    private let store    = ShiftStore.shared
    private let ekManager = EventKitManager.shared

    @State private var passwordDraft      = ""
    @State private var showPasswordSaved  = false
    @State private var showClearConfirm   = false
    @State private var debugMessage: String?
    @State private var calendarResetMessage: String?
    @State private var showDebugPrompt = false
    @State private var debugPwDraft = ""
    @State private var checkingCloudKit = false
    @AppStorage("tourReplayRequested") private var tourReplayRequested = false   // "Replay tour" one-off trigger
    @State private var rosterProbe: String?   // dev: roster date-span + last-60d readout
    @State private var showImporter = false   // dev: manual master schedule CSV import (moved off Home)
    @State private var importResult: String?
    @State private var importError: String?
    private var dev = DevAccess.shared
    @Environment(\.dismiss) private var dismiss

    /// Trailing affordance for tappable (non-navigation) DXIconRow rows.
    private var settingsChevron: some View {
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }

    var body: some View {
        NavigationStack {
            Form {

                // ── Welcome / What's New (top: quick access to the toggle) ───
                Section {
                    DXIconRow(icon: "hand.wave", tint: AppColor.primary, title: "Show Welcome on launch") {
                        Toggle("", isOn: $settings.showWelcomeOnLaunch).labelsHidden().tint(AppColor.success)
                    }
                    DXIconRow(icon: "sparkles", tint: AppColor.special, title: "Show update notes on launch") {
                        Toggle("", isOn: $settings.showUpdateOnLaunch).labelsHidden().tint(AppColor.success)
                    }
                } footer: {
                    Text("The welcome tour appears on first launch (replay it below anytime). The “What's New” screen appears after the tour and after each app update — turn it off here to skip it.")
                }

                // ── App info: installed version + last schedule sync (moved off the Home page) ───
                Section {
                    DXIconRow(icon: "info.circle", tint: AppColor.neutral, title: "Version") {
                        Text("\(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
                    }
                    DXIconRow(icon: "arrow.triangle.2.circlepath", tint: AppColor.neutral, title: "Schedule synced") {
                        Text(Self.syncedText).foregroundStyle(.secondary)
                    }
                }

                // ── Help ─────────────────────────────────────────────
                Section {
                    // Re-arm the guided tour once (independent of the launch toggle), then close Settings so
                    // the full-screen walkthrough appears.
                    Button {
                        tourReplayRequested = true
                        dismiss()
                    } label: {
                        DXIconRow(icon: "play.circle", tint: AppColor.primary, title: "Replay tour") { settingsChevron }
                    }.buttonStyle(.plain)
                    NavigationLink {
                        VersionHistoryView()
                    } label: {
                        DXIconRow(icon: "clock.arrow.circlepath", tint: AppColor.neutral, title: "Update history") { EmptyView() }
                    }
                }

                // ── Appearance ───────────────────────────────────────
                Section {
                    DXIconRow(icon: "circle.lefthalf.filled", tint: AppColor.special, title: "Theme") {
                        Picker("", selection: $settings.appearance) {
                            ForEach(AppAppearance.allCases) { a in Text(a.label).tag(a.rawValue) }
                        }.labelsHidden()
                    }
                } footer: {
                    Text("“Automatic” follows your device's light/dark (day-night) setting.")
                }

                // ── Accessibility ────────────────────────────────────
                Section {
                    DXIconRow(icon: "plus.magnifyingglass", tint: AppColor.special, title: "Screen magnifier") {
                        Toggle("", isOn: $settings.magnifierEnabled).labelsHidden().tint(AppColor.success)
                    }
                } footer: {
                    Text("Shows a floating magnifier button (drag it anywhere). Tap it, then pinch with two fingers to zoom and drag with two fingers to pan — one finger still taps and scrolls normally.")
                }

                // ── Daily summary ────────────────────────────────────
                Section {
                    DXIconRow(icon: "bell.badge", tint: AppColor.heat, title: "Daily summary notification") {
                        Toggle("", isOn: $settings.dailyDigestEnabled).labelsHidden().tint(AppColor.success)
                    }
                    if settings.dailyDigestEnabled {
                        Picker(selection: $settings.dailyDigestHour) {
                            ForEach(0..<24, id: \.self) { h in Text(Self.hourLabel(h)).tag(h) }
                        } label: {
                            Label("Time", systemImage: "clock")
                        }
                    }
                } footer: {
                    Text("Once a day, a notification summarises what needs you — pending trades and unread messages. On-device only.")
                }
                .onChange(of: settings.dailyDigestEnabled) { _, _ in rescheduleDigest(); publishPrefs() }
                .onChange(of: settings.dailyDigestHour) { _, _ in rescheduleDigest(); publishPrefs() }

                // ── Account ──────────────────────────────────────────
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
                            Label("Signed in", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(AppColor.success)
                        }
                    }
                } header: {
                    Text("Your Account")
                } footer: {
                    Text("Your employee ID is locked to your Apple ID and can't be changed here. Contact the admin if it's wrong.")
                }

                // ── Contact (optional, on-device) ────────────────────
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
                    Text("Contact")
                } footer: {
                    Text("Saved on your device for future email/text trade alerts. Not shared with others yet.")
                }

                // ── iCloud trade sync ────────────────────────────────
                Section {
                    Toggle("Sync trades via iCloud", isOn: Binding(
                        get: { settings.useCloudKit },
                        set: { on in
                            settings.useCloudKit = on
                            Task {
                                await TradeProfileStore.shared.setCloudKit(on)
                                await MessagingStore.shared.setCloudKit(on)
                            }
                        }
                    ))
                } header: {
                    Text("iCloud Trade Sync")
                } footer: {
                    Text("When on, your trade willingness (openness, blacklist, days you want to trade away) is shared with other dispatchers via iCloud so matches are real cross-user. Requires being signed into iCloud. Off = local only.")
                }

                // ── Personal calendar ────────────────────────────────
                Section {
                    LabeledContent("Calendar access") {
                        Text(calendarStatusText)
                            .foregroundStyle(ekManager.isAuthorized ? AppColor.success : AppColor.danger)
                    }
                    LabeledContent("Writes to") {
                        Text(ekManager.personalCalendarName)
                            .foregroundStyle(.secondary)
                    }
                    // Resets every calendar event the app created (clears duplicates), then re-adds
                    // your current shifts ONCE, cleanly. Fixes accidental duplicate buildup.
                    Button(role: .destructive) {
                        Task { @MainActor in
                            // Removing events requires FULL (read+write) access — write-only can't
                            // enumerate events to delete them (the likely "did nothing" cause). Prompt first.
                            if !EventKitManager.shared.isAuthorized {
                                _ = await EventKitManager.shared.requestPermission()
                            }
                            guard EventKitManager.shared.isAuthorized else {
                                calendarResetMessage = "Full calendar access is needed to remove events. Enable it in iOS Settings → Privacy & Security → Calendars → \(AppGuide.appName) (Full Access), then try again."
                                return
                            }
                            let removed = EventKitManager.shared.removeAllEvents()                                // clear ALL app events across every calendar
                            let readOnly = EventKitManager.shared.lastResetReadOnly
                            let added = EventKitManager.shared.resyncPersonalEvents(for: ShiftStore.shared.shifts) // re-add clean (deduped)
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
                    Text("Personal Calendar (Your Shifts)")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your shifts are added to '\(ekManager.personalCalendarName)' automatically on every fetch. Traded shifts are removed automatically. Use Reset if you see duplicate events — it clears the app's events and re-adds your shifts once.")
                        Text("Using Google Calendar? Add your Google account in iOS Settings → Calendar. Your shifts sync into it automatically through Apple Calendar — no separate setup in this app.")
                    }
                }

                // ── Notifications ────────────────────────────────────
                Section {
                    Stepper(
                        "Lead time: \(settings.notificationLeadHours)h before shift",
                        value: $settings.notificationLeadHours,
                        in: 1...12
                    )
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("A notification fires this many hours before each shift starts. Alarms are set separately via Shortcuts.")
                }
                .onChange(of: settings.notificationLeadHours) { _, _ in
                    Task { await NotificationManager.shared.scheduleAll(for: ShiftStore.shared.shifts) }
                    publishPrefs()
                }

                // ── Schedule data ────────────────────────────────────
                Section {
                    LabeledContent("Working shifts stored") {
                        Text("\(store.shifts.filter { !$0.isOff }.count)")
                            .monospacedDigit()
                    }
                    LabeledContent("Last fetched") {
                        Text(formattedLastFetch).foregroundStyle(.secondary)
                    }
                    if let diff = store.lastDiff, diff.hasChanges {
                        LabeledContent("Last changes") {
                            Text(diff.summary)
                                .foregroundStyle(AppColor.pending)
                                .font(.caption)
                        }
                    }
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear stored schedule", systemImage: "trash")
                    }
                } header: {
                    Text("Schedule Data")
                }

                // ── Debug ────────────────────────────────────────────
                #if DEBUG
                Section {
                  if dev.unlocked {
                    Toggle(isOn: $settings.showDebugWebView) {
                        Label("Show web view while fetching", systemImage: "safari")
                    }
                    Button(role: .destructive) {
                        Task { @MainActor in
                            EventKitManager.shared.removeAllEvents()
                            AvailabilityManager.shared.clearAll()
                        }
                    } label: {
                        Label("Clear calendar events", systemImage: "calendar.badge.minus")
                    }

                    #if DEBUG   // Z1: engine-test harness is DEBUG-only (stripped from Release).
                    Button {
                        // Pure suite is synchronous; the roster atomic-import check is async + needs SwiftData,
                        // so run it here (in-app, where a ModelContainer actually builds) and merge failures.
                        Task { @MainActor in
                            let pure = TradeEngineTests.runAll()
                            let roster = await TradeEngineTests.rosterAtomicityFailures()
                            let fails = pure + roster
                            debugMessage = fails.isEmpty
                                ? "✅ All engine tests passed (incl. roster atomic-import)."
                                : "Engine test failures:\n" + fails.joined(separator: "\n")
                        }
                    } label: {
                        Label("Run engine tests", systemImage: "checkmark.shield.fill")
                    }
                    #endif
                    Button {
                        Task { @MainActor in
                            let n = await TradeProfileStore.shared.seedFromRoster()
                            debugMessage = n == 0
                                ? "No profiles seeded — import the roster CSV first (with upcoming dates)."
                                : "Seeded \(n) test trade profiles."
                        }
                    } label: {
                        Label("Seed test trade profiles", systemImage: "person.3.sequence.fill")
                    }
                    Button(role: .destructive) {
                        Task { @MainActor in
                            await TradeProfileStore.shared.resetPeers()
                            debugMessage = "Cleared test trade profiles."
                        }
                    } label: {
                        Label("Clear test trade profiles", systemImage: "person.3.fill")
                    }
                    Button {
                        Task { @MainActor in
                            await MessagingStore.shared.seedFakeIncoming()
                            debugMessage = "Added a test incoming trade request — check the Inbox."
                        }
                    } label: {
                        Label("Add test incoming request", systemImage: "tray.and.arrow.down.fill")
                    }
                    Button {
                        Task { @MainActor in
                            checkingCloudKit = true
                            let result = await TradeProfileStore.shared.checkCloudKit()
                            checkingCloudKit = false
                            debugMessage = result
                        }
                    } label: {
                        Label(checkingCloudKit ? "Checking CloudKit…" : "Check CloudKit",
                              systemImage: "checkmark.icloud.fill")
                    }
                    .disabled(checkingCloudKit)
                    Button {
                        Task { @MainActor in
                            if let seed = await TradeProfileStore.shared.seedGuaranteedMutual() {
                                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                                let pretty = DateFormatter(); pretty.dateFormat = "EEE, MMM d"
                                let dateStr = f.date(from: seed.giveDay).map { pretty.string(from: $0) } ?? seed.giveDay
                                debugMessage = "Mutual match seeded with \(seed.name). In Find Candidates, SELECT \(dateStr) and tap Find — \(seed.name) shows 🔥×1; open their two-way → for the gold days."
                            } else {
                                debugMessage = "Couldn't build a mutual bookend match from the loaded roster."
                            }
                        }
                    } label: {
                        Label("Seed guaranteed gold match", systemImage: "flame.fill")
                    }
                  } else {
                    Button { showDebugPrompt = true } label: {
                        Label("Unlock developer tools", systemImage: "lock.fill")
                    }
                  }
                } header: {
                    Text("Developer Tools")
                } footer: {
                    Text("“Clear calendar events” removes every event this app wrote (personal “AA Schedule” + shared availability) without deleting your imported schedule — useful for cleaning up stray events. Re-import to rewrite them.")
                }
                #endif

                // ── Developer access (available in every build, for moderation) ──
                Section {
                    if dev.unlocked {
                        Button(role: .destructive) { dev.lock() } label: {
                            Label("Lock developer access", systemImage: "lock.open.fill")
                        }
                        Button { Task { rosterProbe = await Self.probeRoster() } } label: {
                            Label("Roster date-span probe", systemImage: "calendar.badge.clock")
                        }
                        Button { showImporter = true } label: {
                            Label("Import schedule CSV", systemImage: "square.and.arrow.down")
                        }
                    } else {
                        Button { showDebugPrompt = true } label: {
                            Label("Developer access", systemImage: "lock.fill")
                        }
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Unlocks moderation in the broadcast channel (delete any post or reply), the roster probe, and manual master schedule import.")
                }

                // ── Support the project ──────────────────────────────
                Section {
                    VStack(spacing: 14) {
                        Text("Built by a dispatcher, for dispatchers.")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text("If it's saved you a few headaches and you'd like to buy me a coffee, it's deeply appreciated but never expected.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Link(destination: URL(string: "https://account.venmo.com/u/Ervin-Lee")!) {
                            Image("VenmoQR")
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220)
                                .padding(8)
                                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .strokeBorder(.quaternary, lineWidth: 1)
                                )
                        }
                        .accessibilityLabel("Donate via Venmo")

                        Text("Tap to open Venmo, or scan with your camera")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                // ── Terms record (bottom) ────────────────────────────
                if let accepted = settings.consentAcceptedAt {
                    Section {
                        VStack(spacing: 2) {
                            Text("Terms accepted \(accepted.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.tertiary)
                            if !settings.consentVersion.isEmpty {
                                Text("Version \(settings.consentVersion)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DXCloseButton { dismiss() }
                }
            }
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
            .alert("Password saved", isPresented: $showPasswordSaved) {
                Button("OK", role: .cancel) {}
            }
            .alert("Trade profiles", isPresented: Binding(
                get: { debugMessage != nil },
                set: { if !$0 { debugMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(debugMessage ?? "")
            }
            .alert("Calendar Reset", isPresented: Binding(
                get: { calendarResetMessage != nil },
                set: { if !$0 { calendarResetMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(calendarResetMessage ?? "")
            }
            .alert("Developer Access", isPresented: $showDebugPrompt) {
                SecureField("Password", text: $debugPwDraft)
                Button("Unlock") {
                    dev.unlock(debugPwDraft)
                    debugPwDraft = ""
                }
                Button("Cancel", role: .cancel) { debugPwDraft = "" }
            } message: {
                Text("Enter the developer password.")
            }
            .confirmationDialog(
                "Clear all stored shift data?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) {
                    Task { @MainActor in ShiftStore.shared.clear() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes all shifts, calendar events (personal and shared), and notifications. Run Fetch again to reload.")
            }
        }
    }

    // MARK: - Computed helpers

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols   // ["Sunday" … "Saturday"]
        return symbols[(weekday - 1) % symbols.count]
    }

    /// 12-hour label for the digest time picker (e.g. "8 AM", "1 PM").
    private static func hourLabel(_ h: Int) -> String {
        let ampm = h < 12 ? "AM" : "PM"
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve) \(ampm)"
    }

    /// Last schedule sync, for the App-info section (moved here from the Home page's SyncTag).
    private static var syncedText: String {
        guard let date = ShiftStore.shared.lastFetchDate else { return "Not synced yet" }
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }

    /// Stamp the cross-device prefs clock and republish so the user's OTHER devices adopt the changed
    /// notification settings (A3 — lead time / daily digest now sync).
    private func publishPrefs() {
        settings.markPrefsChanged()
        Task { await TradeProfileStore.shared.publishMine() }
    }

    /// Re-schedule the daily digest with the latest counts + current settings (on toggle/time change).
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

    /// DEV-only manual import of a schedule/roster CSV (moved off the Home toolbar). When the file
    /// holds many workers, it loads the whole roster for matching and — if dev-unlocked — publishes it
    /// as the MASTER everyone syncs. Identical import pipeline as before; just gated behind dev access.
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
                    // G4: post-import sanity check — surface malformed/partial imports instead of shipping them.
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

    /// DEV: confirm the roster's actual date span + whether the last-60-day (backward) window that B4-5
    /// inference reads even contains data. If "last 60d" is ~0, backward inference is impossible and the
    /// lookback is looking at the wrong period (the master is likely forward-only).
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

    private var formattedLastFetch: String {
        guard let date = store.lastFetchDate else { return "Never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
