// ContentView.swift
// Tab-based main interface:
//   Tab 1 — Schedule: fetch button, shift list, debug web view
//   Tab 2 — Availability: edit your off-day availability, find trade candidates

import SwiftUI
import UIKit
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
    @State private var tradesLoaded = false   // §7: create TradesView lazily on first visit (no launch cost)
    @State private var showInbox = false
    @State private var showChannel = false
    @State private var showSettings = false        // single unified Settings (opens the Trade tab by default)
    @State private var showColorKey = false        // Colors & Legend (⋯ menu)
    @State private var showDashboard = false       // trade-status dashboard (from the top-bar status strip)
    @State private var showECB = false             // ECB Accounting ledger — its own dock tile
    @State private var showChangelog = false   // Z2: "What's New" — now only from Settings, not on launch
    @AppStorage("hasOnboarded") private var hasOnboarded = false   // has completed the tour at least once
    @State private var walkthroughDismissed = false   // per-launch: closed the tour this session
    @AppStorage("tourReplayRequested") private var tourReplayRequested = false   // Settings → Replay tour
    @State private var launchLoading = true     // spinner during the initial sync so it never looks frozen
    @Environment(\.scenePhase) private var scenePhase
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
            // One clean, shared top bar (identity + utilities), laid out above the content.
            AppTopBar(showInbox: $showInbox, showChannel: $showChannel,
                      showSettings: $showSettings, showColorKey: $showColorKey,
                      showDashboard: $showDashboard, showECB: $showECB)
            // §7: content in a ZStack — BOTH tabs kept alive so state + the unsaved-intents leave guard
            // survive a switch; only the selected one is shown/hittable. Trades is created lazily on first
            // visit so its heavy feed never computes at launch.
            ZStack {
                HomeView()
                    .opacity(selectedTab == 0 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 0)
                    .zIndex(selectedTab == 0 ? 1 : 0)
                if tradesLoaded {
                    TradesView()
                        .opacity(selectedTab == 1 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 1)
                        .zIndex(selectedTab == 1 ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Quiet full-width stats row, then the FLAT tab bar flush at the bottom (§7) — nothing floats.
            TradeStatsBar()
            AppTabBar(current: selectedTab, selection: tabSelection)
        }
        .onChange(of: selectedTab) { _, t in if t == 1 { tradesLoaded = true } }
        // Radar-notification deep-link arrives → bring Home (tab 0) forward so its day-detail sheet presents.
        .onChange(of: MatchStore.shared.pendingDayID) { _, day in if day != nil { selectedTab = 0 } }
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
        .fullScreenCover(isPresented: $showInbox) { InboxView().magnifiable() }
        .fullScreenCover(isPresented: $showChannel) { ChannelView().magnifiable() }
        .sheet(isPresented: $showSettings) { SettingsView(initialTab: .trade).magnifiable() }
        .sheet(isPresented: $showColorKey) { IntentKeySheet().magnifiable() }
        .sheet(isPresented: $showDashboard) { TradeDashboardSheet().magnifiable() }
        .sheet(isPresented: $showECB) { ECBAccountingView().magnifiable() }
        .alert("Not on the app yet", isPresented: Binding(
            get: { messaging.blockedRecipient != nil },
            set: { if !$0 { messaging.blockedRecipient = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(messaging.blockedRecipient ?? "This dispatcher") doesn't have an active \(AppGuide.appName) profile, so they can't receive trade requests or messages yet. They still show in your matches — reach out another way, or wait until they set up trading in the app.")
        }
        .alert("Trade already in progress", isPresented: Binding(
            get: { messaging.duplicateNotice != nil },
            set: { if !$0 { messaging.duplicateNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(messaging.duplicateNotice ?? "")
        }
        .alert("Day already traded", isPresented: Binding(
            get: { messaging.committedNotice != nil },
            set: { if !$0 { messaging.committedNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(messaging.committedNotice ?? "")
        }
        .sheet(isPresented: $showChangelog) {
            WhatsNewView {
                settings.lastSeenChangelogBuild = AppInfo.build   // mark this build's notes seen
                showChangelog = false                             // "Continue" dismisses the sheet
            }
            .magnifiable()
        }
        // First-run identity setup — until signed in with Apple AND an ID claimed.
        .fullScreenCover(isPresented: Binding(
            get: { settings.appleUserID.isEmpty || settings.username.trimmingCharacters(in: .whitespaces).isEmpty },
            set: { _ in }
        )) {
            OnboardingView()
        }
        // Guided tour on launch — driven by the "Show Welcome on launch" toggle (ON ⇒ shows every launch,
        // OFF ⇒ never). Shown only AFTER identity is set (so it never stacks with OnboardingView), and only
        // until it's finished this session (walkthroughDismissed), so completing it closes the cover.
        .fullScreenCover(isPresented: Binding(
            get: { ((settings.showWelcomeOnLaunch && !walkthroughDismissed) || tourReplayRequested)
                   && !settings.appleUserID.isEmpty
                   && !settings.username.trimmingCharacters(in: .whitespaces).isEmpty },
            set: { _ in }
        )) {
            WelcomeWalkthrough {
                walkthroughDismissed = true   // close the cover for this session (the toggle re-shows it next launch)
                tourReplayRequested = false   // consume a one-off replay
                hasOnboarded = true
                settings.syncPrefsChanged()   // sync "completed the tour" (+ consent) across the user's devices
                // The "What's New" screen pops right after the welcome (once the cover dismisses).
                if settings.showUpdateOnLaunch {
                    Task { try? await Task.sleep(for: .milliseconds(450)); showChangelog = true }
                }
            }
            .magnifiable()   // screen magnifier available during the welcome tour too
        }
        .preferredColorScheme(AppAppearance(rawValue: settings.appearance)?.scheme)
        // Loading animation (loading.json) over the initial cross-device sync.
        .loadingOverlay(launchLoading, label: "Loading…")
        // Returning to the app (e.g. after tapping a trade-request / mention push) pulls the latest so both
        // devices show new inbox/channel items, trade status, ECB and prefs without a manual refresh.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !launchLoading { Task { await foregroundRefresh() } }
        }
        .task {
            // Home already renders from the locally-persisted schedule/intents (hydrated synchronously at
            // store init), so the loader only covers the cross-device SYNC + the mutual precompute. A hard
            // safety timeout guarantees a slow/hung CloudKit call can never trap the user on "Loading…".
            Task { try? await Task.sleep(for: .seconds(10)); launchLoading = false }
            let hasUser = !settings.username.trimmingCharacters(in: .whitespaces).isEmpty

            // PHASE 1 — the independent launch reads run CONCURRENTLY (was a strictly serial chain of
            // ~8 CloudKit round-trips, each blocking the next). None depend on another; overlapping their
            // network waits is where the loader time is won.
            async let messagingRefresh: Void = MessagingStore.shared.refresh()
            async let dmRefresh: Void         = DirectMessageStore.shared.refresh()   // 1:1 direct messages
            async let rosterRows: Int         = RosterStore.shared.syncMasterIfNewer()   // latest master
            async let privateState: Void      = PrivateStateStore.shared.syncOnLaunch()  // private notes (A3)
            async let myStatus: Void          = TradeProfileStore.shared.syncMyStatus()  // public status (A3 #12)
            async let ecb: Void               = ECBAccountingStore.shared.syncOnLaunch() // B6-ECB
            async let history: Void           = TradeHistoryStore.shared.syncOnLaunch()  // status board / history
            // ESSENTIALS ONLY gate the loader. Home renders from the LOCAL schedule/intents, and Welcome's
            // trade-prefs region gating needs the roster + my prefs — so await just those, then drop the
            // loader. Don't hold it hostage to the slowest of six concurrent CloudKit calls (that was the
            // "launch sits for a few seconds" lag). Prefs land before publish so we never republish stale.
            await TradeProfileStore.shared.syncMyPreferences()
            _ = await rosterRows                               // roster must be imported before Welcome/qual cache

            if hasUser {
                // Warm the qual cache from the now-synced roster BEFORE Welcome appears — its trade-prefs
                // region gating reads `cachedQuals` reactively.
                let q = await RosterStore.shared.schedule(forWorker: settings.username).first?.quals ?? []
                if !q.isEmpty { settings.cachedQuals = q }
                await TradeProfileStore.shared.publishMine()   // stamp `accountClaimed` so peers see us as active
            }
            // Essential data is in → Home renders locally, the app is usable. Drop the loader NOW.
            launchLoading = false
            // The first-run welcome is the WelcomeWalkthrough (full-screen cover, gated by `hasOnboarded`),
            // and it pops the What's New screen on finish. For ALREADY-onboarded users, show What's New once
            // per app update (build changed). This intentionally IGNORES the "show update notes" toggle the
            // FIRST time a new build runs — a genuinely new version always surfaces once — then `onClose`
            // records the build so it never repeats; the toggle still governs re-opening it later.
            // …but NOT while the Welcome cover is (about to be) up — presenting the What's New sheet over the
            // full-screen cover collapses the tour (it flashes, dismisses, then What's New appears). When the
            // Welcome will show, IT pops What's New on finish instead. So only auto-show here when it won't.
            let welcomeWillShow = (settings.showWelcomeOnLaunch && !walkthroughDismissed) || tourReplayRequested
            if hasOnboarded, settings.lastSeenChangelogBuild != AppInfo.build, !welcomeWillShow {
                showChangelog = true
            }

            // PHASE 2 — background housekeeping; none of it gates first paint or Welcome. The remaining
            // cross-device reads (started concurrently above) are awaited HERE, so the loader wasn't held on
            // them; the work that DEPENDS on them follows.
            _ = await (messagingRefresh, dmRefresh, privateState, myStatus, ecb, history)
            // Master import flipped my schedule to match a pending trade → auto-complete it. Needs the
            // refreshed inbox, so it runs after the messaging await. (B6-AUTOCOMPLETE.)
            if let diff = ShiftStore.shared.lastDiff, diff.hasChanges {
                await MessagingStore.shared.autoCompleteProvenTrades(diff: diff)
            }
            // Warm the "look up a dispatcher" list (12-month distinct roster) NOW, in the background, so the
            // FIRST tap into Trades isn't gated on that fetch (the reported first-time-slow). No-op if cached.
            if hasUser, TradeFeedCache.shared.allDispatchers.isEmpty {
                let now = Date(); let end = Calendar.current.date(byAdding: .month, value: 12, to: now) ?? now
                let entries = await RosterStore.shared.entries(from: now, to: end)
                let myID = settings.username
                TradeFeedCache.shared.allDispatchers = await Task.detached(priority: .utility) {
                    var seen = Set<String>(); var out: [(id: String, name: String)] = []
                    for e in entries where e.workerID != myID && seen.insert(e.workerID).inserted {
                        out.append((e.workerID, TradeNames.resolved(displayName: nil, rosterName: e.workerName, workerID: e.workerID)))
                    }
                    return out.sorted { $0.name < $1.name }
                }.value
            }
            await CloudPush.setup()                            // register push subscriptions
            WidgetData.update()
            let c = DashboardCounts.from(requests: messaging.requests, responses: messaging.responses,
                                         unread: messaging.pendingIncoming.count,
                                         pendingLedger: TradeHistoryStore.shared.pendingCount)
            await NotificationManager.shared.scheduleDailyDigest(
                enabled: settings.dailyDigestEnabled, hour: settings.dailyDigestHour,
                pending: c.pending, unread: c.unread)
            NotificationManager.shared.scheduleDigestRefresh()   // live digest: refresh counts in the background

            // Mutual-intent precompute — DEFERRED off the launch path. Runs only AFTER the UI is up and
            // interactive, at low priority, yielding per candidate (inside `intentSolutions`) so the Intents
            // badge fills in without freezing the app. The Trade Solutions / Intents feed still recompute on
            // demand (with their own loader) if a user opens them before this finishes.
            if hasUser {
                Task(priority: .utility) {
                    // Let the first interactive screen (incl. the Welcome sheet) settle before the heavy
                    // mutual precompute. `MatchContext.derive` runs at `.userInitiated` — firing it the
                    // instant Welcome appears starved the main thread and made Welcome feel frozen. Yield
                    // that window to the UI first; the Intents badge filling in a moment later is invisible.
                    try? await Task.sleep(for: .seconds(3))
                    guard TradeFeedCache.shared.snapshot("intents")?.signature != TradeFeedCache.signature(whatIf: false) else { return }
                    let mutual = await TradeRouter.intentSolutions(
                        excluding: settings.username,
                        generation: SearchFilter(engine: .both, maxPeople: settings.normalMaxPeople),
                        lucky: false, mutualOnly: true)
                    TradeFeedCache.shared.intentMatchCount = mutual.count
                    TradeFeedCache.shared.save("intents", TradeFeedCache.Snapshot(
                        signature: TradeFeedCache.signature(whatIf: false),
                        packages: [], mutualPackages: mutual, allLoaded: false,
                        rosterPeople: [], hasSearched: true))
                }
            }
        }
    }

    /// Re-pull everything that changes on the OTHER device while this one was backgrounded. Cheap, guarded,
    /// and each call has its own empty-fetch/LWW protection so a transient outage never wipes local state.
    private func foregroundRefresh() async {
        guard settings.useCloudKit,
              !settings.username.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let rosterRows = await RosterStore.shared.syncMasterIfNewer()  // admin master-schedule updates (cheap version probe)
        await MessagingStore.shared.refresh()                 // inbox + channel posts/replies
        await DirectMessageStore.shared.refresh()             // 1:1 direct messages (conversations + messages)
        await PrivateStateStore.shared.syncDMOnLaunch()       // DM read-state across YOUR devices (LWW merge)
        await TradeProfileStore.shared.refreshOthers()        // peers' latest profiles/status
        await PrivateStateStore.shared.syncIntentsOnLaunch()  // intents (LWW)
        await ECBAccountingStore.shared.syncOnLaunch()        // ECB balance + shared lines
        await TradeHistoryStore.shared.syncOnLaunch()         // status board / history
        await TradeProfileStore.shared.syncMyPreferences()    // adopt any newer prefs (incl. notifications)
        // Only when THIS refresh imported a new master: auto-complete trades it proves (B6-AUTOCOMPLETE).
        if rosterRows > 0, let diff = ShiftStore.shared.lastDiff, diff.hasChanges {
            await MessagingStore.shared.autoCompleteProvenTrades(diff: diff)
        }
        WidgetData.update()
    }
}

// MARK: - App top bar
// `AppTopBar` now lives in `DXMosaicIntegration.swift` (the mosaic drop-in: glazed avatar tile +
// identity + the palette-stripe signature rule). The former plain-row version was removed here to
// avoid a duplicate declaration.

// MARK: - Flat bottom tab bar (§7)

/// A flat, native-style Home / Trades tab bar flush at the bottom — replaces iOS 26's floating capsule so
/// nothing overlaps the calendar. Drives the guarded `tabSelection` binding (unsaved-intents leave guard
/// still fires); `current` highlights the active tab in the accent.
struct AppTabBar: View {
    let current: Int
    let selection: Binding<Int>

    var body: some View {
        HStack(spacing: 0) {
            item(0, "Home", "calendar")
            item(1, "Trades", "arrow.left.arrow.right")
        }
        .padding(.top, 8).padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))   // §11: no top hairline on the tab bar
    }

    private func item(_ i: Int, _ title: String, _ icon: String) -> some View {
        Button { selection.wrappedValue = i } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 20, weight: .regular))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(current == i ? AppColor.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(current == i ? .isSelected : [])
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
            .background(Color(.systemBackground))   // §11: no hairline above the stats strip
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

extension View {
    /// Wraps a sheet/cover root so the global screen magnifier works inside it too (sheets are separate
    /// presentation contexts the root `MagnifierHost` can't reach). Each surface gets its own zoom + button.
    func magnifiable() -> some View { MagnifierHost { self } }
}

// MARK: - Global screen magnifier (accessibility)

/// Wraps the whole app surface. A draggable, semi-transparent magnifier button (shown only when the
/// feature is enabled in App Settings) toggles zoom. While active, **two-finger pinch** zooms and
/// **two-finger drag** pans; **single-finger** touches pass straight through so the user still taps and
/// scrolls normally — mirroring iOS's built-in Zoom. Sheets are separate presentation contexts and aren't
/// scaled (v1 limitation).
struct MagnifierHost<Content: View>: View {
    @ViewBuilder var content: Content
    private var settings = SettingsManager.shared

    @State private var active = false
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var baseZoom: CGFloat = 1
    @State private var basePan: CGSize = .zero
    @State private var buttonPos: CGPoint? = nil

    private let maxZoom: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack {
                content
                    .scaleEffect(zoom, anchor: .center)
                    .offset(pan)

                if active {
                    ZoomGestureCatcher(
                        onPinch: { scale, began in
                            if began { baseZoom = zoom }
                            let z = min(max(1, baseZoom * scale), maxZoom)
                            // Snap fully back to 1× and clear pan when pinched almost all the way out, so
                            // zooming out never leaves the content slightly scaled/offset (the cut-off edge bug).
                            if z <= 1.02 { zoom = 1; pan = .zero }
                            else { zoom = z; pan = clampPan(pan, zoom: z, in: geo.size) }
                        },
                        onPan: { t, began in
                            guard zoom > 1 else { pan = .zero; return }   // nothing to pan at 1×
                            if began { basePan = pan }
                            pan = clampPan(CGSize(width: basePan.width + t.width, height: basePan.height + t.height),
                                           zoom: zoom, in: geo.size)
                        })
                    .allowsHitTesting(false)   // it installs window-level recognizers; nothing to hit here
                }

                if settings.magnifierEnabled {
                    magnifierButton(in: geo.size)
                }
            }
        }
    }

    private func clampPan(_ p: CGSize, zoom: CGFloat, in size: CGSize) -> CGSize {
        let maxX = size.width * (zoom - 1) / 2
        let maxY = size.height * (zoom - 1) / 2
        return CGSize(width: min(max(p.width, -maxX), maxX), height: min(max(p.height, -maxY), maxY))
    }

    @ViewBuilder private func magnifierButton(in size: CGSize) -> some View {
        let pos = buttonPos ?? CGPoint(x: size.width - 40, y: size.height - 150)
        Image(systemName: active ? "minus.magnifyingglass" : "plus.magnifyingglass")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(active ? Color.white : AppColor.primary)
            .frame(width: 48, height: 48)
            .background(active ? AnyShapeStyle(AppColor.primary) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
            .overlay(Circle().stroke(AppColor.primary.opacity(0.5), lineWidth: 1.5))
            .opacity(0.92)
            .shadow(radius: 3, y: 1)
            .position(pos)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        // Only treat as a drag past a small threshold; otherwise it's a tap (handled onEnded).
                        if abs(v.translation.width) + abs(v.translation.height) > 8 {
                            buttonPos = CGPoint(x: min(max(24, v.location.x), size.width - 24),
                                                y: min(max(60, v.location.y), size.height - 60))
                        }
                    }
                    .onEnded { v in
                        if abs(v.translation.width) + abs(v.translation.height) <= 8 {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                active.toggle()
                                if !active { zoom = 1; pan = .zero }
                            }
                        }
                    })
            .accessibilityLabel(active ? "Turn off magnifier" : "Magnifier — pinch with two fingers to zoom")
    }
}

/// Installs app-wide 2-finger pinch + 2-finger pan recognizers on the key window (with
/// `cancelsTouchesInView = false` + `minimumNumberOfTouches = 2`), so single-finger taps/scrolls are never
/// stolen and both fingers of a gesture are always seen regardless of which view they land on.
struct ZoomGestureCatcher: UIViewRepresentable {
    var onPinch: (CGFloat, Bool) -> Void   // (cumulative scale, began)
    var onPan: (CGSize, Bool) -> Void      // (cumulative translation, began)

    func makeCoordinator() -> Coordinator { Coordinator(onPinch: onPinch, onPan: onPan) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            guard let window = v.window ?? UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
            context.coordinator.attach(to: window)
        }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPinch = onPinch; context.coordinator.onPan = onPan
    }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.detach() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPinch: (CGFloat, Bool) -> Void
        var onPan: (CGSize, Bool) -> Void
        private weak var window: UIWindow?
        private var pinch: UIPinchGestureRecognizer?
        private var pan: UIPanGestureRecognizer?
        /// Only ONE catcher owns the window recognizers at a time — so a sheet's magnifier takes over from
        /// the main surface's cleanly (no duplicate recognizers). The most-recently-activated wins.
        private static weak var current: Coordinator?

        init(onPinch: @escaping (CGFloat, Bool) -> Void, onPan: @escaping (CGSize, Bool) -> Void) {
            self.onPinch = onPinch; self.onPan = onPan
        }
        func attach(to window: UIWindow) {
            Self.current?.detach()
            let p = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            let d = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            d.minimumNumberOfTouches = 2; d.maximumNumberOfTouches = 2
            [p, d].forEach { $0.delegate = self; $0.cancelsTouchesInView = false; window.addGestureRecognizer($0) }
            self.window = window; self.pinch = p; self.pan = d
            Self.current = self
        }
        func detach() {
            if let p = pinch { window?.removeGestureRecognizer(p) }
            if let d = pan { window?.removeGestureRecognizer(d) }
            pinch = nil; pan = nil; window = nil
            if Self.current === self { Self.current = nil }
        }
        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) { onPinch(g.scale, g.state == .began) }
        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view); onPan(CGSize(width: t.x, height: t.y), g.state == .began)
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
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
                    Text("Welcome to \(AppGuide.appName)").font(.title2.bold())
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
                await DirectMessageStore.shared.setCloudKit(true)
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

