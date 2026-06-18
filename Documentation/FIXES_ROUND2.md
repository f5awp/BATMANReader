# Device-Test Fixes — Round 2 (2026-06-17)

> Scope + 5-Whys + fail-tests (🔴 red now / 🟡 partial / 🟢 after fix) + safeguards + assumptions for the
> issues found on-device. Several screenshots share **one root cause** (R-A below) — fixing it clears
> the most. Build discipline unchanged: fail-test-first, runtime safeguards, harness + build green.

---

## ROOT CAUSES (shared)

### R-A — Matching only sees PUBLISHED profiles, not the 500+ roster  ⭐ biggest
**Symptoms:** Just 2 shows ~3 dispatchers (img 36/37), "No Intent Matches" with 12 intents (img 27),
"can't tell if intents upload" (img 29).
**Cause:** `TradeRouter.packages` / `twoWayExplore` iterate `TradeProfileStore.others` (only dispatchers
who have *published a TradeProfile*). In a real roster only a handful have opted in, so everyone else is
invisible — even though all 500+ are in `RosterStore`.
**5 Whys:** (1) Few dispatchers show → (2) we loop `others` (published profiles) → (3) profiles are the
"willingness" layer and we treated them as the candidate UNIVERSE → (4) early design assumed everyone
opts in before matching → (5) no test asserted "a roster dispatcher with NO profile still appears as an
(unknown-willingness) candidate." **→ the universe must be the ROSTER; profiles layer on top.**
**Fix:** candidate universe = roster workers (`RosterStore`), each using their published profile if present
else a **default-open `.unknown`** profile; rank unknown below willing (the `TradeWillingness` ladder
already exists). `candidatesForTrades` already does this for ECB — apply the same to `packages`/two-way.
**Fail-test 🔴→🟢:** pure `MatchUniverse.candidates(roster:profiles:)` → a roster worker with no profile is
included as `.unknown`; with a `.declined` profile excluded (unless What-If). **Safeguard:** universe count
test = distinct roster workers (minus self), not `others.count`. **Assumption:** unknown-willingness peers
ARE tradeable (matches the existing `.unknown` ladder); confirm.

### R-B — Status + intents not visible cross-device
**Symptoms:** "statuses still not there" (your note, img 36 shows your OWN status only); "can't tell if
their intents are uploading" (img 29).
**5 Whys:** (1) Peer status/intents blank → (2) the view reads `TradeProfileStore.others` → (3) `others`
is only refreshed in some screens / may be empty → (4) publish-on-change isn't firing for every edit, or
fetch isn't running where the status is shown → (5) no test/telemetry confirms "publish wrote → peer
fetch read it back." **Fix:** ensure `publishMine()` fires on every intent/status change (single funnel),
call `refreshOthers()` on the Trades/Home appearance, and render peer `statusBroadcast` + intent bars on
the two-way calendars. **Fail-test:** pure round-trip — a profile encoded→decoded preserves
`statusBroadcast`/`seekingDayIDs`/`wantToWorkDayIDs`; **device:** 2-account status/intent visibility.
**Safeguard:** a single `publishMine()` call site (no scattered partial writes). **Assumption:** CloudKit
profile schema is deployed (it's JSON-payload, no deploy) — so this is a fetch/publish-timing bug, not schema.

---

## PER-IMAGE ISSUES

### 1 — img 25: Want-to-Work offered on days with NO legal shift → needs auto-X
**Symptom:** Jul 11 & 23 are paintable Want-to-Work though no shift start (0500/1300/2100) is legally
coverable there (8h-rest etc.). Should show a red ⊘.
**5 Whys:** (1) WTW allowed on an impossible day → (2) the brush doesn't check feasibility → (3) feasibility
(off + a rest-legal start exists) is computed only at match time, not at paint time → (4) the calendar
paints from intent state, not from `AvailabilityManager.eligibleTypes` → (5) no test "a day with zero
eligible types cannot be marked Want-to-Work." **Fix:** per off-day, compute eligible shift types
(`AvailabilityManager.eligibleTypes(forOffDay:workedShifts:)`); if empty → render a red ⊘ + block WTW.
**Fail-test 🔴:** `eligibleTypes` empty for a no-rest-legal day → `canMarkWantToWork == false`. **Safeguard:**
the paint gate and the matcher both call the same `eligibleTypes`. **Assumption:** "no legal shift" = no
eligible AM/PM/MID after 8h-rest vs adjacent worked days.

### 2 — img 26: mystery 3rd visibility layer + icons on Aug 10 / Aug 31 (unrequested)
**Symptom:** a 3rd layer-toggle (top-right) + odd badges on specific days I never asked for.
**5 Whys:** (1) Unrequested UI → (2) a 3rd `LayerVisibility` case + per-day glyph was added → (3) likely
the "others' intents" (A1) + availability-pill layers stacked → (4) added speculatively during A1/F1
without a spec line → (5) no ASSUMED_PRESENT entry flagged "added a layer the user didn't request." **Fix:**
identify the 3rd toggle + the Aug-10/31 glyphs (likely others-interest badge + availability pill), confirm
with you, then remove or relabel. **Safeguard:** every calendar layer maps to a named spec item.
**Assumption:** you want only the layers you explicitly asked for — I'll enumerate them for your sign-off.

### 3 — img 27: "Intents 12" but "No Intent Matches"; wrong tally categories; circle the count
**Symptom:** 12 intents → no matches (see R-A). Tally shows Want-to-work/Must-be-off; should be the two
MATCHING factors: **Want-to-Work (off day)** + **Want-to-Trade-away (working day)**. "12" needs a circle so
it's clearly a count (vs "Just 2").
**5 Whys (no matches):** = R-A. **5 Whys (tally):** (1) wrong categories → (2) tally lists all 4 intent
enums → (3) it was built as a raw intent counter (D2a) not as "matching factors" → (4) the matching-factor
concept (give-away + want-to-work) wasn't separated from display intents → (5) no test "tally categories ==
the matcher's input factors." **Fix:** tally = Want-to-Trade-away (seeking, working) + Want-to-Work (off);
wrap the segment count in a `Circle`/Capsule badge. **Algorithm definition (below).** **Fail-test:** tally
factors == `[.tradeAway, .wantToWork]`; count badge present.

### 4 — img 28/37/38: "CIRCULAR" tag on a 2-person swap (must be ≥3)
**5 Whys:** (1) 2-person tagged circular → (2) the card reads `package.route != nil` OR methodology to show
"circular" → (3) a 2-participant package was built with `methodology: .circular` / a route → (4) the
qual-swap / route path set the tag without a participant-count guard → (5) no test "peopleCount == 2 ⇒ never
labeled circular." **Fix:** label = circular ONLY when `peopleCount >= 3`; 2-person = "2-Person Swap" with no
CIRCULAR tag. **Fail-test 🔴:** `packageKindLabel(peopleCount:2, isCircular:true) != "circular"`. **Safeguard:**
`TradePackage.isCircular { route != nil && peopleCount >= 3 }`.

### 4b — img 28: global sort tiebreak = earliest trade date
**Symptom:** with all else equal (N, 🔥, bookends), the swap with the **earliest offered date** should sort
first (Dmitry Oct 15 before Denny Dec 21).
**Fix:** add a final `rankPackages` tiebreak: earliest min-date across the package's days, ascending.
**Fail-test 🔴→🟢:** two equal packages, earlier-date one sorts first. **Safeguard:** pure, in `rankPackages`.

### 5 — img 29: peer intents not shown; a non-bookend (Jun 18) labeled bookend; add intent key
**5 Whys (bookend):** (1) Jun 18 not a bookend but shown as one → (2) `bookend` computed for the wrong
person/side, or the two-way leg's `bookend` flag is for the receiver not the giver → (3) when I GIVE Jun 18
to him, the bookend that matters is whether it anchors to HIS work — computed against the wrong map → (4)
the iGive bookend uses the peer's map but the display reads my side → (5) no test "giving an isolated day is
NOT a bookend for the receiver." **Fix:** ensure the displayed bookend = receiver-side anchored (already the
rule — verify the wiring). **Intent key:** add intent-color legend (Trade-away / Want-to-Work / Keep /
Must-Be-Off bars) to the two-way sheet key + ECB. **Fail-test:** isolated give-day → `bookend == false`.

### 6 — img 30: ECB names 1-col; bookends dispersed; need 2 broadcast buttons
**Fix:** 2-column dispatcher grid on regular width (1-col compact); sort the ECB candidate list by bookend
(bookend-first); replace the single "Request all" with **"Broadcast to bookends"** + **"Broadcast to all"**.
**5 Whys (sort):** (1) bookends dispersed → (2) ECB list sorts by want-to-work then name, not bookend → (3)
ECB sort never included the bookend key → (4) bookend wasn't surfaced per-candidate in ECB → (5) no test
"ECB candidates sort bookend-first." **Fail-test:** ECB sort puts a bookend candidate above a non-bookend.

### 7 — img 31: redundant card text; MOVE email button to Trade Solutions/ECB top
**Fix:** remove "2-Person Swap — your part is highlighted" line. Remove the per-thread "Email to dispatch DL"
button; put an **email button at the TOP of Trade Solutions + ECB**: user selects dates → prefilled Outlook
draft to the DL **with Must-Be-Off blackout days**. **ECB email** = states the ECB count, **no blackout days.**
**5 Whys (placement):** (1) email buried in a thread → (2) built where a single trade lives → (3) spec said
"send a trade" so I attached it to a request → (4) the date-driven bulk flow wasn't the model → (5) no test
on where the action lives. **Fail-test:** `TradeEmail.body` (ECB variant) has the ECB count + NO blackout line.

### 8 — img 32 (channel): unlimited reactions; premium reply box; photo in replies; DATA WIPED
**8a Reactions:** must be **1 per user per post/reply** — picking a new emoji REPLACES the old.
**5 Whys:** (1) unlimited → (2) `Reaction.toggle` only toggles the SAME emoji, doesn't replace a different
one → (3) toggle was specced as add/remove-this-emoji, not single-choice-per-user → (4) "one reaction per
user" wasn't a stated rule → (5) no test "a user's 2nd distinct emoji replaces their 1st." **Fix:** add
`Reaction.setSingle(...)`; **fail-test 🔴:** user picks 👍 then ❤️ → exactly one reaction (❤️).
**8b Reply box:** premium TextField + send **icon** (not "Send" text) + photo attach (extend `imageBase64`
to `BroadcastReply`). **8c DATA WIPED ⭐:** all posts/replies/trades/feedback gone this build.
**5 Whys (wipe):** (1) data gone → (2) likely a CloudKit record-type/schema mismatch OR a local-store
migration wipe from the new optional fields → (3) added fields (reactions/imageBase64/perfectMatch/...)
changed decoding; a non-optional/old record may fail to decode → (4) or the messaging store key/container
changed → (5) no migration test "old records still decode after adding fields." **Fix:** audit decode
back-compat (all new fields optional+defaulted — verify), confirm the CloudKit record types/containers
unchanged, and check no `clear()`/migration ran. **Fail-test:** decode a v1 BroadcastPost/Reply/Response
JSON (no new fields) → succeeds.

### 9 — img 32 (metrics): "0% trades cleared" — wanted TOTALS, not a %
**Fix:** Home header shows **total successful trades** (not %), with a **month/year/all** filter; show TWO
totals — **You** and **Company (whole app)** — that switch together as the period filter changes.
**5 Whys:** (1) shows % → (2) `Metrics.successPercent` drives the header → (3) I built success-rate, not a
running total → (4) "metrics" was read as a rate not a count → (5) no spec test on the metric shape. **Fix:**
`Metrics.totalCleared(events:period:scope:)` (you vs company); header = two totals + one period control.
**Fail-test 🔴→🟢:** total counts (not %) for you vs company per period.
**9b — "successful" definition (your note):** the "4" counts trades that are merely *completed/proposed*,
but a trade is only **successful once ACCEPTED *and* ARCHIVED** (the full lifecycle). The metric currently
logs/counts the wrong event.
**5 Whys:** (1) count too high → (2) we count completed/recorded trades → (3) the `MetricEvent(.trade)` /
`completedCount` fires at record time, not at accept+archive → (4) "successful" wasn't pinned to the
accept→archive terminal state → (5) no test "a proposed-but-unaccepted (or accepted-but-unarchived) trade
is NOT counted." **Fix:** only count toward success when status == accepted AND the request is archived;
move the `MetricEvent(.trade)` hook to the archive-after-accept step. **Fail-test 🔴:** a completed-not-archived
trade → success total unchanged; accept + archive → +1. **Safeguard:** single pure `isSuccessful(request,
status, archived)` predicate driving both the local count and the `MetricEvent`.

### 10 — img 33/34/35: mass-action lag; per-day overwrite prompt; button clarity; layout; labels
**10a Lag/freeze** between day selections in mass-action mode.
**5 Whys:** (1) lag → (2) each tap re-runs heavy work (publish/recompute/animation) synchronously → (3)
painting a day triggers `publishMine()` + a full match-signature recompute per tap → (4) no debounce/batch
→ (5) no perf guard. **Fix:** batch paint; debounce publish/recompute to end-of-gesture.
**10b Overwrite prompt per day** (img 34/35) → ask **once** on the first day after choosing a mass-action
tab, then overwrite silently. **Fail-test:** the confirm fires once per tab-session, not per day.
**10c Buttons:** larger + clearly-selected mass-action chips; AM/PM/MID on the **same line** as the 3 brushes;
rename **"Pick up" → "Shift Availability"**.
**10d Fonts (img 35):** baseline ≥ the "2-Person Swap" header size; scale up the rest; use horizontal space.
**10e Card colors (img 35):** date chips use each person's calendar color (not all blue) — already done in
the detail (img 38) but not the summary card. **10f "Execute trade" → "Propose Trade"** everywhere.

### 11 — img 36: Just 2 / matching shows only ~3 dispatchers = **R-A** (see above).

---

## Intents matching algorithm — definition (img 27 ask)
The matcher layers, in order:
1. **Universe:** all roster dispatchers (R-A), minus self.
2. **Physical (hard):** off + qualified + 8h-rest + (cap, keep, must-be-off) — `TradeEligibility.canCover`.
3. **Willingness:** their published profile (`wouldPickUp`); no profile = `.unknown` (kept, ranked below willing).
4. **Matching FACTORS (what "intent match" means):** my **Want-to-Trade-away** (a working day I marked to
   give) ∩ their ability/willingness to take it, AND their **Want-to-Trade-away** ∩ my willingness — plus
   **Want-to-Work** off days as pickup intent. 🔥 = wanted on BOTH sides.
5. **Rank:** fewest people → 🔥+bookends → 🔥 → bookends (top-two-band cap) → **earliest date** (new) → name.

---

## Build order (proposed, highest-leverage first)
1. **R-A** universe = roster (clears img 27/36/37 "few dispatchers / no matches") — pure `MatchUniverse` + wire.
2. **8c data-wipe** decode/back-compat audit (data loss is P0).
3. **R-B** status/intents publish+fetch+display.
4. **#4** circular-tag guard + **#4b** earliest-date sort.
5. **#3** tally factors + count badge; **#1** WTW auto-X.
6. **#9** metrics totals; **#10** mass-action UX; **#5** bookend display + key.
7. **#6** ECB 2-col/sort/buttons; **#7** email relocation; **#8a/b** reactions+reply box; **#2** mystery layer.
8. **#10d/e/f** fonts/colors/"Propose Trade".
</content>
