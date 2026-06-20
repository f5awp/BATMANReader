// SlackKit.swift
// Slack-style building blocks for the trade channel + inbox: initials avatars,
// a message row (avatar · name · time · markdown body · inline actions), and a
// pinned composer with a formatting bar. Presentation only — the messaging data
// flow in MessagingStore is unchanged.

import SwiftUI

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
            .foregroundStyle(s.over ? Color.red : (s.nearLimit ? Color.orange : Color.secondary))
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
            Text(name ?? participantName(id)).font(nameFont)
            if let status = participantStatus(id) {
                Text(status).font(.caption2).italic()
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

// MARK: - Style helpers

enum SlackStyle {
    /// Slack-like avatar palette.
    static let palette: [Color] = [
        Color(red: 0.20, green: 0.51, blue: 0.89), Color(red: 0.46, green: 0.31, blue: 0.78),
        Color(red: 0.86, green: 0.32, blue: 0.55), Color(red: 0.91, green: 0.55, blue: 0.18),
        Color(red: 0.13, green: 0.63, blue: 0.55), Color(red: 0.24, green: 0.65, blue: 0.34),
        Color(red: 0.36, green: 0.42, blue: 0.85), Color(red: 0.81, green: 0.28, blue: 0.28),
        Color(red: 0.17, green: 0.60, blue: 0.73)
    ]

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

// MARK: - Composer

/// A pinned Slack-style composer: bordered rounded field, formatting bar, send.
struct SlackComposer: View {
    let placeholder: String
    @Binding var text: String
    var showFormatBar = true
    var canSendWhenEmpty = false   // allow send with no text (e.g. an image is attached)
    let onSend: () -> Void

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
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(isEmpty ? Color.gray.opacity(0.4) : Color.accentColor, in: Circle())
                }
                .disabled(isEmpty)
            }
            if showFormatBar {
                HStack(spacing: 14) {
                    FormatBar(text: $text)
                    Text("**bold** *italic* ~~strike~~").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - User status header (shown atop Home + Trades)

/// The signed-in dispatcher's avatar + name + public status line.
struct StatusHeaderBar: View {
    private var settings = SettingsManager.shared

    var body: some View {
        let name = settings.displayName.isEmpty ? settings.username : settings.displayName
        HStack(spacing: 8) {
            Avatar(name: name, id: settings.username, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(settings.statusBroadcast.isEmpty ? "Set a status in Trade Settings →" : settings.statusBroadcast)
                    .font(.caption2)
                    .foregroundStyle(settings.statusBroadcast.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
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
