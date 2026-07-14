# DX Trader — style parity v2 (multi-surface)

Round 2, after the calendar glaze/blackout work landed. Focus is **style/system consistency**, not copy. The Home calendar is now largely correct (glazed gradient cells, matte+lock blackout, tighter grout, native tab bar). The gaps below are about applying that same ceramic system to the *other* surfaces and finishing the brand signature.

Priority order is at the bottom. Every fix is visual only.

---

## 1 · The palette stripe is STILL missing, and the green bar is still there (do this first)
Present on every screen: a thin **green progress/loading bar** sits directly under the profile header (Home, Mark Intents, Trade Solutions, loading). That was supposed to be replaced by the **multicolor palette stripe** — the single most-repeated miss across all rounds.
- **Fix:** remove the green bar from the header chrome (move any real loading state into content, not a brand-position rule). Add `DXPaletteStripe(height: 4)` directly under the profile bar on every top-level surface. Stripe gradient (L→R, ~11% bands): `#17233B, #2C4A72, #4F7196, #7D9B6F, #4D6A30, #D9A63E, #D9762E, #B5452F, #8F3B30`.

## 2 · Cell treatment is inconsistent between Home and Trade Solutions
- **Now:** Home day cells are glazed ceramic (correct). On the **Trade Solutions** calendar, the non-selected days are **flat dark-gray tiles with thin hairline borders and no glaze** — a different, hollower look — while only the selectable days get the navy glaze. Two calendars, two visual languages.
- **Fix:** use the **same glazed cell** everywhere. Non-selected/greyed days = the glazed navy tile at reduced opacity (e.g. `.opacity(0.45)`), NOT a flat bordered box. Out-of-month days keep the dim treatment but still glazed. Match Home's radius (7) and 4pt grout — the Trade Solutions grid currently reads with a larger radius and wider gaps.

## 3 · Planes aren't doing their one job (empty + loading states)
The system reserves the **origami planes** for *motion* moments — empty states and loading — as the brand delight. Right now:
- **Trade Solutions empty state** ("Pick Shifts to Trade") uses a generic gray people-with-gear glyph. **Fix:** replace with `DXPlanesEmptyState()` (the `dxPlanes` art), same as the Trades "all caught up" state.
- **Loading splash** (see §7) uses a bland gray card + wordmark instead of the planes. **Fix:** planes are the loading motif.
Nowhere else should planes appear (never a header watermark).

## 4 · Segmented controls — one solid-pill look, NO underline
- **Preference (locked):** the active segment is a **solid color-filled pill with a white label** — exactly the Trade Status look (green Accepted / red Denied). **Remove the rainbow palette-accent underline entirely** (the bar under "Working Shifts" / "Trade Solutions") — it's not wanted anywhere.
- **Now:** three different styles across the app — solid semantic pills (Trade Status ✓), rainbow-underline (Trade Solutions, Working Shifts/Days Off ✗), and flat chips (Trade preferences).
- **Fix:** route every `Picker(.segmented)` / tab strip through `DXSegmented`. The shared control has been updated so the active pill is always a solid fill: **semantic strips pass a `color:`** (Trade Status → success/pending/danger), **everything else defaults to the app accent** (`AppColor.primary`). No underline, no border on the active tile. Keep your existing binding + switch; only the picker view changes.

## 5 · Chips & selectors are flat — glaze them, and fix the blackout-color clash
- **Trade preferences:** the AM/PM/MID type chips, region chips (Domestic / Latin America / grayed ones), and the S–M–T–W–T–F–S "Blackout days" selector are all **flat fills**. The active state is a flat purple. **Fix:** make active chips glazed tiles (detail kit — `DXStatusBadge` / glazed chip / `.dxControlTile()`), so they read as ceramic like the rest of the app.
- **Semantic clash:** the "Blackout days" weekday selector uses **purple** for active, but a blackout *calendar cell* is now the **matte-gray + lock** language (§2d, round 1). Same concept, two colors. **Fix:** align the blackout-day selector to the blackout language — active = the matte/graphite tile (or at least a neutral, not purple, which reads as "trade").

## 6 · Legend rows are heavy / all-caps
- **Now:** two stacked legends — a global `32 TRADE · 5 WORK · 61 BLKOUT` and a per-month `29 ON · 2 OFF · 1 TRADE · 2 BLKOUT` — both **all-caps** with square dots.
- **Fix:** fold counts into the month header as the quiet **lowercase, dot-led** row (`● 29 on · ● 2 off · ● 1 trade · ● 2 blackout`, 8px dots radius 2). Drop the heavy global caps legend or make it the same quiet style. (Round-1 §6.)

## 7 · Header still heavy
- **Now:** profile bar + a separate row with the blue-tinted **"Mark Intents"** pill and icon tiles, plus the green bar. The icon tiles are now glazed squircles (good).
- **Fix:** tighten to the compact bar; "Mark Intents" should use the system accent, not a standalone neon-blue pill; palette stripe replaces the green bar (§1). (Round-1 §5.)

## 8 · Floating magnifier button — DO NOT TOUCH
- The blue circular magnifier that floats bottom-right is an **accessibility control**. Leave it exactly as-is — do not move, restyle, dock, or hide it. Ignore it when evaluating overlap on other elements.

## 9 · ECB Accounting — mostly on-system, keep it
Good: the **mosaic band** photo strip in the balance card and the colored squircle **icon tiles** (blue trade arrows, red withdrawal, green overtime) match the detail kit. Leave as-is. Minor polish only: the balance card is a flat `secondarySystemBackground` block — that's fine; don't glaze the numbers.

## 11 · Kill the "chrome" hairline borders
The thin gray hairline lines under bars / around bar surfaces (the classic UIKit bar chrome) are disliked and should go app-wide. They are NOT the ceramic glaze rims on tiles/cards — keep those. Targets:
- **`AppTopBar`** — already fixed in `DXMosaicIntegration.swift`: `.background(.bar)` + `.overlay { Divider() }` → `.background(Color(.systemBackground))`. Apply the same anywhere else you background a bar with `.bar` + a `Divider()`.
- **Sheet / navigation bars** (e.g. "Trade Status", "ECB Accounting", "Your trade preferences" headers): hide the nav-bar hairline with `.toolbarBackground(Color(.systemBackground), for: .navigationBar)` + `.toolbarBackground(.visible, for: .navigationBar)` and, globally, `UINavigationBar.appearance().shadowImage = UIImage(); ...standardAppearance.shadowColor = .clear` (also set `scrollEdgeAppearance`).
- **Tab bar** (Home / Trades): remove its top hairline — `let a = UITabBarAppearance(); a.shadowColor = .clear; UITabBar.appearance().standardAppearance = a; UITabBar.appearance().scrollEdgeAppearance = a`.
- **Lists / forms** (Trade preferences, ECB register): `.listRowSeparator(.hidden)` and `.scrollContentBackground(.hidden)` where you don't want the row/section separators.
- **Optional:** if the faint card outline still reads as a border, drop `DXCard`'s `.strokeBorder(.primary.opacity(0.06))`. Do NOT remove the day-cell/tile glaze rim — that's the ceramic edge, not chrome.

## 10 · Normalize the day-cell corner marker
Home July "4" carries a small copper/brown corner circle; it reads as a one-off. **Fix:** make any per-day marker (picked-to-trade, has-note, etc.) a consistent small corner dot/seat-tile in a semantic color from the palette, used identically everywhere — not an ad-hoc badge on one cell.

---

## Priority order
1. **Palette stripe in, green bar out** (§1) — everywhere.
2. **Unify cell treatment** Home ↔ Trade Solutions (§2).
3. **Planes for empty + loading** (§3) + the new launch screen (§7 / separate mockup).
4. **One solid-pill segmented control, no underline** (§4) and **glazed chips** (§5).
5. **Quiet dot-led legend** (§6), **compact header** (§7).
6. **Kill chrome hairline borders app-wide** (§11), **marker normalization** (§10). *(The floating magnifier, §8, is an accessibility control — leave it.)*

Test every change in light and dark. ECB (§9) already passes — use it as the reference for "on-system."
