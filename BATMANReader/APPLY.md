# DX Trader — Mosaic build-out: per-view apply guide

Everything references the atoms in **`DXMosaicIntegration.swift`**. Each atom is compile-safe (depends only on your `AppColor` / `DS`). Apply surface-by-surface; every edit is additive and preserves your logic, bindings, and store calls.

First, one shared mapping used by Inbox / Trades / Trade Status:

```swift
// Put in DXMosaicIntegration.swift or near your status enum.
extension MessagingStore {           // or wherever `TradeStatus` lives
    static func dxBadge(_ s: TradeStatus) -> (String, Color) {
        switch s {
        case .accepted:  return ("Accepted", AppColor.success)
        case .pending:   return ("Pending",  AppColor.pending)
        case .countered: return ("Replied",  AppColor.primary)
        case .declined, .cancelled: return ("Declined", AppColor.danger)
        }
    }
}
// Usage anywhere a StatusBadge was: DXStatusBadge(text: t, color: c) where (t,c) = MessagingStore.dxBadge(store.status(of: req))
```

---

## 1 · Home calendar — `HomeCalendar.swift` → `IntentCalendarView`
- **Month header** (Section `header:`):
  ```swift
  } header: {
      let worked  = shifts.filter { !$0.isOff && cal.isDate($0.date, equalTo: month, toGranularity: .month) }.count
      let offDays = shifts.filter {  $0.isOff && cal.isDate($0.date, equalTo: month, toGranularity: .month) }.count
      DXMonthHeader(title: Self.monthF.string(from: month), shifts: worked, off: offDays,
                    toTrade: intents.tradeAwayCount(inMonth: month))   // your seeking-count accessor
  }
  ```
- **Glazed cells** in `cell(...)`: right after `.clipShape(RoundedRectangle(cornerRadius: 7))`, add `.dxGlaze()`. Optionally tighten grout: the two `HStack(spacing: 4)` → `spacing: 4` stays; cell `cornerRadius` 7 already matches.
- **AppTopBar** is already the drop-in in `DXMosaicIntegration.swift`.

## 2 · Trades — `TradeIntentsFeed.swift` → `PackageCard` / `CompactSwapCard`
- Seat dots → tiles: every `Circle().fill(peerColor).frame(width: 8–9, height: 8–9)` → `DXSeatTile(color: peerColor)`. In `TradeParticipantLines`, same for the `color(r.id, r.isMe)` circle.
- Card surface: the outer `.padding(...).background(.bar, in: RoundedRectangle(cornerRadius: DS.cardRadius))` → `.dxCard()`.
- Quality pill: `pill(quality.text, quality.color)` → `DXStatusBadge(text: quality.text, color: quality.color)`.
- `swapLine` day text → wrap the days in `DXDayChip(text: DayFmt.list(days))`.
- Propose button: `.buttonStyle(.borderedProminent).tint(AppColor.primary)`.

## 3 · Inbox — `MessagingViews.swift` → `InboxView` / `RequestRow`
- Header: keep `.navigationTitle("Trade Inbox").navigationBarTitleDisplayMode(.inline)`, and drop a `DXPaletteStripe(height: 4).padding(.horizontal)` directly under the segmented `Picker`. (Or replace the title with `DXBrandHeader("Trade Inbox")` above the picker.)
- `RequestRow`: add a leading `DXSeatTile(color: TradeColors.color(forParticipant: other, myID: myID, orderedPeers: [other]))`; status → `DXStatusBadge` via `dxBadge`.
- Section rows sit in a plain `List`; no other change.

## 4 · Chat — `MessagingViews.swift` → `ThreadView`
- Message list: each bubble → `DXChatBubble(text: msg.text, mine: msg.fromID == myID)`.
- Pinned trade proposal at top → `.dxCard()`, seat tiles for both sides, and the action row:
  `Accept` `.tint(AppColor.success)`, `Counter` neutral (`Color(.tertiarySystemFill)`), `Decline` `.foregroundStyle(AppColor.danger)`.
- Composer send button: `RoundedRectangle(cornerRadius: DS.controlRadius).fill(AppColor.primary)` with paperplane.

## 5 · Channel — `MessagingViews.swift` → `ChannelView`
- Each post → `.dxCard()`, author `DXSeatTile` + name, keep your `ReactionChips`.
- Composer send tile tinted `AppColor.heat` (the channel's accent).

## 6 · Welcome — `HelpView.swift` → `WelcomeView.hero`
- Replace the hero block with `DXMosaicHero(title: AppGuide.appName, subtitle: "DISPATCH SHIFT TRADING")` (uses the real `mosaicBand` photo).
- `pillars`: give each pillar a tinted icon tile — `Image(systemName:).frame(width:26,height:26).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))` with tints `primary / special / success / vacation`.

## 7 · Settings — `SettingsView.swift`
- Rows → `DXIconRow(icon: "...", tint: AppColor.x, title: "...") { Text(value) }` or `{ Toggle("", isOn: $x).labelsHidden().tint(AppColor.success) }`.
- Suggested tints: Account `primary`, Notifications `heat`, Appearance `special`, About `neutral`.
- Keep your `ThemePicker`; it already reads as three tiles.

## 8 · Trade Status — `TradesView.swift` → `TradeDashboardSheet` zones
- Under the segmented `Picker`, add `DXPaletteStripe(height: 4).padding(.horizontal)`.
- Each zone's `RequestRow` gets the same seat-tile + `DXStatusBadge` treatment as Inbox.
- `AcceptedZone` action: `.buttonStyle(.borderedProminent).tint(AppColor.success)` (already success) — keep.

## 9 · ECB ledger — `AvailabilityView.swift` → `ECBAccountingView`
- Keep `balanceHeader` (big stats already use `AppColor.success/.danger`). Under it, add one cosmetic accent: `Image("mosaicBand").resizable().scaledToFill().frame(height: 8).clipShape(RoundedRectangle(cornerRadius: 4)).opacity(0.85).listRowInsets(...)`.
- Register `row(e)`: lead with `DXIconRow(icon:, tint:, title:)` where tint = success (credit) / danger (withdrawal) / primary (trade) / pending (holiday); trailing amount `Text(ecbText(e.amount)).foregroundStyle(e.amount >= 0 ? AppColor.success : AppColor.danger)`.

## 10 · Finder — `AvailabilityView.swift` → `PlanCandidateCell`
- Its gold (two-way) / green (bookend) border already matches the mockup — keep `borderColor`.
- Add a leading `DXSeatTile(color: TradeColors.color(forParticipant: candidate.workerID, myID: myID, orderedPeers: [candidate.workerID]))`.
- Wrap the row body in `.dxCard(padding: 10)` (replaces the `secondarySystemBackground` background) or leave as-is if you prefer the tighter list row.

---

### Order I'd implement
1. Home calendar (glaze + header) — highest visual payoff.
2. Trades cards (seat tiles + dxCard + badges).
3. Inbox + Trade Status (shared row treatment).
4. Chat + Channel.
5. Welcome + Settings.
6. ECB + Finder.

Each step is independent and shippable on its own.

## Themed segmented control — `DXSegmented.swift` (separate file)
Replaces every `Picker("", selection:).pickerStyle(.segmented)` with the glazed themed control. Drop-in, same binding; keep your `switch`/`if` on the bound value.
- **Neutral variant** (Trades, Inbox, Trade Settings, Welcome prefs): `DXSegmented(selection: $filter, options: [.init(0,"Intents"), .init(1,"Search"), .init(2,"ECB \(n)"), .init(3,"Misc")])`.
- **Semantic variant** (Trade Status): pass `color:` per value → active tile adopts accepted-green / pending-amber / denied-red.
No old struct to delete (native `Picker` just gets swapped out at each call site).

**Details kit** (all in `DXMosaicIntegration.swift`): status pills → `DXStatusBadge`, day/qual chips → `DXDayChip`, seats/blacklist → `DXSeatTile`, cards → `.dxCard()`, rows → `DXIconRow`, icon buttons → `.dxControlTile()`, toggles → `.tint(AppColor.success)`, section rules → `DXPaletteStripe`. Apply these anywhere the equivalent primitive appears so the small details match globally.

## Top-bar icon buttons — `DXMessagingDock.swift` (separate file)
The four home-top controls (Inbox · Channel · Trade status · ⋯) get the glazed squircle tile. Same pattern as `AppTopBar`: **add `DXMessagingDock.swift`, then delete the old `struct MessagingDock` from `ContentView.swift`.** Bindings, badges, taps, and the ⋯ Menu are preserved; only `iconLabel` changed (`.dxControlTile()`, which lives in `DXMosaicIntegration.swift`). Bottom tabs stay native — set `.tint(AppColor.primary)` on the `TabView`.
