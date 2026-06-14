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
    static let dsCardTitle = Font.subheadline.weight(.semibold) // card headlines, names
    static let dsCardMeta  = Font.caption2                       // subtitles, statuses
    static let dsChip      = Font.caption.weight(.semibold)      // day chips
    static let dsBadge     = Font.caption2.weight(.heavy)        // pills / counts
    static let dsLabel     = Font.caption2.weight(.bold)         // small section labels
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
    // Trade-calendar signature colors. You read blue (your schedule); the
    // counterparty reads red (theirs). The mini-calendars tint worked days faintly
    // and trade cells more strongly in these hues, so a swapped shift looks like it
    // belongs to whichever schedule it lands on.
    static let mineScheme = Color(red: 0.13, green: 0.45, blue: 0.92)    // your schedule blue
    static let peerScheme = Color(red: 0.84, green: 0.25, blue: 0.28)    // their schedule red
    // Day-marker circles, used identically on every calendar.
    static let highImpact = Color(red: 0.86, green: 0.65, blue: 0.12)    // gold — high-demand date
    static let personalDay = milestone                                  // pink — personal milestone
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
