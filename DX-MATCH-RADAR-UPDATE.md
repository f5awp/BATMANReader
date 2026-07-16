# Match Radar — Update (what changed since the last build)

This update covers everything added **after** the original 11-stage Match Radar build (documented in
`DX-MATCH-RADAR-CHANGES.md`). The full end-to-end system is in `DX-MATCH-RADAR-FLOW.md`. Deploy + still-
deferred work is in `DX-DEV-TODO.md`.

---

## Standing offers — how they work (re-explained, plain English)

A **standing offer** is a saved trade wish you set once and leave running: **"give away one of these days,
to get one of these days in return."** Instead of searching over and over, the app keeps checking for you.

**How you make one:** open **Standing Offers** (top of the Inbox → Matches lane) → **＋** → pick the days
you'll **give** (your working shifts), pick the days you want to **get** (a calendar of future dates),
choose Day / ECB / Either, add a note, Save. It's now "watching."

**What the app does with it:** every time the radar runs (open Home/Inbox, refresh, new schedule, or the
daily background check), it looks at everyone eligible and asks, for each offer:
> Is there a person who would **take one of my give-days** AND is **offering one of my get-days** (a day
> they marked to trade away that I'm legally able to work)?

If yes, the offer is **"fillable."**

**What you get:** the moment an offer becomes fillable, you get a push — **"Your standing offer can be
filled — give Aug 3, get Aug 10 with Blake."** Open the offer to see every peer who fits, and press
**Propose** to send one of them the trade. (Tapping the push jumps you to that day.)

**Important — this is the "v1" behavior:**
- It **alerts YOU** and you send the proposal manually. It does **not** auto-send offers out to peers on its
  own. (An "auto-send to the best 3–5 matches" version was designed but not built — see DX-DEV-TODO.md.)
- You can turn the alerts off: **Trade Settings → Match Radar → Auto-match standing offers.** With it off,
  offers still match and show in the Standing Offers list; you just don't get pushed.
- Offers keep standing until you **pause** (toggle) or **delete** them. No auto-expiry yet.
- Each alert fires **once** per offer becoming fillable (it won't re-nag you every recompute).

**Where it lives / syncs:** your offers save on the phone and sync across your own devices via a private
iCloud record — that sync needs a CloudKit field deploy (`standingOffers` / `standingOffersUpdatedAt`).

---

## Everything that changed since the last update

### Calendar & day markers
- The green **star now covers BOTH directions** with one marker: an off-day you can pick up **or** a working
  day someone wants to work (a taker for your shift).
- **Significant days** now show a **filled orange/pink disc behind the date number** (was a corner star that
  clashed with the match star). The **"today" blue ring** now also shows on significant days (it used to
  vanish there).

### Day detail
- Tapping a day opens **Info first** (left), **Trade List** second (right).
- Trade List shows **one list based on the day**: off day → "Shifts you can pick up"; working day → "Wants to
  work this day."
- "Shifts you can pick up" now lists only **real offers** (people who marked the day to trade away), not every
  coworker you're merely eligible to cover.
- List rows are **cards**; tapping a person opens the **two-way calendar** to propose (seeded with that day).
- **Trade options** on a trade-away day now include an optional **date calendar** for "accept a return only on
  these dates" (in addition to shift types).

### Performance
- The day's Trade List is now **instant** — the radar builds a per-day index in one pass, so opening a day is
  a lookup, not a fresh search.
- The heavy scan runs **off the main thread**; the day sheet opens immediately (spinner only on a cold start).
- The world the radar builds (**MatchContext**) is now **cached** and only rebuilt when something relevant
  changes (your day, the roster, peer profiles) — big speed-up.

### Notifications (this is the part that mixed several systems)
- **Both sides get "It's a match!"** — when you and a coworker both marked the same trade, each phone detects
  it and alerts its owner: **"You have a match on Aug 7!"** (taps into that day). No server needed.
- **Dated, per-day copy** for watched-day alerts: off day → *"Someone is looking to drop Aug 7 you want to
  work!"*; working day → *"Someone is looking to work on Aug 7 you want to trade!"* — and tapping any alert
  **deep-links** straight to that day's Trade List.
- Watched-day alerts fire **only for days you Watch**; **unwatched** opportunities roll into the **daily
  digest** ("…and N trade matches you haven't watched") instead of spamming you.
- Fixed a bug where new-opportunity alerts **re-fired every launch**; each now alerts once.

### Trades & safety
- **Duplicate guard:** if you and a coworker both got the same match and both try to propose it, the **second
  proposal is caught** — *"[name] already proposed this — reply in your inbox"* — instead of creating a twin.
  (Fresh proposals only; counters and ECB offers are never blocked.)
- Proposals still carry **alternate days** so the other person can counter with a different day you offered.
- Proposing from a day/ match / standing offer files in the recipient's inbox under **Search**.

### Cross-device sync
- Your **watched days** and the radar's "already told you" memory now sync across your own devices (needs the
  `radar` CloudKit field deploy).

---

## ⚠️ Before this all works across devices — CloudKit Console deploy

Add these fields to the **PrivateState** record (none need to be Queryable):
`radar`, `radarUpdatedAt`, `standingOffers`, `standingOffersUpdatedAt`. Until then, watch/seen and standing
offers work **on the one device** but don't sync. (Full list in DX-DEV-TODO.md.)

## The honest limit
Radar alerts (watched / match / standing) arrive the **next time each phone runs the radar** — not the exact
second a coworker acts. Only a real **sent proposal** pushes instantly. True real-time radar is the deferred
CloudKit silent-push work.
