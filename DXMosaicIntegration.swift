// DXMosaicIntegration.swift
// ─────────────────────────────────────────────────────────────────────────────
// "THE SCHEDULE IS THE MOSAIC" — the brand expressed through DX Trader's OWN two
// assets (its color language + its calendar grid), not a photograph.
//
// What this gives you (all drawn in code from your existing DispatchPalette — no
// image assets required for the core system):
//   • DXPaletteStripe  — the signature tile ribbon, rendered from AppColor tokens.
//                        Recolorable, crisp at any size, and it teaches the legend.
//   • .dxGlaze()       — a view modifier that turns a flat day cell into a glazed
//                        ceramic tile (top highlight + inner shadow). Additive:
//                        drop it on the cell background; nothing else changes.
//   • AppTopBar        — compact drop-in: glazed avatar tile + identity + the stripe
//                        as a 4pt signature rule. ~28pt shorter than the photo band.
//   • DXMonthHeader    — info-forward: month + a live "shifts · off · to-trade" line.
//   • DXPlanesEmptyState — the plane motif, reserved for Trades / empty / loading.
//
// The only image asset still used is `dxPlanes` (transparent), and ONLY in the
// empty-state / Trades context. The top bar and calendar need no images at all.
//
// Design-system contract: every color is an AppColor token (one hue = one meaning);
// every framed shape is a RoundedRectangle at DS radii (no capsules / circles);
// all bindings, inits, and store calls below are preserved verbatim.
//
// iPhone + iPad, portrait + landscape: sizing is size-class driven, no fixed widths.

import SwiftUI

// MARK: - Signature palette stripe (brand, from the color language)

/// The mosaic signature: a row of glazed tiles in the app's semantic hues. Because it
/// IS the palette, it doubles as an ambient legend. Varying flex weights echo the
/// hand-cut tile wall without any photo. Height drives the "presence" of the brand.
struct DXPaletteStripe: View {
    var height: CGFloat = 4
    var radius: CGFloat = 2

    // Ordered around the wheel for harmony; each is a real semantic token.
    private static let tiles: [(Color, CGFloat)] = [
        (AppColor.primary,  1.1),   // you
        (AppColor.vacation, 0.8),   // vacation
        (AppColor.success,  1.3),   // keep
        (AppColor.pending,  0.9),   // want / caution
        (AppColor.heat,     1.1),   // demand
        (AppColor.danger,   0.85),  // declined
        (AppColor.milestone,1.0),   // personal
        (AppColor.special,  1.2),   // trade / multi-way
    ]

    var body: some View {
        // Widths are PROPORTIONAL to each tile's weight, computed from the available width. (Previously
        // each tile used `.frame(maxWidth: .infinity)` + a differing `.layoutPriority`, which makes an
        // HStack hand ALL the width to the single highest-priority flexible child — so the whole stripe
        // rendered as one solid band, `success` green. Explicit widths fix that and keep the varied look.)
        let gap: CGFloat = 3
        let total = Self.tiles.reduce(0) { $0 + $1.1 }
        GeometryReader { geo in
            let avail = max(0, geo.size.width - gap * CGFloat(Self.tiles.count - 1))
            HStack(spacing: gap) {
                ForEach(Array(Self.tiles.enumerated()), id: \.offset) { _, tile in
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(tile.0)
                        .frame(width: avail * tile.1 / total)
                        .overlay(   // glaze
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(LinearGradient(colors: [.white.opacity(0.32), .clear],
                                                     startPoint: .top, endPoint: .bottom))
                        )
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Ceramic glaze (turns any fill into a tile)

private struct DXGlaze: ViewModifier {
    var radius: CGFloat = 8
    /// 0 = flat matte (day cells — matches the mockup), 1 = full glossy dome (small controls).
    var intensity: CGFloat = 0.35
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let i = max(0, min(1, intensity))
        content
            // MATTE ceramic: a thin top highlight that fades fast, and only a whisper of
            // bottom shade. No big top-to-bottom sweep — that read as glossy plastic.
            .overlay(
                shape.fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.10 + 0.22 * i), location: 0.0),
                    .init(color: .white.opacity(0.02 + 0.05 * i), location: 0.16),
                    .init(color: .clear,                          location: 0.5),
                    .init(color: .black.opacity(0.06 + 0.16 * i), location: 1.0),
                ], startPoint: .top, endPoint: .bottom))
            )
            // hairline rim: brighter along the top edge, neutral elsewhere (like the
            // mockup's 1px border), no dark bottom edge unless intensity is high.
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [
                    .white.opacity(0.16 + 0.24 * i),
                    .white.opacity(0.05),
                    .black.opacity(0.05 + 0.16 * i),
                ], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            )
            .clipShape(shape)
    }
}

extension View {
    /// Give a filled squircle subtle ceramic depth. DEFAULT is MATTE (intensity 0.35) —
    /// use this on day cells and cards; it matches the mockup's flat tiles, NOT a glossy
    /// dome. Pass `intensity: 0.9` only for small controls that should look domed.
    /// Apply as the LAST modifier on the fill/background layer, with the SAME radius the
    /// cell is clipped to. In `IntentCalendarView.cell`: `.dxGlaze(radius: R)` on the fill.
    func dxGlaze(radius: CGFloat = 8, intensity: CGFloat = 0.35) -> some View {
        modifier(DXGlaze(radius: radius, intensity: intensity))
    }
}

// MARK: - App top bar (drop-in replacement for ContentView.swift's AppTopBar)

/// Compact header: a glazed avatar tile, identity, the utilities dock, and the palette
/// stripe as a 4pt signature rule beneath. No photo band — reclaims vertical space and
/// ties the brand to the color system. Bindings / init / logic unchanged.
struct AppTopBar: View {
    @Binding var showInbox: Bool
    @Binding var showChannel: Bool
    @Binding var showTradeSettings: Bool
    @Binding var showAppSettings: Bool
    @Binding var showDashboard: Bool
    @Binding var showECB: Bool
    private var settings = SettingsManager.shared

    @Environment(\.horizontalSizeClass) private var hClass

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

        VStack(spacing: DS.s) {
            HStack(spacing: DS.s + 2) {
                Avatar(name: name, id: settings.username, size: 30)   // your Avatar atom, unchanged
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !status.isEmpty {
                        Text(status).font(.caption2).italic().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: DS.s)
                MessagingDock(showInbox: $showInbox, showChannel: $showChannel,
                              showTradeSettings: $showTradeSettings, showAppSettings: $showAppSettings,
                              showDashboard: $showDashboard, showECB: $showECB)
            }
            .padding(.horizontal, hClass == .regular ? DS.l : DS.m)
            .padding(.top, DS.s)

            if DXBrand.enabled {
                DXPaletteStripe(height: 4)
                    .padding(.horizontal, hClass == .regular ? DS.l : DS.m)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))   // §11: solid, no .bar translucency and NO hairline divider
    }
}

// MARK: - Month divider (drop-in for IntentCalendarView's Section header)

/// Info-forward month header: the month, plus a live one-line summary that turns the
/// divider into a glance-able status. Counts come straight from the stores you already
/// have — swap the sample values for real ones (see `counts(for:)` note below).
struct DXMonthHeader: View {
    let title: String
    var shifts: Int = 0
    var off: Int = 0
    var toTrade: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: DS.m) {
                Text(title).font(DXFont.heading(25))   // Archivo (mockup: 800/25px), was plain SF title3
                Spacer(minLength: 0)
            }
            HStack(spacing: DS.m) {
                legendDot(AppColor.success, "\(shifts) shifts")
                legendDot(AppColor.locked,  "\(off) off")
                legendDot(AppColor.special, "\(toTrade) to trade")
            }
            .font(.dsBadge)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))   // opaque — required for pinned headers
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}
// Wiring the counts (in IntentCalendarView, where `shifts` and `intents` are in scope):
//   let worked  = shifts.filter { !$0.isOff && isSameMonth($0.date, month) }.count
//   let offDays = shifts.filter {  $0.isOff && isSameMonth($0.date, month) }.count
//   let trading = intents.tradeAwayCount(inMonth: month)   // however you count seeking days
//   DXMonthHeader(title: Self.monthF.string(from: month),
//                 shifts: worked, off: offDays, toTrade: trading)

// MARK: - Plane empty / loading state (the ONE place planes live)

/// Brand delight reserved for movement contexts — the Trades tab empty view, a first-run
/// calendar, or a loading moment. Uses the transparent `dxPlanes` asset only.
struct DXPlanesEmptyState: View {
    var title: String = "No open trades yet"
    var subtitle: String = "Mark a shift to trade away to get started"

    var body: some View {
        VStack(spacing: DS.s) {
            Image("dxPlanes")
                .resizable().scaledToFit()
                .frame(width: 132)
                .opacity(0.92)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(DS.xl)
    }
}

// MARK: - Trade atoms (push the mosaic into cards)

/// A seat rendered as a glazed tile instead of a flat dot — ties trade cards to the
/// mosaic. `color` comes straight from `TradeColors.color(forParticipant:…)` /
/// `BrickPalette.mineScheme`, so meaning is unchanged.
/// In `CompactSwapCard` / `TradeParticipantLines`, replace `Circle().fill(peerColor)
/// .frame(width: 9, height: 9)` with `DXSeatTile(color: peerColor)`.
struct DXSeatTile: View {
    let color: Color
    var size: CGFloat = 16
    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.35), .clear, .black.opacity(0.18)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .accessibilityHidden(true)
    }
}

/// A glazed day chip for the "You get / They get" and participant day lists. Use in place
/// of the plain `Text(DayFmt.list(days))` runs on a filled background.
struct DXDayChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(.primary)
            .padding(.horizontal, DS.s)
            .padding(.vertical, 3)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            )
    }
}

/// The small white-on-translucent corner label that tags a calendar day's intent (TRADE / KEEP /
/// BLACKOUT / WANT). Shared by every calendar so intents read identically — a pill, never a line/dot.
struct DXIntentPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 7, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.5)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityLabel(text)
    }
}

// MARK: - Mosaic photo hero (real ceramic photo — cosmetic surfaces only)

/// The one place the REAL mosaic photograph belongs: big cosmetic moments — the Welcome
/// hero, a launch splash, an ECB balance backdrop. NOT on data surfaces (those stay on
/// the drawn `DXPaletteStripe`). Needs the `mosaicBand` image in Assets.xcassets.
/// Usage in `WelcomeView.hero`: `DXMosaicHero(title: "DX Trader", subtitle: "DISPATCH SHIFT TRADING")`.
struct DXMosaicHero: View {
    var title: String = "DX Trader"
    var subtitle: String = "DISPATCH SHIFT TRADING"
    var height: CGFloat = 184

    var body: some View {
        ZStack(alignment: .bottom) {
            Image("mosaicBand")
                .resizable().scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.28), .black.opacity(0.42),
                                    Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
            Image("dxPlanes")
                .resizable().scaledToFit()
                .frame(width: 128)
                .offset(y: -46)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                .accessibilityHidden(true)
            VStack(spacing: 2) {
                Text(title).font(.system(size: 26, weight: .heavy))
                Text(subtitle).font(.caption).fontWeight(.semibold).tracking(2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding(.bottom, 12)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
    }
}

// MARK: - Headers, badges, cards, rows, bubbles (build-ready atoms)

/// A bold brand header: big Archivo-weight title + the palette stripe. Drop above a
/// segmented picker (Inbox / Trade Status / Settings / Finder) for the mockups' look.
/// Keep the view's `.navigationTitle("")` + `.navigationBarTitleDisplayMode(.inline)`.
struct DXBrandHeader: View {
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 22, weight: .heavy))
            DXPaletteStripe(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, DS.s)
        .padding(.bottom, DS.m)
    }
}

/// Glazed status pill. Map your status → (text, color) once (see apply guide), e.g.
/// accepted→success, pending→pending, declined/cancelled→danger, countered→primary,
/// circular→special. Replaces the old `StatusBadge`.
struct DXStatusBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, DS.s)
            .padding(.vertical, 3)
            .background(color.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: DS.pillRadius, style: .continuous))
    }
}

/// The standard card surface for trade / inbox / register cards. Replaces ad-hoc
/// `.background(.bar, in: RoundedRectangle(...))`.
private struct DXCard: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }
}
extension View {
    func dxCard(padding: CGFloat = DS.cardPadding) -> some View { modifier(DXCard(padding: padding)) }
}

/// One chat message. `mine` = blue glazed / trailing; else the neutral surface / leading.
/// In `ThreadView`, render each message with `DXChatBubble(text: msg.body, mine: msg.fromID == myID)`.
struct DXChatBubble: View {
    let text: String
    let mine: Bool
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(mine ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if mine {
                    LinearGradient(colors: [AppColor.primary.opacity(0.92), AppColor.primary],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: 264, alignment: mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

/// A settings / register row: a tinted icon tile + title + trailing content (a value,
/// chevron, or Toggle). Toggles: add `.tint(AppColor.success)`.
struct DXIconRow<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: DS.m) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).font(.body)
            Spacer(minLength: DS.s)
            trailing()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Glazed control tile (icon buttons: MessagingDock, header chips)

/// The app's one icon-button surface, glazed: a squircle at DS.controlRadius with a top
/// highlight, faint inner shadow, and hairline rim. Apply to an Image already framed to
/// `DS.controlSize`. Replaces `.background(Color(.tertiarySystemFill), in: RoundedRectangle(...))`.
private struct DXControlTile: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.10)],
                                             startPoint: .top, endPoint: .bottom)))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        )
    }
}
extension View {
    func dxControlTile() -> some View { modifier(DXControlTile()) }
}

// MARK: - Close button (replaces sheet/form "Done" toolbar buttons)

/// A small circular ✕ close button — the standard dismiss affordance for every sheet/form (replaces the
/// old text "Done" buttons). Pass the dismiss/close action.
struct DXCloseButton: View {
    let action: () -> Void
    var body: some View {
        // Just the glyph — the toolbar supplies the single circular chrome. (No own circle, so it doesn't
        // double-ring inside the toolbar's button background.)
        Button(action: action) {
            Image(systemName: "xmark").font(.footnote.weight(.bold))
        }
        .accessibilityLabel("Close")
    }
}

// MARK: - Brand switch

enum DXBrand {
    /// Master on/off for the whole mosaic system.
    static let enabled = true
}
