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

## 4 · Segmented controls are two different styles — unify
- **Now:** Trade Solutions uses the themed **rainbow-underline** segmented control (Intents / Trade Solutions / ECB) — correct, that's `DXSegmented`. But **Mark Intents** uses a plain rounded-**pill** segmented control (Working Shifts / Days Off), and Trade preferences uses yet another flat-chip style.
- **Fix:** route every `Picker(.segmented)` / tab strip through `DXSegmented` so the active tile is the glazed treatment with the palette-accent underline. One control, everywhere (this was the original §1 of round 1).

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

## 10 · Normalize the day-cell corner marker
Home July "4" carries a small copper/brown corner circle; it reads as a one-off. **Fix:** make any per-day marker (picked-to-trade, has-note, etc.) a consistent small corner dot/seat-tile in a semantic color from the palette, used identically everywhere — not an ad-hoc badge on one cell.

---

## Priority order
1. **Palette stripe in, green bar out** (§1) — everywhere.
2. **Unify cell treatment** Home ↔ Trade Solutions (§2).
3. **Planes for empty + loading** (§3) + the new launch screen (§7 / separate mockup).
4. **One segmented control** (§4) and **glazed chips** (§5).
5. **Quiet dot-led legend** (§6), **compact header** (§7).
6. **Marker normalization** (§10). *(The floating magnifier, §8, is an accessibility control — leave it.)*

Test every change in light and dark. ECB (§9) already passes — use it as the reference for "on-system."
