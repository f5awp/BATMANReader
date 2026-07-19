# Welcome-Walkthrough Screenshot Capture & Anonymization

How the `wt-*` screenshots in the welcome tour (`WelcomeWalkthrough.swift`, spec in
`WELCOME-SCREEN-SPECS.md`) are produced. The hard rule: **no real names ship in the tour.**

The shipped convention (visible in the older `wt-solutions` / `wt-home` assets):

- Your own display name renders as **"Dispatcher"** with an orange **"DX"** avatar tile.
- Peer names render as **"Dispatcher B", "Dispatcher C", "Dispatcher D"…** — never real names.

There was no in-app "anonymize" toggle and no prior doc; the old shots were simply captured against
anonymized/demo data. This file records both supported ways to get there so it isn't lost again.

---

## Assets & where they live

Asset catalog (authoritative — this is what builds):
`BATMANReader/Assets.xcassets/wt-<name>.imageset/wt-<name>.jpg`, referenced by `Image("wt-<name>")`.

| Asset | Page | Source screenshot |
|---|---|---|
| `wt-home` | Everything from Home | Home calendar (single month) |
| `wt-compact` | Compact view | Home in compact/continuous mode |
| `wt-intents` | Tell it what you want | Mark Intents brush open |
| `wt-trade-options` | Complex intents | Day-detail Trade options (method · ECB/IOU · scope) |
| `wt-tradelist` | Trade List | "Who could work this day" (roster — anonymized) |
| `wt-solutions` | It finds real trades | Find Trades ▸ Date Range solutions (roster — anonymized) |
| `wt-dispatcher` | Find a Dispatcher | Dispatcher directory (roster — anonymized) |
| `wt-package` | Respond your way | Twin-calendar package |
| `wt-ecb-queue` | ECB, made fair | Find Trades ▸ ECB queue (roster — anonymized) |
| `wt-ecb-ledger` | Track your ECB | ECB ledger (current — keep) |
| `wt-channels` | Channels & Messages | Channels ↔ Messages, empty channel |

Loose copies at `BATMANReader/wt-*.jpg` are legacy; keep them in sync but the imageset is what matters.
Source frames are 1290×2796 (iPhone Pro, 3×); `Image(...).scaledToFit()` handles the rest, and callouts are
anchored by fraction of the image, so exact size isn't critical.

---

## Method A — capture already-anonymized (preferred for peer-name screens)

For any screen that shows **other people** (Find Trades solutions, Trade List, Dispatcher directory), the
only clean path is to capture against anonymized data so peers already read "Dispatcher B/C/D…". Set your
own profile name to "Dispatcher" in Settings before shooting so the header needs no post-edit either.

## Method B — redact the header after the fact (for own-name-only screens)

Home / Compact / Intents show **only your own name** in the top-left header (avatar + "Lee, Ervin"); the
top-right hub icons must stay (they're a page-2 callout). For these, capture normally, then run the
CoreGraphics redactor, which paints the shipped convention over the header:

```sh
swift Documentation/tools/redact-welcome-header.swift <in.png> <out.jpg>
```

What it does (`redact-welcome-header.swift`): draws the original frame, blacks out the name text region
(header bg is pure black, so the bar is invisible), repaints the avatar as an orange `#E48B30` rounded tile
with white **"DX"**, and writes white **"Dispatcher"** (HelveticaNeue-Bold) where the name was. Output is JPEG.

Header geometry is hard-coded for 1290×2796 frames (name row centered at image-top y≈255, avatar box
x[44,134] y[210,300]). If Apple moves the header or you shoot at another size, re-measure with:

```sh
sips -c 130 1290 --cropOffset 190 0 in.png --out /tmp/hdr.png   # crop the header band to eyeball coords
```

and adjust the constants at the top of the script. Always eyeball the output header after running.

### Install

```sh
cp out-home.jpg    BATMANReader/Assets.xcassets/wt-home.imageset/wt-home.jpg
cp out-intents.jpg BATMANReader/Assets.xcassets/wt-intents.imageset/wt-intents.jpg
cp out-compact.jpg BATMANReader/Assets.xcassets/wt-compact.imageset/wt-compact.jpg
```

Same filename → the imageset `Contents.json` needs no change. A new asset needs a `Contents.json` with the
`wt-<name>.jpg` file in the `1x` slot (copy an existing one). Then build to bake the catalog.

---

## When you change a screenshot, also check the callouts

Callouts are `Callout(id:x:y:caption:)` in `WelcomeWalkthrough.swift`, positioned by fraction of the image.
A new frame usually shifts them — open the redacted image, estimate each target's x/y fraction, and update
both the on-image dot and its caption. Keep captions to what's actually visible in the frame (e.g. the v2.5
Home shot has no orange match disc, so that callout was repointed to "tap any colored day → Trade List").
