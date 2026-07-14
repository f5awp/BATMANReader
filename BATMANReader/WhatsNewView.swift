// WhatsNewView.swift
// DX Trader — "What's New" release notes screen
// Drop into your Xcode project alongside ReleaseNotes.swift.
//
// Present after onboarding or on build change (see WHATS-NEW-GUIDE.md):
//
//   @AppStorage("lastSeenChangelogBuild") private var lastSeenBuild = ""
//   .sheet(isPresented: $showWhatsNew) {
//       WhatsNewView { lastSeenBuild = Bundle.main.buildNumber }
//   }

import SwiftUI

// MARK: - Palette (matches the DX dark theme)

private enum WN {
    static let bg = Color(red: 0.051, green: 0.051, blue: 0.059)          // #0D0D0F
    static let card = Color(red: 0.110, green: 0.110, blue: 0.125)        // #1C1C20
    static let stroke = Color(red: 0.165, green: 0.165, blue: 0.188)      // #2A2A30
    static let text = Color(red: 0.949, green: 0.941, blue: 0.922)        // #F2F0EB
    static let dim = Color(red: 0.659, green: 0.659, blue: 0.690)         // #A8A8B0
    static let faint = Color(red: 0.353, green: 0.353, blue: 0.384)       // #5A5A62
    static let accent = Color(red: 0.910, green: 0.314, blue: 0.165)      // #E8502A
    static let blue = Color(red: 0.039, green: 0.518, blue: 1.0)          // #0A84FF
}

// MARK: - View

struct WhatsNewView: View {
    /// Which release to show. Defaults to the latest.
    var release: ReleaseNote = ReleaseNotes.all[0]
    var onClose: () -> Void

    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("What's New")
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundColor(WN.text)
                    Text(release.headline)
                        .font(.system(size: 15)).lineSpacing(3.5)
                        .foregroundColor(WN.dim)
                    VStack(spacing: 11) {
                        ForEach(release.bullets) { b in bulletCard(b) }
                    }
                    .padding(.top, 4)
                    if ReleaseNotes.all.count > 1 { historySection }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .background(WN.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image("dx-standard-dark-1024") // the standard dark 1024 mark
                    .resizable().scaledToFit()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("DX TRADER")
                    .font(.system(size: 11, weight: .heavy)).kerning(2.4)
                    .foregroundColor(WN.accent)
            }
            Spacer()
            Text(release.version)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(WN.blue)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(Capsule().stroke(WN.blue, lineWidth: 1.5))
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private func bulletCard(_ b: ReleaseBullet) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(b.icon)
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(b.color)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(b.color.opacity(0.13)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(b.color.opacity(0.33), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(b.title)
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundColor(WN.text)
                Text(b.body)
                    .font(.system(size: 13)).lineSpacing(2.5)
                    .foregroundColor(WN.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
        .background(RoundedRectangle(cornerRadius: 16).fill(WN.card))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(WN.stroke, lineWidth: 1))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(showHistory ? "Hide previous versions" : "Previous versions") {
                withAnimation { showHistory.toggle() }
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundColor(WN.blue)
            if showHistory {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ReleaseNotes.all.dropFirst()) { r in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(r.version)
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundColor(Color(red: 0.49, green: 0.49, blue: 0.522))
                            Text(r.headline)
                                .font(.system(size: 13)).lineSpacing(2.5)
                                .foregroundColor(WN.dim)
                        }
                    }
                }
                .padding(.top, 14)
                .overlay(Rectangle().fill(WN.stroke).frame(height: 1), alignment: .top)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: onClose) {
                Text("Continue")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(RoundedRectangle(cornerRadius: 14).fill(WN.blue))
            }
            Text("Turn these off any time in Settings → \"Show update notes on launch.\"")
                .font(.system(size: 11.5))
                .foregroundColor(WN.faint)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

#Preview {
    WhatsNewView {}
}
