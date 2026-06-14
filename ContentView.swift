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
    private var dev = DevAccess.shared
    private var settings = SettingsManager.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "calendar") }
                .tag(0)

            TradesView()
                .tabItem { Label("Trades", systemImage: "arrow.left.arrow.right") }
                .tag(1)
        }
        // Floating Inbox + Channel dock — top-right, below the nav bar, on every tab.
        .overlay(alignment: .topTrailing) {
            MessagingDock(showInbox: $showInbox, showChannel: $showChannel)
                .padding(.top, 52)
                .padding(.trailing, 10)
        }
        // Developer mode: a thick red border so it's obvious you have moderation powers.
        .overlay {
            if dev.unlocked {
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .strokeBorder(Color.red, lineWidth: 14)
                    Text("DEVELOPER MODE")
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 3)
                        .background(Color.red, in: Capsule())
                        .padding(.bottom, 2)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
        .fullScreenCover(isPresented: $showInbox) { InboxView() }
        .fullScreenCover(isPresented: $showChannel) { ChannelView() }
        // First-run identity setup — until signed in with Apple AND an ID claimed.
        .fullScreenCover(isPresented: Binding(
            get: { settings.appleUserID.isEmpty || settings.username.trimmingCharacters(in: .whitespaces).isEmpty },
            set: { _ in }
        )) {
            OnboardingView()
        }
        .preferredColorScheme(AppAppearance(rawValue: settings.appearance)?.scheme)
        .task {
            await MessagingStore.shared.refresh()
            _ = await RosterStore.shared.syncMasterIfNewer()   // pull the latest master roster
            await CloudPush.setup()                            // register push subscriptions
            WidgetData.update()
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
                            .foregroundStyle(.green)
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
                await TradeProfileStore.shared.publishMine()
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

