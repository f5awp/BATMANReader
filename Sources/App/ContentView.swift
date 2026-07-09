// ContentView.swift
// Tab-based main interface:
//   Tab 1 — Schedule: fetch button, shift list, debug web view
//   Tab 2 — Availability: edit your off-day availability, find trade candidates

import SwiftUI
import WebKit
import UniformTypeIdentifiers
import AuthenticationServices

// MARK: - WKWebView bridge

struct DebugWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Root

struct ContentView: View {

    @State private var selectedTab = 0
    @State private var showInbox = false
    @State private var showChannel = false
    @State private var showKey = false            // color key / legend (moved into the dock)
    @State private var showTradeSettings = false  // settings (moved into the dock, on every tab)
    @State private var showAppSettings = false
    @State private var showDashboard = false       // trade-status dashboard (from the top-bar status strip)
    @State private var showChangelog = false   // Z2: startup "What's New"
    @State private var launchLoading = true     // spinner during the initial sync so it never looks frozen
    @State private var pendingTab: Int? = nil   // C1 phase-2: tab the user wants to leave Home for
    @State private var showLeaveGuard = false   // C1 phase-2: Save-or-Discard guard
    private var dev = DevAccess.shared
    private var settings = SettingsManager.shared
    private var intents = DayIntentStore.shared
    private var messaging = MessagingStore.shared

    /// Leaving Home (tab 0) with unsaved intent edits is intercepted so the user must
    /// Save or Discard first — marks never silently leak between sessions.
    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if selectedTab == 0, newValue != 0, intents.hasUnsavedChanges {
                    pendingTab = newValue
                    showLeaveGuard = true
                } else {
                    selectedTab = newValue
                }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            // One clean, shared top bar (identity + utilities) — replaces the old floating dock that
            // overlapped the status header. Laid out above the tabs, so nothing overlaps.
            AppTopBar(showInbox: $showInbox, showChannel: $showChannel, showKey: $showKey,
                      showTradeSettings: $showTradeSettings, showAppSettings: $showAppSettings,
                      showDashboard: $showDashboard)
            TabView(selection: tabSelection) {
                HomeView()
                    .tabItem { Label("Home", systemImage: "calendar") }
                    .tag(0)

                TradesView()
                    .tabItem { Label("Trades", systemImage: "arrow.left.arrow.right") }
                    .tag(1)
            }
            // Stats strip sits at the VERY bottom — BELOW the Home/Trades tab bar, centered — so it never
            // covers in-tab controls like the ECB "Send to Selected" button (B6-STATS).
            TradeStatsBar()
        }
        // Developer mode: a thick red border so it's obvious you have moderation powers.
        .overlay {
            if dev.unlocked {
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .strokeBorder(AppColor.danger, lineWidth: 14)
                    Text("DEVELOPER MODE")
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 3)
                        .background(AppColor.danger, in: Capsule())
                        .padding(.bottom, 2)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
        .confirmationDialog("Unsaved intent changes", isPresented: $showLeaveGuard, titleVisibility: .visible) {
            Button("Save") {
                intents.markIntentsSaved()
                Task { await TradeProfileStore.shared.publishMine() }
                Task { await PrivateStateStore.shared.publishLocalIntents() }   // B4-2
                if let t = pendingTab { selectedTab = t }; pendingTab = nil
            }
            Button("Discard", role: .destructive) {
                intents.discardChanges()
                if let t = pendingTab { selectedTab = t }; pendingTab = nil
            }
            Button("Keep Editing", role: .cancel) { pendingTab = nil }
        } message: { Text("You have unsaved marks. Save them so your trades update, or discard to revert.") }
        .fullScreenCover(isPresented: $showInbox) { InboxView() }
        .fullScreenCover(isPresented: $showChannel) { ChannelView() }
        .sheet(isPresented: $showKey) { IntentKeySheet() }
        .sheet(isPresented: $showTradeSettings) { TradeSettingsSheet() }
        .sheet(isPresented: $showAppSettings) { SettingsView() }
        .sheet(isPresented: $showDashboard) { TradeDashboardSheet() }
        .alert("Not on the app yet", isPresented: Binding(
            get: { messaging.blockedRecipient != nil },
            set: { if !$0 { messaging.blockedRecipient = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(messaging.blockedRecipient ?? "This dispatcher") doesn't have an active BATMAN Watcher profile, so they can't receive trade requests or messages yet. They still show in your matches — reach out another way, or wait until they set up trading in the app.")
        }
        .sheet(isPresented: $showChangelog) {
            WelcomeView {
                settings.lastSeenChangelogBuild = AppInfo.build   // mark seen on dismiss
            }
        }
        // First-run identity setup — until signed in with Apple AND an ID claimed.
        .fullScreenCover(isPresented: Binding(
            get: { settings.appleUserID.isEmpty || settings.username.trimmingCharacters(in: .whitespaces).isEmpty },
            set: { _ in }
        )) {
            OnboardingView()
        }
        .preferredColorScheme(AppAppearance(rawValue: settings.appearance)?.scheme)
        .loadingOverlay(launchLoading, label: "Loading…")   // spinner during the initial sync
        .task {
            defer { launchLoading = false }
            await MessagingStore.shared.refresh()
            _ = await RosterStore.shared.syncMasterIfNewer()   // pull the latest master roster
            await PrivateStateStore.shared.syncOnLaunch()      // private notes across your devices (A3)
            await TradeProfileStore.shared.syncMyStatus()      // public status across your devices (A3 #12)
            if !settings.username.trimmingCharacters(in: .whitespaces).isEmpty {
                await TradeProfileStore.shared.publishMine()   // stamp our profile `accountClaimed` so peers see us as active
            }
            await CloudPush.setup()                            // register push subscriptions
            WidgetData.update()
            // Refresh the once-a-day summary notification with the latest counts (default ON).
            let c = DashboardCounts.from(requests: messaging.requests, responses: messaging.responses,
                                         unread: messaging.pendingIncoming.count,
                                         pendingLedger: TradeHistoryStore.shared.pendingCount)
            await NotificationManager.shared.scheduleDailyDigest(
                enabled: settings.dailyDigestEnabled, hour: settings.dailyDigestHour,
                pending: c.pending, unread: c.unread)
            NotificationManager.shared.scheduleDigestRefresh()   // live digest: refresh counts in the background
            // Z2: show "What's New" on EVERY launch (per user request) — but not over onboarding.
            // (Was once-per-build via ChangeLog.shouldShow; intentionally every restart now.)
            if !settings.username.trimmingCharacters(in: .whitespaces).isEmpty {
                showChangelog = true
                // Populate the Intents tab badge (mutual-match count) in the background — fire-and-forget
                // so it never delays launch. Cheap fast pass; the engine yields cooperatively.
                Task {
                    let matches = await TradeRouter.intentSolutions(excluding: settings.username, mutualOnly: true)
                    TradeFeedCache.shared.intentMatchCount = matches.count
                }
            }
        }
    }
}

// MARK: - App top bar (shared identity + utilities, replaces the floating dock)

/// The single header bar at the very top of the app, on every tab. Left: the signed-in
/// dispatcher's avatar + name (and their live status, only if they've set one — no "set a
/// status" nudge). Right: just three controls — Inbox · Channel · ⋯ (overflow: Trade status,
/// Colors & legend, Trade/App Settings). One row, laid out (not floating), never overlapping.
struct AppTopBar: View {
    @Binding var showInbox: Bool
    @Binding var showChannel: Bool
    @Binding var showKey: Bool
    @Binding var showTradeSettings: Bool
    @Binding var showAppSettings: Bool
    @Binding var showDashboard: Bool
    private var settings = SettingsManager.shared

    init(showInbox: Binding<Bool>, showChannel: Binding<Bool>, showKey: Binding<Bool>,
         showTradeSettings: Binding<Bool>, showAppSettings: Binding<Bool>, showDashboard: Binding<Bool>) {
        _showInbox = showInbox; _showChannel = showChannel; _showKey = showKey
        _showTradeSettings = showTradeSettings; _showAppSettings = showAppSettings
        _showDashboard = showDashboard
    }

    var body: some View {
        let name = settings.displayName.isEmpty ? settings.username : settings.displayName
        let status = settings.statusBroadcast.trimmingCharacters(in: .whitespaces)
        // ONE clean row: identity on the left, three controls on the right (Inbox · Channel · ⋯).
        // The old second status row is gone — its "needs you" signal is the Inbox badge, and the full
        // Accepted/Pending/Denied breakdown lives in the dashboard (⋯ → Trade status).
        HStack(spacing: 10) {
            Avatar(name: name, id: settings.username, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !status.isEmpty {
                    Text(status).font(.caption2).italic().foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            MessagingDock(showInbox: $showInbox, showChannel: $showChannel, showKey: $showKey,
                          showTradeSettings: $showTradeSettings, showAppSettings: $showAppSettings,
                          showDashboard: $showDashboard)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Trade stats bar (B6-STATS)

/// Slim, full-width successful-trade stats pinned just above the tab bar (relocated from the Home header
/// so it doesn't crowd the calendar). Tap to pick the period (month / year / all time). "Successful" =
/// accepted + archived; totals are YOU + the whole company (PAFCA), same source as the old header.
struct TradeStatsBar: View {
    private var metrics = MetricsStore.shared
    private var dev = DevAccess.shared
    @State private var period: MetricPeriod = .month

    private var myID: String { SettingsManager.shared.username }
    private var mine: Int { Metrics.count(metrics.globalEvents, kind: .trade, period: period, now: Date(), workerID: myID) }
    private var company: Int { Metrics.count(metrics.globalEvents, kind: .trade, period: period, now: Date()) }

    var body: some View {
        Menu {
            Picker("Period", selection: $period) {
                ForEach(MetricPeriod.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(AppColor.success)
                countPair(mine, "you")
                Text("·").foregroundStyle(.tertiary)
                countPair(company, "PAFCA")
                Text("· \(period.label)").foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .frame(maxWidth: .infinity)   // centered content, full-width strip
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .buttonStyle(.plain)
        .onLongPressGesture { if dev.unlocked { TradeHistoryStore.shared.resetMetrics() } }   // admin reset
        .accessibilityLabel("Successful trades: \(mine) you, \(company) PAFCA, \(period.label)")
        .task { await metrics.refresh() }
    }

    private func countPair(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text("\(n)").fontWeight(.bold).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Theme

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Automatic"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil      // follows the device (which can switch by time)
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// A small stylized preview of the app in a given theme, used in the picker.
struct ThemePreview: View {
    let appearance: AppAppearance
    let selected: Bool

    private var dark: Bool { appearance == .dark }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(bg)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor).frame(height: 10)   // nav bar
                    HStack(spacing: 3) {
                        ForEach(0..<5) { _ in
                            RoundedRectangle(cornerRadius: 2).fill(cell)
                                .frame(height: 16)
                        }
                    }
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 50, height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(line.opacity(0.6)).frame(width: 36, height: 6)
                }
                .padding(8)
                if appearance == .system {
                    // diagonal split hint for "automatic"
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 96)

            Label(appearance.label, systemImage: selected ? "checkmark.circle.fill" : "circle")
                .font(.caption).foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
                .padding(-4)
        )
    }

    private var bg: Color { dark ? Color(white: 0.10) : Color(white: 0.97) }
    private var cell: Color { (dark ? Color.white : Color.black).opacity(0.12) }
    private var line: Color { (dark ? Color.white : Color.black).opacity(0.35) }
}

/// Three tappable theme previews.
struct ThemePicker: View {
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 14) {
            ForEach(AppAppearance.allCases) { a in
                ThemePreview(appearance: a, selected: selection == a.rawValue)
                    .onTapGesture { selection = a.rawValue }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - First-run onboarding

struct OnboardingView: View {
    @Bindable private var settings = SettingsManager.shared
    private let account = AccountService()

    @State private var appleUser = ""        // set after Sign in with Apple
    @State private var employeeID = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var personalEmail = ""
    @State private var aaEmail = ""
    @State private var phone = ""
    @State private var working = false
    @State private var showHelp = false
    @State private var errorMsg: String?

    private var signedIn: Bool { !appleUser.isEmpty }
    private var canClaim: Bool {
        signedIn &&
        !employeeID.trimmingCharacters(in: .whitespaces).isEmpty &&
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Welcome to BATMAN Watcher").font(.title2.bold())
                    Text("Sign in with Apple to secure your account, then link your employee ID. Your schedule loads automatically from the dispatch master.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                Section {
                    if signedIn {
                        Label("Signed in with Apple", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(AppColor.success)
                    } else {
                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.fullName]
                        } onCompletion: { result in
                            switch result {
                            case .success(let auth):
                                if let cred = auth.credential as? ASAuthorizationAppleIDCredential {
                                    appleUser = cred.user
                                    if let fn = cred.fullName {
                                        if firstName.isEmpty, let g = fn.givenName { firstName = g }
                                        if lastName.isEmpty, let f = fn.familyName { lastName = f }
                                    }
                                }
                            case .failure(let e):
                                errorMsg = e.localizedDescription
                            }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 46)
                    }
                } footer: {
                    Text("Your Apple ID can't be faked, so no one can claim your employee ID.")
                }

                Section {
                    TextField("Employee ID (e.g. 292216)", text: $employeeID)
                        .keyboardType(.numberPad).autocorrectionDisabled().disabled(!signedIn)
                    TextField("First name", text: $firstName)
                        .autocorrectionDisabled().disabled(!signedIn)
                    TextField("Last name", text: $lastName)
                        .autocorrectionDisabled().disabled(!signedIn)
                } header: {
                    Text("Your identity")
                } footer: {
                    Text("Use your REAL employee ID — it links you to your row in the master roster and is locked to your Apple ID. You'll appear as “Last, First.”")
                }

                Section {
                    TextField("Personal email (optional)", text: $personalEmail)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(!signedIn)
                    TextField("AA email (optional)", text: $aaEmail)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(!signedIn)
                    TextField("Phone (optional)", text: $phone)
                        .keyboardType(.phonePad).disabled(!signedIn)
                } header: {
                    Text("Contact (optional)")
                } footer: {
                    Text("Saved on your device for future email/text trade alerts.")
                }

                Section {
                    ThemePicker(selection: $settings.appearance)
                        .padding(.vertical, 4)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("“Automatic” follows your device's day/night setting. You can change this later in Settings.")
                }

                Section {
                    Button {
                        claim()
                    } label: {
                        if working { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("Link & get started").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canClaim || working)

                    Button("How it works") { showHelp = true }
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showHelp) { HelpView() }
            .alert("Couldn't continue", isPresented: Binding(
                get: { errorMsg != nil }, set: { if !$0 { errorMsg = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMsg ?? "") }
        }
        .interactiveDismissDisabled(true)
    }

    private func claim() {
        working = true
        let id = employeeID.trimmingCharacters(in: .whitespaces)
        let f = firstName.trimmingCharacters(in: .whitespaces)
        let l = lastName.trimmingCharacters(in: .whitespaces)
        let nm = "\(l), \(f)"   // "Last, First"
        Task {
            // CloudKit must be on for the claim (and everything else) to work.
            if !settings.useCloudKit {
                settings.useCloudKit = true
                await TradeProfileStore.shared.setCloudKit(true)
                await MessagingStore.shared.setCloudKit(true)
            }
            let result = await account.claim(employeeID: id, appleUserID: appleUser, displayName: nm)
            switch result {
            case .ok:
                settings.appleUserID = appleUser
                settings.username = id
                settings.firstName = f
                settings.lastName = l   // recomposes displayName = "Last, First"
                settings.personalEmail = personalEmail.trimmingCharacters(in: .whitespaces)
                settings.aaEmail = aaEmail.trimmingCharacters(in: .whitespaces)
                settings.phone = phone.trimmingCharacters(in: .whitespaces)
                await TradeProfileStore.shared.publishMine()   // active profile now exists → 🤖 clears for others
                await CloudPush.setup()                        // register push NOW (launch task ran before signup)
                _ = await RosterStore.shared.syncMasterIfNewer()
                WidgetData.update()
                working = false   // cover auto-dismisses once username + appleUserID are set
            case .takenByAnother:
                working = false
                errorMsg = "Employee ID \(id) is already registered to a different Apple ID. If this is you, sign in with the Apple ID you used before, or contact the admin."
            case .error:
                working = false
                errorMsg = "Couldn't reach iCloud. Check your connection and that you're signed into iCloud, then try again."
            }
        }
    }
}

