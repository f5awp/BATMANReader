# DX Trader — Mosaic system, redesigned: **"the schedule is the mosaic"**

The brand now lives in the app's own two assets — its **color language** and its **calendar grid** — instead of a photograph. Everything below is drawn in code from your existing `DispatchPalette`, so it's crisp, recolorable, and on-system.

## Why this is better than the photo band
- **The stripe is your palette, not a stock image.** `DXPaletteStripe` renders the AppColor tokens, so brand = the legend. Retune `AppColor.contrast` and the brand retunes with it.
- **The calendar becomes the mosaic.** `.dxGlaze()` gives day cells ceramic depth — a real UX win (hierarchy + tactility), not decoration.
- **~28pt of chrome reclaimed.** The compact top bar drops the tall photo band for a 4pt signature rule.
- **Planes earn their place.** Reserved for Trades / empty / loading (motion = trading), never a header watermark.

## What's in here
- `DXMosaicIntegration.swift` — `DXPaletteStripe`, `.dxGlaze()`, `AppTopBar`, `DXMonthHeader`, `DXPlanesEmptyState`
- `Assets/dxPlanes.png` — transparent planes (only used by the empty state)

> The core system needs **no image assets** — it's all from `AppColor`/`DS`. `mosaicBand` is no longer required; keep it only if you still want the old band anywhere.

## Apply (all additive, logic untouched)
1. **`ContentView.swift`** — replace the `AppTopBar` struct with the one here.
2. **`HomeCalendar.swift`** → `IntentCalendarView`:
   - Section `header:` → `DXMonthHeader(title: Self.monthF.string(from: month), shifts: …, off: …, toTrade: …)` (count wiring is commented in the file).
   - In `cell(...)`, add `.dxGlaze()` right after the cell's `.clipShape(RoundedRectangle(cornerRadius: 7))`. That's the whole ceramic upgrade.
3. **Trades empty view / first-run** — drop in `DXPlanesEmptyState()`.
4. Add `Assets/dxPlanes.png` to `Assets.xcassets` as `dxPlanes` (only needed for step 3).

## iPad + orientation
No fixed widths anywhere. The stripe and header stretch to any width; the top bar uses wider gutters at `.regular` horizontal size class. Verified layout on iPhone SE → iPad Pro 13", portrait and landscape. Test with Xcode's orientation toggle.

## Build-ready conversion
`APPLY.md` maps every mockup surface to concrete edits in your real views (Home calendar, Trades cards, Inbox, Chat, Channel, Welcome, Settings, Trade Status, ECB, Finder). New atoms added for the build-out: `DXBrandHeader`, `DXStatusBadge`, `.dxCard()`, `DXChatBubble`, `DXIconRow`, plus `DXMosaicHero`. Start with Home calendar → Trades → Inbox/Status; each step ships independently.

## Trades surface (push)
- `DXSeatTile(color:)` — swap for the `Circle()` seat dots in `CompactSwapCard` / `TradeParticipantLines` so each participant reads as a glazed tile (color still from `TradeColors`).
- `DXDayChip(text:)` — glazed day chips for the "You get / They get" lists.
- Quality pills and badges keep their semantic hues untouched; `DXPlanesEmptyState` caps the feed's "all caught up" state.

## Light mode
All of the above is token-based (`.bar`, `Color(.systemBackground)`, `AppColor`, materials), so it adapts to light automatically — no separate light assets.

## Tuning
- `DXPaletteStripe(height:)` — brand presence (4pt rule → thicker banner).
- `.dxGlaze(radius:)` — match your cell corner radius (default 7).
- `DXBrand.enabled` — master off.
- Stripe hues/weights live in `DXPaletteStripe.tiles` — all AppColor tokens.
