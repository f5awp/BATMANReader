// DXMessagingDock.swift
// ─────────────────────────────────────────────────────────────────────────────
// Drop-in replacement for the top-of-home icon buttons (`MessagingDock`).
// Same bindings, init, stores, badges, taps, and Menu as the original — the ONLY
// change is presentation: each button is now the glazed squircle tile
// (`.dxControlTile()` from DXMosaicIntegration.swift).
//
// APPLY (same pattern as AppTopBar):
//   1. Add this file to the target.
//   2. DELETE the existing `struct MessagingDock { … }` from ContentView.swift
//      (it's a duplicate declaration otherwise — the target won't compile until
//      one is removed). Everything that constructs MessagingDock(showInbox:…)
//      keeps working unchanged.
//
// Depends on: DXMosaicIntegration.swift (for `.dxControlTile()` + DS/AppColor),
// and the app's existing stores (MessagingStore, TradeHistoryStore,
// ECBAccountingStore, DashboardCounts) — all already in the project.

import SwiftUI

struct MessagingDock: View {
    @Binding var showInbox: Bool
    @Binding var showChannel: Bool
    @Binding var showSettings: Bool          // the single unified Settings (opens the Trade tab)
    @Binding var showColorKey: Bool          // Colors & Legend (⋯ menu)
    @Binding var showDashboard: Bool         // trade-status breakdown (⋯ menu)
    @Binding var showECB: Bool               // ECB Accounting ledger — its own tile
    private var store = MessagingStore.shared
    private var dms = DirectMessageStore.shared
    private var history = TradeHistoryStore.shared

    init(showInbox: Binding<Bool>, showChannel: Binding<Bool>,
         showSettings: Binding<Bool>, showColorKey: Binding<Bool>,
         showDashboard: Binding<Bool>, showECB: Binding<Bool>) {
        _showInbox = showInbox; _showChannel = showChannel
        _showSettings = showSettings; _showColorKey = showColorKey
        _showDashboard = showDashboard; _showECB = showECB
    }

    /// Active-trades badge for the Inbox: agreed-in-app (accepted, awaiting the schedule) + still-negotiating
    /// (pending). Loops are deduped so a circular trade counts ONCE. Live via @Observable stores.
    private var activeTradesBadge: Int {
        let c = DashboardCounts.from(requests: MessagingStore.dedupeLoops(store.requests), responses: store.responses,
                                     unread: store.pendingIncoming.count, pendingLedger: history.pendingCount)
        return c.accepted + c.pending
    }

    var body: some View {
        // Four controls: Inbox · Channel · ECB · ⋯. The ⋯ menu holds Trade History, Colors & Legend,
        // and the single Settings entry (opens the Trade tab by default).
        HStack(spacing: DS.s) {
            iconButton("tray.full.fill", label: "Inbox",
                       badge: activeTradesBadge, badgeColor: AppColor.danger) { showInbox = true }
            iconButton("megaphone.fill", label: "Channels & Messages",
                       badge: store.unreadBroadcastCount + dms.totalUnread,
                       badgeColor: AppColor.primary) { showChannel = true }
            iconButton("banknote.fill", label: "ECB Accounting",
                       badge: ECBAccountingStore.shared.pendingConfirmations.count,
                       badgeColor: AppColor.pending) { showECB = true }
            Menu {
                Button { showDashboard = true } label: { Label("Trade History", systemImage: "clock.arrow.circlepath") }
                Button { showColorKey = true } label: { Label("Colors & Legend", systemImage: "paintpalette") }
                Divider()
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            } label: { iconLabel("ellipsis") }
            .buttonStyle(.plain)
            .accessibilityLabel("More")
        }
    }

    private func iconButton(_ icon: String, label: String, badge: Int = 0,
                            badgeColor: Color = .clear, action: @escaping () -> Void) -> some View {
        Button(action: action) { iconLabel(icon, badge: badge, badgeColor: badgeColor) }
            .buttonStyle(.plain)
            .accessibilityLabel(badge > 0 ? "\(label), \(badge)" : label)
    }

    /// The one uniform icon button — now the glazed squircle tile. Badge logic unchanged.
    private func iconLabel(_ icon: String, badge: Int = 0, badgeColor: Color = .clear) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: DS.controlSize, height: DS.controlSize)
            .dxControlTile()                       // ← glazed tile (was flat tertiarySystemFill)
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
