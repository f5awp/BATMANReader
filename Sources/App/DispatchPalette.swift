// DispatchPalette.swift
// Semantic colors mirroring the airline dispatch "brick" notification legend, so
// the app's intent overlays and trade-status badges read the way dispatchers
// already expect from WSI Fusion / Desk Flight Progress.
//
//   green   = good / available / done        purple = change (trade away)
//   yellow  = caution / pending              cyan   = info / unread
//   orange  = alert / high-demand            red    = stop / critical
//   pink    = milestone (rejected hue)       gray   = neutral

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

enum BrickPalette {
    static let clear     = Color(red: 0.26, green: 0.74, blue: 0.30)  // bright green
    static let change    = Color(red: 0.62, green: 0.27, blue: 0.80)  // purple/magenta
    static let info      = Color(red: 0.18, green: 0.68, blue: 0.90)  // cyan
    static let caution   = Color(red: 0.85, green: 0.64, blue: 0.08)  // deeper yellow-gold (readable on light)
    static let warning   = Color(red: 0.95, green: 0.55, blue: 0.15)  // orange
    static let critical  = Color(red: 0.86, green: 0.21, blue: 0.21)  // red
    static let milestone = Color(red: 0.95, green: 0.40, blue: 0.70)  // pink
    static let neutral   = Color.gray
    // Distinct off-day hues so off intents never collide with worked-day intents.
    // availableOff is amber/gold (colorblind-safe — readable for red-green vision).
    static let availableOff = Color(red: 0.93, green: 0.69, blue: 0.13)  // amber — ACTIVE "want to work"
    static let openOff      = Color(red: 0.42, green: 0.55, blue: 0.62)  // muted slate-blue — PASSIVE "open/available", faded
    static let lockedOff    = Color(red: 0.27, green: 0.30, blue: 0.55)  // slate
    static let vacation     = Color(red: 0.13, green: 0.59, blue: 0.53)  // teal — a day OFF on vacation (distinct). S-UIUX-NEW
    // Trade-calendar signature colors. You read blue (your schedule); the
    // counterparty reads red (theirs). The mini-calendars tint worked days faintly
    // and trade cells more strongly in these hues, so a swapped shift looks like it
    // belongs to whichever schedule it lands on.
    static let mineScheme = Color(red: 0.13, green: 0.45, blue: 0.92)    // your schedule blue
    static let peerScheme = Color(red: 0.84, green: 0.25, blue: 0.28)    // their schedule red
    static let loopTrade  = Color(red: 0.48, green: 0.31, blue: 0.84)    // violet
    // POSITIONAL per-seat trade colors (you are always `mineScheme` blue). Seat order, per the
    // user spec: 2nd person red, 3rd orange, 4th green, then violet/magenta for any extras.
    static let traderThemes: [Color] = [
        peerScheme,                                    // seat 1 (2nd person) — red
        Color(red: 0.90, green: 0.52, blue: 0.10),     // seat 2 (3rd person) — orange
        Color(red: 0.20, green: 0.62, blue: 0.34),     // seat 3 (4th person) — green
        loopTrade,                                     // seat 4 — violet
        Color(red: 0.80, green: 0.20, blue: 0.52),     // seat 5 — magenta
    ]
    // Day-marker circles, used identically on every calendar.
    static let highImpact = Color(red: 0.86, green: 0.65, blue: 0.12)    // gold — high-demand date
    static let personalDay = milestone                                  // pink — personal milestone
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
