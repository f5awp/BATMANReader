# DX — Dev TODO (deferred / not yet built)

Running list of work intentionally left undone. Nothing here is a bug in shipped code — it's scoped-out
or "later." Grouped by area. See also `DX-MATCH-RADAR-CHANGES.md` (what shipped) and the memory notes
`build6-backlog` / `tradescore-exact-legfeatures`.

## Match Radar — notifications & real-time

- **CloudKit real-time push (the big one).** Today radar alerts fire during an in-app `recompute` (app
  open / inbox / manual refresh) plus a best-effort background digest window — NOT the instant a peer
  marks intent. Real-time needs a **silent push that wakes the app to recompute locally**, because:
  - CKQuerySubscription predicates run server-side over ONE record's queryable fields — they can't
    evaluate a cross-user, per-recipient legality match (quals/rest/openness/blackout/accept-scope).
  - Only viable trigger = "a `TradeProfile` record changed" → a blanket `firesOnRecordUpdate` subscription
    → `content-available` silent push → app wakes, runs `recompute()`, posts a LOCAL notification only if a
    real watched match appeared.
  - Costs: wakes every device on every publish (fan-out/battery/throttle); background exec is ~30s so the
    scan must be fast (leans on the perf work below); silent pushes are throttled → still best-effort.
  - Scoping the subscription (e.g. by region/desk) to cut fan-out needs NEW queryable fields on
    `TradeProfile` → the one place the radar would finally need a **CloudKit Console schema deploy**.
- **Settings opt-out toggle for radar alerts.** No user control yet to silence radar notifications
  (separate from the shift-alert + daily-digest toggles).
- **Working-day (taker) calendar indicator.** The star is pickups-only (per spec). A watched working day
  shows only the watch ring; consider a distinct marker when a taker exists, for discoverability.

## Match Radar — perf (partially done)

- Done: per-day index precompute (O(1) day detail), off-main scan, instant sheet + tab-gating.
- **Not done — cache `MatchContext`.** Every `recompute` still rebuilds it (two full-roster SwiftData
  range queries + universe/inferred-prefs for all workers). Cache it on `MatchStore`, invalidate on roster
  generation / peer-profile change. Biggest remaining recompute cost.

## Match Radar — sync & scope

- **Watch / seen markers are LOCAL only.** `watchedDays` + the notify baselines don't sync across a user's
  devices. Would ride the `PrivateState` blob (no schema deploy) if promoted.
- **Accept-scope UI is shift-types only.** The model (`AcceptScope`) supports dates/range + quals + desks,
  but the editor only exposes shift-types. The user asked earlier for a date/range calendar in Mark Intents.

## From existing backlog (see memory)

- **iPad calendar doesn't scale-to-fit** — must scroll to see both calendars (build6-backlog).
- **TradeScore exact per-leg LegFeatures** — dev-only score still uses the summary approximation.
- **Build 6 MUST-have: standing conditional offers** — Cary's auto-matching "trade X to get Y" offers with
  push (build6-standing-conditional-offers).
