# DX — Dev TODO (deferred / not yet done)

Running list of work intentionally left undone. See `DX-MATCH-RADAR-CHANGES.md` (what shipped) and the
memory notes `build6-backlog` / `tradescore-exact-legfeatures`.

## ⚠️ CloudKit Console deploy REQUIRED before these sync

The following features work locally but need new fields on the **PrivateState** record (private DB) to sync
across a user's devices. Add them in the CloudKit Console (Development → deploy to Production):

| Field | Type | Feature |
|---|---|---|
| `radar` | String | Match Radar watch/seen |
| `radarUpdatedAt` | Date/Time | ↑ LWW clock |
| `standingOffers` | String | Standing conditional offers |
| `standingOffersUpdatedAt` | Date/Time | ↑ LWW clock |

(None need to be Queryable — they're fetched by fixed record name, like `intents`/`appPrefs`.)

## Match Radar — real-time push (still deferred, by request)

- **CloudKit silent push.** Radar + standing-offer alerts fire during an in-app `recompute`/`evaluate`
  (app open / inbox / manual refresh) plus the best-effort background digest window — NOT the instant a
  peer marks intent. Real-time needs a `content-available` silent push on `TradeProfile` record updates
  that wakes the app to recompute locally (predicates can't evaluate a cross-user legality match). Costs:
  fan-out/battery/throttle; ~30s background budget (leans on the now-done MatchContext cache); scoping to
  cut fan-out needs new queryable `TradeProfile` fields → another deploy.
- **Settings opt-out toggle** for radar / standing-offer alerts (separate from shift + digest toggles).

## Verify on device (implemented, not runtime-checked)

- **iPad two-calendar scale-to-fit.** The old "must scroll" backlog note looks STALE — `TwoWaySheet` already
  scales the twin grids to the viewport (portrait iPad 82% height, side-by-side in landscape, `fill`). Confirm
  on a real iPad that both calendars fit without scrolling.
- The whole Match Radar + standing-offers UI/notification surface (star both directions, day detail cards,
  propose→Search, watched-day alert + deep-link, standing-offer fill alert) — compile+unit verified only.

## Done since this list was created

- ✅ MatchContext caching (token-invalidated) — big recompute cost removed.
- ✅ Watch/seen cross-device sync (needs the deploy above).
- ✅ AcceptScope date/range calendar UI (MultiDatePicker) — model UI complete.
- ✅ Working-day taker indicator → the SAME star now shows on both on & off days.
- ✅ Standing conditional offers (Build 6 MUST-have) — model, engine, store, sync, notify, UI.

## From existing backlog (see memory)

- **TradeScore exact per-leg LegFeatures** — dev-only score still uses the summary approximation; feed it
  the router's exact per-leg `LegFeatures` so the dev score matches what the engine optimizes.
