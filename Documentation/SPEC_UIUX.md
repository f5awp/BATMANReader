# BATMAN Watcher — UI/UX Spec (Layouts, Components, Copy, Interactions)

> Built **on top of** `SPEC_STRUCTURAL.md` (referenced as "S-…"). Traces to `NEXT_CHANGES.md` items.
> Written to be **exact and non-ambiguous**. Where a token, color, font, or string is specified, use
> it verbatim. Tone target throughout: **clean, professional, Fortune-500 training-grade copy** [I1].
>
> **Design system (from `DispatchPalette.swift`) — use these, do not hardcode new values:**
> - Spacing `DS`: `xs 4 · s 8 · m 12 · l 16 · xl 24`. `cardRadius 14 · cardPadding 14 · rowRadius 12 ·
>   pillRadius 8 · pillFill 0.16 · avatar 30`.
> - Font ramp (R2-#10d, scaled up): `dsCardTitle` (subheadline.semibold), `dsCardMeta` (caption), `dsChip`
>   (subheadline.semibold), `dsBadge` (caption.heavy), `dsLabel` (caption.bold).
> - Trade colors: `mineScheme` (blue, you give), `peerScheme` (red, you take), `loopTrade` (violet,
>   circular), `traderThemes[]` (per-trader rotation), `highImpact` (gold), `personalDay` (pink).
> - Dynamic Type clamps where layout is tight (`.dynamicTypeSize(...DynamicTypeSize.xLarge)`).
> - **New colors to add** (S-UIUX-NEW): `qualSwap` (teal/cyan — qual-swap pending), `vacation`
>   (muted green-gray, distinct from `openOff`), `urgentAlert` (high-saturation red/orange for invalid).

---

## U-GLOBAL — Cross-cutting patterns

### U-GLOBAL-1 — Tier separators in every ranked list [C6, R6]
Anywhere options are grouped by tier (Trade Search, Individual Swaps, packages, candidates):
- Separate tiers with a **thin 1pt divider** (`.quaternary`) **plus** a small tier label in `dsLabel`
  (e.g., "Intent matches", "Bookends", "Other options"). If a label would crowd, use **`DS.l`
  vertical space** alone. Order = S-ENG-7 (intent → bookend → other).
- This pattern is **identical** across screens (one reusable `TierSectionHeader` view).

### U-GLOBAL-2 — Unified legend / keys [C6, I1]
- One reusable `TradeLegendSheet` documents **all** colors/markers (give/take, circular, bookend,
  intent 🔥, vacation, qual-swap, high-impact, personal day). Remove the per-screen ad-hoc keys; every
  screen opens this same sheet via an **ⓘ** affordance.
- A **usability pass [I1]:** any control whose meaning isn't obvious gets either an inline caption or
  an ⓘ to the legend. Err toward a one-line caption over a hidden key.

### U-GLOBAL-3 — Status shown by name, everywhere [A7/B8]
Wherever a dispatcher's name renders (cards, chips, message rows, candidate rows), show their
`statusBroadcast` in **italics**, placed **next to** the name if horizontal space allows, else
**directly under** it, truncated with tail ellipsis. Never let it wrap to more than one line.

### U-GLOBAL-4 — Character counters [F3]
Every length-limited field shows a live "used/limit" counter that appears as you approach the limit:
notes (≤50), status (≤140), private notes (≤2000), chat composer. Counter uses `dsLabel`, turns
`urgentAlert` within the last 10%.

---

## U-HOME — Home page (top header + metrics + calendar) [R4, A1, F1]

### U-HOME-1 — Top metrics header (pinned, first thing seen) [R4]
**Mandate:** redesign the Home top so the **metrics header**, the page title, and existing controls
(Mark Intents pill, visibility toggles, sync line) are **legible, well-spaced, never colliding.**

Exact layout, top to bottom:
1. **Metrics strip** (pinned to the very top, full width): three compact stat tiles in a row —
   - **Success** — global % (S-DATA-4 `successRate`), label "Trades accepted".
   - **Searches** — count with a **segmented period toggle** (Month / Year / All-time), label
     "Trade searches".
   - (Admin only) a small **Reset** affordance (dev-gated) on long-press of the strip.
   - Tiles use `dsBadge` for the number, `dsLabel` for the caption; separated by `DS.m`; the strip has
     `DS.cardPadding` insets and sits on a subtle `.bar` background so it reads as a header band.
2. **Title row** — "Home" / month context on the left; **Mark Intents** pill and **visibility
   toggles** on the right, with **≥ `DS.m`** gap so they never touch the metrics or each other. If
   width is tight (compact iPhone), the controls wrap to a second line rather than overlap.
3. **Private-notes bar** (existing) and **Sync line** (existing) remain below, unchanged in function.

Spacing rule: a minimum `DS.s` between any two interactive elements; the metrics strip and title row
are visually distinct bands (divider or background change), so the eye parses "stats" vs "navigation."

### U-HOME-2 — Intents calendar shows MINE + OTHERS [A1]
- The Intents calendar uses the **same theme/format as every other calendar** in the app (one shared
  calendar component; no bespoke styling). [A1]
- **My** intents render with the established fill/border language. **Others'** published intents on a
  day render as a distinct, secondary indicator (e.g., a small stack of `traderThemes` dots or a count
  chip) — visually subordinate to mine. [A1]
- Add **"Show others' intents"** to the **visibility toggle** set. When a trade is open, the two (or
  more) involved people's marked days render with border (gives away) / fill (takes) in **their**
  `traderThemes` color, and the **focused day** gets the `.primary` ring. [A1]
- Each person surfaced shows a small **Openness** note (their current openness label) near their name.

### U-HOME-3 — Bulk intent editing [F1, F2]
- A **Bulk** mode: tap **Select action** (any intent action, S-INTENT) → then **multi-select days** on
  the calendar → **Apply**. A persistent action bar shows the chosen action + an Apply/Cancel.
- **Bulk note [F2]:** same flow, action = "Add note", one note applied to all selected days (counter
  per U-GLOBAL-4).

---

## U-TRADES — Trades tab [D2, C5]

### U-TRADES-1 — Default segment + tab badges [D2]
- Trades opens on **Trade Search** (the **middle** segment) by default. [D2]
- The **Intents** segment shows an **indication bubble** with the user's intent count; if multiple
  intent types exist, show **multiple small bubbles color-coded by tier** (intent-match / bookend /
  other), using the tier colors. [D2]

### U-TRADES-2 — Remove stale copy / empty state [C5]
- Delete the "import the roster file first" text. [C5]
- When the roster genuinely hasn't synced, show: **"Waiting for the latest dispatch master to sync —
  pull to refresh."** [C5a]

---

## U-SEARCH — Trade Search [C3, C4, A1, S-ENG-7]

### U-SEARCH-1 — Day-picker calendar shows YOUR context [C3]
When selecting days to trade away, the picker calendar is **not blank** — it renders **your own**
intents, availability, notes, and topology markers (so you know what you're trading), using the shared
calendar component. [C3]

### U-SEARCH-2 — Person search + pin [C4]
- A **single unified people dropdown/search** used by **all** people-search features (Trade Search,
  qual-swap target, etc.). [E1a, C4]
- Search by name; **pin** chosen people to the top of the list. Pins persist **for the current search
  session only** (cleared when the search ends). [C4a]

### U-SEARCH-3 — Results sorting + tiers [S-ENG-7, C2c, U-GLOBAL-1]
- Results exclude anything unavailable (S-ENG-1). Sorted intent → bookend → other, with tier
  separators (U-GLOBAL-1). Single-person full-cover package sorts to the very top (S-ENG-3).

---

## U-SWAPS — Individual Swaps redesign [C1, C2]

### U-SWAPS-1 — Rename [C1]
"Individual takers" → **"Individual Swaps"** everywhere (UI + help).

### U-SWAPS-2 — Layout (top to bottom, exact) [C2]
1. **Your marked give-days** (the days you're requesting off) and **the reciprocal days that work
   back**. "**You give**" = the days you want **off**. [C2]
2. **Bookend matches highlighted** at the top — all reciprocal options that are bookends for you
   (S-ENG-2), visually emphasized, sorted above non-bookends (after intent matches). [C2]
3. **Below bookends:** the other working reciprocal options ("which other trades work"). [C2]
4. **"More picks"** — additional candidate days you can choose from yourself. [C2]
5. **Other potential trades** — a selectable list at the bottom. [C2]
- Lists are **filtered/sorted/categorized by preference and location** (S-ENG-7); never show
  unavailable days (Keep/Must-Be-Off/blacklist/openness/closed shifts). [A1, C2c]
- **Remove the Bookends filter control** — bookends still surface and sort to top, they're just no
  longer a toggle. [C2]

---

## U-CARD — Unified Package Card [B1, B2, R1, Q2, Q3, Q6]

One reusable `TradePackageCard` renders **all** trade types (1:1, ECB one-way, circular, qual-swap),
used in the **feed, inbox, and chat thread**. [B1]

### U-CARD-1 — Single trade-type label (cleanup) [B2, R1]
- Exactly **one** badge per card (S-ENG-5 precedence): **"1-Way Swap"** (ECB) · **"Qual Swap"**
  (contains a qual-swap step) · else **"{peopleCount}-Person Swap"** (e.g., "2-Person Swap",
  "3-Person Swap"). **No "Direct swap", no "N-way".** You↔Cary = **"2-Person Swap"**. [B2, R1]
- **Remove the second/contradictory label** that currently appears ("3-way trade" headline +
  "2-way trade" subtitle) — there must be only this one badge. [B2, R1]
- General card cleanup: consistent header (type + one people badge + status), `traderThemes` chips per
  participant (border = gives, fill = takes), `HandoffChain` for 3+ legs. Tap anywhere on the card →
  opens the **calendar view** focused on the trade's legs/people (reuse `PackageDetailView` steps). [B1]

### U-CARD-2 — Qual-swap presentation [Q2, Q3, Q6]
- A card whose trade includes a qual-swap step shows a **`qualSwap`-colored indicator** ("Qual swap
  requested"). [Q2]
- The qual-swap step renders as a **single line of name buttons** (NOT a card) — every candidate Q for
  that shift; **multi-select** who to contact. [Q2]
- After sending: card shows **"Waiting on qual swap"** and, as acceptances arrive (≤5), a live list of
  **"{Q} accepted — {desk} ({qual})"**, plus **"{n} of {sentCount} qual-swap requests sent."** [Q6]
- **Desk-choice [Q5/Q6]:** the desk-receiver D sees a **Choose desk** control listing accepted Qs
  whose desk passes D's blacklist; picking one + all-others-accepted → auto-finalize. [Q5, Q6]

### U-CARD-3 — Accept / Counter / Decline + chat [B1]
- Every card (inbox/thread) exposes Accept / Counter / Decline and, for qual-swap candidates, their
  own Accept / Decline. Below the card, free-form **chat** (U-MSG). [B1]

---

## U-INBOX — Trade Inbox [B1, B3]

- **All trades as cards** (U-CARD). [B1]
- **Archive / Delete** actions on each item (swipe + button). **Delete** = forever; **Archive** =
  hidden but in history (S-VALID-3). Archived items live under an **Archived** section. [B3]
- **Invalid trades [B3/S-VALID]:** render with the **`urgentAlert`** treatment — a bold banner
  ("This trade may no longer work — {reason}") in heavier type, and the **Delete/Archive control is
  highlighted**. The banner **auto-clears** if the blocking condition reverses. [B3]
- Status badges include `.waitingOnQualSwap` and `.invalid` (S-DATA-3) with distinct colors/icons.

---

## U-MSG — Messaging & Channels [R6, B4, B5, B6, B7, A2]

### U-MSG-1 — Channels [R6]
- Channel switcher order: **General · Trades · Feedback**. [R6]
- **Unread indicator:** a count circle on **each** channel; the **General** entry/button also shows the
  **total** new-message count across channels. Counts **reset when the user opens** that channel/message;
  **not** when minimized or already within an open thread. [R6, A2]

### U-MSG-2 — Edit / delete (everyone, own messages) [B4, R6]
- Anyone can **edit** and **delete** their **own** posts/replies/chats. Edited items show
  **"edited · {time}"** (`dsLabel`). Deleted items render a **`[Deleted]`** tombstone (keeps thread
  continuity). [R6]

### U-MSG-3 — Admin moderation [B7, R6]
- Admin (DevAccess unlocked) can **pin to top** of each channel, and **edit/delete (moderate)** anyone's
  content. [B7, R6]
- On moderation, the admin is **prompted for a reason** (required). The **reason + timestamp** render
  at the **bottom** of the affected item in **small, light, italic** font (e.g., `dsLabel`,
  `.secondary`, `.italic()`): "Moderated by {admin} · {time} — {reason}". [R6]

### U-MSG-4 — Reactions, images/GIF, emoji [B5, B6]
- **Emoji reactions** on posts, replies, and 1:1 chat — any Apple emoji; reactions show as chips with
  counts. [B6]
- **Image + GIF** posting in chat and channels (photo library; **no in-app GIF search**); animated GIFs
  play inline. [B5]
- **Apple emoji** allowed in chat, **status**, and **private notes**. [B5/B6]

---

## U-ECB — ECB controls [R3, A4]

- ECB price stepper: **min 5, max 25, step 0.5** (S-ENG-8). Display one decimal only when fractional
  (e.g., "13.5 ECB", "9 ECB"). [R3]
- The ECB section's targeting [E earlier]: **toggle All**, **Bookends only**, or **search a specific
  person** (via the unified people dropdown, U-SEARCH-2). [item 33/35 context]
- A one-line caption explains ECB to new users (1 ECB = 1 hr pay), behind the ⓘ legend. [I1]

---

## U-VAC — Vacation display [P1d, user correction]

- Vacation days (`leaveCode == "V"`) render as a **distinct `vacation`-colored state**, visually
  different from a plain day off, labeled **"Vacation"** on tap. [P1d]
- On the **current user's own** calendar, a vacation day shows an **auto-set Must-Be-Off** intent that
  the user can **freely change** (it is a normal intent chip, not locked). [user correction]
- **Vacation is NOT hard-blocked from trading.** A user may clear the Must-Be-Off and **trade into**
  their vacation day; the UI must allow selecting/offering it once the intent is cleared. Nothing about
  the vacation day is disabled or hardcoded. [user correction]

---

## U-SETTINGS — Settings [Q4, D1, I1]

### U-SETTINGS-1 — Qual-Swap section [Q4]
- New **Qual Swap** section with:
  - A **ranked, drag-to-reorder list** of the user's own quals (highest preference on top) — maps to
    `qualRanking` (S-DATA-2). Inline caption: "You'll qual-swap into a desk only if its qualification
    ranks equal or higher than the one you're working." [Q4]
  - A **Qual-Swap Blacklist** editor for desks and quals you'll never work. [Q4]

### U-SETTINGS-2 — Defaults [D1]
- New users default openness to **Bookends** (S-ENG-1 / SettingsManager). Verify onboarding doesn't
  override. [D1]

### U-SETTINGS-3 — Guides & tone [I1]
- Fix the Help + Tester guides: update renamed terms (Individual Swaps), correct any stale steps, and
  apply **Fortune-500 training-grade tone** — careful, concise, professional word choice. Run the
  usability pass (U-GLOBAL-2) to add keys/captions where meaning isn't obvious. [I1]

---

## U-NOTIF — Urgent notification styling [B3, S-VALID-2]

- Invalid-trade / availability-change alerts use **`urgentAlert`** color, heavier weight (at least
  `.semibold`), and direct, plain wording: "Action needed: {Name} is no longer available for {day}."
- These appear in the **status bar** area and on the affected **package card** banner, and clear
  automatically when resolved. [B3]

---

## U-EMAIL — Outlook trade-board email design [G1–G3, un-deferred]

Designed by mirroring the **real DL_Dispatch_Trades board** (the four samples: single-day, day-group,
ECB, "day for day") so it feels native to dispatchers — then **enriched** with app data. To
`DL_Dispatch_Trades@aa.com`. Premier-grade: clean, scannable, more information than a normal post but
never cluttered. Content is identical for plain-text (path A) or HTML (path B); only styling differs.

### U-EMAIL-1 — Subject line
Mirror the board's terse convention, generated from the offer:
- Single day: **"Sunday June 21 · 0500 · FD31 — D4D/ECB"**
- Group: **"Aug 10–30 + scattered — D4D"**
- ECB-only: **"Jun 24/25 MIDs — ECB"**

### U-EMAIL-2 — Body structure (top → bottom)
1. **THE ASK** (one bold line): what's offered + trade type. e.g. *"Trading off: Fri Jun 19, 0500,
   FD31 — Day for Day or ECB (12.5 ECB)."*
2. **WANTED DAYS OFF** — month-grouped date list (board style: `July 7/8/9/21/22/30/31`), from
   `seekingDayIDs`. Days already taken render struck-through ((taken) in plain text).
3. **WANT TO WORK** — month-grouped, the off days they'll happily pick up (distinct from #2).
4. **CAN'T TRADE / BLACKOUT** — Keep + Must-Be-Off ranges (e.g. *"Blackout: Jun 20–Jul 7, Jul 20–30"*).
5. **WON'T WORK (blacklist)** — concise, human (e.g. *"No Pacific desks; no Saturdays"*) — only if set.
6. **NOTE** — optional reason line.
7. **CONTACT** — Name · Title · Base · "Text is best {phone}" · AA email (from settings).
8. **FOOTER** — *"Generated by BATMAN Watcher"* + **"Open this trade →"** deep link
   (`batmanwatcher://trade/<id>`).

### U-EMAIL-3 — Visual design (HTML path B, if chosen)
- Single centered content column ~600pt, white card on light-gray, **Outlook-safe table layout, inline
  styles only**, web-safe font stack (`-apple-system, Segoe UI, Helvetica, Arial`).
- A slim branded header band (app name + a one-line tagline), section labels in small caps/`dsLabel`
  equivalents, generous whitespace, a single accent color (`mineScheme` blue) for headers + the CTA
  button. No images that could be blocked; the CTA is a bulletproof table button.
- Struck-through taken dates; month labels bold; dates in a tidy wrap. Footer in light gray italic.

### U-EMAIL-4 — Entry point (one action)
- **"Post to Trade Board"** — opens **Outlook plain-text** compose (S-EMAIL-2): To = DL, subject
  (U-EMAIL-1), body = trade data + a **short stats/pitch tail** (`TradeBoardCopy`, S-EMAIL-5). **No
  attachment, no flyer** (dropped). User edits before sending.

> **Flyer dropped for now** (no attachment path on work iPads). The premium `TradeBoardCopy` (S-EMAIL-5)
> is the canonical pitch; it appears as the short email tail and, later, an in-app About screen. No
> graphic one-pager is built at this time.

---

## U-DEFER — Deferred UI (logged, not now)

- See-all-trades view [B1a], dedicated qual-swap search screen [Q-c]. Mirror `SPEC_STRUCTURAL.md`
  S-DEFER.

---

## U-BUILD-ORDER — Suggested UI build sequence (after/with structural)

1. **Card cleanup** (U-CARD-1) + **participant count** — fastest visible correctness win. [B2]
2. **Vacation display** (U-VAC) once parsing lands.
3. **Home metrics header** (U-HOME-1) + intents-show-others (U-HOME-2).
4. **Trade Search defaults/empty-state** (U-TRADES) + **picker context** (U-SEARCH-1) + **person
   search/pin** (U-SEARCH-2).
5. **Individual Swaps redesign** (U-SWAPS).
6. **Inbox archive/invalid** (U-INBOX) + **urgent styling** (U-NOTIF).
7. **Channels/edit/delete/moderation/reactions/media** (U-MSG).
8. **Qual-swap UI** (U-CARD-2) on top of S-ENG-4.
9. **Settings** (U-SETTINGS), **ECB stepper** (U-ECB), **bulk intents** (U-HOME-3), **counters/legend**
   (U-GLOBAL).

> Definition of Done per item = `SPEC_STRUCTURAL.md` build discipline + the AC here, verified
> on-device. One label, one legend, one calendar component, one people dropdown — no duplicates.
</content>
