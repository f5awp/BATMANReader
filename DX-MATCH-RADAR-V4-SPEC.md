# Match Radar v4 — Architecture Spec (locked)

The organizing principle is an **intent ladder** — how much intent exists on each side
decides which surface a trade lives in. A candidate appears in **exactly one** tier.

The real dividing line is **"does the app need you to pick days?"**

| Tier | Contains | Needs a day choice? | Behavior |
|---|---|---|---|
| **AUTO** | 4-mutual day-for-day, **or** ECB-only-day matches | **No** (days fully determined / one-way) | auto-sent by the giver (or SEND when toggle off) |
| **Suggested** | 3-mutual & 2-mutual (day-for-day + ECB fallback) | **Yes** | opens two-way calendar to pick → propose → Requests › Sent |
| **Calendar Day Detail** | everything, incl. open discovery | — | browse by date; never auto |

A candidate appears in **exactly one** tier.

---

## Roles & directions

A trade always moves a shift from the **worker → coverer**.
- **Giver** = the **Want-to-Trade** side (owns the shift). **Single initiator: only the giver auto-sends.**
- **Taker / coverer** = the **Want-to-Work** side (off that day, covers the shift).

Per-day intent options:
- **Working day** → *Want-to-Trade* (+ optional criteria) or no intent.
- **Off day** → *Want-to-Work* (+ optional criteria) or no intent.
- Criteria (date / shift-type / qual) are a **two-sided** filter: they must satisfy *your*
  accept-scope **and** you must satisfy *theirs*.

---

## The four desires (mutual-count)

For a swap of your X ↔ their Y: `M1` you want X gone (you marked Want-to-Trade X), `M2` they
want X (they marked Want-to-Work X), `M3` they want Y gone (they marked Want-to-Trade Y),
`M4` you want Y (you marked Want-to-Work Y).

- **4-mutual** = M1+M2+M3+M4 — the days are fully determined and both want both legs.
- **3-mutual / 2-mutual** = fewer desires aligned; a *day choice* exists.

---

## AUTO (was "Proposed") — zero-decision sends only

Auto-sent by the **giver** (the Want-to-Trade side); the **taker never auto-sends** (kills
mirror duplicates by design). AUTO contains only trades needing **no day choice**:

1. **4-mutual day-for-day** — the exact X↔Y is agreed by both marks, so it sends itself.
2. **ECB-only-kind days** — a day you marked kind = **ECB** that a Want-to-Work peer covers.
   One-way (no return day), so nothing to pick. (A **Both**/Day day with only a partial match
   goes to Suggested, so auto-ECB never preempts a day-for-day you might prefer.)

**Choice rules:** the **Want-to-Work (receiver) side chooses** Day vs ECB when an offer carries
both; with **multiple bidders (≤3)** the **giver chooses the person**. ECB is inherently
"complete" (sheds an unwanted shift / gains a wanted one, no unwanted shift in return).

**Multiple 4-mutual return options** (several fully-mutual Ys): auto-send the top-ranked Y and
**carry the alternates** (existing propose-carries-alternates), so the taker can counter.

**Toggle off** ("Auto-match my intents"): the item still shows in AUTO but with a **SEND**
button instead of firing. It does not fall to Suggested. On the taker's side an unsent mutual
shows "matched — waiting on \<giver\>" with an optional **Send pickup** so it never dead-ends.

---

## Suggested — you pick the days

Matches where **you** marked (Want-to-Trade or Want-to-Work) and a real day-for-day exists but
it's **not** a clean 4-mutual — i.e. **3-mutual or 2-mutual**, so a day choice is needed.
- **Sorted 3-mutual → 2-mutual**; ECB is offered as a fallback within each (not part of the sort).
- Tap → the two-way calendar (**best + alternates**) → you choose day(s) → propose / counter.
- **Proposing from Suggested files under Requests › Sent** (not AUTO). AUTO is only the app's
  own auto-sends.
- Includes days where the counterpart is only eligible (hasn't marked) — still your-marked side.

---

## Calendar Day Detail (broad — discovery)

Looks at **what they want**, whether or not you've marked anything:
- **Working day**, you marked Want-to-Trade → **who could work it** (sorted).
- **Working day**, no intent / open → **who wants to work it** (shown, **not** auto-proposed).
- **Off day**, you marked Want-to-Work → **whose shifts you could pick up** (sorted).
- **Off day**, open → **who marked Want-to-Trade** (their shifts available).

Never auto-sends. It's the per-date lens; Suggested is the marked-only roll-up.

---

## Global filters (all three surfaces)

Never surface: **Keep**, **Must-Be-Off**, **past days**, **same-day-locked** (a day already
in an accepted trade). **Carryover-vacation ON = a plain OFF day** (vacation) — treated as off.

---

## Trades tab — "Find Trades" (merge)

Roll the old **Intents feed** + **Trade Solutions** into one surface (they're the same engine,
differing only by input). Default mode **Search a date range**; **From my marked days** is a
toggle. This is the home for the complex engine output (**multi-person loops / N-way /
qual-swap bridges**) that AUTO's pairwise flow doesn't cover.

---

## Residual micro-decisions (need a call before/at build)

1. **AUTO "3-mutual (giver)"** implies proposing a return day the peer is *working but did NOT
   mark Want-to-Trade* (¬M3). That means AUTO would ask someone to give up a day they never
   offered. Options: **(a)** restrict AUTO to offered days only → the practical AUTO tiers are
   4-mutual, 3-taker, 2/ECB (recommended, least aggressive); **(b)** allow AUTO to request
   unmarked return days → enables true 3-giver but auto-asks for un-offered shifts.
2. **AUTO scope** = pairwise (one giver ↔ one taker, ≤3 bidders). **Multi-person loops / N-way**
   stay in *Find Trades*, not AUTO. (Recommended — keeps AUTO simple and auto-sendable.)
3. **Taker side when giver's toggle is off:** the giver sees SEND. On the taker's side the same
   mutual match shows as "matched — waiting on <giver>," with an optional **Send pickup** so it
   never dead-ends if the giver never sends. (Recommended default; dedup covers the rare double.)
