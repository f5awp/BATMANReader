# DX Trader — Welcome Walkthrough Specs (app 2.4, build 1)

> **Authoritative 17-page order & titles** (code is SSOT — `WelcomeWalkthrough.swift`; the numbered
> sections lower in this file predate the reorder — treat this list as the source of truth for position):
> 1. Welcome · 2. Everything from Home · 3. Compact view · 4. **Mark Your Intents** · 5. **Specify and Search
> By Day** (adds a 4th callout on the Trade List tab) · 6. **Match ⇄ Match** · 7. Track your ECB (ledger) ·
> 8. Channels & Messages · 9. The color language · 10. Dig Deeper · 11. **Find Trades Searches Further** ·
> 12. **Broadcast your ECB Requests** · 13. Find a Dispatcher · 14. Respond your way · 15. You're set ·
> 16. Set your preferences · 17. Before you start.
>
> Copy notes: Intents drops all "brush/paint" language and uses "Choose Day-for-Day / ECB". `wt-dispatcher`
> now shows an **expanded** directory row (info · Find Trades · Message), anonymized incl. fake employee #,
> a 555 phone, and a generic email. ECB legend mark is `dollarsign.circle.fill`. All screenshot pages are
> current (new "Find Trades" top bar). Assets: `wt-trade-options`, `wt-tradelist`, `wt-dispatcher`, `wt-channels`.


Design spec for the first-run / replayable welcome tour (app 2.4, build 1). Covers Direct Messages, calendar
markers, notifications, ECB, and Dispatcher, plus the Compact view page and anonymized screenshot captures
(own name → "Dispatcher", "DX" avatar; see `SCREENSHOT-CAPTURE.md`). Hand this to a design tool
(Fable / Claude design). Source of truth in code: `WelcomeWalkthrough.swift`.

---

## Design system

**Theme:** dark only. Portrait phone. Full-screen cover.

**Palette (hex):**
| Token | Hex | Use |
|---|---|---|
| bg | `#0D0D0F` | page background |
| card | `#1C1C20` | cards / chips |
| stroke | `#2A2A30` | 1px card borders |
| text | `#F2F0EB` | headings / primary |
| dim | `#A8A8B0` | body copy |
| faint | `#7D7D85` | fine print |
| accent (brand) | `#E8502A` | logo wordmark, callout dots |
| blue | `#0A84FF` | working day, watch, primary CTA, page dot |
| green | `#30D158` | keep, success, consent CTA |
| violet | `#BF5AF2` | trade-away / intents |
| gold | `#FFC838` | want-to-work, high-demand star, pills |
| teal | `#40C8E0` | vacation, Find-a-Dispatcher |
| slate | `#7D7DA0` | blackout / lock |
| orange | `#FF9F0A` | **match disc**, 🔥, high-impact |
| red | `#FF453A` | blacked-out shift |
| pink | `#FF6482` | personal milestone star |

**Typography (SF Pro / system):** card title 22 heavy · subtitle 13.5 (dim, line-spacing 2.5) ·
body 12.5–14 · section label 11 bold, kerning 1.5, faint · wordmark 11 heavy, kerning 2.4, accent.

**Chrome (every page):**
- **Header:** app-icon mark (24pt, 6-radius) + "DX TRADER" (accent, kerned) on the left; "Skip" (dim) on the right (hidden on the last page).
- **Footer:** "Back" (dim, disabled on page 1) · centered page-dot rail (active dot = blue, elongated 20×7; others 7×7 `#3A3A42`) · a compact circular blue **arrow** button (→, 44×44) to advance — a plain icon since the 17-dot rail leaves no room for a text pill. The final (consent) page hides the arrow and uses its own gated button.

**Card types:**
1. **Text card** — title + subtitle + content (chips / list / grid). Left-aligned, 22 h-padding.
2. **Screenshot card** — title + subtitle, then a device screenshot (16-radius, 1px stroke) with numbered **accent circle callouts** positioned by %; the same numbered dots repeat below as a caption list.

**13 pages, in order:** Welcome · Everything from Home · Compact view · Tell it what you want ·
The color language · It finds real trades · Dig deeper in the Trades tab · Respond your way · ECB made fair ·
Track your ECB · You're set · Set your preferences · Before you start.

---

## Page 1 — Welcome (text card, centered)

- App-icon mark (104pt, 22-radius), centered.
- **Title:** "Welcome to DX Trader" (30 heavy).
- **Body:** "It reads the BATMAN schedule for you and finds trades that actually work. Do everything from Home — then dig deeper in the Trades tab. Here's the two-minute tour."
- **Chips (stacked, capsule, card fill + stroke):**
  - "Everything from Home"
  - "Trade Inbox · Channels & Messages · ECB"
  - "Compact view when you want it"
  - "Dig deeper in the Trades tab"

## Page 2 — Everything from Home (screenshot: Home calendar)
> Refreshed anonymized capture (`wt-home`, own name → "Dispatcher").

- **Title:** "Everything from Home"
- **Subtitle:** "Home does it all — your schedule, your intents, and the top-bar hubs: Trade Inbox, Channels & Messages, ECB Accounting, and a Compact view. It stays current automatically."
- **Callouts:**
  1. (top-right hubs) "Top bar: Trade Inbox · Channels & Messages · ECB · ⋯"
  2. (Mark Intents) "Mark Intents — paint days, then set Day or ECB terms"
  3. (a colored day) "Tap any colored day to open its Trade List & matches"

## Page 3 — Compact view (screenshot: compact calendar)
> New page. Anonymized capture (`wt-compact`).

- **Title:** "Compact view when you want it"
- **Subtitle:** "Tap the compact icon to switch to a continuous, denser calendar — more months at a glance for planning ahead. Same colors, same marks."
- **Callouts:**
  1. (compact icon) "Tap the compact icon for a continuous, denser calendar"
  2. (month divider) "Months flow inline — SEP · OCT · NOV — scroll to plan ahead"
  3. (a colored day) "Same colors and marks, just tighter cells"

## Page 4 — Tell it what you want (screenshot: Mark Intents — working-day brush)
> Refreshed anonymized capture (`wt-intents`).

- **Title:** "Tell it what you want"
- **Subtitle:** "Paint your days with the brush: trade away, want to work, keep, or must-be-off. Keep and must-be-off are never crossed."
- **Callouts:**
  1. "Pick the brush: Working / Off, then Want to Trade or Keep"
  2. "Choose the method — Both / Day / ECB"
  3. "Save publishes your marks to the group"

## Page 5 — The color language (text card: swatch grid + marks list)
- **Title:** "The color language" · **Subtitle:** "One hue, one meaning — the same everywhere."
- **DAY COLORS** (2-col swatch grid, 14pt rounded chips):
  Working `#0A84FF` · Trade away `#BF5AF2` · Want to work `#FFC838` · Keep `#30D158` ·
  Blackout·lock `#7D7DA0` · VAC `#40C8E0`
- **MARKS & BADGES** — each row is an **SF Symbol** (rendered in the mark color) + label:
  - `circle.fill` orange — **Match** — bold orange disc behind the date (most visible)
  - `star.fill` gold — High-demand / holiday — top-right star (a MID counts for the night-before holiday)
  - `star.fill` pink — Personal milestone — pink top-right star
  - `exclamationmark.circle.fill` blue — Watching this day — top-left
  - `a.circle.fill` gold — Availability pills — shifts you'd work on an off day
  - `xmark` red — Shift type you've blacked out
  - `flame.fill` orange — Both marked the day — strongest match
  - `book.fill` green — Bookend — pickup touches your days off
  - `q.square.fill` gold — Needs a third-person qual bridge
  - `note.text` blue — Note — blue (public) / orange (private)
  - `arrow.left.arrow.right` blue — Day-for-day trade — swap a shift for a shift
  - `dollarsign.circle.fill` gold — ECB trade — give a shift away for points

## Page 6 — It finds real trades (screenshot: Find Trades solutions)
- **Title:** "It finds real trades"
- **Subtitle:** "The app searches the whole roster and shows only trades that pass every rule — best ones on top."
- **Callouts:**
  1. "Two-person, multi-person, even circular loops"
  2. "🔥 = you both marked it · 📖 = keeps days off together"
  3. "Propose sends it straight to their Inbox"

## Page 7 — Dig deeper in the Trades tab (text card: feature list)
> Text card (no screenshot). Each feature = SF-symbol tile (34pt, 10-radius, color@13% fill + 33% stroke) + bold title + dim body, on a card row.

- **Title:** "Dig deeper in the Trades tab"
- **Subtitle:** "Home covers the everyday — mark days, see matches, propose. When you need more, the Trades tab goes further."
- **Features:**
  - `person.crop.circle` (teal) **Find a Dispatcher** — "Look someone up for their info and quals, find trades with just them, or send a direct message."
  - `slider.horizontal.3` (violet) **Complex searches** — "Search a date range, build from your marked intents, or send ECB out — with granular filters for shift type, qual, and dates."
  - `person.3.fill` (gold) **Go wide** — "Multi-person and circular solutions — up to four dispatchers deep — when a straight two-way isn't there."

## Page 8 — Respond your way (screenshot: package / twin calendars)
- **Title:** "Respond your way"
- **Subtitle:** "Pick and choose right on the two calendars — keep just the days that work. The most optimal match comes first; alternate dates show up after."
- **Callouts:** 1. "What you give and what you get, up top" · 2. "Twin calendars — your days and theirs, side by side" · 3. "\"Select specific days\" = partial accept"

## Page 9 — ECB, made fair (screenshot: ECB queue)
- **Title:** "ECB, made fair"
- **Subtitle:** "Give a shift away one-way for ECB credit — claimed in a first-come queue everyone can see."
- **Callouts:** 1. "Set the ECB you're offering" · 2. "Only people who can actually cover are offered" · 3. "Send to bookends, everyone, or the people you pick"

## Page 10 — Track your ECB (screenshot: ECB ledger)
- **Title:** "Track your ECB"
- **Subtitle:** "The ledger keeps score — what's cleared, what's coming, and who owes whom."
- **Callouts:** 1. "Available now — cleared credit, capped at 144" · 2. "Projected — once scheduled ECB and IOUs land" · 3. "Force a line through for your own books before the other side confirms"

## Page 11 — You're set (text card: checklist)
- **Title:** "You're set" · **Body:** "Five things, and you're trading. The more of us on it, the better the matches get — for everyone."
- **Checklist rows** (green ✓ + card row): Turn on iCloud & the shared calendar · Set your openness & blacklists · Mark a month of intents · Run one search & propose a trade · Post anything odd in # feedback.
- Fine print: "It's in validation — try to break it. Real use is what finds the sharp edges."

## Page 12 — Set your preferences (embedded Trade Settings)
- **Title:** "Set your preferences" · **Subtitle:** "So you only see trades you'd actually take — change any of this anytime in Trade Settings."
- **Body:** embeds the **exact Trade Settings tab** (Match Radar · Openness + date-range override · Trade Acceptance: Blacklist (shift types / regions / specific days / desks) · ECB · Qual Swap · Relief), each with an (i) info bubble; every change publishes + syncs live. (Render as a rounded, inset form.)

## Page 13 — Before you start (consent, gated)
- **Title:** "Before you start" · **Subtitle:** "The short version — tap each to agree."
- **Three consent rows** (tappable checkbox card; checked = green fill + ✓):
  1. "It organizes trades — the official trade still goes through the normal process."
  2. "It's a volunteer beta, provided as-is — I'll confirm trades against the posted schedule."
  3. "My data lives in my iCloud. No company server, no ads. Use is voluntary."
- **Gated CTA:** disabled "Tap all three to continue" → enabled green "Agree & Get Started".
  - **Persistence:** once consent is recorded (timestamp stamped once), a replay of the tour shows the
    three boxes **pre-checked** and the CTA enabled — the user never re-agrees, and the original timestamp
    is preserved.
- Fine print: "Not affiliated with or endorsed by the employer. Full terms in the app."

---

## Screenshot status

**Refreshed in v2.5** (anonymized per `SCREENSHOT-CAPTURE.md`): `wt-home`, `wt-intents`, `wt-compact`.
**Unchanged (still fine):** `wt-solutions`, `wt-package`, `wt-ecb-queue`, `wt-ecb-ledger`.

Still-optional future captures (not yet in the flow):
- **Day detail** — the Trade options group (Day/ECB/Either, ECB amount + IOU, shift/qual/date scope, note) and the **Trade List** of matches for that date.
- **Channels & Messages** — the Channels ↔ Messages group toggle + a DM thread.

> All screenshot pages must be captured in **anonymized form** — own display name shows as "Dispatcher"
> with a "DX" avatar, and any peer names as "Dispatcher B / C / D…". See `SCREENSHOT-CAPTURE.md` for the
> two ways to produce that (in-app demo data, or the CoreGraphics header-redaction script).
