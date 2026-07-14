// DXType.swift
// ─────────────────────────────────────────────────────────────────────────────
// Exact type + spacing ramp from the mockup. Import this and use DXFont.* / DXSpace.*
// everywhere instead of ad-hoc .font(.title) / .padding() so the build matches 1:1.
//
// FONTS — the mockup's headings use ARCHIVO (heavy geometric). To match exactly:
//   1. Add Archivo-Black.ttf, Archivo-Bold.ttf, Archivo-SemiBold.ttf to the target.
//   2. Info.plist → "Fonts provided by application" → list the three filenames.
//   3. Flip `hasArchivo = true` below.
// Until then it falls back to San Francisco at the same sizes/weights (close, not identical).
// Body/number text stays system (SF) on purpose — that matches the mockup.

import SwiftUI

enum DXFont {
    static let hasArchivo = true           // Archivo static .ttf bundled + registered in Info.plist

    /// Big display: month titles, hero numbers. Mockup = Archivo Black / 800.
    static func display(_ size: CGFloat) -> Font {
        hasArchivo ? .custom("Archivo-Black", size: size) : .system(size: size, weight: .heavy)
    }
    /// Section / card headings. Mockup = Archivo Bold / 800.
    static func heading(_ size: CGFloat) -> Font {
        hasArchivo ? .custom("Archivo-Bold", size: size) : .system(size: size, weight: .bold)
    }

    // ── System text ramp (unchanged font, exact sizes/weights from the mockup) ──
    static let monthTitle   = display(28)                                   // "July 2026"
    static let dayNumber    = Font.system(size: 16, weight: .bold)          // date (mockup 14 + 2px)
    static let dayNote      = Font.system(size: 10, weight: .bold)          // shift/desk (mockup 8 + 2px)
    static let personName   = Font.system(size: 16, weight: .semibold)      // "Lee, Ervin"
    static let personSub    = Font.system(size: 12).italic()                // "Testing…."
    static let sectionLabel = Font.system(size: 10, weight: .bold)          // "NEEDS YOUR REPLY" (+ tracking below)
    static let badge        = Font.system(size: 10, weight: .bold)
    static let tabLabel     = Font.system(size: 11, weight: .semibold)
}

extension Text {
    /// Uppercase section label with the mockup's letter-spacing.
    func dxSectionLabel() -> some View {
        self.font(DXFont.sectionLabel).tracking(0.6).foregroundStyle(.secondary)
    }
}

/// Spacing ramp from the mockup (points). Use these instead of literals.
enum DXSpace {
    static let cellGap: CGFloat      = 4    // gap between calendar day cells (mockup)
    static let cellRadius: CGFloat   = 7    // day-cell corner radius (pass to .dxGlaze(radius:))
    // Shared day-cell metrics — the ONE place cell SHAPE is defined. Both IntentCalendarView
    // (Home) and ShiftSelectCalendar (Trades) read these so the grid can never drift again.
    static let cellNumberH: CGFloat  = 19   // fits the 16pt number (mockup 14 + 2px)
    static let cellLabelH: CGFloat   = 18   // FIXED content-row height (fits the 10pt shift/desk + A·P·M pills) → every cell identical
    static let cellVPad: CGFloat     = 6    // ~7pt vertical padding (§1d)
    static let cellMarker: CGFloat   = 16   // marker / today disc diameter
    static let cardRadius: CGFloat   = 16   // cards / sheets
    static let controlRadius: CGFloat = 10  // icon buttons, chips
    static let screenH: CGFloat      = 16   // screen horizontal inset
    static let rowV: CGFloat         = 9    // vertical padding inside rows
    static let sectionGap: CGFloat   = 18   // between sections
}
