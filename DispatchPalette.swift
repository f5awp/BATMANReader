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

enum BrickPalette {
    static let clear     = Color(red: 0.26, green: 0.74, blue: 0.30)  // bright green
    static let change    = Color(red: 0.62, green: 0.27, blue: 0.80)  // purple/magenta
    static let info      = Color(red: 0.18, green: 0.68, blue: 0.90)  // cyan
    static let caution   = Color(red: 0.95, green: 0.78, blue: 0.20)  // yellow
    static let warning   = Color(red: 0.95, green: 0.55, blue: 0.15)  // orange
    static let critical  = Color(red: 0.86, green: 0.21, blue: 0.21)  // red
    static let milestone = Color(red: 0.95, green: 0.40, blue: 0.70)  // pink
    static let neutral   = Color.gray
    // Distinct off-day hues so off intents never collide with worked-day intents.
    static let availableOff = Color(red: 0.00, green: 0.68, blue: 0.62)  // teal
    static let lockedOff    = Color(red: 0.27, green: 0.30, blue: 0.55)  // slate
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
    /// Calendar fill hue for an off day with this intent.
    var brickColor: Color {
        switch self {
        case .wantToWork:  return BrickPalette.availableOff // teal — distinct from worked "want to work"
        case .mustBeOff:   return BrickPalette.lockedOff     // slate — distinct from worked "keep"
        case .neutralOpen: return BrickPalette.neutral
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
