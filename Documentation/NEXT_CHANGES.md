# BATMAN Watcher — Next Changes & Bug Backlog

> Source: raw notes dump (2026-06-15). This document restates each item, interprets it **only where
> the intent is unambiguous**, and flags everything uncertain under **❓ Open Questions** so nothing
> gets half-built. Items are grouped by area, each with: what you said, the interpretation, concrete
> **Acceptance Criteria (AC)**, the **files** most likely involved, and open questions.
>
> **Build discipline for every item below (Definition of Done):**
> 1. Feature is fully wired end-to-end — model → store → service → view — no stubbed branches.
> 2. Every symbol referenced exists and compiles; no `TODO`/`fatalError`/placeholder paths left live.
> 3. CloudKit additions are optional Codable fields in the JSON `payload` (no breaking schema change).
> 4. Project builds green for the iPhone simulator before the item is called done.
> 5. New UI honors the `DS` design tokens + Font ramp and the trade color language in `DispatchPalette.swift`.
> 6. Each AC is manually verifiable on-device by a tester.
>
> **Legend:** 🐞 bug · ✨ feature · 🎨 UI/UX · 🔧 config/default · ❓ needs clarification before build.
> Priority is **proposed** (P0 = blocks testers, P1 = important, P2 = polish) — confirm before sequencing.

---

## A. Current Bugs / Errors

### A1 🐞 Intent calendar doesn't show *other* dispatchers' intents (P1)
- **You said:** "Calendar in intents is different colors too. Can't see other intents…but good colors?"
- **Interpretation (confirmed parts):** In the Intents calendar, you cannot see **other** dispatchers'
  intents — only your own. The colors themselves look right.
- **AC:**
  - The intents calendar surfaces other dispatchers' published intents for a day (read from
    `TradeProfileStore.others` / availability pills), visually distinct from your own.
  - Your own intent colors remain unchanged.
- **Files:** `HomeCalendar.swift`, `HomeView.swift`, `TradeProfileStore.swift`, `DispatchPalette.swift`.
- **❓ Open Question A1a:** "different colors too" — do you mean the **same** intent shows **inconsistent
  colors across screens** (a bug to unify), or simply that the colors are good (a compliment)? If it's
  an inconsistency, tell me which two screens disagree and I'll align them.
- **❓ Open Question A1b:** When showing *others'* intents on a day, what exactly should be visible —
  count only ("3 others want this day"), names, or their give/take direction?

### A2 🐞 Channel notifications are "sticking" (P1)
- **You said:** "Channel notifs are sticking."
- **Interpretation:** Broadcast-channel push notifications/badges don't clear after you've read them.
- **AC:**
  - Opening the channel (or the specific post) clears its unread badge/notification.
  - Badge count reflects only genuinely-unread items and reaches zero after reading.
- **Files:** `CloudPush.swift`, `MessagingViews.swift` (ChannelView), `MessagingStore` (Messaging.swift), `NotificationManager.swift`.
- **❓ Open Question A2a:** "Sticking" = the **banner/notification** re-appears, the **red badge count**
  never decrements, or **the post stays marked unread** in-list? Which one (or all)?

### A3 🐞 Status & private notes don't transfer between devices (P1)
- **You said:** "status and notes don't trans btwn devices."
- **Interpretation:** A user's **status broadcast** and **private notes** are stored locally
  (`SettingsManager` → UserDefaults) so they don't follow the user to a second device.
- **AC:**
  - Status broadcast syncs across a user's devices (it's already on `TradeProfile`/`statusBroadcast` —
    confirm it's published + re-fetched).
  - Private notes sync across the same user's devices.
- **Files:** `SettingsManager.swift` (`statusBroadcast`, `privateNotes`), `TradeProfile.swift`,
  `CloudKitTradeProfileService.swift`, `TradeProfileStore.swift`.
- **❓ Open Question A3a:** **Private notes** are currently private/local. Confirm you want them stored
  in **CloudKit** (your own private DB or your public TradeProfile payload). They are described as
  "private" — syncing them via the **public** profile would expose them. Recommended: sync via the
  user's CloudKit **private** database so they stay private but cross devices. Approve that approach?

### A4 🐞 ECB shows a ".5" count (P1)
- **You said:** "ECB .5 Count."
- **Interpretation:** An ECB counter is displaying a fractional value (e.g., 0.5 / 1.5).
- **Files:** `MessagingStore` (Messaging.swift — ECB queue/counts), `TradesView.swift`, `AvailabilityView.swift` (ECB section).
- **❓ Open Question A4a:** Where exactly does the ".5" show — the Trades dashboard counter, the ECB
  offer row, or the per-shift queue position? A screenshot or the label text would pin it instantly.

### A5 🐞 One-way (ECB) trade sometimes renders as a package (P1)
- **You said:** "1-Way trade showing up as package sometimes, why?"
- **Interpretation:** A one-way ECB pickup is occasionally being built/displayed as a reciprocal
  **TradePackage**, which it should not be.
- **AC:**
  - One-way ECB items never appear in the reciprocal-package feed; they live only in the ECB flow.
  - Package methodology (`greedy`/`circular`) is never assigned to a one-way item.
- **Files:** `TradeRouter.swift` (`packages(...)`), `TradeIntentsFeed.swift`, `Messaging.swift` (`TradeRequest.ecb`).
- **❓ Open Question A5a:** Do you recall the repro (which screen, what you'd selected)? If not, I'll
  audit `TradeRouter.packages` for a path that emits a package when `giveDayIDs`/`takeDayIDs` are
  one-sided.

### A6 🐞 Intent matches don't work (P0)
- **You said:** "intent matches don't work."
- **Interpretation:** The 🔥 "mutual intent" matching (you want to give a day they'd take **and**
  vice-versa) is not producing matches when it should.
- **Files:** `TradeMatcher.swift` (`goldCount`, candidate gating), `DayIntentStore.swift`
  (`seekingDayIDs`), `TradeProfile.swift` (`wouldPickUp`), `TradeRouter.swift`.
- **❓ Open Question A6a:** This is the highest-impact bug but the least specified. Please give one
  concrete failing case: your marked give-days, the other person's marked days, and what you expected
  to match. With one real example I can write a failing EngineTest first, then fix to green.

### A7 🐞 Status messages leak everywhere a name appears (P2)
- **You said:** "Status messages showing under anything where your name shows up."
- **Interpretation:** This reads as a **bug** (status text appearing in places it shouldn't) — but
  item B-status (C-? below) asks for the opposite. See **B7** for the intended-feature version.
- **❓ Open Question A7a:** Is "status messages showing under anything where your name shows up" a
  **complaint** (it's showing in the wrong places — list them) or the **feature request** that your
  status *should* show under your name everywhere? These are opposites; I won't build until you pick.

---

## B. Messaging, Inbox & Trade Cards

### B1 ✨ Every trade renders as a clickable package card (P1)
- **You said:** "Make all trades cards." / "Perhaps trade inbox will have the unfiltered cards?" /
  "Send trade as package card where they can click to see calendar."
- **Interpretation (confirmed):** Every trade — 1:1, one-way ECB, and circular/multi-person — is
  presented as the **same package card** component, in the feed **and** the inbox **and** the sent
  message. Tapping the card opens the calendar view for that trade's legs (this exists in
  `PackageDetailView`'s clickable steps — reuse it).
- **AC:**
  - A single reusable `TradePackageCard` view renders 1:1, ECB, and circular trades consistently.
  - The card is tappable → opens the dual/step calendar focused on that trade's days + people.
  - Inbox, the intents feed, and the chat thread all use this same card.
- **Files:** `MessagingViews.swift` (InboxView, ThreadView), `TradeIntentsFeed.swift` (`PackageDetailView`, `HandoffChain`, `TraderChips`), `TradeRouter.swift`.
- **❓ Open Question B1a:** "unfiltered cards" in the inbox — does "unfiltered" mean *show every
  incoming request without the current status filtering*, or *render the raw package without the
  give/take summary collapse*? Clarify "unfiltered."

### B2 🎨 Swap cards must show 3-way trades correctly and open the calendar (P1)
- **You said:** "swap cards show 3-way for +Cary and show open up calendar view."
- **Interpretation:** When a trade includes a 3rd person (your example: "+Cary"), the card must show
  it as a true 3-way (not collapse to 2), and tapping opens the calendar.
- **AC:**
  - A trade with 3 participants shows all 3 on the card (handoff chain + per-trader colors).
  - `peopleCount` is correct (this was fixed for circular — verify it holds for this case).
  - Tap → calendar view with each leg's two people, per the clickable-step model.
- **Files:** `TradeIntentsFeed.swift`, `TradeRouter.swift` (`peopleCount`, `nWayRoutes`), `MessagingViews.swift`.
- **❓ Open Question B2a:** "for +Cary" — is Cary a specific reproducible test case? If you can share
  the participants + days, I'll add it as an EngineTest so the 3-way render is locked in.

### B3 ✨ Inbox: delete / archive denied or invalid trades (P1)
- **You said:** "When in an inbox and denied, be able to delete or archive." / "Be able to archive the
  check and delete the X in status bar." / "When a trade is no longer valid/dates change, mark it
  invalid and highlight the delete/archive button."
- **Interpretation (confirmed):**
  - Denied/declined inbox items can be **deleted or archived**.
  - In the status bar/dashboard, you can **archive the ✓ (accepted)** and **delete the ✗ (denied)**.
  - When a trade becomes invalid (dates changed / no longer feasible), it's flagged **Invalid** and
    its delete/archive button is **highlighted**.
- **AC:**
  - `TradeRequest`/`TradeResponse` gain an `archived: Bool` (default false) and an `invalid: Bool`
    (or a derived validity check against the current roster).
  - Inbox rows expose Delete and Archive actions (swipe + button); archived items move to an
    Archived section, deleted items are removed.
  - Dashboard counters (`accepted`/`denied`) let you archive the accepted (✓) and delete the
    denied (✗).
  - On master-roster sync, any request whose days no longer exist / changed is marked Invalid and its
    delete/archive control is visually emphasized.
- **Files:** `Messaging.swift` (models + store), `MessagingViews.swift` (InboxView), `TradesView.swift` (dashboard), `RosterStore.swift` (`syncMasterIfNewer` triggers revalidation).
- **❓ Open Question B3a:** Difference between **delete** and **archive** for you — delete = gone
  forever (local + CloudKit record removed); archive = hidden but kept in history? Confirm so the data
  model is right the first time.
- **❓ Open Question B3b:** What precisely makes a trade "invalid" — (a) any day in it changed in the
  new master, (b) the giver no longer works that day, or (c) the taker is no longer off that day?
  Likely all three; confirm.

### B4 ✨ Edit / delete your own replies, with timestamp (P2)
- **You said:** "messaging edit and delete your replies w/ timestamp."
- **Interpretation:** You can edit and delete **your own** chat replies; edited replies show an
  "edited" marker + timestamp.
- **AC:**
  - Author-only edit + delete on replies (`BroadcastReply` and the `.message` `TradeResponse` chats).
  - Edited replies display "edited · {time}"; deleted replies show a tombstone or are removed.
- **Files:** `Messaging.swift` (`BroadcastReply`, `TradeResponse`), `MessagingViews.swift`, `SlackKit.swift` (`SlackMessageRow`).
- *(Note: post edit/delete already exists for broadcasts — extend the same pattern to replies.)*

### B5 ✨ Images / GIF messages (P2)
- **You said:** "Images/Gif msg."
- **Interpretation:** Support sending images/GIFs in messages.
- **Files:** `Messaging.swift`, `CloudKitMessagingService.swift` (CKAsset attachment), `MessagingViews.swift`, `SlackKit.swift`, `SlackComposer`.
- **❓ Open Question B5a:** Scope: in **1:1 chat only**, the **broadcast channel**, or both?
- **❓ Open Question B5b:** GIFs — static images from the photo library only, or an animated-GIF
  picker/keyboard integration? The latter is materially more work; recommend starting with
  photo-library images + animated GIF playback, no in-app GIF search. Approve?

### B6 ✨ Message reactions (P2)
- **You said:** "react."
- **Interpretation:** Emoji reactions on messages.
- **Files:** `Messaging.swift` (reaction model on post/reply/response), `CloudKitMessagingService.swift`, `MessagingViews.swift`, `SlackKit.swift`.
- **❓ Open Question B6a:** Which surfaces — broadcast posts, replies, and/or 1:1 chat? Fixed reaction
  set (👍❤️✅⚠️) or any emoji?

### B7 ✨ Admin can pin messages (P2)
- **You said:** "pin msgs as admin."
- **Interpretation:** A developer/admin (DevAccess unlocked) can pin a message so it stays at the top.
- **AC:** Admin-only pin/unpin; pinned items render in a pinned section at the top of the channel.
- **Files:** `Messaging.swift` (`pinned: Bool`), `MessagingViews.swift` (ChannelView), `CloudKitMessagingService.swift`.
- **❓ Open Question B7a:** Pinning in the **broadcast channel** only, or also inside a 1:1 thread?

### B8 ✨ Your status shows under your name everywhere (P2) — *feature reading of A7*
- **You said:** "Status messages showing under anything where your name shows up."
- **Interpretation (feature reading):** Wherever your name is rendered (cards, chips, message rows),
  show your current status line beneath it.
- **Files:** `SlackKit.swift` (Avatar/row), `MessagingViews.swift`, `TradeIntentsFeed.swift` (`TraderChips`).
- **Blocked by A7a** — confirm this is the intent (vs. the bug reading) before building.

---

## C. Trade Search & "Individual Swaps" Redesign

### C1 🎨 Rename "Individual takers" → "Individual Swaps" (P1)
- **You said:** "Individual takers -> individual Swaps."
- **AC:** All user-facing "Individual takers" copy becomes "Individual Swaps."
- **Files:** `AvailabilityView.swift`, `TradeIntentsFeed.swift`, `HelpView.swift`.

### C2 🎨 Redesign the Individual Swaps flow (P1)
- **You said (verbatim):** "Mark the days that you want traded away and mark the trades that work
  back. If it shows 3 bookends, show those bookends highlighted. Then underneath, show which other 2
  trades work. For you give, it should be the days you are requesting off. Then you can choose from
  more picks to decide for yourself. Under all that you can select, other potential trades. Remove
  Bookends filter."
- **Interpretation (confirmed structure, top to bottom):**
  1. **Mark days to trade away** + **mark the trades that work back** (reciprocal days).
  2. If there are **bookend** matches, **highlight those bookends** at the top.
  3. **Underneath**, show "which other 2 trades work" — i.e., the next-best non-bookend reciprocal
     options.
  4. **"You give"** column = **the days you're requesting off** (not the days you'd take).
  5. Then **"more picks"** you can choose from yourself.
  6. **Below all of that**, a selectable list of **other potential trades**.
  7. **Remove the Bookends *filter*** control.
- **AC:**
  - The Individual Swaps screen lays out: marked give-days → highlighted bookend matches → other
    working reciprocal options → manual "more picks" → other potential trades.
  - "You give" consistently means *the days you want off*.
  - The standalone **Bookends filter** toggle is removed (bookends still *surface/highlight*, they're
    just no longer a filter — confirm in C2a).
- **Files:** `AvailabilityView.swift` (two-way explorer + Find Candidates), `TradeMatcher.swift`, `TradeRouter.swift`, `DispatchPalette.swift`.
- **❓ Open Question C2a:** "If it shows 3 bookends, show those bookends highlighted. Then underneath,
  show which other 2 trades work." — Is "3 bookends" / "other 2 trades" a **specific example** from
  one search, or a **rule** (always show up to 3 bookends, then up to 2 others)? If it's a rule, give
  me the exact counts; if it's an example, I'll show *all* bookends then *all* others.
- **❓ Open Question C2b:** Removing the **Bookends filter** — confirm bookends should still be
  *highlighted/surfaced*, just not a filter you toggle. (This also relates to D-bookends-default.)

### C3 🎨 Trade Search shows *your* intents as a bottom color bar (P1)
- **You said:** "Trade Search should show your intents (color bar on bottom)."
- **Interpretation:** While in Trade Search, render a color bar along the bottom representing your own
  marked intents (give/keep/availability), using the existing color language.
- **AC:** A persistent bottom strip in Trade Search reflects your current intent colors for the days
  in view.
- **Files:** `AvailabilityView.swift`, `ScheduleStripView.swift`, `DispatchPalette.swift`.
- **❓ Open Question C3a:** Should the bottom bar span the **days currently shown** (a mini timeline),
  or be a **legend/key** of your intent colors? "Color bar" could be either.

### C4 ✨ Search + pin a person to the top (P2)
- **You said:** "When doing search, be able to search and pin a person's name to the top."
- **Interpretation:** In the candidate/search list, search by name and pin chosen people to the top.
- **AC:** A search field filters the roster/candidate list; pinned people persist at the top of the
  list for the session (or until unpinned).
- **Files:** `AvailabilityView.swift` (Find Candidates), `SettingsManager.swift` (if pins persist).
- **❓ Open Question C4a:** Should pins **persist** across launches, or just within a session?

### C5 🔧 Remove stale "import the roster file first" text in Trade Search (P1)
- **You said:** "Trade search - remove text 'import the roster file first'."
- **Interpretation:** This message is stale now that schedules auto-derive from the master roster.
- **AC:** The string is removed; if a real empty-state is still needed, replace with accurate copy
  ("Your roster is still syncing…") — confirm in C5a.
- **Files:** `AvailabilityView.swift`, `TradesView.swift`.
- **❓ Open Question C5a:** When the roster genuinely hasn't synced yet, what should the empty state
  say instead? (Proposed: "Waiting for the latest dispatch master to sync — pull to refresh.")

### C6 ❓ Are tiers supposed to exist? + key relevance (P1 decision)
- **You said:** "Are there supposed to be tiers?" / "Check relevance of keys in trades." / "key for
  intents trade."
- **Interpretation:** This is a **product decision**, not a build task yet. Current code has 4
  `SolutionTier`s and several legend/key sheets.
- **❓ Open Question C6a:** Do you want to **keep the 4-tier model** (matching-intents / intents+
  bookends / neutral-optimization / global-pool), **simplify to fewer**, or **drop tiers** for a flat
  ranked list? This decision cascades into C2, B1, and the feed layout — let's settle it first.
- **❓ Open Question C6b:** "key for intents trade" — do you want a single unified **legend** for all
  trade/intent colors (and remove the per-screen keys), or per-screen keys that you want me to audit
  for relevance? Tell me the end state you want and I'll converge every screen to it.

---

## D. Defaults & Settings

### D1 🔧 Set Bookends as the default openness (P1)
- **You said:** "set bookends as default."
- **Interpretation:** Default `tradeOpenness` = bookends for new users.
- **AC:** New installs default to bookends; verify onboarding doesn't override it; existing users
  unaffected.
- **Files:** `SettingsManager.swift` (`tradeOpenness` default), `ContentView.swift` (OnboardingView).
- *(Note: code currently shows default "bookends" — verify it's actually applied at first run and not
  reset elsewhere. Coordinate with C2's "remove bookends filter": default ≠ filter.)*

### D2 🔧 Make Trade Search the default tab/segment (P1)
- **You said:** "trade search is default."
- **Interpretation:** When opening Trades, the **Trade Search** segment is selected by default
  (instead of Intents or ECB).
- **AC:** Trades tab opens on Trade Search.
- **Files:** `TradesView.swift`.
- **❓ Open Question D2a:** Confirm "Trade Search" = the **Search** segment of the Trades feed (not a
  rename of the whole tab).

---

## E. Channels & Broadcast

### E1 ✨ Multiple broadcast channels incl. "# discussions" and qual-based (P2)
- **You said:** "Qual swaps..different channels in broadcast. # discussions."
- **Interpretation:** Expand beyond `# trades` / `# feedback` to include `# discussions` and
  qualification-oriented channels for qual swaps.
- **AC:**
  - The channel switcher supports an extensible channel list including `# discussions`.
  - Posts carry their `channel` (already optional on `BroadcastPost`) and filter correctly.
- **Files:** `Messaging.swift` (`BroadcastPost.channel`), `MessagingViews.swift` (ChannelView switcher), `CloudKitMessagingService.swift`.
- **❓ Open Question E1a:** Exact channel list to ship — e.g., `# trades`, `# discussions`,
  `# feedback`, plus qual channels? For "qual swaps," do you want **one** `# qual-swaps` channel or a
  channel **per qualification code**? (Per-qual is powerful but needs the qual taxonomy — list them.)

---

## F. Intents — Bulk Actions & Keys

### F1 ✨ Mass-action: edit intents by selecting an action then dates (P1)
- **You said:** "mass action edit intent -> select action, then choose dates."
- **Interpretation:** A bulk-edit mode: pick an intent action first (e.g., Trade away / Keep / Must be
  off), then tap multiple dates to apply it.
- **AC:**
  - A bulk mode where you choose an action, then multi-select days, then apply in one commit.
  - Works with the existing `DayIntentStore` intent states.
- **Files:** `HomeView.swift`, `HomeCalendar.swift`, `DayIntentStore.swift`.
- **❓ Open Question F1a:** Which actions are available in bulk — the full set
  (working: must-work/want-to/neutral/don't-want; off: must-be-off/neutral/want-to-work;
  availability AM/PM/MID; topology; note)? Or a subset?

### F2 ✨ Mass-action: apply the same note to multiple days (P2)
- **You said:** "Mass action - same note."
- **Interpretation:** Bulk-apply one note (≤50 chars, with reason/private flag) across selected days.
- **AC:** Select days → enter one note → applied to all (respecting the 50-char limit + private flag).
- **Files:** `DayIntentStore.swift` (`DayNote`), `HomeView.swift`.

### F3 ✨ Character counter shown before the limit (P2)
- **You said:** "characters before limit."
- **Interpretation:** Text inputs with a max length show a live "remaining/used" counter as you
  approach the limit.
- **AC:** Notes (≤50), status (≤140), private notes (≤2000), and chat composers show a live counter.
- **Files:** `HomeView.swift`, `SettingsView.swift`, `MessagingViews.swift`, `SlackKit.swift` (SlackComposer).

### F4 🎨 Intents legend / key (P2)
- **You said:** "key for intents trade."
- *(Tracked with C6b — resolve the unified-legend decision there, then implement here.)*

---

## G. Integrations (Outlook / Email / Deep Links)

### G1 ✨ Send a trade via Outlook using a formatted template to DL_Dispatch Trades (P2)
- **You said:** "Inbox function to send via outlook in a formatted template to DL_Dispatch Trades…with
  link to BATMAN W."
- **Interpretation:** From the inbox/trade card, an action composes an email (Outlook) to the
  distribution list **DL_Dispatch Trades** using a formatted template summarizing the trade, including
  a deep link back into BATMAN Watcher.
- **AC:**
  - A "Send to Dispatch Trades" action opens a prefilled email (recipient `DL_Dispatch Trades`,
    formatted subject + body with the trade details) via the system mail composer.
  - The body contains a working deep link that opens the specific trade in the app.
- **Files:** new mail integration (MFMailComposeViewController or `mailto:`/share sheet), `MessagingViews.swift`, deep-link handling (see G3), `Info.plist`.
- **❓ Open Question G1a:** "via Outlook" — must it be the **Outlook app specifically** (custom
  `ms-outlook://` URL scheme), or is the **system mail composer / default mail client** acceptable?
  (System composer is far more reliable; Outlook-specific deep links are brittle.) Recommend system
  composer — approve?
- **❓ Open Question G1b:** Provide the **exact template** you want — subject line, body layout, and
  the real email address behind "DL_Dispatch Trades" (a display name needs a resolvable address).

### G2 ✨ Text/email contains a link back into BATMAN Watcher (P2)
- **You said:** "Text or email has link back to BATMAN W for interaction."
- **Interpretation:** Outbound texts/emails include a deep link that reopens the relevant screen/trade
  in the app.
- **AC:** Shared messages include a deep link; tapping it opens the app to the right context.
- **Files:** deep-link/URL-scheme handling, `Info.plist` (`CFBundleURLTypes` or Universal Links), `ContentView.swift` (`onOpenURL`).
- **❓ Open Question G2a:** **Custom URL scheme** (e.g., `batmanwatcher://trade/<id>`) is quick but
  only works if the app is installed and won't preview nicely. **Universal Links** need an
  `apple-app-site-association` file on a web domain you control. Which do you want? (Recommend a custom
  scheme now; Universal Links later when there's a website.)

### G3 ✨ Deep-link routing inside the app (enabler for G1/G2) (P2)
- **Interpretation:** A single deep-link router that opens a specific trade/inbox/channel from a URL.
- **AC:** `onOpenURL` parses `batmanwatcher://…` and navigates to trade / inbox / channel / day.
- **Files:** `ContentView.swift`, `Info.plist`.

---

## H. Metrics & Analytics

### H1 ✨ Trade success metrics — % successful trades (P2)
- **You said:** "metrics for % successful trade."
- **Interpretation:** Surface analytics on trade outcomes, primarily the percentage of proposed trades
  that complete successfully.
- **AC:** A metrics view shows % successful (completed ÷ proposed) over a period, derived from
  `TradeHistoryStore` + request/response data.
- **Files:** `TradeHistoryStore.swift`, `Messaging.swift`, a new metrics view.
- **❓ Open Question H1a:** Define "successful" — accepted in-app, or marked official (completed in
  ARIS)? And what denominator — all proposed, or all *responded-to*?
- **❓ Open Question H1b:** Audience — is this a **per-user** stat, or an **admin/global** dashboard
  (dev-gated)?

---

## I. Guides & Copy

### I1 🎨 Fix the guides (P2)
- **You said:** "fix guides."
- **Interpretation:** The Help and/or Tester guides need correction.
- **Files:** `HelpView.swift` (`HelpView`, `TesterGuideView`), `TESTING_GUIDE.md`.
- **❓ Open Question I1a:** What's wrong with the guides — **outdated steps** (which?), **broken
  references** (e.g., renamed "Individual takers"→"Individual Swaps"), **wrong screenshots/wording**,
  or **missing sections**? List the specific fixes; I won't rewrite blind.

---

## J. Consolidated Open Questions (must answer before building those items)

1. **A1a/A1b** — intent calendar "different colors": inconsistency or fine? What to show for others?
  1. Confirm that the trades>intents calendar is the same theme and format as all other calendars. All trade calendar formats shhould be the same - the ones in the Intents section list the trade between 2 people, but do not indicate it via border and fill in the calendar view. They dates are there underneath, but not selected. In individual trades, filter, sort and categorize the You Take, You Give lists so the best trades based on pref and location are at the top. Currently, the 2nd date recmmended between Joshua La Boy and i for You Take is June 23rd in Neutral Optimization, which I have marked as Must Not Work. Intents tab do not show any available trades, nor bookends. It seems none of the algorithm, including openness and mercernary work on this page, nor do they refresh after changing your openness and changing your marked intents. Mercerary should also turn your Openness to Open to ALl Trades. Before it was set to Not accepting trades and mercenary, which is impossible. It still did not affect my trade options,w hich means the entire algo is not being executed properly. In Trade seearch, Cary country is in a 1 person package with me, which is already not what we want, but his Jun 25 does not show a desk assignment. Trade Search packages also do not account for my marked intents, namely my Must be off on Jun 21. My Openness was moved to bookends only and the trades did not refresh. Even though bookend, I am being offered August 30 by Gar even though it does not sit next to an adjacent work week. I also  input a updated master file, and all my marked intents are now gone. ALl  trades should also show their marked intents for all involved in trade. It is public and used for trading decision.  Should put small note of each person's current Openness as well. Therefore, when i am doing a trade, I should be able to see which days they have marked as Want to trade, etc, add to visibility toggle too.
3. **A2a** — how "channel notifs stick": banner / badge / unread state? 
  1. The blue circle indicating the number of unread does not dissapear even after reading the messages. 
5. **A3a** — sync private notes via CloudKit **private** DB (keep them private)? Approve.
  1. Sync so that all of each users' devices with the app is synced privately, including private note and status. 
7. **A4a** — where the ECB ".5" appears.
  1. In the Trade > ECB, the ECB counter should go up and down by .5 increments instead of 1.
9. **A5a** — repro for one-way-as-package (or I audit `TradeRouter.packages`).
    1. I meant a trade between 2 people. Not multiple people. This can be done if all individual trades can be met by that one person. 1 person package should be brought to the top. The algo should be more exhaustive in find the most optimized trades, and reduce the number of individual trades. 
11. **A6a** — one concrete failing intent-match example (highest priority).
  1. See A1a for example. Let me know if the example does not suffice. 
13. **A7a / B8** — is "status under your name" a bug or the feature? (opposites)
  1. I want status next to, or under, depending on the most appropriate format, to show up in italics next to each users name, if space allows. 
15. **B1a** — meaning of "unfiltered cards." 
  1. A suggestion was made to have the ability to see all trades in the system, regardless if it pertains to you. Put this to the same on the queue for later. 
17. **B2a** — is "+Cary" a reproducible 3-way case?
  1. It shows up on the Trade Inbox - where i have proposed a trade to Cary Countryman. In blue, it say 3-way trade, even though thre are 2 people. Under that line, it says 2-way trade. I will upload a picture or this. If not understood, ask me for the picture if i forget to submit it. Note also that there may be a bookend error where the trade search is trading me bookend shifts from others to me, when it is no a bookend for me. Aka, it is the first day of their workweek (system thinks its a bookend but this is not how bookend should be counted in this case. It is only a bookend, if the shift youre trading to would make it a bookend). Aka, bookends for me are different from bookends for another user. 
19. **B3a/B3b** — delete vs archive semantics; exact "invalid" rule.
  1. Delete is delted forever. Archive will be hidden but be in history. Invalid means that the the day being requested to trade is no longer on that person's schedule, or someone that was available on that day, isnt anymore. Make this is a notification and have it show up on their status bar to attend to. In addition, if you mark intent to suddenly change your state from available to invavailable, or of you change your openness so that you wouldnt be available for that shift anymore, the package will show a big alert saying that the person has set openness/day avaialblity/Must be Off, etc.) for that day. It notifies both parties of this state in the status bar. It goes away if the person makes it avaiable again. Make all these notifications urgent in UI/UX, typography, and wording. 
21. **B5a/B5b/B6a/B7a** — image/GIF/react/pin scope (which surfaces).
  1. image and gif posting, but no search. be able to use apple emojis in chat but also react to messages with emojis. Allow emojis in status and private notes. Make sure you are able to delete and edit any replies, just add timestamp when editted. 
23. **C2a/C2b** — "3 bookends / 2 trades": rule or example? Bookends still highlighted after filter removed?
  1. This is an example. Bookends are still highlighted and sorted to the top, after intent matches. Unavailable status should not show up as possible days to trade. This includes openness/blacklist/individual shifts turned off/intents that make that trade unavailable to trade (Keep Shift/Must be Off)
25. **C3a** — bottom color bar: mini-timeline or legend?
  1. By this i mean, that when you are selecting days to trade search, the calendar is blank and does not show your intents, availablity, notes etc. this is important to know to know what you want to trade. 
27. **C4a** — do name pins persist across launches?
  1. Just per trade search session. 
29. **C5a** — replacement empty-state copy for Trade Search.
  1. the suggestion works. 
31. **C6a/C6b** — keep/simplify/drop tiers; unified legend vs per-screen keys. **(Settle first — it cascades.)**
  1. yes, unify but be an expert UI/UX designer and think deeply on how you will differentiate the tiers for people. I think you should atleast put a thin bar when 1 tier ends, and it goes into the next. This should be the case for all sorting tiers in this app (like trade search, individual trades, etc.) If not a line, just a space. 
33. **D2a** — confirm "Trade Search" = the Search segment.
  1. yes. make Trade Search the main page in Trades. It can stay as the middle tab. I want the Intents Tab to have a indication bubble showing how many intents they have, perhaps multiple and color coded by tiers.
35. **E1a** — exact channel list; one `# qual-swaps` or per-qual channels (+ the qual taxonomy)?
  1. just add a # General, instead. Qual swaps are an additional factor in all of this, that should be added to the algo, where because everyone is D domestic qualified, but not everyone is L Latin, P Pacific, E Euro, etc. qualified, people in those additional quals will rquest a trade from everyone, including domestic, even though their desk assignment is not domestic. they will sayt hat will handle the  qual swap, meaning, if a domestic dispatcher accepts, they will find someone who does qualify but is working a domestic desk that day, and do a 3 way trade of sorts. It would be, qual swap (so that requester now has a domestic desk) and then trade the shift. I tink that shold be aded into the app, but also, in search, perhaps you should be able to just do a simple search for a qual swap for a select shift, with the goal to trade with a select person/shift (if we can keep the person search to one drop down for all people search features, that would be best) and get solutions. All trade searches will have to consider quals now, and intents should too. This means that a 3 way trade may become a 4 + trade, if  a qual swap needs to happen in one of the legs. 
37. **F1a** — which actions are bulk-editable.
  1. All
39. **G1a/G1b/G2a** — Outlook-specific vs system mail; exact template + real DL address; URL scheme vs Universal Links.
  1. Most likely outlook only, because that is where the work mail resides. I will give you the email address later, so prompt me when building. Be a professional copy, but keep it very simple with professional typography and formatting. This is a marketing point and will be a tool to get people interested in the app. If there is a way to format Package Cards with the ability to see the 2 way calendar, that would be best. otherwise, a simple request will all the relevant information (trade date, shift, desk, ecb, any reason, etc) should be on there and it should have a nice and professional and eye-catching way for people to want to checj out our app. Be a e-mail createive marketing expert and copy and ui designer for this. 
41. **H1a/H1b** — definition of "successful" + per-user vs admin.
  1. global for everyone. show accepted on the app, not necc. on aris. also show metrics perhaps of how many trade searches this month, this year, since creation (tab-able) just as immovable headers on the top of the app. admin can reset them if needed. 
43. **I1a** — specific guide fixes.
  1. All the above, but also tone. Must an expert copy for a fortune 500 company focusd on training and UI. be careful with the words chosen. Be a usablity expert and see which parts of the UI should have a key or needs some explaining. 

---

## Q. Qual Swaps — Mechanics & Flow

**Model:** every dispatcher holds **D (Domestic)**; foreign desks (E/L/P…) require that qual
(`DeskRules.requiredQual` already derives it from desk number). When a trade leg's **taker lacks the
desk's qual**, the engine inserts a **qual-swap step**: a same-day desk exchange with a third party
**Q** who holds the needed qual and is working a desk the taker *can* take. This can turn a 2-way into
a 3-way, or a 3-way into a 4-way. Qual swaps are considered in **all** searches (auto).

### Q1 ✨ Qual swaps evaluated in ALL searches (auto) (P1)
- **You said:** "a. in all searches."
- **Confirmed:** Trade Search, Intents, and two-way all run qual-aware. Intents must consider quals too.
- **Status:** ✅ two-way path wired (TwoWaySheet → blast picker). ✅ **engine core (tested)**:
  `TradePackage.qualSwap` field; pure `DeskRules.isQualBlocked` (give-day where NO candidate taker is
  qualified → only a bridge unblocks); pure `QualSwap.solutions(...)` (3-party assembly: bridge C takes
  A's desk, off-taker B takes C's freed desk; bridge NOT counted in N). **Rendering decided:** inline
  card with a **"Q-in-a-box" badge** (qual swap needed).
- ✅ **DONE (UI-after):** async generator in `TradeRouter.packages` — for each qual-blocked give-day it
  derives working/off sets from the loaded `maps`, calls `QualSwap.solutions`, verifies B's willingness
  via `TradeEligibility.canCover(.full)` on the bridge's desk, and builds a qual-swap `TradePackage`
  (assignment = B takes the give-day; `qualSwap` leg candidates = the willing bridges; bridge not in N).
  `rankPackages` **exempts** qual-swap packages from the bookends-only cap (never hidden, tested).
  `PackageCard` shows a purple **Q-square badge**; `propose` in `FindCandidatesSection`/`JustTwoSection`
  routes through `QualSwapPickerSheet` (blast picker) → sends the request to taker B with the leg.
  **Q1 COMPLETE** — qual swaps now surface automatically in Trade Solutions, Just 2, and (via the same
  `packages()`) Intents. (Async/roster generation is build-verified; pure cores are harness-tested.)

### Q2 🎨 Qual-swap step UI = a name-button line, multi-select (P1)
- **You said:** "instead of making it a card, make it a line that shows buttons of all names that they
  could qual swap with for that shift, select the ones she wants to reach out to." / "At least a color
  indicator for the card indicating qual swap is being requested should be made."
- **AC:**
  - For a leg needing a qual swap, render a **line** (not a card) of **buttons — every dispatcher Q
    she could qual-swap with for that shift**. She **multi-selects** which Qs to contact.
  - The package card shows a **distinct color indicator** meaning "qual swap requested/pending."

### Q3 ✨ Qual-swap request = a blast; first acceptance fills it; all parties consent (P1)
- **You said:** "when the trade request gets sent out, it does a blast of the people she requested for
  qual swap for that step, and in the emails of the others, say that is contingent of qual swap on X
  shift. and then in the inbox, show waiting on qual swap, if it has not been accepted yet. Once it
  does, everyone will be notified and it will auto accepted (if all other parties have already
  accepted). they must also accept and decline."
- **AC:**
  - On send, the request **blasts all selected Qs** for that step. Each Q **must Accept/Decline**
    (full participant — their desk changes, so consent is required).
  - **First Q to accept fills** the qual-swap leg; the other Qs' requests for that step **close**
    ("filled").
  - Main counterparties' push + email state the trade is **"contingent on qual swap on {shift}."**
  - Inbox shows **"Waiting on qual swap"** while no Q has accepted.
  - When a Q accepts: **everyone is notified**; if all *other* parties already accepted, the whole
    trade **auto-accepts/finalizes**.
- **Files:** `TradeRouter.swift` (qual-aware routing + candidate-Q discovery), `Messaging.swift`
  (request model gains a qual-swap leg with its own candidate list + status), `MessagingViews.swift`
  (button line, "waiting on qual swap", color indicator), `CloudPush.swift` (blast notifications),
  `DeskRules`/`TradeMatcher.swift` (Q eligibility), `DispatchPalette.swift` (indicator color).
### Resolved design (answers 2026-06-16)
- **Q-a — same start hour (RESOLVED + DONE):** A qual swap is a same-**day** desk exchange and **both
  shifts must have the same start hour.** Normal shifts start **05:00, 13:00, 21:00** only; any other
  start = special assignment/project/training, which is **not tradeable** and out of scope. This is a
  **GLOBAL** rule for ALL trading, not just qual swaps. ✅ SSOT: `TradeTiming.validStartHours = {5,13,21}`
  + `TradeTiming.isTradeable(startHour:)` (TradeMatcher.swift), enforced in `QualSwap.bridges`; tested.
  ⚠️ TODO: wire `TradeTiming.isTradeable` into the main matcher's candidate-building so every search
  honors it (currently enforced in qual-swap discovery only).
- **Q-c — dedicated qual-swap search (DEFERRED):** not now; **logged as a future addition** (a simple
  "qual-swap search for a select shift + optional target person"). Auto-in-all-searches ships first.

### Q4 ✨ Settings: Qual-Swap preference VALUES (engine DONE; UI TODO) (P1)
- **You said (refined 2026-06-17):** rank quals by a **numeric value** — HIGHER = more preferred.
  **0 = blacklisted** for that qual. **1 = lowest** acceptable preference (still above the blacklisted
  0). Rank all others upward from there. **Blank = no preference = fully open = highest value.**
  Acceptance: willing to move into a desk whose qual is **equal-or-higher value** than the qual of the
  desk they're currently working that day.
- **AC:**
  - New **Qual-Swap** section in Trade Settings: per-qual **value** entry for the user's own quals,
    with **instructions** (0 = won't work it; 1 = least preferred; higher = more preferred; leave blank
    = open). Preference granularity is **per-qual only**. Qual-level blacklist is folded into value 0.
  - PLUS a **desk-number blacklist** (separate): specific desk numbers the user will never qual-swap
    into, hard-blocking regardless of qual value. ✅ `qualSwapBlacklistDesks` on Settings + profile +
    `acceptsQualSwap(... blacklistDesks:)`; tested.
  - ✅ **Engine DONE (pure + tested):** `qualValues: [String:Int]` on `SettingsManager` + published on
    `TradeProfile`; `DeskRules.qualValue` / `DeskRules.acceptsQualSwap(into:fromCurrentDesk:values:)`
    + `TradeProfile.acceptsQualSwap(into:fromCurrentDesk:)`. higher≥, 0=blacklist, unset/nil=max.
  - ✅ **UI DONE:** `qualSwapSettings` section in `TradeSettingsSheet` (HomeCalendar.swift) — per-qual
    picker (Open / Won't work / 1…N) with instructions footer + a desk-number blacklist field;
    publishes on change. (T32.)
- **Files:** `SettingsManager.swift` ✅, `TradeProfile.swift` ✅, `TradeMatcher.swift`/`DeskRules` ✅,
  `HomeCalendar.swift` ✅.

### Q5 ✨ Desk-receiver consent = NORMAL blacklist + a desk-choice stage (P1)
- **You said:** "the person who will ultimately receive that desk must be okay with working it, and
  should also be based on his blacklist (normal blacklist). Not his intents necessarily, because his
  overall availability should be filtered for intents/openness when matching in the initial search …
  the qual swap means the desk would be different … there would [be] another stage where after the
  qual swaps are broadcast and they receive acceptances, the person who will ultimately work the desk
  gets a chance at choosing which desk he wants to work, before the entire trade is accepted."
- **AC:**
  - The **desk-receiver D** (counterparty who ends up on the swapped desk) is gated by **D's NORMAL
    blacklist** against the **new** desk — **not** re-filtered by D's intents/openness (already
    satisfied for that day/shift-time in the initial availability match).
  - A distinct **desk-choice stage:** once qual-swap acceptances arrive, **D chooses which offered
    desk** (among accepted Qs whose desk passes D's blacklist) **before** the trade finalizes.
- **Files:** `TradeRouter.swift`, `Messaging.swift` (desk-choice step + pending state),
  `MessagingViews.swift` (D's desk-choice UI), `TradeProfile.swift`.

### Q6 ✨ Qual-swap blast = first 5 acceptors, live, D decides when ready (P1)
- **You said:** "like in the 1-way ecb trades, the 1st 5 people can respond before it says already
  filled … the person taking that desk [doesn't] have to wait for 5. they will automatically be
  notified (and will show in the package card) that a certain person has accepted the qual swap — with
  the desk and qual, every time someone accepts … he can choose to wait for all 5 options (it will
  state how many total qual swaps have been sent out) or just pick from the ones that have already
  accepted and accept the trade."
- **AC:**
  - Blast accepts up to the **first 5 acceptors** (ECB-style cap); 6th+ sees "already filled."
  - **Every acceptance** updates the package card live with **that person + desk + qual**, and the
    card states **how many total qual-swap requests were sent**.
  - **D is not forced to wait** — D may **wait** for more or **pick from those already accepted** and
    finalize (feeds the Q5 desk-choice stage).
- **Files:** `Messaging.swift`, `MessagingViews.swift`, `CloudPush.swift`, `TradeRouter.swift`.

---

## P. Parsing — Leave Codes (Vacation, etc.)

### P1 🐞 Vacation days mis-parsed as working (P0 correctness) — ✅ DONE (own user)
> ✅ Parser reads the `L`/`V` annotation sub-row on the day spine → vacation days are OFF with
> `leaveCode "V"` (overrides the printed shift); `DayIntentStore` auto-marks own vacation Must-Be-Off +
> "vacation" note; `HomeCalendar` shows the distinct vacation glyph. ⚠️ Confirm data: CSV shows Keriellen's
> leave on Nov 5–8, 12, **13** (not 14). ⬜ Peers: `RosterShift` has no `leaveCode`, so a peer on vacation
> reads as a normal OFF day (soft — per decision #10 "still allowed to trade into it"). Hard-block = a
> small schema add if wanted.
- **You said:** Keriellen Beck's **Nov 5–8, 12, 14** are vacation but show as **working**. The CSV shows
  a start/desk on those days, but the **ignored annotation row** beneath her shows leave codes (an "L"
  and a "V") indicating vacation. Correct the parsing; auto-mark those days **Must Be Off** + **Note:
  vacation**.
- **Interpretation:** The parser currently skips each worker's annotation row(s). It must read the
  leave-code row, align codes to the day-number **spine** (same technique as shifts), and treat
  vacation-coded days as **not working**.
- **Required behavior:**
  - Parser detects leave codes on the annotation row(s) directly beneath each worker, aligned to the
    day-number spine.
  - A vacation-coded day is parsed as **OFF/vacation (not a working shift)** for that worker — in both
    their personal schedule and the roster.
  - Vacation days are **EXCLUDED from trade-pickup eligibility** (a dispatcher on vacation is not "an
    available off day" and cannot take a shift) — **distinct** from a normal OFF day. → requires a
    `leaveCode`/`unavailable` flag on `Shift` **and** `RosterShift`, and a matcher gate.
  - For the **current user's own** schedule, a vacation day **auto-creates a DayIntent: Must Be Off +
    Note "vacation"** (`DayIntentStore`). (For other dispatchers it just means off/unavailable.)
- **Files:** `ScheduleParser.swift`, `Shift.swift`, `RosterShift.swift`, `RosterStore.swift`
  (`syncMasterIfNewer` derives the user's schedule), `DayIntentStore.swift`, `TradeMatcher.swift`
  (exclude vacation from off-eligibility), `HomeCalendar.swift` (distinct vacation display).
- **✅ P1a RESOLVED — exact CSV structure (decoded from `expanded_schedule_STD-8.csv`, Keriellen Beck
  750560, lines 11529–11531):** Beneath each worker's shift row there are **one or more annotation
  sub-rows**, each a full row aligned to the **same day-number spine** (so a day's two columns are
  `[startCol, deskCol]`, identical to the shift row). The **2nd "OFF" line** is one such sub-row; the
  **leave sub-row** is another. A **leave day** is encoded as the pair **`("L","V")`** placed at the
  day's `[startCol, deskCol]` — `L` in the start column, `V` in the desk column — while the **main
  shift row still prints a start time** (e.g., `21`) with an empty desk. That printed shift is what's
  currently (wrongly) parsed as "working."
  - **Canonical rule:** for each day, scan **all** annotation sub-rows under the worker; if any has a
    leave marker in the start column (`L`) with a leave code in the desk column, the day is **leave**
    and the leave code = the **desk-column token** (here `V` = Vacation). This **overrides** the
    printed shift.
- **✅ P1b RESOLVED:** `V` = **Vacation**. The `L` is a **leave marker in the annotation sub-row's
  start column** — NOT the Latin qual (quals live only in the name cell `… (750560) D, L`). Confirmed
  it's a leave code in this row.
- **⚠️ Data discrepancy to confirm (P1e):** You said Keriellen's vacation = **Nov 5–8, 12, 14**. The
  CSV actually shows `L|V` on **Nov 5, 6, 7, 8, 12, and 13** (Nov 14 is a normal `OFF`; Nov 13 carries
  the leave code). I'll parse **from the data** (5–8, 12, 13). Flagging in case **14** matters — but I
  believe `13` is correct and `14` was a miscount.
- **❓ Open Question P1c (still needed):** Full **leave-code vocabulary** for the desk-column token.
  Confirmed: `V` = Vacation. Also seen elsewhere in the file: **`x`** (e.g., Baker Sarah, line 11514:
  `… L,x`). What does **`x`** mean, and what are the **other codes** (Sick? Holiday? Training?) — and
  which of them should mark a day **off/unavailable** vs. still-working? I'll handle the whole set, not
  just `V`.
- **✅ P1d RESOLVED:** Vacation days render as a **distinct "Vacation" off state** (visually different
  from a plain day off) and are **excluded** from being offered for pickup.

---

## R. Final Answers — Round 2 (2026-06-16)

- **R1 (B2 card cleanup) — RESOLVED:** The package card currently shows **TWO** participant-count
  labels ("3-way trade" headline **and** "2-way trade — your part is highlighted" subtitle). **Remove
  the duplicate** — show exactly **one** label, computed from **distinct participant count**
  (reciprocal 1:1 ⇒ "Direct swap"). Clean up the whole package card so there's a single, correct
  people-count badge. → `MessagingViews.swift`, `TradeIntentsFeed.swift`.
- **R2 (parsing fix) — RESOLVED:** Parse leave per §P1. **Nov 14 = normal day off** (parse exactly as
  the data shows). The fix must be correct on **master re-upload**, and **must NOT reset individual
  intents** (the prior bug — `reconcile(withShifts:)` wiped marked intents). On re-import, **preserve
  user intents/notes**; only update schedule facts. Leave-code vocabulary: **handle `V` (Vacation)
  only** for now; record `x`/`S`/`R` but don't change availability. (Baker `L|x` sample dates given to
  user to verify in ARIS.)
- **R3 (ECB currency) — RESOLVED:** ECB = the dispatch trading currency. **1 ECB = 1 hour of pay**; a
  normal 9-hour shift = **9 ECB**. The company grants ECB for holiday/overtime (cap 144) for
  dispatchers to spend on trades/time off. Asking price rises with demand/scarcity/holidays (up to
  ~18), and **1.5× overtime = 13.5 ECB** — hence **0.5 increments**. **Stepper: min 5, max 25, step
  0.5.** → `Messaging.swift` (ECB value), `MessagingViews.swift`/`AvailabilityView.swift` (stepper).
- **R4 (metrics placement) — RESOLVED:** Pin the metrics to the **very top of the Home page** as the
  first thing users see (also serves as the page heading region). **UI/UX mandate:** redesign the
  Home top/header so the metrics, title, and existing controls (Mark Intents, visibility toggles) are
  **legible, well-spaced, and never collide**. Metrics = global **% successful** (accepted-in-app ÷
  proposed) + **trade-search counts** tabbable **month / year / all-time**, admin-resettable. →
  `HomeView.swift`, `TradeHistoryStore.swift`, `TradesView`/global counters.
- **R5 (bookend rule + multi-step) — RESOLVED:** Confirmed the immediate-adjacency rule (D8), **both
  directions**. **PLUS:** the algorithm must allow multi-step solutions where a day **becomes** a
  bookend **after all steps complete** — e.g., trading away **D−3** is acceptable if **D−2** and
  **D−1** get filled later in the same multi-step trade (so the time off ends up contiguous);
  symmetrically for D+1, D+2…. **Bookend status is evaluated against each participant's FINAL
  post-trade schedule across all legs, not per-leg intermediate state.** → `TradeMatcher.swift`,
  `TradeRouter.swift`, `OptimalMatcher.swift`.
- **R6 (channels + moderation) — RESOLVED:**
  - Channel order: **General, Trades, Feedback.**
  - **Per-channel unread-count circle**; the **General button** also shows the **total** new-message
    count. Counts **reset when the user opens the channel/message** — **not** while minimized or when
    the message is within an already-open thread.
  - **Everyone** can **edit + delete their own** messages/replies, with an **edited timestamp**;
    delete leaves a **`[Deleted]`** tombstone.
  - **Admin** can **pin to top** of each channel and **edit/delete (moderate)** anyone's, with
    timestamp. When an admin moderates, they're **prompted for a reason**; that **reason + timestamp**
    render in **small, light, italic** font at the bottom of the affected item.
  - → `Messaging.swift`, `MessagingViews.swift`, `SlackKit.swift`, `CloudKitMessagingService.swift`,
    `CloudPush.swift`.

---

## K. Proposed Build Order (after questions are answered)

1. **Decisions first (no code):** C6 tiers/keys, A7-vs-B8, delete/archive semantics (B3), Outlook
   approach (G1/G2). These shape everything else.
2. **P0 correctness:** A6 intent matches, A5 one-way-as-package.
3. **P1 bugs:** A1, A2, A3, A4.
4. **P1 UX core:** C1/C2 Individual Swaps redesign, C3 intent bar, C5 stale copy, D1/D2 defaults,
   B1/B2 unified clickable cards, B3 archive/invalidate.
5. **P2 features:** F1/F2 bulk intents, F3 counters, B4 reply edit, E1 channels, C4 pinning,
   B5/B6/B7 media/react/pin, G1–G3 integrations, H1 metrics, I1 guides.

> Each item ships only when it meets the Definition of Done at the top. No item is marked complete
> with a stubbed branch, an unresolved symbol, or a non-building target.

---

## U. Unified Trade Engine + Trade-Solutions UI redesign (decided 2026-06-17)

**Goal:** one matching algorithm for Search, Intents, and ECB — differing only in execution/format/outer
rules. Every proposal renders as a `TradePackage` card. Plus a qual-swap-aware, N-iterating optimizer.

### U1 — Three-layer architecture (the merge)
- **Layer 1 (Eligibility, the unify target):** one pure predicate `TradeEligibility.canCover(cover, giveDesk,
  day, map, plan, profile, options)`. Always: off · `DeskRules.qualified` · 8h rest (`isRested`) ·
  anchored/bookend (`isAnchored`). Toggleable hard opts: weeklyCap · keepDays · mustBeOff. Toggleable
  Layer-B: `wouldPickUp` (openness/blacklist/pills/want-to-work). MUST stay pure + synchronous (data loaded
  once per search; never fetch in-loop) — this is the 550-user performance rule.
- **Layer 2 (Capacity):** `TradeMatcher.twoWayExplore` runs Layer 1 over the window → per-peer
  `canTake`/`givesBack`. Already shared by Search + Intents + Individual Swaps. Unchanged by merge.
- **Layer 3 (Optimization):** `OptimalMatcher.minPeopleReciprocal` (min-cost flow + branch&bound) and
  `nWayRoutes` (circular DFS) consume Layer-2 day-lists. Merge does NOT touch this — same inputs ⇒
  identical min-cost/n-way output (guarded by harness).
- **Performance:** matching is on-device against the local roster + cached profiles; concurrency across 550
  users doesn't compound CPU. Merge is same-complexity (often fewer allocations). No CloudKit change.

### U2 — Per-path calls into the one predicate
- **Trade Solutions – package build:** Layer 1 + B + cap + keep + mustBeOff → `TradePackage[]`.
- **Intents:** same as above + outer tiers/topology/intent-chaining.
- **ECB broadcast filter:** Layer 1 + B + cap + mustBeOff (keep N/A — recipient isn't giving). The
  *initiating searcher* is ungated (actively seeking). Want-to-work is NOT a filter — broadcast equally,
  flag 🔥 (see U6).

### U3 — Optimizer: N-iteration with greedy ∪ circular, qual-swap aware
- Iterate **N = 2,3,4… (N = total people INCLUDING the requester)**. At each N: greedy reciprocal **and**
  circular routes, combined. Keep only VALID packages (balanced + Layer-1 pass; if a leg needs a qual swap,
  at least one bridge must exist or the package is dropped — "not a match if none").
- **Qual-swap bridges are NOT counted in N** (a 3-person trade needing a bridge is still N=3).
- Surface **every N group** (N=2 first, then N+1, …), each internally priority-sorted (U4). Fewest-N tops.

### U4 — Bookends + priority sort
- **Bookend = sum across BOTH/all sides** (total bookends in the trade). It's a sort key: more total
  bookends ranks higher **even when all parties are open-to-all** (bookends still more optimal).
- Within an N group, sort priority: (1) **🔥 + bookends** (mutual intent AND most total bookends) →
  (2) **🔥 only** → (3) **bookends-only** (no 🔥).
- **Bookends-only cap:** show only the **top two bands** — counts `max` and `max−1`; hide `≤ max−2` as
  clutter. (e.g. if best bookends-only = 3, show 3 and 2; hide 1-and-below.)

### U5 — UI: everything is package cards
- Both **Intents** and **Trade Solutions** render only `TradePackage` cards, sorted by U3/U4.
- **Rename "Search" header → "Trade Solutions".** Remove the individual-takers section entirely; instead
  include 2-person packages (prioritized per U4) alongside multi-person + circular.
- **📖 badge = total bookends the trade delivers** (both sides); per-day legcards show 📖 for whoever
  RECEIVES that day; drop the literal "bookend" text. Applied to ALL trade cards (two-way, packages,
  individual swaps, circular — thread per-leg bookend flag through `NWayRoute`).
- **New 3rd segment "Just 2"** (beside Trade Solutions / Intents): requester picks a date → only 2-person
  swaps (incl. you), all options, same U4 priority sort; PLUS a dropdown of all dispatcher names → choosing
  one filters to swaps available with that specific dispatcher only.

### U6 — Inbox 🔥 intent-match badge + notification (all shifts)
- When an incoming request lands, flag 🔥 + notify if it hits the recipient's own intents:
  a day they'd **pick up** matches their **Want-to-Work** (off-day; ECB-relevant) OR a day **taken from
  them** matches their **Trade-Away** (working day). Pure `matchesMyIntents(request)` + InboxView badge +
  push. Applies to 2-way, ECB, and circular.

### Build order (test-first, harness + build green each step)
1. `TradeEligibility.canCover` SSOT + gate tests
2–4. migrate `candidatesForTrades` / `twoWayExplore` / router `canCover` to delegate
5. ECB → full gates + want-to-work 🔥 eligibility
6. optimizer N-iteration (greedy∪circular per N; qual-swap not-counted-but-required)
7. bookend = both-sides total + priority sort + bookends-only top-two-bands cap (pure `rankPackages` v2)
8. UI: packages-everywhere, rename Trade Solutions, drop individual-takers, 📖 receiver-count display
9. "Just 2" segment (date → 2-person packages + per-dispatcher filter dropdown)
10. inbox 🔥 intent-match badge + notification (U6)

### Z1 — Cleanup + strip tests from the shipped build — ✅ DONE (2026-06-17)
> ✅ `EngineTests.swift` wrapped in `#if DEBUG` (+ the "Run engine tests" button in SettingsView) → the
> 208-assertion harness is **excluded from Release/TestFlight** builds (smaller binary, faster launch);
> the dev harness still runs in DEBUG (RunCodeSnippet/verified green). ✅ Dead code removed:
> `TradeRouter.tieredSolutions` + `route(from:)`, and `RouteCard` + `TierLegendSheet` (orphaned by the C6
> flatten). Build green, guard green, runtime safeguards (CaseIterable guards, single-source predicates)
> retained. (Original spec below.)

### Z1 (original spec) — Cleanup + strip tests/safeguards from the shipped build
- **You said:** the app is starting to slow; reduce code / remove garbage, and **consolidate all tests +
  safeguards into something NOT sent to build** for efficiency.
- **AC:**
  - Wrap `EngineTests.swift` (the 200+ assertion harness) + any test-only scaffolding in `#if DEBUG`
    (or move to a dev-only target/package) so RELEASE/TestFlight builds **exclude** it → smaller binary.
  - Remove now-dead code surfaced by the redesigns: `tieredSolutions`, `RouteCard`, `TierLegendSheet`
    (C6 flatten), `SolutionTier` machinery if fully unused, and any other unreferenced helpers.
  - Keep the **runtime** safeguards (CaseIterable universe checks, single-source predicates) — those are
    engine, not tests. Only the *test harness* leaves the release build.
  - Verify: release build compiles + app launch/match perf improves; the dev "Run engine tests" path still
    works in DEBUG; `scripts/check_arch_map.sh` still passes.
- **Files:** `EngineTests.swift` (DEBUG-gate), `TradeIntentsFeed.swift`/`TradeRouter.swift` (dead code),
  build settings.

### Z2 — Startup "What's New" / changelog screen — ✅ DONE (2026-06-17)
> ✅ `ChangeLogEntry` + `ChangeLog.current` (Added/Fixed/Changed/Improved + a short "Please test" list) +
> pure `ChangeLog.shouldShow(currentBuild:lastSeen:)` (tested) + `AppInfo.build`. `ChangeLogView` (one-page
> sheet) presented on launch from `ContentView` when the build is newer than `SettingsManager.
> lastSeenChangelogBuild` (guarded so it never stacks over onboarding); dismiss records the build. (T45.)
> To update for a release: edit `ChangeLog.current`.

### Z2 (original spec) — Startup "What's New" / changelog screen
- **You said:** a startup updates screen — a 1-page list of everything Added / Fixed / Changed / Improved
  (a changelog), plus a short "to-test" for testers.
- **AC:**
  - On launch, if the app version/build is newer than the last one the user saw, show a **one-page sheet**:
    sections **Added · Fixed · Changed · Improved**, then a short **"Please test"** list (curated from
    `USER_TEST_LIST.md` highlights). Dismiss → remembers the version so it shows once per update.
  - Content is a static, versioned `ChangeLog` model (per-release entries) — not auto-generated.
- **Files:** new `ChangeLogView` (in an existing compiled file), `SettingsManager` (lastSeenChangelogBuild),
  `ContentView` (present on launch).
- **You said:** when adding shifts to the user's Apple Calendar, the event shows extra info (e.g.
  "available"). The **title** should be just the **shift (AM/PM/MID) + the desk** they're working.
- **AC:** EventKit event `title` = e.g. `"AM 82"` (shift type + desk); drop availability/status
  text from the title. Any extra detail goes in `notes`, not the title.
- ✅ **DONE:** personal-shift event `title` now `shift.shiftShortLabel` ("AM 82" — type + desk),
  not the raw start-time form. NOTE: the literal "— Available" text is only on the **shared**
  off-day availability calendar (by design; not a shift event). If you want that relabeled too, say so.
- **Files:** `EventKitManager.swift`.

### REL1 — Relief Dispatcher mode (added 2026-06-17) ✅ engine+UI; ⬜ own-display
- **You said:** relief dispatchers only get their schedule ~45 days out; the master CSV pads the rest
  of the year with bogus 0500 AMs (e.g. Ivet Valdivieso's real schedule ends Aug 7). Add a Trade
  Settings **toggle "Relief Dispatcher" + a "schedule known through" date**. After setting, hide all
  their shifts after that date (off the Apple Calendar + not available for trading), surviving CSV
  re-uploads.
- **Decided:** PUBLISH the relief date to peers (everyone's matcher excludes those days); **filter at
  read-time** (never delete rows); only active when toggled ON **and** a date is set (date forced on).
- ✅ **DONE (engine+calendar+settings, tested):** `SettingsManager.isReliefDispatcher` +
  `reliefScheduleThrough` + `effectiveReliefThrough`; `TradeProfile.reliefThrough` (published, JSON
  payload — no schema deploy) + pure `isPastRelief`/`scheduleUnknown`; gated in `TradeEligibility.canCover`
  (cover-side), `twoWayExplore` (give + take), `nWayRoutes` (give-side); `EventKitManager` skips/removes
  post-relief events; Trade Settings toggle + DatePicker (forces a date).
- ✅ **own-display DONE:** `ShiftStore.shifts` is now a **relief-filtered computed view** over private
  `rawShifts` — every consumer (Home calendar, day pickers, next-shift, widget, Shortcuts) sees post-relief
  days as BLANK. EventKit diff stays on `rawShifts` (calendar-add relief-filters itself). The shared
  availability calendar also skips post-relief off-days (others can't see "available" past the horizon).
- **Files:** `SettingsManager.swift` ✅ · `TradeProfile.swift` ✅ · `TradeMatcher.swift`/`TradeRouter.swift` ✅ ·
  `EventKitManager.swift` ✅ · `HomeCalendar.swift` ✅ · `ShiftStore.swift` ✅.
</content>

