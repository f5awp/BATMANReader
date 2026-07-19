// DXSegmented.swift
// ─────────────────────────────────────────────────────────────────────────────
// The app's themed segmented control — one look for every tab strip:
//   • Trades:        Intents / Solutions / ECB
//   • Trade Inbox:   Intents / Search / ECB / Misc
//   • Trade Status:  Accepted / Pending / Denied / History   (semantic active color)
//   • Trade Settings / Welcome prefs: Profile / Trade Settings
//
// Native `Picker(.segmented)` can't take a glazed active tile or a semantic active
// color, so this is a custom control with the same binding contract. Depends only on
// `AppColor` / `DS` (from DispatchPalette.swift). Animates the selection.
//
// USE — drop-in for `Picker("", selection:).pickerStyle(.segmented)`:
//
//   // neutral active tile + palette-accent underline (Trades / Inbox / Settings):
//   DXSegmented(selection: $filter, options: [
//       .init(0, "Intents"), .init(1, "Search"), .init(2, "ECB \(ecbCount)"), .init(3, "Misc"),
//   ])
//   .padding(.horizontal)
//
//   // semantic active color (Trade Status): pass `color:` per value
//   DXSegmented(selection: $tab, options: [
//       .init(0, "Accepted"), .init(1, "Pending"), .init(2, "Denied"), .init(3, "History"),
//   ], color: { v in [0: AppColor.success, 1: AppColor.pending, 2: AppColor.danger][v] })
//
// Keep your existing switch/if on the bound value — only the picker view changes.

import SwiftUI

struct DXSegment<T: Hashable> {
    let value: T
    let label: String
    let badge: Int      // optional TOTAL count badge (0 = none) shown to the right of the label
    let newBadge: Int   // optional NEW/unread count (0 = none) — a small red bubble after the total
    init(_ value: T, _ label: String, badge: Int = 0, newBadge: Int = 0) {
        self.value = value; self.label = label; self.badge = badge; self.newBadge = newBadge
    }
}

struct DXSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [DXSegment<T>]
    /// Optional semantic active color per value. Return nil (default) for the neutral
    /// glazed tile + palette-accent underline.
    var color: (T) -> Color? = { _ in nil }

    @Namespace private var ns

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { i in
                let opt = options[i]
                let active = opt.value == selection
                let tint = color(opt.value)
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = opt.value }
                } label: {
                    // The label defines the size. The active tile is the label's BACKGROUND
                    // (never a free-floating sibling), so the RoundedRectangle can only fill
                    // the label's compact frame — it can't expand to eat the whole screen.
                    HStack(spacing: 5) {
                        Text(opt.label)
                            .font(.subheadline.weight(active ? .bold : .semibold))
                            .foregroundStyle(active ? .white : .secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        if opt.badge > 0 {
                            Text("\(min(opt.badge, 99))")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(active ? (tint ?? AppColor.primary) : .white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(active ? Color.white.opacity(0.95) : (tint ?? AppColor.primary), in: Capsule())
                        }
                        // NEW/unread → a single compact heat dot (not "N new" text, which packed the strip
                        // when several tabs had news). The total badge already carries the number; this dot
                        // just says "something in here needs attention".
                        if opt.newBadge > 0 {
                            Circle().fill(AppColor.heat).frame(width: 7, height: 7)
                                .accessibilityLabel("\(opt.newBadge) new")
                        }
                    }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if active {
                                activeBackground(tint: tint)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)   // hug content height — never grow tall
    }

    @ViewBuilder
    private func activeBackground(tint: Color?) -> some View {
        // One look everywhere: a solid colored pill. Semantic strips pass `tint`; everything else uses the
        // app accent. NO underline, NO border on the active tile. (§4, round 2.)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let fill = tint ?? AppColor.primary
        shape.fill(LinearGradient(colors: [fill.opacity(0.92), fill], startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.28), .clear],
                                               startPoint: .top, endPoint: .bottom)))
    }
}
