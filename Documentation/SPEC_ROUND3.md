# SPEC — Round 3 (on-demand search, qual-swap redesign, save-flow, unified calendar, UI)

> Planning artifact. Nothing here is built yet. Each item: **Scope · Approach · Fail-tests
> (🔴→🟢, live in `Sources/Support/EngineTests.swift`) · Safeguards · Assumptions**; bugs add **5-Whys**.
> Feasibility verdicts (skeptic/essentialist) are inline. Build order is at the bottom.

Legend: ✅ recommended · ⚠️ feasible-with-caveats · ❌ advise against.

---

## PART A — On-demand, parameterized search ("I'm Feeling Lucky" + Master Filter)

**The reframe driving all of A:** today `TradeRouter.packages()` runs **eagerly** on tab-appear
*and* on every `MatchInputsSignature.current` change (`TradeIntentsFeed.swift:74,78,98`), and it
fuses 2-way + n-way circular + qual-swap into one pass. The fix is to **split cheap from
expensive** and run the expensive engines **only on explicit action, at a user-chosen shape.**

### A1 — "I'm Feeling Lucky" runs the heavy search behind a button (best-first, cap 100, cancellable)
**Scope:** On Trade Solutions and Intents, the default load computes only the cheap pass
(1-way + 2-way reciprocal). A primary **"I'm Feeling Lucky"** button runs the heavy engines
(n-way DFS, incl. qual-swap — see A6) with a **"Running the numbers… this may take a moment"**
modal that has a **Cancel**.
**Approach:**
- New `TradeRouter.luckySearch(filter:) async -> [TradePackage]` — a *separate* entry point from
  the cheap default. Honors `Task.isCancelled` checks inside `extend` and between seeds so Cancel
  is immediate.
- **Best-first seeding:** the seed loop (`TradeRouter.swift:538`) and the per-node peer loop
  (line 525/542) currently iterate `maps.sorted(by: key)` (alphabetical). Replace the ordering key
  with a **desirability score** descending: seed givers ordered by (my-intent strength, urgency,
  bookend potential); candidate coverers ordered by (their want-to-work on this day = 🔥, bookend,
  fewest downstream conflicts). This makes the route cap keep the *best* routes, not alphabetical.
- **Cap 100:** raise the n-way `routes.count > 60` brake to a parameter `maxRoutes` (default 100 for
  Lucky). Because seeding is best-first, the 100 kept are the 100 best-found.
- **Cancellable:** wrap in a `Task` stored on the view; Cancel calls `task.cancel()`; `extend`
  early-returns on `Task.isCancelled`.
**Fail-tests (pure, deterministic):**
1. 🔴 `bestFirstOrder` — given givers with known intent/urgency scores, the seed order returned is
   strictly descending by score (ties broken by stable id). Asserts seeding is best-first, not alpha.
2. 🔴 `luckyCapKeepsBest` — feed a synthetic dense graph where the 100 *best* routes are known;
   assert the capped result == the known-best set (not the first-100-by-id).
3. 🔴 `cancellationStops` — inject a cancel flag after N expansions; assert `extend` returns and
   route count is bounded by N (proves the cancel check is on the hot path).
**Safeguards:** the ordering score is **one pure function** `routeSeedScore(...)` reused by seed loop
+ peer loop + ranking (single source of truth — divergent orderings were the alphabetical-cap bug).
The `maxRoutes` cap is never silently exceeded; `log`/return surfaces "showing best 100 of N found".
**Assumptions:** "best" = the existing rank signal (fewest-people → 🔥 → bookends → earliest date).
Cancel discards partial results (no half-rendered route list).
**Feasibility:** ✅ — pure parameterization of an already-capped engine; deterministic; fully testable.

### A2 — Master Filter (the search shape popup)
**Scope:** Before "Lucky" runs, a popup lets the user shape the search; choices stay **visible** as
chips on the results header. Controls:
- **Engine:** `Min-Cost` · `N-Way` · `Both`.
- **Max participants:** `1` · `2` · `3` · `4`.
- **If `Both`:** N-Way is limited to the **60 Best** (shown as a caption: *"With Both, N-Way returns
  the 60 best to keep results fast"*).
- **Force-include a person:** a dropdown of **all dispatchers**; when set, only solutions that
  *contain that person* are returned, up to the chosen max-participants.
**Approach:**
- `struct SearchFilter { engine: {minCost, nWay, both}; maxPeople: 1...4; requiredWorkerID: String? }`
  — a value type threaded into `luckySearch(filter:)`.
- `maxPeople` maps to `OptimalMatcher.maxPeers`-side caps and `nWayRoutes(maxDepth:)`
  (depth = maxPeople). `engine` selects which sub-searches run. `both` forces n-way `maxRoutes = 60`.
- **Force-include person:** two-layer — (1) **seed/route filter:** keep only routes whose
  `participants.contains(requiredWorkerID)`; (2) **optimization:** for min-cost, restrict the peer
  set to subsets that include the required worker. Cheaper + more targeted: the required person's
  per-day availability *seeds* the search.
**Fail-tests:**
1. 🔴 `filterEngineSelect` — `engine == .minCost` → zero n-way routes returned; `.nWay` → zero
   min-cost packages; `.both` → both present and n-way count ≤ 60.
2. 🔴 `filterMaxPeople` — `maxPeople == 2` → no package/route has `peopleCount > 2`; `== 4` → routes
   up to 4 appear.
3. 🔴 `filterRequiredPerson` — with `requiredWorkerID = X`, **every** returned solution contains X;
   solutions without X are absent even if otherwise optimal.
4. 🔴 `filterBothCapsNWayTo60` — `engine == .both` → n-way routes ≤ 60 regardless of `maxRoutes`.
**Safeguards:** `SearchFilter` is `Equatable` + has a `CaseIterable` universe test so a new engine/
participant option can't be silently unhandled. The required-person filter is a **post-filter AND a
seed constraint** (defense in depth — if the seed constraint is bypassed, the post-filter still
guarantees correctness).
**Assumptions:** dropdown lists every roster dispatcher (not just published profiles). Max-people 1 =
ECB-style one-way (no swap-back). Filter chips persist until changed.
**Feasibility (6-sigma):** ✅ — yes. Every control is a parameter on already-bounded, deterministic
engines; the required-person constraint is expressible as a pure predicate over `participants`. The
4 fail-tests above + the `CaseIterable` universe guard give the 6-σ coverage. The only real risk is
**combinatorial UI state** (engine × people × person), mitigated by making `SearchFilter` one value
type with one validation function.

### A3 — Remove the "intent-only vs all-eligible" toggle
**Scope:** Drop that option from the Lucky popup (A2). Lucky always searches **all-eligible** and
uses intent only as the best-first *ranking* signal (A1), not as a hard gate.
**Approach:** delete the toggle; `luckySearch` never filters the universe by intent.
**Fail-test:** 🔴 `luckyUsesAllEligible` — an eligible peer with **no** want-to-work intent still
appears in Lucky results (ranked below intented peers), proving intent isn't a gate.
**Safeguard:** the ranking function treats intent as a *score bump*, never a filter (asserted).
**Assumption:** users prefer "more options, best on top" over "only the eager ones."
**Feasibility:** ✅ trivial (removes a branch).

### A6 — Qual-swap participates in n-way (no early qual gate)
**Scope:** Lucky's n-way no longer pre-filters unqualified takers out; qual-swap bridges are
discoverable *within* the route search, since Lucky is now an explicit, can-take-its-time action.
**Approach:** inside `extend`, when a give-leg is qual-blocked for the chosen taker, allow a
**bridge expansion** (insert a qualified middle-person C who swaps desks) instead of pruning the
branch. This makes qual-swap a *leg type* in the route, not a separate package.
**Fail-tests:**
1. 🔴 `nWayFindsQualBridge` — a scenario solvable only via a desk-qual bridge yields a route whose
   legs include the bridge swap; without the bridge expansion it returns empty.
2. 🔴 `nWayQualLegLegal` — every emitted bridge leg leaves *all* parties on a desk they're qualified
   for (no illegal placements).
**Safeguard:** bridge legality reuses `TradeMatcher.qualified` + `acceptsQualSwap` (single source);
a route with any unqualified placement is rejected by an assert in route assembly.
**Assumptions:** bridge expansion only triggers on qual-blocked legs (keeps the common path cheap).
This is **Lucky-only** — the cheap default pass still skips it.
**Feasibility:** ⚠️ — feasible but the **highest-complexity item**. Adding a bridge dimension to the
DFS raises worst-case branching; it's safe *because* it's behind Lucky + the `maxRoutes`/`maxDepth`
caps + cancel. Recommend building A1–A3 first, then A6 as its own milestone with its own tests.

### A8 — No published profile defaults to **Bookends Only** (global)
**Scope:** Anywhere the matcher fabricates a default profile for a peer who hasn't published one,
the default openness becomes **`.bookends`** (was `.all`). A profileless peer is therefore only
offered **bookend** (non-splitting) pickups — they're never asked to fragment their time off until
they opt into broader trading.
**Approach:** change the default-open fallbacks to `.bookends`: `TradeRouter` `openProfile(...)`, the
`TwoWaySheet.load()` fallback (`AvailabilityView.swift:1217` openness `.all` → `.bookends`),
`MatchUniverse` unknown-profile peers, and any `TradeProfile(... openness: "all")` placeholder used
for *missing* (not explicitly-set-open) peers. **One** helper `TradeProfile.defaultForUnpublished(
workerID:name:)` so every site agrees.
**Why this matters (ties to G3):** it's a *cleaner* partial fix for the split-the-weekend trades —
a no-profile receiver now **rejects** non-bookend pickups at `canCover`, so those routes are never
generated, not merely penalized after the fact.
**Fail-tests:**
1. 🔴 `unpublishedDefaultsBookends` — `defaultForUnpublished(...).openness == .bookends`.
2. 🔴 `noProfileRejectsSplit` — a profileless receiver does **not** pass `canCover` for a
   non-bookend (mid-off-stretch) pickup, but **does** for a bookend pickup.
3. 🔴 `explicitOpenStillOpen` — a peer who *published* `.all` is unaffected (only *missing* profiles
   default to bookends).
**Safeguards:** one `defaultForUnpublished` factory (no scattered `openness: "all"` literals for
missing peers — a grep-guard/test asserts the fallback sites use the factory). Distinguish **missing**
profile (→ bookends) from **explicitly published open** (→ all) so we never override a real choice.
**Assumptions:** early-adoption tradeoff accepted — until people publish profiles, profileless peers
yield *fewer* (bookend-only) offers; this is intended (conservative-by-default). Mercenary/“not
accepting” unaffected.
**Feasibility:** ✅ — a one-line default change centralized behind a factory; high impact on G3.

---

## PART B — Qual-Swap redesign (international-desk aware) + package merge

### B1 — International-desk detection → glowing "Qual Swap" action
**Scope:** When the user's selected give-shifts include an **international desk** (qual-gated),
a normally-gray **"Qual Swap"** button turns **glowing green** and becomes tappable. Tapping opens a
**per-day paged sheet** (swipe between days); each day lists its potential qual-swap matches. Per day
the user can select match(es) to broadcast, or **Broadcast All**. The broadcast card/request states:
*"Looking to trade for {that day} — may require a qual swap."* Qual-swap is **removed from the
inline trade-package** card (it becomes its own flow).
**Approach:**
- `DeskRules.isInternational(desk:)` (or `requiredQual != nil` on the international set) → derive
  `hasQualGatedSelection(shifts:) -> Bool` (pure) to drive button enable + glow.
- Reuse `TradeMatcher.qualSwapBridges(giveDayID:…)` (already indexed by `dispatchersWorking(on:)`)
  per selected day → `[day: [QualSwapCandidate]]`.
- New paged sheet `QualSwapDaysSheet` (TabView `.page` style); per-day multi-select + Broadcast/All.
- **DO NOT delete** the auto qual-swap package builder in `TradeRouter.packages()` (lines 336–362) —
  per the Just-2 clarification it **stays a function** (no initial qual gate; auto-creates a
  bridge-in-the-middle package whenever a give-day is qual-blocked). The international-desk button is
  an **additional, deliberate broadcast flow** layered on top — *not* a replacement. (Earlier
  "remove from package" is **superseded**: the inline auto-package remains; the button is the power UX.)
**Fail-tests:**
1. 🔴 `qualButtonEnable` — `hasQualGatedSelection` true iff ≥1 selected shift is on a qual-gated desk.
2. 🔴 `qualPerDayGrouping` — bridges are grouped by day; a day with no bridge yields an empty page,
   not a crash.
3. 🔴 `qualBroadcastCopy` — the request body for a day contains that day + the "may require a qual
   swap" clause and **no other day's** info (per-match relevance).
**Safeguards:** button enable is a pure function (testable, can't drift from the glow state). Removing
inline qual packages is covered by updating the existing `#7/Q-series` tests so a regression (qual
package reappearing in `packages()`) fails.
**Assumptions:** "international desk" = the qual-gated desks in `DeskRules.requiredQual`. One sheet
page per selected give-day that has ≥1 bridge.
**Feasibility:** ✅ — all the matching primitives exist; this is mostly a new sheet + moving where
qual packages are built.

### B2 — Merge two accepted packages/requests into one ("is this possible?")
**Verdict: ✅ Yes, possible.** A qual-swap is structurally a normal trade **+ a middle-man leg on the
same day/desk**. So a merge is: take an accepted **base 2-way request** (A↔B for day D) and an
accepted **qual-swap bridge** (C frees the qual on day D) and compose them into **one** combined
request whose legs are the union, sharing day D.
**Scope:** When a qual-swap bridge has *already accepted*, offer **"Merge with base trade"** to fuse
the bridge request + the base request into a single `MergedRequest` (one card, one lifecycle).
**Approach:**
- `struct MergedTradeRequest` (or extend `TradeRequest` with `mergedLegs: [TradeLeg]` + `mergedFrom:
  [String]`) composing the base legs + the bridge leg, keyed on the shared `dayID`+`desk`.
- Pure `TradeMerge.canMerge(base:bridge:) -> Bool` — true iff they share the give-day/desk and the
  bridge's freed qual matches the base's blocked qual and no participant collides illegally.
- Pure `TradeMerge.merge(base:bridge:) -> MergedTradeRequest`.
**Fail-tests:**
1. 🔴 `mergeEligibility` — `canMerge` true for a matching base+bridge on day D; false when days/desks/
   quals don't line up.
2. 🔴 `mergeComposesLegs` — merged legs == base legs ∪ bridge leg, deduped; participant set is the
   union; everyone ends qualified.
3. 🔴 `mergeIdempotent` — merging twice / merging an already-merged request is a no-op (no leg dupes).
**Safeguards:** `canMerge` gates `merge` (never merge incompatible); merged request re-runs the same
legality asserts as a fresh request (no illegal placement can survive a merge).
**Assumptions:** only **accepted** bridges are mergeable. Merge is user-initiated, not automatic.
**Feasibility:** ✅ with caveat — the *data composition* is straightforward and pure-testable. The
*messaging lifecycle* (two CloudKit requests → one) needs care: define the merged request as a **new
record** that supersedes the two, with the originals archived, to avoid split-brain accept states.

---

## PART C — Save-flow change (intents are staged, committed on SAVE)

### C1 — Mark-Intents becomes a staged buffer with an explicit SAVE
**Scope:** Mass-action selections + per-day edits go into a **pending buffer**, not straight to the
store. The sheet's **Done** becomes a **high-contrast SAVE** button. A caution line: *"Unsaved —
press SAVE or your changes will be lost."* Navigating away (to Trades/Inbox/etc.) with unsaved
changes prompts **Save now / Discard**. **Every SAVE → recompute** (replaces the per-change
auto-recompute). Auto-recompute also fires on **Home→Trades** transition **only if** schedule or
intents changed since last compute.
**Approach (skeptic-tuned — see verdict):**
- `DayIntentStore` gains a **staging layer**: `stagedOff/stagedWorking` dictionaries + `hasUnsaved:
  Bool`. Paint writes to staging; `commit()` flushes staging → real intents + bumps a
  `intentsRevision` counter; `discard()` clears staging.
- `MatchInputsSignature.current` is replaced as the recompute trigger by an explicit
  **`intentsRevision`** (only `commit()` bumps it). Trade Solutions recomputes when
  `intentsRevision != lastComputedRevision` **on appear** (Home→Trades), not on every keystroke.
- Navigation guard: a `hasUnsaved` flag drives a confirmation on tab-switch.
**Fail-tests:**
1. 🔴 `stagingIsolation` — painting into staging does **not** change `seekingDayIDs`/`offIntent`
   until `commit()`; `discard()` leaves the store untouched.
2. 🔴 `commitBumpsRevision` — `commit()` increments `intentsRevision`; `discard()` does not.
3. 🔴 `recomputeOnlyOnChange` — Home→Trades with `intentsRevision == lastComputed` does **not**
   recompute; with a newer revision, it does.
4. 🔴 `unsavedFlagAccuracy` — `hasUnsaved` true after any staged edit, false after commit/discard.
**Safeguards:** staging + commit is **one path** (no scattered direct writes that bypass staging — a
test asserts the public paint API only touches staging). The recompute trigger is a single
`intentsRevision` integer (no signature drift).
**Assumptions:** SAVE persists locally *and* publishes the profile (single funnel — ties into R-B).
Discard reverts to last committed state. Schedule re-import counts as a "change" for the Home→Trades
recompute.
**Feasibility / consult (heavy vs current?):** ⚠️ **Moderately heavy but worth it**, with one
trim. The staging buffer + SAVE + revision-gated recompute is the *efficient* core and directly
fixes the "recompute on every toggle" waste — **do it.** The **per-tab navigation-guard popup is the
heavy/annoying part**; skeptic recommendation: keep a lightweight **unsaved badge + a one-time
confirm only when leaving the Home tab with unsaved edits**, rather than intercepting *every* tab.
Intercepting all navigation is brittle (SwiftUI tab changes aren't trivially cancellable) and
nags users. **Recommended: staged-commit + Home-exit confirm only.** This is *more* efficient than
the current per-change recompute, not less.

---

## PART D — Unified trade calendar + Just-2 fixes

### D1 — One calendar component for all trade surfaces ("can we merge them?")
**Verdict: ✅ Yes — and it collapses D2/D3/D4/D6 into one fix.** Today ECB, Trade Solutions, and
Just-2 each render their own calendar; that's why selection-date display works in two and not the
third, and why labels diverge. Build **one** `TradeCalendar` view parameterized by
`role` (who am I in this trade), `colorScheme(perWorker)`, `selection binding`, and a
`legend` — execution (propose vs ECB vs lookup) differs at the call site, the calendar does not.
**Approach:** extract the best existing calendar (the two-way dual-calendar) into a reusable
`TradeCalendar` taking `(days, selection, perWorkerColors, showDateChips, legend)`. ECB / Trade
Solutions / Just-2 all render it; only their action buttons differ.
**Fail-tests:** mostly snapshot/behavioral, but pure pieces:
1. 🔴 `selectedDayChips` — given a selection set, the chip model lists exactly those ISO days with
   formatted dates (drives D3: dates show on *every* surface).
2. 🔴 `perWorkerColorAssignment` — `colorFor(workerID)` is stable per worker and ≠ blue/red default
   (drives the F-series color fix).
**Safeguards:** one component = one place for date-chip + color + legend logic (kills the per-surface
drift that caused D2/D3/D4).
**Assumptions:** the dual-calendar is the canonical base. Per-surface behavior is injected, not forked.
**Feasibility:** ✅ recommended — this is the **highest-leverage UI item**; it makes D2/D3/D4/D6/F1
one fix instead of five.

### D2 — Just-2 candidate model (your question) + dropdown of ALL dispatchers
**Answer to "how does Just-2 work":** Just-2 (`JustTwoSection`) gathers via
`TradeMatcher.candidatesForTrades` = **all physically-eligible** coverers (off+qual+rest), **not**
intent-only; want-to-work is only a **sort annotation** (`wantsToWork`, sorts 🔥 to top). It **does**
carry qual-swap (`pkg.qualSwap` path). So Just-2 = "anyone who *can*," ranked by "who *wants*."
**Scope:** Just-2 has **two modes sharing one engine**, hard-capped to **exactly 2 distinct people**
(you + one other; may yield *many* such 2-person trades, never 3+):
- **Default (no person selected):** the 2-person package feed, **ranked** by the acceptance score
  (G3). The min-score threshold *may* thin this list like other feeds.
- **Person selected (dropdown of every dispatcher):** pick anyone in the office → show **their
  calendar + every package that exists with them**, score shown as an *annotation only*. The
  threshold must **NEVER hide** an explicitly-selected person (an explicit lookup is immune to the
  filter — "hide" = removed-from-list; selection overrides it).
(a) **Move the match-filtering search bar OUT of Just-2 → into Trade Solutions** (filtering a
*populated match list* belongs there). (b) The Just-2 dropdown sources the **full roster**.
**Approach:** Trade Solutions gets the `searchText` filter over its package list. Just-2 gets a
`Picker`/searchable dropdown sourced from the **full roster** (`RosterStore` distinct workers), which
on selection runs the existing two-way explorer against that one person.
**Fail-tests:**
1. 🔴 `justTwoRosterDropdown` — the dropdown source == all distinct roster workers (not just match
   results); selecting one yields that person's two-way exploration.
2. 🔴 `tradeSolutionsSearchFilters` — search text filters the Trade Solutions package list by
   participant name.
3. 🔴 `justTwoTwoPeopleCap` — every Just-2 package has `peopleCount == 2` (never 3+).
4. 🔴 `justTwoSelectionImmuneToThreshold` — when a person is explicitly selected, their packages are
   shown even when the score < τ (explicit lookup is never hidden by the filter).
**Safeguards:** dropdown source is the roster query (indexed), asserted to be the full set.
**Assumptions:** "look up anyone" = full roster, even people with no current match.
**Feasibility:** ✅.

### D3 — Selected-day chips with dates on ALL trade calendars
Folded into **D1** — the unified calendar renders `selectedDayChips` everywhere (fixes Just-2 missing
dates). Fail-test = `selectedDayChips` (D1).

### D4 — Just-2 "Propose to All" label when only 1 person
**Scope:** Button reads "Propose to {Name}" (or "Propose") when the candidate count is 1; "Propose to
All" only when >1.
**Approach:** pure `proposeButtonTitle(count:, name:) -> String`.
**Fail-test:** 🔴 `proposeLabelSingular` — count 1 → "Propose to {Name}"; count ≥2 → "Propose to All".
**Safeguard:** single pure title function reused by every surface.
**Feasibility:** ✅ trivial.

### D5 — Just-2 includes qual-swap (it should; qual-swap ≠ N) — CONFIRMED + sort rule
**Confirmed against code:** Just-2 (`JustTwoSection.search`, line 469) calls
`TradeRouter.packages(forGiveShifts:)`, which has **NO initial qual gate** — for every give-day it
checks `isQualBlocked` and, when blocked, **auto-builds a qual-swap (bridge-in-the-middle) package**
via `QualSwap.solutions` (lines 336–362). Those packages are **exempt from the bookend cap**
(lines 404–405) so a qual-swap solution is never hidden. So all three of your points are already
true: *(a) no initial gate, (b) auto-creates bridge packages when needed, (c) it's a function.*
**Gap to fix:** the final sort (lines 412–421) does **not** explicitly demote qual-swap packages — a
bridge package can currently sort *above* a clean package if it has fewer people / more 🔥. Per your
ask, qual-swap packages must sort **underneath** otherwise-comparable non-qual packages.
**Scope:** (1) add a sort tiebreak: `needsQualSwap` (`qualSwap != nil`) ranks **after** clean
packages within the same people/tier band. (2) Keep the bridge **out of the "N" count** (a 2-way +
bridge is still "2-Person"/"Qual Swap", never "3-Person").
**Approach (corrected per clarification):** the comparator order is **peopleCount → `needsQualSwap`
→ tier → fire → bookend → earliest → urgency**. So within the **same N**, *all* non-qual packages
sort **above** *all* qual-swap packages **regardless of fire/bookend**; the usual priorities (more 🔥,
more bookends, earlier) apply **inside each group**. `needsQualSwap` sits **directly below
peopleCount** (N still dominates) and **above** fire/bookend. Reuse the B2 `tradeTypeLabel` rule so
the bridge doesn't bump `distinctParticipants`.
**Fail-tests (corrected):**
1. 🔴 `qualUnderCleanEvenWithMoreFire` — same N: a **clean** package with *fewer* 🔥/bookends vs a
   **qual-swap** package with *more* 🔥/bookends → the **clean one still sorts first** (proves
   `needsQualSwap` outranks fire/bookend within an N-band).
2. 🔴 `qualGroupKeepsUsualPriorities` — two qual-swap packages, same N → the one with more 🔥 (then
   bookends, then earlier date) sorts first (usual priorities preserved *inside* the qual group).
3. 🔴 `peopleCountDominatesQual` — a qual-swap **2-way** sorts **before** a clean **3-way** (N is the
   top key; `needsQualSwap` is subordinate to it).
4. 🔴 `justTwoQualNotCountedAsN` — a 2-way+bridge labels "Qual Swap"/"2-Person", never "3-Person".
5. 🔴 `noInitialQualGate` — a give-day with **zero** qualified off-takers still yields a (qual-swap)
   package, proving quals aren't pre-filtered out.
**Safeguard:** the `tradeTypeLabel` universe test already exists; extend it. The sort comparator stays
a single `rankPackages` (no per-surface re-sort).
**Feasibility:** ✅ — confirmation + one sort key + one label rule.

### D6 — Intent-color legend on the 2-calendar view
**Scope:** Add the `IntentColorKey` (already built in Round-2) to the dual-calendar / two-way view.
Folded into **D1** (legend is a calendar parameter).
**Fail-test:** covered by D1 + the existing `IntentColorKey` render.
**Feasibility:** ✅ trivial (component exists).

---

## PART E — Messaging + Settings UI

### E1 — Broadcast channel as a Reddit-style thread, top-to-bottom
**Scope:** Render the channel as nested thread cards (post → replies indented), ordered **oldest→
newest top-to-bottom** (currently reversed).
**Approach:** reverse the sort in the channel list; adopt the reply-nesting layout (replies indented
under their post). Pure piece: `threadOrder(posts:) -> [...]` ascending by `createdAt`.
**Fail-test:** 🔴 `threadOrderAscending` — posts/replies returned oldest-first; a reply sorts under
its parent post.
**Safeguard:** one ordering function (no per-view sort drift).
**Assumptions:** "reddit format" = post header + indented replies + reactions; not full infinite nesting
(1 level of reply, matching current `BroadcastReply`).
**Feasibility:** ✅.

### E2 — Statuses (with emoji) under/right of names in the channel
**Scope:** Show each author's `statusBroadcast` (incl. emoji) beneath/next to their name on posts &
replies.
**Approach:** the channel already can read peer profiles (`participantStatus`); render it in the
author row. Ties into R-B (peer status must be fetched — `refreshOthers`).
**Fail-test:** 🔴 `authorStatusRendered` — given a peer with a status, the row model includes it;
empty status → no status line (no empty bubble).
**Safeguard:** status pulled from the same `TradeProfileStore.others` single source.
**Assumptions:** status is the published `statusBroadcast` (≤140), emojis preserved.
**Feasibility:** ✅.

### E3 — Settings: separate blacklist / qual-swap-prefs / relief visually
**Scope:** Either a thick divider between blacklisted-regions and qual-swap-prefs **or** tint the
qual-swap-prefs section a distinct color; tint the relief-dispatcher box a different color.
**Approach:** pure SwiftUI section styling in `SettingsView` (section backgrounds / dividers). No
logic.
**Fail-test:** n/a (cosmetic) — verify by render; add a note to ASSUMED_PRESENT, not a harness test.
**Feasibility:** ✅ trivial.

---

## PART F — BUG: per-user trade colors regressed to blue/red

### F1 — Trades show blue/red instead of per-worker calendar themes
**Scope:** Across intents + trade solutions, trades render the old **blue (you) / red (them)** instead
of the per-worker `traderColor` themes built earlier.
**5-Whys (skeptic):**
1. *Why blue/red?* → the views are using the fixed `youColor`/`themColor` (blue/red) constants, not
   `colorFor(workerID)`.
2. *Why the fixed constants?* → the two-way/dual-calendar path predates the per-worker theming and
   was never switched to `traderColor`; the per-worker colors live only in `PackageCard`/`TraderChips`.
3. *Why didn't it propagate?* → color assignment is **duplicated** per surface (each calendar picks
   its own colors) instead of one shared `colorFor(workerID)` — so fixing one didn't fix the others.
4. *Why duplicated?* → no single calendar component (the exact gap **D1** closes); each surface forked
   its own rendering + color logic.
5. *Why no test caught it?* → there's no assertion that "a rendered trade leg's color == the worker's
   theme color, never the blue/red default." Color was treated as pure cosmetics, untested.
**Approach:** route ALL trade surfaces through D1's `perWorkerColorAssignment` (`colorFor(workerID)`
→ stable `traderColor`, you = your scheme). Delete the per-surface blue/red constants.
**Fail-tests:**
1. 🔴 `colorForStableAndThemed` — `colorFor(workerID)` returns a stable, distinct `traderColor` per
   worker and is **never** the raw blue/red default for a real participant.
2. 🔴 `noFixedTwoColorFallback` — for ≥3 distinct participants, ≥3 distinct colors are assigned
   (proves it's not the 2-color blue/red scheme).
**Safeguard:** **one** `colorFor` used by every surface (the D1 unification) + the test above so a
future fork can't silently regress to blue/red.
**Assumptions:** you always render in your own scheme; peers cycle `traderColor` by stable index.
**Feasibility:** ✅ — and it's *caused by* the missing D1 unification, so **D1 fixes F1 structurally.**

---

## PART G — Round-3b device findings (IMG_0041–0044)

### G1 — No way to delete a swap message in the thread (IMG_0041)
**Scope:** The swap/proposal thread has no delete affordance. Add the ability to delete (or withdraw)
your own swap proposal / message from the thread.
**Approach:** reuse the existing soft-delete on `TradeResponse`/messages (`editedAt`/deleted
tombstone) + add a delete action (swipe or overflow menu) on swap-proposal rows you authored.
**Fail-tests:** 🔴 `deleteOwnProposalOnly` — delete is offered only on rows you authored; deleting
sets the tombstone and removes it from the active list. 🔴 `deleteIdempotent` — deleting twice is a
no-op.
**Safeguards:** authorship check is a pure predicate; soft-delete (tombstone), never hard-destroy, so
the counterparty sees a `[Withdrawn]` marker.
**Assumptions:** you can withdraw your own proposal/message; you can't delete the counterparty's.
**Feasibility:** ✅ (reuses B4-chat soft-delete).

### G2 — Two-way calendar shows employee # not name; missing intent key; partial peer intents (IMG_0042)
**Three sub-issues, confirmed in code:**
- **(a) Name shows as employee # ("660615").** The peer header/column uses the raw `workerID` /
  unresolved `name` when the peer has no `displayName`. **Fix:** resolve through
  displayName → roster `workerName` → workerID, one shared `resolvedName(workerID:)`. 🔴 test
  `resolvedNamePrefersDisplayName` — given a profile with a displayName, the label is the name, never
  the employee #; only falls back to # when truly nameless.
- **(b) No intent-color key.** The bottom legend explains chip border/fill ("Trades a shift away /
  Takes a shift") but **not** the intent-bar colors. **Fix:** add the Round-2 `IntentColorKey` here
  (folds into **D1**). 🔴 covered by D1.
- **(c) Peer intents only PARTIALLY rendered — CONFIRMED GAP.** `AvailabilityView.swift:1079-1080`:
  the peer tint returns **only** `theirSeeking.contains(day) ? .change : nil` — i.e. only their
  *trade-away* days, in one color. Their **want-to-work / must-be-off / keep** intents are **not**
  drawn (self gets the full palette at 1071-1073). So the answer to "are the other user's intents
  visible?" is **no, only their seeking days.** **Fix:** render the peer's full intent palette from
  their published profile (`wantToWorkDayIDs`, `mustBeOffDayIDs`, `keepDayIDs`) via the same
  `brickColor` mapping. 🔴 test `peerIntentPaletteFull` — a peer with want-to-work + must-be-off days
  yields the matching brick colors on their calendar, not just the seeking color.
**Safeguards:** one `resolvedName`; one peer-intent→color mapping reused from self (no divergence).
**Assumptions:** peer intents come from their published `TradeProfile` (ties to R-B fetch).
**Feasibility:** ✅.

### G3 — n-way offers split-the-weekend (non-bookend-for-receiver) trades (IMG_0043, IMG_0044) ★
**Root cause (verified, no hallucination):** (1) bookend is a **soft** rule — `canCover` requires it
only when the receiver's openness is `.bookends` (`TradeMatcher` lines 485-488); open-to-all
receivers legally accept a mid-off-stretch pickup. (2) **`NWayLeg` has no bookend field**
(`TradeEngineModels.swift:210`) and the route score (`TradeRouter.swift:506`) has no bookend term, so
the circular engine is **blind** to receiver-side splits and can't penalize them.
**Scope:** Give the n-way engine bookend awareness, then a **desirability score** + an optional
**user-set minimum-score filter** (Master Filter A2) that drops weak packages — used as a prune bound
for speed, not just a post-filter.
**Approach:**
- Add `bookend: Bool` to `NWayLeg`, computed via the **existing tested** `TradeMatcher.anchored(day:
  map:plan:cal:)` against the receiver's map (receiver-side anchoring).
- Pure `tradeDesirability(route) -> Double`: `+w1·(receiver-bookend legs) − w2·(receiver-split legs)
  + w3·🔥 − w4·participantCount + w5·earliness`. Single source of truth.
- Wire three ways: (i) **best-first ordering** (A1), (ii) **Master-Filter minimum-score** drop
  (A2), (iii) **branch-and-bound prune** — abandon a partial route whose *upper-bound* desirability
  can't clear the threshold (this is the only one that buys **speed**, and only if the bound is
  admissible).
**Fail-tests:**
1. 🔴 `nWayLegBookendComputed` — a leg landing adjacent to the receiver's worked block → `bookend ==
   true`; a leg splitting their off-stretch (the Aug-10 case) → `bookend == false`.
2. 🔴 `desirabilityPenalizesSplit` — two routes identical except one has a receiver-split leg → the
   split route scores strictly lower.
3. 🔴 `minScoreFilterDrops` — packages below the user threshold are absent; at/above remain.
4. 🔴 `pruneBoundAdmissible` — the branch-and-bound upper bound never under-estimates a route's final
   score (no valid route is pruned). *(Admissibility guard — prevents dropping good trades.)*
**Safeguards:** `tradeDesirability` is one pure function reused by order/filter/prune; the prune bound
has an admissibility test (#4) so speed never costs correctness. Threshold default = 0 (drops
nothing) so behavior is opt-in.
**5-Whys (why split trades were offered):** (1) split-weekend trade shown → (2) it's legal for an
open-to-all receiver → (3) bookend is soft, gated on receiver openness → (4) **n-way never computes
receiver-side bookend at all** (`NWayLeg` has no flag; two-way does) → (5) no test asserted
"a circular leg that splits the receiver's time off is flagged/penalized." → fix: leg bookend flag +
desirability score + the four tests above.
**Assumptions:** "split" = receiver picks up a shift inside a ≥2-day off stretch (not anchored to
their existing work). Weights are tunable constants; threshold is user-set (default 0).
**Feasibility:** ✅ for the leg-flag + score + post-filter (deterministic, pure-testable). ⚠️ the
admissible prune-bound (the speed win) is the subtle part — build the flag+score+filter first
(quality), add the prune bound second (speed) behind test #4.

### G4 — Import-success validation (every roster/schedule import) + the IMG_42 name bug
**Root cause of IMG_42 (verified):** the two-way calendar labels the peer with the **roster
`workerName`**, and that worker's `workerName` is the bare employee number "660615" — meaning the
import produced a **name-less row**: `ScheduleParser.workerIdentity` only yields a real name when the
cell matches `Name (id)` (lines 237–247); a cell without that pattern leaves the name == the id. The
messaging thread shows "Test Dispatcher" because that comes from the published `TradeProfile.
displayName`, a *different* source. So: (1) a malformed/partial import, **and** (2) no fallback from
roster-name → profile displayName.
**Scope:** (a) **Name resolution** (also G2a): label peers via `displayName → roster workerName →
#`, so a published name overrides a number-only roster name. (b) **Import validation:** after every
import, run a check that the import parsed correctly and surface a clear pass/warn result.
**Approach:**
- Pure `ImportAudit.validate(parsed:) -> ImportReport` checking: ≥1 worker parsed; **every worker has
  a non-numeric name** (catches the 660615 case); expected day-columns present; per-worker shift
  counts within sane bounds; the importing user's own row found; no duplicate worker IDs; date range
  contiguous. Returns `{ ok, warnings:[...], stats }`.
- Surface the report after import (banner: "Imported N workers ✓" or "⚠️ 3 workers have no name —
  check the report format").
**Fail-tests:**
1. 🔴 `auditFlagsNamelessWorker` — a parsed worker whose name == its id (or all-digits) → report has
   a `namelessWorkers` warning naming it (the 660615 case).
2. 🔴 `auditFlagsMissingSelf` — the user's own employee ID absent from the parse → `selfNotFound`
   warning.
3. 🔴 `auditPassesCleanImport` — a well-formed parse → `ok == true`, no warnings.
4. 🔴 `auditFlagsDupesAndEmpty` — duplicate worker IDs / zero workers → respective warnings.
**Safeguards:** validation is **pure** over the parsed model (no I/O), so it's fully harness-tested;
it never blocks the import, only reports (a bad import still loads, but the user is told). Name
resolution is one `resolvedName(workerID:)` reused everywhere.
**Assumptions:** "nameless" = name empty or all-digits or == workerID. The audit is advisory
(warn, not hard-fail) so a partial roster is still usable.
**Feasibility:** ✅ — pure validator + a banner; the name-resolution half folds into D1.

---

## PART H — Unified acceptance-likelihood scoring

### H1 — One score model, every surface (the math)
**Objective:** maximize the probability a trade *executes* = ∏ over legs of `p(ℓ)` (each party must
accept). Work in log-space so it's additive and admissibly boundable.
- **Per-leg:** `p(ℓ) = σ(z(ℓ))`, `z(ℓ) = (β0 + θ_R) + β_book·x_book − β_split·x_split + β_fire·x_fire
  + β_gw·x_gw + β_rw·x_rw + β_t·x_t − β_q·x_qual − β_h·x_hours (+ β_ecb·x_ecb for ECB legs)`. Features
  reuse `anchored()`, `seekingDayIDs`, `wantToWorkDayIDs`, `dayDate`, `isQualBlocked`,
  `maxWeeklyHours`. `θ_R` = receiver person-prior (H2; **0 by default**).
- **Package:** `Q(P) = Σ_ℓ log p(ℓ)`. **Lexicographic** primary keys `(peopleCount ↑, needsQual ↑)`,
  then `Q ↓`. User threshold τ is a **probability** ("min chance accepted"); drop `P(P) < τ`.
- **Pruning (speed):** since `log p(ℓ) ≤ 0`, a partial route's running sum is an admissible upper
  bound → prune when `Σ_partial log p < log τ`.

**One model — `TradeScore.legProb(...)` / `TradeScore.packageLogProb(...)` — reused by EVERY surface;
only the aggregation/use differs:**
| Surface | legs | aggregation | use |
|---|---|---|---|
| Lucky / Trade Solutions / Intents (n-way + min-cost) | many | ∏ p | rank + threshold + **prune** |
| Just-2 (≤2 people) | 2 | p_out·p_in | rank (default feed); **annotate-only, never hide** on explicit selection |
| ECB (one-way) | 1 | p | rank + threshold; **adds `x_ecb`** (points offered ↑ acceptance) |

**Fail-tests:** `legProbMonotone` (each + feature raises p, each − lowers it); `packageProbProduct`
(`P == ∏ p`, `Q == Σ log p`); `pruneBoundAdmissible` (running partial sum ≥ final → no valid route
pruned); `ecbAmountRaisesProb` (more ECB points → higher p); `lexBeforeScalar` (a clean 2-way outranks
any 3-way regardless of Q). **Safeguards:** one `TradeScore` module; β are named constants in one
place; σ bounds outputs intrinsically (no data-dependent normalization → deterministic/6-σ testable).
**Assumptions:** leg independence (approx). **Feasibility:** ✅ — pure, deterministic, unifies all engines.

### H2 — Private person-prior `θ_R` (OFF by default; non-punitive by construction)
**Scope:** an optional per-person intercept that nudges `p(ℓ)` from a receiver's *own* accept/decline
history. **Predictive, never judgmental; private; never blocking.** Ships disabled (`θ = 0` for all).
**Approach + the 9 failsafes:**
1. **Private** — computed locally; **never published** to others, never in `TradeProfile`, no leaderboard.
2. **Attaches to a TRADE, not a person** — UI shows "this trade ~X% likely," never "Bob 32% reliable."
3. **Bayesian shrinkage** — `θ̂_R = (n_R·ā_R + κ·μ)/(n_R + κ)`, κ≈20 → little data ⇒ ~population mean.
4. **Time-decay** — outcome weight `e^{−Δt/τ½}`, half-life 60–90d; everyone recovers toward neutral.
5. **Reason-aware** — a decline of a **low-p (bad) trade** carries ~no person-signal (weight each
   outcome by the trade's own quality), so nobody is penalized for *correctly* rejecting a bad offer.
6. **Clamped + never-blocking** — `θ_R ∈ [−c, +c]` small; never drives p→0, never removes anyone.
7. **Symmetric** — neutral point = population mean; "yes"/"no" both normal.
8. **Opt-out** — opting out pins `θ_R = μ`.
9. **Ship θ=0** — enable only after real accept/decline data exists; `κ→∞` disables instantly.
**Fail-tests:** `shrinkageTowardMean` (n_R small → θ̂≈μ); `decayRecovery` (old declines fade → θ
returns to neutral over time — the recovery guarantee); `badTradeDeclineNoPenalty` (declining a
sub-τ trade barely moves θ); `clampBounded` (θ ∈ [−c,c]); `disabledEqualsZero` (κ→∞ ⇒ θ=0 ⇒ scores
identical to H1); `neverHidesPerson` (θ never removes a candidate). **Safeguards:** all six tests above
are the non-punitive guarantee, in the harness. **Skeptic note:** most acceptance signal already lives
in the *trade* features — θ_R is a marginal lift with outsized social risk, hence off-by-default +
opt-out + the recovery test. **Feasibility:** ✅ framework slot now (θ=0); enable later with data.

### H3 — Recognition badges (positive-only, top-percentile) — LATER PHASE
**Scope:** Opt-in **positive** recognition (no negative/bottom marks): emoji/badges for the **top ~5%**
on **most reliable** (acceptance rate), **most trades completed**, **most trades requested**. Public
output is only the **badge** (binary "top-5%"), never the underlying score.
**Approach:** derive from existing `MetricEvent` counts (`trade`, `proposed`) + a new reliability
metric (accept-rate). Percentile computed over the active population; badges assigned only above a
**minimum-sample gate**.
**Failsafes (skeptic-tuned):**
- **Positive-only** — only top performers get a badge; *no one* ever gets a visible negative/bottom mark.
- **Min-sample gate** — below N completed trades you can't be crowned (no "100% reliable" off 2 trades).
- **Decay window** — computed over a recent window (e.g. trailing 90d), so it reflects *current* behavior.
- **Opt-out** — a user can hide their badges.
- **Config/admin-gated + off initially** — ship dark; enable deliberately.
- **No raw exposure** — the private `θ_R`/raw rates are never shown; only the qualified badge is.
**Fail-tests:** `top5PercentileOnly` (only ≥95th pct earns a badge); `minSampleGate` (below N → no
badge regardless of rate); `positiveOnlyNoBottomBadge` (no badge type is negative); `optOutHidesBadge`;
`decayWindowRecent` (uses the trailing window, not all-time). **Safeguards:** the percentile + gate are
one pure function; "no bottom badge" is structurally guaranteed (no negative badge type exists).
**Skeptic caveat:** even positive badges create social pressure ("most trades requested" could nudge
over-trading; a reliability badge could pressure accepting bad trades) — hence **optional, admin-gated,
min-sample, decayed, opt-out**, and *never* tied to declining bad trades (reuses H2's reason-aware rule).
**Feasibility:** ✅ but **defer** — build H1 first; H2 needs data; H3 is the last, opt-in layer.

---

## Build order (highest-leverage first; each milestone is test-first, build + harness green)

0. **A8 — no-profile defaults to Bookends Only** (one centralized factory). Quick, high-impact: it
   *prevents generation* of most split-the-weekend trades (G3) at the source. Do this first — it's
   small and de-risks G3.
1. **D1 — unified `TradeCalendar`** + **G4 name resolution.** Unblocks D3, D4, D6, **F1**, **G2(a
   name + b key + c peer intents)** (one fix, eight symptoms).
2. **C1 — staged-commit save-flow** (staging + SAVE + revision-gated recompute; Home-exit confirm
   only — *not* per-tab). Kills the eager-recompute waste.
3. **A1 + A2 + A3 + G3 + H1 — Lucky button + Master Filter + drop intent-only toggle + the unified
   `TradeScore`.** The on-demand engine. **H1** (log-joint-acceptance `legProb`/`packageLogProb`,
   reused by *all* surfaces) *is* G3's `tradeDesirability` and the best-first/threshold/prune signal —
   build it once here, with `θ_R = 0`.
3b. **G4 — import-success audit** (pure validator + banner). Pairs naturally after D1's name work.

**Deferred (data- or policy-gated; ship dark):**
- **H2 — private person-prior `θ_R`** — frame the slot now (`θ=0`); enable only after real accept/
  decline data + all 6 non-punitive fail-tests green.
- **H3 — recognition badges** (top-5%, positive-only) — last, opt-in, admin-gated layer.
4. **D2 + D5 — Just-2 dropdown / search relocation / qual labeling.**
5. **B1 — qual-swap international-desk flow** (move qual out of inline packages into the paged sheet).
6. **A6 — qual-swap inside n-way** (highest engine complexity; its own milestone + tests).
7. **B2 — package merge** (data merge first w/ pure tests, then the messaging lifecycle).
8. **E1 + E2 — channel thread format + statuses.**
9. **E3 — settings section styling** (cosmetic, fast).

**Cross-cutting safeguards (apply to every milestone):** fail-test-first (show 🔴), one-source-of-
truth pure functions for any rule touched (color, label, ordering, filter, eligibility), `CaseIterable`
universe guards for new enums (engine, max-people), `check_arch_map.sh` green, harness green, build
green, and ASSUMED_PRESENT / ARCHITECTURE_MAP updated per milestone.

**Open clarifications (won't block starting D1/C1):**
- B2 merged-request lifecycle: new superseding record vs. in-place mutation? (spec assumes new record).
- C1 navigation guard: confirm Home-exit-only is acceptable (recommended) vs. every-tab intercept.
- A2 "force-include person": should it also accept *multiple* required people? (spec assumes one.)
