# DX Trader — launch screen build spec (option 1c, iPhone + iPad)

Chosen design: **dark launch, DX + planes mark centered, "DX TRADER" wordmark, and a full-mosaic-photo rectangle band pinned near the bottom.** Static (iOS launch screens can't animate — the planes float only in the mockup; the launch asset is one still frame).

The whole thing is **centered content on a solid dark fill**, so it adapts to every iPhone and iPad size and both orientations with no per-device layout. Two elements only: the mark image and the mosaic band.

---

## 1 · Assets to add (Assets.xcassets)
- **`LaunchMark`** — one composited image containing the white **DX** glyph + the two orange planes + the letter-spaced **"DX TRADER"** line beneath it. Baking the wordmark into the image avoids any custom-font dependency at launch (custom fonts are fragile in launch storyboards). Provide as a **PDF vector** (Single Scale, "Preserve Vector Data") or `@1x/2x/3x` PNGs with transparent background. Design canvas ~ 420×360 pt.
  - Colors: DX + wordmark tint off-white `#F5F3EE`; planes orange `#E9542B`; wordmark tracking ~5.
- **`mosaicBand`** — the real mosaic photo strip (already in the handoff `Assets/`). Use a wide crop (e.g. 1200×80) so it stays crisp when the bar is 240–320 pt wide.
- **Launch background color** — add a color asset `LaunchBG` = `#0E0F11` (match the app's dark background token so launch → first screen has no color jump).

## 2 · Build route A — LaunchScreen.storyboard (recommended)
Works on iPhone + iPad automatically; no code.

1. **Root view** background = `LaunchBG`.
2. **`LaunchMark` UIImageView**
   - `contentMode = .scaleAspectFit`, `clipsToBounds = true`.
   - Constraints: **centerX = safeArea.centerX**, **centerY = safeArea.centerY** (or nudge up: centerY with multiplier ≈ 0.92).
   - **Fixed width = 200 pt** + an **aspect-ratio constraint** (from the asset). Do **not** pin leading/trailing — the fixed width is what keeps the mark a modest size instead of ballooning on iPad.
3. **`mosaicBand` UIImageView**
   - `contentMode = .scaleAspectFill`, `clipsToBounds = true`, **cornerRadius = 0** (sharp rectangle).
   - Constraints: **centerX = safeArea.centerX**, **bottom = safeArea.bottom − 34**, **width = 260 pt** (fixed/capped — never full-bleed, or the photo smears on a wide iPad), **height = 13 pt**.
4. In target settings, set **"Launch Screen File" = LaunchScreen**. Ensure iPad + all orientations are enabled under Supported Interface Orientations — the centered layout resolves in each automatically.

### iPad polish (optional, nice-to-have)
Add **size-class variations** for **Regular width / Regular height** (iPad): bump `LaunchMark` width 200 → **300 pt** and `mosaicBand` width 260 → **360 pt**. Everything else stays. This makes the mark feel intentional on the larger canvas rather than small-in-a-sea-of-black.

## 3 · Build route B — SwiftUI (only if you also want an in-app splash)
The static storyboard above is the true launch screen. If you want a SwiftUI splash/loading view *after* launch (this is where the planes may actually animate, per the system's "motion = loading" rule):

```swift
struct LaunchView: View {
    var body: some View {
        ZStack {
            Color(hex: 0x0E0F11).ignoresSafeArea()
            VStack(spacing: 22) {
                Image("LaunchMark")
                    .resizable().scaledToFit()
                    .frame(width: horizontalSizeClass == .regular ? 300 : 200)  // iPad vs iPhone
            }
            VStack {
                Spacer()
                Image("mosaicBand")
                    .resizable().scaledToFill()
                    .frame(width: horizontalSizeClass == .regular ? 360 : 260, height: 13)
                    .clipped()                       // rectangle, no cornerRadius
                    .padding(.bottom, 34)
            }
        }
    }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
}
```
- `scaledToFit` on the mark + fixed width per size class = same "centered, capped" behavior as the storyboard.
- Keep the launch storyboard as the real cold-start screen; only animate planes here in the in-app loading state, never in the launch file.

## 4 · Rules recap
- **Fixed mark size**, centered — do not scale to screen.
- **Capped mosaic bar width**, centered on the bottom safe area — never full-bleed.
- **Rectangle bar** (cornerRadius 0), using the real mosaic photo.
- **Static** launch; background matches the app's dark token.
- iPad = same file; the fixed-size centered composition + optional size-class bumps handle it.
