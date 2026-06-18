# BATMAN Watcher — Tester Guide

Thanks for testing! You're a dispatcher, so test it like one: do the normal stuff,
then **try to break it**. Below is every area to exercise, what *should* happen, and
nasty edge cases to throw at it.

**How to report:** open the **Trade Channel** (📣 top-right) and post a message that
starts with **`FEEDBACK:`** — what you did, what you expected, what happened, and the
date/time. Screenshots help. (One thread keeps it all in one place for everyone.)

---

## 1. First run & sign-in
- Sign in with Apple, enter your **real Employee ID** + name.
- ✅ You should land on the Home calendar with your schedule loaded.
- **Try to break:** wrong employee ID; an ID already used by someone else; kill the
  app mid-setup and reopen; airplane mode during sign-in.

## 2. Schedule (Home calendar)
- Scroll months; confirm your shifts, days off, and **today** (blue) look right.
- Tap the ⓘ color key; confirm the legend matches what you see.
- **Gold** = high-impact day, **pink** = personal day — tap one to read it.
- **Try to break:** very long shift labels; a month with lots of trades/holidays;
  pull to refresh repeatedly; check the day after the schedule master updates.

## 3. Marking intents
- Tap **Mark Intents** → **Working Shifts**: mark shifts "Trade away" / "Keep".
- → **Days Off**: tap days and set **AM/PM/MID** availability (pills only show here).
- Long-press any day to open the editor: set a reason, "Significant day", a note
  (public/private).
- ✅ Colors update; private notes show read-only on Home (swipe to read).
- **Try to break:** mark, undo, re-mark fast; mark a day already marked differently
  (should ask to overwrite); set a 50-char note; set notes >1 line.

## 4. Openness & availability (Trade Settings → gear)
- Set **Accepting**: All / Bookends / Not accepting. Confirm the calendar stays
  neutral (no "want to work" paint) for All & Bookends.
- Add a **date-range override** (＋) — e.g. "Open to all" for one week. Delete it.
- Toggle **Mercenary mode** — confirm all off days turn "want to work".
- Set **blacklists** (desks, shift types, regions, weekdays) and weekly-hour cap.
- **Try to break:** overlapping overrides; an override in the past; toggle mercenary
  on/off repeatedly; blacklist everything (you should get no matches).

## 5. Trades — Search
- Pick days to trade away → **Find**.
- Review **Packages** (multi-person) and **Individual takers**.
- **Try to break:** select many days; select days no one can take (expect "No Takers");
  use **What If?** to widen; select a high-demand day.

## 6. Trades — Intents feed (tiers)
- Browse **Intents / Bookends / Neutral / All**; tap ⓘ to read what each means.
- Open a **package** and an **individual swap**; read the bottom **Key**.
- ✅ Every tier is a real two-way (reciprocal) swap. One-way trades live in **ECB**.
- **Try to break:** confirm a package's people-count badge matches the rows.

## 7. Two-way & multi-person swaps (clarity check)
- Open a swap's dual calendars — **blue = you, red = them**, give = border, get = fill.
- ✅ Each card/summary spells out **what you give/get AND what each other person
  gives/gets**.
- **Circular trades** (3–4 people) should read as a chain of handoffs:
  *You → Denny: date · desk / Denny → Dimitry: … / Dimitry → You: …*
- **Try to break:** does anyone's give/get look wrong or missing? Does the chain
  loop back to you? Do the dates match the calendars?

## 8. ECB (one-way) trades
- Pick shifts you want taken, set the **ECB** offer, **Find**, **Request all**.
- In another tester's app: open the request, **accept per shift**, reply with employee #.
- Confirm the **queue** (first to accept each shift wins), the **ledger** (pending →
  done), and the **audit trail**.
- **Try to break:** two people accept the same shift at once; skip the #1 accepter;
  cancel an offer mid-queue.

## 9. Messaging — Inbox & Channel
- **Inbox** (🗂): propose/accept/counter/decline a swap; check "Needs your reply",
  Incoming, Sent. Confirm the other side sees your reply.
- **Channel** (📣): post what you're trading; reply public/private; edit/delete your
  post; use **bold/italic/strike**.
- **Try to break:** very long posts; rapid send; reply to your own post; delete a post
  others replied to; go offline then back.

## 10. Trades dashboard & status
- On the **Trades** tab, tap the status row (🟢🟡🔴💬) → check Accepted / Pending /
  Denied / History, and "Mark complete".
- **Try to break:** complete a trade, confirm counts update; check History after an
  ECB transfer.

## 11. Reminders, widgets, Siri
- Settings → set **lead time**; confirm a shift reminder fires.
- Add the **Next Shift** and **Trade Requests** widgets to your Home Screen.
- Ask Siri: *"Do I work tomorrow in BATMAN Watcher"*, *"Who can trade with me…"*,
  *"Turn on shift alerts…"*. (See the Shortcuts guide for the alarm/calendar automation.)
- **Try to break:** ask Siri before fetching a schedule; toggle notifications off/on.

## 12. General robustness
- Rotate the device; switch light/dark mode; bump up **Dynamic Type** (Settings →
  Accessibility) and confirm text scales without breaking layouts.
- Background the app for a while, reopen; lose/regain network.
- **Anything that looks wrong, confusing, or ugly → FEEDBACK: it.**

---

### What we most want to know
1. Anything **incorrect** (wrong days/people in a trade, bad counts, a match that
   shouldn't exist).
2. Anything **confusing** (you couldn't tell who gets what, a term you didn't know).
3. Anything that **crashes, freezes, or looks broken**.

Post it all in the channel with **`FEEDBACK:`**. Thank you! 🦇
