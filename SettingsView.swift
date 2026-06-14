// SettingsView.swift
// In-app settings — credentials, notifications, shared calendar, debug.
// Everything here persists without needing Xcode.

import SwiftUI
import EventKit

struct SettingsView: View {

    @Bindable private var settings = SettingsManager.shared
    private let store    = ShiftStore.shared
    private let ekManager = EventKitManager.shared

    @State private var passwordDraft      = ""
    @State private var showPasswordSaved  = false
    @State private var showClearConfirm   = false
    @State private var showCalendarPicker = false
    @State private var debugMessage: String?
    @State private var showDebugPrompt = false
    @State private var debugPwDraft = ""
    @State private var checkingCloudKit = false
    @State private var showHelp = false
    @State private var showTesterGuide = false
    private var dev = DevAccess.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {

                // ── Help ─────────────────────────────────────────────
                Section {
                    Button { showHelp = true } label: {
                        Label("How to use BATMAN Watcher", systemImage: "questionmark.circle")
                    }
                    Button { showTesterGuide = true } label: {
                        Label("Tester guide", systemImage: "checklist")
                    }
                }

                // ── Appearance ───────────────────────────────────────
                Section {
                    Picker(selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { a in Text(a.label).tag(a.rawValue) }
                    } label: {
                        Label("Theme", systemImage: "circle.lefthalf.filled")
                    }
                } footer: {
                    Text("“Automatic” follows your device's light/dark (day-night) setting.")
                }

                // ── Account ──────────────────────────────────────────
                Section {
                    HStack {
                        Label("Employee ID", systemImage: "person.fill")
                        Spacer()
                        Text(settings.username.isEmpty ? "—" : settings.username)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("First Name", systemImage: "person.text.rectangle")
                        Spacer()
                        TextField("First", text: $settings.firstName)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    HStack {
                        Label("Last Name", systemImage: "person.text.rectangle")
                        Spacer()
                        TextField("Last", text: $settings.lastName)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    HStack {
                        Label("Account", systemImage: "applelogo")
                        Spacer()
                        if settings.appleUserID.isEmpty {
                            Text("Not signed in").foregroundStyle(.secondary)
                        } else {
                            Label("Signed in", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    }
                } header: {
                    Text("Your Account")
                } footer: {
                    Text("Your employee ID is locked to your Apple ID and can't be changed here. Contact the admin if it's wrong.")
                }

                // ── Contact (optional, on-device) ────────────────────
                Section {
                    HStack {
                        Label("Personal Email", systemImage: "envelope")
                        Spacer()
                        TextField("optional", text: $settings.personalEmail)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    HStack {
                        Label("AA Email", systemImage: "envelope.badge")
                        Spacer()
                        TextField("optional", text: $settings.aaEmail)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    HStack {
                        Label("Phone", systemImage: "phone")
                        Spacer()
                        TextField("optional", text: $settings.phone)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.phonePad)
                    }
                } header: {
                    Text("Contact")
                } footer: {
                    Text("Saved on your device for future email/text trade alerts. Not shared with others yet.")
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

                // ── Personal calendar ────────────────────────────────
                Section {
                    LabeledContent("Calendar access") {
                        Text(calendarStatusText)
                            .foregroundStyle(ekManager.isAuthorized ? .green : .red)
                    }
                    LabeledContent("Writes to") {
                        Text(ekManager.personalCalendarName)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Personal Calendar (Your Shifts)")
                } footer: {
                    Text("Your shifts are added to '\(ekManager.personalCalendarName)' automatically on every fetch. Traded shifts are removed automatically.")
                }

                // ── Shared dispatcher calendar ───────────────────────
                Section {
                    Toggle("Enable shared dispatcher calendar", isOn: $settings.sharedCalendarEnabled)

                    if settings.sharedCalendarEnabled {
                        Button {
                            ekManager.refreshAvailableCalendars()
                            showCalendarPicker = true
                        } label: {
                            HStack {
                                Label("Select 'AA Dispatch' calendar", systemImage: "calendar.badge.plus")
                                Spacer()
                                if !settings.sharedCalendarIdentifier.isEmpty {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                }
                            }
                        }

                        if let name = selectedSharedCalendarName {
                            LabeledContent("Selected") {
                                Text(name).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Shared Dispatcher Calendar")
                } footer: {
                    Text(sharedCalendarFooter)
                }
                .confirmationDialog(
                    "Select the shared dispatcher calendar",
                    isPresented: $showCalendarPicker,
                    titleVisibility: .visible
                ) {
                    ForEach(ekManager.availableCalendars, id: \.calendarIdentifier) { cal in
                        Button(cal.title) {
                            settings.sharedCalendarIdentifier = cal.calendarIdentifier
                        }
                    }
                    Button("Cancel", role: .cancel) {}
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
                                .foregroundStyle(.orange)
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

                    Button {
                        let fails = TradeEngineTests.runAll()
                        debugMessage = fails.isEmpty
                            ? "✅ All engine tests passed."
                            : "Engine test failures:\n" + fails.joined(separator: "\n")
                    } label: {
                        Label("Run engine tests", systemImage: "checkmark.shield.fill")
                    }
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
                    } else {
                        Button { showDebugPrompt = true } label: {
                            Label("Developer access", systemImage: "lock.fill")
                        }
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Unlocks moderation in the broadcast channel (delete any post or reply).")
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
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showHelp) { HelpView() }
            .sheet(isPresented: $showTesterGuide) { TesterGuideView() }
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


    private var calendarStatusText: String {
        switch ekManager.authorizationStatus {
        case .fullAccess:    return "Authorized ✓"
        case .denied:        return "Denied — enable in Settings"
        case .restricted:    return "Restricted"
        case .notDetermined: return "Not requested yet"
        default:             return "Unknown"
        }
    }

    private var selectedSharedCalendarName: String? {
        guard !settings.sharedCalendarIdentifier.isEmpty else { return nil }
        return ekManager.availableCalendars
            .first { $0.calendarIdentifier == settings.sharedCalendarIdentifier }?
            .title
    }

    private var sharedCalendarFooter: String {
        if !settings.sharedCalendarEnabled {
            return "When enabled, your off days appear on the shared dispatcher calendar so others can see your availability for trades. Your shift details are never shared."
        }
        if settings.sharedCalendarIdentifier.isEmpty {
            return "Tap 'Select calendar' to choose the shared 'AA Dispatch' calendar. The coordinator must create and share it first via iCloud."
        }
        return "Your off days will appear as '\(settings.displayName.isEmpty ? settings.username : settings.displayName) — Available' on the shared calendar."
    }

    private var formattedLastFetch: String {
        guard let date = store.lastFetchDate else { return "Never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
