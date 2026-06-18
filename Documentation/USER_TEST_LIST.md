# BATMAN Watcher — User Test List

> What **you** test on-device to confirm each shipped change. I append to this every session.
> Each item: **what to do** → **what you should see** (and **try to break it**). Spec ID + the
> automated test that already guards it are noted so you know what's covered vs. what needs your eyes.
>
> Legend: ☐ untested by you · ✅ you confirmed · ⚠️ you found an issue (tell me).
> "Auto" = covered by `TradeEngineTests` (Settings → Developer → run engine tests) and/or
> `scripts/check_arch_map.sh`. Your job is the on-device behavior the harness can't see.

---

## Session 1 (2026-06-16)

### T1 — Re-import never wipes your intents  [S-PARSE-2 · Auto ✅]
1. Mark several days: a few **Trade-away**, a **Keep**, a **Must-Be-Off**, add a **note** to one.
2. Have the admin post a **new master** (or re-import the master CSV) where **those days are unchanged**.
3. Reopen Home.
- **Expect:** every mark and note is **exactly as you left it**. Only days whose working/off status
  *actually changed* in the new master get cleared, and a banner names how many changed.
- **Break it:** re-import the *same* file twice; mark a day, re-import, then re-mark it and reopen —
  your re-mark must survive.

### T2 — Vacation days read as days off  [S-PARSE-1 · Auto ✅]
1. Use a master where you have **vacation** (the `L|V` rows, e.g. Keriellen's Nov 5–8, 12, 13).
2. Open your schedule/calendar.
- **Expect:** those days show as **OFF (not working)** — the printed shift is gone.
- **Break it:** confirm a normal day off next to a vacation day still looks like a normal day off.

### T3 — Vacation auto-marks Must-Be-Off + "vacation" note (changeable)  [S-PARSE-2 · Auto ✅]
1. After a master with your vacation imports, open one of those days.
- **Expect:** it's auto-set to **Must-Be-Off** with a **"vacation"** note.
2. Change that day's intent (clear Must-Be-Off / mark want-to-work).
- **Expect:** your change **sticks** and is **not** re-applied on the next sync. You **can** trade into
  your vacation day if you choose (it's not locked).

### T4 — One clean people-count label on every trade card  [B2/S-ENG-5 · Auto ✅]
1. Open the inbox / a trade card for a **1:1 swap** (you + one person).
- **Expect:** it reads **"2-Person Swap"** — and **only that** (no second "3-way/2-way" line).
2. Open a **circular** 3-person trade.
- **Expect:** **"3-Person Swap"**. An **ECB one-way** reads **"1-Way Swap"**.
- **Break it:** the "Countryman, Cary" swap that used to say "3-way trade · 2-way trade" should now
  say a single **"2-Person Swap"**.

### T5 — A Must-Be-Off day is never offered to you  [S-ENG-9 · Auto ✅]
1. Mark a day **Must-Be-Off**.
2. Run **Trade Search** / open the **Intents** feed / a two-way swap that involves that day.
- **Expect:** that day is **never** offered as a day **you take** ("You Take"). (This was the June-23 bug.)
- **Break it:** turn on **Mercenary** — the Must-Be-Off day must **still** never be offered.

### T6 — A Keep day is never given away  [S-ENG-9 · Auto ✅]
1. Mark a working day **Keep**.
2. Run Trade Search / Intents / two-way.
- **Expect:** that day never appears in **"You Give"** and is never used as a leg you give in a
  multi-person/circular trade.

### T7 — Results refresh when you change settings  [S-ENG-9 · Auto (trigger) ✅]
1. Run a Trade Search (or open the Intents feed) so results show.
2. **Without leaving**, change your **Openness** (e.g. All → Bookends), toggle **Mercenary**, or change a
   day's **intent**.
- **Expect:** the results **recompute immediately** to reflect the change — no need to leave and come
  back. (This was the "changed openness, nothing refreshed" bug.)
- **Break it:** flip openness back and forth quickly; results should track each change.

### T8 — Mercenary forces "Open to all"  [S-ENG-6 · Auto ✅]
1. Set Openness to **Not accepting** (or Bookends). Then turn **Mercenary ON**.
- **Expect:** Openness immediately flips to **Open to all** — the contradictory "Not accepting +
  Mercenary" state is impossible.
- **Break it:** toggle Mercenary on/off a few times; openness should read "Open to all" while on.

### T9 — Trades opens on Trade Search  [D2/U-TRADES-1 · your eyes]
1. Open the **Trades** tab fresh.
- **Expect:** the **Search** (middle) segment is selected by default — not Intents.
- *(Pending: the Intents tab count bubble, coming later.)*

### T10 — No stale "import the roster" copy  [C5 · your eyes]
1. Open **Trades → Search** before picking days; open **ECB** with no schedule.
- **Expect:** prompts read "Tap the days you want to give away, then Find." and, when nothing's synced,
  **"Waiting for your schedule to sync — pull to refresh…"**. **No** "Import the roster file first."

### T11 — ECB offered in 0.5 steps, 5–25  [A4/S-ENG-8 · Auto ✅]
1. Trades → **ECB** → use the **ECB offered** stepper.
- **Expect:** it steps by **0.5** (e.g. 9 → 9.5 → 10), **min 5, max 25**. A 1.5× OT shift = **13.5**.
2. Send an ECB request, open it in the **inbox/thread**.
- **Expect:** the same value (e.g. **"13.5 ECB"**) shows everywhere — request row, offer view, accept
  section, receipt, history summary. No "13.5" rounding to 14 in the offer.
- **Break it:** set 13.5, send, confirm the recipient sees 13.5.

### T12 — Intents tab shows a count badge  [D2a · Auto ✅]
1. Mark a few days with intents (trade-away / keep / must-be-off / want-to-work).
2. Look at the **Trades → Intents** segment label.
- **Expect:** it reads **"Intents N"** where N = how many days you've marked (non-neutral). Clear a
  mark → N drops live. (Color-coded multi-bubbles are a later visual upgrade.)

### T13 — Channel unread badge clears after reading  [A2/S-SYNC-1 · Auto ✅]
1. Have someone post in the **Channel** (📣). Note the **blue number** on the Channel dock button.
2. **Open** the Channel and read.
- **Expect:** the blue badge **drops to 0** after you open it (it used to show the total post count and
  never clear). New posts after that re-raise it; **your own** posts don't count.
- **Break it:** post yourself (shouldn't bump the badge); open then close then have someone post (badge
  should reappear).

### T14 — Character counters on limited fields  [F3 · Auto ✅]
1. Open the **day note** editor (≤50), **Status** (≤140), and **Private notes** (≤2000).
- **Expect:** each shows a live **"used/limit"** counter that turns **amber** near the limit (≥90%) and
  the field stops accepting more at the cap.
- **Break it:** paste a long string — it clamps and the counter shows the cap.

### T15 — Status shows under a person's name  [A7/B8 · Auto ✅]
1. Have a peer set a **Status** (e.g. "Taking weekend PMs"). Open a trade with them: the **inbox row**,
   the **package-card chips**, the **thread card**.
- **Expect:** their status shows in **italics** under their name. **Your own** name doesn't show your
  status (no self-clutter). People with no status just show their name.

### T16 — Vacation days look distinct  [U-VAC · Auto (parse) ✅]
1. With a master that has your vacation (`L|V`), view the Home calendar.
- **Expect:** vacation days show a **teal beach-umbrella** glyph — clearly different from a plain day
  off — in both normal and Mark-Intents modes.

### T17 — Trade Search calendar shows your intents  [C3 · your eyes]
1. Trades → **Search** → look at the day-picker calendar before picking.
- **Expect:** working days you've marked show a thin **intent-color bar** (e.g. trade-away vs keep) and
  days with a **note** show a small blue dot — it's no longer blank, so you can see what you're trading.

### T18 — Inbox archive & delete  [B3 (archive/delete) · Auto ✅]
1. In the **Trade Inbox**, swipe a request left.
- **Expect:** **Archive** (gray) moves it to an **Archived** section (kept, hidden from active lists);
  **Delete** (red) removes it **forever**. Swiping an archived item offers **Unarchive**.
- **Break it:** archive several, reopen the inbox — they stay in Archived; delete one — it's gone for good.
- *(Pending: auto "invalid trade" detection + urgent alerts — that's the S-VALID slice, separate.)*

### T19 — Edit & delete your channel replies  [B4 · Auto (model) ✅]
1. In a **Channel** post, expand replies and reply yourself.
2. Tap the **pencil** to edit; tap the **trash** to delete your reply.
- **Expect:** edited replies show **"· edited"** next to public/private; deleted replies show **"[Deleted]"**
  (the row stays as a tombstone). Edit/delete only appear on **your own** replies.

### T20 — Channels: General · Trades · Feedback  [E1 (General) · your eyes]
1. Open the **Channel** (📣) and use the segment picker.
- **Expect:** three channels in order **# general · # trades · # feedback**, each with its own
  title/subtitle/empty-state. Posting goes to the selected channel.
- *(Pending: per-channel unread circles — global unread badge already clears on open, T13.)*

### T21 — Admin can pin posts  [B7 · Auto (sort) ✅]
1. Unlock **Developer** access. In a Channel, open a post's **⋯ menu → Pin to top**.
- **Expect:** the post jumps to the **top** of the channel with a **"Pinned"** badge; **Unpin** restores
  normal order. Non-admins don't see Pin. (Pinned-first, then newest.)
- **Bonus fix:** editing a post no longer moves it to the wrong channel.

### T22 — Bulk intents: every intent is a brush + note stamp  [F1/F2 · Auto (completeness) ✅]
1. **F1 — Working Shifts:** brushes for **Trade away · Keep · Open** — pick one, tap multiple working
   days, each becomes that intent.
2. **F1 — Days Off:** direct brushes for **Must Be Off · Want to Work · Open** (NEW — Must Be Off used to
   require deselecting all pills), plus **AM/PM/MID** granular pickup. Pick one, tap multiple off days.
3. **F2 — note stamp:** type a note in "Stamp a note on tapped days" — every tapped day also gets it
   (≤50, counter, ✕ to clear).
- **Break it:** confirm **all** of Trade away/Keep/Open and Must-Be-Off/Want-to-Work/Open actually paint.
  (A completeness test guards that every intent has a brush.)

### T23 — Audit discharge round (A5 · A6 · D1 · A7/B8 · C3 · B4-chat)  [Auto ✅ where noted]
- **A5:** in Trade Search, a single person who can cover all your days shows as a **2-Person Swap at the
  top** (above multi-person/circular). *(ranking test)*
- **A6:** mark a day to trade away that a peer would take, and a peer's marked day you'd take → the
  **🔥 match count** reflects it; marking that day **Must-Be-Off** removes it. *(engine test)*
- **A7/B8:** open the **Inbox** fresh — peers' status now loads (it didn't refresh profiles before).
- **C3:** the **ECB** picker calendar also shows your intent bars (same fix as Trade Search).
- **B4 chat:** in a trade **thread**, edit/delete your own **chat messages** (pencil/trash) → "edited" /
  "[Deleted]". (Was only channel replies before.)

### T24 — Intents tally bar (color-coded tiers)  [D2a/#11 · Auto (counts) ✅]
1. Mark a mix of intents (some Trade away, Keep, Want to work, Must be off).
2. Open **Trades**.
- **Expect:** a thin row under the segment picker with a **colored chip per intent type** showing its
  count (e.g. 🟣 3 Trade away · 🟢 2 Keep · 🟠 1 Want to work · 🔴 1 Must be off). Clear a mark → it
  updates live. Categories with 0 don't show.

### T25 — Private notes sync across your devices  [A3/#6 · 2-DEVICE check]
1. With **iCloud Trade Sync ON** and signed into iCloud, type **Private notes** on Device A.
2. Open the app on Device B (same Apple ID).
- **Expect:** Device B shows the same private notes (last edit wins). They are **never** visible to
  anyone else. *(Requires the `PrivateState` schema deployed to Production — see the rollout checklist.)*
- *(Status-line cross-device sync is a later chunk; the merge logic is unit-tested.)*

### T26 — Want-to-Work overrides bookends  [S-ENG-10 · Auto ✅]
1. Set Openness to **Bookends**. Mark an off day **Want to Work** that is NOT next to your work.
- **Expect:** you're still offered for that day (Want-to-Work overrides the bookend-only rule). A
  non-bookend day you did **not** mark stays hidden. Blacklist / Must-Be-Off still block it.

### T27 — Invalid trade alert  [S-VALID · Auto (core) ✅]
1. Open a pending trade, then have the master change so one of its days is **no longer worked**.
2. Reopen the trade **thread**.
- **Expect:** a **red, bold "Action needed — … INVALID — delete/archive"** banner at top, and Accept is
  blocked.
3. Back in the **inbox list**, that request row shows a red **"Invalid"** badge. If the master reverses
   (the day is worked again), the badge **clears on the next refresh** (pull-to-refresh).

### T28 — Home metrics header  [H1 · Auto (math) ✅]
1. Open **Home** — a metrics band sits at the very top.
- **Expect:** a **% cleared** figure (your completed ÷ proposed) and a **search count** with a
  **Month / Year / All** segmented toggle. Run a Trade Search (Find) → the count goes up. Admin: long-press
  the band to reset. *(Counts are this-device for now; team-wide totals are a later chunk.)*

### T29 — Others' intents on the calendar  [A1 · Auto (count) ✅]
1. On Home, toggle the **person.2** visibility icon ON.
- **Expect:** days where **other** dispatchers want to trade/work show a small **👥 N** badge (count of
  peers seeking or want-to-work that day). Toggle off to hide.

### T30 — Trade Search: search + pin people  [C4 · Auto (filter) ✅]
1. Run a Trade Search with several candidates.
- **Expect:** a **"Search people by name…"** field filters the list; **long-press a candidate → Pin to
  top** moves them to the front (pin icon shown). Pins last for the session.

### T31 — Emoji reactions on channel posts  [B6 · Auto (toggle) ✅]
1. In a Channel post, tap the **smiley** → pick an emoji.
- **Expect:** a **emoji + count** chip appears; tapping the chip toggles **your** reaction off; others'
  reactions stay. Counts group by emoji.
3. Open a post's **replies** and a **1:1 trade chat** message; tap the smiley on each.
- **Expect:** the same reaction chips + quick-react menu work on **replies and chat messages** too (B6).

### T32 — Qual-swap preferences  [Q4 · Auto (rule) ✅; UI device-check]
1. Open **Trade Settings → Trade Settings tab** → scroll to **Qual-swap preferences**.
- **Expect:** one row per qual you hold (D plus any of E/L/P/…). Each is a picker:
  **Open / Won't work / 1 (least) … N (most)**. Footer explains the equal-or-higher rule.
2. Set, e.g., Pacific = "Won't work", Euro = highest. Close + reopen Settings.
- **Expect:** selections persist (saved to your profile + published).
3. In **Qual-swap desk blacklist**, type `64, 65`.
- **Expect:** those desk numbers are stored; you'll never be offered a qual swap onto them.

### T33 — Qual-swap inbox flow  [Q3/Q5/Q6 · device-check; logic Auto ✅]
*(Requires a request carrying a qual-swap leg — wired once Q1 surfaces blasts in search.)*
1. As a **bridge** (you're in the blast), open the request.
- **Expect:** a **Qual swap** section: "Waiting on qual swap", a line saying which desk you'd move onto
  and which of your desks frees up, and an **Accept qual swap** button. After tapping: "You accepted."
  Once 5 have accepted, others see **"already filled."**
2. As the **taker (B)**, open the request.
- **Expect:** "X of N asked have accepted", a row per acceptance (**name · frees desk D (qual)**) each with
  **Choose**, plus **Decline — cancels the trade**. Tapping Choose marks it **Chosen** and finalizes.
3. As the **giver/other party**.
- **Expect:** "This trade is contingent on the qual swap" until it finalizes or goes invalid.

### T34 — Trade Solutions (packages-only) + 📖🔥 badges  [§U 8 · device-check]
1. Trades tab → **Trade Solutions** segment → pick days → Find.
- **Expect:** only **package cards** (no individual-takers grid). Cards sorted fewest-people first,
  then 🔥/bookends. Each card header shows **🔥 N** (mutual intent) and **📖 N** (total bookends).

### T35 — "Just 2" segment  [§U 9 · device-check]
1. Trades tab → **Just 2** → pick a day → Find.
- **Expect:** only **two-person** swaps (you + one). A **dropdown** lists the available dispatchers;
  choosing one filters to swaps with that person. Same priority sort.

### T36 — Inbox 🔥 intent match  [§U 10 · Auto ✅; device-check]
1. Have someone send you a request for a day you marked **Trade-Away** (or an **ECB** offer on a
   **Want-to-Work** off day).
- **Expect:** that inbox row shows a **🔥 "Matches your intent"** badge.

### T37 — Relief Dispatcher  [REL1 · Auto (gate) ✅; device-check]
1. Trade Settings → **Relief schedule** → toggle **Relief Dispatcher** on.
- **Expect:** a date picker appears, defaulted ~45 days out (you can't be "on" without a date).
2. Set the date to your real last-scheduled day; reopen Settings.
- **Expect:** it persists + publishes.
3. Check Apple Calendar + Trade Solutions / Just 2.
- **Expect:** your shifts AFTER that date are **blank everywhere** — Home calendar, the trade day
  pickers, Apple Calendar, widget — and are **never offered for trading** (yours or to peers).
  Re-importing the master CSV does **not** bring them back. The shared availability calendar also
  stops showing you "available" past that date.

### T38 — Qual swaps surface automatically (Q1)  [device-check]
1. Pick a give-day whose desk needs a qual most off dispatchers don't hold (e.g. a Euro/Latin/Pacific
   desk), then Find in **Trade Solutions** (and **Just 2**).
- **Expect:** if no one off is qualified but a working dispatcher could **bridge**, a package card appears
  with a purple **Q-square "Qual swap"** badge.
2. Tap **Propose** on that card.
- **Expect:** the **blast picker** opens (pick which bridges to ask) → sends; the bridges get a qual-swap
  request, the taker gets it as contingent (T33 flow). No qualified taker + no bridge → no card.

### T39 — Status syncs across your devices  [A3 #12 · Auto (LWW) ✅; 2-device check]
1. Set your public **Status** on device A. On device B (same iCloud), relaunch.
- **Expect:** device B shows the status you set on A. The most recently edited side wins (LWW).

### T40 — Global (team-wide) metrics  [H1 #18 · Auto (math) ✅; device-check]
1. With CloudKit on, open Home after a few people have searched/proposed/cleared trades.
- **Expect:** the header reads **"trades cleared (team)"** and the numbers reflect **everyone's** activity
  for the chosen period — not just your device. Offline/empty → falls back to your local numbers.
  *(Requires the `MetricEvent` schema deployed in CloudKit.)*

### T41 — Qual-swap response push  [Q3/Q6 · device-check]
1. As the taker on a qual-swap request, have a bridge accept.
- **Expect:** you get a **"qual-swap response came in"** push. *(Requires `hasQualSwap` deployed + queryable.)*

### T42 — Email a trade to the dispatch DL  [G1 · Auto (builder) ✅; device-check]
1. Open a trade thread → **Email trade to dispatch DL**.
- **Expect:** a prefilled Outlook/Mail draft to **DL_dispatch_trades@aa.com**, subject + body summarizing
  the trade, with a **"Blackout days (unavailable)"** line listing your Must-Be-Off days.

### T43 — Attach a photo to a channel post  [B5 · device-check]
1. In a Channel, tap **Photo**, pick an image → it previews → type a caption → send.
- **Expect:** the post shows your **image inline**, and other dispatchers see it too. Very large photos may
  post text-only (image dropped to stay under the sync size limit).

### T44 — Intents is one flat sorted list  [C6 · device-check]
1. Open **Trades → Intents**.
- **Expect:** one list of package cards (no tier accordions), sorted **fewest-people → 🔥 → bookends** —
  same as Trade Solutions. Qual-swap cards show the Q-badge and Propose opens the blast picker.

### T45 — "What's New" on launch  [Z2 · Auto (show-once) ✅; device-check]
1. Install a new build and launch (with your ID already set up).
- **Expect:** a one-page **What's New** sheet — Added / Fixed / Changed / Improved + a short **Please test**
  list. Tap **Got it**. Relaunch → it does **not** show again (until the next build). Never appears over
  onboarding.

---

### Notes for the tester
- If something here fails, tell me the item number (e.g. "T5 ⚠️") and what you saw.
- "Auto ✅" means the logic is unit-guarded, but **your device check is still the real proof** — the
  harness can't see the actual UI.
- Run the engine self-checks anytime: **Settings → Developer → run engine tests** (should report all pass).
</content>
