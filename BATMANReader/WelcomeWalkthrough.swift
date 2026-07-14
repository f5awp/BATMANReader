// WelcomeWalkthrough.swift
// DX Trader — first-run welcome walkthrough
// Drop this file into your Xcode project, add the 7 screenshots to Assets.xcassets
// (names listed below), then present with:
//
//   @AppStorage("hasOnboarded") private var hasOnboarded = false
//   .fullScreenCover(isPresented: .constant(!hasOnboarded)) {
//       WelcomeWalkthrough { hasOnboarded = true }
//   }
//
// Asset catalog image names expected (drag the JPGs in and name them exactly):
//   wt-home, wt-intents, wt-solutions, wt-menu, wt-package, wt-ecb-queue, wt-ecb-ledger

import SwiftUI

// MARK: - Palette

private enum WT {
    static let bg = Color(red: 0.051, green: 0.051, blue: 0.059)          // #0D0D0F
    static let card = Color(red: 0.110, green: 0.110, blue: 0.125)        // #1C1C20
    static let stroke = Color(red: 0.165, green: 0.165, blue: 0.188)      // #2A2A30
    static let text = Color(red: 0.949, green: 0.941, blue: 0.922)        // #F2F0EB
    static let dim = Color(red: 0.659, green: 0.659, blue: 0.690)         // #A8A8B0
    static let faint = Color(red: 0.490, green: 0.490, blue: 0.522)       // #7D7D85
    static let accent = Color(red: 0.910, green: 0.314, blue: 0.165)      // #E8502A
    static let blue = Color(red: 0.039, green: 0.518, blue: 1.0)          // #0A84FF
    static let green = Color(red: 0.188, green: 0.820, blue: 0.345)       // #30D158
    static let violet = Color(red: 0.749, green: 0.353, blue: 0.949)      // #BF5AF2
    static let gold = Color(red: 1.0, green: 0.784, blue: 0.220)          // #FFC838
    static let teal = Color(red: 0.251, green: 0.784, blue: 0.878)        // #40C8E0
    static let slate = Color(red: 0.490, green: 0.490, blue: 0.627)       // #7D7DA0
    static let orange = Color(red: 1.0, green: 0.624, blue: 0.039)        // #FF9F0A
    static let red = Color(red: 1.0, green: 0.271, blue: 0.227)           // #FF453A
    static let pink = Color(red: 1.0, green: 0.392, blue: 0.510)          // #FF6482
}

// MARK: - Models

private struct Callout: Identifiable {
    let id: Int
    let x: CGFloat   // percent of image width, 0–1
    let y: CGFloat   // percent of image height, 0–1
    let caption: String
}

// MARK: - Root

struct WelcomeWalkthrough: View {
    var onFinish: () -> Void
    @State private var index = 0
    @State private var consent = [false, false, false]

    private let last = 11 // 12 cards, 0-indexed

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $index) {
                welcomeCard.tag(0)
                homeCard.tag(1)
                intentsCard.tag(2)
                legendCard.tag(3)
                findsCard.tag(4)
                menuCard.tag(5)
                respondCard.tag(6)
                ecbCard.tag(7)
                ledgerCard.tag(8)
                setCard.tag(9)
                prefsCard.tag(10)
                consentCard.tag(11)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.3), value: index)
            footer
        }
        .background(WT.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("DX TRADER")
                .font(.system(size: 11, weight: .heavy))
                .kerning(2.4)
                .foregroundColor(WT.accent)
            Spacer()
            if index < last {
                Button("Skip") { withAnimation { index = last } }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(WT.dim)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack {
            Button("Back") { withAnimation { index = max(0, index - 1) } }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(WT.dim)
                .opacity(index == 0 ? 0.25 : 1)
                .disabled(index == 0)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0...last, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? WT.blue : Color(red: 0.227, green: 0.227, blue: 0.259))
                        .frame(width: i == index ? 20 : 7, height: 7)
                        .onTapGesture { withAnimation { index = i } }
                }
            }
            Spacer()
            Button(index == last ? "Get Started" : "Continue") {
                withAnimation { index = min(last, index + 1) }
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 24).padding(.vertical, 11)
            .background(Capsule().fill(WT.blue))
            .opacity(index == last ? 0 : 1) // last card has its own gated button
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    // MARK: Card 1 — Welcome (mosaic theme: solid dark + accent glow stand-in;
    // swap in your mosaic image as a background if you prefer)

    private var welcomeCard: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("AppIconLarge") // or your plane mark; falls back gracefully if absent
                .resizable().scaledToFit().frame(width: 84, height: 84)
                .opacity(0.001) // remove this line + asset note if you add the mark
                .overlay(
                    Image(systemName: "airplane")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundColor(WT.accent)
                )
            Text("Welcome to DX Trader")
                .font(.system(size: 30, weight: .heavy))
                .foregroundColor(WT.text)
            Text("It reads the BATMAN schedule for you — shifts, days off, vacation, quals — then finds shift trades that actually work. Here's the two-minute tour.")
                .font(.system(size: 14.5)).lineSpacing(3)
                .foregroundColor(WT.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            VStack(spacing: 9) {
                chip("Your schedule, read for you")
                chip("Real trades, ranked best-first")
                chip("Built by one of us")
            }.padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }

    private func chip(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(WT.text)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(Capsule().fill(WT.card))
            .overlay(Capsule().stroke(WT.stroke, lineWidth: 1))
    }

    // MARK: Cards 2–9 — screenshot + callouts

    private var homeCard: some View {
        ScreenshotCard(
            title: "Home is your schedule",
            subtitle: "Your months appear on their own, straight from the BATMAN schedule — kept current automatically.",
            image: "wt-home",
            callouts: [
                Callout(id: 1, x: 0.20, y: 0.15, caption: "Mark Intents — everything starts here"),
                Callout(id: 2, x: 0.50, y: 0.45, caption: "Each day shows your shift and desk — \"AM 32\""),
                Callout(id: 3, x: 0.40, y: 0.78, caption: "Violet = days you're offering to trade away"),
            ])
    }

    private var intentsCard: some View {
        ScreenshotCard(
            title: "Tell it what you want",
            subtitle: "Paint your days: trade away, want to work, keep, or must-be-off. Keep and must-be-off are never crossed.",
            image: "wt-intents",
            callouts: [
                Callout(id: 1, x: 0.50, y: 0.22, caption: "Off-day brushes: Blackout ↔ Want to Work"),
                Callout(id: 2, x: 0.38, y: 0.27, caption: "Go finer than whole-day: AM / PM / MID"),
                Callout(id: 3, x: 0.50, y: 0.35, caption: "Save glows, then publishes your marks to the group"),
            ])
    }

    private var findsCard: some View {
        ScreenshotCard(
            title: "It finds real trades",
            subtitle: "The app searches the whole roster and shows only trades that pass every rule — best ones on top.",
            image: "wt-solutions",
            callouts: [
                Callout(id: 1, x: 0.50, y: 0.38, caption: "Two-person, multi-person, even circular loops"),
                Callout(id: 2, x: 0.81, y: 0.365, caption: "🔥 = you both marked it · 📖 = keeps days off together"),
                Callout(id: 3, x: 0.19, y: 0.515, caption: "Propose sends it straight to their Inbox"),
            ])
    }

    private var menuCard: some View {
        ScreenshotCard(
            title: "More in the ⋯ menu",
            subtitle: "Power tools on the Trade Solutions calendar, one tap away.",
            image: "wt-menu",
            callouts: [
                Callout(id: 1, x: 0.48, y: 0.275, caption: "I'm Feeling Lucky — the deep search, with filters: max people, force-include, dates, desks"),
                Callout(id: 2, x: 0.48, y: 0.33, caption: "Look up a dispatcher — start from a person, not a day"),
                Callout(id: 3, x: 0.48, y: 0.387, caption: "Email to dispatch DL — one tap drafts the old-style email for folks not on the app yet"),
            ])
    }

    private var respondCard: some View {
        ScreenshotCard(
            title: "Respond your way",
            subtitle: "Pick and choose right on the two calendars — keep just the days that work. The most optimal match comes first; alternate dates show up after.",
            image: "wt-package",
            callouts: [
                Callout(id: 1, x: 0.15, y: 0.09, caption: "What you give and what you get, up top"),
                Callout(id: 2, x: 0.50, y: 0.40, caption: "Twin calendars — your days and theirs, side by side"),
                Callout(id: 3, x: 0.24, y: 0.895, caption: "\"Select specific days\" = partial accept"),
            ])
    }

    private var ecbCard: some View {
        ScreenshotCard(
            title: "ECB, made fair",
            subtitle: "Give a shift away one-way for ECB credit — claimed in a first-come queue everyone can see.",
            image: "wt-ecb-queue",
            callouts: [
                Callout(id: 1, x: 0.22, y: 0.215, caption: "Set the ECB you're offering"),
                Callout(id: 2, x: 0.50, y: 0.295, caption: "Only people who can actually cover are offered"),
                Callout(id: 3, x: 0.50, y: 0.80, caption: "Send to bookends, everyone, or the people you pick"),
            ])
    }

    private var ledgerCard: some View {
        ScreenshotCard(
            title: "Track your ECB",
            subtitle: "The ledger keeps score — what's cleared, what's coming, and who owes whom.",
            image: "wt-ecb-ledger",
            callouts: [
                Callout(id: 1, x: 0.18, y: 0.23, caption: "Available now — cleared credit, capped at 144"),
                Callout(id: 2, x: 0.41, y: 0.23, caption: "Projected — once scheduled ECB and IOUs land"),
                Callout(id: 3, x: 0.50, y: 0.62, caption: "Lines wait as \"awaiting confirm\" until the credit lands"),
            ])
    }

    // MARK: Card 4 — color legend

    private var legendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The color language")
                .font(.system(size: 22, weight: .heavy)).foregroundColor(WT.text)
            Text("One hue, one meaning — the same everywhere in the app.")
                .font(.system(size: 13.5)).foregroundColor(WT.dim)
            sectionLabel("DAY COLORS")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 9) {
                swatch(WT.blue, "Working day"); swatch(WT.violet, "Trade away")
                swatch(WT.gold, "Want to work"); swatch(WT.green, "Keep")
                swatch(WT.slate, "Blackout · lock"); swatch(WT.teal, "VAC — vacation")
            }
            sectionLabel("MARKS & BADGES").padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                mark("APM", WT.gold, "Gold pills — shifts you'd work on an off day")
                mark("✕", WT.red, "Shift type you've blacked out")
                mark("★", WT.orange, "High-demand day — marked automatically")
                mark("★", WT.pink, "Personal milestone day")
                mark("🔥", WT.orange, "Both of you marked the day — strongest match")
                mark("📖", WT.green, "Bookend — pickup touches your days off")
                mark("Q", WT.gold, "Needs a third-person qual bridge")
                mark("●", WT.blue, "Blue / orange dot — public / private note")
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.top, 14)
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .bold)).kerning(1.5).foregroundColor(WT.faint).padding(.top, 4)
    }
    private func swatch(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(c).frame(width: 14, height: 14)
            Text(t).font(.system(size: 12.5)).foregroundColor(WT.dim)
        }
    }
    private func mark(_ g: String, _ c: Color, _ t: String) -> some View {
        HStack(spacing: 10) {
            Text(g).font(.system(size: 13, weight: .heavy)).foregroundColor(c).frame(width: 34, alignment: .leading)
            Text(t).font(.system(size: 12.5)).foregroundColor(WT.dim)
        }
    }

    // MARK: Card 10 — You're set

    private var setCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("You're set")
                .font(.system(size: 27, weight: .heavy)).foregroundColor(WT.text)
            Text("Five things, and you're trading. The more of us on it, the better the matches get — for everyone.")
                .font(.system(size: 14.5)).lineSpacing(3).foregroundColor(WT.dim)
            VStack(spacing: 11) {
                check("Turn on iCloud & the shared calendar")
                check("Set your openness & blacklists")
                check("Mark a month of intents")
                check("Run one search & propose a trade")
                check("Post anything odd in # feedback")
            }.padding(.top, 4)
            Text("It's in validation — try to break it. Real use is what finds the sharp edges.")
                .font(.system(size: 13)).foregroundColor(WT.faint)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
    }

    private func check(_ t: String) -> some View {
        HStack(spacing: 12) {
            Text("✓").font(.system(size: 15, weight: .heavy)).foregroundColor(WT.green)
            Text(t).font(.system(size: 14)).foregroundColor(WT.text)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 14).fill(WT.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(WT.stroke, lineWidth: 1))
    }

    // MARK: Card 11 — Set your preferences (the essentials, right in the tour)

    private var prefsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set your preferences")
                .font(.system(size: 22, weight: .heavy)).foregroundColor(WT.text)
            Text("So you only see trades you'd actually take — change any of this anytime in Trade Settings.")
                .font(.system(size: 13.5)).lineSpacing(2.5).foregroundColor(WT.dim)
            WelcomeTradePrefs()
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 8)
    }

    // MARK: Card 12 — Consent

    private var allAgreed: Bool { consent.allSatisfy { $0 } }

    private var consentCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("Before you start")
                .font(.system(size: 26, weight: .heavy)).foregroundColor(WT.text)
            Text("The short version — tap each to agree.")
                .font(.system(size: 14)).foregroundColor(WT.dim)
            VStack(spacing: 10) {
                consentRow(0, "It organizes trades — the official trade still goes through the normal process.")
                consentRow(1, "It's a volunteer beta, provided as-is — I'll confirm trades against the posted schedule.")
                consentRow(2, "My data lives in my iCloud. No company server, no ads. Use is voluntary.")
            }.padding(.top, 4)
            Button {
                if allAgreed {
                    SettingsManager.shared.recordConsent()   // stamp the on-device consent record (time + version)
                    onFinish()
                }
            } label: {
                Text(allAgreed ? "Agree & Get Started" : "Tap all three to continue")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(allAgreed ? WT.bg : WT.faint)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 13).fill(allAgreed ? WT.green : Color(red: 0.149, green: 0.149, blue: 0.165)))
            }
            .disabled(!allAgreed)
            .padding(.top, 6)
            Text("Not affiliated with or endorsed by the employer. Full terms in the app.")
                .font(.system(size: 11.5)).foregroundColor(Color(red: 0.353, green: 0.353, blue: 0.384))
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private func consentRow(_ i: Int, _ t: String) -> some View {
        Button {
            consent[i].toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(consent[i] ? WT.green : Color(red: 0.353, green: 0.353, blue: 0.384), lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(consent[i] ? WT.green : .clear))
                        .frame(width: 20, height: 20)
                    if consent[i] {
                        Text("✓").font(.system(size: 13, weight: .heavy)).foregroundColor(WT.bg)
                    }
                }
                Text(t)
                    .font(.system(size: 13.5)).lineSpacing(2)
                    .foregroundColor(WT.text)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 13).fill(consent[i] ? WT.green.opacity(0.10) : WT.card))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(consent[i] ? WT.green : WT.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Screenshot card with percentage-anchored callouts

private struct ScreenshotCard: View {
    let title: String
    let subtitle: String
    let image: String
    let callouts: [Callout]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 22, weight: .heavy)).foregroundColor(WT.text)
            Text(subtitle).font(.system(size: 13.5)).lineSpacing(2.5).foregroundColor(WT.dim)
            GeometryReader { _ in
                Image(image)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(WT.stroke, lineWidth: 1))
                    .overlay(
                        GeometryReader { geo in
                            ForEach(callouts) { c in
                                dot(c.id)
                                    .position(x: geo.size.width * c.x, y: geo.size.height * c.y)
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(callouts) { c in
                    HStack(alignment: .top, spacing: 8) {
                        dot(c.id, small: true).padding(.top, 1)
                        Text(c.caption).font(.system(size: 12.5)).lineSpacing(2).foregroundColor(WT.dim)
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 8)
    }

    private func dot(_ n: Int, small: Bool = false) -> some View {
        Text("\(n)")
            .font(.system(size: small ? 10 : 12, weight: .heavy))
            .foregroundColor(.white)
            .frame(width: small ? 16 : 22, height: small ? 16 : 22)
            .background(Circle().fill(WT.accent))
            .overlay(small ? nil : Circle().stroke(.white.opacity(0.85), lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }
}

#Preview {
    WelcomeWalkthrough {}
}
