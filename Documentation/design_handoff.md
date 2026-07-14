# DX Trader — SwiftUI design-revamp handoff (ALL views)

Paste this whole file into the design tool. It contains a briefing, the color/type
vocabulary, and the full source of every UI view to restyle. **Restyle presentation only.**

## Hard constraints (do NOT break these)
- **Route every color through `AppColor` / `BrickPalette`** (see DispatchPalette.swift). Never introduce
  raw `Color(red:…)`, `.blue`, etc. One hue = one meaning.
- Use the `DS` spacing/radius tokens and the `Font.ds*` type ramp. Keep ONE squircle control shape
  (`DS.controlRadius` = 10, `DS.controlSize` = 34) — no circles, no capsules.
- **Preserve all logic verbatim:** every `@Observable` store call (`SettingsManager`, `ShiftStore`,
  `DayIntentStore`, `MessagingStore`, `TradeProfileStore`, `RosterStore`, `ECBAccountingStore`,
  `TradeHistoryStore`), all `Binding`s, `.task` / `.onChange` / `.sheet` / `.refreshable` blocks, tap
  handlers, and the `MagnifierHost { … }` / `.magnifiable()` wrappers. Do NOT rename types, functions,
  or existing structs (`ContentView`, `AppTopBar`, `InboxView`, `ChannelView`, `SettingsView`, …).
- iOS/iPadOS only. Must work in light + dark and scale with Dynamic Type (the `Font.ds*` styles scale).
- Return drop-in replacements for `body` / subviews, leaving state, init, and data flow untouched.

## Color / type vocabulary to reuse
- Semantic: `AppColor.primary`(blue=you/actions) `.success`(green) `.pending`(amber) `.danger`(red)
  `.heat`(orange=demand) `.special`(violet=multi-way) `.vacation`(teal) `.locked`/`.passiveOpen`(slate off)
  `.neutral`. Global retune knob: `AppColor.contrast`.
- Per-seat trade identity: `TradeColors.color(forParticipant:myID:orderedPeers:)`.
- Intent hues: `WorkingIntentState.brickColor` / `OffIntentState.brickColor` — reuse, don't redefine.
- Spacing/shape: `DS.xs/s/m/l/xl`, `DS.cardRadius`(14), `DS.rowRadius`(12), `DS.pillRadius`(8).
- Type: `Font.dsCardTitle / dsCardMeta / dsChip / dsBadge / dsLabel`.
- Shared atoms (reuse, don't reinvent): `Avatar`, `SlackComposer`, `AnimatedLoader`/`LoadingOverlay`,
  `ReactionChips`, `CharCounter`, `CollapsibleLegend` — all in SlackKit.swift.

## Views included below (whole app UI surface)
1.  DispatchPalette.swift — theme / color source of truth
2.  ContentView.swift — root TabView + `AppTopBar` header + `TradeStatsBar` + `MagnifierHost`
3.  HomeView.swift — Home tab (calendar host + Mark-Intents toolbar + import)
4.  HomeCalendar.swift — month intent calendar + `TradeSettingsSheet` (profile / trade-settings editor)
5.  TradesView.swift — Trades tabs + `TradeDashboardSheet` (Trade Status board)
6.  TradeIntentsFeed.swift — Intents marketplace feed + trade cards
7.  AvailabilityView.swift — Find candidates, `TwoWaySheet`, `ECBAccountingView`
8.  MessagingViews.swift — `InboxView`, `ThreadView`, `ChannelView` (inbox + channels + 1:1 chat)
9.  SettingsView.swift — App Settings
10. HelpView.swift — Welcome / What's New / help / tester guide
11. ShiftSelectCalendar.swift — compact multi-select day-picker calendar
12. SlackKit.swift — shared UI atoms (Avatar, composer, loaders, chips, legend)

---


## `Sources/App/DispatchPalette.swift`

```swift
// DispatchPalette.swift
// THE single color language for the app. One hue = one meaning, so a color can be
// decoded at a glance. `AppColor` is the source of truth (Tier 1 = semantic, Tier 2 =
// categorical identity). Everything else — the legacy `BrickPalette` names, the intent /
// status / staging extensions, avatars, and trade-seat colors — resolves to `AppColor`,
// so re-tuning a hue is a one-line change here.
//
// Tier 1 — SEMANTIC (functional meaning; never reuse a hue for two meanings):
//   primary  (blue)   actions · links · selection · "you" · info
//   success  (green)  accepted · kept · authorized · optimal · done
//   pending  (amber)  waiting · caution · "want to work"
//   danger   (red)    declined · error · destructive · over-limit
//   heat     (orange) demand / urgency ONLY
//   special  (violet) multi-way / circular trades · "trade away"
//   milestone(pink)   a protected personal date (rare)
//   neutral  (gray)   cancelled · inert · no intent
//   locked / passiveOpen / vacation — the cooler off-day states
//
// Tier 2 — CATEGORICAL (identity only, NO meaning): avatars and per-seat trade colors.

import SwiftUI

// MARK: - Design tokens (one source of truth for rhythm, radius, and type)

/// Spacing / radius / sizing scale on a 4-pt grid, so every card, pill, and gutter
/// shares the same rhythm instead of ad-hoc values.
enum DS {
    static let xs: CGFloat = 4
    static let s:  CGFloat = 8
    static let m:  CGFloat = 12
    static let l:  CGFloat = 16
    static let xl: CGFloat = 24

    static let cardRadius: CGFloat = 14   // feature cards (package, route, key, dashboard)
    static let cardPadding: CGFloat = 14
    static let rowRadius: CGFloat = 12    // compact selectable list rows (candidate cells)
    static let pillRadius: CGFloat = 8
    static let pillFill: Double = 0.16    // one tint strength for all chips/pills
    static let avatar: CGFloat = 30
    // ONE control shape for the whole app: every button / chip / icon toggle is a rounded-rect
    // (squircle) of this radius + height — matching the calendar day cells. No circles, no capsules.
    static let controlRadius: CGFloat = 10
    static let controlSize: CGFloat = 34   // square icon-button side, and the height of text controls
}

/// Semantic type ramp — built on Dynamic Type styles so everything scales for
/// accessibility, replacing scattered `.system(size:)` literals.
extension Font {
    // R2-#10d: scaled up so card content reads near the headline size (was a tier smaller).
    static let dsCardTitle = Font.subheadline.weight(.semibold) // card headlines, names
    static let dsCardMeta  = Font.caption                       // subtitles, statuses (was caption2)
    static let dsChip      = Font.subheadline.weight(.semibold) // day chips (was caption)
    static let dsBadge     = Font.caption.weight(.heavy)        // pills / counts (was caption2)
    static let dsLabel     = Font.caption.weight(.bold)         // small section labels (was caption2)
}

/// THE color language. Tier 1 tokens carry meaning (one hue per meaning); Tier 2 is a
/// categorical ramp for identity only. Fresh reduced palette — harmonized saturation/
/// luminance so hues sit together cleanly in light and dark.
enum AppColor {
    /// Global contrast knob: every palette color's channels are scaled toward/away from mid-gray by this
    /// factor, so the whole app (and the legend, which uses these same tokens) retunes from one place.
    /// 1.00 = raw definition; 0.92 = −8% contrast (softer, current). Change here to retune the ENTIRE app.
    static let contrast: Double = 0.92
    /// Build a palette color with the global contrast applied to each channel.
    private static func c(_ r: Double, _ g: Double, _ b: Double) -> Color {
        func adj(_ v: Double) -> Double { min(1, max(0, 0.5 + (v - 0.5) * contrast)) }
        return Color(red: adj(r), green: adj(g), blue: adj(b))
    }

    // ── Tier 1 · semantic ────────────────────────────────────────────────
    static let primary   = c(0.16, 0.43, 0.88)  // blue — actions, links, selection, "you", info
    static let success   = c(0.20, 0.66, 0.33)  // green — accepted, kept, authorized, optimal, done
    static let pending   = c(0.90, 0.63, 0.11)  // amber — waiting, caution, "want to work"
    static let danger    = c(0.84, 0.24, 0.22)  // red — declined, error, destructive
    static let heat      = c(0.95, 0.45, 0.16)  // orange — demand / urgency ONLY
    static let special   = c(0.49, 0.33, 0.83)  // violet — multi-way / circular / trade-away
    static let milestone = c(0.89, 0.35, 0.63)  // pink — protected personal date (rare)
    static let neutral   = Color(.systemGray)    // cancelled / inert / no intent (system-managed)

    // Cooler off-day states (kept distinct from worked-day hues).
    static let locked      = c(0.29, 0.32, 0.52) // slate — "must be off" (locked)
    static let passiveOpen = c(0.45, 0.53, 0.60) // faded slate-blue — passively open
    static let vacation    = c(0.11, 0.60, 0.55) // teal — a day OFF on vacation

    /// Your schedule reads in the action/"you" blue on every trade surface.
    static var mine: Color { primary }

    // ── Tier 2 · categorical (identity only — assign NO meaning) ──────────
    /// Evenly spaced, equal-weight hues for avatars and per-seat trade colors. Index 0 is
    /// unused for "you" (you're always `mine`/blue); peers cycle from index 1 so a peer is
    /// never the danger red or success green by coincidence of meaning.
    static let categorical: [Color] = [
        primary,               // 0 — blue (you)
        c(0.85, 0.30, 0.34),   // 1 — red
        c(0.93, 0.55, 0.16),   // 2 — orange
        c(0.24, 0.64, 0.36),   // 3 — green
        special,               // 4 — violet
        c(0.82, 0.30, 0.55),   // 5 — magenta
        c(0.13, 0.62, 0.60),   // 6 — teal
    ]
}

/// Legacy names, kept as thin aliases so existing call sites and domain extensions keep
/// compiling — every one now resolves to an `AppColor` token (the single source of truth).
enum BrickPalette {
    static let clear     = AppColor.success
    static let change    = AppColor.special
    static let info      = AppColor.primary
    static let caution   = AppColor.pending
    static let warning   = AppColor.heat
    static let critical  = AppColor.danger
    static let milestone = AppColor.milestone
    static let neutral   = AppColor.neutral
    static let availableOff = AppColor.pending      // "want to work" reads as active/attention (amber)
    static let openOff      = AppColor.passiveOpen
    static let lockedOff    = AppColor.locked
    static let vacation     = AppColor.vacation
    // Trade-calendar signature: you = blue; peers cycle the categorical ramp.
    static let mineScheme = AppColor.mine
    static let peerScheme = AppColor.categorical[1]   // the two-person counterparty seat
    static let loopTrade  = AppColor.special
    /// Per-seat trade colors (you are always `mineScheme`). Peers take categorical seats 1…N.
    static let traderThemes: [Color] = Array(AppColor.categorical.dropFirst())
    static let highImpact = AppColor.heat             // high-demand date marker
    static let personalDay = AppColor.milestone
}

// MARK: - Legend (the ONE comprehensive color key — drives the info sheet + every collapsible legend)

/// Single source of truth for "what does each color/marker mean". Rendered comprehensively in the
/// info Color Key sheet and, collapsed-by-default, in the inline legends under the trade feeds.
enum AppLegend {
    enum Swatch { case fill(Color); case border(Color); case icon(String, Color); case glyph(String) }
    struct Item: Identifiable { let id = UUID(); let swatch: Swatch; let name: String; let meaning: String }
    struct Section: Identifiable { let id = UUID(); let title: String; let items: [Item] }

    static let sections: [Section] = [
        Section(title: "Trade calendars", items: [
            Item(swatch: .fill(AppColor.mine), name: "You give",
                 meaning: "Your shift, moving to someone else"),
            Item(swatch: .fill(AppColor.categorical[1]), name: "You get",
                 meaning: "Their shift, coming to you"),
            Item(swatch: .icon("person.2.fill", AppColor.special), name: "Multi-way",
                 meaning: "In 3+ person trades each person has their own color"),
        ]),
        Section(title: "Intent colors", items: [
            Item(swatch: .fill(WorkingIntentState.dontWantToWork.brickColor), name: "Trade away",
                 meaning: "A working day you want to give away"),
            Item(swatch: .fill(WorkingIntentState.mustWork.brickColor), name: "Keep — working shift",
                 meaning: "A working day you'll never trade away (green = keep this shift)"),
            Item(swatch: .fill(OffIntentState.wantToWork.brickColor), name: "Want to work",
                 meaning: "An off day you'd pick up a shift on"),
            Item(swatch: .fill(OffIntentState.mustBeOff.brickColor), name: "Blackout / blacklisted",
                 meaning: "Slate = blocked: an off day you'll never work, or a shift type / region / desk / weekday you've blacklisted — never offered"),
            Item(swatch: .fill(OffIntentState.neutralOpen.brickColor), name: "Open",
                 meaning: "An off day you're passively available — no strong preference"),
            Item(swatch: .fill(AppColor.vacation), name: "Vacation",
                 meaning: "A day off on approved vacation"),
            Item(swatch: .fill(AppColor.neutral), name: "Neutral",
                 meaning: "Nothing marked for this day"),
        ]),
        Section(title: "Trade quality & status", items: [
            Item(swatch: .fill(AppColor.success), name: "Optimal / accepted",
                 meaning: "Fewest people to cover — or an agreed trade"),
            Item(swatch: .fill(AppColor.pending), name: "Pending",
                 meaning: "Waiting on a reply"),
            Item(swatch: .fill(AppColor.danger), name: "Declined",
                 meaning: "Rejected, expired, or cancelled"),
            Item(swatch: .fill(AppColor.special), name: "Circular",
                 meaning: "A multi-person loop trade"),
            Item(swatch: .fill(AppColor.heat), name: "High demand",
                 meaning: "A hot / high-demand date"),
        ]),
        Section(title: "Markers & borders", items: [
            Item(swatch: .border(AppColor.heat), name: "High-demand date",
                 meaning: "Orange border on the calendar"),
            Item(swatch: .border(AppColor.milestone), name: "Personal milestone",
                 meaning: "A protected personal date"),
            Item(swatch: .icon("note.text", AppColor.primary), name: "Note",
                 meaning: "Tap the day to read it"),
            Item(swatch: .glyph("🔥"), name: "Mutual intent",
                 meaning: "You both want this exact move"),
            Item(swatch: .glyph("📖"), name: "Bookend",
                 meaning: "Attaches cleanly to existing work / off"),
            Item(swatch: .glyph("🤖"), name: "Not on the app yet",
                 meaning: "This dispatcher hasn't set up trading — they show in matches but can't receive messages until they join"),
        ]),
    ]
}

/// F1: POSITIONAL trade colors, used by every trade surface. You are always `mineScheme` (blue);
/// each peer takes a SEAT color by their order in the trade — seat 1 (2nd person) = red, 2 = orange,
/// 3 = green, … `orderedPeers` is the list of non-me participants in seat order.
enum TradeColors {
    static func color(forParticipant id: String, myID: String, orderedPeers: [String]) -> Color {
        if id == myID { return BrickPalette.mineScheme }
        let idx = orderedPeers.firstIndex(of: id) ?? 0
        return BrickPalette.traderThemes[idx % BrickPalette.traderThemes.count]
    }
}

/// G2c: a PEER's published-intent calendar tint for `day` — so the two-way view shows their
/// FULL intent picture, not just trade-away. Precedence (strongest first): must-be-off → keep
/// → trade-away (seeking) → want-to-work; nil if the peer marked nothing for that day.
enum PeerIntentColor {
    static func forDay(_ day: String, seeking: Set<String>, wantToWork: Set<String>,
                       mustBeOff: Set<String>, keep: Set<String>) -> Color? {
        if mustBeOff.contains(day)  { return OffIntentState.mustBeOff.brickColor }
        if keep.contains(day)       { return WorkingIntentState.mustWork.brickColor }
        if seeking.contains(day)    { return WorkingIntentState.dontWantToWork.brickColor }
        if wantToWork.contains(day) { return OffIntentState.wantToWork.brickColor }
        return nil
    }
}

// MARK: - Intent → brick color

extension WorkingIntentState {
    /// Calendar fill hue for a worked day with this intent.
    var brickColor: Color {
        switch self {
        case .dontWantToWork:        return BrickPalette.change  // trading it away
        case .mustWork, .wantToWork: return BrickPalette.clear   // keeping / happy to work it
        case .neutralOpen:           return BrickPalette.neutral
        }
    }
}

extension OffIntentState {
    /// Calendar fill hue for an off day with this intent. Off-day hues are
    /// deliberately cooler/more muted than worked-day hues, and "open" (passive
    /// availability) is a faded slate — clearly NOT the amber active "want to work".
    var brickColor: Color {
        switch self {
        case .wantToWork:  return BrickPalette.availableOff  // amber — actively soliciting
        case .mustBeOff:   return BrickPalette.lockedOff      // slate — locked off
        case .neutralOpen: return BrickPalette.openOff        // faded slate-blue — passively open
        }
    }
}

extension DayTopology {
    /// Border accent for a date's "gravity".
    var accent: Color {
        switch self {
        case .standard:          return .clear
        case .highDemand:        return BrickPalette.warning   // orange alert
        case .personalMilestone: return BrickPalette.milestone // pink
        }
    }
}

// MARK: - Trade staging → brick color

extension StagingState {
    var brickColor: Color {
        switch self {
        case .acceptedInApp:        return BrickPalette.clear
        case .pendingNegotiation:   return BrickPalette.caution
        case .denied:               return BrickPalette.critical
        case .markedOfficialByUser: return BrickPalette.info
        }
    }
}

```


## `Sources/App/ContentView.swift`

```swift
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
    @State private var showInbox = false
    @State private var showChannel = false
    @State private var showTradeSettings = false  // settings (moved into the dock, on every tab)
    @State private var showAppSettings = false
    @State private var showDashboard = false       // trade-status dashboard (from the top-bar status strip)
    @State private var showECB = false             // ECB Accounting ledger (⋯ menu)
    @State private var showChangelog = false   // Z2: startup "What's New"
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
            // One clean, shared top bar (identity + utilities) — replaces the old floating dock that
            // overlapped the status header. Laid out above the tabs, so nothing overlaps.
            AppTopBar(showInbox: $showInbox, showChannel: $showChannel,
                      showTradeSettings: $showTradeSettings, showAppSettings: $showAppSettings,
                      showDashboard: $showDashboard, showECB: $showECB)
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
        .fullScreenCover(isPresented: $showInbox) { InboxView().magnifiable() }
        .fullScreenCover(isPresented: $showChannel) { ChannelView().magnifiable() }
        .sheet(isPresented: $showTradeSettings) { TradeSettingsSheet().magnifiable() }
        .sheet(isPresented: $showAppSettings) { SettingsView().magnifiable() }
        .sheet(isPresented: $showDashboard) { TradeDashboardSheet().magnifiable() }
        .sheet(isPresented: $showECB) { ECBAccountingView().magnifiable() }
        .alert("Not on the app yet", isPresented: Binding(
            get: { messaging.blockedRecipient != nil },
            set: { if !$0 { messaging.blockedRecipient = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(messaging.blockedRecipient ?? "This dispatcher") doesn't have an active \(AppGuide.appName) profile, so they can't receive trade requests or messages yet. They still show in your matches — reach out another way, or wait until they set up trading in the app.")
        }
        .sheet(isPresented: $showChangelog) {
            WelcomeView {
                settings.lastSeenChangelogBuild = AppInfo.build   // mark seen on dismiss
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
        .preferredColorScheme(AppAppearance(rawValue: settings.appearance)?.scheme)
        .loadingOverlay(launchLoading, label: "Loading…")   // spinner during the initial sync
        // Returning to the app (e.g. after tapping a trade-request / mention push) pulls the latest so both
        // devices show new inbox/channel items, trade status, ECB and prefs without a manual refresh.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !launchLoading { Task { await foregroundRefresh() } }
        }
        .task {
            defer { launchLoading = false }
            await MessagingStore.shared.refresh()
            _ = await RosterStore.shared.syncMasterIfNewer()   // pull the latest master roster
            await PrivateStateStore.shared.syncOnLaunch()      // private notes across your devices (A3)
            await TradeProfileStore.shared.syncMyStatus()      // public status across your devices (A3 #12)
            await TradeProfileStore.shared.syncMyPreferences() // trade prefs across your devices — BEFORE publish
            if !settings.username.trimmingCharacters(in: .whitespaces).isEmpty {
                await TradeProfileStore.shared.publishMine()   // stamp our profile `accountClaimed` so peers see us as active
            }
            await ECBAccountingStore.shared.syncOnLaunch()     // B6-ECB: shared lines + personal blob
            await TradeHistoryStore.shared.syncOnLaunch()      // status board / history across your devices
            // If the master import flipped my schedule to match a pending trade, auto-complete it (B6-AUTOCOMPLETE).
            if let diff = ShiftStore.shared.lastDiff, diff.hasChanges {
                await MessagingStore.shared.autoCompleteProvenTrades(diff: diff)
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
            // Show "What's New" on launch (not over onboarding). If the user turned OFF "show on every
            // launch," it only appears after an app update — a build they haven't seen yet.
            let isNewBuild = settings.lastSeenChangelogBuild != AppInfo.build
            if !settings.username.trimmingCharacters(in: .whitespaces).isEmpty,
               settings.showWelcomeOnLaunch || isNewBuild {
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

    /// Re-pull everything that changes on the OTHER device while this one was backgrounded. Cheap, guarded,
    /// and each call has its own empty-fetch/LWW protection so a transient outage never wipes local state.
    private func foregroundRefresh() async {
        guard settings.useCloudKit,
              !settings.username.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let rosterRows = await RosterStore.shared.syncMasterIfNewer()  // admin master-schedule updates (cheap version probe)
        await MessagingStore.shared.refresh()                 // inbox + channel posts/replies
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

// MARK: - App top bar (shared identity + utilities, replaces the floating dock)

/// The single header bar at the very top of the app, on every tab. Left: the signed-in
/// dispatcher's avatar + name (and their live status, only if they've set one — no "set a
/// status" nudge). Right: just three controls — Inbox · Channel · ⋯ (overflow: Trade status,
/// Colors & legend, Trade/App Settings). One row, laid out (not floating), never overlapping.
struct AppTopBar: View {
    @Binding var showInbox: Bool
    @Binding var showChannel: Bool
    @Binding var showTradeSettings: Bool
    @Binding var showAppSettings: Bool
    @Binding var showDashboard: Bool
    @Binding var showECB: Bool
    private var settings = SettingsManager.shared

    init(showInbox: Binding<Bool>, showChannel: Binding<Bool>,
         showTradeSettings: Binding<Bool>, showAppSettings: Binding<Bool>,
         showDashboard: Binding<Bool>, showECB: Binding<Bool>) {
        _showInbox = showInbox; _showChannel = showChannel
        _showTradeSettings = showTradeSettings; _showAppSettings = showAppSettings
        _showDashboard = showDashboard; _showECB = showECB
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
            MessagingDock(showInbox: $showInbox, showChannel: $showChannel,
                          showTradeSettings: $showTradeSettings, showAppSettings: $showAppSettings,
                          showDashboard: $showDashboard, showECB: $showECB)
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
                            zoom = min(max(1, baseZoom * scale), maxZoom)
                            pan = clampPan(pan, zoom: zoom, in: geo.size)
                        },
                        onPan: { t, began in
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


```


## `Sources/UI/Home/HomeView.swift`

```swift
// HomeView.swift
// v2 Home tab — the evolved Schedule page: a robust vertical-scrolling month
// calendar with per-day trade-intent marking, layer toggles, a snapshot banner,
// and a tabbed Trade Settings sheet. Intent is read/written through DayIntentStore
// (the single source of truth); the calendar layout descends from
// ScheduleCalendarView.

import SwiftUI

// MARK: - Marking mode

enum IntentMode: String, CaseIterable, Identifiable {
    case off = "Main View"
    case workingShifts = "Working Shifts"
    case daysOff = "Days Off"
    var id: String { rawValue }
}

/// Which optional overlays the calendar draws.
struct LayerVisibility {
    var notes = true          // DayNote markers
    var intentOverlays = true // intent tints
    var availability = true   // AM/PM/MID pickup markers on off days (#2: now toggleable)
    var shiftType = true       // show the shift TYPE (AM/PM/MID) on worked days
    var deskAssignments = true // show the desk on worked days ("PM 32" vs just "PM")
}

// MARK: - Home

struct HomeView: View {

    private let store    = ShiftStore.shared
    private let settings = SettingsManager.shared
    private var intents  = DayIntentStore.shared

    @State private var mode: IntentMode = .off
    @State private var layers = LayerVisibility()
    @State private var editTarget: DayEditTarget?     // day tap (any mode) → full DayIntentEditor
    @State private var changedDays: Set<String> = []
    @State private var showBanner = false
    @AppStorage("batman.v2.lastReconciledFetch") private var lastReconciledFetch: Double = 0
    @State private var flashChanged = false
    @State private var offBrush: ShiftAvailabilityType?   // nil = generic "want to work"
    @State private var workBrush: WorkingIntentState = .dontWantToWork
    @State private var offIntentBrush: OffIntentState = .wantToWork   // direct off-day intent brush (F1)
    @State private var noteBrush = ""   // F2: when set, each tapped day also gets this note
    @State private var clearNoteMode = false   // when on, tapping a day CLEARS its note (no intent paint)
    @State private var showColorKey = false    // color key / legend (its own button, left of the layers toggle)
    @State private var pendingConflict: PendingConflict?
    @State private var overwriteConfirmed = false   // #10: ask-overwrite ONCE per mass-action session
    @State private var showLeaveGuard = false        // C1 phase-2: Save-or-Discard when leaving with unsaved edits

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showBanner, !changedDays.isEmpty {
                    updateBanner
                }
                // ONE control row (not editing): primary action on the left; the ambient trades stat
                // + layers toggle grouped on the right. Collapses the old 3 stacked strips into one,
                // killing the dead space. While editing, the edit panel takes over this space.
                if mode == .off {
                    HStack(spacing: 10) {
                        markIntentsPill
                        Spacer(minLength: 8)
                        // Successful-trade stats moved to the shared bottom bar (TradeStatsBar) so the top
                        // of the calendar isn't crowded (B6-STATS). Color Key sits just left of the layers toggle.
                        colorKeyButton
                        VisibilityToolbar(layers: $layers)
                    }
                    .padding(.horizontal).padding(.vertical, 6)
                    // Intent tally under the Mark Intents button (full "Want to Trade/Work" labels are too
                    // wide to sit inline without wrapping on iPhone). Centered; hidden when no intents.
                    IntentTallyBar(centered: true)
                }
                homeNotesBar
                MarkIntentsToolbar(mode: $mode, offBrush: $offBrush, workBrush: $workBrush,
                                   offIntentBrush: $offIntentBrush, noteBrush: $noteBrush,
                                   clearNoteMode: $clearNoteMode, layers: $layers,
                                   onSave: saveIntents, onDone: attemptLeaveEditing)
                Divider()

                if store.shifts.isEmpty {
                    ContentUnavailableView(
                        "No Schedule Loaded",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Import your schedule on the Trades tab or wait for the next master sync."))
                } else {
                    IntentCalendarView(
                        shifts: store.shifts,
                        mode: mode,
                        layers: layers,
                        flashDays: flashChanged ? changedDays : [],
                        onTap: handleTap,
                        // Detailed per-day editor only inside Mark Intents — general view is read-only.
                        onLongPress: { day, isOff in
                            if mode != .off { editTarget = DayEditTarget(dayID: day, isOff: isOff) }
                        })
                }

                // (Last-synced + app version moved to App Settings; the Home page ends at the calendar.)
            }
            .navigationTitle(AppGuide.appName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)   // the shared AppTopBar is the header now
            .sheet(item: $editTarget) { target in
                DayIntentEditor(target: target)
                    .magnifiable()
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showColorKey) { IntentKeySheet() }
            .alert("Overwrite existing marks?", isPresented: Binding(
                get: { pendingConflict != nil }, set: { if !$0 { pendingConflict = nil } })) {
                Button("Overwrite", role: .destructive) { pendingConflict?.apply(); pendingConflict = nil }
                Button("Cancel", role: .cancel) { pendingConflict = nil }
            } message: {
                Text("This day is already marked \"\(pendingConflict?.existing ?? "")\". Overwrite it? You won't be asked again while painting with this brush.")
            }
            .confirmationDialog("Unsaved intent changes", isPresented: $showLeaveGuard, titleVisibility: .visible) {
                Button("Save") {
                    saveIntents()
                    withAnimation(.snappy) { mode = .off }
                }
                Button("Discard", role: .destructive) {
                    intents.discardChanges()
                    withAnimation(.snappy) { mode = .off }
                }
                Button("Keep Editing", role: .cancel) {}
            } message: { Text("You have unsaved marks. Save them so your trades update, or discard to revert.") }
            .onAppear(perform: reconcileSnapshot)
            // R-B: load peers when Home appears so matching/status reflect what everyone published.
            // Also re-pull MY intents + trade prefs from the private DB so a change made on another
            // device shows here (LWW; won't clobber unsaved local edits). Was launch-only before.
            .task {
                await TradeProfileStore.shared.refreshOthers()
                await PrivateStateStore.shared.syncIntentsOnLaunch()
                await TradeProfileStore.shared.syncMyPreferences()
            }
            .onChange(of: mode) { _, new in
                overwriteConfirmed = false   // #10: new marking session re-asks once
                // Finished marking → publish updated availability pills for matching.
                if new == .off { Task { await TradeProfileStore.shared.publishMine() } }
            }
            .onChange(of: workBrush) { _, _ in overwriteConfirmed = false }
            .onChange(of: offIntentBrush) { _, _ in overwriteConfirmed = false }
            .onChange(of: offBrush) { _, _ in overwriteConfirmed = false }
        }
    }

    // MARK: CSV import (admin publishes the shared master roster)

    // MARK: Pieces

    /// Enters Mark-Intents (edit) mode — lives on the left of the header row.
    private var markIntentsPill: some View {
        Button { withAnimation(.snappy) { mode = .workingShifts } } label: {
            Label("Mark Intents", systemImage: "pencil.and.list.clipboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(height: DS.controlSize)
                .padding(.horizontal, 14)
                .background(Color.accentColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Color key / legend — a dedicated icon button just left of the layers (visibility) toggle. Same
    /// control shape as VisibilityToolbar; opens the shared `IntentKeySheet`.
    private var colorKeyButton: some View {
        Button { showColorKey = true } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: DS.controlSize, height: DS.controlSize)
                .foregroundStyle(Color.primary)
                .background(Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colors & legend")
    }

    /// Read-only one-line view of your private notes (from Trade Settings), swipe to
    /// read overflow. Hidden when empty. No vertical padding — sits tight under the row.
    @ViewBuilder private var homeNotesBar: some View {
        if !settings.privateNotes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(settings.privateNotes)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal)
            }
        }
    }

    private var updateBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(AppColor.pending)
            VStack(alignment: .leading, spacing: 2) {
                Text("Schedule Updated").font(.subheadline.bold())
                Text("^[\(changedDays.count) date](inflect: true) changed. Tap to review and re-mark your intents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { withAnimation { showBanner = false } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(AppColor.pending.opacity(0.12))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { flashChanged = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { flashChanged = false } }
        }
    }


    // MARK: Actions

    /// SAVE: persist baseline + bump the revision so the trade feeds recompute once,
    /// and re-publish availability. Clears the dirty flag (the glowing Save button dims).
    private func saveIntents() {
        intents.markIntentsSaved()
        Task { await TradeProfileStore.shared.publishMine() }
        Task { await PrivateStateStore.shared.publishLocalIntents() }   // B4-2: sync full intents across devices
    }

    /// Leaving the Mark Intents section: if there are unsaved edits, force Save-or-Discard;
    /// otherwise exit cleanly.
    private func attemptLeaveEditing() {
        if intents.hasUnsavedChanges { showLeaveGuard = true }
        else { withAnimation(.snappy) { mode = .off } }
    }

    /// Single tap: apply the mode's default intent, toggling it off if already set.
    /// If the day already carries a *different* explicit intent, confirm first.
    private func handleTap(day: String, isOff: Bool) {
        // Clear-note brush: while active, a tap ONLY clears that day's note (no intent paint), so you can
        // sweep dates to wipe notes. Works in both Working and Days-Off sub-modes.
        if mode != .off, clearNoteMode {
            intents.setNote(nil, forDay: day)
            return
        }
        switch mode {
        case .off:
            // Outside Mark Intents a day tap opens the FULL day editor (intent, reason, note,
            // significant-day, and the vacation traded-in toggle) — edit anything in one tap.
            editTarget = DayEditTarget(dayID: day, isOff: isOff)
        case .workingShifts:
            guard !isOff else { return }
            stampNote(day)
            applyWorking(workBrush, on: day)
        case .daysOff:
            guard isOff else { return }
            stampNote(day)
            if let brush = offBrush {                       // AM/PM/MID granular pill brush
                // Only legal pickup types can be set.
                guard Legality.legalTypes(forDayID: day, shifts: store.shifts).contains(brush) else { return }
                intents.toggleAvailability(brush, forDay: day)
                return
            }
            applyOff(offIntentBrush, on: day)               // direct off-intent brush
        }
    }

    /// Apply the selected off-day intent brush to a day (toggle off if same;
    /// confirm if it would overwrite a different intent). Mirrors `applyWorking`.
    private func applyOff(_ brush: OffIntentState, on day: String) {
        // #1: Want-to-Work needs a legally-coverable shift; a fully rest-blocked off day can't be marked.
        if brush == .wantToWork, Legality.legalTypes(forDayID: day, shifts: store.shifts).isEmpty { return }
        let current = intents.offIntent(forDay: day)
        if current == brush { intents.setOffIntent(nil, forDay: day); return }
        if let current, !overwriteConfirmed {
            pendingConflict = PendingConflict(dayID: day, existing: current.label) {
                overwriteConfirmed = true                 // #10: confirm once, then paint freely
                intents.setOffIntent(brush, forDay: day)
            }
            return
        }
        intents.setOffIntent(brush, forDay: day)
    }

    /// Apply the selected working-shift brush to a day (toggle off if same;
    /// confirm if it would overwrite a different intent).
    private func applyWorking(_ brush: WorkingIntentState, on day: String) {
        let current = intents.workingIntent(forDay: day)
        if current == brush { intents.setWorkingIntent(nil, forDay: day); return }
        if let current, !overwriteConfirmed {
            pendingConflict = PendingConflict(dayID: day, existing: current.label) {
                overwriteConfirmed = true                 // #10: confirm once, then paint freely
                intents.setWorkingIntent(brush, forDay: day)
            }
            return
        }
        intents.setWorkingIntent(brush, forDay: day)
    }

    /// F2: while a note-stamp is set, every tapped day also gets that note.
    private func stampNote(_ day: String) {
        let text = noteBrush.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        intents.setNote(DayNote(dayID: day, message: text), forDay: day)
    }

    /// On appear: clear intent for any date whose worked/off status flipped since
    /// the last snapshot, and surface a banner so the user can re-map them.
    private func reconcileSnapshot() {
        // Diff-based: reset intents ONLY for days the new master actually changed,
        // never the unchanged majority (SPEC_STRUCTURAL.md S-PARSE-2). Run once per
        // fetch so a user's fresh re-mark of a changed day isn't wiped on re-appear.
        guard let diff = store.lastDiff, diff.hasChanges else { return }
        let fetchStamp = store.lastFetchDate?.timeIntervalSince1970 ?? 0
        guard fetchStamp > lastReconciledFetch else { return }
        lastReconciledFetch = fetchStamp
        let wiped = intents.reconcile(diff: diff)
        if !wiped.isEmpty {
            changedDays = wiped
            withAnimation { showBanner = true }
        }
    }
}

// MARK: - Mark Intents toolbar (collapsible)

struct MarkIntentsToolbar: View {
    @Binding var mode: IntentMode
    @Binding var offBrush: ShiftAvailabilityType?
    @Binding var workBrush: WorkingIntentState
    @Binding var offIntentBrush: OffIntentState
    @Binding var noteBrush: String
    @Binding var clearNoteMode: Bool       // when on, tapping a day clears its note
    @Binding var layers: LayerVisibility   // layers menu rides in the top row while editing
    var onSave: () -> Void          // SAVE this session's marks (clears the dirty glow)
    var onDone: () -> Void          // leave the section (guarded if there are unsaved edits)
    private var intents = DayIntentStore.shared

    init(mode: Binding<IntentMode>, offBrush: Binding<ShiftAvailabilityType?>,
         workBrush: Binding<WorkingIntentState>, offIntentBrush: Binding<OffIntentState>,
         noteBrush: Binding<String>, clearNoteMode: Binding<Bool>, layers: Binding<LayerVisibility>,
         onSave: @escaping () -> Void, onDone: @escaping () -> Void) {
        _mode = mode; _offBrush = offBrush; _workBrush = workBrush
        _offIntentBrush = offIntentBrush; _noteBrush = noteBrush; _clearNoteMode = clearNoteMode; _layers = layers
        self.onSave = onSave; self.onDone = onDone
    }

    var body: some View {
        Group {
            if mode != .off {
                editPanel.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// Secondary edit panel: a two-way Working/Days-Off switch + brushes + Done.
    private var editPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $mode.animation(.easeInOut)) {
                    Text("Working Shifts").tag(IntentMode.workingShifts)
                    Text("Days Off").tag(IntentMode.daysOff)
                }
                .pickerStyle(.segmented)
                VisibilityToolbar(layers: $layers)
                Button { onDone() } label: {
                    Text("Done").font(.subheadline.weight(.bold))
                }
            }
            .padding(.horizontal)

            if mode == .workingShifts {
                workingPills
            } else if mode == .daysOff {
                availabilityPills
            }
            // F2: optional note stamped onto every day you tap. The eraser toggles a "clear notes" brush —
            // while on, tapping days wipes their notes instead of stamping.
            HStack(spacing: 8) {
                Image(systemName: "note.text").foregroundStyle(.secondary)
                TextField(clearNoteMode ? "Tap days to clear their notes" : "Stamp a note on tapped days (optional)",
                          text: $noteBrush)
                    .font(.subheadline)
                    .disabled(clearNoteMode)
                    .foregroundStyle(clearNoteMode ? .secondary : .primary)
                    .onChange(of: noteBrush) { _, v in if v.count > DayNote.maxLength { noteBrush = String(v.prefix(DayNote.maxLength)) } }
                if !clearNoteMode, !noteBrush.isEmpty {
                    CharCounter(text: noteBrush, limit: DayNote.maxLength)
                    Button { noteBrush = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
                // Clear-note brush toggle (to the right of the note input).
                Button {
                    clearNoteMode.toggle()
                    if clearNoteMode { noteBrush = "" }   // the two brushes are mutually exclusive
                } label: {
                    Image(systemName: "eraser.line.dashed")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: DS.controlSize, height: DS.controlSize)
                        .foregroundStyle(clearNoteMode ? Color.white : Color.primary)
                        .background(clearNoteMode ? AppColor.danger : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearNoteMode ? "Clear-note brush on" : "Clear notes")
            }
            .padding(.horizontal)

            saveButton.padding(.horizontal)   // glowing primary action — transparent until you edit
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The session's Save action. Transparent/faded while clean, glowing green the moment
    /// there are unsaved edits — so it's obvious there's something to save. (C1 phase-2)
    private var saveButton: some View {
        let dirty = intents.hasUnsavedChanges
        return Button(action: onSave) {
            Label(dirty ? "Save Changes" : "Saved", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(dirty ? .white : AppColor.success.opacity(0.55))
                .background(dirty ? AppColor.success : AppColor.success.opacity(0.14), in: Capsule())
                .shadow(color: dirty ? AppColor.success.opacity(0.7) : .clear, radius: dirty ? 10 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!dirty)
        .animation(.easeInOut(duration: 0.25), value: dirty)
    }

    /// Working-shift intent brushes — EVERY meaningful working intent (F1), driven by
    /// `IntentBrushes.working` so none can be silently omitted.
    private var workingPills: some View {
        HStack(spacing: 6) {
            ForEach(IntentBrushes.working) { state in
                brushPill(on: workBrush == state, label: state.label, color: state.brickColor) { workBrush = state }
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private func brushPill(on: Bool, label: String, color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(label).font(.subheadline.weight(.semibold))   // constant weight → selecting doesn't resize
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(on ? color : Color.primary)
            .background(on ? color.opacity(0.22) : Color(.tertiarySystemFill), in: Capsule())
            .overlay(Capsule().stroke(on ? color : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    /// Off-day brushes: direct intent brushes (Must Be Off / Want to Work / Open — EVERY
    /// OffIntentState, F1) on top, plus AM/PM/MID granular pills for "want to work".
    private var availabilityPills: some View {
        // #10: intent brushes + AM/PM/MID on ONE line (scrolls if narrow), larger/clearer buttons.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(IntentBrushes.off) { state in
                    brushPill(on: offBrush == nil && offIntentBrush == state, label: state.label, color: state.brickColor) {
                        offIntentBrush = state; offBrush = nil
                    }
                }
                Divider().frame(height: 24)
                Text("Shift Availability").font(.caption).foregroundStyle(.secondary)
                ForEach(ShiftAvailabilityType.allCases, id: \.self) { type in
                    let on = offBrush == type
                    Button { offBrush = on ? nil : type } label: {
                        Text(type.rawValue)
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(on ? BrickPalette.availableOff : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(on ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Visibility toolbar (WSI-style icon strip)

/// A compact horizontal strip of icon toggles controlling which calendar layers
/// are drawn — modeled on the dispatch desk's icon toolbar, with Slack-grade
/// spacing and clear on/off states.
/// Compact "last synced" line, shown at the bottom of the Home page.
struct VisibilityToolbar: View {
    @Binding var layers: LayerVisibility

    /// Collapsed into a single "layers" menu so it no longer occupies a full toolbar row.
    /// The icon fills accent when any layer is hidden (so it's obvious something is off).
    private var anyHidden: Bool {
        !(layers.notes && layers.intentOverlays && layers.availability && layers.shiftType && layers.deskAssignments)
    }

    var body: some View {
        Menu {
            Toggle(isOn: $layers.notes) { Label("Notes", systemImage: "note.text") }
            Toggle(isOn: $layers.intentOverlays) { Label("Intent colors", systemImage: "paintpalette.fill") }
            Toggle(isOn: $layers.availability) { Label("Shift availability", systemImage: "clock.badge.checkmark") }
            Toggle(isOn: $layers.shiftType) { Label("Shift type (AM/PM/MID)", systemImage: "clock") }
            Toggle(isOn: $layers.deskAssignments) { Label("Desk numbers", systemImage: "number") }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: DS.controlSize, height: DS.controlSize)
                .foregroundStyle(anyHidden ? Color.white : Color.primary)
                .background(anyHidden ? Color.accentColor : Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Layer visibility")
    }
}

// MARK: - Edit target

struct DayEditTarget: Identifiable {
    let dayID: String
    let isOff: Bool
    var id: String { dayID }
}

/// A queued single-tap that would overwrite an existing, different intent.
struct PendingConflict: Identifiable {
    let dayID: String
    let existing: String
    let apply: () -> Void
    var id: String { dayID }
}

// MARK: - Color key

/// The comprehensive color key / legend — the single source of "what every color means" across
/// the app (calendars, intents, trade status, markers). Driven by `AppLegend`, so it can never
/// drift from the colors the UI actually draws.
struct IntentKeySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("One color = one meaning across the app. Everything below is drawn from the same palette the calendars and trade cards use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(AppLegend.sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { LegendRow(item: $0) }
                    }
                }
            }
            .navigationTitle("Colors & Legend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

```


## `Sources/UI/Home/HomeCalendar.swift`

```swift
// HomeCalendar.swift
// The interactive intent calendar + per-day editor + Trade Settings sheet used by
// HomeView. The grid layout descends from ScheduleCalendarView; cells add tap /
// long-press and draw intent overlays from DayIntentStore.

import SwiftUI

// MARK: - Off-day legality

/// Which shift types you could LEGALLY pick up on an off day, given the 8-hour
/// rest rule versus the shifts you work on the adjacent days.
enum Legality {
    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// Legal pickup types for an off day. Delegates to the SINGLE source of truth
    /// (`AvailabilityManager.eligibleTypes`) so the calendar, the want-to-work gate, and the
    /// tests can never diverge (was a duplicate rest-rule implementation — the meta-seam bug).
    static func legalTypes(forDayID dayID: String, shifts: [Shift]) -> Set<ShiftAvailabilityType> {
        guard let day = isoF.date(from: dayID) else { return [] }
        return AvailabilityManager.eligibleTypes(forOffDay: day, workedShifts: shifts.filter { !$0.isOff })
    }
}

// MARK: - Tappable, color-coded note marker

/// A note icon on a calendar day — blue = public, orange = private — that shows
/// the note text in a popover when tapped.
struct NoteMarker: View {
    let note: DayNote
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: note.isPrivate ? "lock.doc.fill" : "note.text")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(note.isPrivate ? BrickPalette.warning : BrickPalette.info)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: note.isPrivate ? "lock.fill" : "globe")
                    Text(note.isPrivate ? "Private note" : "Public note").font(.caption.bold())
                }
                .foregroundStyle(note.isPrivate ? BrickPalette.warning : BrickPalette.info)
                Text(note.message).font(.subheadline)
                if let r = note.reason {
                    Text("Reason: \(r.label)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(minWidth: 180)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// A tappable event marker (holiday / milestone) showing the event name in a popover.
struct EventMarker: View {
    let name: String
    let color: Color
    let icon: String
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 6) {
                Label(name, systemImage: icon).font(.subheadline.bold()).foregroundStyle(color)
                Text("High-demand date").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14).frame(minWidth: 180)
            .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Interactive month calendar with intent overlays

struct IntentCalendarView: View {
    let shifts: [Shift]
    let mode: IntentMode
    let layers: LayerVisibility
    let flashDays: Set<String>
    let onTap: (_ dayID: String, _ isOff: Bool) -> Void
    let onLongPress: (_ dayID: String, _ isOff: Bool) -> Void

    private var intents = DayIntentStore.shared
    @State private var infoDay: String?
    private let cal = Calendar.current
    private static let headers = ["Su", "M", "T", "W", "Th", "F", "Sa"]
    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let monthF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    init(shifts: [Shift], mode: IntentMode, layers: LayerVisibility, flashDays: Set<String>,
         onTap: @escaping (String, Bool) -> Void, onLongPress: @escaping (String, Bool) -> Void) {
        self.shifts = shifts; self.mode = mode; self.layers = layers
        self.flashDays = flashDays; self.onTap = onTap; self.onLongPress = onLongPress
    }

    private var byDay: [String: Shift] {
        Dictionary(shifts.map { (Self.isoF.string(from: $0.date), $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var months: [Date] {
        let today = cal.startOfDay(for: Date())
        guard let startMonth = cal.dateInterval(of: .month, for: today)?.start else { return [] }
        let lastDate = shifts.map { $0.date }.max() ?? today
        let endMonth = cal.dateInterval(of: .month, for: lastDate)?.start ?? startMonth
        var result: [Date] = []; var m = startMonth
        while m <= endMonth {
            result.append(m)
            guard let next = cal.date(byAdding: .month, value: 1, to: m) else { break }
            m = next
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(months, id: \.self) { month in
                    Section {
                        monthGrid(month)
                    } header: {
                        // Plain black header (matches the calendar background) — no elevated band
                        // slicing the view. Opaque so pinned scrolling still occludes rows cleanly.
                        Text(Self.monthF.string(from: month))
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal).padding(.top, 10).padding(.bottom, 6)
                            .background(Color(.systemBackground))
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func monthGrid(_ month: Date) -> some View {
        let days = gridDays(month)
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(Self.headers, id: \.self) { h in
                    Text(h).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<(days.count / 7), id: \.self) { week in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { col in
                        cell(days[week * 7 + col], month: month)
                    }
                }
            }
        }
        .padding(.horizontal)
        // Scale with Dynamic Type, but cap it so the day cells stay on their grid.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private func gridDays(_ month: Date) -> [Date] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let weekdayIndex = cal.component(.weekday, from: interval.start) - 1
        guard let start = cal.date(byAdding: .day, value: -weekdayIndex, to: interval.start) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    @ViewBuilder private func cell(_ date: Date, month: Date) -> some View {
        let dayID     = Self.isoF.string(from: date)
        let inMonth   = cal.isDate(date, equalTo: month, toGranularity: .month)
        let shift     = byDay[dayID]
        let hasShift  = shift != nil
        let isOff     = shift.map { $0.isOff } ?? true
        let isWorking = hasShift && !isOff
        let today     = cal.startOfDay(for: Date())
        let isToday   = cal.isDate(date, inSameDayAs: today)
        let isPast    = date < today && !isToday
        let faded     = isFaded(isWorking: isWorking, inMonth: inMonth)

        let marker = markerColor(dayID: dayID, isToday: isToday)

        VStack(spacing: 2) {
            ZStack {
                // Gold = high-impact, pink = personal day, blue = today. When today
                // also falls on a marked day, ring the gold/pink circle in blue.
                if let marker {
                    Circle().fill(marker).frame(width: 24, height: 24)
                    if isToday && marker != Color.accentColor {
                        // White gap + blue ring so "today on a marked day" reads on any fill.
                        Circle().stroke(Color(.systemBackground), lineWidth: 2).frame(width: 27, height: 27)
                        Circle().stroke(Color.accentColor, lineWidth: 3).frame(width: 30, height: 30)
                    }
                }
                Text("\(cal.component(.day, from: date))")
                    .font(.headline).fontWeight(isToday ? .black : .semibold)
                    // Dark text on the light gold circle; white on blue/pink.
                    .foregroundStyle(marker == nil ? .primary
                        : (intents.topology(forDay: dayID) == .highDemand ? Color.black.opacity(0.85) : .white))
            }
            .frame(height: 31)
            .contentShape(Circle())
            .onTapGesture {
                if intents.topology(forDay: dayID) != .standard { infoDay = dayID }
                else if inMonth, hasShift { onTap(dayID, isOff) }   // normal day → same as cell tap
            }
            .popover(isPresented: Binding(get: { infoDay == dayID },
                                          set: { if !$0 { infoDay = nil } })) {
                topologyInfo(dayID: dayID)
            }
            dayContent(shift: shift, isWorking: isWorking, isOff: isOff, dayID: dayID)
                .frame(minHeight: 14)
            noteDot(dayID)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(background(dayID: dayID, isToday: isToday, isWorking: isWorking, hasShift: hasShift, date: date, shift: shift))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(borderColor(dayID: dayID, isToday: isToday, isOff: isOff, hasShift: hasShift),
                        lineWidth: flashDays.contains(dayID) ? 3 : borderWidth(dayID: dayID, isOff: isOff))
        )
        .opacity(inMonth ? (faded ? 0.3 : (isPast ? 0.45 : 1)) : 0.12)
        .contentShape(Rectangle())
        .onTapGesture { if inMonth, hasShift { onTap(dayID, isOff) } }
        .onLongPressGesture(minimumDuration: 0.35) { if inMonth, hasShift { onLongPress(dayID, isOff) } }
    }

    @ViewBuilder private func dayContent(shift: Shift?, isWorking: Bool, isOff: Bool, dayID: String) -> some View {
        if isWorking, let shift {
            // Type (AM/PM/MID) and desk are independently toggleable. Both off → blank (the colored day
            // circle still marks it as worked).
            let type = layers.shiftType ? shift.shiftTypeLabel : ""
            let desk = (layers.deskAssignments && !shift.desk.isEmpty) ? shift.desk : ""
            let label = [type, desk].filter { !$0.isEmpty }.joined(separator: " ")
            if label.isEmpty {
                Color.clear.frame(height: 14)
            } else {
                Text(label)
                    .font(.caption.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.6)
            }
        } else if let shift, shift.isVacation {
            // Vacation reads as a distinct teal state, not a plain day off. (U-VAC)
            Image(systemName: "beach.umbrella.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(BrickPalette.vacation)
                .accessibilityLabel("Vacation")
        } else if isOff, layers.availability {
            // A/P/M availability pills on off days — controlled purely by the "Shift
            // availability" layer toggle (the clock button), so it works in the general
            // read-only view too, not just while marking days-off.
            offAvailability(dayID)
        } else {
            Color.clear.frame(height: 14)
        }
    }

    /// Off-day availability: legal pickup types (faint), your chosen ones solid;
    /// a red ⊗ when you've marked yourself unavailable (deselected everything).
    @ViewBuilder private func offAvailability(_ dayID: String) -> some View {
        if intents.offIntent(forDay: dayID) == .mustBeOff {
            Image(systemName: "xmark.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(BrickPalette.critical)
        } else {
            let legal = Legality.legalTypes(forDayID: dayID, shifts: shifts)
            let marked = intents.availability(forDay: dayID)
            // Amber only when you're ACTIVELY soliciting (want-to-work); passive
            // "open" availability (bookends/all) reads in a faded slate so an open
            // day off never looks like a want-to-work day.
            let tint = intents.offIntent(forDay: dayID) == .wantToWork
                ? BrickPalette.availableOff : BrickPalette.openOff
            if legal.isEmpty {
                // #1: no legal shift is coverable here (rest / legal-start) → auto-X; can't want-to-work it.
                Image(systemName: "nosign")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BrickPalette.critical.opacity(0.75))
                    .accessibilityLabel("No tradeable shift available")
            } else {
                HStack(spacing: 2) {
                    ForEach(ShiftAvailabilityType.allCases.filter { legal.contains($0) }, id: \.self) { t in
                        let on = marked.contains(t)
                        Text(String(t.rawValue.prefix(1)))
                            .font(.system(size: 9, weight: .black))   // fixed: the A/P/M pill is a compact glyph
                            .foregroundStyle(on ? .white : tint.opacity(0.8))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(on ? tint : Color.clear))
                            .overlay(Circle().stroke(tint.opacity(on ? 0 : 0.6), lineWidth: 1.5))
                    }
                }
            }
        }
    }

    @ViewBuilder private func noteDot(_ dayID: String) -> some View {
        if layers.notes, let note = intents.note(forDay: dayID) {
            NoteMarker(note: note)
        } else if layers.notes, let holiday = Holidays.name(forDay: dayID) {
            // Auto-label the event for high-demand holidays.
            EventMarker(name: holiday, color: BrickPalette.warning, icon: "exclamationmark.triangle.fill")
        } else if layers.notes, intents.topology(forDay: dayID) == .personalMilestone {
            EventMarker(name: "Personal milestone", color: BrickPalette.milestone, icon: "star.fill")
        } else {
            Color.clear.frame(height: 9)
        }
    }

    // MARK: Styling

    private func isFaded(isWorking: Bool, inMonth: Bool) -> Bool {
        guard inMonth else { return false }
        switch mode {
        case .off:           return false
        case .workingShifts: return !isWorking
        case .daysOff:       return isWorking
        }
    }

    private func background(dayID: String, isToday: Bool, isWorking: Bool, hasShift: Bool,
                            date: Date, shift: Shift?) -> Color {
        if layers.intentOverlays {
            // Explicit per-day intent wins over the blacklist Blackout tint (B4-3 precedence).
            if let tint = intentTint(dayID: dayID, isWorking: isWorking) { return tint }
            if let bo = blackoutTint(date: date, shift: shift) { return bo }
        }
        if !hasShift { return Color(.systemGray6) }
        return isWorking ? Color.accentColor.opacity(0.20) : Color(.systemGray5)
    }

    /// B4-3: tint a day that matches the user's trade blacklist (never traded/worked). Working shifts
    /// match on desk/type/region/weekday; off days match on **weekday only** (no desk). Only reached
    /// when the day has no explicit intent (intent wins). Assumptions flagged in ASSUMED_PRESENT.
    private func blackoutTint(date: Date, shift: Shift?) -> Color? {
        let weekday = cal.component(.weekday, from: date)
        let s = SettingsManager.shared
        let hit: Bool
        if let shift, !shift.isOff {
            // Working day: tint only on the desk/type/region dimensions. The weekday ("Blackout days")
            // dimension is intentionally EXCLUDED here (pass []), because a blacked-out weekday only ever
            // suppresses PICKUPS — and pickups require you to be off (canCover's hard isOff gate). Tinting a
            // working shift for it would misrepresent the matching behavior.
            hit = Blackout.isBlacklisted(desk: shift.desk, startHour: shift.startHour, weekday: weekday,
                                         desks: s.blacklistedDesks, shiftTypes: s.blacklistedShiftTypes,
                                         regions: s.blacklistedRegions, weekdays: [])
        } else {
            hit = s.blacklistedWeekdays.contains(weekday)   // off day: weekday blackout applies here
        }
        // Blacklist "blocked" family reads SLATE (same as an off-day Blackout + the Trade-Settings pills),
        // visually distinct from the green "keep"/must-work intent. (One hue = one meaning.)
        return hit ? OffIntentState.mustBeOff.brickColor.opacity(0.30) : nil
    }

    /// Dispatch "brick" intent fill, or nil when the day has no explicit intent.
    /// Day-off fills are intentionally fainter than worked-day fills so a day off
    /// reads as the lighter, more passive layer of the calendar.
    private func intentTint(dayID: String, isWorking: Bool) -> Color? {
        if isWorking {
            guard let s = intents.workingIntent(forDay: dayID) else { return nil }
            return s.brickColor.opacity(0.62)
        } else {
            // must-be-off is shown by the red ⊗ marker, not a fill.
            guard let s = intents.offIntent(forDay: dayID), s != .mustBeOff else { return nil }
            // Passive "open" is the faintest; an active want-to-work off day is a bit stronger.
            return s.brickColor.opacity(s == .wantToWork ? 0.45 : 0.30)
        }
    }

    /// Popover shown when a gold/pink day's circle is tapped: what the day is, plus
    /// the reason (a public note's text, else the categorized reason).
    @ViewBuilder private func topologyInfo(dayID: String) -> some View {
        let topo = intents.topology(forDay: dayID)
        let isPersonal = topo == .personalMilestone
        let note = intents.note(forDay: dayID)
        VStack(alignment: .leading, spacing: 6) {
            Label(isPersonal ? "Personal milestone" : "High-impact day",
                  systemImage: isPersonal ? "star.circle.fill" : "exclamationmark.circle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(isPersonal ? BrickPalette.personalDay : BrickPalette.highImpact)
            if !isPersonal, let holiday = Holidays.name(forDay: dayID) {
                Text(holiday).font(.body)
            }
            if let note, !note.isPrivate, !note.message.isEmpty {
                Text(note.message).font(.body)
            } else if let r = note?.reason {
                Text("Reason: \(r.label)").font(.caption).foregroundStyle(.secondary)
            } else if isPersonal {
                Text("Long-press the day to add a reason or note.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(minWidth: 200)
        .presentationCompactAdaptation(.popover)
    }

    /// Gold for a high-demand day, pink for a personal day, blue (accent) for today.
    /// Today is only the fallback when the day isn't otherwise marked.
    private func markerColor(dayID: String, isToday: Bool) -> Color? {
        switch intents.topology(forDay: dayID) {
        case .highDemand:        return BrickPalette.highImpact
        case .personalMilestone: return BrickPalette.personalDay
        case .standard:          return isToday ? Color.accentColor : nil
        }
    }

    private func borderColor(dayID: String, isToday: Bool, isOff: Bool, hasShift: Bool) -> Color {
        // High-impact / personal days now read as gold/pink circles, not borders.
        flashDays.contains(dayID) ? BrickPalette.warning : .clear
    }

    private func borderWidth(dayID: String, isOff: Bool) -> CGFloat { 0 }
}

// MARK: - Per-day intent editor (long-press)

struct DayIntentEditor: View {
    let target: DayEditTarget

    private var intents = DayIntentStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var working: WorkingIntentState?
    @State private var off: OffIntentState?
    @State private var reason: IntentReason?
    @State private var reasonText = ""
    @State private var significant = false
    @State private var noteText = ""
    @State private var notePrivate = false
    @State private var saving = false

    init(target: DayEditTarget) { self.target = target }

    private var prettyDate: String {
        guard let d = TradeMatcher.dayDate(fromISO: target.dayID) else { return target.dayID }
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d, yyyy"; return f.string(from: d)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Intent") {
                    if target.isOff {
                        Picker("Day off", selection: Binding(
                            get: { off ?? .neutralOpen },
                            set: { off = $0 })) {
                            ForEach(OffIntentState.allCases) { Text($0.label).tag($0) }
                        }
                    } else {
                        Picker("Working shift", selection: Binding(
                            get: { working == .wantToWork ? .mustWork : (working ?? .neutralOpen) },
                            set: { working = $0 })) {
                            ForEach(WorkingIntentState.allCases.filter { $0 != .wantToWork }) {
                                Text($0.label).tag($0)   // .mustWork label = "Keep" (working-day protect; green)
                            }
                        }
                    }
                }

                Section {
                    TextField("Why? (free text)", text: $reasonText, axis: .vertical)
                        .lineLimit(1...3)
                    if let reason {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").foregroundStyle(AppColor.special)
                            Text("Tagged as \(reason.label)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Reason")
                } footer: {
                    Text("Type it naturally — it's tagged automatically on save.")
                }

                Section {
                    if let holiday = Holidays.name(forDay: target.dayID) {
                        Label("High-demand holiday: \(holiday)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(BrickPalette.warning)
                    }
                    Toggle("Significant day", isOn: $significant)
                } footer: {
                    Text("Protects this date from automatic trade suggestions.")
                }

                Section("Note (≤ 50 chars)") {
                    HStack {
                        TextField("Short note", text: $noteText)
                            .onChange(of: noteText) { _, v in if v.count > 50 { noteText = String(v.prefix(50)) } }
                        CharCounter(text: noteText, limit: 50)
                    }
                    Toggle("Make Private", isOn: $notePrivate)
                }

                Section {
                    Button("Clear all intent for this day", role: .destructive) {
                        intents.clearIntent(forDay: target.dayID)
                        intents.setNote(nil, forDay: target.dayID)
                        intents.setTopology(nil, forDay: target.dayID)
                        dismiss()
                    }
                }
            }
            .navigationTitle(prettyDate)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        working = intents.workingIntent(forDay: target.dayID)
        off = intents.offIntent(forDay: target.dayID)
        significant = intents.topology(forDay: target.dayID) != .standard
        if let n = intents.note(forDay: target.dayID) {
            noteText = n.message; notePrivate = n.isPrivate; reason = n.reason
        }
    }

    private func save() async {
        saving = true
        // Categorize the free-text reason with the on-device model.
        reason = await ReasonClassifier.classify(reasonText)
        if target.isOff { intents.setOffIntent(off, forDay: target.dayID) }
        else { intents.setWorkingIntent(working, forDay: target.dayID) }
        intents.setTopology(significant ? .personalMilestone : nil, forDay: target.dayID)
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        intents.setNote(trimmed.isEmpty ? nil
                        : DayNote(dayID: target.dayID, message: trimmed, reason: reason, isPrivate: notePrivate),
                        forDay: target.dayID)
        saving = false
        dismiss()
    }
}

// MARK: - Wrapping pill row + selectable blackout pill (Trade Settings)

/// A simple left-to-right wrapping layout — pills flow onto the next line when a row fills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxRowW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { maxRowW = max(maxRowW, x - spacing); x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        maxRowW = max(maxRowW, x - spacing)
        return CGSize(width: min(maxRowW, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

/// A tappable "blackout / blacklist" pill. Selected = excluded (slate Blackout hue, matching the calendar's
/// Blackout tint). `enabled == false` grays it out (e.g. a region the user isn't qualified for).
struct BlacklistPill: View {
    let label: String
    let selected: Bool
    var enabled: Bool = true
    let action: () -> Void
    private var blackout: Color { OffIntentState.mustBeOff.brickColor }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(!enabled ? Color.secondary.opacity(0.45) : (selected ? .white : .primary))
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(!enabled ? Color(.tertiarySystemFill).opacity(0.4)
                                     : (selected ? blackout : Color(.tertiarySystemFill)),
                            in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Tabbed Trade Settings sheet

struct TradeSettingsSheet: View {
    @Bindable private var settings = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var myQuals: [String] = []
    @State private var showOverrideEditor = false
    @State private var editingNotes = false

    /// Re-run the base openness shortcut (which layers in the date-range overrides)
    /// and re-publish. Call after any override change.
    private func reapplyOpenness() {
        settings.markPrefsChanged()
        let level = TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends
        DayIntentStore.shared.applyOpenness(level, shifts: ShiftStore.shared.shifts)
        Task { await TradeProfileStore.shared.publishMine() }
    }

    private var openness: Binding<TradeOpenness> {
        Binding(get: { TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends },
                set: { level in
                    settings.tradeOpenness = level.rawValue
                    settings.markPrefsChanged()
                    // Openness is a shortcut: bulk-apply it to the availability pills,
                    // then publish so matching reflects it.
                    DayIntentStore.shared.applyOpenness(level, shifts: ShiftStore.shared.shifts)
                    Task { await TradeProfileStore.shared.publishMine() }
                })
    }
    private var mercenary: Binding<Bool> {
        Binding(get: { settings.isMercenaryMode },
                set: { on in
                    settings.isMercenaryMode = on
                    settings.markPrefsChanged()
                    let level = TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends
                    DayIntentStore.shared.applyMercenary(on, openness: level, shifts: ShiftStore.shared.shifts)
                    Task { await TradeProfileStore.shared.publishMine() }
                })
    }
    private var deskText: Binding<String> {
        Binding(get: { settings.blacklistedDesks.sorted().joined(separator: ", ") },
                set: { v in settings.blacklistedDesks = Set(v.split { $0 == "," || $0 == " " }
                    .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) })
    }

    // ── Qual-swap settings (Q4) ──────────────────────────────────────────
    /// Comma/space-separated list of desk numbers the user won't qual-swap into.
    private var qualSwapDeskText: Binding<String> {
        Binding(get: { settings.qualSwapBlacklistDesks.sorted().joined(separator: ", ") },
                set: { v in
                    settings.qualSwapBlacklistDesks = Set(v.split { $0 == "," || $0 == " " }
                        .map { String($0).uppercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                    publishProfile()
                })
    }
    /// Per-qual preference value: `-1` = Open (no preference, absent from the map),
    /// `0` = won't work (blacklisted), `1…` = least→most preferred.
    private func qualValueBinding(_ qual: String) -> Binding<Int> {
        Binding(get: { settings.qualValues[qual] ?? -1 },
                set: { newVal in
                    var v = settings.qualValues
                    if newVal < 0 { v.removeValue(forKey: qual) } else { v[qual] = newVal }
                    settings.qualValues = v
                    publishProfile()
                })
    }
    private func publishProfile() { settings.markPrefsChanged(); Task { await TradeProfileStore.shared.publishMine() } }

    /// Weekday pills for "Blackout days" — Calendar weekday numbers (1 = Sun … 7 = Sat) → single letters.
    static let weekdayPills: [(day: Int, letter: String)] =
        [(1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")]

    /// Toggle a value in one of the blacklist sets, then re-publish so peers' matching reflects it. The
    /// user's OWN feed/calendar update live (SettingsManager is @Observable); publish keeps peers current.
    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
        publishProfile()
    }

    // ── Relief dispatcher (schedule known only ~45 days out) ─────────────
    private var reliefOn: Binding<Bool> {
        Binding(get: { settings.isReliefDispatcher },
                set: { on in
                    settings.isReliefDispatcher = on
                    // Force a date when toggled on (default 45 days out).
                    if on && settings.reliefScheduleThrough == nil {
                        settings.reliefScheduleThrough = Calendar.current.date(byAdding: .day, value: 45, to: Date())
                    }
                    publishProfile()
                })
    }
    private var reliefDate: Binding<Date> {
        Binding(get: { settings.reliefScheduleThrough ?? (Calendar.current.date(byAdding: .day, value: 45, to: Date()) ?? Date()) },
                set: { settings.reliefScheduleThrough = Calendar.current.startOfDay(for: $0); publishProfile() })
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $tab) {
                    Text("Profile").tag(0)
                    Text("Trade Settings").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if tab == 0 { profile } else { tradeSettings }
            }
            .navigationTitle("Trade Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            // R-B: single publish funnel — guarantees status/settings edits reach peers even
            // when a vertical TextField swallows .onSubmit (status was blank cross-device).
            .onDisappear { publishProfile() }
            .sheet(isPresented: $showOverrideEditor) {
                OpennessOverrideEditor { ov in
                    settings.opennessOverrides.append(ov)
                    reapplyOpenness()
                }
            }
            .sheet(isPresented: $editingNotes) { PrivateNotesEditor() }
            .task {
                // Heal any stale "want to work" left by the old openness behavior:
                // re-apply the (neutral) openness shortcut. Manual edits are preserved.
                if !settings.isMercenaryMode {
                    let lvl = TradeOpenness(rawValue: settings.tradeOpenness) ?? .bookends
                    DayIntentStore.shared.applyOpenness(lvl, shifts: ShiftStore.shared.shifts)
                }
                myQuals = settings.cachedQuals   // instant from cache so region pills aren't stale
                let q = await RosterStore.shared.schedule(forWorker: settings.username).first?.quals ?? []
                if !q.isEmpty { myQuals = q; settings.cachedQuals = q }
            }
        }
    }

    private func prettyRange(_ start: String, _ end: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let out = DateFormatter(); out.dateFormat = "MMM d, yyyy"
        guard let s = f.date(from: start), let e = f.date(from: end) else { return "\(start) – \(end)" }
        return "\(out.string(from: s)) – \(out.string(from: e))"
    }

    // MARK: Profile tab

    @ViewBuilder private var profile: some View {
        Section("Status (public, 140 chars)") {
            TextField("e.g. \"😀 Happy to take weekend PMs\" — emojis welcome", text: Binding(
                get: { settings.statusBroadcast },
                set: { settings.statusBroadcast = String($0.prefix(140)) }), axis: .vertical)
                .lineLimit(1...3)
                .onSubmit { publishProfile() }   // publish status on change (A3 cross-device)
            HStack { Spacer(); CharCounter(text: settings.statusBroadcast, limit: 140) }
        }
        Section("Qualifications") {
            if myQuals.isEmpty {
                Text("No quals loaded — import your roster.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    ForEach(myQuals, id: \.self) { q in
                        Text(q).font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
        Section {
            // Read-only single-line bar; swipe horizontally to read long notes, tap to edit.
            Button { editingNotes = true } label: {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(settings.privateNotes.isEmpty ? "Tap to add private notes" : settings.privateNotes)
                            .font(.subheadline)
                            .foregroundStyle(settings.privateNotes.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.vertical, 2)
                    }
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Private notes")
        } footer: {
            Text("Stored on your device only and never shared. Tap to edit; swipe to read.")
        }
    }

    // MARK: Trade Settings tab

    @ViewBuilder private var tradeSettings: some View {
        Section {
            Picker("Accepting", selection: openness) {
                ForEach(TradeOpenness.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("Mercenary mode (take any qualifying shift)", isOn: mercenary)
        } header: {
            Text("Openness")
        } footer: {
            Text("A shortcut that sets your availability pills on Main View — “All” accepts any pickup, “Bookends” accepts only pickups that don’t split your time off, “Not accepting” blocks all matches. Both All and Bookends leave the calendar neutral; only Mercenary mode paints every off day “want to work.” You can fine-tune any day afterward.")
        }

        Section {
            ForEach(settings.opennessOverrides.sorted { $0.startDay < $1.startDay }) { ov in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ov.openness.label).font(.subheadline.weight(.semibold))
                        Text("\(prettyRange(ov.startDay, ov.endDay))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: ov.openness.symbol).foregroundStyle(.secondary)
                }
            }
            .onDelete { idx in
                let sorted = settings.opennessOverrides.sorted { $0.startDay < $1.startDay }
                let ids = Set(idx.map { sorted[$0].id })
                settings.opennessOverrides.removeAll { ids.contains($0.id) }
                reapplyOpenness()
            }
            Button { showOverrideEditor = true } label: {
                Label("Add date-range override", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Date-range overrides")
        } footer: {
            Text("Temporarily change your openness for a specific span — e.g. base “Bookends”, but “Open to all” for a slow week. Active until you delete it.")
        }
        Section {
            TextField("e.g. 29, 82", text: deskText)
                .autocorrectionDisabled().textInputAutocapitalization(.characters)
        } header: {
            Text("Blacklisted desks")
        } footer: {
            Text("You won't be offered automated pickups on these desks.")
        }
        Section {
            FlowLayout(spacing: 8) {
                ForEach(ShiftAvailabilityType.allCases, id: \.self) { type in
                    BlacklistPill(label: type.rawValue,
                                  selected: settings.blacklistedShiftTypes.contains(type.rawValue)) {
                        toggle(&settings.blacklistedShiftTypes, type.rawValue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
        } header: {
            Text("Blacklisted shift types")
        } footer: {
            Text("Tap a type (AM / PM / MID) to stop being offered those shifts.")
        }
        Section {
            FlowLayout(spacing: 8) {
                ForEach(DeskRegion.allCases, id: \.self) { region in
                    let qualed = DeskRules.isQualified(quals: myQuals, forRegion: region)
                    BlacklistPill(label: region.rawValue,
                                  selected: settings.blacklistedRegions.contains(region.rawValue),
                                  enabled: qualed) {
                        toggle(&settings.blacklistedRegions, region.rawValue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
        } header: {
            Text("Blacklisted regions")
        } footer: {
            Text("Grayed regions need a qualification you don't hold. Tap a region to stop being offered its desks.")
        }
        Section {
            FlowLayout(spacing: 8) {
                ForEach(Self.weekdayPills, id: \.day) { wd in
                    BlacklistPill(label: wd.letter,
                                  selected: settings.blacklistedWeekdays.contains(wd.day)) {
                        toggle(&settings.blacklistedWeekdays, wd.day)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
        } header: {
            Text("Blackout days")
        } footer: {
            Text("Tap the days you never want offered in trades — they show as Blackout on your calendar.")
        }

        qualSwapSettings
        reliefSettings
    }

    // MARK: Relief dispatcher

    @ViewBuilder private var reliefSettings: some View {
        Section {
            Toggle("Relief Dispatcher", isOn: reliefOn)
            if settings.isReliefDispatcher {
                DatePicker("Schedule known through", selection: reliefDate, displayedComponents: .date)
            }
        } header: {
            Text("Relief schedule")
        } footer: {
            Text("Relief dispatchers only get their schedule ~45 days out; the master roster pads the rest of the year with placeholder AMs. Set the last real date — your shifts after it are hidden from your calendar and from trading (for everyone), and stay hidden across roster updates.")
        }
        .listRowBackground(AppColor.vacation.opacity(0.20))   // E3: relief box visually distinct (higher contrast)
    }

    // MARK: Qual-swap preferences (Q4)

    private var qualSwapMaxValue: Int { max(myQuals.count, 2) }

    @ViewBuilder private var qualSwapSettings: some View {
        Section {
            if myQuals.isEmpty {
                Text("No quals loaded — import your roster to set qual-swap preferences.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(myQuals, id: \.self) { q in
                    Picker(q, selection: qualValueBinding(q)) {
                        Text("Open").tag(-1)
                        Text("Won't work").tag(0)
                        ForEach(1...qualSwapMaxValue, id: \.self) { v in
                            Text(v == 1 ? "1 (least)"
                                 : v == qualSwapMaxValue ? "\(v) (most)" : "\(v)").tag(v)
                        }
                    }
                }
            }
        } header: {
            Text("Qual-swap preferences")
        } footer: {
            Text("When a trade needs a qual swap, you'll be asked to move onto a different desk. You'll accept only if that desk's qual is ranked EQUAL OR HIGHER than the qual of the desk you're already working that day.\n\n• Open = no preference (you'll take it).\n• Won't work (0) = never swap into that qual.\n• 1 = least preferred … higher = more preferred.")
        }
        .listRowBackground(AppColor.special.opacity(0.20))   // E3: qual-swap section distinct from blacklists above

        Section {
            TextField("e.g. 64, 65", text: qualSwapDeskText)
                .autocorrectionDisabled().textInputAutocapitalization(.characters)
        } header: {
            Text("Qual-swap desk blacklist")
        } footer: {
            Text("Specific desk numbers you'll never qual-swap into — blocked regardless of qual preference.")
        }
        .listRowBackground(AppColor.special.opacity(0.20))   // E3
    }
}

// MARK: - Private notes editor

/// Full editor for the device-only private notes (the settings row shows a
/// read-only swipeable preview that opens this).
struct PrivateNotesEditor: View {
    private var settings = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: Binding(
                        get: { settings.privateNotes },
                        set: { settings.editPrivateNotes(String($0.prefix(2000))) }))
                        .frame(minHeight: 220)
                    HStack { Spacer(); CharCounter(text: settings.privateNotes, limit: 2000) }
                } footer: {
                    Text("Private to you — synced across your own devices, never shared with anyone else.")
                }
            }
            .navigationTitle("Private Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onDisappear { Task { await PrivateStateStore.shared.publishLocal() } }   // sync up on close (A3)
        }
    }
}

// MARK: - Date-range openness override editor

/// Modal to add a date-range openness override that supersedes the base openness
/// for its span until deleted.
struct OpennessOverrideEditor: View {
    let onSave: (OpennessOverride) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var start = Date()
    @State private var end = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var openness: TradeOpenness = .all

    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section("Date range") {
                    DatePicker("Start", selection: $start, displayedComponents: .date)
                    DatePicker("End", selection: $end, in: start..., displayedComponents: .date)
                }
                Section("Openness for these days") {
                    Picker("Accepting", selection: $openness) {
                        ForEach(TradeOpenness.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Openness Override")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let cal = Calendar.current
                        let s = cal.startOfDay(for: start)
                        let e = cal.startOfDay(for: max(end, start))
                        onSave(OpennessOverride(id: UUID().uuidString,
                                                startDay: Self.isoF.string(from: s),
                                                endDay: Self.isoF.string(from: e),
                                                opennessRaw: openness.rawValue))
                        dismiss()
                    }
                }
            }
        }
    }
}

```


## `Sources/UI/Trades/TradesView.swift`

```swift
// TradesView.swift
// v2 Trades tab — global status dashboard (🟢🟡🔴💬) + a segmented feed:
//   [ Trade by Intents ]  → TradeRouter.tieredSolutions in 4 tier accordions
//   [ Trade Search ]      → the existing FindCandidatesSection (date-range query)
// Reuses TwoWaySheet, PlanCandidate, MessagingStore, TradeHistoryStore.

import SwiftUI

struct TradesView: View {

    private var messaging = MessagingStore.shared
    private var intents   = DayIntentStore.shared
    private var feedCache = TradeFeedCache.shared

    @State private var segment = 1   // default to Trade Search (middle). S-UIUX U-TRADES-1
    @State private var whatIf = false
    @State private var loading = true   // spinner on first entry so the tab never looks frozen

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The trade-status counters now live in the shared top bar (AppTopBar) on every tab.
                // Badge = number of MUTUAL intent matches (not your raw intent count).
                TradesSegmentBar(segment: $segment, intentCount: feedCache.intentMatchCount)
                    .padding(.horizontal).padding(.top, 6).padding(.bottom, 8)   // cushion below the top bar

                if segment == 0 {
                    IntentTallyBar(centered: true)   // color-coded per-intent counts — Intents tab only (D2a)
                }

                Divider()

                switch segment {
                case 0: TradeByIntentsFeed(whatIf: $whatIf)
                case 1: FindCandidatesSection(whatIf: $whatIf) { loading = false }   // drop spinner when cold load settles
                default: ECBTradesView()
                }
            }
            .loadingOverlay(loading, label: "Loading trades…")
            .navigationTitle("Trades")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)   // the shared AppTopBar is the header now
            .task {
                await messaging.refresh()
                // Safety net: if the landing segment isn't the one that reports readiness, still
                // drop the spinner after the first frame so it can never get stuck on.
                await Task.yield()
                if segment != 1 { loading = false }
            }
        }
    }
}

// MARK: - Trades segment bar (custom — so the Intents count can be a CIRCLED badge, #3)

/// 4-way selector. The Intents segment shows its matching-factor count in an orange **circle** so
/// it reads clearly as a count (vs "Just 2" where the 2 is part of the name).
struct TradesSegmentBar: View {
    @Binding var segment: Int
    let intentCount: Int
    private let titles = ["Intents", "Trade Solutions", "ECB"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(titles.indices, id: \.self) { i in
                Button { segment = i } label: {
                    HStack(spacing: 5) {
                        Text(titles[i])
                            .font(.subheadline.weight(segment == i ? .semibold : .regular))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        if i == 0 && intentCount > 0 {
                            Text("\(intentCount)")
                                .font(.caption2.bold()).monospacedDigit().foregroundStyle(.white)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Circle().fill(AppColor.heat))
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(segment == i ? Color(.secondarySystemFill) : .clear, in: Capsule())
                    .contentShape(Capsule())
                    .foregroundStyle(segment == i ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.bar, in: Capsule())
    }
}

// MARK: - Intent tally bar (the two MATCHING factors — Want-to-Trade + Want-to-Work, #3)

/// A thin row of color-coded count chips — one per active intent category — so you can
/// see your marked intents at a glance. Counts come from `DayIntentStore` (pure).
struct IntentTallyBar: View {
    var centered: Bool = false
    private var intents = DayIntentStore.shared

    init(centered: Bool = false) { self.centered = centered }

    var body: some View {
        let wc = intents.workingIntentCounts
        let oc = intents.offIntentCounts
        // All four marked intents, color-matched to the calendar legend: the two MATCHING factors
        // (Want to Trade / Want to Work) plus the two PROTECTIVE ones (Keep working shift = green;
        // Blackout off day = slate). Zero-count categories drop out.
        let items: [(label: String, color: Color, count: Int)] = [
            ("Want to Trade", WorkingIntentState.dontWantToWork.brickColor, wc[.dontWantToWork] ?? 0),
            ("Want to Work",  OffIntentState.wantToWork.brickColor,         oc[.wantToWork] ?? 0),
            ("Keep",          WorkingIntentState.mustWork.brickColor,       wc[.mustWork] ?? 0),
            ("Blackout",      OffIntentState.mustBeOff.brickColor,          oc[.mustBeOff] ?? 0),
        ].filter { $0.count > 0 }
        if !items.isEmpty {
            HStack(spacing: 10) {
                ForEach(items, id: \.label) { it in
                    HStack(spacing: 4) {
                        Circle().fill(it.color).frame(width: 7, height: 7)
                        Text("\(it.count)").font(.caption2.weight(.bold)).monospacedDigit()
                        Text(it.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !centered { Spacer() }   // left-aligned by default; centered when requested
            }
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .padding(.horizontal).padding(.bottom, 4)
        }
    }
}

// MARK: - Dashboard sheet (4 zones)

struct TradeDashboardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Accepted").tag(0)
                    Text("Pending").tag(1)
                    Text("Denied").tag(2)
                    Text("History").tag(3)
                }
                .pickerStyle(.segmented).padding()

                switch tab {
                case 0: AcceptedZone()
                case 1: PendingZone()
                case 2: DeniedZone()
                default: HistoryZone()
                }
                Spacer(minLength: 0)
            }
            .navigationTitle("Trade Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            // Pull the latest trade state + your cross-device history when the board opens (and on pull).
            .task { await MessagingStore.shared.refresh(); await TradeHistoryStore.shared.syncOnLaunch() }
            .refreshable { await MessagingStore.shared.refresh(); await TradeHistoryStore.shared.syncOnLaunch() }
        }
    }
}

// MARK: - Zones

private struct AcceptedZone: View {
    private var messaging = MessagingStore.shared
    private var history   = TradeHistoryStore.shared
    private var myID: String { SettingsManager.shared.username }

    private var accepted: [TradeRequest] {
        messaging.requests.filter { messaging.status(of: $0) == .accepted }
    }

    var body: some View {
        if accepted.isEmpty {
            ZoneEmpty("No accepted trades", "Agreed trades waiting to be entered on the official board show here.")
        } else {
            List(accepted) { req in
                VStack(alignment: .leading, spacing: 8) {
                    RequestRow(request: req, myID: myID)
                    Button {
                        Task { await confirmOfficial(req) }
                    } label: {
                        Label("Done: Confirmed on Official Board", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(AppColor.success).controlSize(.small)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
        }
    }

    private func confirmOfficial(_ req: TradeRequest) async {
        let entry = TradeHistoryEntry(
            summary: tradeSummary(req),
            participants: [req.fromName, req.toName],
            dayIDs: req.giveDayIDs + req.takeDayIDs,
            completedAt: Date())
        history.record(entry)
        await messaging.cancelRequest(req.id)   // clears it out of the active list
    }
}

private struct PendingZone: View {
    private var messaging = MessagingStore.shared
    private var myID: String { SettingsManager.shared.username }
    private var pending: [TradeRequest] {
        messaging.requests.filter {
            let s = messaging.status(of: $0)
            return s == .pending || s == .countered
        }
    }
    var body: some View {
        if pending.isEmpty {
            ZoneEmpty("Nothing pending", "Outbound proposals and circular-trade confirmations awaiting a reply show here.")
        } else {
            List(pending) { RequestRow(request: $0, myID: myID) }.listStyle(.plain)
        }
    }
}

private struct DeniedZone: View {
    private var messaging = MessagingStore.shared
    private var myID: String { SettingsManager.shared.username }
    private var denied: [TradeRequest] {
        messaging.requests.filter {
            let s = messaging.status(of: $0)
            return s == .declined || s == .cancelled
        }
    }
    var body: some View {
        if denied.isEmpty {
            ZoneEmpty("No denied trades", "Rejected or expired proposals show here so you know instantly.")
        } else {
            List(denied) { RequestRow(request: $0, myID: myID).opacity(0.7) }.listStyle(.plain)
        }
    }
}

private struct HistoryZone: View {
    private var history = TradeHistoryStore.shared
    var body: some View {
        if history.entries.isEmpty {
            ZoneEmpty("No history yet", "Settled trades — and pending ECB transfers — are recorded here.")
        } else {
            List(history.entries) { e in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(e.summary).font(.subheadline)
                        Spacer()
                        if e.pending {
                            Text("PENDING").font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(BrickPalette.caution.opacity(0.25), in: Capsule())
                                .foregroundStyle(AppColor.pending)
                        } else {
                            Text("DONE").font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(BrickPalette.clear.opacity(0.22), in: Capsule())
                                .foregroundStyle(AppColor.success)
                        }
                    }
                    Text("\(e.participants.joined(separator: " · ")) — \(e.completedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                    if e.pending {
                        Button { history.markComplete(id: e.id, at: Date()) } label: {
                            Label("Mark transfer complete", systemImage: "checkmark.seal.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Shared small views

private struct ZoneEmpty: View {
    let title: String; let message: String
    init(_ title: String, _ message: String) { self.title = title; self.message = message }
    var body: some View {
        ContentUnavailableView(title, systemImage: "tray", description: Text(message))
    }
}

/// "I take 2; you take 1" style summary of the moved days.
func tradeSummary(_ req: TradeRequest) -> String {
    var parts: [String] = []
    if !req.takeDayIDs.isEmpty { parts.append("you take \(req.takeDayIDs.count)") }
    if !req.giveDayIDs.isEmpty { parts.append("they take \(req.giveDayIDs.count)") }
    return parts.isEmpty ? "—" : "Swap: " + parts.joined(separator: "; ")
}

```


## `Sources/UI/Trades/TradeIntentsFeed.swift`

```swift
// TradeIntentsFeed.swift
// The "Trade by Intents" feed (4 tier accordions from TradeRouter.tieredSolutions)
// plus the N-way chain card and the execution-confirmation checkout.

import SwiftUI

// MARK: - Feed result cache (keeps each Trades tab loaded across tab switches)

/// Per-tab snapshot so moving between Intents / Trade Solutions / ECB doesn't destroy results or
/// re-run the engine when nothing changed. A feed restores its snapshot on appear and recomputes only
/// when its input SIGNATURE (intents revision + max-people + What-If + selected days) differs. The
/// `switch segment` in TradesView tears each feed down on every tab change, so without this the
/// (main-actor, heavy) search re-runs every return. (U-PERF.)
@MainActor @Observable
final class TradeFeedCache {
    static let shared = TradeFeedCache()
    private init() {}

    struct Snapshot {
        var signature: Int
        var selectedIDs: Set<String> = []
        var packages: [TradePackage] = []            // ALL-mode results (superset)
        var mutualPackages: [TradePackage] = []      // Mutual-mode subset (both cached so the toggle is instant)
        var candidates: [PlanCandidate] = []
        var rosterPeople: [(id: String, name: String)] = []
        var hasSearched: Bool = false
    }
    private var snaps: [String: Snapshot] = [:]
    func snapshot(_ key: String) -> Snapshot? { snaps[key] }
    func save(_ key: String, _ snap: Snapshot) { snaps[key] = snap }
    func clear(_ key: String) { snaps[key] = nil }

    /// Number of MUTUAL intent matches — drives the Intents tab badge. Set by the feed's mutual-mode
    /// searches and the launch background pass; read live by the segment bar (this class is @Observable).
    var intentMatchCount: Int = 0

    /// Full distinct roster (minus self), names resolved — loaded ONCE per session for the
    /// "Look up a dispatcher" dropdown (moved from the former Just 2 tab) so it isn't re-fetched
    /// on every tab return.
    var allDispatchers: [(id: String, name: String)] = []

    /// A stable hash of the inputs that change a feed's results. Days are optional (Intents seeds from
    /// marked intent, not a day picker).
    static func signature(selectedIDs: Set<String> = [], whatIf: Bool) -> Int {
        var h = Hasher()
        h.combine(DayIntentStore.shared.intentsRevision)
        h.combine(SettingsManager.shared.normalMaxPeople)
        h.combine(whatIf)
        for id in selectedIDs.sorted() { h.combine(id) }
        return h.finalize()
    }
}

// MARK: - Feed

struct TradeByIntentsFeed: View {

    @Binding var whatIf: Bool

    @State private var packages: [TradePackage] = []        // ALL-mode results (superset)
    @State private var mutualPackages: [TradePackage] = []  // Mutual subset — both computed once per search
    @State private var loading = true
    @State private var execRoute: NWayRoute?
    @State private var sentMessage: String?
    @State private var detailPackage: TradePackage?
    @State private var pkgSwap: PackageSwapContext?   // Q1: qual-swap package → blast picker
    // A1/A2: Master Filter — shapes the on-demand "I'm Feeling Lucky" search; chips stay visible.
    @State private var searchFilter = SearchFilter()
    @State private var showFilter = false
    @State private var rosterPeople: [(id: String, name: String)] = []
    @State private var searchTask: Task<Void, Never>?   // A1: cancellable Lucky search
    @State private var mutualOnly = true   // Mutual (both sides marked) vs All (also one-sided, active peers)

    /// The result set for the current toggle — Mutual (subset) or All (superset). Both are computed in one
    /// search and cached, so flipping the toggle is an instant state change (no engine re-run).
    private var activePackages: [TradePackage] { mutualOnly ? mutualPackages : packages }
    /// A1/A2: filtered + capped (best-first via rankPackages order) view of the results.
    private var displayed: [TradePackage] { Array(searchFilter.filter(activePackages).prefix(100)) }

    /// The deeper-search button label reflects the active one-time criteria (or the default name).
    /// "More: 3+ & loops" = the on-demand heavy search for 3+person / circular options (the normal feed
    /// stays fast at two-person swaps).
    private var luckyTitle: String {
        searchFilter.summary(nameFor: { id in rosterPeople.first { $0.id == id }?.name ?? id })
            .map { "More: \($0)" } ?? "More: 3+ & loops"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !loading {
                    luckyBar
                    // Mutual = both sides marked (true intent matches). All = also one-sided deals where
                    // an ACTIVE peer could take days you marked. Robots/inactives are excluded in both.
                    Picker("Match type", selection: $mutualOnly) {
                        Text("Mutual").tag(true)
                        Text("All").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.top, 4)
                    // No re-run on toggle: both Mutual + All were computed in one search (instant flip).
                    // Trade size (Max people) is a Lucky-time option — only shown once Lucky is engaged.
                    if searchFilter.isActive {
                        MaxPeoplePicker().padding(.horizontal).padding(.top, 4)
                    }
                }

                if loading {
                    VStack(spacing: 14) {
                        AnimatedLoader(name: "finding-matches", maxSize: 260)
                        Button(role: .cancel) { searchTask?.cancel(); loading = false } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 30)
                } else if displayed.isEmpty {
                    ContentUnavailableView("No Intent Matches",
                        systemImage: "sparkles",
                        description: Text(activePackages.isEmpty
                            ? (mutualOnly
                               ? "No two-sided intent matches yet — mark days to trade away on Home, and as others mark theirs, matches appear here. Switch to All to see active people who could take the days you marked."
                               : "Mark days to trade away on Home. Tap “More: 3+ & loops” for 3+ person and circular options.")
                            : "No matches fit your current filter — tap the filter to widen it."))
                        .padding(.top, 20)
                } else {
                    sectionHeader("Intent Matches", "Most mutual intent first — your marked days matched with theirs (🔥 = both sides marked)")
                    ForEach(displayed) { pkg in
                        if pkg.usesCompactCard {   // B4-14: 2-person → compact ECB-style card
                            CompactSwapCard(package: pkg,
                                            onPropose: { Task { await propose(pkg) } },
                                            onOpen: { detailPackage = pkg })
                        } else {
                            PackageCard(package: pkg,
                                        onPropose: { Task { await propose(pkg) } },
                                        onExecute: { if let r = pkg.route { execRoute = r } },
                                        onOpen: { detailPackage = pkg })
                        }
                    }
                    TradeFeedKey().padding(.horizontal).padding(.top, 8)
                }
            }
            .padding(.bottom, 24)
        }
        .fullScreenCover(item: $detailPackage) { pkg in
            PackageDetailView(package: pkg,
                              onPropose: { Task { await propose(pkg) } },
                              onExecute: { if let r = pkg.route { execRoute = r } })
                .magnifiable()
        }
        .sheet(item: $execRoute) { ExecutionConfirmationView(route: $0, origin: .intents) }
        .sheet(item: $pkgSwap) { ctx in
            QualSwapPickerSheet(giveDeskLabel: "desk \(ctx.leg.giveDesk) (\(ctx.leg.giveQual))",
                                takerName: ctx.leg.takerName, dayLabel: ctx.dayLabel,
                                candidates: ctx.leg.candidates) { chosen in
                Task {
                    var sendLeg = ctx.leg
                    sendLeg.candidates = ctx.leg.candidates.filter { chosen.contains($0.workerID) }
                    await MessagingStore.shared.sendRequest(
                        to: ctx.leg.takerID, toName: ctx.leg.takerName,
                        note: "Qual swap to give away \(ctx.dayLabel) — \(ctx.leg.takerName) takes a freed desk.",
                        take: [], give: [ctx.leg.giveShiftDayID], qualSwap: sendLeg, origin: .intents)
                    WidgetData.update()
                    pkgSwap = nil
                    sentMessage = "Qual-swap request sent. Track it in your Inbox."
                }
            }
        }
        .sheet(isPresented: $showFilter) {
            MasterFilterSheet(filter: $searchFilter, people: rosterPeople,
                              onGenerate: { f in runSearch { await reload(generation: f, lucky: true) } },
                              onReset: { runSearch { await reloadFast() } })
        }
        .task {
            // U-PERF: restore the last results instantly if nothing changed; otherwise run a
            // CANCELLABLE fast search (so the spinner shows a working Cancel and the engine yields).
            if let snap = TradeFeedCache.shared.snapshot(Self.cacheKey),
               snap.signature == TradeFeedCache.signature(whatIf: whatIf) {
                packages = snap.packages; mutualPackages = snap.mutualPackages
                rosterPeople = snap.rosterPeople; loading = false
            } else {
                runSearch { await reloadFast() }
            }
        }
        .onChange(of: whatIf) { _, _ in runSearch { await reloadFast() } }
        // C1: recompute on an explicit SAVE (intents revision) — NOT on every edit (was
        // MatchInputsSignature, which re-ran the heavy search on every keystroke). Background
        // reruns stay FAST (2-person) — the heavy 3+/N-Way search only runs via Lucky → Generate.
        .onChange(of: DayIntentStore.shared.intentsRevision) { _, _ in runSearch { await reloadFast() } }
        .onChange(of: SettingsManager.shared.normalMaxPeople) { _, _ in runSearch { await reloadFast() } }
        .onDisappear { searchTask?.cancel() }   // A1: leaving cancels any in-flight Lucky search
        .alert("Package sent", isPresented: Binding(
            get: { sentMessage != nil }, set: { if !$0 { sentMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(sentMessage ?? "") }
    }

    /// A1/A2: the "I'm Feeling Lucky" filter bar — a button to shape the search + visible chips
    /// of the active choices.
    private var luckyBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showFilter = true } label: {
                Label(luckyTitle, systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .tint(searchFilter.isActive ? AppColor.heat : nil)
            if searchFilter.isActive {
                HStack(spacing: 6) {
                    chip("One-time generation — tap to change or reset")
                    Spacer()
                }
                .font(.caption2)
            }
        }
        .padding(.horizontal).padding(.top, 4)
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.title3.bold())
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.top, 4)
    }

    /// A1: run a search, CANCELLING any still-running one first (re-Generate / Reset / SAVE / What-If
    /// supersedes the previous Lucky search instead of racing it).
    private func runSearch(_ work: @escaping () async -> Void) {
        searchTask?.cancel()
        searchTask = Task {
            // B4-10: debounce — coalesce rapid triggers (SAVE + whatIf + max-people can fire together) so
            // the engine starts once for the settled input. A superseded task is cancelled during the
            // sleep and bails; the final trigger still runs (result-neutral for the settled state).
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            await work()
        }
    }

    /// Background/default: fast 2-person generation, and clear any Lucky filter so the
    /// 2-person results aren't hidden by a stale engine/people selection.
    private func reloadFast() async {
        searchFilter = .normal
        // Step 4: normal feed searches up to the user's N-max toggle (default 3) — the floor +
        // N-penalty keep small trades on top. (Reverses the old 2-way-only U-PERF gate.)
        await reload(generation: SearchFilter(engine: .both, maxPeople: SettingsManager.shared.normalMaxPeople))
        // U-PERF: cache BOTH result sets so a tab switch OR a Mutual/All toggle restores them without
        // re-running the engine.
        if Task.isCancelled { return }
        TradeFeedCache.shared.save(Self.cacheKey, .init(
            signature: TradeFeedCache.signature(whatIf: whatIf),
            packages: packages, mutualPackages: mutualPackages, rosterPeople: rosterPeople, hasSearched: true))
    }

    private static let cacheKey = "intents"

    /// `generation` bounds the engine work: `.fast` (2-person, background) or the user's Lucky
    /// criteria (heavy 3+/N-Way, one-time). The display still filters via `searchFilter`.
    private func reload(generation: SearchFilter = .fast, lucky: Bool = false) async {
        loading = true
        await TradeProfileStore.shared.refreshOthers()
        let myID = SettingsManager.shared.username
        // Intents uses its OWN engine — a marketplace of intent-for-intent deals involving you, scored by
        // the real packageLogProb. Compute BOTH modes in ONE search: All (superset, every peer) and Mutual
        // (both-sides-marked, active accounts). The toggle then just picks which cached set to show.
        let allResult = await TradeRouter.intentSolutions(excluding: myID, generation: generation,
                                                          lucky: lucky, mutualOnly: false)
        if Task.isCancelled { return }   // A1: superseded by a newer search — don't clobber its state
        let mutualResult = await TradeRouter.intentSolutions(excluding: myID, generation: generation,
                                                            lucky: lucky, mutualOnly: true)
        if Task.isCancelled { return }
        packages = allResult
        mutualPackages = mutualResult
        // The Intents badge = number of MUTUAL matches.
        TradeFeedCache.shared.intentMatchCount = mutualResult.count
        // A2: people for the Connection dropdown — union of the roster, published peers, and anyone
        // already in a result — names resolved (G2a) — so it's never blank with a thin roster.
        let now = Date()
        let end = Calendar.current.date(byAdding: .month, value: 12, to: now) ?? now
        let entries = await RosterStore.shared.entries(from: now, to: end)
        var seen = Set<String>(); var people: [(id: String, name: String)] = []
        func add(_ id: String, _ name: String) {
            guard id != myID, seen.insert(id).inserted else { return }
            people.append((id, TradeNames.resolved(displayName: nil, rosterName: name, workerID: id)))
        }
        for e in entries { add(e.workerID, e.workerName) }
        for (id, p) in TradeProfileStore.shared.others { add(id, p.displayName) }
        for pkg in packages { for a in pkg.assignments { add(a.workerID, a.name) } }
        rosterPeople = people.sorted { $0.name < $1.name }
        loading = false
    }

    /// Greedy package: send a cover request to each assigned dispatcher. A qual-swap package
    /// opens the blast picker instead (Q1).
    private func propose(_ pkg: TradePackage) async {
        if let leg = pkg.qualSwap { pkgSwap = PackageSwapContext(leg: leg); return }
        for a in pkg.assignments {
            await MessagingStore.shared.sendRequest(
                to: a.workerID, toName: a.name, note: swapNote(a),
                take: a.takeDayIDs, give: a.giveDayIDs, origin: .intents)
        }
        WidgetData.update()
        let n = pkg.assignments.count
        sentMessage = "Sent to \(n) dispatcher\(n == 1 ? "" : "s"). Track replies in your Inbox."
    }
}

// MARK: - Feed key (explains the chips, flame, and quality pills)

/// Compact "max people in a trade" control shown on the Intents + Trade Solutions feeds (was in
/// Trade Settings). Writes `SettingsManager.normalMaxPeople`; the feed observes it and re-runs.
struct MaxPeoplePicker: View {
    private var settings = SettingsManager.shared
    var body: some View {
        HStack(spacing: 8) {
            Label("Trade size", systemImage: "person.3.fill").font(.caption).foregroundStyle(.secondary)
            Picker("Trade size", selection: Binding(
                get: { settings.normalMaxPeople }, set: { settings.normalMaxPeople = $0 })) {
                Text("Pairs").tag(2)
                Text("≤ 3").tag(3)
                Text("≤ 4").tag(4)
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }
}

/// A2: the "I'm Feeling Lucky" Master Filter sheet — engine, max-people, force-include person.
/// Choices are shown as chips on the feed; the results are filtered by `SearchFilter.filter`.
struct MasterFilterSheet: View {
    @Binding var filter: SearchFilter
    let people: [(id: String, name: String)]
    var availableQuals: [String] = []
    /// One-time HEAVY generation with the chosen criteria (runs 3+ / N-Way).
    var onGenerate: (SearchFilter) -> Void = { _ in }
    /// Back to the section's fast NORMAL generation (2-person only).
    var onReset: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SearchFilter
    @State private var limitDates = false   // gate the date-range pickers

    init(filter: Binding<SearchFilter>, people: [(id: String, name: String)], availableQuals: [String] = [],
         onGenerate: @escaping (SearchFilter) -> Void = { _ in }, onReset: @escaping () -> Void = {}) {
        _filter = filter; self.people = people; self.availableQuals = availableQuals
        self.onGenerate = onGenerate; self.onReset = onReset
        _draft = State(initialValue: filter.wrappedValue)
        _limitDates = State(initialValue: filter.wrappedValue.dateStart != nil || filter.wrappedValue.dateEnd != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Search engine") {
                    Picker("Engine", selection: $draft.engine) {
                        Text("Min-Cost").tag(SearchFilter.Engine.minCost)
                        Text("N-Way").tag(SearchFilter.Engine.nWay)
                        Text("Both").tag(SearchFilter.Engine.both)
                    }.pickerStyle(.segmented)
                    Text("Min-Cost = fewest-people swaps · N-Way = circular loops · Both = everything (capped for speed).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("Max people in a trade") {
                    Picker("Max people", selection: $draft.maxPeople) {
                        ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section("Connection") {
                    Picker("Connection", selection: Binding(
                        get: { draft.requiredWorkerID ?? "" },
                        set: { draft.requiredWorkerID = $0.isEmpty ? nil : $0 })) {
                        Text("Anyone").tag("")
                        ForEach(people, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Text("Only show trades that include this dispatcher.").font(.caption2).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Limit to a date range", isOn: Binding(
                        get: { limitDates },
                        set: { on in
                            limitDates = on
                            if on {
                                if draft.dateStart == nil { draft.dateStart = Date() }
                                if draft.dateEnd == nil { draft.dateEnd = Date() }
                            } else { draft.dateStart = nil; draft.dateEnd = nil }
                        }))
                    if limitDates {
                        DatePicker("From", selection: Binding(get: { draft.dateStart ?? Date() },
                                                              set: { draft.dateStart = $0 }), displayedComponents: .date)
                        DatePicker("To", selection: Binding(get: { draft.dateEnd ?? Date() },
                                                            set: { draft.dateEnd = $0 }), displayedComponents: .date)
                    }
                } header: { Text("Date range") }
                footer: { Text("Only show trades where every moved day falls inside this window.") }

                Section {
                    HStack(spacing: 8) {
                        ForEach(ShiftAvailabilityType.allCases, id: \.self) { t in
                            let on = draft.receiveTypes.contains(t)
                            Button {
                                if on { draft.receiveTypes.remove(t) } else { draft.receiveTypes.insert(t) }
                            } label: {
                                Text(t.rawValue).font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(on ? AppColor.primary : Color(.tertiarySystemFill), in: Capsule())
                                    .foregroundStyle(on ? .white : .primary)
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                    }
                } header: { Text("Shift time you'd pick up") }
                footer: { Text("Only show trades where the shifts you'd receive are these types.") }

                if !availableQuals.isEmpty {
                    Section {
                        FlowLayout(spacing: 8) {
                            ForEach(availableQuals, id: \.self) { q in
                                let on = draft.deskQuals.contains(q)
                                Button {
                                    if on { draft.deskQuals.remove(q) } else { draft.deskQuals.insert(q) }
                                } label: {
                                    Text(q).font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(on ? AppColor.primary : Color(.tertiarySystemFill), in: Capsule())
                                        .foregroundStyle(on ? .white : .primary)
                                }.buttonStyle(.plain)
                            }
                        }
                    } header: { Text("Desk qualification") }
                    footer: { Text("Only show trades involving desks that require any of the selected quals.") }
                }
                Section {
                    // One-time HEAVY generation for the chosen criteria (3+ / N-Way included).
                    Button {
                        filter = draft; onGenerate(draft); dismiss()
                    } label: {
                        Label("Generate matches", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    // Reset back to the fast NORMAL generation (2-person only).
                    Button(role: .destructive) {
                        draft = .normal; filter = .normal; onReset(); dismiss()
                    } label: {
                        Label("Reset to normal", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                    }
                    .disabled(!filter.isActive && !draft.isActive)
                } footer: {
                    Text("Generate runs the heavy 3+ person and circular (N-Way) search once. The normal feed stays fast with two-person trades only.")
                }
            }
            .navigationTitle("More: 3+ & loops")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// The Intents-feed legend — now the shared comprehensive, collapsed-by-default color key.
struct TradeFeedKey: View {
    var body: some View { CollapsibleLegend() }
}

/// The intent-color legend used in the two-way sheet + ECB — the same shared collapsed key.
struct IntentColorKey: View {
    var body: some View { CollapsibleLegend() }
}

/// Stable per-trader calendar color (you are always blue). Same index → same color
/// across the package card and the dual-calendar view.
func traderColor(_ index: Int) -> Color {
    BrickPalette.traderThemes[index % BrickPalette.traderThemes.count]
}

/// One trader's days in THEIR color, matching their calendar: a small color dot +
/// name, then "Gives" (bordered chips = trades away) and "Gets" (filled chips = takes).
struct TraderChips: View {
    let name: String
    let color: Color
    let giveDays: [String]
    let getDays: [String]
    var maxChips = 5
    var id: String? = nil   // when set, shows the person's status in italics (A7/B8)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(name + (id.map(botSuffix) ?? "")).font(.dsCardTitle).foregroundStyle(color).lineLimit(1)
            }
            if let id, let status = participantStatus(id) {
                Text(status).font(.dsCardMeta).italic().foregroundStyle(.secondary).lineLimit(1)
            }
            if !giveDays.isEmpty { chipRow("Gives", giveDays, filled: false) }
            if !getDays.isEmpty  { chipRow("Gets", getDays, filled: true) }
        }
    }

    private func chipRow(_ lbl: String, _ days: [String], filled: Bool) -> some View {
        HStack(spacing: 5) {
            Text(lbl).font(.dsLabel).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            ForEach(days.prefix(maxChips), id: \.self) { iso in
                Text(SwapChips.chipDay(iso)).font(.dsChip)
                    .foregroundStyle(filled ? .white : color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(filled ? color : Color.clear, in: Capsule())
                    .overlay(Capsule().stroke(color, lineWidth: filled ? 0 : 1.5))
            }
            if days.count > maxChips { Text("+\(days.count - maxChips)").font(.dsBadge).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 13)
    }
}

// MARK: - Handoff chain (for circular trades: who hands which day to whom)

/// One directed handoff in a chain, names included so it renders offline (inbox).
struct HandoffStep: Identifiable, Hashable {
    let id: String
    let fromID: String, fromName: String
    let toID: String, toName: String
    let dayID: String
    var desk: String? = nil
}

/// Renders a multi-person loop as explicit directed handoffs — "You → Denny: Jul 4",
/// "Denny → Dimitry: Jul 8", "Dimitry → You: Jul 12" — so who gives/gets what is
/// unambiguous. Works from route legs (feed) or a request's chain (inbox).
struct HandoffChain: View {
    let steps: [HandoffStep]
    private var myID: String { SettingsManager.shared.username }

    init(steps: [HandoffStep]) { self.steps = steps }
    init(legs: [NWayLeg]) {
        self.steps = legs.map { HandoffStep(id: $0.id, fromID: $0.fromID, fromName: participantName($0.fromID),
                                            toID: $0.toID, toName: participantName($0.toID), dayID: $0.dayID, desk: $0.desk) }
    }
    init(chain: [TradeLeg]) {
        self.steps = chain.enumerated().map { i, l in
            HandoffStep(id: "\(i)|\(l.dayID)", fromID: l.fromID, fromName: l.fromName,
                        toID: l.toID, toName: l.toName, dayID: l.dayID, desk: l.desk) }
    }

    /// F1: positional seat color — non-me participants in first-appearance order across the legs.
    private var orderedPeers: [String] {
        var ids: [String] = []
        for s in steps { for id in [s.fromID, s.toID] where id != myID && !ids.contains(id) { ids.append(id) } }
        return ids
    }
    private func color(_ id: String) -> Color {
        TradeColors.color(forParticipant: id, myID: myID, orderedPeers: orderedPeers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(steps) { s in
                HStack(spacing: 6) {
                    Text(label(s.fromID, s.fromName)).font(.caption.weight(.semibold))
                        .foregroundStyle(color(s.fromID))
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Text(label(s.toID, s.toName)).font(.caption.weight(.semibold))
                        .foregroundStyle(color(s.toID))
                    Spacer(minLength: 6)
                    // Day chip in the GIVER's color (border) — matches that person's calendar.
                    Text(SwapChips.chipDay(s.dayID) + (s.desk.map { " · \($0)" } ?? ""))
                        .font(.dsChip)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(color(s.fromID).opacity(DS.pillFill), in: Capsule())
                        .foregroundStyle(color(s.fromID))
                }
            }
        }
    }

    private func label(_ id: String, _ name: String) -> String { id == myID ? "You" : firstName(name) }
}

// MARK: - Swap day chips (give = blue, get = red) — shared by route & package cards

/// Compact day chips for a swap: which days YOU give (blue) and get (red), matching
/// the calendar color language. Overflow collapses to "+N".
struct SwapChips: View {
    let giveDays: [String]
    let getDays: [String]
    var giveLabel = "You give"
    var getLabel = "You get"
    var labelWidth: CGFloat = 50
    var maxChips = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !giveDays.isEmpty { row(giveLabel, giveDays, BrickPalette.mineScheme) }
            if !getDays.isEmpty  { row(getLabel,  getDays,  BrickPalette.peerScheme) }
        }
    }

    private func row(_ label: String, _ days: [String], _ color: Color) -> some View {
        HStack(spacing: DS.xs + 1) {
            Text(label).font(.dsLabel).foregroundStyle(color)
                .frame(width: labelWidth, alignment: .leading)
            ForEach(days.prefix(maxChips), id: \.self) { iso in
                Text(Self.chipDay(iso))
                    .font(.dsChip)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(color.opacity(DS.pillFill), in: Capsule())
                    .foregroundStyle(color)
            }
            if days.count > maxChips {
                Text("+\(days.count - maxChips)").font(.dsBadge).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    static func chipDay(_ iso: String) -> String {
        guard let d = TradeMatcher.dayDate(fromISO: iso) else { return iso }
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
    }
}

// MARK: - Package card (one card per deal)

/// B4-14: compact ECB-style card for two-person swaps — thin (more results per screen), shows the
/// counterparty's name + status snapshot, "You get" / "They get" **once each** (no PackageCard
/// duplication), badges (🔥/📖/Q), and Propose. Tapping opens their schedule. 3+-person and circular
/// keep `PackageCard`. Presentation-only: the same 2-way packages, in the same order (INV-2).
struct CompactSwapCard: View {
    let package: TradePackage
    let onPropose: () -> Void
    var onOpen: () -> Void = {}

    private var myID: String { SettingsManager.shared.username }

    var body: some View {
        let a = package.assignments.first
        let peerColor = a.map { TradeColors.color(forParticipant: $0.workerID, myID: myID, orderedPeers: [$0.workerID]) } ?? AppColor.neutral
        VStack(alignment: .leading, spacing: 6) {
            // Header: peer name + their status snapshot · badges · Propose.
            HStack(spacing: 8) {
                Circle().fill(peerColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text((a?.name ?? "Swap") + (a.map { botSuffix($0.workerID) } ?? "")).font(.subheadline.weight(.semibold))
                    if let id = a?.workerID, let status = participantStatus(id), !status.isEmpty {
                        Text(status).font(.caption2).italic().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                badges
                Button(action: onPropose) {
                    Label("Propose", systemImage: "paperplane.fill").labelStyle(.iconOnly).font(.subheadline)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityLabel("Propose")
            }
            // You get / They get — on ONE line (ECB-card style), each shown once.
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                swapLine("You get", days: a?.takeDayIDs ?? [], color: BrickPalette.mineScheme)
                swapLine("They get", days: a?.giveDayIDs ?? [], color: peerColor)
                Spacer(minLength: 0)
            }
            if DevAccess.shared.unlocked {
                Text(String(format: "TradeScore: %.0f%% · cover %d", package.acceptanceScore * 100, package.coverageCount))
                    .font(.dsBadge).foregroundStyle(AppColor.special)
            }
        }
        .padding(.horizontal, DS.cardPadding).padding(.vertical, 8)
        .background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))
        .padding(.horizontal)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 6) {
            if package.qualSwap != nil {
                Image(systemName: "q.square.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(AppColor.special)
            }
            if package.fireCount > 0 {
                Label("\(package.fireCount)", systemImage: "flame.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(AppColor.heat).labelStyle(.titleAndIcon)
            }
            if package.bookendTotal > 0 {
                Label("\(package.bookendTotal)", systemImage: "book.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(AppColor.success).labelStyle(.titleAndIcon)
            }
        }
    }

    private func swapLine(_ label: String, days: [String], color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(color)
            Text(days.isEmpty ? "—" : DayFmt.list(days)).font(.caption)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
    }
}

/// The counterparty's WEEK containing the shift you're giving them, that day highlighted (in their color)
/// with YOUR shift label — so you can see how the pickup lands in their week (bookend vs split). Loads
/// only this peer's schedule lazily (after the feed renders; cached in RosterStore), keeping search fast.
/// Tapping the parent card opens the full calendar. (B4-14 mini-calendar.)
struct TraderWeekStrip: View {
    let workerID: String
    let giveDayIDs: [String]
    let peerColor: Color
    @State private var peerLabels: [String: String] = [:]
    @State private var loaded = false

    private let cal = Calendar.current
    private static let wd = ["Su", "M", "T", "W", "Th", "F", "Sa"]
    private static let isoF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    private var giveSet: Set<String> { Set(giveDayIDs) }
    /// Sun–Sat of the week that holds the earliest give-day.
    private var weekDays: [Date] {
        guard let first = giveDayIDs.min(), let d = TradeMatcher.dayDate(fromISO: first),
              let wk = cal.dateInterval(of: .weekOfYear, for: d) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: wk.start) }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weekDays, id: \.self) { date in
                let key = Self.isoF.string(from: date)
                let isGive = giveSet.contains(key)
                let label = isGive ? myShiftLabel(key) : (peerLabels[key] ?? "")
                VStack(spacing: 1) {
                    Text(Self.wd[cal.component(.weekday, from: date) - 1])
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    Text("\(cal.component(.day, from: date))")
                        .font(.system(size: 11, weight: isGive ? .bold : .regular))
                        .foregroundStyle(isGive ? .white : .primary)
                    Text(label.isEmpty ? "·" : label)
                        .font(.system(size: 8, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(isGive ? .white : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(isGive ? peerColor : Color(.tertiarySystemFill).opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .task { if !loaded { await load() } }
    }

    /// YOUR shift on a give-day (what they'll be working) — read from your own schedule (synchronous).
    private func myShiftLabel(_ dayID: String) -> String {
        guard let s = ShiftStore.shared.shifts.first(where: { $0.id == dayID && !$0.isOff }) else { return "shift" }
        return "\(ShiftAvailabilityType.infer(fromStartHour: s.startHour).rawValue) \(s.desk)"
    }

    private func load() async {
        var m: [String: String] = [:]
        for e in await RosterStore.shared.schedule(forWorker: workerID) where !e.isOff {
            m[e.day] = "\(ShiftAvailabilityType.infer(fromStartHour: e.startHour).rawValue) \(e.desk)"
        }
        peerLabels = m; loaded = true
    }
}

/// Reusable compact participant summary: one "● Name — Jul 16, Jul 22, Jul 29" line per person (the days
/// they GIVE; the swap/loop conveys who receives them). Shared by the feed's `PackageCard` AND the inbox
/// trade card so both read identically (B6-CARD).
struct TradeParticipantLines: View {
    let rows: [(id: String, name: String, isMe: Bool, days: [String])]
    let orderedPeers: [String]

    private var myID: String { SettingsManager.shared.username }
    private func color(_ id: String, _ isMe: Bool) -> Color {
        isMe ? BrickPalette.mineScheme
             : TradeColors.color(forParticipant: id, myID: myID, orderedPeers: orderedPeers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows, id: \.id) { r in
                HStack(spacing: 8) {
                    Circle().fill(color(r.id, r.isMe)).frame(width: 9, height: 9)
                    Text(r.name).font(.subheadline.weight(.semibold)).foregroundStyle(color(r.id, r.isMe)).lineLimit(1)
                    Text(r.days.isEmpty ? "—" : r.days.map(SwapChips.chipDay).joined(separator: ", "))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(2).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Rows for a directed chain (each participant gives the days on the legs they originate, loop order).
    static func rows(chain legs: [TradeLeg], myID: String) -> [(id: String, name: String, isMe: Bool, days: [String])] {
        var gives: [String: [String]] = [:]; var order: [String] = []
        for leg in legs {
            if gives[leg.fromID] == nil { order.append(leg.fromID) }
            gives[leg.fromID, default: []].append(leg.dayID)
        }
        let mapped = order.map { id in
            let name = legs.first { $0.fromID == id }?.fromName ?? participantName(id)
            return (id: id, name: id == myID ? "You" : name, isMe: id == myID, days: gives[id] ?? [])
        }
        // Each viewer sees THEMSELVES first/on top; the rest stay in loop order. (Colors map by id,
        // so reordering rows for display doesn't change anyone's assigned color.)
        return mapped.filter(\.isMe) + mapped.filter { !$0.isMe }
    }
}

struct PackageCard: View {
    let package: TradePackage
    let onPropose: () -> Void
    let onExecute: () -> Void
    var onOpen: () -> Void = {}

    private var isCircular: Bool { package.isCircular }   // #4: circular only when ≥3 participants

    private var headline: String {
        tradeTypeLabel(distinctPeople: package.peopleCount)
    }
    private var subtitle: String {
        let days = package.allDayIDs.count
        let kind = isCircular ? "circular loop" : (package.isOptimal ? "fewest people" : "quick match")
        return "\(days) day\(days == 1 ? "" : "s") · \(kind)"
    }
    private var quality: (text: String, color: Color) {
        if isCircular { return ("Circular", AppColor.special) }
        return package.isOptimal ? ("Optimal", AppColor.success) : ("Fast", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header — headline value, metadata, quality + urgency.
            HStack(spacing: 10) {
                Image(systemName: isCircular ? "arrow.triangle.2.circlepath" : "person.2.fill")
                    .font(.title3).foregroundStyle(quality.color)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline).font(.headline)
                    Text(subtitle).font(.dsCardMeta).foregroundStyle(.secondary)
                    // DEV-ONLY: TradeScore acceptance estimate. Hidden from the userbase; never in copy;
                    // does NOT affect ranking. Visible only in developer mode.
                    if DevAccess.shared.unlocked {
                        Text(String(format: "TradeScore: %.0f%% · cover %d", package.acceptanceScore * 100, package.coverageCount))
                            .font(.dsBadge).foregroundStyle(AppColor.special)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    pill(quality.text, quality.color)
                    HStack(spacing: 6) {
                        if package.qualSwap != nil {
                            // Q-in-a-box: this solution needs a qual swap (Q1).
                            Label("Qual swap", systemImage: "q.square.fill")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(AppColor.special)
                        }
                        if package.fireCount > 0 {
                            Label("\(package.fireCount)", systemImage: "flame.fill")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(AppColor.heat)
                        }
                        if package.bookendTotal > 0 {
                            // 📖 = total bookends delivered across all parties (more = more optimal).
                            Label("\(package.bookendTotal)", systemImage: "book.fill")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(AppColor.success)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    if package.urgency >= 3 {
                        Label("Urgent", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(BrickPalette.warning)
                    }
                }
            }

            Divider()

            // B6-CARD: one compact line per participant — "● Name — Jul 16, Jul 22, Jul 29" (the days that
            // person GIVES; whoever's next in the swap/loop receives them). Replaces the tall dual
            // Gives/Gets rows, which repeated every day twice. Same component as the inbox trade card.
            TradeParticipantLines(rows: participantRows, orderedPeers: package.assignments.map(\.workerID))

            Divider()

            // Actions — primary commit + view on schedule.
            HStack {
                Button {
                    isCircular ? onExecute() : onPropose()
                } label: {
                    Label("Propose", systemImage: isCircular ? "arrow.triangle.2.circlepath" : "paperplane.fill")   // D4: generic
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                Spacer()
                Button(action: onOpen) {
                    HStack(spacing: 3) {
                        Text("View on schedule").font(.caption.weight(.semibold))
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(AppColor.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.cardPadding)
        .background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))
        .padding(.horizontal)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased())
            .font(.dsBadge)
            .padding(.horizontal, DS.s).padding(.vertical, 3)
            .background(color.opacity(DS.pillFill), in: Capsule())
            .foregroundStyle(color)
    }

    private var myID: String { SettingsManager.shared.username }

    /// One row per participant with the days they GIVE. Reciprocal: You give your give-days, each peer
    /// gives their take-days (= what you get). Circular: each participant gives the days on the legs they
    /// originate, in loop order.
    private var participantRows: [(id: String, name: String, isMe: Bool, days: [String])] {
        if isCircular, let route = package.route {
            var gives: [String: [String]] = [:]; var order: [String] = []
            for leg in route.legs {
                if gives[leg.fromID] == nil { order.append(leg.fromID) }
                gives[leg.fromID, default: []].append(leg.dayID)
            }
            return order.map { id in
                (id: id, name: id == myID ? "You" : participantName(id), isMe: id == myID, days: gives[id] ?? [])
            }
        }
        var rows: [(id: String, name: String, isMe: Bool, days: [String])] = []
        let myGives = package.assignments.flatMap(\.giveDayIDs)
        if !myGives.isEmpty { rows.append((id: "__me", name: "You", isMe: true, days: myGives)) }
        for a in package.assignments {
            rows.append((id: a.workerID, name: a.name, isMe: false, days: a.takeDayIDs))
        }
        return rows
    }
}

// MARK: - Package detail (back-to-back calendars, per-trader tabs)

struct PackageDetailView: View {
    let package: TradePackage
    let onPropose: () -> Void
    let onExecute: () -> Void
    var readOnly: Bool = false   // inbox view: show the calendars, hide the Propose/Execute action

    /// Build a view-only package from an inbox request's chain so the two-calendar view opens
    /// straight from the thread card. startHour is display-irrelevant here (only desk is drawn).
    static func fromChain(_ chain: [TradeLeg]) -> TradePackage {
        let legs = chain.map { NWayLeg(fromID: $0.fromID, toID: $0.toID, dayID: $0.dayID, desk: $0.desk ?? "", startHour: 0) }
        var order: [String] = []
        for l in chain where !order.contains(l.fromID) { order.append(l.fromID) }
        let route = NWayRoute(participants: order, legs: legs, tier: .neutralOptimization,
                              score: 0, usesBookends: false)
        return TradePackage(id: "thread-" + order.joined(separator: ">"),
                            methodology: .circular, assignments: [], route: route)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selectedStep = 0
    @State private var monthIndex = 0
    @State private var schedules: [String: [String: String]] = [:]   // workerID → day labels

    private let cal = Calendar.current
    private let youColor = BrickPalette.mineScheme
    private let monthOffsets = Array(0...12)
    private static let monthF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f }()
    private var myID: String { SettingsManager.shared.username }
    private var isCircular: Bool { package.isCircular }   // #4: circular only when ≥3 participants

    /// One tappable step per handoff. Circular = the loop legs; reciprocal = legs
    /// synthesized from each assignment (you→them for your gives, them→you for theirs).
    struct Step: Identifiable {
        let id: String
        let fromID: String, toID: String, dayID: String
        var desk: String? = nil
    }
    private var steps: [Step] {
        if isCircular, let legs = package.route?.legs {
            return legs.map { Step(id: $0.id, fromID: $0.fromID, toID: $0.toID, dayID: $0.dayID, desk: $0.desk) }
        }
        var out: [Step] = []
        for a in package.assignments {
            for d in a.giveDayIDs { out.append(Step(id: "\(myID)>\(a.workerID)@\(d)", fromID: myID, toID: a.workerID, dayID: d)) }
            for d in a.takeDayIDs { out.append(Step(id: "\(a.workerID)>\(myID)@\(d)", fromID: a.workerID, toID: myID, dayID: d)) }
        }
        return out
    }
    private var participants: [String] {
        if isCircular, let route = package.route { return route.participants }
        var ids = [myID]
        for a in package.assignments where !ids.contains(a.workerID) { ids.append(a.workerID) }
        return ids
    }
    private func colorFor(_ id: String) -> Color {
        TradeColors.color(forParticipant: id, myID: myID, orderedPeers: participants.filter { $0 != myID })   // F1: positional seat color
    }
    private func name(_ id: String) -> String { id == myID ? "You" : participantName(id) }
    private func gives(_ id: String) -> Set<String> { Set(steps.filter { $0.fromID == id }.map(\.dayID)) }
    private func gets(_ id: String) -> Set<String> { Set(steps.filter { $0.toID == id }.map(\.dayID)) }

    private var thisMonthStart: Date {
        cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
    }
    private func monthAnchor(_ offset: Int) -> Date {
        cal.date(byAdding: .month, value: offset, to: thisMonthStart) ?? thisMonthStart
    }
    private func monthOffset(for dayID: String) -> Int {
        guard let d = TradeMatcher.dayDate(fromISO: dayID) else { return 0 }
        let comps = cal.dateComponents([.month], from: thisMonthStart,
                                       to: cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d)
        return max(0, min(monthOffsets.count - 1, comps.month ?? 0))
    }
    private func select(_ i: Int) {
        guard steps.indices.contains(i) else { return }
        selectedStep = i
        monthIndex = monthOffset(for: steps[i].dayID)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // Landscape (wider than tall): calendars go SIDE BY SIDE and the chrome (chip index,
                // legend) collapses so the two calendars scale to fill the screen instead of being
                // squished into an unusable sliver.
                let wide = geo.size.width > geo.size.height
                VStack(spacing: wide ? 6 : 12) {
                    // Compact top row: a small corner X, then the give/get chips right beside it (no
                    // wasted space from a big "Close" button or a verbose title).
                    HStack(alignment: .top, spacing: 10) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color(.tertiarySystemFill)))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Close")
                        chipIndex(wide: wide)
                    }
                    .padding(.horizontal)
                    .padding(.top, 6)

                    HStack {
                        Button { if monthIndex > 0 { monthIndex -= 1 } } label: { Image(systemName: "chevron.left").font(.headline) }
                            .disabled(monthIndex == 0)
                        Spacer()
                        Text(Self.monthF.string(from: monthAnchor(monthIndex))).font(.headline)
                        Spacer()
                        Button { if monthIndex < monthOffsets.count - 1 { monthIndex += 1 } } label: { Image(systemName: "chevron.right").font(.headline) }
                            .disabled(monthIndex >= monthOffsets.count - 1)
                    }
                    .padding(.horizontal)

                    TabView(selection: $monthIndex) {
                        ForEach(monthOffsets, id: \.self) { off in
                            stepCalendars(for: off, wide: wide).tag(off).padding(.horizontal)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    if !readOnly {
                        Button {
                            isCircular ? onExecute() : onPropose()
                            dismiss()
                        } label: {
                            Label("Propose", systemImage: isCircular ? "arrow.triangle.2.circlepath" : "paperplane.fill")   // D4: generic
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).padding(.horizontal).padding(.bottom, 8)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)   // custom compact top row (corner X + chips) instead
            .task { await load() }
        }
    }

    /// Sheet title: a descriptor + counts (dates live in the chips + calendars, not repeated here).
    private var dateTitle: String {
        let g = gives(myID).count, t = gets(myID).count
        if isCircular { return "\(Set(participants).count)-person loop" }
        if g == 0 && t == 0 { return tradeTypeLabel(distinctPeople: Set(participants).count) }
        return "Swap · give \(g), get \(t)"
    }

    /// Compact, fixed-height horizontal index that REPLACES the old growing vertical list — so the
    /// calendars below stay the hero at any trade size. Reciprocal trades show two rows (You give / You
    /// get); circular loops show the loop path in order. Tapping a chip focuses that leg on the calendars.
    @ViewBuilder private func chipIndex(wide: Bool) -> some View {
        let all = Array(steps.enumerated())
        let give = all.filter { $0.element.fromID == myID }
        let get  = all.filter { $0.element.toID == myID }
        Group {
            if isCircular {
                chipRow("Loop", all)
            } else if wide {
                // Landscape: give + get side by side (each slides horizontally) to save vertical space.
                HStack(alignment: .top, spacing: 16) {
                    chipRow("You give", give)
                    chipRow("You get",  get)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    chipRow("You give", give)
                    chipRow("You get",  get)
                }
            }
        }
    }

    private func chipRow(_ label: String, _ items: [(offset: Int, element: Step)]) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text("\(label) \(items.count)")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.element.id) { i, s in
                        Button { withAnimation(.snappy) { select(i) } } label: { chip(i, s) }
                            .buttonStyle(.plain)
                    }
                    if items.isEmpty { Text("—").font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    /// One day chip, colored by the OTHER party (loop: the giver). Selected chip is outlined.
    private func chip(_ i: Int, _ s: Step) -> some View {
        let on = i == selectedStep
        let other = isCircular ? s.fromID : (s.fromID == myID ? s.toID : s.fromID)
        let c = colorFor(other)
        return HStack(spacing: 4) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(SwapChips.chipDay(s.dayID)).font(.caption2.weight(.semibold))
            if isCircular {   // loop needs "who→who" since a hop may not involve you
                Text("\(shortFirst(s.fromID))→\(shortFirst(s.toID))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(on ? c.opacity(0.18) : Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.controlRadius).stroke(on ? c : .clear, lineWidth: 1.5))
    }

    private func shortFirst(_ id: String) -> String {
        if id == myID { return "You" }
        let n = participantName(id)
        return n.split(whereSeparator: { $0 == "," || $0 == " " }).first.map(String.init) ?? n
    }

    /// The selected leg's two calendars — YOU pinned on top whenever the leg involves you (stable, no
    /// give/get flip); a loop hop between two OTHER people shows that hop's giver→receiver.
    @ViewBuilder private func stepCalendars(for off: Int, wide: Bool) -> some View {
        if steps.indices.contains(selectedStep) {
            let s = steps[selectedStep]
            let involvesMe = s.fromID == myID || s.toID == myID
            let topID = involvesMe ? myID : s.fromID
            let bottomID = involvesMe ? (s.fromID == myID ? s.toID : s.fromID) : s.toID
            if wide {
                // Side by side in landscape → each calendar gets full height and stays readable.
                HStack(alignment: .top, spacing: 12) {
                    personCalendar(topID, off: off, focus: s.dayID)
                    personCalendar(bottomID, off: off, focus: s.dayID)
                }
            } else {
                VStack(spacing: 8) {
                    personCalendar(topID, off: off, focus: s.dayID)
                    Image(systemName: "arrow.down").font(.subheadline).foregroundStyle(.secondary)
                    personCalendar(bottomID, off: off, focus: s.dayID)
                }
            }
        }
    }

    private func personCalendar(_ id: String, off: Int, focus: String) -> some View {
        let isMe = id == myID
        let intentClosure: (String) -> (label: String, color: Color)? = { isMe ? myIntent($0) : peerIntent($0, workerID: id) }
        let topoClosure: (String) -> DayTopology = {
            isMe ? DayIntentStore.shared.topology(forDay: $0) : TwoWaySheet.globalTopology($0)
        }
        let eventClosure: (String) -> String? = {
            isMe ? TwoWaySheet.eventText($0, topology: DayIntentStore.shared.topology(forDay: $0), includePrivate: true)
                 : TwoWaySheet.globalEvent($0)
        }
        return MiniScheduleGrid(
            title: name(id), days: schedules[id] ?? [:], month: monthAnchor(off),
            accent: colorFor(id), giveDays: gives(id), takeDays: gets(id), focusDay: focus,
            intent: intentClosure, topology: topoClosure, eventName: eventClosure, fill: true)
            .frame(maxHeight: .infinity)   // the two calendars split the available height → fit, no scroll
    }

    /// My intent on the "You" calendar (name + color) — Want to Trade Away / Keep / Blackout / Want to
    /// Work — surfaced as the cell's corner dot + the tap popover. "Open" (no real intent) is skipped.
    private func myIntent(_ day: String) -> (label: String, color: Color)? {
        let store = DayIntentStore.shared
        if let w = store.workingIntent(forDay: day), w != .neutralOpen {
            let name = w == .dontWantToWork ? "Want to Trade" : (w == .mustWork ? "Keep" : "Want to Work")
            return (name, w.brickColor)
        }
        if let o = store.offIntent(forDay: day), o != .neutralOpen {
            return (o == .mustBeOff ? "Blackout Day" : "Want to Work", o.brickColor)
        }
        if !store.availability(forDay: day).isEmpty { return ("Want to Work", BrickPalette.availableOff) }
        return nil
    }

    /// A peer's published intent (days they're seeking to trade away).
    private func peerIntent(_ day: String, workerID: String) -> (label: String, color: Color)? {
        let seeks = TradeProfileStore.shared.profile(forWorker: workerID)?.seekingDayIDs ?? []
        return seeks.contains(day) ? ("Wants to Trade", BrickPalette.change) : nil
    }

    private func load() async {
        for id in participants where schedules[id] == nil {
            schedules[id] = await TradeMatcher.dayLabels(forWorker: id)
        }
        select(0)
    }
}

// MARK: - Execution confirmation (checkout)

struct ExecutionConfirmationView: View {
    let route: NWayRoute
    var origin: TradeOrigin = .search   // where the loop was surfaced (Intents feed vs Trade Solutions)

    private var messaging = MessagingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var sent = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(route.legs) { leg in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(participantName(leg.fromID)) → \(participantName(leg.toID))")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(prettyDay(leg.dayID)) · desk \(leg.desk) · \(leg.startHour)00")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle").foregroundStyle(AppColor.special)
                        }
                    }
                } header: {
                    Text("Chain of custody — \(route.participants.count) people, \(route.legs.count) shifts")
                } footer: {
                    Text("Sending notifies every other participant with the full loop. Each confirms in their own inbox; enter it on the official board once all agree.")
                }

                Section {
                    Button {
                        Task { await execute() }
                    } label: {
                        HStack {
                            Spacer()
                            if sending { ProgressView() }
                            else { Label(sent ? "Sent" : "Send proposals to all", systemImage: "paperplane.fill") }
                            Spacer()
                        }
                    }
                    .disabled(sending || sent)
                }
            }
            .navigationTitle("Confirm Trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func execute() async {
        sending = true
        let myID = SettingsManager.shared.username
        let legs = route.legs.map {
            TradeLeg(fromID: $0.fromID, fromName: participantName($0.fromID),
                     toID: $0.toID, toName: participantName($0.toID), dayID: $0.dayID, desk: $0.desk)
        }
        for pid in route.participants where pid != myID {
            await messaging.sendRequest(to: pid, toName: participantName(pid),
                                        note: "",   // #7: the card shows the trade visually; no redundant text
                                        take: [], give: [], chain: legs, origin: origin)
        }
        sending = false
        sent = true
    }
}

// MARK: - Helpers

/// "Last, First" / "First Last" → "First", for compact give/get labels.
func firstName(_ name: String) -> String {
    name.components(separatedBy: ",").last?.trimmingCharacters(in: .whitespaces) ?? name
}

func participantName(_ id: String) -> String {
    if id == SettingsManager.shared.username {
        let dn = SettingsManager.shared.displayName
        return dn.isEmpty ? "You" : dn
    }
    // B4-8: published display name → cached roster name → employee # (last resort). `TradeNames.resolved`
    // rejects blank / all-digits / == id so a calendar never shows a bare number when a real name exists.
    return TradeNames.resolved(displayName: TradeProfileStore.shared.profile(forWorker: id)?.displayName,
                               rosterName: RosterStore.shared.name(for: id),
                               workerID: id)
}

func participantStatus(_ id: String) -> String? {
    if id == SettingsManager.shared.username {
        let s = SettingsManager.shared.statusBroadcast
        return s.isEmpty ? nil : s
    }
    let s = TradeProfileStore.shared.profile(forWorker: id)?.statusBroadcast
    return (s?.isEmpty ?? true) ? nil : s
}

/// Is this peer actually ON the app? True only if they're a real signed-in account (their published
/// profile is stamped `accountClaimed`) — NOT merely a legacy/orphan profile record. You are always on.
/// Inactive roster peers still appear in matches (behavior inferred) but can't receive messages.
func participantHasProfile(_ id: String) -> Bool {
    TradeProfileStore.shared.isActiveAccount(id)
}

/// Robot suffix (🤖) for peers not on the app — appended to their NAME in displays so it's obvious
/// they can't be messaged yet. Empty for active users. Display-only; never used as a stored name.
func botSuffix(_ id: String) -> String { participantHasProfile(id) ? "" : " 🤖" }

func prettyDay(_ iso: String) -> String {
    guard let d = TradeMatcher.dayDate(fromISO: iso) else { return iso }
    let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: d)
}

/// Human-readable reciprocal-swap note for a package assignment.
func swapNote(_ a: PackageAssignment) -> String {
    var parts: [String] = []
    if !a.takeDayIDs.isEmpty { parts.append("I take your \(a.takeDayIDs.map(prettyDay).joined(separator: ", "))") }
    if !a.giveDayIDs.isEmpty { parts.append("you take my \(a.giveDayIDs.map(prettyDay).joined(separator: ", "))") }
    return parts.isEmpty ? "Trade proposal." : "Swap: " + parts.joined(separator: "; ") + "."
}


```


## `Sources/UI/Trades/AvailabilityView.swift`

```swift
// AvailabilityView.swift
// Trade discovery surfaces used by the Trades tab (the standalone "My Availability"
// page was retired in v2 — openness/pills now live on the Home calendar):
//   • FindCandidatesSection — reciprocal Trade Search (date range → packages)
//   • ECBTradesView         — one-way ECB (points-for-coverage) trades
//   • TwoWaySheet           — the rich two-person swap explorer
//   • MiniScheduleGrid/Legend — the shared trade calendar + key

import SwiftUI
import UIKit

// MARK: - Find Candidates

/// #7: open a prefilled draft in the OUTLOOK app (ms-outlook://compose); if Outlook isn't installed,
/// fall back to the default mail app via mailto. To = the dispatch trades DL.
@MainActor func openDispatchDraft(subject: String, body: String) {
    let dl = SettingsManager.shared.tradeEmailDL
    if let outlook = TradeEmail.outlookURL(dl: dl, subject: subject, body: body) {
        UIApplication.shared.open(outlook, options: [:]) { ok in
            if !ok, let mail = TradeEmail.mailtoURL(dl: dl, subject: subject, body: body) {
                UIApplication.shared.open(mail)
            }
        }
    } else if let mail = TradeEmail.mailtoURL(dl: dl, subject: subject, body: body) {
        UIApplication.shared.open(mail)
    }
}

struct FindCandidatesSection: View {

    @Binding var whatIf: Bool
    var onReady: () -> Void = {}   // fired once the cold roster load settles (drops the Trades spinner)

    private let store    = ShiftStore.shared
    private let settings = SettingsManager.shared
    private var intent   = TradeIntentStore.shared

    @State private var selectedIDs: Set<String> = []
    @State private var candidates: [PlanCandidate] = []
    @State private var selected: Set<String> = []      // candidates chosen for messaging
    @State private var bookendsOnly = false
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var calendarExpanded = true
    @State private var twoWayCandidate: PlanCandidate?
    @State private var packages: [TradePackage] = []
    @State private var searchText = ""                 // C4: filter candidates by name
    @State private var pinnedPeople: Set<String> = []  // C4: pinned to top (per session)
    @State private var execRoute: NWayRoute?
    @State private var packageSent: String?
    @State private var detailPackage: TradePackage?
    @State private var pkgSwap: PackageSwapContext?    // Q1: qual-swap package → blast picker
    // A1/A2 on Trade Solutions: candidate-focused Master Filter (engine / max-people / Connection),
    // applied to the package results (TS keeps whole packages — no 2-person decomposition).
    @State private var searchFilter = SearchFilter()
    @State private var showFilter = false
    @State private var rosterPeople: [(id: String, name: String)] = []
    @State private var allDispatchers: [(id: String, name: String)] = []   // D2: full-roster lookup (was Just 2)
    @State private var searchTask: Task<Void, Never>?   // A1: cancellable Lucky search
    // More-filter resolution maps for the receive-type / desk-qual criteria (need roster data):
    @State private var dayType: [String: ShiftAvailabilityType] = [:]   // "workerID|dayID" → that shift's type
    @State private var dayQual: [String: String] = [:]                  // "workerID|dayID" → desk's required qual
    @State private var myDayQual: [String: String] = [:]                // my give-day id → desk's required qual
    private var filteredPackages: [TradePackage] { searchFilter.filter(packages).filter(criteriaMatch) }
    /// Quals present across the current results — the qual filter's option list.
    private var availableQuals: [String] { Set(dayQual.values).union(myDayQual.values).sorted() }
    /// Apply the roster-backed More-filter criteria (receive shift-type + desk qual). Date range,
    /// engine, max-people and required-person are handled by `searchFilter.filter`.
    private func criteriaMatch(_ p: TradePackage) -> Bool {
        let types = searchFilter.receiveTypes
        let quals = searchFilter.deskQuals
        if types.isEmpty && quals.isEmpty { return true }
        var recvTypes: Set<ShiftAvailabilityType> = []
        var deskQuals: Set<String> = []
        for a in p.assignments {
            for d in a.takeDayIDs {                     // days I PICK UP (partner shifts)
                if let t = dayType["\(a.workerID)|\(d)"] { recvTypes.insert(t) }
                if let q = dayQual["\(a.workerID)|\(d)"] { deskQuals.insert(q) }
            }
            for d in a.giveDayIDs { if let q = myDayQual[d] { deskQuals.insert(q) } }   // my give desks
        }
        for leg in p.route?.legs ?? [] {
            if leg.toID == settings.username { recvTypes.insert(.infer(fromStartHour: leg.startHour)) }
            if let q = DeskRules.requiredQual(forDesk: leg.desk) { deskQuals.insert(q) }
        }
        if !types.isEmpty, recvTypes.isDisjoint(with: types) { return false }
        if !quals.isEmpty, deskQuals.isDisjoint(with: quals) { return false }
        return true
    }
    // B1: international-desk qual-swap entry — the button glows green only when a selected desk is gated.
    @State private var showQualSwaps = false
    @State private var qualSwapResults: [TradePackage] = []
    @State private var loadingQual = false
    private var qualGatedSelected: Bool { DeskRules.hasQualGatedSelection(desks: selectedShifts.map(\.desk)) }

    private var hasShifts: Bool { !store.upcomingWorkingShifts().isEmpty }
    private var selectedShifts: [Shift] {
        store.shifts.filter { selectedIDs.contains($0.id) }.sorted { $0.date < $1.date }
    }
    /// Selected shifts listed by date, annotating the year only when it's not the
    /// current year (e.g. rolls into January).
    private var selectedDatesLabel: String {
        // Compact numeric dates (7/15, 7/17…) so more fit before truncating; add the year only off-year.
        let cal = Calendar.current
        let thisYear = cal.component(.year, from: Date())
        let f  = DateFormatter(); f.dateFormat  = "M/d"
        let fy = DateFormatter(); fy.dateFormat = "M/d/yy"
        return selectedShifts.map {
            cal.component(.year, from: $0.date) == thisYear ? f.string(from: $0.date) : fy.string(from: $0.date)
        }.joined(separator: ", ")
    }
    private var displayed: [PlanCandidate] {
        // What If? widens results: ignore the bookends-only filter.
        let base = (bookendsOnly && !whatIf) ? candidates.filter { $0.bookendCount > 0 } : candidates
        // C4: name search + pinned-to-top.
        return PeopleFilter.arrange(base, query: searchText, pinned: pinnedPeople,
                                    id: { $0.workerID }, name: { $0.name })
    }
    private let resultColumns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .fullScreenCover(item: $twoWayCandidate) { c in
            TwoWaySheet(candidate: c).magnifiable()
        }
        .sheet(isPresented: $showFilter) {
            MasterFilterSheet(filter: $searchFilter, people: rosterPeople, availableQuals: availableQuals,
                              onGenerate: { f in if !selectedIDs.isEmpty { runSearch { await search(generation: f, lucky: true) } } },
                              onReset: { if !selectedIDs.isEmpty { runSearch { await searchFast() } } })
        }
        .onDisappear {
            // Leaving Trade Solutions resets the search — no auto-re-search on return (per user). Clear the
            // in-flight task, local state, and the cached snapshot so coming back shows a clean day picker.
            searchTask?.cancel()
            selectedIDs = []; packages = []; candidates = []; hasSearched = false; calendarExpanded = true
            TradeFeedCache.shared.clear(Self.cacheKey)
        }
        .task {
            defer { onReady() }   // clear the Trades spinner however this task exits (incl. early return)
            if allDispatchers.isEmpty { await loadAllDispatchers() }
            // U-PERF: restore prior results on tab return; only re-search if intents/settings changed
            // while away (and we'd already searched). Keeps Trade Solutions loaded across tab switches.
            guard let snap = TradeFeedCache.shared.snapshot(Self.cacheKey) else { return }
            // Only restore the cached selection when the user has NONE in progress — never clobber a
            // selection they've changed since (the "deselected Aug 5 but it came back" bug).
            if selectedIDs.isEmpty { selectedIDs = snap.selectedIDs }
            packages = snap.packages
            candidates = snap.candidates; rosterPeople = snap.rosterPeople; hasSearched = snap.hasSearched
            if snap.hasSearched { calendarExpanded = false }
            if snap.hasSearched, !selectedIDs.isEmpty,
               snap.signature != TradeFeedCache.signature(selectedIDs: selectedIDs, whatIf: whatIf) {
                runSearch { await searchFast() }
            }
        }
        .sheet(isPresented: $showQualSwaps) {
            QualSwapDaysSheet(packages: qualSwapResults, loading: loadingQual, selectedShifts: selectedShifts) { selectedPkgs in
                showQualSwaps = false
                Task {
                    var n = 0
                    for pkg in selectedPkgs {
                        guard let leg = pkg.qualSwap else { continue }
                        await MessagingStore.shared.sendRequest(
                            to: leg.takerID, toName: leg.takerName,
                            note: "Qual swap to give away \(SwapChips.chipDay(leg.giveShiftDayID)) — \(leg.takerName) takes a freed desk.",
                            take: [], give: [leg.giveShiftDayID], qualSwap: leg, origin: .search)
                        n += 1
                    }
                    WidgetData.update()
                    packageSent = "Qual-swap request\(n == 1 ? "" : "s") sent to \(n) dispatcher\(n == 1 ? "" : "s"). Track replies in your Inbox."
                }
            }
        }
        .sheet(item: $execRoute) { ExecutionConfirmationView(route: $0) }
        .fullScreenCover(item: $detailPackage) { pkg in
            PackageDetailView(package: pkg,
                              onPropose: { Task { await propose(pkg) } },
                              onExecute: { if let r = pkg.route { execRoute = r } })
                .magnifiable()
        }
        .alert("Package sent", isPresented: Binding(
            get: { packageSent != nil }, set: { if !$0 { packageSent = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(packageSent ?? "") }
        .sheet(item: $pkgSwap) { ctx in
            QualSwapPickerSheet(giveDeskLabel: "desk \(ctx.leg.giveDesk) (\(ctx.leg.giveQual))",
                                takerName: ctx.leg.takerName, dayLabel: ctx.dayLabel,
                                candidates: ctx.leg.candidates) { chosen in
                Task {
                    var sendLeg = ctx.leg
                    sendLeg.candidates = ctx.leg.candidates.filter { chosen.contains($0.workerID) }
                    await MessagingStore.shared.sendRequest(
                        to: ctx.leg.takerID, toName: ctx.leg.takerName,
                        note: "Qual swap to give away \(ctx.dayLabel) — \(ctx.leg.takerName) takes a freed desk.",
                        take: [], give: [ctx.leg.giveShiftDayID], qualSwap: sendLeg, origin: .search)
                    WidgetData.update()
                    pkgSwap = nil
                    packageSent = "Qual-swap request sent. Track it in your Inbox."
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if !hasShifts {
                Text("Waiting for your schedule to sync — pull to refresh, or check your Employee ID in Settings.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // ONE clean action row: [selection summary ▾] · [Qual Swap when needed] · Find · ⋯
                HStack(spacing: 10) {
                    // Tap the summary to show/hide the day calendar (replaces the separate chevron button).
                    Button { withAnimation(.snappy) { calendarExpanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Trading away").font(.caption2).foregroundStyle(.secondary)
                                Text(selectedIDs.isEmpty ? "Tap to pick days" : selectedDatesLabel)
                                    .font(.subheadline).bold().lineLimit(1).foregroundStyle(.primary)
                            }
                            Image(systemName: calendarExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(calendarExpanded ? "Hide day calendar" : "Show day calendar")

                    Spacer(minLength: 8)

                    // Qual Swap surfaces ONLY when a selected desk actually needs it (progressive disclosure).
                    if qualGatedSelected {
                        Button {
                            Task {
                                loadingQual = true; showQualSwaps = true
                                qualSwapResults = await TradeRouter.qualSwapOptions(forGiveShifts: selectedShifts, excluding: settings.username)
                                loadingQual = false
                            }
                        } label: { Image(systemName: "arrow.triangle.swap") }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(AppColor.success)
                        .disabled(isSearching)
                        .accessibilityLabel("Qual swap for international desks")
                    }

                    // Primary action.
                    Button { TradeHistoryStore.shared.recordSearch(at: Date()); runSearch { await searchFast() } } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(selectedIDs.isEmpty || isSearching)

                    // Everything secondary lives in the overflow — no clutter by default.
                    Menu {
                        if !selectedIDs.isEmpty {
                            Button(role: .destructive) {
                                selectedIDs = []; packages = []; candidates = []; hasSearched = false
                            } label: { Label("Clear selection", systemImage: "xmark.circle") }
                        }
                        Button { showFilter = true } label: { Label(luckyTitle, systemImage: "wand.and.stars") }
                        // What If? hidden for now — it doesn't affect the new package-based results yet.
                        if !allDispatchers.isEmpty {
                            Menu {
                                ForEach(allDispatchers, id: \.id) { p in
                                    Button(p.name) {
                                        twoWayCandidate = PlanCandidate(workerID: p.id, name: p.name, quals: [],
                                                                        coveredShiftIDs: [], bookendShiftIDs: [], week: [])
                                    }
                                }
                            } label: { Label("Look up a dispatcher", systemImage: "magnifyingglass.circle") }
                        }
                        Button { emailSelectedToDispatch() } label: { Label("Email to dispatch DL", systemImage: "envelope") }
                            .disabled(selectedIDs.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                            .foregroundStyle(searchFilter.isActive ? AppColor.primary : .secondary)   // orange = a Lucky filter is on
                    }
                    .accessibilityLabel("More trade options")
                }

                // Trade size appears only once Lucky is engaged; calendar only when expanded.
                if searchFilter.isActive { MaxPeoplePicker() }
                if calendarExpanded {
                    ShiftSelectCalendar(shifts: store.shifts, selection: $selectedIDs)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
        // Re-run FAST when inputs change (What If / saved intents / max-people). Heavy 3+/N-Way is Lucky-only.
        .onChange(of: whatIf) { _, _ in if hasSearched { runSearch { await searchFast() } } }
        .onChange(of: DayIntentStore.shared.intentsRevision) { _, _ in if hasSearched { runSearch { await searchFast() } } }
        .onChange(of: SettingsManager.shared.normalMaxPeople) { _, _ in if hasSearched { runSearch { await searchFast() } } }
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            VStack(spacing: 14) {
                AnimatedLoader(name: "finding-matches", maxSize: 260)
                Button(role: .cancel) { searchTask?.cancel(); isSearching = false } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasSearched {
            ContentUnavailableView("Pick Shifts to Trade", systemImage: "person.2.badge.gearshape",
                description: Text("Tap the days you want to give away, then Find."))
        } else if candidates.isEmpty && packages.isEmpty {
            ContentUnavailableView("No Matches", systemImage: "person.slash",
                description: Text("No one is off, desk-qualified, and rested for these shifts. Try other days or What If? mode."))
        } else if packages.isEmpty {
            ContentUnavailableView("No Package", systemImage: "shippingbox",
                description: Text(candidates.isEmpty
                    ? "No one is off, desk-qualified, and rested for these shifts. Try other days or What If? mode."
                    : "No single package covers all your selected days. Set Trade size to “Pairs” for two-person-only swaps, or look up a specific dispatcher above."))
        } else {
            // Packages only (U5): every solution is a card, sorted fewest-people → 🔥 → bookends.
            ScrollView {
                Text("Trade Solutions").font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.top, 8)
                Text("Swap away all selected days — fewest people first, then most 🔥 and bookends.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                let shown = filteredPackages
                if shown.isEmpty {
                    ContentUnavailableView("No matches for your filter", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Widen the filter (engine / max people / Connection)."))
                        .padding(.top, 12)
                } else {
                    ForEach(shown) { pkg in
                        if pkg.usesCompactCard {   // B4-14: 2-person → compact ECB-style card
                            CompactSwapCard(package: pkg,
                                            onPropose: { Task { await propose(pkg) } },
                                            onOpen: { detailPackage = pkg })
                        } else {
                            PackageCard(package: pkg,
                                        onPropose: { Task { await propose(pkg) } },
                                        onExecute: { if let r = pkg.route { execRoute = r } },
                                        onOpen: { detailPackage = pkg })
                        }
                    }
                }
            }
        }
    }

    /// A1/A2: the "I'm Feeling Lucky" filter bar for Trade Solutions + active-choice chips.
    private var luckyTitle: String {
        searchFilter.summary(nameFor: { id in rosterPeople.first { $0.id == id }?.name ?? id })
            .map { "Lucky: \($0)" } ?? "I'm Feeling Lucky"
    }

    // (Old always-on lucky bar / look-up capsule / chip removed — their actions now live in the
    // trade bar's overflow ⋯ menu. `luckyTitle` above is still used as that menu item's label.)

    private var resultsHeader: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $bookendsOnly) {
                Label("Bookends", systemImage: "book.fill").font(.caption2)
            }
            .toggleStyle(.button).controlSize(.mini).tint(AppColor.success)

            Spacer()
            Text("\(displayed.count) matched").font(.caption).foregroundStyle(.secondary)
            Spacer()

            Button(allSelected ? "Clear" : "All") { toggleAll() }.font(.caption)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }

    private var messageBar: some View {
        Button { messageSelected() } label: {
            Label("Message \(selectedCount) selected", systemImage: "message.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedCount == 0)
        .padding(10)
        .background(.bar)
    }

    private var selectedCount: Int { displayed.filter { selected.contains($0.id) }.count }
    private var allSelected: Bool { !displayed.isEmpty && displayed.allSatisfy { selected.contains($0.id) } }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    private func toggleAll() {
        if allSelected { displayed.forEach { selected.remove($0.id) } }
        else { displayed.forEach { selected.insert($0.id) } }
    }

    /// A1: run a search, CANCELLING any still-running one first (Find / Generate / Reset / What-If
    /// supersedes the previous search instead of racing it).
    private func runSearch(_ work: @escaping () async -> Void) {
        searchTask?.cancel()
        searchTask = Task {
            // B4-10: debounce — coalesce rapid triggers so the engine starts once for the settled input.
            // A superseded task is cancelled during the sleep and bails; the final trigger still runs.
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            await work()
        }
    }

    /// Find: fast 2-person generation, with any Lucky filter cleared so the results show.
    private func searchFast() async {
        searchFilter = .normal
        // Step 4: Find searches up to the user's N-max toggle (default 3); floor + N-penalty keep
        // small trades on top.
        await search(generation: SearchFilter(engine: .both, maxPeople: SettingsManager.shared.normalMaxPeople))
    }

    /// `generation` bounds the engine work: `.fast` (2-person, the Find default) or the user's Lucky
    /// criteria (heavy 3+/N-Way, one-time via Generate). Display still filters via `searchFilter`.
    private func search(generation: SearchFilter = .fast, lucky: Bool = false) async {
        let shifts = selectedShifts
        guard !shifts.isEmpty else { return }
        isSearching = true
        selected = []

        let able = await TradeMatcher.candidatesForTrades(shifts: shifts, excluding: settings.username)
        await TradeProfileStore.shared.refreshOthers()
        let profiles = TradeProfileStore.shared

        // Annotate each able candidate with their published willingness; drop
        // anyone who's opted in but won't take any of these shifts. No profile =
        // unknown (kept, ranked below the willing).
        var annotated: [PlanCandidate] = able.compactMap { c in
            let covered = shifts.filter { c.coveredShiftIDs.contains($0.id) }
            let w = TradeProfile.classify(coveredShifts: covered,
                                          bookendIDs: c.bookendShiftIDs,
                                          profile: profiles.profile(forWorker: c.workerID))
            // What If? keeps even opted-out (declined) candidates in the fallback set.
            guard whatIf || w != .declined else { return nil }
            var x = c
            x.willingness = w
            return x
        }

        // 🔥×N gold — A (your give-away days they'd take) + B (their wanted days
        // you'd take), gated by the receiving side's openness + blacklist. The
        // give-away set is your year-round marks PLUS the days selected in this
        // search. Computed only for candidates who've published a profile.
        let mySeeking = DayIntentStore.shared.seekingDayIDs
        var giveByID: [String: Shift] = [:]
        for s in shifts { giveByID[s.id] = s }                                   // this search's selection
        for s in store.shifts where mySeeking.contains(s.id) { giveByID[s.id] = s } // year-round marks
        let myGiveShifts = Array(giveByID.values)
        let myEntries = await RosterStore.shared.schedule(forWorker: settings.username)
        let myProfile = profiles.myProfile()
        for i in annotated.indices {
            guard let theirProfile = profiles.profile(forWorker: annotated[i].workerID) else { continue }
            annotated[i].twoWayCount = await TradeMatcher.goldCount(
                workerID: annotated[i].workerID, myGiveShifts: myGiveShifts,
                theirProfile: theirProfile, myProfile: myProfile, myEntries: myEntries)
        }

        candidates = annotated.sorted {
            if $0.twoWayCount != $1.twoWayCount { return $0.twoWayCount > $1.twoWayCount }
            if $0.willingness.rank != $1.willingness.rank { return $0.willingness.rank < $1.willingness.rank }
            if $0.bookendCount != $1.bookendCount { return $0.bookendCount > $1.bookendCount }
            if $0.matchCount != $1.matchCount { return $0.matchCount > $1.matchCount }
            return $0.name < $1.name
        }

        // Same packaging algos as Trade by Intents, seeded from the selected days. Generation
        // scope gates the heavy 3+/N-Way work to Lucky → Generate (Find stays fast).
        let result = await TradeRouter.packages(forGiveShifts: shifts, excluding: settings.username, generation: generation, lucky: lucky)
        if Task.isCancelled { return }   // A1: superseded by a newer search — don't clobber its state
        packages = result

        // Resolve type + desk-qual for every result day so the More-filter (shift-time / qual) can
        // apply synchronously. Partner shifts come from their cached schedules; mine from the store.
        var dt: [String: ShiftAvailabilityType] = [:]; var dq: [String: String] = [:]
        for wid in Set(packages.flatMap { $0.assignments.map(\.workerID) }) {
            for e in await RosterStore.shared.schedule(forWorker: wid) where !e.isOff {
                dt["\(wid)|\(e.day)"] = ShiftAvailabilityType.infer(fromStartHour: e.startHour)
                if let q = DeskRules.requiredQual(forDesk: e.desk) { dq["\(wid)|\(e.day)"] = q }
            }
        }
        dayType = dt; dayQual = dq
        myDayQual = Dictionary(uniqueKeysWithValues: store.shifts.compactMap { s in
            (!s.isOff ? DeskRules.requiredQual(forDesk: s.desk) : nil).map { (s.id, $0) }
        })

        // A2: people for the Connection dropdown — candidates + published peers + result participants.
        var seen = Set<String>(); var people: [(id: String, name: String)] = []
        func add(_ id: String, _ name: String) {
            guard id != settings.username, seen.insert(id).inserted else { return }
            people.append((id, TradeNames.resolved(displayName: nil, rosterName: name, workerID: id)))
        }
        for c in candidates { add(c.workerID, c.name) }
        for (id, p) in profiles.others { add(id, p.displayName) }
        for pkg in packages { for a in pkg.assignments { add(a.workerID, a.name) } }
        rosterPeople = people.sorted { $0.name < $1.name }

        isSearching = false
        hasSearched = true
        withAnimation(.snappy) { calendarExpanded = false }
        // U-PERF: cache so a tab switch restores results without re-running the engine.
        TradeFeedCache.shared.save(Self.cacheKey, .init(
            signature: TradeFeedCache.signature(selectedIDs: Set(shifts.map(\.id)), whatIf: whatIf),
            selectedIDs: selectedIDs, packages: packages, candidates: candidates,
            rosterPeople: rosterPeople, hasSearched: true))
    }

    private static let cacheKey = "tradeSolutions"

    /// D2: load the full distinct roster (minus you) for the "Look up a dispatcher" dropdown — ONCE per
    /// session (cached in TradeFeedCache), so it's not re-fetched on every tab return.
    private func loadAllDispatchers() async {
        if !TradeFeedCache.shared.allDispatchers.isEmpty {
            allDispatchers = TradeFeedCache.shared.allDispatchers; return
        }
        let myID = settings.username
        let now = Date(); let end = Calendar.current.date(byAdding: .month, value: 12, to: now) ?? now
        let entries = await RosterStore.shared.entries(from: now, to: end)
        var seen = Set<String>(); var out: [(id: String, name: String)] = []
        for e in entries where e.workerID != myID && seen.insert(e.workerID).inserted {
            out.append((e.workerID, TradeNames.resolved(displayName: nil, rosterName: e.workerName, workerID: e.workerID)))
        }
        allDispatchers = out.sorted { $0.name < $1.name }
        TradeFeedCache.shared.allDispatchers = allDispatchers
    }

    /// #7: email the selected give-days to the dispatch DL (Outlook draft) + Must-Be-Off blackout days.
    private func emailSelectedToDispatch() {
        let me = settings.displayName.isEmpty ? settings.username : settings.displayName
        let give = selectedShifts.map { prettyDay($0.id) }
        let blackout = DayIntentStore.shared.mustBeOffDayIDs.sorted().map { prettyDay($0) }
        openDispatchDraft(subject: TradeEmail.dispatchSubject(giver: me),
                          body: TradeEmail.dispatchBody(giver: me, giveDays: give, blackoutDays: blackout))
    }

    /// Greedy package: send a cover request to each assigned dispatcher. A qual-swap package
    /// instead opens the blast picker so the user chooses which bridges to ask (Q1).
    private func propose(_ pkg: TradePackage) async {
        if let leg = pkg.qualSwap { pkgSwap = PackageSwapContext(leg: leg); return }
        for a in pkg.assignments {
            await MessagingStore.shared.sendRequest(
                to: a.workerID, toName: a.name, note: swapNote(a),
                take: a.takeDayIDs, give: a.giveDayIDs, origin: .search)
        }
        WidgetData.update()
        let n = pkg.assignments.count
        packageSent = "Sent to \(n) dispatcher\(n == 1 ? "" : "s"). Track replies in your Inbox."
    }

    private func messageSelected() {
        let chosen = displayed.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let dayList = selectedShifts.map { "\(Self.weekday($0.date)) \($0.formattedDate) (\($0.title))" }.joined(separator: "; ")
        let names = chosen.map { $0.name }.joined(separator: ", ")
        let body = "Hi — looking to trade away: \(dayList). Reaching out to: \(names). Let me know what you can take!"
        let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "sms:?body=\(encoded)") { UIApplication.shared.open(url) }
    }

    static func weekday(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: date)
    }
}

// MARK: - ECB Trades (one-way, points-for-coverage)

/// One-way trades: find who can cover shifts you want off, offer ECB points, and
/// request them all. No swap-back, no greedy/N-way — pure "who can work my shift".
struct ECBTradesView: View {
    private let store    = ShiftStore.shared
    private let settings = SettingsManager.shared

    @State private var selectedIDs: Set<String> = []
    @State private var selectedRecipients: Set<String> = []   // tap-to-select takers for the ECB send
    @State private var candidates: [PlanCandidate] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var ecb: Double = 9
    @State private var calendarExpanded = true
    @State private var sentMsg: String?
    @Environment(\.horizontalSizeClass) private var hSize

    private var hasShifts: Bool { !store.upcomingWorkingShifts().isEmpty }
    private var selectedShifts: [Shift] {
        store.shifts.filter { selectedIDs.contains($0.id) }.sorted { $0.date < $1.date }
    }
    private var selectedDatesLabel: String {
        let cal = Calendar.current
        let thisYear = cal.component(.year, from: Date())
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        let fy = DateFormatter(); fy.dateFormat = "EEE MMM d, yyyy"
        return selectedShifts.map {
            cal.component(.year, from: $0.date) == thisYear ? f.string(from: $0.date) : fy.string(from: $0.date)
        }.joined(separator: ", ")
    }
    // #6: two columns on regular-width (iPad), one on compact (iPhone portrait).
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: hSize == .regular ? 2 : 1)
    }
    /// Candidates who'd cover at least one selected day as a bookend (for the bookend-only broadcast).
    private var bookendCandidates: [PlanCandidate] { candidates.filter { $0.bookendCount > 0 } }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .alert("ECB requests sent", isPresented: Binding(
            get: { sentMsg != nil }, set: { if !$0 { sentMsg = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(sentMsg ?? "") }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if !hasShifts {
                Text("Waiting for your schedule to sync — pull to refresh.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Stepper(value: $ecb, in: 5...25, step: 0.5) {
                    HStack(spacing: 8) {
                        Label("ECB offered", systemImage: "star.circle.fill").foregroundStyle(AppColor.pending)
                        Text(ecbText(ecb)).font(.headline.monospacedDigit())
                        Spacer()
                    }
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Take my shift (one-way)").font(.caption2).foregroundStyle(.secondary)
                        Text(selectedIDs.isEmpty ? "Tap days on the calendar" : selectedDatesLabel)
                            .font(.subheadline).bold().lineLimit(2)
                    }
                    Spacer()
                    Button { emailECBToDispatch() } label: { Image(systemName: "envelope.fill") }
                        .controlSize(.small).disabled(selectedIDs.isEmpty)
                        .accessibilityLabel("Email ECB offer to dispatch DL")
                    Button { TradeHistoryStore.shared.recordSearch(at: Date()); Task { await search() } } label: { Label("Find", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(selectedIDs.isEmpty || isSearching)
                    Button { withAnimation(.snappy) { calendarExpanded.toggle() } } label: {
                        Image(systemName: calendarExpanded ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                    }
                }
                if calendarExpanded {
                    ShiftSelectCalendar(shifts: store.shifts, selection: $selectedIDs)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8).background(.bar)
    }

    @ViewBuilder private var content: some View {
        if isSearching {
            AnimatedLoader(name: "finding-matches", maxSize: 260)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasSearched {
            ContentUnavailableView("One-Way ECB Trades", systemImage: "star.circle",
                description: Text("Pick shifts you want taken, set the ECB you'll offer, then Find. No swap back — you're paying ECB points."))
        } else if candidates.isEmpty {
            ContentUnavailableView("No Takers", systemImage: "person.slash",
                description: Text("No one is off, desk-qualified, and rested to take these shifts."))
        } else {
            VStack(spacing: 0) {
                Text("\(candidates.count) can take").font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                IntentColorKey().padding(.horizontal, 8)   // #5: intent-color legend in ECB
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(candidates) { c in
                            PlanCandidateCell(candidate: c, selectedShifts: selectedShifts,
                                              total: selectedShifts.count,
                                              isSelected: selectedRecipients.contains(c.workerID),
                                              onTap: { toggleRecipient(c.workerID) },
                                              onEnter: {}, showSchedule: true, showEnter: false)
                        }
                    }
                    .padding(8)
                }
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Button { Task { await requestAll(bookendsOnly: true) } } label: {
                            Label("Bookends (\(bookendCandidates.count))", systemImage: "book.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(AppColor.success)
                        .disabled(bookendCandidates.isEmpty)
                        Button { Task { await requestAll(bookendsOnly: false) } } label: {
                            Label("All \(candidates.count)", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    // Tap dispatchers above to pick exactly who gets the offer, then send to just them.
                    Button { Task { await requestSelected() } } label: {
                        Label(selectedRecipients.isEmpty ? "Send to Selected"
                                                          : "Send to Selected (\(selectedRecipients.count))",
                              systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedRecipients.isEmpty)
                }
                .padding(10).background(.bar)
            }
        }
    }

    /// #7: email the ECB offer (selected days + ECB count, NO blackout) to the dispatch DL (Outlook).
    private func emailECBToDispatch() {
        let me = settings.displayName.isEmpty ? settings.username : settings.displayName
        let give = selectedShifts.map { prettyDay($0.id) }
        openDispatchDraft(subject: TradeEmail.ecbSubject(giver: me, ecb: ecb),
                          body: TradeEmail.ecbBody(giver: me, giveDays: give, ecb: ecb))
    }

    private func search() async {
        let shifts = selectedShifts
        guard !shifts.isEmpty else { return }
        isSearching = true
        selectedRecipients = []   // a fresh candidate list — clear any prior hand-picked takers
        let able = await TradeMatcher.candidatesForTrades(shifts: shifts, excluding: settings.username)
        await TradeProfileStore.shared.refreshOthers()
        // ECB broadcast filter (U2/U5): only offer to recipients whose OWN rules accept it —
        // weekly cap, must-be-off, and published shift availability (the unified `.full` gate).
        // Want-to-work is NOT a filter (it's surfaced as 🔥 + sorted first below). The initiating
        // searcher is ungated. Load the roster span once (perf rule), then filter.
        let cal = Calendar.current
        let dates = shifts.map { cal.startOfDay(for: $0.date) }
        let lower = cal.date(byAdding: .day, value: -8, to: dates.min() ?? Date()) ?? Date()
        let upper = cal.date(byAdding: .day, value: 8, to: dates.max() ?? Date()) ?? Date()
        let entries = await RosterStore.shared.entries(from: lower, to: upper)
        var maps: [String: [String: RosterEntry]] = [:]
        for e in entries { maps[e.workerID, default: [:]][e.day] = e }
        let eligible = able.filter { c in
            guard let prof = TradeProfileStore.shared.profile(forWorker: c.workerID) else { return true }
            let map = maps[c.workerID] ?? [:]
            return shifts.contains { s in
                guard c.coveredShiftIDs.contains(s.id) else { return false }
                let day = cal.startOfDay(for: s.date)
                return TradeEligibility.canCover(
                    coverDayID: TradeMatcher.isoDay(day), coverDay: day, desk: s.desk, startHour: s.startHour,
                    coverMap: map, coverQuals: c.quals, coverProfile: prof, options: .full).eligible
            }
        }
        // 4101: behavior filter for INACTIVE/robot accounts only. An ACTIVE dispatcher (claimed account)
        // already had their own prefs/blacklists applied by the `.full` gate above, so they pass through
        // untouched. For someone NOT on the app (no claimed profile), we can't read prefs — so we infer
        // willingness from their last-60-day behavior: only offer a TYPE (AM/PM/MID) they've actually
        // worked recently (a MID-only dispatcher won't be offered a PM).
        var behaviorFiltered: [PlanCandidate] = []
        for c in eligible {
            let isActive = TradeProfileStore.shared.profile(forWorker: c.workerID)?.accountClaimed == true
            if isActive { behaviorFiltered.append(c); continue }
            let coveredTypes = Set(shifts.filter { c.coveredShiftIDs.contains($0.id) }
                .map { ShiftAvailabilityType.infer(fromStartHour: $0.startHour) })
            let recent = await TradeMatcher.recentWorkedTypes(workerID: c.workerID)
            if TradeMatcher.recentBehaviorAllows(recentTypes: recent, coveredTypes: coveredTypes) {
                behaviorFiltered.append(c)
            }
        }
        // People who actively marked WANT-TO-WORK (published availability) on these
        // off days are looking for a shift — surface them first (🔥).
        candidates = behaviorFiltered.sorted {
            if $0.bookendCount != $1.bookendCount { return $0.bookendCount > $1.bookendCount }  // #6: bookends first
            let aw = wantsToWork($0), bw = wantsToWork($1)
            if aw != bw { return aw }
            if $0.matchCount != $1.matchCount { return $0.matchCount > $1.matchCount }
            return $0.name < $1.name
        }
        isSearching = false; hasSearched = true
        withAnimation(.snappy) { calendarExpanded = false }
    }

    /// Whether this dispatcher published want-to-work availability for any of the
    /// requested days (= they're actively seeking a shift).
    private func wantsToWork(_ c: PlanCandidate) -> Bool {
        guard let prof = TradeProfileStore.shared.profile(forWorker: c.workerID),
              prof.hasPublishedAvailability else { return false }
        return selectedShifts.contains { s in
            let t = ShiftAvailabilityType.infer(fromStartHour: s.startHour)
            return prof.availabilityMap[s.id]?.contains(t) ?? false
        }
    }

    /// Toggle a taker in/out of the hand-picked recipient set (tap-to-select, no checkbox).
    private func toggleRecipient(_ id: String) {
        if selectedRecipients.contains(id) { selectedRecipients.remove(id) }
        else { selectedRecipients.insert(id) }
    }

    private func requestAll(bookendsOnly: Bool) async {
        await sendECB(to: bookendsOnly ? bookendCandidates : candidates)   // #6: bookends-only or everyone
    }

    /// Send the ECB offer to exactly the hand-picked takers (tap-to-select).
    private func requestSelected() async {
        await sendECB(to: candidates.filter { selectedRecipients.contains($0.workerID) })
    }

    /// One ECB send path — a request per taker for only the selected days THEY can cover.
    private func sendECB(to targets: [PlanCandidate]) async {
        let offerID = UUID().uuidString   // groups the broadcast; queue is per shift
        var sent = 0
        for c in targets {
            let theirDays = selectedShifts.filter { c.coveredShiftIDs.contains($0.id) }.map(\.id)
            guard !theirDays.isEmpty else { continue }
            let dates = theirDays.map { prettyDay($0) }.joined(separator: ", ")
            // No boilerplate note — the card shows the ECB offer + shifts, and the accepter's employee #
            // appears automatically in the sender's ECB offer view once they accept.
            await MessagingStore.shared.sendRequest(
                to: c.workerID, toName: c.name, note: "",
                take: [], give: theirDays, ecb: Int(ecb.rounded()), ecbValue: ecb, offerID: offerID, origin: .ecb)
            sent += 1
        }
        WidgetData.update()
        sentMsg = "Sent ECB requests to \(sent) dispatcher\(sent == 1 ? "" : "s") offering \(ecbText(ecb)) ECB. Track replies in your Inbox."
    }
}

struct PlanCandidateCell: View {
    let candidate: PlanCandidate
    let selectedShifts: [Shift]
    let total: Int
    let isSelected: Bool
    let onTap: () -> Void
    let onEnter: () -> Void
    var showSchedule: Bool = false   // ECB tab shows the mini-schedule instead of status
    var showEnter: Bool = true       // ECB hides the two-way enter button

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showMatchDates = false

    private let bookendGreen = AppColor.success
    private let seekingGold  = AppColor.pending

    /// The traded-away shifts this candidate covers as a clean bookend — the
    /// dates the 📖 badge is counting.
    private var bookendShifts: [Shift] {
        selectedShifts.filter { candidate.bookendShiftIDs.contains($0.id) }
    }

    /// Gold = has mutual two-way swaps, green = bookend match, else none.
    private var borderColor: Color {
        if candidate.twoWayCount > 0 { return seekingGold }
        return candidate.bookendCount > 0 ? bookendGreen : .clear
    }

    var body: some View {
        Group {
            if hSize == .compact { compactRow } else { regularRow }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AppColor.primary.opacity(0.10) : Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: DS.rowRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.rowRadius)
                .stroke(borderColor, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    // iPhone: name on its own line; small 📖/🔥 icons beneath it. No mini, no "covers" line.
    private var compactRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name + botSuffix(candidate.workerID)).font(.dsCardTitle).lineLimit(1)
                HStack(spacing: 10) {
                    if !candidate.quals.isEmpty {
                        Text(candidate.quals.joined(separator: " "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    smallBook
                    flameOrUnknown
                }
                if let s = TradeProfileStore.shared.profile(forWorker: candidate.workerID)?.statusBroadcast,
                   !s.isEmpty {
                    Text(s).font(.dsCardMeta).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if showSchedule { scheduleStrip }
            selectionCheck
            if showEnter { enterButton }
        }
    }

    // iPad: big book badge left, name + quals + "covers", mini-schedule on the right.
    private var regularRow: some View {
        HStack(spacing: 10) {
            if candidate.bookendCount > 0 {
                Button { showMatchDates = true } label: {
                    VStack(spacing: 0) {
                        Text("📖").font(.system(size: 24))
                        Text("×\(candidate.bookendCount)")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(bookendGreen)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showMatchDates) {
                    MatchDatesPopover(name: candidate.name, shifts: bookendShifts)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(candidate.name + botSuffix(candidate.workerID)).font(.dsCardTitle).lineLimit(1)
                    flameOrUnknown
                }
                Text(candidate.quals.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("takes \(candidate.matchCount) of \(total)")
                    .font(.dsCardMeta).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if showSchedule { scheduleStrip } else { statusMessage }
            selectionCheck
            if showEnter { enterButton }
        }
    }

    /// Mini-schedule (coverage of the selected shifts, or a ±4-day snapshot).
    @ViewBuilder private var scheduleStrip: some View {
        if candidate.week.isEmpty {
            CoverageStrip(shifts: selectedShifts, covered: candidate.coveredShiftIDs)
        } else {
            MiniSchedule(week: candidate.week)
        }
    }

    /// The candidate's public status line (replaces the mini-schedule).
    @ViewBuilder private var statusMessage: some View {
        if let s = TradeProfileStore.shared.profile(forWorker: candidate.workerID)?.statusBroadcast,
           !s.isEmpty {
            Text(s)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.trailing)
                .frame(maxWidth: 130, alignment: .trailing)
        }
    }

    // Small 📖×N badge (tappable for the match-dates popover) used in the compact row.
    @ViewBuilder private var smallBook: some View {
        if candidate.bookendCount > 0 {
            Button { showMatchDates = true } label: {
                HStack(spacing: 1) {
                    Text("📖").font(.system(size: 12))
                    Text("×\(candidate.bookendCount)").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(bookendGreen)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showMatchDates) {
                MatchDatesPopover(name: candidate.name, shifts: bookendShifts)
            }
        }
    }

    @ViewBuilder private var flameOrUnknown: some View {
        if candidate.twoWayCount > 0 {
            HStack(spacing: 1) {
                Image(systemName: "flame.fill").font(.system(size: 11))
                Text("×\(candidate.twoWayCount)").font(.system(size: 12, weight: .heavy))
            }
            .foregroundStyle(seekingGold)
        } else if candidate.willingness == .unknown {
            Image(systemName: "questionmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var selectionCheck: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(AppColor.primary)
        }
    }

    private var enterButton: some View {
        Button(action: onEnter) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.title3).foregroundStyle(AppColor.primary.opacity(0.85))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Find two-way swaps with \(candidate.name)")
    }
}

/// Lists the dates a candidate covers as bookends — shown when the 📖 badge is tapped.
struct MatchDatesPopover: View {
    let name: String
    let shifts: [Shift]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(name) — bookend matches")
                .font(.headline)
            ForEach(shifts.sorted { $0.date < $1.date }) { s in
                HStack(spacing: 6) {
                    Text("📖").font(.caption2)
                    Text(s.weekdayDate)
                    Text(s.shiftShortLabel).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
        .padding(16)
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - Two-way swap explorer (sheet)

/// Opens on top of the one-way page for one dispatcher: a 4-month-at-a-time,
/// paginated list of feasible BOOKEND swaps — their work days you could cover and
/// your work days they could cover, all bookends. 🔥 marks days the owner has
/// actively marked to trade away (mutual intent).
struct TwoWaySheet: View {
    let candidate: PlanCandidate

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var full: TwoWayPlan?         // whole-horizon results, filtered client-side
    @State private var loading = true
    @State private var windowIndex = 0           // each step = 4 months ahead
    @State private var myDays: [String: String] = [:]      // ISO → A/P/M (mini glance)
    @State private var theirDays: [String: String] = [:]
    @State private var monthIndex = 0                       // month offset shown in the glance
    @State private var sentConfirmation = false
    @State private var selectedTake: Set<String> = []       // their days you'll take
    @State private var selectedGive: Set<String> = []       // your days they'll take
    @State private var theirSeeking: Set<String> = []       // days they want to trade away
    @State private var theirWantToWork: Set<String> = []     // G2c: peer's full intent palette
    @State private var theirMustBeOff: Set<String> = []      // G2c
    @State private var theirKeep: Set<String> = []           // G2c
    @State private var theirStatus: String?                  // R-B: peer's published status, shown in-context
    @State private var peerDisplayName: String?              // G2a: published displayName (resolved into peerName)
    @State private var ignoreMyBlacklist = false            // active-outbound override
    @State private var zoom: CGFloat = 1
    @State private var qualSwapPicker: QualSwapPickerContext?  // Q1/Q2: blast-picker when a give-desk needs a qual swap
    @State private var qualSwapNoBridge: String?               // Q1: a needed swap has no eligible bridge

    private let youColor  = BrickPalette.mineScheme
    // F1/D1: the peer reads in their STABLE per-worker color (was hardcoded red).
    private var themColor: Color { TradeColors.color(forParticipant: candidate.workerID, myID: SettingsManager.shared.username, orderedPeers: [candidate.workerID]) }
    // G2a: the peer's human name — published displayName → roster name → employee # (fixes "660615").
    private var peerName: String { TradeNames.resolved(displayName: peerDisplayName, rosterName: candidate.name, workerID: candidate.workerID) }

    private var isPad: Bool { hSize == .regular }
    /// LANDSCAPE (any device — iPhone rotated or iPad) lays the calendars side by side; PORTRAIT
    /// stacks them. Chosen by real geometry (wider than tall) rather than size class, so an iPhone
    /// in landscape goes side-by-side and a portrait iPad (still `.regular`) doesn't.
    private func sideBySide(_ viewport: CGSize) -> Bool { viewport.width > viewport.height }
    /// Height the twin-calendar glance should occupy. Landscape (either device) and portrait iPad
    /// scale-to-fit the viewport so both calendars are visible without scrolling; portrait iPhone
    /// keeps the fixed full-width stacked height.
    private func glanceBaseHeight(_ viewport: CGSize) -> CGFloat {
        guard viewport.height > 0 else { return 720 }
        if sideBySide(viewport) { return viewport.height * 0.78 }   // landscape: one row of two → fill height
        return isPad ? viewport.height * 0.82 : 720                 // portrait: iPad fills; iPhone stacked fixed
    }

    private let bookendGreen = AppColor.success
    private let seekingGold  = AppColor.pending
    private let cal = Calendar.current
    private let windowMonths = 4
    private static let dayF:   DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f }()
    private static let rangeF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()

    private var today: Date { cal.startOfDay(for: Date()) }
    private var maxWindow: Int { max(0, TradeMatcher.twoWayHorizonMonths / windowMonths - 1) }
    private var windowStart: Date { cal.date(byAdding: .month, value: windowMonths * windowIndex, to: today) ?? today }
    private var windowEnd: Date { cal.date(byAdding: .month, value: windowMonths, to: windowStart) ?? windowStart }
    private var rangeLabel: String {
        let end = cal.date(byAdding: .day, value: -1, to: windowEnd) ?? windowEnd
        return "\(Self.rangeF.string(from: windowStart)) – \(Self.rangeF.string(from: end))"
    }
    private func inWindow(_ d: Date) -> Bool { d >= windowStart && d < windowEnd }

    // Full-horizon mutual matches (both marked the day) — drives the gold count.
    private var mutualTakes: [TwoWayLeg] { full?.iTake.filter(\.wanted) ?? [] }
    private var mutualGives: [TwoWayLeg] { full?.iGive.filter(\.wanted) ?? [] }
    private var mutualN: Int { min(mutualTakes.count, mutualGives.count) }

    // Windowed discovery lists.
    private var winTakes: [TwoWayLeg] { (full?.iTake ?? []).filter { inWindow($0.date) } }
    private var winGives: [TwoWayLeg] { (full?.iGive ?? []).filter { inWindow($0.date) } }

    // Mutual-wanted day-id sets → gold borders on the twin mini-calendars.
    private var myGoldDays: Set<String> { Set(mutualGives.map(\.dayID)) }
    private var theirGoldDays: Set<String> { Set(mutualTakes.map(\.dayID)) }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    AnimatedLoader(name: "finding-matches", maxSize: 260)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let full, (!full.iTake.isEmpty || !full.iGive.isEmpty) {
                    content
                } else {
                    ContentUnavailableView(
                        "No Bookend Swaps",
                        systemImage: "arrow.triangle.swap",
                        description: Text("No feasible bookend swaps with \(peerName) in the next \(TradeMatcher.twoWayHorizonMonths) months."))
                }
            }
            .navigationTitle("Swap with \(peerName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .onChange(of: ignoreMyBlacklist) { _, _ in Task { await load() } }
            .alert("Request sent", isPresented: $sentConfirmation) {
                Button("OK") { dismiss() }
            } message: {
                Text("Sent to \(peerName). Track it in your Trade Inbox.")
            }
            .alert("Qual swap needed", isPresented: Binding(
                get: { qualSwapNoBridge != nil }, set: { if !$0 { qualSwapNoBridge = nil } })) {
                Button("OK", role: .cancel) { qualSwapNoBridge = nil }
            } message: {
                Text(qualSwapNoBridge ?? "")
            }
            .sheet(item: $qualSwapPicker) { ctx in
                QualSwapPickerSheet(
                    giveDeskLabel: "desk \(ctx.giveLeg.desk) (\(ctx.giveQual))",
                    takerName: candidate.name, dayLabel: Self.dayF.string(from: ctx.giveLeg.date),
                    candidates: ctx.candidates) { chosen in
                        Task {
                            let leg = await TradeMatcher.buildQualSwapLeg(
                                giveDayID: ctx.giveLeg.dayID, giveDesk: ctx.giveLeg.desk,
                                giveStartHour: ctx.giveLeg.startHour, giverID: SettingsManager.shared.username,
                                takerID: candidate.workerID, takerName: candidate.name,
                                takerQuals: candidate.quals, chosenCandidateIDs: chosen)
                            await sendTwoWay(note: ctx.note, takes: ctx.takes, gives: ctx.gives, qualSwap: leg)
                            qualSwapPicker = nil
                        }
                    }
            }
        }
    }

    private var thisMonthStart: Date {
        cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
    }
    private func monthAnchor(_ offset: Int) -> Date {
        cal.date(byAdding: .month, value: offset, to: thisMonthStart) ?? thisMonthStart
    }
    private let monthOffsets = Array(-1...13)
    private static let monthF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f }()

    /// Twin month grids that swipe together, month by month. `viewport` is the sheet's available
    /// size, used to scale the calendars to fit the screen on iPad (portrait & landscape).
    private func scheduleGlance(_ viewport: CGSize) -> some View {
        let baseHeight = glanceBaseHeight(viewport)
        let wide = sideBySide(viewport)
        return VStack(spacing: 4) {
            HStack {
                Button { setZoom(zoom - 0.5) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(zoom <= 1)
                Text(Self.monthF.string(from: monthAnchor(monthIndex)))
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                Button { setZoom(zoom + 0.5) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(zoom >= 3)
            }
            .buttonStyle(.plain)
            .font(.body.weight(.semibold))
            .padding(.horizontal, 8)
            TabView(selection: $monthIndex) {
                ForEach(monthOffsets, id: \.self) { off in
                    // Side-by-side on iPad (both fit without scrolling); stacked on iPhone so
                    // each calendar gets full width and stays readable. `fill` stretches the
                    // grids to the glance height so they scale to fit either layout.
                    Group {
                        if wide {
                            HStack(alignment: .top, spacing: 16) { youGrid(off); peerGrid(off) }
                        } else {
                            VStack(spacing: 16) { youGrid(off); peerGrid(off) }
                        }
                    }
                    .padding(.horizontal, 2)
                    .tag(off)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: baseHeight)
            .scaleEffect(zoom, anchor: .top)
            .frame(height: baseHeight * zoom, alignment: .top)
            .clipped()
            Text("Use +/− to zoom · swipe for months")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    /// The "You" calendar — `fill: true` so it stretches to the glance height (scale-to-fit
    /// in both the stacked-iPhone and side-by-side-iPad layouts).
    private func youGrid(_ off: Int) -> some View {
        MiniScheduleGrid(title: "You", days: myDays, month: monthAnchor(off),
                         accent: youColor, giveDays: selectedGive, takeDays: selectedTake,
                         gold: myGoldDays, intent: myIntent,
                         topology: myTopology, eventName: myEvent, fill: true)
    }
    /// The peer's calendar — same fill behavior.
    private func peerGrid(_ off: Int) -> some View {
        MiniScheduleGrid(title: peerName, days: theirDays, month: monthAnchor(off),
                         accent: themColor, giveDays: selectedTake, takeDays: selectedGive,
                         gold: theirGoldDays, intent: theirIntent,
                         topology: Self.globalTopology, eventName: Self.globalEvent, fill: true)
    }

    /// Steps the calendar zoom, clamped to 1×–3×.
    private func setZoom(_ value: CGFloat) {
        withAnimation { zoom = min(max(value, 1), 3) }
    }

    /// Your intent (name + color) on the "You" calendar — Want to Trade Away / Keep / Blackout /
    /// Want to Work — shown as the cell's corner dot + the tap popover. "Open" is skipped.
    private func myIntent(_ day: String) -> (label: String, color: Color)? {
        let store = DayIntentStore.shared
        if let w = store.workingIntent(forDay: day), w != .neutralOpen {
            let name = w == .dontWantToWork ? "Want to Trade" : (w == .mustWork ? "Keep" : "Want to Work")
            return (name, w.brickColor)
        }
        if let o = store.offIntent(forDay: day), o != .neutralOpen {
            return (o == .mustBeOff ? "Blackout Day" : "Want to Work", o.brickColor)
        }
        if !store.availability(forDay: day).isEmpty { return ("Want to Work", BrickPalette.availableOff) }
        return nil
    }

    /// The peer's published intent for a day (name + color).
    private func theirIntent(_ day: String) -> (label: String, color: Color)? {
        if theirSeeking.contains(day)    { return ("Wants to Trade", BrickPalette.change) }
        if theirWantToWork.contains(day) { return ("Wants to Work", BrickPalette.availableOff) }
        if theirMustBeOff.contains(day)  { return ("Blackout Day", OffIntentState.mustBeOff.brickColor) }
        if theirKeep.contains(day)       { return ("Keeping", WorkingIntentState.mustWork.brickColor) }
        return nil
    }

    /// Your own day markers (high-demand or personal milestone) and their detail text.
    private func myTopology(_ day: String) -> DayTopology { DayIntentStore.shared.topology(forDay: day) }
    private func myEvent(_ day: String) -> String? { Self.eventText(day, topology: myTopology(day), includePrivate: true) }

    /// The peer's calendar only shows GLOBAL high-demand days (personal milestones
    /// aren't published), so it's identical for everyone.
    static func globalTopology(_ day: String) -> DayTopology { Holidays.isHighDemand(day) ? .highDemand : .standard }
    static func globalEvent(_ day: String) -> String? { Holidays.name(forDay: day) }

    /// Shared text for a marked day's popover.
    static func eventText(_ day: String, topology: DayTopology, includePrivate: Bool) -> String? {
        switch topology {
        case .highDemand:
            return Holidays.name(forDay: day) ?? "High-impact day"
        case .personalMilestone:
            let note = DayIntentStore.shared.note(forDay: day)
            if let note, includePrivate || !note.isPrivate, !note.message.isEmpty { return note.message }
            return "Personal day"
        case .standard:
            return nil
        }
    }

    private var content: some View {
        GeometryReader { geo in
        ScrollView {
            VStack(spacing: 16) {
                if let theirStatus {   // R-B: show the peer's published status in-context
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "quote.bubble").font(.caption).foregroundStyle(themColor)
                        Text(theirStatus).font(.caption).italic().foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(themColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
                scheduleGlance(geo.size)
                Toggle(isOn: $ignoreMyBlacklist.animation()) {
                    Label("Show my blacklisted shifts (override)", systemImage: "eye.slash")
                        .font(.caption.weight(.semibold))
                }
                .tint(AppColor.pending)
                if mutualN > 0 { mutualSection }
                discoverySection
                VStack(spacing: 4) {
                    Button { propose() } label: {
                        Label("Propose selected swap", systemImage: "message.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedTake.isEmpty && selectedGive.isEmpty)
                    if selectedTake.isEmpty && selectedGive.isEmpty {
                        Text("Tap days above to add them to the proposal.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        }
    }

    // Highlighted, NOT windowed — guarantees a gold candidate always shows content.
    private var mutualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("^[\(mutualN) match](inflect: true) where you BOTH want the trade", systemImage: "flame.fill")
                .font(.subheadline.bold()).foregroundStyle(seekingGold)
            columns(takes: mutualTakes, gives: mutualGives)
        }
        .padding(12)
        .background(seekingGold.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var discoverySection: some View {
        VStack(spacing: 10) {
            HStack {
                Button { if windowIndex > 0 { windowIndex -= 1 } } label: { Image(systemName: "chevron.left").font(.headline) }
                    .disabled(windowIndex == 0)
                Spacer()
                VStack(spacing: 1) {
                    Text(rangeLabel).font(.subheadline).bold()
                    Text("All bookend swaps · 4-month window").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { if windowIndex < maxWindow { windowIndex += 1 } } label: { Image(systemName: "chevron.right").font(.headline) }
                    .disabled(windowIndex >= maxWindow)
            }
            IntentColorKey()   // #5: intent-color legend in the two-way sheet
            columns(takes: winTakes, gives: winGives)
        }
    }

    // Two side-by-side columns: take (their shift) | give (your shift). Tap a day
    // to select it — selected days highlight on the calendars and form the proposal.
    private func columns(takes: [TwoWayLeg], gives: [TwoWayLeg]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            legColumn("You take ←", subtitle: "their shift", legs: takes, selected: selectedTake) { id in
                if selectedTake.contains(id) { selectedTake.remove(id) } else { selectedTake.insert(id) }
            }
            legColumn("You give →", subtitle: "they take", legs: gives, selected: selectedGive) { id in
                if selectedGive.contains(id) { selectedGive.remove(id) } else { selectedGive.insert(id) }
            }
        }
    }

    private func legColumn(_ title: String, subtitle: String, legs: [TwoWayLeg],
                           selected: Set<String>, toggle: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold())
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            if legs.isEmpty {
                Text("None").font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
            } else {
                ForEach(legs) { leg in
                    legCard(leg, isSelected: selected.contains(leg.dayID))
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(leg.dayID) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legCard(_ leg: TwoWayLeg, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11)).foregroundStyle(isSelected ? AppColor.primary : .secondary)
                Text(leg.wanted ? "🔥" : "📖").font(.caption)
                Text(Self.dayF.string(from: leg.date)).font(.caption).bold().lineLimit(1)
            }
            Text(legLabel(leg)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            // #5: only label legs that are ACTUALLY bookends (was printed unconditionally).
            if leg.bookend {
                Text("bookend").font(.system(size: 10, weight: .bold)).foregroundStyle(bookendGreen)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AppColor.primary.opacity(0.14)
                               : (leg.wanted ? seekingGold.opacity(0.12) : Color(.secondarySystemBackground)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? AppColor.primary : (leg.wanted ? seekingGold : .clear), lineWidth: 1.5))
    }

    private func load() async {
        loading = true
        let myProfile    = TradeProfileStore.shared.myProfile()
        let theirProf    = await TradeProfileStore.shared.fetchProfile(forWorker: candidate.workerID)
            ?? TradeProfile.defaultForUnpublished(workerID: candidate.workerID, name: candidate.name)   // A8: missing → Bookends Only
        let theirSeek    = theirProf.seekingDayIDs
        peerDisplayName  = theirProf.displayName   // G2a
        theirWantToWork  = theirProf.wantToWorkDayIDs ?? []   // G2c: peer's full intent palette
        theirMustBeOff   = theirProf.mustBeOffDayIDs ?? []
        theirKeep        = theirProf.keepDayIDs ?? []

        theirSeeking = theirSeek
        let trimmedStatus = theirProf.statusBroadcast?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        theirStatus  = trimmedStatus.isEmpty ? nil : trimmedStatus
        let mySeeking    = DayIntentStore.shared.seekingDayIDs
        let horizonEnd   = cal.date(byAdding: .month, value: TradeMatcher.twoWayHorizonMonths, to: today) ?? today
        full = await TradeMatcher.twoWayExplore(
            withWorker: candidate.workerID, name: candidate.name,
            windowStart: today, windowEnd: horizonEnd,
            mySeeking: mySeeking, theirSeeking: theirSeek,
            myProfile: myProfile, theirProfile: theirProf, myID: SettingsManager.shared.username,
            ignoreOwnBlacklist: ignoreMyBlacklist)
        myDays    = await TradeMatcher.dayLabels(forWorker: SettingsManager.shared.username)
        theirDays = await TradeMatcher.dayLabels(forWorker: candidate.workerID)
        // Pre-select the mutually-wanted days as a sensible starting proposal.
        selectedTake = Set(full?.iTake.filter(\.wanted).map(\.dayID) ?? [])
        selectedGive = Set(full?.iGive.filter(\.wanted).map(\.dayID) ?? [])
        loading = false
    }

    private func legLabel(_ leg: TwoWayLeg) -> String {
        let type = ShiftAvailabilityType.infer(fromStartHour: leg.startHour).rawValue
        return leg.desk.isEmpty ? type : "\(type) · \(leg.desk)"
    }

    private func propose() {
        guard let full else { return }
        let takes = full.iTake.filter { selectedTake.contains($0.dayID) }
        let gives = full.iGive.filter { selectedGive.contains($0.dayID) }
        guard !takes.isEmpty || !gives.isEmpty else { return }
        var parts: [String] = []
        if !takes.isEmpty { parts.append("I take your \(takes.map { Self.dayF.string(from: $0.date) }.joined(separator: ", "))") }
        if !gives.isEmpty { parts.append("you take my \(gives.map { Self.dayF.string(from: $0.date) }.joined(separator: ", "))") }
        let note = "Swap: " + parts.joined(separator: "; ") + "."
        let takeIDs = takes.map(\.dayID), giveIDs = gives.map(\.dayID)
        Task {
            // Q1 (shared SSOT): a give-desk the taker can't work needs a qual swap before the trade can go through.
            if let gap = gives.first(where: { !$0.desk.isEmpty && DeskRules.qualSwapNeeded(forDesk: $0.desk, takerQuals: candidate.quals) }) {
                let bridges = await TradeMatcher.qualSwapBridges(
                    giveDayID: gap.dayID, giveDesk: gap.desk, giveStartHour: gap.startHour,
                    takerID: candidate.workerID, takerQuals: candidate.quals,
                    excludeIDs: [SettingsManager.shared.username])
                guard !bridges.isEmpty else {
                    qualSwapNoBridge = "\(peerName) isn't qualified for desk \(gap.desk), and no one working that day can qual-swap onto it. Adjust the days you give away."
                    return
                }
                let qual = DeskRules.requiredQual(forDesk: gap.desk) ?? "D"
                qualSwapPicker = QualSwapPickerContext(giveLeg: gap, giveQual: qual, candidates: bridges,
                                                       takes: takeIDs, gives: giveIDs, note: note)
                return
            }
            await sendTwoWay(note: note, takes: takeIDs, gives: giveIDs, qualSwap: nil)
        }
    }

    private func sendTwoWay(note: String, takes: [String], gives: [String], qualSwap: QualSwapLegData?) async {
        await MessagingStore.shared.sendRequest(
            to: candidate.workerID, toName: candidate.name, note: note,
            take: takes, give: gives, qualSwap: qualSwap, origin: .search)
        WidgetData.update()
        sentConfirmation = true
    }
}

/// Context for the qual-swap blast picker (Q1/Q2): the give leg that needs a swap, the
/// eligible bridges, and the pending proposal to send once the user picks who to ask.
struct QualSwapPickerContext: Identifiable {
    let id = UUID()
    let giveLeg: TwoWayLeg
    let giveQual: String
    let candidates: [QualSwapCandidate]
    let takes: [String]
    let gives: [String]
    let note: String
}

/// Identifiable wrapper so a qual-swap PACKAGE's leg can drive the blast picker sheet (Q1).
struct PackageSwapContext: Identifiable {
    let id = UUID()
    let leg: QualSwapLegData
    var dayLabel: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let out = DateFormatter(); out.dateFormat = "EEE MMM d"
        guard let d = f.date(from: leg.giveShiftDayID) else { return leg.giveShiftDayID }
        return out.string(from: d)
    }
}

/// B1: a per-day paged sheet of potential qual swaps for the selected international give-days.
/// Swipe between days; each lists the qual-swap options. You SELECT which dispatchers to ask
/// (multi-select, all selected by default) then BATCH-broadcast them all at once — no per-row button.
struct QualSwapDaysSheet: View {
    let packages: [TradePackage]
    var loading: Bool = false
    var selectedShifts: [Shift] = []   // ALL the days you picked — so we can label qual vs normal
    let onBroadcast: ([TradePackage]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private var byDay: [(day: String, pkgs: [TradePackage])] {
        let grouped = Dictionary(grouping: packages) { $0.qualSwap?.giveShiftDayID ?? "" }
        return grouped.keys.sorted().map { (day: $0, pkgs: grouped[$0] ?? []) }
    }
    private var allIDs: [String] { packages.filter { $0.qualSwap != nil }.map(\.id) }
    private var selectedPkgs: [TradePackage] { packages.filter { selected.contains($0.id) } }

    // Multi-day breakdown of the selection (qual-only flow: domestic days stay in Find).
    private var workingShifts: [Shift] { selectedShifts.filter { !$0.isOff } }
    private var qualGatedDays: [String] {
        workingShifts.filter { DeskRules.hasQualGatedSelection(desks: [$0.desk]) }.map(\.id).sorted()
    }
    private var solvedDays: Set<String> { Set(packages.compactMap { $0.qualSwap?.giveShiftDayID }) }
    private var unsolvedQualDays: [String] { qualGatedDays.filter { !solvedDays.contains($0) }.sorted() }
    private var normalDays: [String] {
        workingShifts.filter { !DeskRules.hasQualGatedSelection(desks: [$0.desk]) }.map(\.id).sorted()
    }
    private func dayList(_ ids: [String]) -> String { ids.map(SwapChips.chipDay).joined(separator: ", ") }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    AnimatedLoader(name: "finding-matches", maxSize: 260)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        if !selectedShifts.isEmpty { summaryHeader }
                        if byDay.isEmpty {
                            ContentUnavailableView("No qual swaps found", systemImage: "arrow.triangle.swap",
                                description: Text("No off dispatcher could take these international shifts with a desk swap. Try other days."))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            TabView {
                                ForEach(byDay, id: \.day) { group in
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text(SwapChips.chipDay(group.day)).font(.title3.bold()).padding(.horizontal)
                                            Text("Select who to ask for this day, then broadcast. Each request only goes out for the day it covers.")
                                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                                            ForEach(group.pkgs) { pkg in selectableRow(pkg) }
                                        }.padding(.vertical)
                                    }.tag(group.day)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .always))
                            broadcastBar
                        }
                    }
                }
            }
            .navigationTitle("Qual Swaps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !byDay.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selected.count == allIDs.count ? "Deselect All" : "Select All") {
                            selected = selected.count == allIDs.count ? [] : Set(allIDs)
                        }
                    }
                }
            }
            .onAppear { if selected.isEmpty { selected = Set(allIDs) } }   // default: everyone selected
        }
    }

    /// Clear multi-day breakdown: how many of the selected days need a qual swap, which had a bridge,
    /// which didn't, and which are normal days handled by Find.
    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("^[\(qualGatedDays.count) of \(workingShifts.count) selected day](inflect: true) need a qual swap.")
                .font(.subheadline.weight(.semibold))
            if !solvedDays.isEmpty {
                Label("Options for: \(dayList(solvedDays.sorted()))", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(AppColor.success)
            }
            if !unsolvedQualDays.isEmpty {
                Label("No bridge found for: \(dayList(unsolvedQualDays))", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(AppColor.heat)
            }
            if !normalDays.isEmpty {
                Label("Normal days (trade in Find): \(dayList(normalDays))", systemImage: "arrow.left.arrow.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func selectableRow(_ pkg: TradePackage) -> some View {
        let on = selected.contains(pkg.id)
        return Button {
            if on { selected.remove(pkg.id) } else { selected.insert(pkg.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pkg.assignments.first?.name ?? "Taker").font(.subheadline.bold())
                    if let leg = pkg.qualSwap {
                        Text("desk \(leg.giveDesk) (\(leg.giveQual)) · ^[\(leg.candidates.count) bridge](inflect: true)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(.bar, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Color.accentColor : .clear, lineWidth: 1.5))
            .padding(.horizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var broadcastBar: some View {
        HStack {
            Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { onBroadcast(selectedPkgs) } label: {
                Label("Broadcast", systemImage: "megaphone.fill").font(.subheadline.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
        }
        .padding()
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Q2: the multi-select "who to ask" blast picker. Lists every dispatcher who could
/// qual-swap onto the give-desk; the user selects which to blast (default = all).
struct QualSwapPickerSheet: View {
    let giveDeskLabel: String
    let takerName: String
    let dayLabel: String
    let candidates: [QualSwapCandidate]
    let onSend: (Set<String>) -> Void
    @State private var selected: Set<String>
    @Environment(\.dismiss) private var dismiss

    init(giveDeskLabel: String, takerName: String, dayLabel: String,
         candidates: [QualSwapCandidate], onSend: @escaping (Set<String>) -> Void) {
        self.giveDeskLabel = giveDeskLabel; self.takerName = takerName; self.dayLabel = dayLabel
        self.candidates = candidates; self.onSend = onSend
        _selected = State(initialValue: Set(candidates.map(\.workerID)))   // default: ask everyone eligible
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(takerName) can't work \(giveDeskLabel) on \(dayLabel). These dispatchers are working that day and could **qual-swap** onto it, freeing their desk for \(takerName). Pick who to ask — the first 5 to accept can respond.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Who to ask (\(selected.count)/\(candidates.count))") {
                    ForEach(candidates) { c in
                        Button {
                            if selected.contains(c.workerID) { selected.remove(c.workerID) }
                            else { selected.insert(c.workerID) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text("frees desk \(c.desk) (\(c.qual))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selected.contains(c.workerID) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(c.workerID) ? AppColor.success : .secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Request qual swap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { onSend(selected) }.disabled(selected.isEmpty)
                }
            }
        }
    }
}

/// The key under the trade calendars — now the shared comprehensive, collapsed-by-default
/// color key. (In the calendars themselves: border = trades away, fill = takes, each in that
/// person's own color — spelled out inside the legend.)
struct MiniScheduleLegend: View {
    var body: some View { CollapsibleLegend() }
}

/// A full-width Sunday-first month grid with large day cells (day# over shift+desk).
/// One color per side (you = blue, the counterparty = red), one cue per direction:
/// a day you GIVE = own-color BORDER, a day you GET = own-color FILL. So on your
/// (blue) calendar a give is blue-bordered and a pickup is blue-filled; on their
/// (red) calendar their give is red-bordered and their pickup is red-filled. Intent
/// is a thin bar along the bottom; today is a blue circle.
struct MiniScheduleGrid: View {
    let title: String
    let days: [String: String]           // ISO → "AM 82" label ("" = off)
    let month: Date
    var accent: Color = AppColor.primary            // THIS calendar owner's signature color (You=blue, peer=red)
    var giveDays: Set<String> = []       // owner GIVES these away → own-color border
    var takeDays: Set<String> = []       // owner RECEIVES these → own-color fill
    var loopDays: Set<String> = []       // circular handoff between OTHERS → violet fill+border
    var focusDay: String? = nil          // the selected step's day → bold focus ring
    var gold: Set<String> = []           // mutually-wanted → gold border
    var intent: (String) -> (label: String, color: Color)? = { _ in nil }   // the day's intent (name + color), shown in the popover
    var topology: (String) -> DayTopology = { _ in .standard } // high-impact / personal-day circle
    var eventName: (String) -> String? = { _ in nil }          // popover text when a marked day is tapped
    var fill: Bool = false               // stretch rows to fill the container's height (scale-to-fit on iPad)

    /// The tapped day, driving ONE grid-level popover (per-cell popovers inside a paging TabView are
    /// unstable and were dismissing the sheet). Identifiable so `.popover(item:)` stays put until closed.
    struct PopDay: Identifiable { let id: String }
    @State private var popDay: PopDay?

    private let cal = Calendar.current
    private let blue = AppColor.primary
    private let goldBorder = AppColor.pending
    private static let headers = ["Su", "M", "T", "W", "Th", "F", "Sa"]
    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// The Sunday on or before the 1st of the month.
    private var gridStart: Date {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let wd = cal.component(.weekday, from: first)   // 1 = Sun
        return cal.date(byAdding: .day, value: -(wd - 1), to: first) ?? first
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.headline).foregroundStyle(accent).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(Self.headers, id: \.self) { h in
                    Text(h).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<6, id: \.self) { w in
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { c in
                        cell(dayOffset: w * 7 + c)
                    }
                }
                .frame(maxHeight: fill ? .infinity : nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil)
        // Scale with Dynamic Type, but cap it so the fixed-size day cells don't overflow.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        // ONE sheet for the whole grid, driven by the tapped day. A sheet (not a per-cell popover)
        // presents at the window level, so the paging TabView can't dismiss it — it stays until closed.
        .sheet(item: $popDay) { day in dayDetailPopover(key: day.id) }
    }

    private func cell(dayOffset: Int) -> some View {
        let date    = cal.date(byAdding: .day, value: dayOffset, to: gridStart) ?? gridStart
        let key     = Self.isoF.string(from: date)
        let label   = days[key] ?? ""
        let working = !label.isEmpty
        let inMonth = cal.isDate(date, equalTo: month, toGranularity: .month)
        let isToday = cal.isDateInToday(date)
        let filled  = takeDays.contains(key) || loopDays.contains(key)   // solid fill → white text reads

        // Decluttered cell (UX): only the swap-critical signals inline — big date, big shift label, and
        // the trade role via fill/border. Intent, holiday/personal, and mutual-gold move to the tap
        // popover so nothing overlaps and the text stays large. Every day is tappable.
        // No fixed row/label heights and no content clip — both texts scale to whatever height the
        // row gets, so nothing is ever cut. The rounded FILL is applied via `background(in:)` (which
        // clips only the fill, never the text). This is the permanent fix for the label clipping.
        return VStack(spacing: 1) {
            Text("\(cal.component(.day, from: date))")
                .font(.headline).fontWeight(isToday ? .black : .semibold)
                .foregroundStyle(filled ? .white : (isToday ? blue : .primary))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label.isEmpty ? " " : label)
                .font(.footnote.weight(.heavy))
                .foregroundStyle(filled ? .white : (working ? accent : .secondary))
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, minHeight: fill ? 30 : 50, maxHeight: fill ? .infinity : nil)
        .padding(.vertical, 2)
        .background(background(key: key, working: working), in: RoundedRectangle(cornerRadius: 7))
        .overlay { border(key: key) }
        // Small intent dot (top-trailing) so the intent COLOR reads at a glance without cluttering the
        // cell; the named intent (Want to trade / Blackout / Want to work …) is in the tap popover.
        .overlay(alignment: .topTrailing) {
            if let info = intent(key) {
                Circle().fill(info.color).frame(width: 7, height: 7)
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 0.5))
                    .padding(2)
            }
        }
        .opacity(inMonth ? 1 : 0.18)
        .contentShape(Rectangle())
        .onTapGesture { popDay = PopDay(id: key) }   // any day → the single grid popover
    }

    private func background(key: String, working: Bool) -> Color {
        if loopDays.contains(key) { return BrickPalette.loopTrade.opacity(0.5) }  // 3rd-party handoff
        if takeDays.contains(key) { return accent.opacity(0.5) }    // owner receives → own-color fill
        return working ? accent.opacity(0.16) : Color(.systemGray5)
    }

    private static let popoverDateF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f
    }()

    /// Full detail for a tapped day — concrete facts, no filler: the date, the shift broken into type +
    /// desk, and what happens to it in THIS trade as a directional tag (with the calendar owner's name).
    @ViewBuilder private func dayDetailPopover(key: String) -> some View {
        let date    = Self.isoF.date(from: key) ?? month
        let label   = days[key] ?? ""
        let working = !label.isEmpty
        let parts = label.split(separator: " ").map(String.init)
        let shiftType = parts.first ?? ""
        let deskNo    = parts.count > 1 ? parts[1...].joined(separator: " ") : ""
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.popoverDateF.string(from: date)).font(.headline)

            // The shift, spelled out. "AM shift · Desk 32" reads better than the compact "AM 32".
            if working {
                HStack(spacing: 8) {
                    Image(systemName: "clock.fill").foregroundStyle(accent)
                    Text(shiftType.isEmpty ? "Working" : "\(shiftType) shift").font(.subheadline.weight(.bold))
                    if !deskNo.isEmpty {
                        Text("· Desk \(deskNo)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("Off", systemImage: "moon.zzz.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }

            // What happens to it in this trade — a bold directional chip naming the owner (grammar
            // agrees whether the owner is "You" or a named peer).
            let isYou = title == "You"
            if takeDays.contains(key) {
                tradeTag(isYou ? "You pick this up" : "\(title) picks this up", "arrow.down.circle.fill", accent)
            } else if giveDays.contains(key) {
                tradeTag(isYou ? "You give this away" : "\(title) gives this away", "arrow.up.circle.fill", accent)
            } else if loopDays.contains(key) {
                tradeTag("Loop handoff", "arrow.triangle.2.circlepath", BrickPalette.loopTrade)
            }
            if gold.contains(key) { tradeTag("Both sides want this", "flame.fill", goldBorder) }

            // The day's marked intent, named (Want to trade / Blackout / Want to work …) in its color.
            if let info = intent(key) { tradeTag(info.label, "paintpalette.fill", info.color) }

            // Only surface a holiday / personal day if it actually applies (concrete, not "marked").
            switch topology(key) {
            case .highDemand:
                tradeTag(eventName(key) ?? "High-impact day", "exclamationmark.circle.fill", BrickPalette.highImpact)
            case .personalMilestone:
                tradeTag(eventName(key) ?? "Personal day", "star.circle.fill", BrickPalette.personalDay)
            case .standard:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
    private func tradeTag(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.bold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    @ViewBuilder private func border(key: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        // Focus (selected step) wins — a bold high-contrast ring on top of any fill.
        if focusDay == key { shape.stroke(.primary, lineWidth: 3.5) }
        else if loopDays.contains(key) { shape.stroke(BrickPalette.loopTrade, lineWidth: 3) }
        else if giveDays.contains(key) { shape.stroke(accent, lineWidth: 3) }
    }
}

/// One small box per day you're trading away: the day-of-month over your shift
/// letter, solid green when this candidate can cover it, faint grey when not.
struct CoverageStrip: View {
    let shifts: [Shift]
    let covered: Set<String>

    private let coverGreen = AppColor.success
    private static let dayF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d"; return f }()

    var body: some View {
        // Single row; cap at 10 boxes, then a "+N" so it never overflows.
        let sorted = shifts.sorted { $0.date < $1.date }
        let shown = Array(sorted.prefix(10))
        let extra = sorted.count - shown.count
        HStack(spacing: 2) {
            ForEach(shown) { s in
                let isCovered = covered.contains(s.id)
                VStack(spacing: 1) {
                    Text(Self.dayF.string(from: s.date))
                        .font(.system(size: 11, weight: .bold))
                    Text(s.shiftLetter.isEmpty ? "·" : s.shiftLetter)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(isCovered ? .white : .secondary)
                .frame(width: 18)
                .padding(.vertical, 3)
                .background(isCovered ? coverGreen : Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 22).padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

/// Tiny ±4-day schedule snapshot: weekday letters over shift-type letters,
/// the covered day highlighted yellow, off days blank.
struct MiniSchedule: View {
    let week: [DayCell]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                VStack(spacing: 1) {
                    Text(cell.weekday)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(cell.letter.isEmpty ? " " : cell.letter)
                        .font(.system(size: 13, weight: .bold))
                }
                .frame(width: 18)
                .padding(.vertical, 1)
                .background(cell.isTarget ? AppColor.pending.opacity(0.85) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

// MARK: - CaseIterable for ForEach

extension ShiftAvailabilityType: Identifiable {
    public var id: String { rawValue }
}

// MARK: - ECB Accounting (B6-ECB)

/// The ECB bookkeeping register: a balance derived from dated line items, opened from the top-bar ⋯ menu.
struct ECBAccountingView: View {
    private var store = ECBAccountingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var editing: ECBEntry?
    @State private var capBlocked = false
    private var myID: String { SettingsManager.shared.username }

    var body: some View {
        NavigationStack {
            List {
                Section { balanceHeader }
                if !store.pendingConfirmations.isEmpty {
                    Section {
                        Label("^[\(store.pendingConfirmations.count) shared trade](inflect: true) awaiting confirmation — respond in your Inbox.",
                              systemImage: "clock.badge.questionmark")
                            .font(.caption).foregroundStyle(AppColor.pending)
                    }
                }
                if store.register.isEmpty {
                    Section {
                        ContentUnavailableView("No ECB activity yet", systemImage: "banknote",
                            description: Text("Tap + to log overtime, holiday pay, a withdrawal, or a trade with another dispatcher."))
                    }
                } else {
                    Section("Register") {
                        ForEach(store.register) { e in
                            row(e)
                                .contentShape(Rectangle())
                                .onTapGesture { editing = e }
                                .swipeActions(edge: .leading) {
                                    // Mark a scheduled (agreed, un-posted) line as cleared/received.
                                    if e.isAgreed && !e.cleared {
                                        Button {
                                            if !store.markCleared(id: e.id) { capBlocked = true }
                                        } label: { Label(e.isShared ? "Received" : "Cleared", systemImage: "checkmark.circle") }
                                        .tint(AppColor.success)
                                    } else if e.cleared {
                                        Button { store.markCleared(id: e.id, false) } label: {
                                            Label("Un-clear", systemImage: "arrow.uturn.backward")
                                        }.tint(.secondary)
                                    }
                                }
                        }
                        .onDelete { idx in
                            let items = store.register
                            idx.map { items[$0].id }.forEach { store.delete(id: $0) }
                        }
                    }
                }
            }
            .navigationTitle("ECB Accounting")
            .navigationBarTitleDisplayMode(.inline)
            // Pull the latest ledger (personal blob + shared lines) each time the page opens, so a
            // change made on another device shows without relaunching.
            .task { await store.syncOnLaunch() }
            .refreshable { await store.syncOnLaunch() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add line item")
                }
            }
            .sheet(isPresented: $showAdd) { ECBAddSheet().magnifiable() }
            .sheet(item: $editing) { ECBAddSheet(editing: $0).magnifiable() }
            .alert("Over the 144 cap", isPresented: $capBlocked) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Clearing this would push your available ECB over 144. Add a withdrawal first, then clear it.")
            }
        }
    }

    private var balanceHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Left: the two headline numbers (Available now + Projected). Right: a smaller card with
            // Owe / Owed stacked vertically — same row, visually secondary to the big balances.
            HStack(alignment: .top, spacing: 16) {
                HStack(alignment: .top, spacing: 20) {
                    bigStat("Available now", store.available, store.available < 0 ? AppColor.danger : AppColor.success,
                            caption: "/ \(ecbText(ECBAccounting.maxBalance)) max")
                    bigStat("Projected", store.projected, .primary,
                            caption: "once scheduled + IOUs clear")
                }
                Spacer(minLength: 8)
                // Owe / Owed card — ALWAYS shown so your position is visible; counts every uncleared
                // shared line by side, incl. awaiting-confirm ones (matches the register).
                VStack(alignment: .leading, spacing: 8) {
                    midStat("You owe", outstandingOwe, AppColor.danger)
                    midStat("Owed to you", outstandingOwed, AppColor.success)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            if pendingCount > 0 {
                Text("^[\(pendingCount) line](inflect: true) still awaiting confirmation — counts once confirmed and cleared.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if store.available >= ECBAccounting.maxBalance - 0.0001 {
                Label("At the 144 cap — withdraw before clearing more.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(AppColor.pending)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bigStat(_ label: String, _ value: Double, _ color: Color, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(ecbText(value)).font(.system(size: 32, weight: .bold).monospacedDigit()).foregroundStyle(color)
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
    }
    private func midStat(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(ecbText(value)).font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(color)
        }
    }

    /// Every uncleared shared line where I'm the payer (I'll pay ECB), incl. awaiting-confirm.
    private var outstandingOwe: Double {
        store.entries.filter { $0.isShared && !$0.cleared && $0.payerID == myID }
            .reduce(0) { $0 + abs($1.amount) }
    }
    /// Every uncleared shared line where I'm the payee (they'll pay me), incl. awaiting-confirm.
    private var outstandingOwed: Double {
        store.entries.filter { $0.isShared && !$0.cleared && $0.payeeID == myID }
            .reduce(0) { $0 + abs($1.amount) }
    }
    /// Shared lines not yet confirmed by the counterparty.
    private var pendingCount: Int {
        store.entries.filter { $0.isShared && $0.state != .confirmed }.count
    }

    @ViewBuilder private func row(_ e: ECBEntry) -> some View {
        let signed = ECBAccounting.signedAmount(for: myID, e)
        let pending = e.isShared && e.state != .confirmed
        HStack(spacing: 10) {
            Image(systemName: e.category.symbol)
                .foregroundStyle(signed < 0 ? AppColor.danger : AppColor.success)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.isShared ? "Trade · \(e.counterpartyName(myID: myID) ?? "dispatcher")" : e.category.label)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle(e)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(signed >= 0 ? "+" : "−")\(ecbText(abs(signed)))")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(signed < 0 ? AppColor.danger : AppColor.success)
                statusChip(e)
            }
        }
        .opacity(pending ? 0.6 : 1)
    }

    /// Right-aligned status under the amount: confirmation state first, else cleared vs scheduled.
    @ViewBuilder private func statusChip(_ e: ECBEntry) -> some View {
        if e.isShared && e.state == .pendingIncoming {
            Text("Confirm in Inbox").font(.caption2).foregroundStyle(AppColor.pending)
        } else if e.isShared && e.state == .pendingOutgoing {
            Text("Awaiting confirm").font(.caption2).foregroundStyle(AppColor.pending)
        } else if !e.cleared {
            Text(e.isShared ? "Scheduled · swipe to receive" : "Scheduled · swipe to clear")
                .font(.caption2).foregroundStyle(AppColor.pending)
        } else {
            Label("Cleared", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly).font(.caption2).foregroundStyle(AppColor.success)
        }
    }

    private func subtitle(_ e: ECBEntry) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"
        let date = f.string(from: e.date)
        return e.memo.isEmpty ? date : "\(date) · \(e.memo)"
    }
}

/// Add / edit an ECB line. Segmented type: Add · Subtract · Trade · Set balance.
struct ECBAddSheet: View {
    var editing: ECBEntry? = nil
    private var store = ECBAccountingStore.shared
    @Environment(\.dismiss) private var dismiss
    private var myID: String { SettingsManager.shared.username }

    enum Mode: String, CaseIterable, Identifiable { case add = "Add", subtract = "Subtract", trade = "Trade", setBalance = "Set balance"; var id: String { rawValue } }
    @State private var mode: Mode = .add
    @State private var creditCat: ECBCategory = .overtime
    @State private var debitCat: ECBCategory = .withdrawal
    @State private var amount: Double = 1
    @State private var memo = ""
    @State private var target: Double = 0
    @State private var payDate = Date()         // effective / pay date this line posts
    @State private var alreadyPosted = false    // add/subtract that already hit the balance → cleared now
    @State private var overCapacity = false     // IOU/trade exceeds what I can promise
    // Trade
    @State private var dispatchers: [(id: String, name: String)] = []
    @State private var counterpartyID = ""
    @State private var iPaid = true

    init(editing: ECBEntry? = nil) { self.editing = editing }

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil {
                    Picker("Type", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
                switch mode {
                case .add:
                    Picker("Category", selection: $creditCat) {
                        ForEach(ECBCategory.creditCases) { Text($0.label).tag($0) }
                    }
                    amountStepper
                    // Preset OT rates — prefill the standard ECB values (payroll conversions).
                    HStack(spacing: 8) {
                        Button("1.5× OT · 13.04") { creditCat = .overtime; amount = 13.04 }
                        Button("2× OT · 17.39") { creditCat = .overtime; amount = 17.39 }
                        Spacer()
                    }
                    .buttonStyle(.bordered).controlSize(.small).font(.caption)
                    payDateRow
                    memoField
                case .subtract:
                    Picker("Category", selection: $debitCat) {
                        ForEach(ECBCategory.debitCases) { Text($0.label).tag($0) }
                    }
                    amountStepper
                    payDateRow
                    memoField
                case .trade:
                    Picker("Dispatcher", selection: $counterpartyID) {
                        Text("Select…").tag("")
                        ForEach(dispatchers, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("Direction", selection: $iPaid) {
                        Text("I paid them").tag(true)
                        Text("They paid me").tag(false)
                    }.pickerStyle(.segmented)
                    amountStepper
                    DatePicker("Arrives / pay date", selection: $payDate, displayedComponents: .date)
                    memoField
                    if iPaid {
                        if store.payableCapacity <= 0.0001 {
                            Text("You have no ECB to trade yet — log a cleared balance or a scheduled deposit (OT / Holiday) first. You can only promise what you have or will have.")
                                .font(.caption).foregroundStyle(AppColor.pending)
                        } else {
                            Text("You can trade up to \(ecbText(store.payableCapacity)) ECB — your cleared balance plus scheduled deposits. Anything beyond your cleared balance is an IOU that settles when your deposit lands.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .setBalance:
                    HStack {
                        Text("Available now")
                        Spacer()
                        TextField("0", value: $target, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .monospacedDigit().frame(maxWidth: 120)
                    }
                    Text("Adds a dated Adjustment (cleared) line so your available balance equals the sum of your entries.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(editing == nil ? "Add ECB line" : (editing!.isShared ? "Edit trade line" : "Edit line"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { if save() { dismiss() } }.disabled(!canSave) }
            }
            .alert("Not enough ECB to promise", isPresented: $overCapacity) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You can only trade/IOU up to \(ecbText(store.payableCapacity)) ECB — your cleared balance plus scheduled deposits. Log the deposit first, or lower the amount.")
            }
            .task { await loadDispatchers(); preload() }
        }
    }

    /// Pay/effective date + an "already posted" shortcut for add/subtract lines.
    private var payDateRow: some View {
        Group {
            DatePicker("Pay date", selection: $payDate, displayedComponents: .date)
            Toggle("Already posted (counts now)", isOn: $alreadyPosted)
        }
    }

    /// Free decimal amount entry (ECB isn't restricted to 0.5 increments).
    private var amountStepper: some View {
        HStack {
            Text("ECB")
            Spacer()
            TextField("0", value: $amount, format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .monospacedDigit().frame(maxWidth: 120)
        }
    }
    private var memoField: some View {
        TextField("Note (optional)", text: $memo).font(.subheadline)
    }
    private var canSave: Bool {
        switch mode {
        case .trade: return !counterpartyID.isEmpty && amount > 0
        case .setBalance: return true
        default: return amount > 0
        }
    }

    private func preload() {
        guard let e = editing else { return }
        memo = e.memo; amount = abs(e.amount == 0 ? 1 : e.amount)
        payDate = e.date; alreadyPosted = e.cleared
        if e.isShared {
            mode = .trade
            counterpartyID = e.counterpartyID(myID: myID) ?? ""
            iPaid = e.payerID == myID
        } else if let credit = e.category.isCredit {
            mode = credit ? .add : .subtract
            if credit { creditCat = e.category } else { debitCat = e.category }
        }
    }

    /// Returns true on success. Trade/IOU over `payableCapacity` fails (keeps the sheet open + alerts).
    private func save() -> Bool {
        if let e = editing {
            if e.isShared {
                store.proposeSharedEdit(id: e.id, magnitude: amount, iPaid: iPaid, memo: memo, date: payDate)
            } else {
                store.editPersonal(id: e.id, magnitude: amount, memo: memo, date: payDate)
            }
            return true
        }
        switch mode {
        case .add:      store.addPersonal(category: creditCat, magnitude: amount, memo: memo, date: payDate, cleared: alreadyPosted)
        case .subtract: store.addPersonal(category: debitCat, magnitude: amount, memo: memo, date: payDate, cleared: alreadyPosted)
        case .setBalance: store.setBalance(to: target, date: Date())
        case .trade:
            let name = dispatchers.first { $0.id == counterpartyID }?.name ?? counterpartyID
            if !store.addTradeLine(counterpartyID: counterpartyID, counterpartyName: name,
                                   magnitude: amount, iPaid: iPaid, memo: memo, date: payDate) {
                overCapacity = true
                return false
            }
        }
        return true
    }

    private func loadDispatchers() async {
        if !TradeFeedCache.shared.allDispatchers.isEmpty { dispatchers = TradeFeedCache.shared.allDispatchers; return }
        let now = Date(); let end = Calendar.current.date(byAdding: .month, value: 12, to: now) ?? now
        let entries = await RosterStore.shared.entries(from: now, to: end)
        var seen = Set<String>(); var out: [(id: String, name: String)] = []
        for e in entries where e.workerID != myID && seen.insert(e.workerID).inserted {
            out.append((e.workerID, TradeNames.resolved(displayName: nil, rosterName: e.workerName, workerID: e.workerID)))
        }
        dispatchers = out.sorted { $0.name < $1.name }
        TradeFeedCache.shared.allDispatchers = dispatchers
    }
}

```


## `Sources/UI/Messaging/MessagingViews.swift`

```swift
// MessagingViews.swift
// The in-app trade Inbox (1:1 requests + replies) and the Broadcast Channel
// (self-maintaining feed). Both presented as sheets from the side dock.

import SwiftUI
import PhotosUI

// MARK: - Formatting helpers

enum DayFmt {
    static let iso: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static let pretty: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f }()
    static func nice(_ isoDay: String) -> String {
        guard let d = iso.date(from: isoDay) else { return isoDay }
        return pretty.string(from: d)
    }
    static func list(_ ids: [String]) -> String {
        ids.sorted().map(nice).joined(separator: ", ")
    }
}

struct StatusBadge: View {
    let status: TradeRequestStatus
    var body: some View {
        Text(status.label)
            .font(.caption2.bold())
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
    private var color: Color {
        switch status {
        case .pending:   return AppColor.pending
        case .accepted:  return AppColor.success
        case .declined:  return AppColor.danger
        case .countered: return AppColor.primary
        case .cancelled: return AppColor.neutral
        case .message:   return .secondary
        }
    }
}

extension TradeRequestStatus {
    var icon: String {
        switch self {
        case .pending:   return "hourglass"
        case .accepted:  return "checkmark.circle.fill"
        case .declined:  return "xmark.circle.fill"
        case .countered: return "arrow.uturn.left.circle.fill"
        case .cancelled: return "slash.circle"
        case .message:   return "bubble.left.fill"
        }
    }
    var tint: Color {
        switch self {
        case .pending:   return AppColor.pending
        case .accepted:  return AppColor.success
        case .declined:  return AppColor.danger
        case .countered: return AppColor.primary
        case .cancelled: return AppColor.neutral
        case .message:   return .secondary
        }
    }
}

/// Renders message text as Markdown so **bold**, *italic*, and ~~strike~~ work — and highlights
/// @mentions (@everyone + any active dispatcher's name) in the accent color.
func mdText(_ s: String) -> Text {
    guard var a = try? AttributedString(markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return Text(s) }
    Mentions.highlight(&a, names: Mentions.channelNames())
    return Text(a)
}

/// @mention support for the channel + chat. Names can contain spaces/commas ("Lee, Ervin"), so mentions
/// are inserted via a picker (not fragile inline parsing) and matched for highlighting against the known
/// set of active-dispatcher names + "everyone". Pure + testable.
enum Mentions {
    /// The mention-able names: "everyone" + every ACTIVE (published-profile) dispatcher's resolved name.
    static func channelNames() -> [String] {
        ["everyone"] + TradeProfileStore.shared.others.keys.map { participantName($0) }
    }

    /// Insert "@name " into `text`, adding a separating space only when needed.
    static func insert(_ name: String, into text: String) -> String {
        let sep = (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n")) ? "" : " "
        return text + sep + "@\(name) "
    }

    /// The set of names actually @-mentioned in `text` (matched against the known name list, "everyone"
    /// first, longest-first so "Lee, Ervin" wins over a shorter partial). Drives highlighting + (future) push.
    static func mentioned(in text: String, names: [String]) -> Set<String> {
        var found: Set<String> = []
        for name in names.sorted(by: { $0.count > $1.count }) where text.contains("@\(name)") {
            found.insert(name)
        }
        return found
    }

    /// Resolve the @-mentions in `text` to the worker IDs of the active dispatchers named. "@everyone" is
    /// ignored here — every dispatcher already gets the blanket "new channel post" push, so a per-user
    /// mention push is only needed for specifically-named people. Pure (reads the published-profile roster).
    static func mentionedIDs(in text: String) -> [String] {
        let hits = mentioned(in: text, names: channelNames())
        guard !hits.isEmpty else { return [] }
        var ids: Set<String> = []
        for id in TradeProfileStore.shared.others.keys where hits.contains(participantName(id)) {
            ids.insert(id)
        }
        return Array(ids)
    }

    /// Color every "@name" run in `attr` with the accent, longest names first so a full name isn't
    /// clipped by a shorter partial match.
    static func highlight(_ attr: inout AttributedString, names: [String]) {
        for name in names.sorted(by: { $0.count > $1.count }) {
            let token = "@\(name)"
            var cursor = attr.startIndex
            while cursor < attr.endIndex, let r = attr[cursor...].range(of: token) {
                attr[r].foregroundColor = AppColor.primary
                attr[r].inlinePresentationIntent = .stronglyEmphasized
                cursor = r.upperBound
            }
        }
    }
}

/// Wraps the whole draft in a Markdown marker (used by the format buttons).
func mdWrap(_ text: Binding<String>, _ marker: String) {
    let s = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return }
    text.wrappedValue = "\(marker)\(s)\(marker)"
}

/// Call / Text / Email buttons for a dispatcher, from their published profile.
struct ContactButtons: View {
    let profile: TradeProfile

    private var phoneDigits: String? {
        guard let p = profile.phone?.filter({ $0.isNumber || $0 == "+" }), !p.isEmpty else { return nil }
        return p
    }

    var body: some View {
        HStack(spacing: 18) {
            if let p = phoneDigits {
                contact("Call", "phone.fill", "tel:\(p)")
                contact("Text", "message.fill", "sms:\(p)")
            }
            if let e = profile.bestEmail {
                contact("Email", "envelope.fill", "mailto:\(e)")
            }
        }
        .font(.caption)
    }

    private func contact(_ title: String, _ icon: String, _ urlString: String) -> some View {
        Button {
            if let url = URL(string: urlString) { UIApplication.shared.open(url) }
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.borderless)
    }
}

/// B / I / S buttons that wrap the entire draft.
struct FormatBar: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 16) {
            Button { mdWrap($text, "**") } label: { Image(systemName: "bold") }
            Button { mdWrap($text, "*") }  label: { Image(systemName: "italic") }
            Button { mdWrap($text, "~~") } label: { Image(systemName: "strikethrough") }
        }
        .buttonStyle(.borderless).font(.subheadline).foregroundStyle(.secondary)
    }
}

// MARK: - Inbox

struct InboxView: View {
    private var store = MessagingStore.shared
    private var ecb = ECBAccountingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var filter = 0   // 0 Intents · 1 Search · 2 ECB · 3 Misc

    private var myID: String { SettingsManager.shared.username }

    /// Incoming one-way ECB offers, sorted by most ECB offered.
    private var ecbRequests: [TradeRequest] {
        store.requests.filter { $0.isECB }.sorted { ($0.ecbAmount ?? 0) > ($1.ecbAmount ?? 0) }
    }

    /// Which tab a request files under (0 Intents · 1 Search · 2 ECB · 3 Misc). A request where I'm
    /// neither sender nor recipient (a qual-swap bridge blast) always lands in Misc.
    private func tabIndex(for r: TradeRequest) -> Int {
        if r.isECB { return 2 }
        guard r.fromID == myID || r.toID == myID else { return 3 }   // bridge / not a core party
        switch r.inboxOrigin {
        case .intents: return 0
        case .search:  return 1
        case .ecb:     return 2
        case .manual:  return 3
        }
    }
    private func inTab(_ r: TradeRequest) -> Bool { tabIndex(for: r) == filter }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $filter) {
                    Text("Intents").tag(0)
                    Text("Search").tag(1)
                    Text("ECB (\(ecbRequests.count))").tag(2)
                    Text("Misc").tag(3)
                }
                .pickerStyle(.segmented).padding()

                if filter == 2 { ecbTab } else { requestList }
            }
            .navigationTitle("Trade Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.refresh(); await TradeProfileStore.shared.refreshOthers(); await ecb.syncOnLaunch() }   // load peers so status renders (A7/B8 / audit #7) + ECB confirmations
            .refreshable { await store.refresh(); await TradeProfileStore.shared.refreshOthers(); await ecb.syncOnLaunch() }
        }
    }

    /// ECB tab: outgoing offers as tappable folders, incoming offers, and ledger-line confirmations.
    @ViewBuilder private var ecbTab: some View {
        let incomingECB = store.incoming.filter { $0.isECB }.sorted { ($0.ecbAmount ?? 0) > ($1.ecbAmount ?? 0) }
        if store.ecbOffers.isEmpty && incomingECB.isEmpty && ecb.pendingConfirmations.isEmpty {
            ContentUnavailableView("No ECB Offers", systemImage: "star.circle",
                description: Text("One-way ECB trade offers show here, sorted by most ECB offered."))
        } else {
            List {
                if !ecb.pendingConfirmations.isEmpty {
                    Section("ECB confirmations") { ForEach(ecb.pendingConfirmations) { ecbConfirmRow($0) } }
                }
                if !store.ecbOffers.isEmpty {
                    Section("Your ECB offers · tap to see who you sent it to") {
                        ForEach(store.ecbOffers, id: \.offerID) { offer in
                            NavigationLink { ECBOfferView(offerID: offer.offerID) } label: { ECBOfferRow(offer: offer) }
                        }
                    }
                }
                if !incomingECB.isEmpty {
                    Section("Offers to you · highest ECB first") { ForEach(incomingECB) { row($0) } }
                }
            }
        }
    }

    /// Intents / Search / Misc tabs: the usual sectioned request list, filtered to the active tab.
    @ViewBuilder private var requestList: some View {
        let arch = store.archivedRequestIDs
        let pending = MessagingStore.active(store.pendingIncoming, archived: arch).filter(inTab)
        let handledIncoming = MessagingStore.active(store.incoming, archived: arch)
            .filter { store.status(of: $0) != .pending && inTab($0) }
        let sent = MessagingStore.active(store.outgoing, archived: arch).filter(inTab)
        let archived = store.requests.filter { arch.contains($0.id) && inTab($0) }
        if pending.isEmpty && handledIncoming.isEmpty && sent.isEmpty && archived.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "tray", description: Text(emptyMessage))
        } else {
            List {
                if !pending.isEmpty { Section("Needs your reply") { ForEach(pending) { row($0) } } }
                if !handledIncoming.isEmpty { Section("Incoming") { ForEach(handledIncoming) { row($0) } } }
                if !sent.isEmpty { Section("Sent") { ForEach(sent) { row($0) } } }
                if !archived.isEmpty { Section("Archived") { ForEach(archived) { row($0) } } }
            }
        }
    }

    private var emptyTitle: String {
        switch filter { case 0: return "No Intent Trades"; case 1: return "No Search Trades"; default: return "Nothing Here" }
    }
    private var emptyMessage: String {
        switch filter {
        case 0:  return "Swaps you send or receive from the Intents feed show here."
        case 1:  return "Swaps from Trade Solutions searches show here."
        default: return "Qual-swap bridge requests and other messages show here."
        }
    }

    /// A shared ECB line the counterparty logged, awaiting my confirm. Confirm → posts on both ledgers.
    @ViewBuilder private func ecbConfirmRow(_ e: ECBEntry) -> some View {
        let iReceive = e.payeeID == myID
        let other = e.counterpartyName(myID: myID) ?? "A dispatcher"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "banknote").foregroundStyle(AppColor.pending)
                Text("\(other) logged an ECB trade")
                    .font(.subheadline.weight(.semibold))
            }
            Text("\(iReceive ? "You receive" : "You pay") \(ecbText(abs(e.amount))) ECB\(e.memo.isEmpty ? "" : " · \(e.memo)")")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { ecb.confirm(id: e.id) } label: {
                    Label("Confirm", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.small)
                Button(role: .destructive) { ecb.decline(id: e.id) } label: {
                    Label("Decline", systemImage: "xmark.circle").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func row(_ req: TradeRequest) -> some View {
        NavigationLink { ThreadView(request: req) } label: { RequestRow(request: req, myID: myID) }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { Task { await store.cancelRequest(req.id) } } label: {
                    Label("Delete", systemImage: "trash")   // gone forever
                }
                if store.archivedRequestIDs.contains(req.id) {
                    Button { store.unarchiveRequest(req.id) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }.tint(AppColor.primary)
                } else {
                    Button { store.archiveRequest(req.id) } label: { Label("Archive", systemImage: "archivebox") }.tint(AppColor.neutral)
                }
            }
    }
}

// MARK: - ECB offer (sender side: ordered acceptance queue)

struct ECBOfferRow: View {
    let offer: (offerID: String, requests: [TradeRequest])
    private var store = MessagingStore.shared

    var body: some View {
        let first = offer.requests.first
        let count = store.acceptCount(offerID: offer.offerID)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("\(ecbText(first?.ecbAmount ?? 0)) ECB", systemImage: "star.circle.fill")
                    .font(.subheadline.bold()).foregroundStyle(AppColor.pending)
                Spacer()
                Text("\(offer.requests.count) sent").font(.caption2).foregroundStyle(.secondary)
            }
            if let f = first, !f.giveDayIDs.isEmpty {
                Text("Shifts: " + DayFmt.list(f.giveDayIDs)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(count == 0 ? "No acceptances yet" : "^[\(count) accepted](inflect: true) · tap to confirm")
                .font(.caption.bold()).foregroundStyle(count > 0 ? AppColor.success : .secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Sender's view of one ECB broadcast: a table of shifts, each with a row of
/// numbered dots (the per-shift acceptance queue). Tap a dot to confirm or skip.
struct ECBOfferView: View {
    let offerID: String
    private var store = MessagingStore.shared
    private var history = TradeHistoryStore.shared
    @Environment(\.dismiss) private var dismiss

    private var siblings: [TradeRequest] { store.requests.filter { $0.offerID == offerID } }
    private var ecb: Double { siblings.first?.ecbAmount ?? 0 }
    private var days: [String] { store.ecbDays(offerID: offerID) }

    var body: some View {
        List {
            Section {
                LabeledContent("ECB offered") { Text(ecbText(ecb)).bold() }
            } footer: {
                Text("Each shift has its own line. Numbered dots are the people who accepted, in order — #1 is next. Tap a dot to confirm that person (then submit their ECB form), or skip them to pass it to the next person in line.")
            }
            Section("Sent to \(siblings.count) · tap a name to see their card") {
                ForEach(siblings) { recipientRow($0) }
            }
            Section("Shifts") {
                ForEach(days, id: \.self) { day in shiftRow(day) }
            }
        }
        .navigationTitle("ECB Offer")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One recipient you sent this offer to: name, their response so far, and a tap into the exact
    /// card they received (the 1:1 ECB thread).
    private func recipientRow(_ req: TradeRequest) -> some View {
        NavigationLink { ThreadView(request: req) } label: {
            HStack(spacing: 10) {
                Avatar(name: req.toName, id: req.toID, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(req.toName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(recipientStatusText(req)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(status: store.status(of: req))
            }
        }
    }
    private func recipientStatusText(_ req: TradeRequest) -> String {
        switch store.status(of: req) {
        case .accepted:  return "Accepted"
        case .declined:  return "Declined"
        case .countered: return "Replied"
        case .cancelled: return "Cancelled"
        default:         return "No response yet"
        }
    }

    private func shiftRow(_ day: String) -> some View {
        let queue = Array(store.ecbQueue(offerID: offerID, dayID: day).prefix(MessagingStore.ecbQueueCap))
        return HStack(spacing: 10) {
            Text(DayFmt.nice(day)).font(.subheadline.bold()).frame(width: 110, alignment: .leading)
            if queue.isEmpty {
                Text("no accepters").font(.caption).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(queue.enumerated()), id: \.element.id) { idx, r in
                        Menu {
                            Text("\(r.responderName) · Emp #\(r.responderID)")
                            Button { confirm(day: day, r: r) } label: { Label("Confirm — submit ECB form", systemImage: "checkmark.seal.fill") }
                        } label: {
                            Text("\(idx + 1)")
                                .font(.caption.bold()).foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(idx == 0 ? AppColor.success : AppColor.primary, in: Circle())
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func confirm(day: String, r: TradeResponse) {
        history.record(TradeHistoryEntry(
            summary: "ECB \(ecbText(ecb)) → \(r.responderName) (Emp #\(r.responderID)) for \(DayFmt.nice(day))",
            participants: [r.responderName], dayIDs: [day], completedAt: Date(),
            pending: true, ecb: Int(ecb.rounded()), employeeID: r.responderID))
        Task {
            if let req = siblings.first(where: { $0.toID == r.responderID }) {
                await store.respond(to: req, status: .accepted,
                    note: "ECB CONFIRMED for \(DayFmt.nice(day)) — submitting the \(ecbText(ecb))-ECB form. Confirm receipt in the app once you have it.")
            }
        }
    }
}

/// B5 image helper: downscale + JPEG-compress + base64 so a photo rides the message JSON payload
/// (stays well under CloudKit's ~1MB record limit). Pure-ish (UIKit image ops); decode is the inverse.
enum PostImage {
    static func encode(_ image: UIImage, maxDimension: CGFloat = 1024, quality: CGFloat = 0.5) -> String? {
        func data(_ dim: CGFloat, _ q: CGFloat) -> Data? { downscale(image, maxDimension: dim).jpegData(compressionQuality: q) }
        if let d = data(maxDimension, quality), d.count < 700_000 { return d.base64EncodedString() }
        if let d = data(768, 0.4), d.count < 700_000 { return d.base64EncodedString() }   // try harder once
        return nil   // too big even compressed → skip rather than blow the record limit
    }
    static func decode(_ base64: String) -> UIImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }
    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let m = max(image.size.width, image.size.height)
        guard m > maxDimension else { return image }
        let scale = maxDimension / m
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// Reusable emoji-reaction strip (B6): existing reactions as count chips + a quick-react menu.
/// `onTap(emoji)` toggles the caller's reaction. Used on channel replies and 1:1 chat messages.
struct ReactionChips: View {
    let reactions: [Reaction]
    let onTap: (String) -> Void
    private static let quick = ["👍", "❤️", "✅", "⚠️", "🔥", "🙏"]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Reaction.counts(reactions), id: \.emoji) { r in
                Button { onTap(r.emoji) } label: {
                    Text("\(r.emoji) \(r.count)").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }.buttonStyle(.plain)
            }
            Menu {
                ForEach(Self.quick, id: \.self) { e in Button(e) { onTap(e) } }
            } label: {
                Image(systemName: "face.smiling").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct RequestRow: View {
    let request: TradeRequest
    let myID: String
    private var store = MessagingStore.shared

    init(request: TradeRequest, myID: String) { self.request = request; self.myID = myID }

    var body: some View {
        let mine = request.fromID == myID            // I sent it
        let status = store.status(of: request)
        let needsMe = status == .pending && !mine     // action required from me
        let otherName = mine ? request.toName : request.fromName
        let otherID   = mine ? request.toID : request.fromID
        return HStack(alignment: .top, spacing: 12) {
            Avatar(name: otherName, id: otherID, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    NameWithStatus(id: otherID, name: otherName)
                    Spacer()
                    Text(request.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
                Text(mine ? "You proposed a swap" : "Proposed a swap with you")
                    .font(.caption).foregroundStyle(.secondary)
                if let chain = request.chain, !chain.isEmpty {
                    Label("\(tradeTypeLabel(distinctPeople: distinctParticipants(in: chain))) · tap to view", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.semibold)).foregroundStyle(AppColor.special)
                } else if !(request.giveDayIDs.isEmpty && request.takeDayIDs.isEmpty) {
                    // Your side of the deal, in the same give/get language as the cards.
                    TraderChips(name: "You", color: BrickPalette.mineScheme,
                                giveDays: mine ? request.giveDayIDs : request.takeDayIDs,
                                getDays: mine ? request.takeDayIDs : request.giveDayIDs,
                                maxChips: 3)
                }
                if !request.note.isEmpty {
                    mdText(request.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    StatusBadge(status: status)
                    // S-VALID: a traded day is no longer worked → this request is invalid.
                    if store.isInvalid(request) {
                        Label("Invalid", systemImage: "exclamationmark.octagon.fill")
                            .font(.caption2.bold()).foregroundStyle(BrickPalette.critical)
                    }
                    if let ecb = request.ecbAmount, request.isECB {
                        Label("\(ecbText(ecb)) ECB", systemImage: "star.circle.fill")
                            .font(.caption2.bold()).foregroundStyle(AppColor.pending)
                    }
                    // 🔥 the incoming request hits one of my own marked intents (U6).
                    if !mine, store.matchesMyIntents(request) {
                        Label("Matches your intent", systemImage: "flame.fill")
                            .font(.caption2.weight(.bold)).foregroundStyle(AppColor.heat)
                    }
                    if needsMe {
                        Label("Your move", systemImage: "exclamationmark.circle.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(AppColor.pending)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ThreadView: View {
    let request: TradeRequest
    private var store = MessagingStore.shared
    @State private var replyNote = ""
    @State private var chatDraft = ""
    @State private var ecbSelectedDays: Set<String> = []
    @State private var staleDays: Set<String> = []
    @State private var otherProfile: TradeProfile?
    @State private var editingMessage: TradeResponse?
    @State private var editMsgDraft = ""
    @State private var pickerItem: PhotosPickerItem?   // #28: photo attach on 1:1 chat
    @State private var pendingImage: UIImage?
    @State private var showCalendars = false           // 4100a: multi-person card → two-calendar view
    @Environment(\.dismiss) private var dismiss

    init(request: TradeRequest) { self.request = request }

    private var myID: String { SettingsManager.shared.username }
    private var isIncoming: Bool { request.toID == myID }
    private var status: TradeRequestStatus { store.status(of: request) }

    // The trade card, extracted so the List body stays inside the type-checker's budget.
    @ViewBuilder private var tradeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(cardKind, systemImage: cardIcon).font(.subheadline.bold())
                Spacer()
                StatusBadge(status: status)
            }
            Divider()
            if let chain = request.chain, !chain.isEmpty {
                TradeParticipantLines(rows: TradeParticipantLines.rows(chain: chain, myID: myID),
                                      orderedPeers: chain.map(\.fromID))
                Label("Tap to view everyone's calendars", systemImage: "calendar")
                    .font(.caption.weight(.semibold)).foregroundStyle(AppColor.primary)
            } else {
                TradeParticipantLines(rows: twoWayRows, orderedPeers: [request.fromID, request.toID])
            }
            if request.isECB, let ecb = request.ecbAmount {
                Label("\(ecbText(ecb)) ECB offered", systemImage: "star.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(AppColor.pending)
            }
            if !request.note.isEmpty { Text(request.note).font(.subheadline) }
        }
    }
    private var cardKind: String {
        let people = request.chain.map(distinctParticipants(in:)) ?? 2
        return tradeTypeLabel(distinctPeople: people, isOneWayECB: request.isECB)
    }
    private var cardIcon: String {
        request.chain != nil ? "arrow.triangle.2.circlepath" : (request.isECB ? "star.circle.fill" : "arrow.left.arrow.right")
    }
    private var twoWayRows: [(id: String, name: String, isMe: Bool, days: [String])] {
        var r: [(id: String, name: String, isMe: Bool, days: [String])] = [
            (id: request.fromID, name: request.fromID == myID ? "You" : request.fromName,
             isMe: request.fromID == myID, days: request.giveDayIDs)
        ]
        if !(request.takeDayIDs.isEmpty && request.giveDayIDs.isEmpty) {
            r.append((id: request.toID, name: request.toID == myID ? "You" : request.toName,
                      isMe: request.toID == myID, days: request.takeDayIDs))
        }
        return r
    }

    var body: some View {
        List {
            if !staleDays.isEmpty {
                Section {
                    Label("Action needed — \(DayFmt.list(Array(staleDays))) is no longer worked, so this trade is INVALID. Delete or archive it.",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.subheadline.weight(.bold)).foregroundStyle(BrickPalette.critical)
                        .listRowBackground(BrickPalette.critical.opacity(0.12))
                }
            }
            // The trade as a card — same language as the feed's package card.
            Section {
                tradeCard
                    .padding(DS.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { if request.chain?.isEmpty == false { showCalendars = true } }
            }
            .sheet(isPresented: $showCalendars) {
                if let chain = request.chain, !chain.isEmpty {
                    PackageDetailView(package: PackageDetailView.fromChain(chain), onPropose: {}, onExecute: {}, readOnly: true)
                        .magnifiable()
                }
            }

            qualSwapSection

            Section {
                Button { openDispatchDraft(subject: "", body: "") } label: {
                    Label("New email to dispatch DL", systemImage: "envelope")
                }
            } footer: {
                Text("Opens a blank new message in Outlook addressed to \(SettingsManager.shared.tradeEmailDL).")
            }

            if let p = otherProfile, (p.phone != nil || p.bestEmail != nil) {
                Section("Contact \(isIncoming ? request.fromName : request.toName)") {
                    ContactButtons(profile: p)
                }
            }

            Section("Conversation") {
                auditRow(icon: "paperplane.fill", tint: AppColor.primary,
                         who: request.fromName, what: "proposed this trade", when: request.createdAt,
                         note: request.note)
                ForEach(store.responses(for: request.id).sorted { $0.createdAt < $1.createdAt }) { r in
                    if r.statusValue == .message {
                        // Free-form chat — render as a message, not an audit event.
                        VStack(alignment: .leading, spacing: 4) {
                            SlackMessageRow(name: r.responderID == myID ? "You" : r.responderName,
                                            authorID: r.responderID, timestamp: r.createdAt,
                                            message: r.isDeleted ? "[Deleted]" : r.note,
                                            meta: r.editedAt != nil ? ("edited", .secondary) : nil,
                                            avatarSize: 26) {
                                if !r.isDeleted && r.responderID == myID {
                                    Button { editingMessage = r; editMsgDraft = r.note } label: {
                                        Image(systemName: "pencil").font(.caption2)
                                    }.buttonStyle(.borderless)
                                    Button(role: .destructive) { Task { await store.softDeleteMessage(r) } } label: {
                                        Image(systemName: "trash").font(.caption2)
                                    }.buttonStyle(.borderless)
                                }
                            }
                            if !r.isDeleted, let b64 = r.imageBase64, let ui = PostImage.decode(b64) {
                                ExpandableImage(image: ui, maxHeight: 180)   // B4-11: tap to zoom
                                    .padding(.leading, 34)
                            }
                            if !r.isDeleted {
                                ReactionChips(reactions: r.reactions ?? []) { e in Task { await store.react(to: r, emoji: e) } }
                                    .padding(.leading, 34)
                            }
                        }
                    } else {
                        auditRow(icon: r.statusValue.icon, tint: r.statusValue.tint,
                                 who: r.responderID == myID ? "You" : r.responderName,
                                 what: r.statusValue.label.lowercased(), when: r.createdAt, note: r.note)
                    }
                }
            }

            if isIncoming && status != .pending {
                Section {
                    Label("You replied: \(status.label)", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(status == .declined ? AppColor.danger : AppColor.success)
                }
            }

            // ECB queue position (recipient side) — per shift.
            if isIncoming, request.isECB, let offerID = request.offerID, !senderConfirmedECB {
                Section("Your queue position (per shift)") {
                    ForEach(request.giveDayIDs, id: \.self) { d in
                        HStack {
                            Text(DayFmt.nice(d)).font(.subheadline)
                            Spacer()
                            if let pos = store.myQueuePosition(offerID: offerID, dayID: d) {
                                Text("#\(pos)").font(.subheadline.bold())
                                    .foregroundStyle(pos <= MessagingStore.ecbQueueCap ? AppColor.success : AppColor.pending)
                            } else {
                                Text("not accepted").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // ECB receipt confirmation (recipient side): once the sender confirms
            // and submits the form, you confirm you received the ECB.
            if isIncoming, request.isECB, senderConfirmedECB {
                Section("ECB transfer") {
                    if receivedECB {
                        Label("You confirmed receipt of \(ecbText(request.ecbAmount ?? 0)) ECB.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(AppColor.success)
                    } else {
                        Text("\(request.fromName) is submitting the \(ecbText(request.ecbAmount ?? 0))-ECB form. Confirm once it lands in your account.")
                            .font(.subheadline)
                        Button { confirmReceived() } label: {
                            Label("Confirm ECB received", systemImage: "star.circle.fill")
                        }
                        .buttonStyle(.borderedProminent).tint(AppColor.pending)
                    }
                }
            }

            if isIncoming, request.isECB, status == .pending {
                Section("Accept shifts — \(ecbText(request.ecbAmount ?? 0)) ECB each") {
                    ForEach(request.giveDayIDs, id: \.self) { d in
                        Toggle(DayFmt.nice(d), isOn: Binding(
                            get: { ecbSelectedDays.contains(d) },
                            set: { on in if on { ecbSelectedDays.insert(d) } else { ecbSelectedDays.remove(d) } }))
                    }
                    Button { Task { await store.acceptECB(request, days: Array(ecbSelectedDays)); ecbSelectedDays = [] } } label: {
                        Label("Accept selected", systemImage: "checkmark.circle.fill")
                    }
                    .tint(AppColor.success).disabled(ecbSelectedDays.isEmpty)
                    Button(role: .destructive) { respond(.declined) } label: { Label("Decline all", systemImage: "xmark.circle") }
                }
            } else if isIncoming && status == .pending {
                Section("Respond") {
                    TextField("Optional note…", text: $replyNote, axis: .vertical)
                    Button { respond(.accepted) } label: { Label("Accept", systemImage: "checkmark.circle.fill") }
                        .tint(AppColor.success)
                        .disabled(!staleDays.isEmpty)   // can't accept an invalid swap
                    Button { respond(.countered) } label: { Label("Counter", systemImage: "arrow.uturn.left.circle") }
                    Button(role: .destructive) { respond(.declined) } label: { Label("Decline", systemImage: "xmark.circle") }
                }
            } else if !isIncoming && status == .pending {
                Section {
                    Button(role: .destructive) {
                        Task { await store.cancelRequest(request.id); dismiss() }
                    } label: { Label("Cancel request", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("Swap with \(isIncoming ? request.fromName : request.toName)")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Edit message", isPresented: Binding(get: { editingMessage != nil }, set: { if !$0 { editingMessage = nil } })) {
            TextField("Message", text: $editMsgDraft)
            Button("Save") { if let m = editingMessage { Task { await store.editMessage(m, newText: editMsgDraft) } }; editingMessage = nil }
            Button("Cancel", role: .cancel) { editingMessage = nil }
        }
        // Chat is always available — talk it out regardless of accept/decline state.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Photo", systemImage: "photo").font(.caption)
                    }
                    if let img = pendingImage {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 6))
                        Button { pendingImage = nil; pickerItem = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.top, 4)
                .onChange(of: pickerItem) { _, item in
                    guard let item else { return }
                    Task { if let data = try? await item.loadTransferable(type: Data.self) { pendingImage = UIImage(data: data) } }
                }
                SlackComposer(placeholder: "Message \(isIncoming ? request.fromName : request.toName)",
                              text: $chatDraft, showFormatBar: false,
                              canSendWhenEmpty: pendingImage != nil) {
                    let text = chatDraft; chatDraft = ""
                    let img = pendingImage; pendingImage = nil; pickerItem = nil
                    Task {
                        let b64 = img.flatMap { PostImage.encode($0) }
                        await store.postMessage(to: request, text: text, imageBase64: b64)
                    }
                }
            }
        }
        .task {
            staleDays = await TradeMatcher.staleDays(
                fromID: request.fromID, toID: request.toID,
                giveDayIDs: request.giveDayIDs, takeDayIDs: request.takeDayIDs)
            let otherID = isIncoming ? request.fromID : request.toID
            otherProfile = await TradeProfileStore.shared.fetchProfile(forWorker: otherID)
        }
    }

    /// Color indicator for a qual-swap leg status (Q3).
    private func qualSwapTint(_ s: QualSwapLegStatus) -> Color {
        switch s {
        case .waiting:                 return AppColor.pending
        case .offersOpen, .offersFull: return AppColor.primary
        case .finalized:               return AppColor.success
        case .invalid:                 return BrickPalette.critical
        }
    }

    /// Qual-swap leg (Q3/Q5/Q6): role-aware — bridge accepts, taker chooses/declines,
    /// everyone else sees the contingent status.
    @ViewBuilder private var qualSwapSection: some View {
        if let leg = request.qualSwap {
            let role = request.qualSwapRole(for: myID)
            Section {
                HStack {
                    Image(systemName: leg.status == .invalid ? "exclamationmark.octagon.fill" : "person.2.badge.gearshape.fill")
                        .foregroundStyle(qualSwapTint(leg.status))
                    Text(leg.statusText).font(.subheadline.weight(.semibold))
                }
                Text("Desk \(leg.giveDesk) needs qual \(leg.giveQual); \(leg.takerName) will take whichever desk a bridge frees up.")
                    .font(.caption).foregroundStyle(.secondary)

                // BRIDGE (C): accept / already-filled.
                if role == .bridge {
                    let iAccepted = leg.acceptances.contains { $0.workerID == myID }
                    if iAccepted {
                        Label("You accepted this qual swap.", systemImage: "checkmark.seal.fill").foregroundStyle(AppColor.success)
                    } else if leg.acceptIsOpen && !leg.status.isTerminal {
                        if let cand = leg.candidates.first(where: { $0.workerID == myID }) {
                            Text("You'd move onto desk \(leg.giveDesk) (\(leg.giveQual)); your desk \(cand.desk) (\(cand.qual)) goes to \(leg.takerName).")
                                .font(.caption)
                        }
                        Button { Task { await store.acceptQualSwapBridge(request) } } label: {
                            Label("Accept qual swap", systemImage: "checkmark.circle.fill")
                        }.tint(AppColor.success)
                    } else {
                        Label("Qual swap already filled.", systemImage: "lock.fill").foregroundStyle(.secondary)
                    }
                }

                // TAKER (B): live acceptances + choose + decline.
                if role == .taker {
                    Text("\(leg.acceptances.count) of \(leg.candidates.count) asked have accepted.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(leg.acceptances) { a in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name).font(.subheadline.weight(.semibold))
                                Text("frees desk \(a.desk) (\(a.qual))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if leg.chosenWorkerID == a.workerID {
                                Label("Chosen", systemImage: "checkmark.seal.fill").foregroundStyle(AppColor.success)
                            } else if !leg.status.isTerminal {
                                Button("Choose") { Task { await store.finalizeQualSwap(request, chosenWorkerID: a.workerID) } }
                                    .buttonStyle(.borderedProminent).tint(AppColor.success)
                            }
                        }
                    }
                    if leg.acceptances.isEmpty && !leg.status.isTerminal {
                        Text("Waiting for a bridge to accept…").font(.caption).foregroundStyle(.secondary)
                    }
                    if !leg.status.isTerminal {
                        Button(role: .destructive) { Task { await store.declineQualSwap(request) } } label: {
                            Label("Decline — cancels the trade", systemImage: "xmark.circle")
                        }
                    }
                }

                // GIVER (A) / uninvolved party: read-only contingent state.
                if (role == .giver || role == .none), !leg.status.isTerminal {
                    Label("This trade is contingent on the qual swap.", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // B2: once a bridge is finalized, the giver can fuse this qual swap with their clean
                // base trade on the same day into ONE request.
                if role == .giver, let base = store.mergeBase(for: request) {
                    Button {
                        Task {
                            await store.mergeRequests(base: base, bridge: request)
                            dismiss()   // both originals archived; the merged card is in the inbox
                        }
                    } label: {
                        Label("Merge with base trade", systemImage: "arrow.triangle.merge")
                    }
                    .tint(AppColor.special)
                    Text("Combines this qual swap with your clean trade on \(prettyDay(leg.giveShiftDayID)) into a single request.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } header: {
                Text("Qual swap")
            }
        }
    }

    /// One chronological audit event: who did what, when, with the note.
    private func auditRow(icon: String, tint: Color, who: String, what: String,
                          when: Date, note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("\(who) \(what)").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(when, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
                if !note.isEmpty {
                    mdText(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The sender posted an "ECB CONFIRMED" response → they're submitting the form.
    private var senderConfirmedECB: Bool {
        store.responses(for: request.id).contains {
            $0.responderID == request.fromID && $0.note.localizedCaseInsensitiveContains("ECB CONFIRMED")
        }
    }
    /// You already confirmed receipt.
    private var receivedECB: Bool {
        store.responses(for: request.id).contains {
            $0.responderID == myID && $0.note.localizedCaseInsensitiveContains("RECEIVED")
        }
    }
    /// The sender filled the offer with someone else.
    private var filledByOther: Bool {
        store.responses(for: request.id).contains {
            $0.responderID == request.fromID && $0.note.localizedCaseInsensitiveContains("filled")
        }
    }

    private func confirmReceived() {
        let ecb = request.ecbAmount ?? 0
        Task {
            await store.respond(to: request, status: .accepted, note: "ECB RECEIVED — got the \(ecbText(ecb)) ECB. Thanks!")
            TradeHistoryStore.shared.record(TradeHistoryEntry(
                summary: "Received \(ecbText(ecb)) ECB from \(request.fromName) for taking \(DayFmt.list(request.giveDayIDs))",
                participants: [request.fromName], dayIDs: request.giveDayIDs,
                completedAt: Date(), pending: false, ecb: Int(ecb.rounded())))
            WidgetData.update()
        }
    }

    private func respond(_ status: TradeRequestStatus) {
        var note = replyNote.trimmingCharacters(in: .whitespacesAndNewlines)
        // ECB acceptances auto-include your employee # for the official form.
        if request.isECB, status == .accepted {
            let id = SettingsManager.shared.username
            note = "Employee #\(id)." + (note.isEmpty ? "" : " \(note)")
        }
        Task {
            await store.respond(to: request, status: status, note: note)
            replyNote = ""
            WidgetData.update()
            // Stay on the thread so your reply (and its status) is visible.
        }
    }
}

// MARK: - Broadcast Channel

struct ChannelView: View {
    private var store = MessagingStore.shared
    private var dev = DevAccess.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var expanded: Set<String> = []
    @State private var collapsedReplies: Set<String> = []   // #9: per-comment subtree collapse
    @State private var replyingTo: String? = nil            // #9: reply ID an inline composer targets
    @State private var editingPost: BroadcastPost?
    @State private var editingReply: BroadcastReply?
    @State private var editReplyDraft = ""
    @State private var channel = "trades"
    @State private var pickerItem: PhotosPickerItem?   // B5: photo attach
    @State private var pendingImage: UIImage?

    private var myID: String { SettingsManager.shared.username }
    private var posts: [BroadcastPost] {
        MessagingStore.sortedForChannel(store.broadcasts.filter { $0.channelOrDefault == channel })
    }

    /// Who you can @-mention: every ACTIVE (published-profile) dispatcher, by resolved name.
    private var mentionPeople: [(id: String, name: String)] {
        TradeProfileStore.shared.others.keys
            .map { (id: $0, name: participantName($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Per-channel copy. Unknown channels fall back to the trade board. E1.
    private var channelMeta: (title: String, subtitle: String, emptyTitle: String, emptyDesc: String, icon: String) {
        switch channel {
        case "general":
            return ("General", "Anything dispatch — chat with the group", "No Messages Yet",
                    "Say hello, ask a question, share an update — everyone sees it.", "bubble.left.and.bubble.right")
        case "feedback":
            return ("Feedback", "Bugs & ideas for the app — the builder reads these", "No Feedback Yet",
                    "Report a bug or suggest an improvement — start with what you did and what happened.", "exclamationmark.bubble")
        default:
            return ("Trade Channel", "What you're trading away — everyone sees it", "No Posts Yet",
                    "Post what you're looking to trade away — everyone sees it. Posts expire on their own.", "megaphone")
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Channel", selection: $channel) {
                    Text("# general").tag("general")
                    Text("# trades").tag("trades")
                    Text("# feedback").tag("feedback")
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.top, 6)
                // Slim one-line description (the "# name" is already in the picker above — no redundant header).
                Text(channelMeta.subtitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 3).padding(.bottom, 7)
                    .onAppear { store.markBroadcastsSeen() }   // clears the unread badge (A2)
                Divider()
                if posts.isEmpty {
                    ContentUnavailableView(channelMeta.emptyTitle, systemImage: channelMeta.icon,
                        description: Text(channelMeta.emptyDesc))
                        .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(posts) { post in
                            postRow(post)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await store.refresh(); await TradeProfileStore.shared.refreshOthers() }
                }
            }
            // B4-13: pin the composer in a bottom inset — stable identity OUTSIDE the scrolling List so
            // tapping the Photo picker presents cleanly instead of re-laying-out the channel (which
            // collapsed expanded threads + swallowed the tap). Mirrors ThreadView's working composer.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Image(systemName: "photo").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let img = pendingImage {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 30, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Button { pendingImage = nil; pickerItem = nil } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            Text("Photo attached").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.top, 6)
                    SlackComposer(placeholder: "Message #\(channel)", text: $draft,
                                  mentionPeople: mentionPeople) {
                        let text = draft; draft = ""
                        let img = pendingImage; pendingImage = nil; pickerItem = nil
                        Task {
                            let b64 = img.flatMap { PostImage.encode($0) }
                            await store.post(text: text, channel: channel, imageBase64: b64)
                        }
                    }
                }
                .background(.bar)
                .onChange(of: pickerItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) { pendingImage = UIImage(data: data) }
                    }
                }
            }
            .navigationTitle(channelMeta.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.refresh(); await TradeProfileStore.shared.refreshOthers() }   // E2: load peers so statuses render
            .sheet(item: $editingPost) { post in EditPostSheet(post: post) }
            .alert("Edit reply", isPresented: Binding(get: { editingReply != nil }, set: { if !$0 { editingReply = nil } })) {
                TextField("Reply", text: $editReplyDraft)
                Button("Save") { if let r = editingReply { Task { await store.editReply(r, newText: editReplyDraft) } }; editingReply = nil }
                Button("Cancel", role: .cancel) { editingReply = nil }
            }
        }
    }

    /// E2: the author's published status — mine from Settings, peers from the loaded profiles.
    private func authorStatus(_ id: String) -> String? {
        let raw = (id == SettingsManager.shared.username)
            ? SettingsManager.shared.statusBroadcast
            : (TradeProfileStore.shared.profile(forWorker: id)?.statusBroadcast ?? "")
        let t = raw.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func postRow(_ post: BroadcastPost) -> some View {
        let isOpen = expanded.contains(post.id)
        let reps = store.visibleReplies(for: post)
        return VStack(alignment: .leading, spacing: 6) {
            if post.isPinned {
                Label("Pinned", systemImage: "pin.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(AppColor.heat).padding(.leading, 46)
            }
            SlackMessageRow(name: post.authorName, authorID: post.authorID,
                            timestamp: post.createdAt, message: post.text,
                            status: authorStatus(post.authorID)) {   // E2: status to the LEFT of the name
                postMenu(post)
            }
            if let b64 = post.imageBase64, let ui = PostImage.decode(b64) {
                ExpandableImage(image: ui, maxHeight: 220, cornerRadius: 10)   // B4-11: tap to zoom
                    .padding(.leading, 46)
            }
            reactionsBar(post)

            if !reps.isEmpty && !isOpen {
                Button { expanded.insert(post.id) } label: {
                    // Reddit-style collapse chevron: ▸ to expand.
                    Label("^[\(reps.count) reply](inflect: true)", systemImage: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain).foregroundStyle(AppColor.primary).padding(.leading, 46)
            }

            if isOpen {
                HStack(spacing: 8) {
                    // Reddit-style threadline — a tappable rail that collapses the whole thread.
                    Capsule().fill(Color.accentColor.opacity(0.35)).frame(width: 2.5)
                        .contentShape(Rectangle())
                        .onTapGesture { expanded.remove(post.id) }
                    VStack(alignment: .leading, spacing: 4) {
                        if !reps.isEmpty {
                            Button { expanded.remove(post.id) } label: {
                                Label("Hide ^[\(reps.count) reply](inflect: true)", systemImage: "chevron.up")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        threadedReplies(post: post, reps: reps)
                        // Top-level reply to the post (parentReplyID nil).
                        BroadcastReplyComposer(isAuthor: store.isMine(post)) { text, isPublic, image in
                            Task { await store.addReply(to: post, text: text, isPublic: isPublic, imageBase64: image) }
                        }
                    }
                }
                .padding(.leading, 18)

                actionRow(post)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if isOpen { expanded.remove(post.id) } else { expanded.insert(post.id) }   // #10: tap toggles
        }
    }

    @ViewBuilder private func postMenu(_ post: BroadcastPost) -> some View {
        let mine = store.isMine(post)
        if mine || dev.unlocked {
            Menu {
                if mine {
                    Button { editingPost = post } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { Task { await store.deletePost(post.id) } } label: { Label("Delete", systemImage: "trash") }
                }
                if dev.unlocked {   // admin: pin to top of channel (B7)
                    Button { Task { await store.setPinned(post, !post.isPinned) } } label: {
                        Label(post.isPinned ? "Unpin" : "Pin to top", systemImage: post.isPinned ? "pin.slash" : "pin")
                    }
                    if !mine {
                        Button(role: .destructive) { Task { await store.hide(post.id) } } label: { Label("Hide", systemImage: "eye.slash") }
                    }
                }
                if expanded.contains(post.id) {
                    Button { expanded.remove(post.id) } label: { Label("Collapse", systemImage: "chevron.up") }
                }
            } label: {
                Image(systemName: "ellipsis").font(.caption).foregroundStyle(.secondary).padding(4)
            }
        }
    }

    private static let quickEmojis = ["👍", "❤️", "✅", "⚠️", "🔥", "🙏"]

    /// Emoji reaction chips + a quick-react menu (B6).
    @ViewBuilder private func reactionsBar(_ post: BroadcastPost) -> some View {
        HStack(spacing: 6) {
            ForEach(Reaction.counts(post.reactions ?? []), id: \.emoji) { r in
                Button { Task { await store.react(to: post, emoji: r.emoji) } } label: {
                    Text("\(r.emoji) \(r.count)").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }.buttonStyle(.plain)
            }
            Menu {
                ForEach(Self.quickEmojis, id: \.self) { e in
                    Button(e) { Task { await store.react(to: post, emoji: e) } }
                }
            } label: {
                Image(systemName: "face.smiling").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, 46)
    }

    /// #9: the post's replies rendered as a Reddit-style nested tree — pre-order, indented per depth,
    /// with per-comment Reply + collapse. Descendants of a collapsed comment are hidden.
    @ViewBuilder private func threadedReplies(post: BroadcastPost, reps: [BroadcastReply]) -> some View {
        let tree = ReplyThread.flatten(reps)
        let hiddenByCollapse = collapsedReplies.reduce(into: Set<String>()) { acc, id in
            acc.formUnion(ReplyThread.subtreeIDs(of: id, in: reps))
        }
        ForEach(tree.filter { !hiddenByCollapse.contains($0.reply.id) }) { tr in
            threadedReplyRow(tr, post: post, reps: reps)
        }
    }

    private func threadedReplyRow(_ tr: ThreadedReply, post: BroadcastPost, reps: [BroadcastReply]) -> some View {
        let depth = min(tr.depth, 6)                                  // cap indentation on deep chains
        let childCount = ReplyThread.subtreeIDs(of: tr.reply.id, in: reps).count
        let isCollapsed = collapsedReplies.contains(tr.reply.id)
        return HStack(alignment: .top, spacing: 5) {
            // One threadline rail per nesting level — tap a rail to collapse this comment's subtree.
            ForEach(0..<depth, id: \.self) { _ in
                Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                replyRow(tr.reply)
                HStack(spacing: 14) {
                    Button { replyingTo = (replyingTo == tr.reply.id ? nil : tr.reply.id) } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left").font(.caption2.weight(.semibold))
                    }
                    if childCount > 0 {
                        Button {
                            if isCollapsed { collapsedReplies.remove(tr.reply.id) } else { collapsedReplies.insert(tr.reply.id) }
                        } label: {
                            Label(isCollapsed ? "Show ^[\(childCount) reply](inflect: true)" : "Hide",
                                  systemImage: isCollapsed ? "chevron.right" : "chevron.down").font(.caption2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 32)
                if replyingTo == tr.reply.id {
                    BroadcastReplyComposer(isAuthor: store.isMine(post)) { text, isPublic, image in
                        Task { await store.addReply(to: post, text: text, isPublic: isPublic, imageBase64: image, parentReplyID: tr.reply.id) }
                        replyingTo = nil
                    }
                }
            }
        }
    }

    private func replyRow(_ r: BroadcastReply) -> some View {
        let metaText = (r.isPublic ? "public" : "private") + (r.editedAt != nil ? " · edited" : "")
        return VStack(alignment: .leading, spacing: 4) {
            SlackMessageRow(name: r.authorID == myID ? "You" : r.authorName, authorID: r.authorID,
                            timestamp: r.createdAt, message: r.isDeleted ? "[Deleted]" : r.text,
                            meta: (metaText, r.isPublic ? AppColor.primary : AppColor.pending),
                            avatarSize: 26) {
                if r.isDeleted {
                    EmptyView()
                } else if r.authorID == myID {
                    Button { editingReply = r; editReplyDraft = r.text } label: {
                        Image(systemName: "pencil").font(.caption2)
                    }.buttonStyle(.borderless)
                    Button(role: .destructive) { Task { await store.softDeleteReply(r) } } label: {
                        Image(systemName: "trash").font(.caption2)
                    }.buttonStyle(.borderless)
                } else if dev.unlocked {
                    Button(role: .destructive) { Task { await store.hide(r.id) } } label: {
                        Image(systemName: "eye.slash.fill").font(.caption2)
                    }.buttonStyle(.borderless)
                }
            }
            if !r.isDeleted, let b64 = r.imageBase64, let ui = PostImage.decode(b64) {
                ExpandableImage(image: ui, maxHeight: 180)   // B4-11: tap to zoom
                    .padding(.leading, 34)
            }
            if !r.isDeleted {
                ReactionChips(reactions: r.reactions ?? []) { e in Task { await store.react(to: r, emoji: e) } }
                    .padding(.leading, 34)
            }
        }
    }

    private func actionRow(_ post: BroadcastPost) -> some View {
        // The old "Send trade request" shortcut was removed — it fired an EMPTY request (no days) at the
        // poster, which was vague and duplicated the real trade flow. Reply in-thread or propose a real
        // trade from Trades instead.
        HStack(spacing: 14) {
            Spacer()
            Text("Expires \(post.expiresAt, style: .relative)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.leading, 46)
    }
}

/// Compose a reply (or, for the post author, an update): premium field, public/private,
/// photo attach, and a send ICON. (#8b)
struct BroadcastReplyComposer: View {
    let isAuthor: Bool
    let onSend: (String, Bool, String?) -> Void
    @State private var draft = ""
    @State private var isPublic = true
    @State private var pickerItem: PhotosPickerItem?
    @State private var pendingImage: UIImage?
    @State private var showPicker = false   // B4-13: drive the picker via the isPresented modifier

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let img = pendingImage {
                HStack(spacing: 8) {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                    Button { pendingImage = nil; pickerItem = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            TextField(isAuthor ? "Post an update…" : "Reply…", text: $draft, axis: .vertical)
                .font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .lineLimit(1...4)
            HStack(spacing: 12) {
                Picker("", selection: $isPublic) {
                    Label("Public", systemImage: "globe").tag(true)
                    Label("Private", systemImage: "lock.fill").tag(false)
                }
                .pickerStyle(.segmented).fixedSize()
                FormatBar(text: $draft)
                Button { showPicker = true } label: {
                    Image(systemName: "photo").font(.subheadline).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    let t = draft, img = pendingImage
                    draft = ""; pendingImage = nil; pickerItem = nil
                    onSend(t, isPublic, img.flatMap { PostImage.encode($0) })
                } label: {
                    Image(systemName: "paperplane.circle.fill").font(.title2)
                        .foregroundStyle(canSend ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.vertical, 4)
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { if let data = try? await item.loadTransferable(type: Data.self) { pendingImage = UIImage(data: data) } }
        }
    }
}

/// Edit your own broadcast post (text + Markdown formatting).
struct EditPostSheet: View {
    let post: BroadcastPost
    private var store = MessagingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(post: BroadcastPost) {
        self.post = post
        _draft = State(initialValue: post.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $draft)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                HStack {
                    FormatBar(text: $draft)
                    Spacer()
                    Text("**bold** *italic* ~~strike~~").font(.caption2).foregroundStyle(.tertiary)
                }
                Text("Preview").font(.caption).foregroundStyle(.secondary)
                mdText(draft).font(.subheadline)
                Spacer()
            }
            .padding()
            .navigationTitle("Edit Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await store.editPost(post, newText: draft); dismiss() }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Side dock (floating, on every page)

struct MessagingDock: View {
    @Binding var showInbox: Bool
    @Binding var showChannel: Bool
    @Binding var showTradeSettings: Bool
    @Binding var showAppSettings: Bool
    @Binding var showDashboard: Bool         // trade-status breakdown (now its own top-header button)
    @Binding var showECB: Bool               // ECB Accounting ledger (⋯ menu)
    private var store = MessagingStore.shared
    private var history = TradeHistoryStore.shared

    init(showInbox: Binding<Bool>, showChannel: Binding<Bool>,
         showTradeSettings: Binding<Bool>, showAppSettings: Binding<Bool>,
         showDashboard: Binding<Bool>, showECB: Binding<Bool>) {
        _showInbox = showInbox; _showChannel = showChannel
        _showTradeSettings = showTradeSettings; _showAppSettings = showAppSettings
        _showDashboard = showDashboard; _showECB = showECB
    }

    /// Trade-status "something new" badge: in-flight trades needing your attention — agreed-in-app
    /// (accepted, awaiting you to mark official) + still-negotiating (pending). Live (@Observable stores).
    private var tradeStatusBadge: Int {
        let c = DashboardCounts.from(requests: store.requests, responses: store.responses,
                                     unread: store.pendingIncoming.count, pendingLedger: history.pendingCount)
        return c.accepted + c.pending
    }

    var body: some View {
        // Four controls: Inbox · Channel · Trade status · ⋯ (settings). Each primary destination carries its
        // own "needs you" badge; the ⋯ overflow is settings only now.
        HStack(spacing: 8) {
            iconButton("tray.full.fill", label: "Inbox",
                       badge: store.pendingIncoming.count + ECBAccountingStore.shared.pendingConfirmations.count,
                       badgeColor: AppColor.danger) { showInbox = true }
            iconButton("megaphone.fill", label: "Channel",
                       badge: store.unreadBroadcastCount, badgeColor: AppColor.primary) { showChannel = true }
            iconButton("checklist", label: "Trade status",
                       badge: tradeStatusBadge, badgeColor: AppColor.pending) { showDashboard = true }
            Menu {
                Button { showECB = true } label: { Label("ECB Accounting", systemImage: "banknote") }
                Divider()
                Button { showTradeSettings = true } label: { Label("Trade Settings", systemImage: "arrow.left.arrow.right") }
                Button { showAppSettings = true } label: { Label("App Settings", systemImage: "gearshape") }
            } label: { iconLabel("ellipsis") }
            .buttonStyle(.plain)
            .accessibilityLabel("More")
        }
    }

    /// One uniform rounded-rect icon button (the app's single control shape), with an optional count badge.
    private func iconButton(_ icon: String, label: String, badge: Int = 0,
                            badgeColor: Color = .clear, action: @escaping () -> Void) -> some View {
        Button(action: action) { iconLabel(icon, badge: badge, badgeColor: badgeColor) }
            .buttonStyle(.plain)
            .accessibilityLabel(badge > 0 ? "\(label), \(badge)" : label)
    }

    private func iconLabel(_ icon: String, badge: Int = 0, badgeColor: Color = .clear) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: DS.controlSize, height: DS.controlSize)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
            .foregroundStyle(.primary)
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(min(badge, 99))")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(badgeColor, in: Capsule())
                        .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 1.5))
                        .offset(x: 5, y: -5)
                }
            }
    }
}

```


## `Sources/UI/Settings/SettingsView.swift`

```swift
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
    @State private var showHelp = false
    @State private var showTesterGuide = false
    @State private var showWelcome = false
    @State private var rosterProbe: String?   // dev: roster date-span + last-60d readout
    @State private var showImporter = false   // dev: manual master schedule CSV import (moved off Home)
    @State private var importResult: String?
    @State private var importError: String?
    private var dev = DevAccess.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {

                // ── App info: installed version + last schedule sync (moved off the Home page) ───
                Section {
                    LabeledContent {
                        Text("\(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
                    } label: {
                        Label("Version", systemImage: "info.circle")
                    }
                    LabeledContent {
                        Text(Self.syncedText).foregroundStyle(.secondary)
                    } label: {
                        Label("Schedule synced", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                // ── Help ─────────────────────────────────────────────
                Section {
                    Button { showWelcome = true } label: {
                        Label("Welcome & how it works", systemImage: "sparkles")
                    }
                    Button { showHelp = true } label: {
                        Label("How to use \(AppGuide.appName)", systemImage: "questionmark.circle")
                    }
                    Button { showTesterGuide = true } label: {
                        Label("Tester guide", systemImage: "checklist")
                    }
                    NavigationLink {
                        VersionHistoryView()
                    } label: {
                        Label("Update history", systemImage: "clock.arrow.circlepath")
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

                // ── Accessibility ────────────────────────────────────
                Section {
                    Toggle(isOn: $settings.magnifierEnabled) {
                        Label("Screen magnifier", systemImage: "plus.magnifyingglass")
                    }
                } footer: {
                    Text("Shows a floating magnifier button (drag it anywhere). Tap it, then pinch with two fingers to zoom and drag with two fingers to pan — one finger still taps and scrolls normally.")
                }

                // ── Welcome / What's New ─────────────────────────────
                Section {
                    Toggle(isOn: $settings.showWelcomeOnLaunch) {
                        Label("Show Welcome on every launch", systemImage: "hand.wave")
                    }
                } footer: {
                    Text("When off, the Welcome / What's New screen only appears after an app update.")
                }

                // ── Daily summary ────────────────────────────────────
                Section {
                    Toggle(isOn: $settings.dailyDigestEnabled) {
                        Label("Daily summary notification", systemImage: "bell.badge")
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
                .onChange(of: settings.notificationLeadHours) { _, _ in
                    Task { await NotificationManager.shared.scheduleAll(for: ShiftStore.shared.shifts) }
                    publishPrefs()
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
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
            .sheet(isPresented: $showWelcome) { WelcomeView() }
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

```


## `Sources/UI/Settings/HelpView.swift`

```swift
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

    /// Three-step welcome: 0 = who we are / first steps · 1 = "What's New in Build 6" · 2 = set trade preferences.
    @State private var page = 0
    @Bindable private var settings = SettingsManager.shared
    @State private var myQuals: [String] = []
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
                    default: Button("Done") { onDismiss(); dismiss() }
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
                         enabled: { DeskRules.isQualified(quals: myQuals, forRegion: DeskRegion(rawValue: $0) ?? .domestic) },
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
        .task {
            // Show cached quals INSTANTLY (fixes the stale-on-first-entry region pills), then refresh
            // from the roster (async on launch) and update the cache for next time.
            myQuals = settings.cachedQuals
            for _ in 0..<20 {
                let q = await RosterStore.shared.schedule(forWorker: settings.username).first?.quals ?? []
                if !q.isEmpty { myQuals = q; settings.cachedQuals = q; return }
                try? await Task.sleep(nanoseconds: 300_000_000)   // 0.3s between attempts (~6s max)
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
            Image("AppLogo")
                .resizable()
                .scaledToFill()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            Text("Welcome to \(AppGuide.appName)").font(.title.bold())
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
                ForEach(AppGuide.pillars, id: \.title) { pillar in
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: pillar.symbol).font(.title3).foregroundStyle(AppColor.primary)
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
struct VersionHistoryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(AppGuide.versionHistory.enumerated()), id: \.element.id) { i, rel in
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
            // Header: build name in accent + a one-line headline, so each build reads as its own titled block.
            VStack(alignment: .leading, spacing: 3) {
                Label(rel.version, systemImage: isLatest ? "sparkles" : "shippingbox.fill")
                    .font(.headline).labelStyle(.titleAndIcon).foregroundStyle(AppColor.primary)
                Text(rel.headline).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            // Bullets in full-contrast primary text with an accent dot — readable, not washed-out gray.
            ForEach(rel.points, id: \.self) { p in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(AppColor.primary).frame(width: 6, height: 6).padding(.top, 6)
                    Text(p).font(.subheadline).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        // The current build gets an accent ring so it stands out from prior history.
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
                    "Ask Siri: \"Do I work tomorrow in \(AppGuide.appName)\", \"Who can trade with me…\".",
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

```


## `Sources/UI/Shared/ShiftSelectCalendar.swift`

```swift
// ShiftSelectCalendar.swift
// A month-navigable, MULTI-select calendar for choosing the working shifts you
// want to trade away. Tap working days to toggle them into the selection; use the
// month arrows to reach any week of the year. Off/past days are disabled.

import SwiftUI

struct ShiftSelectCalendar: View {
    let shifts: [Shift]
    @Binding var selection: Set<String>

    @State private var monthAnchor = Calendar.current.startOfDay(for: Date())

    private var intents = DayIntentStore.shared   // show your marks so the picker isn't blank (C3)
    private let cal = Calendar.current
    private static let headers = ["Su", "M", "T", "W", "Th", "F", "Sa"]
    private static let isoF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let monthF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    private var byDay: [String: Shift] {
        Dictionary(shifts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Six weeks of days covering the anchor month (Sunday-aligned).
    private var gridDays: [Date] {
        guard let interval = cal.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let weekdayIndex = cal.component(.weekday, from: interval.start) - 1
        guard let start = cal.date(byAdding: .day, value: -weekdayIndex, to: interval.start) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        let days = gridDays
        VStack(spacing: 5) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").font(.headline) }
                Spacer()
                Text(Self.monthF.string(from: monthAnchor)).font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").font(.headline) }
            }
            .padding(.horizontal, 6)

            HStack(spacing: 3) {
                ForEach(Self.headers, id: \.self) { h in
                    Text(h).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { col in
                        cell(days[week * 7 + col])
                    }
                }
            }
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) { monthAnchor = d }
    }

    private func cell(_ date: Date) -> some View {
        let inMonth   = cal.isDate(date, equalTo: monthAnchor, toGranularity: .month)
        let shift     = byDay[Self.isoF.string(from: date)]
        let isWorking = shift.map { !$0.isOff } ?? false
        let today     = cal.startOfDay(for: Date())
        let isToday   = cal.isDate(date, inSameDayAs: today)
        let isPast    = date < today && !isToday
        let isSelected = shift.map { selection.contains($0.id) } ?? false

        return Button {
            if let s = shift, isWorking, !isPast {
                if selection.contains(s.id) { selection.remove(s.id) } else { selection.insert(s.id) }
            }
        } label: {
            VStack(spacing: 1) {
                ZStack {
                    if isToday { Circle().fill(Color.accentColor).frame(width: 24, height: 24) }
                    Text("\(cal.component(.day, from: date))")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isToday ? .white : .primary)
                }
                .frame(height: 24)
                Text(isWorking ? (shift?.shiftShortLabel ?? "") : "")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minHeight: 15)
                // Your working-intent color (trade-away / keep / …) so the picker shows context. C3
                if isWorking, let id = shift?.id, let w = intents.workingIntent(forDay: id) {
                    Capsule().fill(w.brickColor).frame(height: 3)
                } else {
                    Color.clear.frame(height: 3)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(background(isWorking: isWorking, isSelected: isSelected))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
            )
            .overlay(alignment: .topTrailing) {
                if let id = shift?.id, intents.note(forDay: id) != nil {
                    Circle().fill(BrickPalette.info).frame(width: 5, height: 5).padding(3)
                }
            }
            .opacity(inMonth ? (isPast ? 0.3 : 1) : 0.18)
        }
        .buttonStyle(.plain)
        .disabled(!isWorking || isPast || !inMonth)
    }

    // Working days are clearly tinted; off days are flat grey.
    private func background(isWorking: Bool, isSelected: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.85) }
        if isWorking  { return Color.accentColor.opacity(0.18) }
        return Color(.systemGray5)
    }
}

```


## `Sources/UI/Shared/SlackKit.swift`

```swift
// SlackKit.swift
// Slack-style building blocks for the trade channel + inbox: initials avatars,
// a message row (avatar · name · time · markdown body · inline actions), and a
// pinned composer with a formatting bar. Presentation only — the messaging data
// flow in MessagingStore is unchanged.

import SwiftUI
import Lottie

// MARK: - Animated loader (Lottie)

/// Reusable looping Lottie loader that swaps light/dark by color scheme. Used for the launch
/// overlay and the "Searching for trades" indicator. Falls back to a spinner if a file is missing.
struct AnimatedLoader: View {
    @Environment(\.colorScheme) private var scheme
    /// Base animation name; "-light"/"-dark" is appended by color scheme. "dx-loading" = app loading,
    /// "finding-matches" = trade search.
    var name: String = "dx-loading"
    /// Optional square cap. nil = fill the container; otherwise scales to fit within maxSize.
    var maxSize: CGFloat? = nil
    var body: some View {
        let full = "\(name)-\(scheme == .dark ? "dark" : "light")"
        Group {
            if LottieAnimation.named(full) != nil {
                LottieView(animation: .named(full)).looping()
            } else {
                ProgressView().controlSize(.large)   // graceful fallback if the JSON isn't bundled
            }
        }
        .aspectRatio(contentMode: .fit)                 // scale to fit the area it's placed in
        .frame(maxWidth: maxSize, maxHeight: maxSize)
    }
}

// MARK: - Character counter (F3)

/// A compact "used/limit" counter that turns amber near the limit and red over it.
/// Logic lives in the pure `CharLimit` (testable); this is presentation only.
struct CharCounter: View {
    let text: String
    let limit: Int
    var body: some View {
        let s = CharLimit.state(text, limit: limit)
        Text("\(s.used)/\(limit)")
            .font(.caption2)
            .foregroundStyle(s.over ? AppColor.danger : (s.nearLimit ? AppColor.pending : Color.secondary))
            .monospacedDigit()
            .accessibilityLabel("\(max(0, s.remaining)) characters remaining")
    }
}

// MARK: - Name + status (A7/B8)

/// A person's name with their current status broadcast in italics underneath, shown
/// wherever a name appears in trade views. Status looked up via `participantStatus`.
/// Renders just the name when there's no status. SPEC U-GLOBAL-3.
struct NameWithStatus: View {
    let id: String
    var name: String? = nil
    var nameFont: Font = .subheadline.weight(.semibold)
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // 🤖 marks a peer who isn't on the app yet (no active profile) → can't be messaged.
            Text((name ?? participantName(id)) + botSuffix(id)).font(nameFont)
            if let status = participantStatus(id) {
                Text(status).font(.caption2).italic()
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

// MARK: - Style helpers

enum SlackStyle {
    /// Avatar palette — identity only (Tier 2). Draws from the app's single categorical ramp so
    /// person colors match the trade-seat colors and nothing invents its own hues.
    static let palette: [Color] = AppColor.categorical

    /// Deterministic color from an id (stable across launches).
    static func color(for id: String) -> Color {
        guard !id.isEmpty else { return .gray }
        let sum = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    /// Up to two initials from a "Last, First" or "First Last" name.
    static func initials(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: ",", with: " ")
        let letters = cleaned.split(separator: " ").prefix(2).compactMap { $0.first }
        let s = letters.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

// MARK: - Avatar

struct Avatar: View {
    let name: String
    let id: String
    var size: CGFloat = 36

    var body: some View {
        Text(SlackStyle.initials(name))
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(SlackStyle.color(for: id), in: RoundedRectangle(cornerRadius: size * 0.24))
    }
}

// MARK: - Message row

/// One Slack-style message: avatar gutter, then name + meta + timestamp on the
/// header line (with inline `actions` on the right), then the markdown body.
struct SlackMessageRow<Actions: View>: View {
    let name: String
    let authorID: String
    let timestamp: Date
    let message: String
    var meta: (text: String, color: Color)? = nil
    var status: String? = nil          // E2: the author's status, shown to the RIGHT of their name
    var avatarSize: CGFloat = 36
    @ViewBuilder var actions: () -> Actions

    init(name: String, authorID: String, timestamp: Date, message: String,
         meta: (text: String, color: Color)? = nil, status: String? = nil, avatarSize: CGFloat = 36,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.name = name; self.authorID = authorID; self.timestamp = timestamp
        self.message = message; self.meta = meta; self.status = status
        self.avatarSize = avatarSize; self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: name, id: authorID, size: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.subheadline.weight(.semibold))
                    if let status, !status.isEmpty {
                        Text(status).font(.caption2).italic().foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let meta {
                        Text(meta.text).font(.caption2.weight(.medium)).foregroundStyle(meta.color)
                    }
                    Text(timestamp, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    actions()
                }
                if !message.isEmpty {
                    mdText(message).font(.subheadline).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Legend (shared color key — one comprehensive source, two presentations)

/// A single legend swatch (fill / border / SF-symbol / emoji), sized to align in rows.
struct LegendSwatch: View {
    let swatch: AppLegend.Swatch
    var size: CGFloat = 22
    var body: some View {
        switch swatch {
        case .fill(let c):
            // Full-strength token color (no opacity wash) so the legend reads at true contrast and
            // matches the palette exactly. A hairline keeps light swatches legible on any background.
            RoundedRectangle(cornerRadius: 5).fill(c).frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.15), lineWidth: 0.5))
        case .border(let c):
            RoundedRectangle(cornerRadius: 5).strokeBorder(c, lineWidth: 2.5).frame(width: size, height: size)
        case .icon(let symbol, let c):
            Image(systemName: symbol).font(.system(size: size * 0.72)).foregroundStyle(c).frame(width: size, height: size)
        case .glyph(let g):
            Text(g).font(.system(size: size * 0.8)).frame(width: size, height: size)
        }
    }
}

/// One legend line: swatch · name · meaning. Used by both the info sheet and the inline legend.
struct LegendRow: View {
    let item: AppLegend.Item
    var body: some View {
        HStack(spacing: 10) {
            LegendSwatch(swatch: item.swatch)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.subheadline.weight(.semibold))
                Text(item.meaning).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The comprehensive legend, COLLAPSED by default, shown inline under the trade feeds so it's
/// there to reference but never in the way. Same content as the info Color Key sheet (AppLegend).
struct CollapsibleLegend: View {
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(AppLegend.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title.uppercased()).font(.dsLabel).foregroundStyle(.secondary)
                        ForEach(section.items) { LegendRow(item: $0) }
                    }
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Legend & colors", systemImage: "paintpalette")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .tint(.secondary)
        // Half-height collapsed bar: full horizontal padding, halved vertical padding.
        .padding(.horizontal, DS.cardPadding)
        .padding(.vertical, DS.cardPadding / 2)
        .background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))
    }
}

// MARK: - Loading overlay (so the app never looks frozen)

/// A centered spinner card shown over content while `active`. Reassures the user that startup, a
/// match search, or a tab-load is working — not frozen. Dims the background lightly; taps pass through
/// visually but the spinner sits on top. Fades in/out.
struct LoadingOverlay: ViewModifier {
    let active: Bool
    var label: String = "Loading…"
    func body(content: Content) -> some View {
        content.overlay {
            if active {
                ZStack {
                    Color(.systemBackground).opacity(0.35).ignoresSafeArea()
                    // No card, no text — the dx-loading animation already reads "loading". ~3× larger
                    // than before, capped so it stays reasonable (and scales down) on iPad.
                    AnimatedLoader(name: "dx-loading", maxSize: 288)
                }
                .transition(.opacity)
                .accessibilityElement()
                .accessibilityLabel(label)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: active)
    }
}

extension View {
    /// Show a spinner card over this view while `active` (e.g. startup / match search / tab-load).
    func loadingOverlay(_ active: Bool, label: String = "Loading…") -> some View {
        modifier(LoadingOverlay(active: active, label: label))
    }
}

// MARK: - Expandable image (B4-11)

/// An inline image that expands to a full-screen, pinch-to-zoom viewer on tap. Shared by channel
/// posts, replies, and 1:1 chat so all three get the same behavior (B4-11).
struct ExpandableImage: View {
    let image: UIImage
    var maxHeight: CGFloat = 180
    var cornerRadius: CGFloat = 8
    @State private var showFull = false

    var body: some View {
        Image(uiImage: image).resizable().scaledToFit()
            .frame(maxHeight: maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(Rectangle())
            .onTapGesture { showFull = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Expand image")
            .fullScreenCover(isPresented: $showFull) { ZoomableImageViewer(image: image) }
    }
}

/// Full-screen zoom/pan image viewer: pinch to zoom (1–6×), drag when zoomed, double-tap to toggle,
/// tap the ✕ to close.
struct ZoomableImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image).resizable().scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in scale = max(1, min(lastScale * v, 6)) }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1 { withAnimation { offset = .zero; lastOffset = .zero } }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            guard scale > 1 else { return }
                            offset = CGSize(width: lastOffset.width + v.translation.width,
                                            height: lastOffset.height + v.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                        else { scale = 2; lastScale = 2 }
                    }
                }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.9))
                    .padding()
            }
            .accessibilityLabel("Close")
        }
    }
}

// MARK: - Composer

/// A pinned Slack-style composer: bordered rounded field, formatting bar, send.
struct SlackComposer: View {
    let placeholder: String
    @Binding var text: String
    var showFormatBar = true
    var canSendWhenEmpty = false   // allow send with no text (e.g. an image is attached)
    /// When non-empty, an "@" button appears that opens a mention picker (channel use). id + name.
    var mentionPeople: [(id: String, name: String)] = []
    let onSend: () -> Void

    @State private var showMentions = false

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !canSendWhenEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 0.5))
                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isEmpty ? Color.secondary : .white)
                        .frame(width: DS.controlSize, height: DS.controlSize)
                        .background(isEmpty ? Color(.tertiarySystemFill) : Color.accentColor,
                                    in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isEmpty)
            }
            if showFormatBar {
                HStack(spacing: 14) {
                    FormatBar(text: $text)
                    if !mentionPeople.isEmpty {
                        Button { showMentions = true } label: { Image(systemName: "at") }
                            .buttonStyle(.borderless).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityLabel("Mention someone")
                    }
                    Text("**bold** *italic* ~~strike~~").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .sheet(isPresented: $showMentions) {
            MentionPicker(people: mentionPeople) { name in text = Mentions.insert(name, into: text) }
        }
    }
}

// MARK: - Mention picker

/// A searchable list of who you can @-mention in a channel — "@everyone" pinned first, then every active
/// dispatcher. Picking one inserts "@name " into the composer. Reliable regardless of spaces in names.
struct MentionPicker: View {
    let people: [(id: String, name: String)]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [(id: String, name: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? people : people.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Button { onPick("everyone"); dismiss() } label: {
                    Label("everyone", systemImage: "megaphone.fill")
                        .foregroundStyle(AppColor.primary)
                }
                ForEach(filtered, id: \.id) { p in
                    Button { onPick(p.name); dismiss() } label: {
                        HStack(spacing: 10) {
                            Avatar(name: p.name, id: p.id, size: 26)
                            Text(p.name)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search dispatchers")
            .navigationTitle("Mention")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Channel header

/// A "# channel-name" header strip, Slack-style.
struct ChannelHeader: View {
    let name: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "number").font(.headline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.headline)
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }
}

```
