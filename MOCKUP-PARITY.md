# DX Trader — Home calendar: mockup-parity spec

Goal: make the **Home calendar** screen match the redesign mockup (the "glazed ceramic / the schedule *is* the mosaic" surface). This is a QA diff, not a prompt — reword the instructions however you like. Every value below is pulled from the mockup source, so treat these as the target numbers.

Format for each item: **What's wrong now → Target (mockup) → Fix.** All fixes are visual only; do not touch data, bindings, or store logic.

---

## 0 · The one-line summary
The mockup calendar reads as a **tight ceramic mosaic**: small, glazed, gradient-filled tiles with 4pt grout, one concise status token per cell, a thin multicolor palette stripe as the brand signature, and a calm/muted color set. The current app reads as **big flat bubbly buttons**: large corner radius, wide gaps, over-saturated neon fills, low-contrast sub-labels, no glaze, no palette stripe, and a floating capsule tab bar that overlaps content. Fixing those closes ~90% of the gap.

**Light mode is worse than dark** (§9): ON and OFF are both pale gray on a near-white page and the tiles don't separate from the background at all. And the **blackout** treatment (black + red ✕) doesn't hold up across modes — see §2d.

---

## 1 · Day cells — the core of the mosaic

### 1a. No glaze (biggest miss)
- **Now:** cells are flat solid fills.
- **Target:** every cell is a vertical gradient + top highlight + inner bottom shadow (ceramic depth).
- **Fix:** apply `.dxGlaze()` and use a top→bottom gradient fill instead of a solid color. Reference recipe per cell:
  - `background: linearGradient(top→bottom, lightTone → darkTone)`
  - inner top highlight: `inset 0 1px 0 rgba(255,255,255, 0.28)` on colored tiles, `0.07` on dark navy tiles
  - inner bottom shadow: `inset 0 -3px 5px rgba(0,0,0, 0.28–0.30)`

### 1b. Corner radius too large
- **Now:** ~14–16pt radius → cells look like separate bubbles.
- **Target:** **radius 7–8pt** (mockup uses 8; handoff standard is 7).
- **Fix:** cell `RoundedRectangle(cornerRadius: 7)`, then `.dxGlaze(radius: 7)`.

### 1c. Grout (gap) too wide
- **Now:** wide gaps between cells; tiles feel disconnected.
- **Target:** **4pt** gap between cells, both axes → a tight "grouted tile wall."
- **Fix:** the row/column `HStack`/grid `spacing: 4`.

### 1d. Cells too tall / too much internal padding
- **Now:** big day number (~22pt) + chips make cells tall; fewer weeks fit.
- **Target:** compact. Day number **14pt/700**, status label **8pt/700** sitting **2pt** below it, **~7pt** vertical padding. Cells are near-square only because 7 flexed columns land near-square — do **not** hardcode width/height/aspect; keep 7 equal flexible columns.
- **Fix:** shrink number to ~14–15pt, label to ~8–9pt, vertical padding ~7pt.

---

## 2 · Cell colors, contrast & the ON/OFF problem

### 2a. Colors are over-saturated / labels low-contrast
- **Now:** trade purple is neon (`~#7c5cff`); the sub-label ("AM 22") under a filled cell is a low-contrast tint that's hard to read.
- **Target:** muted, glazed hues; the sub-label is a **lightened tint of the fill** at high opacity so it stays legible on the tile.
- **Fix — exact target tokens (gradient top → bottom, plus label color):**

| State | Gradient top | Gradient bottom | Number | Label color |
|---|---|---|---|---|
| ON / working (default) | `#17233A` | `#0F1829` | `#EEF1F6` | `#9FB0C8` |
| Trade (want to trade) | `#8A63D8` | `#5B3F96` | `#FFFFFF` | `#EFE7FB` |
| Keep / confirmed | `#3FAE5F` | `#2C7A43` | `#FFFFFF` | `#E4F6E9` |
| Want to work | `#E2A63A` | `#B87D1A` | `#FFFFFF` | `#FBF0D8` |
| Vacation | `#2B8F83` | `#1C6A61` | `#FFFFFF` | `#D9F2EE` |
| OFF (see 2b) | — | — | — | — |
| Blackout (see 2d) | — | — | — | — |
| Today | any state fill **+** ring `inset 0 0 0 2px #2F6ED9` | | | |

**Light-mode tiles** (from the mockup's light calendar) — same states, light glaze. The default/ON tile is a **white tile with a real drop shadow** so it lifts off the near-white page; that shadow is what makes the grid read in light mode (your current light tiles are flat and melt into the background):

| State | Gradient top | Gradient bottom | Shadow | Number |
|---|---|---|---|---|
| ON / working (default) | `#FFFFFF` | `#EEF0F4` | `inset 0 1px 0 rgba(255,255,255,.9)`, `0 1px 2px rgba(0,0,0,.12)` | `#1A1A1A` |
| Trade | `#9069DB` | `#7A52CA` | inset highlight `.4` | `#FFFFFF` |
| Keep | `#4AB86F` | `#33A04D` | inset highlight `.4` | `#FFFFFF` |
| Want to work | `#E9AD3F` | `#CF9520` | inset highlight `.45` | `#FFFFFF` |
| Vacation | `#33A89B` | `#1F8A7E` | inset highlight `.35` | `#FFFFFF` |

Keep these tied to your `AppColor` tokens where they exist — the point is the **muted, glazed** character, the **legible tint label**, and (light mode) the **drop shadow that separates tile from page**, not new hardcoded colors.

### 2b. ON and OFF look almost identical (fix this deliberately)
- **Now:** ON and OFF are both dark cool blue-grays → you can't tell working from free at a glance. The single most-scanned distinction is the weakest.
- **Why not a literal complementary color:** the complement of the ON navy (~230°) is orange/amber (~45°), but amber/orange is already the **Want-to-Work / demand** color — a straight complementary OFF would collide with the legend. So differentiate on **value + fill-state**, not a clashing hue.
- **Target / Fix (pick one; A recommended):**
  - **A — OFF = the empty/rest state (recommended).** ON stays a solid glazed navy with a bright number. OFF becomes a light, near-zero-chroma tile with a dim number — e.g. fill `#3B4152 → #2A2F3D` (roughly 2× the luminance of ON) with label `#8B93B5`; or a hollow cell (very dark `#101216` fill + 1px `#24262B` border + dimmed `#8B93B5` number). Contrast is dark-filled-bright vs light/hollow-dim → unmistakable, and no new hue competes with the semantic colors.
  - **B — warm/cool opposition.** Keep ON cool navy; make OFF a **desaturated warm gray/graphite** (near-zero chroma, warm hue ~60°, e.g. `oklch(0.42 0.015 60)` top → darker bottom). Warm vs cool reads instantly and stays quiet. Do **not** use a saturated orange (collides with demand).
  - Target a **≥ 3:1 luminance ratio** between ON and OFF either way.
- **Light mode is the worse offender** — right now ON (pale gray) and OFF (pale gray) are nearly identical on the near-white page, so the grid is unreadable. Mirror the same logic inverted:
  - **ON = lifted white tile** (`#FFFFFF→#EEF0F4` + the drop shadow above) with a dark number.
  - **OFF = a flat, shadowless, slightly-darker *recessed* tile** — e.g. `#E2E4E9` flat, no glaze highlight, dim number `#8A8F98`. Contrast = *lifted-bright* (ON) vs *sunken-matte* (OFF). Same ≥3:1 separation, and OFF visibly recedes below the page plane.

### 2c. Warning days (26/27) obscure the number
- **Now:** an orange day number with a warning-triangle badge overlaps the numeral → the date is barely readable (orange-on-dark, partly behind chips + triangle).
- **Target:** the mockup never obscures the number. If a warning must show, it's a small corner badge that does not sit on top of the numeral, and the number keeps a legible fill.
- **Fix:** keep the number white/legible; move any warning indicator to a non-overlapping corner (or a thin top edge accent), don't recolor the numeral to low-contrast orange. (This is worse in light mode, where the orange numeral sits on a pale tile — even lower contrast.)

### 2d. Blackout days — DECISION: matte tile + lock glyph (option A)
- **Chosen treatment:** blackout is the **one matte, un-glazed, slightly recessed tile** in the grid, with a **lock glyph and no red**. Every tradeable state is glazed (glossy); the *absence of the sheen* is what signals "not tradeable / immovable." This reads identically in light and dark and stays on-system. (This replaces the old black + red ✕, which read as an "error hole" and behaved oppositely across modes — dominating on white, vanishing on black.)
- **Build tokens:**

| Mode | Fill | Border / inset | Number | Glyph |
|---|---|---|---|---|
| Dark | `#1C1D21` flat matte (no gradient, no highlight) | inset `0 0 0 1px #2A2C30` | `#6B6E75` (dim) | lock `#6B6E75` |
| Light | `#D2D4DA` flat matte | inset `0 0 0 1px #C2C4CB` | `#8A8F98` (dim) | lock `#8A8F98` |

- **The critical move in both modes:** *do not* apply `.dxGlaze()` / the inner-top highlight / bottom-gloss shadow to blackout tiles — they must look physically flat and dead next to the glazed tiles. Drop the red ✕ entirely; use an SF Symbol `lock.fill` centered under the number in the dim glyph color.
- Swatch reference: `blackout-options.png` (column A).

---

## 3 · In-cell A/P/M participant chips — default OFF
- **Note:** the in-cell "A / P / M" chips are an existing, user-toggleable feature — leave the toggle in place; do **not** remove the capability.
- **Target:** to match the mockup's clean tile read, ship with the chips **toggled off by default**. A day cell then shows just the number + one concise status token (`AM 24`, `PM 15`, `OFF`, `VAC`, `WANT`), and the user can opt back into chips.
- **Fix:** set the chips toggle's default value to off. No other change.

---

## 4 · The palette stripe (missing brand signature)
- **Now:** no palette stripe anywhere; instead there's a green progress/loading bar under the profile row, which is off-system.
- **Target:** a thin multicolor **ceramic rule** made from the palette tokens, used (a) directly under the profile/top bar and (b) as the month divider accent. Height ~4–5pt.
- **Fix:** add `DXPaletteStripe(height: 4)`. Reference gradient (left→right segments):
  `#17233B, #2C4A72, #4F7196, #7D9B6F, #4D6A30, #D9A63E, #D9762E, #B5452F, #8F3B30` in ~11% bands.
  Remove the green progress bar from the header (or move loading state elsewhere — it should not read as a brand element).

---

## 5 · Header / top profile bar
- **Now:** avatar + name + row of 4 icons, then the green bar, then a separate bright-blue **"Mark Intents"** pill + 3 icon tiles. Heavy, two stacked toolbars, off-palette blue.
- **Target (mockup):** compact single bar — small rounded avatar, "Lee, Ervin" bold + "Testing…." italic muted subtitle, and a tight cluster of **glazed squircle icon tiles** on the right. Directly beneath it: the palette stripe. That's it.
- **Fix:**
  - Icon buttons → `.dxControlTile()` (glazed squircle), via `AppTopBar` / `DXMessagingDock` from the handoff.
  - Replace the neon-blue "Mark Intents" pill with the system accent (`AppColor.primary`) or fold the action into the bar; don't introduce a new blue.
  - Palette stripe (§4) replaces the green bar as the element under the profile row.

## 6 · Month header + counts
- **Now:** "OCTOBER 2026" big + a separate all-caps legend row (`17 ON · 14 OFF · 12 TRADE`) with squares, plus a global top legend (`32 Want to Trade / 4 Want to Work / 56 Blackout`).
- **Target:** month title in **Archivo 800, ~25pt, letter-spacing −0.4**, with a quiet inline count row underneath using **small colored dots (8px, radius 2)** and **lowercase**: e.g. `● 18 shifts · ● 9 off · ● 3 to trade` (dot colors: shifts `#39A558`, off `#4E5584`, trade `#7D58CD`). Optional 3pt gradient underline accent (52pt wide) under the title.
- **Fix:** use `DXMonthHeader(title:shifts:off:toTrade:)`. Drop the heavy all-caps legend; make counts small, lowercase, dot-led. Set the title font to Archivo (see §8).

## 7 · Footer: stats strip + tab bar
- **Now:** a **floating rounded capsule** tab bar (Home / Trades) hovering over the calendar, overlapping the December cells (3/4/5 partly hidden). Stats line sits below it.
- **Target:** a **flat, native-style bottom tab bar** flush at the bottom edge — Home (tinted `AppColor.primary` blue) + Trades — with the thin stats strip (`✓ 0 you · 0 PAFCA · Month`) as a quiet full-width row just above it. Nothing floats over the grid.
- **Fix:** use the native `TabView` with `.tint(AppColor.primary)` (bottom tabs stay native per the handoff). Remove the floating capsule so it never overlaps content. Keep the stats strip as a small centered row on the darker `#101216` bar with a `#24262B` top border.

## 8 · Typography
- **Now:** month titles/numbers look like default SF Bold; numbers oversized.
- **Target:** **Archivo** (heavy geometric) for month titles and the "JUL/2026"-style headers; day numbers 14pt/700; weekday row `Su M T W Th F Sa` at **10pt/600, `#6B7280`**.
- **Fix:** register/use Archivo for headers (via `DXType.swift`); set weekday and number sizes as above.

---

## Priority order (highest visual payoff first)
1. **Day-cell glaze + radius 7 + 4pt grout** (§1) — turns bubbles into a mosaic.
2. **ON/OFF differentiation** (§2b) — the readability fix you flagged.
3. **De-saturate fills + legible tint labels** (§2a).
4. **Default the in-cell A/P/M chips toggle to off** (§3).
5. **Palette stripe in + green bar out** (§4).
6. **Compact header / icon tiles** (§5) and **month-header counts** (§6).
7. **Flat native tab bar (kill the floating capsule)** (§7).
8. **Archivo + type sizes** (§8), **warning-badge readability** (§2c).
9. **Light mode: tile shadow + ON/OFF split** (§9) and **blackout re-language** (§2d) — do these alongside their dark-mode counterparts, not after.

Every step is independent and shippable on its own; build and eyeball against the mockup after each. **Test every change in both light and dark before moving on** — the neutrals (ON / OFF / blackout) behave very differently between modes.

---

## 9 · Light mode
All of the above is token-based and adapts automatically, but light mode currently fails in two specific ways the dark screenshot doesn't show:

- **9a. Tiles melt into the page.** The near-white background and flat pale tiles have almost no separation. **Fix:** the default/ON tile must be a **white glazed tile with a drop shadow** (`0 1px 2px rgba(0,0,0,.12)` + inner top highlight, per §2a light table). The shadow is what makes the grouted grid legible on white — without it there's no grid.
- **9b. ON vs OFF is invisible.** Both are pale gray. **Fix:** ON = lifted white (with shadow); OFF = flat, shadowless, recessed `#E2E4E9` with a dim number (§2b light bullet). Lifted vs sunken does the work.
- **9c. "Available/open" tiles (the pale-mint cells with A/P/M) wash out.** On the near-white page they're barely tinted. **Fix:** give them a touch more chroma and the same drop shadow so they read as real tiles; and with chips defaulted off (§3) they stop looking like clutter.
- **9d. Blackout** — see §2d; the light-mode matte/graphite + lock tokens are there.
- **9e. Header chrome.** In light mode the profile bar + "Mark Intents" + legend read as default iOS list chrome (hairline separators, system blue). Apply the same compact bar + palette stripe (§4–5) so light mode is on-system too, not stock UIKit.
