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
    // Distinct per-trader calendar themes (you are always `mineScheme` blue). Each
    // person's calendar reads in their own color: border = trades away, fill = takes.
    // Hues chosen to stay distinguishable (no teal/green, for colorblindness).
    static let traderThemes: [Color] = [
        peerScheme,                                    // red
        loopTrade,                                     // violet
        Color(red: 0.90, green: 0.52, blue: 0.10),     // orange
        Color(red: 0.80, green: 0.20, blue: 0.52),     // magenta
        Color(red: 0.60, green: 0.42, blue: 0.12),     // amber-brown
    ]
    // Day-marker circles, used identically on every calendar.
    static let highImpact = Color(red: 0.86, green: 0.65, blue: 0.12)    // gold — high-demand date
    static let personalDay = milestone                                  // pink — personal milestone
}

/// D1/F1: THE single stable per-worker calendar color, used by EVERY trade surface so the
/// same person reads the same color everywhere. You are always `mineScheme` (blue); each peer
/// gets a deterministic color from `traderThemes` keyed on their workerID — fixes the two-way
/// sheet that hardcoded blue/red. Deterministic (UTF8 byte sum, NOT the randomized
/// `String.hashValue`, which would change the color every launch).
enum TradeColors {
    static func stableIndex(_ workerID: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return workerID.utf8.reduce(0) { $0 &+ Int($1) } % count
    }
    static func forWorker(_ workerID: String, myID: String) -> Color {
        if workerID == myID { return BrickPalette.mineScheme }
        return BrickPalette.traderThemes[stableIndex(workerID, count: BrickPalette.traderThemes.count)]
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
