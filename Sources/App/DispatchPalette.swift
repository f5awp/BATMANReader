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
import UIKit

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

    // Calendar day-cell SURFACES — ADAPTIVE (light/dark), so they match the mockup in BOTH modes.
    // (A translucent tint over the background washed out badly in light mode.) One source of truth
    // for every calendar cell that has no vivid semantic fill.
    static let cellWorked = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.090, green: 0.137, blue: 0.227, alpha: 1)   // #17233a navy (mockup dark)
            : UIColor(red: 0.953, green: 0.961, blue: 0.973, alpha: 1)   // #f3f5f8 cool near-white (mockup light)
    })
    // OFF = the empty/rest state (§2b): a near-neutral tile clearly LIGHTER than ON navy in dark, and a
    // flat RECESSED gray in light. Differentiated from ON by value + lack of gloss, not a competing hue.
    static let cellOff = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.231, green: 0.255, blue: 0.322, alpha: 1)   // #3b4152 (clearly lighter than ON navy)
            : UIColor(red: 0.886, green: 0.894, blue: 0.914, alpha: 1)   // #e2e4e9 flat recessed
    })
    /// Dim number/label on OFF tiles (§2b): #8B93B5 dark / #8A8F98 light.
    static let cellOffText = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.545, green: 0.576, blue: 0.710, alpha: 1)   // #8b93b5
            : UIColor(red: 0.541, green: 0.561, blue: 0.596, alpha: 1)   // #8a8f98
    })
    // Blackout (§2d, option A): flat MATTE, un-glazed, slightly recessed — a lock glyph, NO red. The
    // absence of sheen (vs every glazed tradeable tile) is what signals "immovable". Reads the same in
    // light + dark. Tokens: fill, inset border, dim number/glyph.
    static let blackout = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.110, green: 0.114, blue: 0.129, alpha: 1)   // #1c1d21
            : UIColor(red: 0.824, green: 0.831, blue: 0.855, alpha: 1)   // #d2d4da
    })
    static let blackoutBorder = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.165, green: 0.173, blue: 0.188, alpha: 1)   // #2a2c30
            : UIColor(red: 0.761, green: 0.769, blue: 0.796, alpha: 1)   // #c2c4cb
    })
    static let blackoutNumber = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.420, green: 0.431, blue: 0.459, alpha: 1)   // #6b6e75
            : UIColor(red: 0.541, green: 0.561, blue: 0.596, alpha: 1)   // #8a8f98
    })
    /// "Keep" (protect this working shift) — a DARK green, distinct from the brighter `success`
    /// (accepted / optimal / done) so keeping a shift never reads the same as an accepted trade.
    static let keep = Color(red: 0.086, green: 0.322, blue: 0.157)   // ≈ #165228 dark green
    /// Drop shadow that lifts a day tile off the near-white page in LIGHT mode so the grouted grid reads;
    /// none in dark (tiles separate via the dark ground + glaze). (§9a)
    static let tileShadow = Color(UIColor { $0.userInterfaceStyle == .dark
        ? .clear : UIColor.black.withAlphaComponent(0.12) })

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
    static let keep      = AppColor.keep      // "Keep" working-shift protect — dark green (distinct from success)
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
        Section(title: "Day colors", items: [
            Item(swatch: .fill(AppColor.primary), name: "Working day",
                 meaning: "A day you're scheduled to work"),
            Item(swatch: .fill(WorkingIntentState.dontWantToWork.brickColor), name: "Trade away",
                 meaning: "A working day you want to give away"),
            Item(swatch: .fill(WorkingIntentState.mustWork.brickColor), name: "Keep",
                 meaning: "A working day you'll never trade away"),
            Item(swatch: .fill(OffIntentState.wantToWork.brickColor), name: "Want to work",
                 meaning: "An off day you'd pick up a shift on"),
            Item(swatch: .fill(OffIntentState.mustBeOff.brickColor), name: "Blackout / blacklisted",
                 meaning: "Slate — an off day you'll never work, or a shift type / region / desk / weekday you've blacklisted (never offered)"),
            Item(swatch: .fill(OffIntentState.neutralOpen.brickColor), name: "Open",
                 meaning: "An off day you're passively available — no strong preference"),
            Item(swatch: .fill(AppColor.vacation), name: "Vacation (VAC)",
                 meaning: "A day off on vacation — toggle \"Trade Picked Up\" if you traded into it"),
            Item(swatch: .fill(AppColor.neutral), name: "Neutral",
                 meaning: "Nothing marked for this day"),
        ]),
        Section(title: "On a day", items: [
            Item(swatch: .icon("a.circle.fill", AppColor.pending), name: "Availability (AM/PM/MID)",
                 meaning: "Gold pills on an off day — the shift types you'd pick up"),
            Item(swatch: .icon("xmark", AppColor.danger), name: "Blacked-out shift",
                 meaning: "A shift type you won't work on that day"),
            Item(swatch: .glyph("AM 82"), name: "Shift + desk",
                 meaning: "Your shift time and desk number on a working day"),
        ]),
        Section(title: "Trade quality & status", items: [
            Item(swatch: .fill(AppColor.success), name: "Optimal / accepted",
                 meaning: "Fewest people to cover — or an agreed trade"),
            Item(swatch: .fill(AppColor.pending), name: "Pending",
                 meaning: "Waiting on a reply"),
            Item(swatch: .fill(AppColor.danger), name: "Declined",
                 meaning: "Rejected, expired, or cancelled"),
            Item(swatch: .fill(AppColor.special), name: "Circular loop",
                 meaning: "A 3+ person loop where everyone covers someone"),
            Item(swatch: .icon("q.square.fill", AppColor.pending), name: "Qual swap (Q)",
                 meaning: "Needs a qualified \"bridge\" to slide onto the desk so an unqualified taker can cover"),
        ]),
        Section(title: "Markers", items: [
            Item(swatch: .icon("circle.fill", AppColor.heat), name: "Match available",
                 meaning: "Orange disc behind the date (the most visible marker) — someone wants to drop a shift you can work, or work a shift you want to trade, on this day"),
            Item(swatch: .icon("exclamationmark.circle.fill", AppColor.primary), name: "Watching",
                 meaning: "Blue “!”, top-left — you turned on Watch Day, so you'll be alerted the moment a match appears here"),
            Item(swatch: .icon("star.fill", AppColor.heat), name: "High-demand date",
                 meaning: "Orange star, top-right — an auto-marked high-demand date (holidays). A Midnight shift counts toward the night-before holiday it works into"),
            Item(swatch: .icon("star.fill", AppColor.milestone), name: "Personal milestone",
                 meaning: "Pink star, top-right — a protected personal date"),
            Item(swatch: .icon("note.text", AppColor.primary), name: "Note",
                 meaning: "Blue dot = public note · orange dot = private note — tap the day to read it"),
            Item(swatch: .glyph("🔥"), name: "Mutual intent",
                 meaning: "You both marked this exact day"),
            Item(swatch: .glyph("📖"), name: "Bookend",
                 meaning: "A pickup that attaches to the edge of your days off"),
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
        case .mustWork:              return BrickPalette.keep    // "Keep" — dark green, protect this shift
        case .wantToWork:            return BrickPalette.clear   // happy to work it
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

// MARK: - Ceramic tile fill (§1a / §2a: a real two-stop hue gradient, derived from the token)

extension Color {
    /// Shift a color's brightness (HSB) by `delta`, with a slight saturation bump so the darker stop
    /// reads deeper rather than muddy. Returns a DYNAMIC color that re-resolves `self` per trait — so a
    /// glazed tile follows light↔dark automatically instead of freezing to whatever mode it first rendered
    /// in (the "stuck light row after switching to dark" bug).
    func adjustBrightness(_ delta: CGFloat) -> Color {
        let ui = UIColor(self)
        return Color(uiColor: UIColor { traits in
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.resolvedColor(with: traits).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return UIColor(hue: h, saturation: min(s * 1.06, 1),
                           brightness: max(min(b + delta, 1), 0), alpha: a)
        })
    }
}

/// A genuine vertical two-tone gradient of the SAME token hue — lighter top → deeper/darker bottom
/// (~18–24% depth) — so glazed cells have real ceramic depth. `.dxGlaze()` sits on top for the wet sheen.
/// Derived from the token, never hardcoded per state. NOT for blackout (that stays flat matte, §2d).
///
/// Every stop is a DYNAMIC color: the base hue AND the depth are recomputed inside a `UIColor { traits }`
/// provider, so the gradient re-resolves on a light↔dark switch instead of baking to the call-time trait
/// (which left cells stuck in the previous mode).
func ceramicFill(_ base: Color) -> LinearGradient {
    let ui = UIColor(base)
    func stop(_ topLift: Bool) -> Color {
        Color(uiColor: UIColor { traits in
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.resolvedColor(with: traits).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            // Depth scales with saturation × brightness so a near-white tile gets only a whisper, a
            // saturated tile gets real depth, and an already-dark navy tile isn't crushed to black.
            let depth = 0.04 + 0.22 * s * b
            let delta = topLift ? min(0.07, depth * 0.5) : -depth   // top: slight lift · bottom: deeper
            return UIColor(hue: h, saturation: min(s * 1.06, 1),
                           brightness: max(min(b + delta, 1), 0), alpha: a)
        })
    }
    return LinearGradient(colors: [stop(true), stop(false)], startPoint: .top, endPoint: .bottom)
}

// MARK: - Info bubble

/// A small (i) button that opens a popover with an explanation — the app-wide way to attach help text
/// to a control or section header (replaces inline footers). Compact-adaptation keeps it a bubble on iPhone.
struct InfoBubble: View {
    let text: String
    @State private var show = false
    var body: some View {
        Button { show = true } label: {
            Image(systemName: "info.circle").font(.footnote).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show) {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("More info")
    }
}
