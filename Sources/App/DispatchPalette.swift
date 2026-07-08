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
    // ── Tier 1 · semantic ────────────────────────────────────────────────
    static let primary   = Color(red: 0.16, green: 0.43, blue: 0.88)  // blue — actions, links, selection, "you", info
    static let success   = Color(red: 0.20, green: 0.66, blue: 0.33)  // green — accepted, kept, authorized, optimal, done
    static let pending   = Color(red: 0.90, green: 0.63, blue: 0.11)  // amber — waiting, caution, "want to work"
    static let danger    = Color(red: 0.84, green: 0.24, blue: 0.22)  // red — declined, error, destructive
    static let heat      = Color(red: 0.95, green: 0.45, blue: 0.16)  // orange — demand / urgency ONLY
    static let special   = Color(red: 0.49, green: 0.33, blue: 0.83)  // violet — multi-way / circular / trade-away
    static let milestone = Color(red: 0.89, green: 0.35, blue: 0.63)  // pink — protected personal date (rare)
    static let neutral   = Color(.systemGray)                          // cancelled / inert / no intent

    // Cooler off-day states (kept distinct from worked-day hues).
    static let locked      = Color(red: 0.29, green: 0.32, blue: 0.52) // slate — "must be off" (locked)
    static let passiveOpen = Color(red: 0.45, green: 0.53, blue: 0.60) // faded slate-blue — passively open
    static let vacation    = Color(red: 0.11, green: 0.60, blue: 0.55) // teal — a day OFF on vacation

    /// Your schedule reads in the action/"you" blue on every trade surface.
    static var mine: Color { primary }

    // ── Tier 2 · categorical (identity only — assign NO meaning) ──────────
    /// Evenly spaced, equal-weight hues for avatars and per-seat trade colors. Index 0 is
    /// unused for "you" (you're always `mine`/blue); peers cycle from index 1 so a peer is
    /// never the danger red or success green by coincidence of meaning.
    static let categorical: [Color] = [
        primary,                                        // 0 — blue (you)
        Color(red: 0.85, green: 0.30, blue: 0.34),      // 1 — red
        Color(red: 0.93, green: 0.55, blue: 0.16),      // 2 — orange
        Color(red: 0.24, green: 0.64, blue: 0.36),      // 3 — green
        special,                                        // 4 — violet
        Color(red: 0.82, green: 0.30, blue: 0.55),      // 5 — magenta
        Color(red: 0.13, green: 0.62, blue: 0.60),      // 6 — teal
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
            Item(swatch: .fill(OffIntentState.wantToWork.brickColor), name: "Want to work",
                 meaning: "An off day you'd pick up a shift on"),
            Item(swatch: .fill(WorkingIntentState.mustWork.brickColor), name: "Blackout (working)",
                 meaning: "A working day you'll never trade away"),
            Item(swatch: .fill(OffIntentState.mustBeOff.brickColor), name: "Must be off",
                 meaning: "An off day you'll never work"),
            Item(swatch: .fill(OffIntentState.neutralOpen.brickColor), name: "Open",
                 meaning: "Passively available — no strong preference"),
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
