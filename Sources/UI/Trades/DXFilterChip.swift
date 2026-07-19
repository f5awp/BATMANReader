// DXFilterChip.swift
// The ONE filter-chip look used by every filter bar in the app (Find Trades, Suggested inbox,
// Dispatcher directory, day Trade List). Same visual + behavior everywhere; each surface supplies its
// own chip set. Active = solid app-accent + white; idle = neutral fill + primary text.

import SwiftUI

/// The chip's visual (icon · value · caret). Used as the label inside a Button, Menu, or NavigationLink so
/// it works for tap-to-sheet, tap-to-menu, and toggle chips alike.
@ViewBuilder
func dxFilterChipLabel(_ text: String, systemImage: String, active: Bool) -> some View {
    HStack(spacing: 4) {
        Image(systemName: systemImage).font(.caption2)
        Text(text).font(.caption.weight(.semibold)).lineLimit(1)
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.5)
    }
    .padding(.horizontal, 11).padding(.vertical, 7)
    .foregroundStyle(active ? .white : .primary)
    .background(active ? AppColor.primary : Color(.secondarySystemBackground), in: Capsule())
}

/// A horizontal, scrolling row of filter chips — the standard container.
struct DXFilterChipRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal).padding(.vertical, 6)
        }
    }
}

/// A stay-open specific-dates picker → a Set of ISO "yyyy-MM-dd" day strings. Used for the client-side
/// "Trade Date" / "Give-back Date" filters (Suggested), where the list is filtered in-memory by day.
struct DXDateFilterSheet: View {
    let title: String
    @Binding var isoDays: Set<String>
    var onApply: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<DateComponents>

    private static let iso: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    init(title: String, isoDays: Binding<Set<String>>, onApply: @escaping () -> Void = {}) {
        self.title = title; _isoDays = isoDays; self.onApply = onApply
        let cal = Calendar.current
        let comps = isoDays.wrappedValue.compactMap { Self.iso.date(from: $0) }
            .map { cal.dateComponents([.year, .month, .day], from: $0) }
        _picked = State(initialValue: Set(comps))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                MultiDatePicker("Dates", selection: $picked).frame(maxHeight: 360)
                Text("Only \(title.lowercased()) matching the tapped dates are shown. Leave empty for any date.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !picked.isEmpty {
                    ToolbarItem(placement: .cancellationAction) { Button("Clear") { picked = []; commit(); onApply() } }
                }
                ToolbarItem(placement: .confirmationAction) { DXCloseButton { commit(); onApply(); dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func commit() {
        let cal = Calendar.current
        isoDays = Set(picked.compactMap { cal.date(from: $0) }.map { Self.iso.string(from: $0) })
    }
}
