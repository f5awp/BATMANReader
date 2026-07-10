// SlackKit.swift
// Slack-style building blocks for the trade channel + inbox: initials avatars,
// a message row (avatar · name · time · markdown body · inline actions), and a
// pinned composer with a formatting bar. Presentation only — the messaging data
// flow in MessagingStore is unchanged.

import SwiftUI
import Lottie

// MARK: - Animated loader (Lottie)

/// Reusable looping Lottie loader that swaps light/dark by color scheme. Used for the launch
/// overlay and the "Searching for trades" indicator. Falls back to a spinner if a file is missing.
struct AnimatedLoader: View {
    @Environment(\.colorScheme) private var scheme
    /// Optional square cap. nil = fill the container; otherwise scales to fit within maxSize.
    var maxSize: CGFloat? = nil
    var body: some View {
        let name = scheme == .dark ? "dx-loading-dark" : "dx-loading-light"
        Group {
            if LottieAnimation.named(name) != nil {
                LottieView(animation: .named(name)).looping()
            } else {
                ProgressView().controlSize(.large)   // graceful fallback if the JSON isn't bundled
            }
        }
        .aspectRatio(contentMode: .fit)                 // scale to fit the area it's placed in
        .frame(maxWidth: maxSize, maxHeight: maxSize)
    }
}

// MARK: - Character counter (F3)

/// A compact "used/limit" counter that turns amber near the limit and red over it.
/// Logic lives in the pure `CharLimit` (testable); this is presentation only.
struct CharCounter: View {
    let text: String
    let limit: Int
    var body: some View {
        let s = CharLimit.state(text, limit: limit)
        Text("\(s.used)/\(limit)")
            .font(.caption2)
            .foregroundStyle(s.over ? AppColor.danger : (s.nearLimit ? AppColor.pending : Color.secondary))
            .monospacedDigit()
            .accessibilityLabel("\(max(0, s.remaining)) characters remaining")
    }
}

// MARK: - Name + status (A7/B8)

/// A person's name with their current status broadcast in italics underneath, shown
/// wherever a name appears in trade views. Status looked up via `participantStatus`.
/// Renders just the name when there's no status. SPEC U-GLOBAL-3.
struct NameWithStatus: View {
    let id: String
    var name: String? = nil
    var nameFont: Font = .subheadline.weight(.semibold)
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // 🤖 marks a peer who isn't on the app yet (no active profile) → can't be messaged.
            Text((name ?? participantName(id)) + botSuffix(id)).font(nameFont)
            if let status = participantStatus(id) {
                Text(status).font(.caption2).italic()
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

// MARK: - Style helpers

enum SlackStyle {
    /// Avatar palette — identity only (Tier 2). Draws from the app's single categorical ramp so
    /// person colors match the trade-seat colors and nothing invents its own hues.
    static let palette: [Color] = AppColor.categorical

    /// Deterministic color from an id (stable across launches).
    static func color(for id: String) -> Color {
        guard !id.isEmpty else { return .gray }
        let sum = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    /// Up to two initials from a "Last, First" or "First Last" name.
    static func initials(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: ",", with: " ")
        let letters = cleaned.split(separator: " ").prefix(2).compactMap { $0.first }
        let s = letters.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

// MARK: - Avatar

struct Avatar: View {
    let name: String
    let id: String
    var size: CGFloat = 36

    var body: some View {
        Text(SlackStyle.initials(name))
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(SlackStyle.color(for: id), in: RoundedRectangle(cornerRadius: size * 0.24))
    }
}

// MARK: - Message row

/// One Slack-style message: avatar gutter, then name + meta + timestamp on the
/// header line (with inline `actions` on the right), then the markdown body.
struct SlackMessageRow<Actions: View>: View {
    let name: String
    let authorID: String
    let timestamp: Date
    let message: String
    var meta: (text: String, color: Color)? = nil
    var status: String? = nil          // E2: the author's status, shown to the RIGHT of their name
    var avatarSize: CGFloat = 36
    @ViewBuilder var actions: () -> Actions

    init(name: String, authorID: String, timestamp: Date, message: String,
         meta: (text: String, color: Color)? = nil, status: String? = nil, avatarSize: CGFloat = 36,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.name = name; self.authorID = authorID; self.timestamp = timestamp
        self.message = message; self.meta = meta; self.status = status
        self.avatarSize = avatarSize; self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: name, id: authorID, size: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.subheadline.weight(.semibold))
                    if let status, !status.isEmpty {
                        Text(status).font(.caption2).italic().foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let meta {
                        Text(meta.text).font(.caption2.weight(.medium)).foregroundStyle(meta.color)
                    }
                    Text(timestamp, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    actions()
                }
                if !message.isEmpty {
                    mdText(message).font(.subheadline).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Legend (shared color key — one comprehensive source, two presentations)

/// A single legend swatch (fill / border / SF-symbol / emoji), sized to align in rows.
struct LegendSwatch: View {
    let swatch: AppLegend.Swatch
    var size: CGFloat = 22
    var body: some View {
        switch swatch {
        case .fill(let c):
            // Full-strength token color (no opacity wash) so the legend reads at true contrast and
            // matches the palette exactly. A hairline keeps light swatches legible on any background.
            RoundedRectangle(cornerRadius: 5).fill(c).frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.15), lineWidth: 0.5))
        case .border(let c):
            RoundedRectangle(cornerRadius: 5).strokeBorder(c, lineWidth: 2.5).frame(width: size, height: size)
        case .icon(let symbol, let c):
            Image(systemName: symbol).font(.system(size: size * 0.72)).foregroundStyle(c).frame(width: size, height: size)
        case .glyph(let g):
            Text(g).font(.system(size: size * 0.8)).frame(width: size, height: size)
        }
    }
}

/// One legend line: swatch · name · meaning. Used by both the info sheet and the inline legend.
struct LegendRow: View {
    let item: AppLegend.Item
    var body: some View {
        HStack(spacing: 10) {
            LegendSwatch(swatch: item.swatch)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.subheadline.weight(.semibold))
                Text(item.meaning).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The comprehensive legend, COLLAPSED by default, shown inline under the trade feeds so it's
/// there to reference but never in the way. Same content as the info Color Key sheet (AppLegend).
struct CollapsibleLegend: View {
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(AppLegend.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title.uppercased()).font(.dsLabel).foregroundStyle(.secondary)
                        ForEach(section.items) { LegendRow(item: $0) }
                    }
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Legend & colors", systemImage: "paintpalette")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .tint(.secondary)
        // Half-height collapsed bar: full horizontal padding, halved vertical padding.
        .padding(.horizontal, DS.cardPadding)
        .padding(.vertical, DS.cardPadding / 2)
        .background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))
    }
}

// MARK: - Loading overlay (so the app never looks frozen)

/// A centered spinner card shown over content while `active`. Reassures the user that startup, a
/// match search, or a tab-load is working — not frozen. Dims the background lightly; taps pass through
/// visually but the spinner sits on top. Fades in/out.
struct LoadingOverlay: ViewModifier {
    let active: Bool
    var label: String = "Loading…"
    func body(content: Content) -> some View {
        content.overlay {
            if active {
                ZStack {
                    Color(.systemBackground).opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        AnimatedLoader(maxSize: 96)
                        Text(label).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                }
                .transition(.opacity)
                .accessibilityElement()
                .accessibilityLabel(label)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: active)
    }
}

extension View {
    /// Show a spinner card over this view while `active` (e.g. startup / match search / tab-load).
    func loadingOverlay(_ active: Bool, label: String = "Loading…") -> some View {
        modifier(LoadingOverlay(active: active, label: label))
    }
}

// MARK: - Expandable image (B4-11)

/// An inline image that expands to a full-screen, pinch-to-zoom viewer on tap. Shared by channel
/// posts, replies, and 1:1 chat so all three get the same behavior (B4-11).
struct ExpandableImage: View {
    let image: UIImage
    var maxHeight: CGFloat = 180
    var cornerRadius: CGFloat = 8
    @State private var showFull = false

    var body: some View {
        Image(uiImage: image).resizable().scaledToFit()
            .frame(maxHeight: maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(Rectangle())
            .onTapGesture { showFull = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Expand image")
            .fullScreenCover(isPresented: $showFull) { ZoomableImageViewer(image: image) }
    }
}

/// Full-screen zoom/pan image viewer: pinch to zoom (1–6×), drag when zoomed, double-tap to toggle,
/// tap the ✕ to close.
struct ZoomableImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image).resizable().scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in scale = max(1, min(lastScale * v, 6)) }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1 { withAnimation { offset = .zero; lastOffset = .zero } }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            guard scale > 1 else { return }
                            offset = CGSize(width: lastOffset.width + v.translation.width,
                                            height: lastOffset.height + v.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                        else { scale = 2; lastScale = 2 }
                    }
                }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.9))
                    .padding()
            }
            .accessibilityLabel("Close")
        }
    }
}

// MARK: - Composer

/// A pinned Slack-style composer: bordered rounded field, formatting bar, send.
struct SlackComposer: View {
    let placeholder: String
    @Binding var text: String
    var showFormatBar = true
    var canSendWhenEmpty = false   // allow send with no text (e.g. an image is attached)
    /// When non-empty, an "@" button appears that opens a mention picker (channel use). id + name.
    var mentionPeople: [(id: String, name: String)] = []
    let onSend: () -> Void

    @State private var showMentions = false

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !canSendWhenEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 0.5))
                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isEmpty ? Color.secondary : .white)
                        .frame(width: DS.controlSize, height: DS.controlSize)
                        .background(isEmpty ? Color(.tertiarySystemFill) : Color.accentColor,
                                    in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isEmpty)
            }
            if showFormatBar {
                HStack(spacing: 14) {
                    FormatBar(text: $text)
                    if !mentionPeople.isEmpty {
                        Button { showMentions = true } label: { Image(systemName: "at") }
                            .buttonStyle(.borderless).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityLabel("Mention someone")
                    }
                    Text("**bold** *italic* ~~strike~~").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .sheet(isPresented: $showMentions) {
            MentionPicker(people: mentionPeople) { name in text = Mentions.insert(name, into: text) }
        }
    }
}

// MARK: - Mention picker

/// A searchable list of who you can @-mention in a channel — "@everyone" pinned first, then every active
/// dispatcher. Picking one inserts "@name " into the composer. Reliable regardless of spaces in names.
struct MentionPicker: View {
    let people: [(id: String, name: String)]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [(id: String, name: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? people : people.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Button { onPick("everyone"); dismiss() } label: {
                    Label("everyone", systemImage: "megaphone.fill")
                        .foregroundStyle(AppColor.primary)
                }
                ForEach(filtered, id: \.id) { p in
                    Button { onPick(p.name); dismiss() } label: {
                        HStack(spacing: 10) {
                            Avatar(name: p.name, id: p.id, size: 26)
                            Text(p.name)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search dispatchers")
            .navigationTitle("Mention")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Channel header

/// A "# channel-name" header strip, Slack-style.
struct ChannelHeader: View {
    let name: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "number").font(.headline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.headline)
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }
}
