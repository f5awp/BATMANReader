# DX Trader — Comprehensive Product Brief (portable export)

**What this file is:** a single, self-contained, *current* description of everything DX Trader does —
written so a downstream agent with **no access to this codebase** can (a) build an impressive slide deck to
propose the app to dispatcher groups, and (b) rewrite/improve the in-app welcome screen and training. It is
compiled from a full sweep of the live source (Home/calendar/intents, Trades, messaging, services, and the
matching engine), so it is comprehensive and up to date — not the older in-app summary.

> **Downstream agent — two deliverables:**
> 1. **Pitch deck** for dispatcher groups (decision-makers + end users). Lead with the *pain* and the
>    *outcome*; keep "under the hood" for a credibility/appendix section. Tone: confident, concrete,
>    dispatcher-native — these are operational people who distrust hype.
> 2. **Welcome screen + training** copy: a first-run walkthrough + short training guide. Skimmable,
>    task-first, reassuring. Sections §4, §5, §18 are your primary source.
>
> Everything below is factual to the current build. When a detail is operationally important (a rule, a
> cap, a number), it's stated precisely so the deck/training don't overstate.

---

## Outline / Table of contents

| § | Section | For the deck | For welcome/training |
|---|---|:--:|:--:|
| 1 | One-liner, platform, audience | ● | ● |
| 2 | The problem it solves | ● | |
| 3 | Feature pillars (the "what it does" grid) | ● | ● |
| 4 | How it works — the core story | ● | ● |
| 5 | First-day walkthrough | | ● |
| 6 | Home tab, calendar & intents — full surface | ● | ● |
| 7 | Trades — three flows (Intents / Solutions / ECB) | ● | ● |
| 8 | Qual swaps — two flows + linking (differentiator) | ● | ● |
| 9 | Inbox, messaging & channel — full surface | ● | ● |
| 10 | Under the hood — the matching engine | ● (appendix) | |
| 11 | Schedule ingestion & data model | ● (appendix) | |
| 12 | Integrations & platform features | ● | ● |
| 13 | Settings & trade profile (control surface) | | ● |
| 14 | Desk / region / qualification model (domain) | ● | ● |
| 15 | Value proposition ("why adopt") | ● | |
| 16 | Screenshots available | ● | |
| 17 | Suggested deck outline | ● | |
| 18 | Welcome-screen / training copy suggestions | | ● |

---

## 1. One-liner, platform, audience

- **Name:** DX Trader (internal repo: BATMANReader).
- **Tagline:** *Schedule reading + shift trading for dispatchers — matched, scored, and synced.*
- **Platform:** iOS/iPadOS, SwiftUI. Whole-shop iCloud sync. Home-Screen widgets, Siri/Shortcuts,
  Apple/Google Calendar integration, on-device AI (iOS 27+).
- **Audience:** airline **dispatchers** who trade shifts against a complex master schedule with hard rules
  (desk qualifications, an 8-hour rest gap, weekly-hour caps, region/desk constraints).

**Elevator pitch:** DX Trader reads the dispatch master schedule for you — shifts, days off, vacation, and
qualifications — with no file to import and nothing to maintain by hand. Then it does the hard part: you
mark the days you want to give away, and it searches the entire roster for trades that would actually
work — checking each against the real rules and each person's own preferences before it ever appears. It
finds two-person swaps, larger multi-person packages, full circular loops where everyone covers someone
else, and three-party "qual-swap" bridges — then ranks the ones most likely to get a *yes* on top.
Everything — trades, the channel, statuses, team stats — syncs across the whole shop through iCloud.

---

## 2. The problem it solves (deck "why")

Dispatcher shift-trading today is manual, slow, and error-prone:
- The master schedule is a dense grid; determining who's off, qualified, and rested for a given desk is
  tedious, and mistakes (proposing an illegal trade) are costly.
- Finding a legal trade means mentally checking desk qualification, the 8-hour rest gap, weekly-hour caps,
  region/desk blacklists, and the *other* person's willingness — for every candidate, for every day.
- Coordination is scattered across texts/email/paper. ECB (extra-credit) shifts are claimed ad hoc with no
  fair ordering. There's no shared source of truth about who's available or what's been agreed.

**DX Trader replaces that with:** automatic schedule reading; a rules-correct engine that only ever surfaces
*legal, likely-to-succeed* trades, ranked best-first; in-app proposing/inbox/chat with partial accept;
three-party qual-swaps; fair first-come ECB queues; an ECB ledger; and a shop-wide synced channel + status
board + team metrics.

---

## 3. Feature pillars (the "what it does" grid)

| Pillar | What it means |
|---|---|
| **Auto schedule** | Your roster, vacation, and quals — read from the master, kept current automatically. No import. |
| **Real trades** | Two-person, multi-person, and circular swaps that pass every hard rule. |
| **Acceptance scoring** | Every trade graded by how likely both sides accept — best on top, unlikely ones filtered out. |
| **Qual swaps** | A qualified "bridge" desk-swaps so an unqualified taker can still cover — two ways to build one. |
| **ECB one-way** | Give a shift away for ECB with a fair, queue-ordered claim, tracked in a ledger. |
| **Channel + chat** | Broadcast what you're trading, threaded replies, @mentions with push, 1:1 chat with photos. |
| **Built into iPhone** | Apple/Google Calendar, Home-Screen widgets, Siri/Shortcuts, on-device AI summaries. |
| **Whole-shop sync** | Profiles, trades, channel, statuses, metrics — one shared board over iCloud. |

---

## 4. How it works — the core story (deck spine + welcome flow)

### 4.1 You tell the app what you want (Intents)
On Home you mark days with four intents (they're the heart of matching):
- **Trade away** (violet) — a working day you'd give up.
- **Want to work** (amber) — a day off you'd pick up.
- **Keep** (dark green) — a working day you'll never trade. *Hard limit.*
- **Must be off / Blackout** (slate) — a day off you'll never take. *Hard limit.*

For off days you can go finer than whole-day: mark **AM / PM / MID** availability per day (AM = 0500 start,
PM = 1300, MID = 2100 overnight). "Want to work" a specific shift type overrides a blackout on that day.
The app pairs your Trade-away days with others' Want-to-work days and vice-versa; **Keep** and **Must-be-off**
are never crossed.

### 4.2 It finds every legal trade
Search from **Intents** (marketplace) or **Trade Solutions** (pick specific give-days). The app scans the
entire roster and builds every legal trade it can:
- **Two-person swaps** first,
- **Multi-person packages** (several people each cover part),
- **Circular loops** (A→B→C→A — everyone covers someone, nobody loses hours),
- **Qual-swap bridges** (a third qualified person slides aside so an unqualified taker can cover).

Every leg is checked against the **hard rules** — desk qualification, the 8-hour rest gap, weekly-hour cap,
Must-Be-Off, Keep, the relief-dispatcher horizon, and bookend anchoring — and both people's **preferences**
before it's ever shown. The same eligibility code runs behind every feed, so the rules can never diverge.

### 4.3 The best matches rise to the top
Matches are **ranked, not piled.** A deal where **both** of you marked the day (a mutual 🔥) sits at the
very top. After that the app prefers trades that keep days off together (**bookends 📖**) over ones that
**split** a weekend, **fewer people** over more, and **sooner** dates over later. Anything too unlikely is
**filtered out** below an acceptance floor — the feed stays honest instead of padded with deals nobody would
take.

### 4.4 What raises/lowers a match
| Signal | Meaning | Effect |
|---|---|---|
| 🔥 Mutual intent | Both of you marked the day | Top priority |
| One-sided intent | Only one side marked it | Strong |
| 📖 Bookend | Pickup sits on the edge of days off | Boosts |
| Split | Pickup breaks up a weekend | Penalized* |
| Sooner date | The trade is coming up | Small boost |
| Q — qual bridge needed | A 3rd person must desk-swap | Small penalty (sorts qual-swaps lower) |
| Fewer people | 2-person vs 3–4 person | Preferred |
| Past acceptance | Partner usually says yes | Tiebreak only |

*The split penalty is *intent-scaled*: a fully-mutual leg almost cancels it, so a *wanted* split can still
surface while a no-intent split is heavily punished.

### 4.5 You propose; they Accept / Counter / Decline (with partial accept)
Tap **Propose** and it lands in the other person's in-app **Inbox**. They can Accept, **partially accept**
(check only the days that work → "Counter with N days"), Counter, Decline, or just Message. You chat on the
trade (photos, reactions, edit/delete). You get a push the moment a request arrives — and a stronger
**"Perfect Match" 🔥** alert when a trade lands exactly on a day you marked.

### 4.6 The five trade types (deck table)
| Type | Detail |
|---|---|
| Two-person swap | You ↔ one person, day-for-day |
| Multi-person package | Several people each cover part; provably-fewest people |
| Circular trade | A→B→C→A — everyone nets even hours |
| Qual swap | A qualified bridge frees a desk for an unqualified taker |
| ECB one-way | Give a shift for ECB credit, claimed first-come in a fair queue |

---

## 5. First-day walkthrough (welcome/training source)

1. **Turn on iCloud & the shared calendar** — how you see everyone, the channel, and your schedule from the
   master.
2. **Set your trade settings** — openness (Bookends-only / Open to all / None), blacklists, a public status.
3. **Mark your intents** — on Home tap *Mark Intents* and paint working days to trade away + off days you'd
   pick up (AM/PM/MID).
4. **Say hi in the channel** — @mention someone or @everyone.
5. **Search for a trade** — Intents or Trade Solutions; best matches on top.
6. **Send a request** — Propose, then track replies in your Inbox.
7. **(Beta)** — try to break it; report anything odd in the **#feedback** channel.

---

## 6. Home tab, calendar & intents — full surface

- **Mark Intents mode** with two sub-modes: *Working Shifts* (brushes: Keep / Want to Trade) and *Days Off*
  (Blackout ↔ Want to Work, with AM/PM/MID sub-brushes; no selection = whole day). An **overwrite guard**
  asks once per session before repainting a differently-marked day; an **Erase** tool clears a day's
  intent+note+topology; a **Note stamp** field appends a short note (≤50 chars) to every tapped day.
- **Save model:** the Save button glows when there are unsaved changes; saving re-publishes your availability
  to peers and triggers exactly one feed recompute (no re-search on every keystroke). Leaving with unsaved
  edits prompts save-or-discard.
- **Calendar:** month-paged by default, with an **opt-in continuous** week-stream mode (single pinned weekday
  header + a floating month tab that expands to show that month's stat chips). **Month stat chips** count
  on / off / trade / keep / blackout / want-to-work / vacation.
- **Day cells** show worked shift type + desk (e.g. "AM 82"), off-day AM/PM/MID availability pills (gold =
  wanted, ✕ = blacked out), a **VAC** teal tile for vacation, a lock glyph for blackout, and small corner
  markers: **note** (blue public / orange private), **high-demand holiday** (orange star, auto-computed incl.
  floating holidays + Good Friday), **personal milestone** (pink star). Tapping a day flashes its intent
  pill; the full **day editor** (long-press / tap in read-only) sets intent, a free-text reason
  (auto-categorized on-device: vacation / avoid-weekends / medical / personal-event / fatigue), significant-day
  toggle, and a public/private note.
- **Visibility layers** toggle Notes / Intent colors / AM-PM-MID pills / Shift-type labels / Desk numbers.
- **Color Key** sheet is the single legend for every hue + marker.
- **Reconciliation banner:** when a fresh master arrives, only *changed* days have their intents cleared
  (diff-based, never touches unchanged days); the banner says "N dates changed — tap to review" and flashes
  them.
- **Vacation & ECB-VC:** the master can't tell whether you *traded into* a vacation day, so vacation (V) and
  ECB-VC (w) days start OFF; open the day and toggle **"Trade Picked Up"** to build the worked day into the
  app + Apple Calendar. Shown as a teal **VAC** tile (display-only fact, not an intent).

---

## 7. Trades — three flows

**Segment 0 — Intents (marketplace).** Ranks by mutual intent, not just availability. Two sections:
**Mutual** (both of you marked the day — computed instantly) and **All** (every possible partner incl. people
without a profile — generated lazily on tap). A badge shows the mutual-match count. The heavy 3+/loop search
is opt-in via **"More: 3+ & loops."**

**Segment 1 — Trade Solutions (give-day search).** Pick give-days on a calendar → **Find** (fast two-person).
Results are cards: **CompactSwapCard** (2-person: counterparty, status, "You get / They get" once, 🔥/📖/Q
badges, Propose) and **PackageCard** (3+/circular: headline, quality badge Optimal/Fast/Circular, participant
lines, Propose/Execute). A **Master Filter** ("I'm Feeling Lucky → Generate") runs the heavy search with
controls: engine (Min-Cost / N-Way / Both), max people (1–4), force-include a specific person, date range,
shift-time (AM/PM/MID), desk-qual filter, and a per-search openness override. Also: a **"No Qual Swap"**
toggle (hides qual-swap trades; appears only when results contain them) and **"look up a dispatcher."**

**Segment 2 — ECB (one-way).** Select shifts → set an ECB value (5–25 in 0.5 steps; a 1.5× OT shift = 13.5)
→ Find eligible coverers (off + qualified + rested + passes their openness) → send to **Bookends only / All /
Selected**. Each dispatcher is offered only the days they can actually cover; interested people are ordered
into a **fair first-come queue** (each sees their position). Recipient confirms once the credit lands; the
official ECB form is filed outside the app.

**Package detail view.** Twin per-person calendars (side-by-side in landscape, stacked in portrait) with your
days blue, peer red, loop days violet, mutual days gold. Day chips: tap to focus a day on the calendar; a
**"Select specific days"** toggle turns chips into checkboxes so you can **propose a subset**; when a peer
offers ranked give-back alternatives you pick one via radio chips ("pick 1", top tagged "best"). Circular
loops are all-or-nothing ("Execute loop"). A **"Sent"** anti-spam state disables Propose after you've sent to
that person/day.

---

## 8. Qual swaps — two flows + linking (this is a differentiator)

A qual swap is a **3-party bridge**: giver **A** gives a desk that the off-taker **B** isn't qualified for, so
a qualified working dispatcher **C** slides onto A's desk and frees C's own desk for B. **C is an *enabling*
leg — not counted in the trade's people-count.** Bridges are **not always domestic**; they're ranked by C's
own qual-swap preference and **flagged ⚠ when the swap is *unfavorable* for C** (included, not hidden, with a
warning).

- **Green double-arrow finder (bridge-first).** In Trade Solutions, when a selected desk needs a
  qualification, the green button opens a per-give-day sheet listing the **working C bridges** who could take
  that desk — favorability-ranked, filterable by qual, favorable ✓ / unfavorable ⚠ tagged. You broadcast a
  standing, self-addressed bridge request; it later **links** into a normal A→B trade via **"Merge with base
  trade"** in the inbox.
- **Q caution button (trade-first).** In the package detail view, the amber **Q** button opens a picker of
  bridges for that specific trade (favorable first, unfavorable ⚠ last, each showing "frees desk X (qual)").
  You pick bridges → Propose sends a single request carrying the qual-swap leg to multiple bridges at once.
- **Automatic surfacing.** Trade Solutions/Intents auto-append qual-swap solutions as lower-ranked, Q-flagged
  cards whenever a give-day is blocked only by a qualification.
- **Inbox lifecycle:** bridges tap **"Accept qual swap"** (first-5 acceptances cap → waiting → offersOpen →
  offersFull); the taker **chooses** which bridge's freed desk to take (or Declines the package); the giver
  can then **merge** the settled bridge into the clean base trade so the two requests become one.

---

## 9. Inbox, messaging & channel — full surface

- **Trade Inbox** with four tabs — **Intents / Search / ECB / Misc** (qual-swap bridges + manual trades file
  under Misc; ECB sorted by amount). Request rows show avatar, a compact day summary, status badge, an
  **invalid** flag if a traded day is no longer worked, a **"Matches your intent" 🔥** badge, and swipe to
  **Archive/Delete** (archiving an accepted trade logs a successful-trade metric).
- **Thread detail** (reskinned into app-style cards): a trade header (2-Way / Multi-Person Loop / ECB) with
  who-gives-what, a stale-day warning, a **respond card** with **"Days to accept" toggles** (partial accept →
  "Accept" if all, **"Counter with N days"** if a subset), plus Message / Decline; a chronological audit
  trail; and 1:1 chat.
- **1:1 chat:** iMessage-style bubbles, photo attach (compressed base64), edit/delete (soft-delete tombstone),
  emoji reactions (one per user).
- **Broadcast channel:** three channels (**# general / # trades / # feedback**). Posts support Markdown,
  photos, reactions, pinning, edit, and **@mentions** (picker-inserted; explicit @names fire a push,
  @everyone doesn't). **Reddit-style threaded replies** with per-comment collapse, public/private scope,
  nesting, photos, reactions. Posts auto-expire (~21 days). Admin/moderator can non-destructively hide posts.
  An unread badge counts new posts since last seen.
- **Request lifecycle:** send (stamps a **Perfect Match** flag when the offer hits the recipient's marked
  intents), respond (Accept/Decline/Counter/Message), cancel (sender). **Auto-complete:** when a new master
  is imported, trades *proven by the schedule* (your give-days flipped to off and take-days flipped to
  working) are auto-accepted, archived, and logged to history. A learned **acceptance prior** from each
  partner's history breaks ranking ties.

---

## 10. Under the hood — the matching engine (credibility / appendix)

The engine is genuinely sophisticated; use this to make "ranked, legal, trustworthy" credible.

- **One shared eligibility predicate** (`TradeEligibility.canCover`) enforces every hard gate — dispatch-shift
  timing (only 0500/1300/2100 starts, never training desks), off-on-cover-day, **desk qualification**,
  **8-hour rest**, **weekly-hour cap**, **Must-Be-Off**, **Keep**, **relief-dispatcher horizon**, and
  **bookend anchoring** — plus a soft layer (openness, blacklists, want-to-work overrides, mercenary mode).
  Because every path calls this exact code, the rules can **never diverge** between feeds. Returns
  eligible + isBookend.
- **Two engines, distinct rankings.** `packages()` (Trade Solutions) ranks **coverage-first** (most of *your*
  days covered → fewest people). `intentSolutions()` (Intents) ranks **intent-first** (most mutual 🔥 →
  fewest people) and is a true *marketplace* — a pairing where neither side marked an intent is excluded by
  construction.
- **Three matching layers:** (1) the eligibility predicate; (2) **two-way reciprocal exploration** that builds
  the balanced day-for-day set and tags each leg mutual 🔥 / bookend / split; (3) **N-way circular DFS**
  (`nWayRoutes`) — a bounded, best-first, cooperatively-cancellable depth-first search for loops that close
  only at ≥3 participants (a 2-cycle is just a swap), capped by a maxRoutes backstop.
- **Provably-fewest-people covers:** `OptimalMatcher.minPeopleReciprocal` is a branch-and-bound over peer
  subsets; a **min-cost-flow** assignment picks the best arrangement (urgency-weighted, fewest splits) when
  several tie on people-count. Reciprocity is always balanced (give N, receive N) — one-way giveaways are the
  separate ECB path.
- **Acceptance model (`packageLogProb`).** Each leg → a feature vector (intent 0–2, bookend vs split,
  soonness decay `exp(−0.05·daysUntil)`, qual-bridge friction, ECB value, a small *learned* per-person
  accept prior). A weighted logistic gives the leg's accept probability; the split penalty is intent-scaled.
  A package's score is the product of its legs plus a `0.85`-per-extra-person penalty, so a smaller clean
  trade outranks a larger one all else equal.
- **Curation by absolute floor, not top-N.** Score-order, keep everything above **0.32** combined-accept for
  the normal feed (**0.07** under "I'm Feeling Lucky"); an empty-feed fallback shows the best few; a safety
  ceiling caps the total. Qual-swap packages are exempt from the floor (they carry a friction penalty but must
  surface).
- **Performance.** *Parse-once/query-many* — the roster is parsed and indexed once; searches are in-memory
  map lookups. The background feed runs only the fast two-person pass; the heavy 3+/circular/min-cost/qual-swap
  work is **opt-in** ("Generate"). Every search builds one shared `MatchContext` snapshot (roster window,
  per-worker day-maps, candidate universe, acceptance-prior map) threaded through all paths; the heavy pure
  cores run **off the main actor** via `Task.detached` over `Sendable` snapshots so the UI never freezes, and
  re-searches supersede stale ones via cooperative cancellation. Pure cores have an adversarial unit-test
  harness.

---

## 11. Schedule ingestion & data model (appendix)

- A **day-row-spine parser** reads the grid-format dispatch master: locates the day spine, walks each worker
  column, reconstructs per-day shifts (start hour, desk, quals), and bounds each worker to a rolling ~15-month
  window. A known dropped-separator quirk on certain rows is handled explicitly. Vacation (V) / ECB-VC (w)
  rows resolve to true days off (never phantom shifts).
- The roster persists **per-device** in SwiftData (not mirrored). Only the master CSV is shared — one
  version-stamped record on the CloudKit public database, fetched via a metadata-only probe first so a device
  re-imports only when the master actually changed. Import is **atomic** (insert a new generation, swap the
  reader pointer in one write, delete old — readers never see a half-written roster). A corrupt store
  self-heals rather than bricking launch.
- Your personal schedule, shift reminders, widgets, and Siri intents are all derived from your row — set your
  Employee ID once and everything follows.

---

## 12. Integrations & platform features

- **Apple Calendar (EventKit):** your working shifts build into a personal "AA Schedule" calendar (title,
  desk/role/time notes, a pre-shift alarm at your lead time, dedup so no duplicates); a shared "AA Dispatch"
  calendar can carry your OFF-day availability to the group. Any in-app change (e.g. a picked-up vacation day)
  updates there too. **Google Calendar** works by adding your Google account in iOS Settings → Calendar.
- **Push notifications** (targeted CloudKit subscriptions): ordinary incoming request; a stronger **Perfect
  Match** alert; **new channel post**; **@mention**; **qual-swap bridge blast** (you're a candidate); and a
  **qual-swap response** (fires on record update). Plus a **daily digest** at a user-set hour with
  background-refreshed pending/unread counts.
- **Home-Screen widgets:** **Next Shift** (type, desk, date, time + a week strip) and **Trade Requests**
  (pending count).
- **Siri / App Shortcuts / App Intents:** fetch schedule; get shifts / tomorrow's shift / a specific date /
  what changed; get available dispatchers on a date filtered by AM/PM/MID; a `ShiftEntity` with a
  pre-computed alarm hour for "Create Alarm" automations. **On-device AI (iOS 27+, Foundation Models):** a
  natural-language schedule summary and a drafted trade-broadcast message — free, private, offline.
- **ECB Accounting** ledger (YNAB-style): categorized deposits (OT, holiday), withdrawals, adjustments, and
  trade lines; balances for **Available** (cleared, capped at 144), **Projected** (once scheduled ECB + IOUs
  land), and **Owe / Owed** outstanding IOUs, with pending-confirmation lines and a payable capacity.
  Personal lines sync to your private iCloud DB; shared trade lines to the public DB, both dispatchers in
  sync; in-app accepted trades auto-post a confirmed line to both ledgers.
- **Team status board & metrics:** an append-only event log (search / proposed / trade) drives shop-wide
  counts and a status board; each dispatcher broadcasts a 140-char public status.
- **Accessibility:** a default-on **screen magnifier** (draggable button; pinch to zoom, two-finger pan; one
  finger still taps/scrolls) and full Dynamic Type via semantic type styles.

---

## 13. Settings & trade profile (control surface)

- **Openness:** Bookends-only / Open to all / None, plus **date-range overrides** (temporarily change openness
  for a span) and a **Mercenary mode** (take any qualifying pickup, ignoring soft prefs — hard legal gates
  still apply).
- **Blacklists:** weekdays, desks, shift types (AM/PM/MID), regions; and **qual-swap preferences** (per-qual
  value where higher = preferred, 0 = never; plus a qual-swap desk blacklist).
- **Relief dispatcher:** limit your known schedule to a horizon (default ~45 days); days beyond it are hidden
  from you and from others' trading.
- **Other:** weekly-hour cap and normal max-people search depth; public status; private notes (2000 chars,
  synced across *your* devices only); contact info; appearance; notification lead time; daily-digest hour;
  Employee ID + Sign in with Apple.
- **Sync model:** the CloudKit public DB holds profiles, channel, trades/responses, and metrics — each record
  stores the whole model as a JSON payload plus a few flat queryable fields (toID, fromID, candidateIDs,
  perfectMatch, hasQualSwap) for cheap server-side filtering, so the data model evolves without schema churn.
  Private notes/intents/ledger/history use the private DB with **last-write-wins** merges (by updatedAt), and
  a guard ensures a transient empty fetch can never wipe a populated local cache.

---

## 14. Desk / region / qualification model (domain reference)

- **Regions & quals:** Domestic (D — universal), European (E), Latin America (L), Pacific (P), and coordinator
  roles (ATC = A, Ops = O, Regional = R, Chief = S). Numeric desks are gated by region; non-numeric desks map
  to coordinator quals. Training desks are never tradeable.
- **Trade timing rule:** only shifts that **start at 0500, 1300, or 2100** are tradeable (globally, direct or
  qual-swap).
- **Color system (one hue = one meaning):** primary/blue = you/actions; success/green = accepted/keep/optimal;
  pending/amber = waiting/want-to-work; danger/red = declined; heat/orange = demand/urgency; special/violet =
  multi-way/circular/trade-away; milestone/pink; neutral/gray; locked/slate = must-be-off/blackout;
  passiveOpen/faded-slate = passively open; vacation/teal.

---

## 15. Value proposition (deck "why adopt" — outcomes)

- **Saves time & removes error:** no manual schedule reading; every surfaced trade is guaranteed *legal* and
  *rested* — no accidentally proposing an illegal swap.
- **Higher trade success:** best-first ranking + acceptance scoring means the trades you send are the ones
  most likely to get a *yes*.
- **Unlocks trades people miss:** multi-person, circular, and qual-swap trades a human wouldn't spot by hand.
- **Flexible acceptance:** partial-accept lets a partner take just the days that work instead of declining the
  whole thing.
- **Fair ECB:** transparent, queue-ordered claims + a real ledger, instead of "who texted first" and paper
  math.
- **One shared board:** the whole shop sees the same channel, statuses, and stats.
- **Fits existing tools:** flows into Apple/Google Calendar, widgets, Siri/Shortcuts; on-device AI keeps data
  private.

---

## 16. Screenshots available (for the deck agent)

In the repo (ask the owner to attach these image files):
- `BATMANReader/Comparison/IMG_4150.PNG … IMG_4157.PNG` — UI surfaces.
- `BATMANReader/IMG_4168.PNG`, `BATMANReader/IMG_4171.PNG`, `BATMANReader/app-vs-mockup.png`.
- Recommended captures to add: Home calendar with intents painted; Trade Solutions results with 🔥/📖/Q
  badges; a qual-swap bridge sheet (favorable vs ⚠); the package detail twin calendars + subset select; the
  Intents 🔥 marketplace; the inbox thread with "Days to accept"; ECB queue + ECB Accounting ledger;
  Home-Screen widgets.

---

## 17. Suggested deck outline (starting point)

1. Title + tagline. 2. The dispatcher's shift-trading problem today. 3. DX Trader in one screen (Home +
Intents). 4. How matching works (§4 spine). 5. Ranked, legal, trustworthy (the scoring table). 6. The five
trade types (incl. the "wow": circular + qual swaps). 7. Propose → Inbox → partial accept → chat. 8. ECB fair
queue + ledger. 9. One shared board (channel/status/metrics/sync). 10. Built into iPhone
(calendar/widgets/Siri/on-device AI). 11. Under-the-hood credibility (§10, appendix). 12. Value/ROI (§15).
13. Call to action (pilot with a shop).

---

## 18. Welcome-screen / training copy suggestions

The current in-app welcome content is good but **predates** qual-swap's two flows, partial accept, the ECB
ledger, and the Intents Mutual/All split. When improving it:
- **Lead with the checklist** (§5), not the pitch — first-day dispatchers want "what do I do."
- **Add a short "Qual swaps, explained"** card: A gives a desk → C (qualified, working) slides on → B (off,
  unqualified) takes C's freed desk. Two ways to start one (green finder / Q button); C is never counted as a
  participant; ⚠ means it's unfavorable for C.
- **Add "You don't have to accept everything"** (partial accept): check just the days that work → Counter with
  N days.
- **Add "Track your ECB"** (the ledger: Available capped at 144, Projected, Owe/Owed, IOUs).
- **Keep the "How it works" walkthrough** (§4) and the scoring table (§4.4) — they're the trust story.
- Keep training skimmable: one concept per card, an icon, one action.

---

*Source of truth: a full sweep of the live source — Home/calendar/intents (`HomeView`, `HomeCalendar`,
`DayIntentStore`, `ShiftAvailability`), Trades (`TradesView`, `AvailabilityView`, `TradeIntentsFeed`),
messaging (`MessagingViews`, `Messaging`), services (`CloudKit*Service`, `CloudPush`, `EventKitManager`,
`NotificationManager`, `WidgetData`, `RosterStore`, `SettingsManager`, `TradeHistoryStore`/ECB accounting,
`Sources/Intents/*`), and the engine (`TradeRouter`, `TradeMatcher`, `OptimalMatcher`, `MinCostFlow`,
`TradeProfile`), plus `AppGuide` in `TradeEngineModels.swift` and `DX-QUALSWAP-FLOW.md`. Regenerate from these
if the app changes.*
