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
//   wt-home, wt-compact, wt-intents, wt-trade-options, wt-tradelist, wt-solutions, wt-menu,
//   wt-dispatcher, wt-package, wt-ecb-queue, wt-ecb-ledger, wt-channels

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

    private let last = 16 // 17 cards, 0-indexed

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        // If consent was already recorded (e.g. replaying the tour), keep the boxes checked so it never has
        // to be re-agreed. The original timestamp is preserved — recordConsent only stamps on first agree.
        let done = SettingsManager.shared.consentAcceptedAt != nil
        _consent = State(initialValue: [done, done, done])
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $index) {
                welcomeCard.tag(0)
                homeCard.tag(1)
                compactCard.tag(2)
                intentsCard.tag(3)
                tradeOptionsCard.tag(4)
                tradeListCard.tag(5)
                ledgerCard.tag(6)
                channelsCard.tag(7)
                legendCard.tag(8)
                menuCard.tag(9)
                findsCard.tag(10)
                ecbCard.tag(11)
                dispatcherCard.tag(12)
                respondCard.tag(13)
                setCard.tag(14)
                prefsCard.tag(15)
                consentCard.tag(16)
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
            HStack(spacing: 8) {
                Image("dx-standard-dark-1024")   // logo in the top-left corner
                    .resizable().scaledToFit().frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("DX TRADER")
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(2.4)
                    .foregroundColor(WT.accent)
            }
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
            // Compact circular arrow — with 17 page dots the old "Continue" pill squished the dot rail.
            Button {
                withAnimation { index = min(last, index + 1) }
            } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(WT.blue))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Continue")
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
            Image("dx-standard-dark-1024")   // the DX Trader logo mark (matches the app icon)
                .resizable().scaledToFit().frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("Welcome to DX Trader")
                .font(.system(size: 30, weight: .heavy))
                .foregroundColor(WT.text)
            Text("It reads the BATMAN schedule for you and finds trades that actually work. Here's the two-minute tour.")
                .font(.system(size: 14.5)).lineSpacing(3)
                .foregroundColor(WT.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            VStack(alignment: .leading, spacing: 10) {
                welcomeFeature("bolt.fill", WT.blue, "Find Trades Immediately")
                welcomeFeature("dollarsign.circle.fill", WT.gold, "Keep Track of your ECB")
                welcomeFeature("bubble.left.and.bubble.right.fill", WT.teal, "Chat with your fellow Dispatchers or privately message them")
                welcomeFeature("sparkles", WT.violet, "Find Complex Trades You've Never Thought Of")
            }
            .frame(maxWidth: 320)
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }

    private func welcomeFeature(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold)).foregroundColor(color)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.13)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.33), lineWidth: 1))
            Text(text)
                .font(.system(size: 13.5, weight: .semibold)).foregroundColor(WT.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Cards 2–9 — screenshot + callouts

    private var homeCard: some View {
        ScreenshotCard(
            page: 1, current: index,
            title: "Everything from Home",
            subtitle: "Home does it all — your schedule, your intents, and the top-bar hubs: Trade Inbox, Channels & Messages, ECB Accounting, and a Compact view. It stays current automatically.",
            image: "wt-home",
            callouts: [
                Callout(id: 1, x: 0.72, y: 0.092, caption: "Top bar: Trade Inbox · Channels & Messages · ECB · ⋯"),
                Callout(id: 2, x: 0.22, y: 0.152, caption: "Mark Intents — paint days, then set Day or ECB terms"),
                Callout(id: 3, x: 0.365, y: 0.493, caption: "Tap any colored day to open its Trade List & matches"),
            ])
    }

    private var compactCard: some View {
        ScreenshotCard(
            page: 2, current: index,
            title: "Compact view when you want it",
            subtitle: "Tap the compact icon to switch to a continuous, denser calendar — more months at a glance for planning ahead. Same colors, same marks.",
            image: "wt-compact",
            callouts: [
                Callout(id: 1, x: 0.82, y: 0.152, caption: "Tap the compact icon for a continuous, denser calendar"),
                Callout(id: 2, x: 0.07, y: 0.545, caption: "Months flow inline — SEP · OCT · NOV — scroll to plan ahead"),
                Callout(id: 3, x: 0.90, y: 0.39, caption: "Same colors and marks, just tighter cells"),
            ])
    }

    private var intentsCard: some View {
        ScreenshotCard(
            page: 3, current: index,
            title: "Mark Your Intents",
            subtitle: "Choose what each day is: trade away, want to work, keep, or must-be-off. Keep and must-be-off are never crossed.",
            image: "wt-intents",
            callouts: [
                Callout(id: 1, x: 0.27, y: 0.222, caption: "Choose Working / Off, then Want to Trade or Keep"),
                Callout(id: 2, x: 0.19, y: 0.277, caption: "Choose Day-for-Day or ECB"),
                Callout(id: 3, x: 0.50, y: 0.365, caption: "Save publishes your marks to the group"),
            ])
    }

    private var findsCard: some View {
        ScreenshotCard(
            page: 10, current: index,
            title: "Find Trades Searches Further",
            subtitle: "Go beyond a single day — search the whole roster by complex intents, a date range, or ECB out. It shows only trades that pass every rule, best ones on top.",
            image: "wt-solutions",
            callouts: [
                Callout(id: 1, x: 0.30, y: 0.103, caption: "Find by Complex Intents, Date Range, or ECB"),
                Callout(id: 2, x: 0.34, y: 0.53, caption: "Ranked swaps — fewest people first, best on top"),
                Callout(id: 3, x: 0.88, y: 0.53, caption: "Send proposes it straight to their Inbox"),
            ])
    }

    private var menuCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dig deeper in the Trades tab")
                .font(.system(size: 22, weight: .heavy)).foregroundColor(WT.text)
            Text("Home covers the everyday — mark days, see matches, propose. When you need more, the Trades tab goes further.")
                .font(.system(size: 13.5)).lineSpacing(2.5).foregroundColor(WT.dim)
            VStack(alignment: .leading, spacing: 10) {
                feature("person.crop.circle", WT.teal, "Find a Dispatcher",
                        "Look someone up for their info and quals, find trades with just them, or send a direct message.")
                feature("slider.horizontal.3", WT.violet, "Complex searches",
                        "Search a date range, build from your marked intents, or send ECB out — with granular filters for shift type, qual, and dates.")
                feature("person.3.fill", WT.gold, "Go wide",
                        "Multi-person and circular solutions — up to four dispatchers deep — when a straight two-way isn't there.")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.top, 14)
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold)).foregroundColor(color)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.13)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.33), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14.5, weight: .bold)).foregroundColor(WT.text)
                Text(body).font(.system(size: 12.5)).lineSpacing(2).foregroundColor(WT.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(WT.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(WT.stroke, lineWidth: 1))
    }

    private var respondCard: some View {
        ScreenshotCard(
            page: 13, current: index,
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
            page: 11, current: index,
            title: "Broadcast your ECB Requests",
            subtitle: "Give a shift away one-way for ECB credit — broadcast it to a first-come queue everyone can see and claim.",
            image: "wt-ecb-queue",
            callouts: [
                Callout(id: 1, x: 0.25, y: 0.127, caption: "Set the ECB you're offering — and an optional IOU date"),
                Callout(id: 2, x: 0.30, y: 0.47, caption: "Only people who can actually cover are shown"),
                Callout(id: 3, x: 0.30, y: 0.80, caption: "Send to bookends, everyone, or the people you pick"),
            ])
    }

    private var ledgerCard: some View {
        ScreenshotCard(
            page: 6, current: index,
            title: "Track your ECB",
            subtitle: "The ledger keeps score — what's cleared, what's coming, and who owes whom.",
            image: "wt-ecb-ledger",
            callouts: [
                Callout(id: 1, x: 0.18, y: 0.23, caption: "Available now — cleared credit, capped at 144"),
                Callout(id: 2, x: 0.41, y: 0.23, caption: "Projected — once scheduled ECB and IOUs land"),
                Callout(id: 3, x: 0.50, y: 0.62, caption: "Lines wait as \"awaiting confirm\" until the credit lands"),
            ])
    }

    // MARK: New screenshot cards (v2.6) — trade options, trade list, dispatcher, channels

    private var tradeOptionsCard: some View {
        ScreenshotCard(
            page: 4, current: index,
            title: "Specify and Search By Day",
            subtitle: "Tune exactly how a day trades — Day-for-Day or ECB, an optional later pay date (IOU), and what you'll accept back by shift type, qual, or date range — then search matches right here.",
            image: "wt-trade-options",
            callouts: [
                Callout(id: 1, x: 0.27, y: 0.355, caption: "Trade as Day-for-Day, ECB, or Either"),
                Callout(id: 2, x: 0.55, y: 0.455, caption: "Offer ECB — and set a later pay date (IOU)"),
                Callout(id: 3, x: 0.28, y: 0.60, caption: "Scope it: accept only these shift types, quals, or dates"),
                Callout(id: 4, x: 0.62, y: 0.955, caption: "Tap Trade List to search matches for this day"),
            ])
    }

    private var tradeListCard: some View {
        ScreenshotCard(
            page: 5, current: index,
            title: "Match ⇄ Match",
            subtitle: "Matches are built specifically from your trade-option selections — so you see only the people who fit, strongest first, and propose right from the list.",
            image: "wt-tradelist",
            callouts: [
                Callout(id: 1, x: 0.72, y: 0.223, caption: "Filter by return date to narrow the list"),
                Callout(id: 2, x: 0.34, y: 0.36, caption: "Only people who fit your selections — strongest first"),
                Callout(id: 3, x: 0.87, y: 0.36, caption: "🔥 you both marked it · 📖 keeps days off · tap to propose"),
            ])
    }

    private var dispatcherCard: some View {
        ScreenshotCard(
            page: 12, current: index,
            title: "Find a Dispatcher",
            subtitle: "Look anyone up and see all their info — quals, contact, seniority. Then find trades with just them, or send a direct message.",
            image: "wt-dispatcher",
            callouts: [
                Callout(id: 1, x: 0.42, y: 0.55, caption: "Tap anyone to see all their info — quals, phone, email, seniority"),
                Callout(id: 2, x: 0.25, y: 0.715, caption: "Find Trades — search swaps with just this person"),
                Callout(id: 3, x: 0.72, y: 0.715, caption: "Message — direct-message them about a trade"),
            ])
    }

    private var channelsCard: some View {
        ScreenshotCard(
            page: 7, current: index,
            title: "Channels & Messages",
            subtitle: "Talk to the whole group in channels, or direct-message your fellow dispatchers about a trade — or anything else.",
            image: "wt-channels",
            callouts: [
                Callout(id: 1, x: 0.27, y: 0.163, caption: "Channels for the group · Messages for 1:1"),
                Callout(id: 2, x: 0.50, y: 0.225, caption: "Channels: #general · #trades · #feedback"),
                Callout(id: 3, x: 0.72, y: 0.163, caption: "Direct-message a fellow dispatcher about a trade"),
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
                mark("circle.fill", WT.orange, "Match — bold orange disc behind the date (most visible)")
                mark("star.fill", WT.gold, "High-demand / holiday — top-right star (a MID counts for the night-before holiday)")
                mark("star.fill", WT.pink, "Personal milestone — pink top-right star")
                mark("exclamationmark.circle.fill", WT.blue, "Watching this day — top-left")
                mark("a.circle.fill", WT.gold, "Availability pills — shifts you'd work on an off day")
                mark("xmark", WT.red, "Shift type you've blacked out")
                mark("flame.fill", WT.orange, "Both of you marked the day — strongest match")
                mark("book.fill", WT.green, "Bookend — pickup touches your days off")
                mark("q.square.fill", WT.gold, "Needs a third-person qual bridge")
                mark("note.text", WT.blue, "Note — blue (public) / orange (private)")
                mark("arrow.left.arrow.right", WT.blue, "Day-for-day trade — swap a shift for a shift")
                mark("dollarsign.circle.fill", WT.gold, "ECB trade — give a shift away for points")
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
    /// `symbol` is an SF Symbol name, rendered in the mark's color.
    private func mark(_ symbol: String, _ c: Color, _ t: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold)).foregroundColor(c)
                .frame(width: 26, alignment: .center)
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
            // LAZY: the embedded Trade Settings form is heavy (loads quals + applies openness across every
            // shift). TabView builds all pages up front, so building it eagerly hitched the tour at launch.
            // Only build it once the user is on/near this page (index 15 of the 0–16 flow).
            if index >= 14 {
                WelcomeTradePrefs()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14).fill(WT.card)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(WT.stroke, lineWidth: 1))
                    .frame(maxWidth: .infinity).frame(minHeight: 320)
            }
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
                    // Stamp the consent record (time + version) only the FIRST time — replays keep the original.
                    if SettingsManager.shared.consentAcceptedAt == nil { SettingsManager.shared.recordConsent() }
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
    let page: Int
    let current: Int
    let title: String
    let subtitle: String
    let image: String
    let callouts: [Callout]

    // The .page TabView builds every page up front. Each screenshot is a full-res JPEG (~14 MB decoded),
    // so decoding all ~10 at once was the source of the lag. Decode only the visible page and its immediate
    // neighbours; the rest render a cheap placeholder of the same aspect ratio (no layout jump on swipe).
    private var showImage: Bool { abs(page - current) <= 1 }
    private static let aspect: CGFloat = 1290.0 / 2796.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 22, weight: .heavy)).foregroundColor(WT.text)
            Text(subtitle).font(.system(size: 13.5)).lineSpacing(2.5).foregroundColor(WT.dim)
            GeometryReader { _ in
                if showImage {
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
                } else {
                    RoundedRectangle(cornerRadius: 16).fill(WT.card)
                        .aspectRatio(Self.aspect, contentMode: .fit)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(WT.stroke, lineWidth: 1))
                        .frame(maxWidth: .infinity)
                }
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
