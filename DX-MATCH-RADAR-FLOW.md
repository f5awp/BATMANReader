# How the Match / Radar / Offers system works — plain English

This is the end-to-end story of the trade-matching system, including the pieces that got mixed together
(the radar star, watched days, standing offers, and the different kinds of notifications). Written to be
read start to finish, no code.

---

## The words (what each thing means)

- **Intent** — what you mark on a day: "want to trade this away" (a shift you work) or "want to work"
  (a day you're off). Peers publish theirs too.
- **The radar** — the app quietly compares your schedule + intents against everyone else's and figures out
  what trades are possible for you. It runs on your phone; there is no server doing this.
- **Star** ⭐ — a green star on a calendar day = there's a real opportunity for you that day.
- **Watch** 🔵 — a blue ring you put on a day to say "alert me about this one."
- **Match** — the strongest case: you AND another person both marked the same trade. You both want it.
- **Standing offer** — a saved "trade X to get Y" that keeps watching for someone who can fill it.

---

## When the radar runs

The radar re-checks (we call it a "recompute") at these moments — NOT continuously:

1. You open the Home tab.
2. You open the Trade Inbox.
3. You pull-to-refresh, or hit the refresh button in a day's detail.
4. A new master schedule is imported.
5. A background check the phone runs about once a day (best effort — iOS decides).

So everything below happens "the next time the radar runs," not the instant a coworker marks something.
(Making it truly instant needs a push system we've intentionally left for later.)

---

## The calendar star (both directions, one star)

When the radar runs, each of your days can earn the **same green star** for either reason:

- **Off day** → someone who works that day wants to **drop** it, and you're legally able to work it
  (right quals, rested, not blacked out). You could pick it up.
- **Working day** → someone wants to **work** that day, and they're legally able to cover your shift.
  They could take it off your hands.

A **blue ring** appears on any day you tapped **Watch Day**. Star + ring can show together.
(The orange/pink **filled disc** behind a date number is a different thing — a significant/holiday day.)

---

## Tapping a day → the day detail

Tapping any day opens a 2-tab sheet:

- **Info** (opens first) — the normal editor: your intent, reason, note, "significant day," carryover
  vacation, and — if you're trading the day away — the **trade options** (Day / ECB / Either, which shift
  types you'll accept back, and optionally which dates via a calendar).
- **Trade List** (second tab) — who you can actually trade with that day. It shows ONE list based on the day:
  - If it's your **off day** → "Shifts you can pick up" (people dropping that day).
  - If it's your **working day** → "Wants to work this day" (people who'd take your shift).
  Each person is a card. Tap a card → the **two-way calendar** (both your schedules side by side), where you
  pick the day(s) and press **Propose**.

The Trade List is instant because the radar already built it during the last recompute (it's a lookup, not
a fresh search).

---

## The four kinds of notification (this is the part that got mixed)

There are FOUR different alerts. They come from different places and mean different things:

| Alert | Fires when | Who gets it | Needs Watch? |
|---|---|---|---|
| **Watched-day alert** | A new opportunity appears on a day you're **watching** | You | Yes |
| **"It's a match!"** | A new **mutual** match forms (you both marked the same trade) | **Both** people | No |
| **Standing-offer alert** | A saved offer can now be filled by someone | You (the offer owner) | No |
| **Incoming request** | Someone actually **sends you a proposal** | The recipient | No |

Key points about how they mix:

- The first three (watched / match / standing) are **the radar talking to you on your own phone.** They
  fire during a recompute, and each one alerts you **once** per new thing (it remembers what it already told
  you, so you don't get pinged again for the same day).
- The **"It's a match!"** alert is special: because a mutual match is symmetric, **each person's phone
  detects it independently**, so **both sides get notified** — no server needed. Copy: *"You have a match on
  Aug 7!"* Tapping it jumps to that day's Trade List.
- The **incoming request** alert is the OLD, real-time one (CloudKit push). It fires the moment someone
  actually sends you a trade request — that part IS instant.
- Unwatched opportunities don't spam you per-day; instead they're **summarized once a day** in the daily
  digest ("…and N trade matches you haven't watched").
- **Standing-offer alerts** can be turned off in **Trade Settings → Match Radar → Auto-match standing
  offers.**

---

## Proposing a trade (and what stops duplicates)

1. From a day's Trade List (or the Matches lane, or a standing offer), you pick a person and press
   **Propose**.
2. That sends a real trade request. It shows up in **their** inbox under the **Search** tab, and they get the
   instant **incoming request** push.
3. The request carries **alternate days** too — so the other person can counter with a different day you also
   offered, not just the one you picked. Both of you see the alternates on the card.
4. **Duplicate guard:** if you and a coworker both got the same match and you both try to propose it, the
   **second** proposal is caught. Instead of creating a twin trade, the app says *"[name] already proposed
   this — reply to it in your inbox."* (This only applies to fresh proposals; counters and ECB offers are
   never blocked.)

---

## Standing offers (the "set it and forget it" version)

1. In **Standing Offers** (top of the Inbox Matches lane) you create "give these days → get these days."
2. Every recompute, the radar checks if anyone can fill both sides.
3. When someone can, you get the **standing-offer alert** and can propose to them in one tap.
4. v1 note: it alerts **you** and you send manually — it does NOT auto-send to peers. (An auto-send-to-best-
   matches version was designed but not built; see DX-DEV-TODO.md.)

---

## What lives where (local vs synced)

- **On your phone only until deployed:** your **watched days**, the radar's "already told you" memory, and
  your **standing offers** sync across YOUR devices via a private iCloud record — but that needs two new
  CloudKit fields deployed (`radar…`, `standingOffers…`). See DX-DEV-TODO.md.
- **Already shared with peers:** your published **intents/profile** (how the radar sees you) and actual
  **trade requests** — these already sync, no deploy.

---

## The one honest limitation

Radar alerts (watched, match, standing) arrive **the next time each phone runs the radar** — app open,
refresh, or the daily background check — not the exact second a coworker marks something. Only the
**incoming request** push is truly instant. Making the radar instant too is the deferred CloudKit
silent-push work in DX-DEV-TODO.md.
