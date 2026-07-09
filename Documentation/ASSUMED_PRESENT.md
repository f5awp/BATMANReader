# Assumed-Present Audit — things I claimed "already there" or skipped

> **Why this exists:** the user is explicit — they ask for things **because they are missing**. So any
> time I said "that's already there / already done by existing code," that is **suspect** and must be
> re-verified by a test or on-device. This is the running list. Each item: **what I assumed → why it's
> suspect → how to discharge it** (a test, or a device check). Nothing here is "done" until discharged.
>
> Status: ❌ assumption proven WRONG · ⚠️ unverified (needs check) · ✅ discharged (proven by test/device).

---

| # | I assumed… | Why suspect | Discharge | Status |
|---|-----------|-------------|-----------|--------|
| 1 | **F1** brush already covered all intents | Only 2/4 working intents, **0** direct off-intents were brushable | FIXED + brush-completeness test (every enum case has a brush) | ✅ proven by test |
| 2 | **editPost** preserved a post's channel | It silently reset channel→nil on edit | FIXED while doing B7 | ✅ fixed |
| 3 | **D1** bookends is the default openness | Checked the default string but not the write sites | DONE: verified onboarding/claim never writes `tradeOpenness`; load + `opennessLevel` default to `.bookends`; fallback test added | ✅ proven by code+test |
| 4 | **A5** fewest-people / solo package sorts to top | I only confirmed `OptimalMatcher` prefers 1 person; not the router end-to-end | DONE: `TradeRouter.rankPackages` (pure) + test — solo(2 ppl) tops, greedy before circular | ✅ proven by test |
| 5 | **A6** mutual-intent (🔥) matches now work | Argued the gate fix "largely fixed it" but never reproduced a real mutual match | DONE: `TradeMatcher.goldCountPure` (pure) + test — true mutual = 2; Must-Be-Off drops to 1 | ✅ proven by test |
| 6 | **A3** private notes / status sync | Private notes didn't sync at all | DONE (private notes): `PrivateStateStore` + `CloudKitPrivateStateService` (private DB) + `LWW` (tested) + launch-sync + publish-on-edit | ✅ code+test; ⚠️ device-verify |
| 12 | **A3 status** cross-device | ✅ DONE: `SettingsManager.statusUpdatedAt` (LWW clock) + publish-on-status-edit + `TradeProfileStore.syncMyStatus()` (LWW.pick vs own published profile) at launch. LWW tested; restore is build-verified (rides the profile JSON payload — no schema deploy) | ✅ wired (device-verify on a fresh device) |
| 13 | **New `.swift` files** auto-compile | The file-system-synchronized group doesn't re-scan on an MCP build → "cannot find X" | RULE: put new code in an EXISTING compiled file (or user adds the file in Xcode). Applied for PrivateState. | ✅ rule adopted |
| 14 | **CloudKit `PrivateState`** record type | New private-DB type needs a schema deploy for Production (like the roster master) | Deploy schema Dev→Prod before TestFlight relies on it | ✅ deployed 2026-06-20 (see CLOUDKIT_DEPLOY.md); device-verify |
| 7 | **A7/B8** `participantStatus` returns peers' status | Inbox never refreshed profiles → `others` could be empty → status silently missing | FIXED: `InboxView.task`/`refreshable` now call `refreshOthers()` so peers load | ✅ fixed |
| 8 | **C3** the day-picker was the only blank calendar | Other pickers might also be blank | DONE: both Trade-Search (108) & ECB (381) pickers use the now-fixed `ShiftSelectCalendar`; two-way sheet uses `MiniScheduleGrid` (already overlays intents) | ✅ verified |
| 9 | **B4** edit/delete only did channel replies | Missed 1:1 chat `.message` responses | DONE: `TradeResponse.editedAt/deleted` + `editMessage`/`softDeleteMessage` + chat-row UI; also fixed local `postReply`/`sendResponse` to upsert | ✅ proven by test |
| 10 | **Vacation** peer-on-vacation as taker | Could be a hard-block question | DECIDED (your rule "still allowed to trade into it") → vacation is a SOFT exclusion only; no hard gate; invariant test added | ✅ decided + test |
| 11 | **D2a** Intents badge = a count is enough | You wanted multiple color-coded tier bubbles | DONE: `IntentTallyBar` (Trade-away/Keep/Want-to-work/Must-be-off, each colored w/ count) under the Trades picker; counts tested | ✅ proven by test |

---

| 15 | **S-ENG-10** fully done | Want-to-Work bookend-override gate (tested) + now the scorer too: §U `rankPackages` ranks **two-sided bookends** (`bookendTotal`, both sides) and boosts **trade-away/wanted** days (`fireCount` counts `.wanted` legs = seeking days). Tested via U4. | ✅ delivered via §U U4 (was the open part of #15) | ✅ done |
| 16 | **Build recovery** | `xcodebuild clean` clears "undefined symbol: old init" linker errors from stale incremental state (e.g. concurrent builds) | RULE: on that linker error, `xcodebuild clean -scheme BATMANReader` then rebuild | ✅ rule adopted |

| 17 | **S-VALID** fully done | Did the validity core (`staleDaysPure`, tested) + urgent thread banner; inbox-wide badge + auto-clear now wired: `MessagingStore.invalidRequestIDs`/`refreshInvalidRequests` (recomputed every `refresh()` → auto-clears) + `RequestRow` "Invalid" badge | ✅ DONE — build-verified (async/roster); core harness-tested. Device: confirm badge appears when a day is re-traded and clears when reversed | ✅ wired (device-verify) |

| 18 | **H1 metrics are GLOBAL** | ✅ DONE: `MetricEvent` (search/proposed/trade) logged to a public-DB event log (`CloudKitMetricsService`); `MetricsStore` fetches + the Home header shows TEAM-WIDE totals (pure `Metrics.global`, tested) with a local fallback when offline/empty. Hooks: `recordSearch`/`sendRequest`/`record(!pending)` | ✅ wired — needs the `MetricEvent` schema deploy (#23) | ✅ done (deploy + device-verify) |

| 19 | **B6 reactions** everywhere | ✅ DONE: `BroadcastReply.reactions` + `TradeResponse.reactions` (both + explicit init) + `MessagingStore.react(to:emoji:)` overloads + reusable `ReactionChips` strip on reply rows AND 1:1 chat messages. Reuses the tested `Reaction.toggle`/`counts`. | ✅ posts + replies + chat all react now | ✅ done |

| 20 | **Qual-swap `candidateIDs`** queryable | New flat list field on `TradeRequest` records for bridge discovery (`candidateIDs CONTAINS me`) — CloudKit needs it added + **indexed/queryable** in the schema (Dev→Prod) before bridges can fetch blasts in Production | Deploy schema: add `candidateIDs` (String List, Queryable) to `TradeRequest` | ✅ deployed 2026-06-20; device-verify |

| 21 | **`perfectMatch`** queryable | New Int flag on `TradeRequest` records driving the "Perfect Match" push subscription (`toID == me AND perfectMatch == 1`) — must be added + **Queryable** in the CloudKit schema (Dev→Prod) before the push fires in Production | Deploy schema: add `perfectMatch` (Int64, Queryable) to `TradeRequest` | ✅ deployed 2026-06-20; device-verify |

| 22 | **§U eligibility merge** is behavior-equivalent | `twoWayExplore`/router `canCover`/ECB delegate to `TradeEligibility.canCover`. ✅ DISCHARGED: added a **gate-matrix regression test** (U1-regression) with hand-reasoned oracles — rest <8h, weekly-cap breach (fails .full / passes .physicalOnly), isolated-off → eligible-but-not-bookend, openness=none soft gate — all green. The eligibility layer every path shares is now harness-PROVEN, not just build-verified. (Per-path *wiring* still benefits from a device glance, but the gate logic is locked.) | ✅ proven by test |
| 23a | **Optimizer per-N generation** | ✅ DISCHARGED: found the real gap — circular (N+1) only ran when solos were scarce (`result.count < targetCount`), so the N+1 group was hidden when N=2 solos existed. FIXED: circular now ALWAYS generates; `rankPackages` orders N=2 solos first, then the N=3/4 circular group. Progressive N is surfaced. Generation is async/roster → build-verified; the SORT is harness-tested. | ✅ fixed (device-glance for card volume) |
| 24a | **`candidatesForTrades`** inline gate | ✅ DISCHARGED: refactored its off+qual+rest gate to delegate to `canCover(.physicalOnly)` (set-anchor bookend kept separate). The LAST duplicate of Layer-1 eligibility is retired — every matcher path now runs the one predicate. Behavior-preserving (inline rest == `rested`; relief still applied downstream in ECB `.full`). Build + suite green. | ✅ delegated (no more duplicate) |
| 25 | **Q1 qual-swap generation** works end-to-end | `TradeRouter.packages` qual-swap generator + `propose`→blast are **build-verified**; only the pure cores (`isQualBlocked`, `solutions`, cap-exemption) are harness-tested | On-device (T38): a qual-blocked give-day with a bridge surfaces a Q-badge card; Propose opens the blast; no bridge → no card | ⚠️ device-verify |
| 26 | **Relief own-display** filter is total | Made `ShiftStore.shifts` a relief-filtered computed over `rawShifts`; assumed EVERY display consumer reads `shifts` (not `rawShifts`) and that `@Observable` re-renders on the computed when the toggle/date changes | On-device (T37): post-relief days blank in Home/pickers/widget AND the UI updates immediately when relief is toggled/dated | ⚠️ device-verify |
| 29 | **`MetricEvent`** record type | New public-DB type for global metrics (H1 #18) — needs the type + a `payload` String field deployed Dev→Prod before team-wide totals populate in Production | Deploy schema: add `MetricEvent` (with `payload` String) to the public DB | ✅ deployed 2026-06-20; device-verify |
| 30 | **`hasQualSwap`** queryable | New Int flag on `TradeRequest` driving the taker's record-UPDATE push subscription (`toID == me AND hasQualSwap == 1`) — must be added + **Queryable** before the qual-swap-response push fires in Production | Deploy schema: add `hasQualSwap` (Int64, Queryable) to `TradeRequest` | ✅ deployed 2026-06-20; device-verify |
| 31 | **Qual-swap acceptance push** | ✅ wired: `hasQualSwap` flag + a `.firesOnRecordUpdate` subscription (`qualswap-update-<me>`) alerts the taker when a bridge responds. NOTE: update subscriptions fire on ANY update to the taker's qual-swap requests (slightly chatty) — acceptable; can't filter "acceptance added" in CloudKit | Device: confirm the taker gets pinged when a bridge accepts | ✅ wired (needs #30 deploy + device-verify) |
| — | **TradeProfile new fields sync** (CONFIRMED) | `qualValues` · `qualSwapBlacklistDesks` · `reliefThrough` ride the TradeProfile **JSON payload** (`CloudKitTradeProfileService` encodes/decodes the whole struct) — **no schema deploy needed**, unlike `candidateIDs`/`perfectMatch` | Verified by reading the service (full-struct JSON payload) | ✅ confirmed |

| 32 | **C6 Intents flatten** behavior-equiv | ~~Intents renders `packages(excluding:)`~~ **SUPERSEDED by #33** — Intents now has its OWN engine (`intentSolutions`), not `packages`. | superseded | ➡️ #33 |
| 35 | **A6 qual-swap-in-n-way** (DEFERRED, not assumed) | The ONE remaining build-3 item. Adds a bridge-expansion *leg type* inside the `nWayRoutes` DFS (insert a qualified middle-person C who desk-swaps when a leg is qual-blocked). NOT built: its fail-tests (`nWayFindsQualBridge`/`nWayQualLegLegal`) are **integration-level** (need a roster scenario solvable only via a bridge), so it can't meet the "tested-to-succeed" bar in the harness alone, and it's high-risk core-DFS surgery on real trades. Qual-swap already works as standalone packages + the dedicated multi-select Qual-Swap button, so this is an enhancement, not a gap. Discharge: its own milestone with roster fixtures + device verification. | ⏸️ deferred (own milestone) |
| 34 | **Unified packageLogProb scoring** drives the live feeds | The whole feed now ranks/floors on `TradeScore.packageLogProb` (per-leg grades from live data via `TradeRouter.legFeatures`/`packageLogProb(for:)`). PURE model (`legLogit`, intent-scaled split, N-penalty, `finalize`) is **harness-proven + teeth**; but the **live wiring is build-verified only** — the per-leg extraction (want-to-take/-trade lookups, `isAnchored` bookend, qual, prior) and the floor magnitudes (0.32/0.07) need on-device eyes. **Assumptions baked in:** (a) every leg is bookend XOR split; (b) `daysUntil` via `exp(−0.05·days)`; (c) receiver quals from rosterMeta; (d) N-penalty 0.85 + floors 0.32/0.07 are first-cut tunables. **Perf assumption:** with the 2-way gate reversed, the normal feed runs n-way up to `normalMaxPeople` (default 3) on SAVE/Find — assumed affordable via the 500 backstop + cancellable + N-penalty rarity; **device-verify it's not janky.** Discharge: on-device — Intents/Trade-Solutions show small-N on top, intent-rich loops appear, no-intent splits gone; tune floors/N-penalty/toggle default from what you see. | ⚠️ device-verify (model tested) |
| 36 | **U-PERF: `MatchContext` is behavior-preserving** | Collapsed the 4×-duplicated roster-load/map-build/universe/prior block into one `TradeRouter.MatchContext.build(selfID:)` built once per pass; threaded `priors` (one `MessagingStore.acceptancePriorMap()` scan, was per-leg `partnerAcceptanceLogOdds`) and `preloadedMaps` (n-way DFS reuses the feed's window, was a 2nd SwiftData fetch) through scoring. **Result-neutral by construction:** same rows, same `PersonPrior.logOdds` formula (absent worker → 0 == `logOdds(0,0)`), same `horizon` window. Build + full harness (`runAll`) + arch-guard all green AFTER the change (proves no output moved). **Assumption:** the roster is read-only mid-search (imports happen on launch/sync), so the preloaded snapshot can't diverge from a re-fetch. | ✅ proven (build + suite green; pure refactor) |
| 33 | **Intents marketplace engine** distinct + correct | Intents = `TradeRouter.intentSolutions` (NOT `packages`): per-peer `twoWayExplore` → split MARKED vs PREF → `assembleIntentDeal` (PURE, tested + teeth) builds best balanced 2-person deal maximizing mutual intent; marketplace seed = ≥1 marked side; whole roster eligible as PREF counterparty (unprofiled = bookend default); `.bookends` set-contiguity (`anchoredSet`); Lucky 3+ via `nWayRoutes(allowPrefMiddles:)` needing ≥1 marked leg, `fireCount` = real marked legs; `rankIntentPackages` (PURE, tested) intent-first; top-20 cap (`intentResultCap`, contract-tested). **Pure cores harness-proven**; the async assembly + `allowPrefMiddles` loop relaxation + contiguity are **build-verified** (need live roster). | On-device: (a) Intents shows ≤20 two-person deals, mutual-🔥 on top; (b) a deal with an unprofiled peer appears (my marked give, their bookend-default take) but ranks below mutual; (c) Lucky→Generate N-Way shows loops with ≥1 marked leg, more-marked higher; (d) Trade Solutions (`packages`, `allowPrefMiddles:false`) unchanged | ⚠️ device-verify (cores tested) |
| 27 | **B5 image size** fits CloudKit | `PostImage.encode` downscales+compresses to < 700KB so the base64 rides the ~1MB record payload; a too-big photo returns nil (post sends text-only). Assumed 700KB ceiling is safe under the real record limit | On-device: attach a large photo → it posts + renders on another device; very large photos drop the image (not the post) | ⚠️ device-verify |
| 28 | **B5 replies/chat** images | ✅ DONE everywhere now: posts (`BroadcastPost`), channel replies (`BroadcastReply`, #8b), AND 1:1 chat (`TradeResponse.imageBase64` — rides the JSON `payload`, **no schema deploy**). `ThreadView` composer gained a `PhotosPicker` + preview; chat message row renders the image; threaded through `respond`/`postMessage` + preserved in `react`/`editMessage` (dropped on soft-delete tombstone); `SlackComposer.canSendWhenEmpty` allows image-only sends. Build + harness green. | ✅ done (device-check render) |

| R-A | **Match universe = published profiles** (bug) | Round-2: Just 2/Trade Solutions/Intents only showed opted-in peers (~3) because `packages()`/`twoWayExplore` looped `TradeProfileStore.others`, not the roster. ✅ FIXED: pure `MatchUniverse.candidates(roster:profiles:)` (unknown-profile peer = `.unknown`, included; declined excluded unless What-If) — tested; `packages()` now loops the roster with preloaded schedules (no 2×N re-fetch). | ✅ proven by test + wired |
| R-B | **Status + intents not visible cross-device** (img 36/29) | ✅ NOT a codec bug — new round-trip test proves `statusBroadcast` + `seekingDayIDs`/`wantToWorkDayIDs`/`mustBeOffDayIDs`/`keepDayIDs` all survive the JSON `payload` encode→decode (the exact CloudKit publish/fetch path). Wired: (1) **single publish funnel** — Trade Settings sheet `.onDisappear { publishProfile() }` (a vertical status `TextField` swallows `.onSubmit`, so edits weren't publishing); (2) `refreshOthers()` on **Home `.task`** (peers/interest counts now load on the main screen, not just inbox/trades); (3) **render peer status** — `TwoWaySheet` shows the peer's `statusBroadcast` banner + uses `theirSeeking`. Remaining: 2-account device verification (timing). | ✅ proven by test (2-device verify) |
| META | **Why the harness missed Round-2 bugs** | Tests covered PURE leaves only; the COMPOSITION/seams (universe, labels, metric timing, decode-compat) had zero assertions, and async/roster paths were "build-verified only." FIX: extract each composition rule into a pure function and test the seam (started: `MatchUniverse`, decode-back-compat). Converts "⚠️ build-verified" → harness-proven. | ✅ process fixed (ongoing) |
| P0-wipe | **Posts/trades/feedback vanished** (img 32) | ✅ NOT a decode regression (v1 decode tests pass). Root: CloudKit queries on undeployed flat fields (`candidateIDs`/`perfectMatch`/`hasQualSwap`) error → empty fetch → `refresh()` clobbered the cache with []. ✅ HARDENED: `FetchMerge.keepCacheOnEmpty` (tested) — an empty fetch never wipes a non-empty cache; wired into `MessagingStore.refresh()` for posts/requests/responses/replies. ROOT still needs the 5 deploys (queries succeed once fields exist) + new-record saves on Prod need them too. | ✅ display hardened (deploy = root) |

| R2-#4 | **2-person tagged CIRCULAR** (bug) | `nWayRoutes` closed the loop at `depth >= 2` (the comment even said ≥3) → emitted 2-cycles tagged circular (img 28/37/38). ✅ FIXED: closing guard `depth >= 3`; pure `TradePackage.isCircular = methodology==.circular && peopleCount>=3` (tested) drives the card label. | ✅ proven by test |
| R2-#4b | **Sort tiebreak = earliest date** | With N/🔥/bookends equal, the closer (earlier) trade should sort first (img 28). ✅ `TradePackage.earliestDayID` + `rankPackages` tiebreak after bookendTotal; tested (beats alphabetical id). | ✅ proven by test |

| R2-#3 | **Wrong tally factors + ambiguous count** (img 27) | ✅ Tally now shows only the two MATCHING factors — **Want-to-Trade** (working) + **Want-to-Work** (off); `DayIntentStore.tradeIntentCount` drives a **circled** count badge on the Intents segment via a custom `TradesSegmentBar` (vs "Just 2" looking like a count). Count tested. | ✅ done |
| R2-#1 | **Want-to-Work on no-legal-shift days** (img 25) | ✅ `AvailabilityManager.hasAnyLegalShift` (tested, fully-rest-blocked → false); calendar shows a red ⊘ + `applyOff` blocks WTW when no legal shift. META-WIN: `Legality.legalTypes` was a SECOND rest-rule impl — consolidated to delegate to the tested `eligibleTypes` (killed the duplicate seam). | ✅ proven by test |

| R2-#9 | **Metric was a % of the wrong event** (img 32 + note) | ✅ Home header now shows TOTAL successful trades — **You** + **Company** — with one shared month/year/all picker (no %). `Metrics.count(events:kind:period:workerID:)` + `Metrics.isSuccessful(accepted:archived:)` tested. "Successful" = **accepted AND archived**: the `.trade` metric moved OFF `history.record` (completed) ONTO `MessagingStore.archiveRequest` (accepted+archived, once). | ✅ proven by test |

| R2-#8a | **Unlimited reactions per user** (img 32) | ✅ `Reaction.toggle` → `Reaction.setSingle` (tested): one reaction per user — a different emoji REPLACES, the same emoji clears. All `react(to:)` store paths now use it. | ✅ proven by test |
| R2-#8b | **Plain reply box; no photo** (img 32) | ✅ `BroadcastReplyComposer` redesigned — premium rounded field, **send icon** (paperplane), public/private, **photo attach** (PhotosPicker → `BroadcastReply.imageBase64`, rendered in `replyRow`; threaded through edit/react upserts). | ✅ done (device-check render) |
| R2-#8c | **Posts/trades/feedback gone** (img 32) | Same as P0-wipe: display hardened (`FetchMerge`); the data is on the server — the 5 CloudKit deploys make the fetch succeed and it returns. | ⚠️ deploy = root |

| R2-#7 | **Email buried in inbox; redundant card text** (img 31) | ✅ Removed the per-thread "Email to dispatch DL" button; added an **envelope button at the top of Trade Solutions + ECB** — selected days → prefilled **Outlook** draft (`ms-outlook://compose`, mailto fallback) to the DL. `TradeEmail.dispatchBody` (give days + Must-Be-Off blackout) / `ecbBody` (ECB count, NO blackout) tested. Dropped the redundant "…— your part is highlighted" auto-note. | ✅ proven by test (open on device) |
| R2-#10f | **"Execute Trade"** wording | ✅ → **"Propose Trade"** on all package/route action buttons. | ✅ done |
| R2-#10d | **Card fonts too small** (img 35) | ✅ Scaled the shared `DS` font ramp up one tier (single source of truth → every card): `dsChip` caption→**subheadline**, `dsLabel`/`dsBadge` caption2→**caption**, `dsCardMeta` caption2→**caption**. PackageCard headline → `.headline`, trader names → `.dsCardTitle`. Spec docs updated. | ✅ done (device-check) |
| R2-#10e | **Date chips all one color** (img 35) | ✅ Reciprocal cards already used per-trader color; the **circular HandoffChain** now colors each name + day chip by that person's calendar color (`orderedPeers` → `traderColor`) instead of uniform indigo. | ✅ done (device-check) |
| R2-#10 | **Mass-action UX: lag, per-day overwrite prompt, cramped/small brushes** (img 33) | ✅ (1) **Lag fix:** the lag source — the "others' intents" badge refiltering 500 profiles per cell per tap — is **removed entirely** with that layer (see #2), so no per-tap refilter remains. (2) **Overwrite once:** `@State overwriteConfirmed` — the conflict alert fires once per painting session (reset on mode/brush change), not per day. (3) **AM/PM/MID on the SAME line** as the 3 intent brushes (horizontal `ScrollView`), `"Pick up:"` → **"Shift Availability"**. (4) **Bigger/clearer buttons:** `brushPill` bumped to `.subheadline`, larger padding, selected = colored fill + 2pt stroke + colored text. | ✅ build-verified (UX device-check) |
| R2-#2 | **Mystery 3rd layer + unrequested day glyphs** (img 26) | ✅ Per your sign-off: **removed** the "Others' intents" layer (toggle + `othersBadge` + the whole `peersInterested`/`peerInterest`/`peerInterestMap`/`peerInterestCounts` API + tests) — it was unrequested speculative UI added during the A1 chunk. The AM/PM/MID off-day pills are **kept** and now **toggleable** via a new **"Shift availability"** (`clock.badge.checkmark`) switch gating `layers.availability` (was always-on). Toolbar now has exactly 3 named layers, each tied to a spec item. | ✅ done (device-check) |

| R3-A8 | **No-profile peers default to "open/all"** (root of split-trade offers) | ✅ `TradeProfile.defaultForUnpublished(workerID:name:)` — ONE factory, openness `.bookends`, epoch `updatedAt` (real profile wins LWW) — replaces 4 scattered `openness:"all"` missing-peer fallbacks (`TradeRouter.profileFor`/`openProfile`, `TradeMatcher` qual-bridge, `TwoWaySheet.load`). A profileless receiver now fails `canCover` for a non-bookend pickup → split-the-weekend trades never generated. Red proven (`no member 'defaultForUnpublished'`) → 4 fail-tests green. | ✅ proven by test |
| R3-D1/G2c | **Two-way calendar shows only peer's trade-away intents** (img 42c) | ✅ `PeerIntentColor.forDay(...)` (pure SSOT, `DispatchPalette`) maps a peer's published intent sets → calendar tint with precedence **must-be-off → keep → trade-away → want-to-work** (reuses the same `brickColor` hues as self). `TwoWaySheet.theirIntent` rewired to it; `load()` now reads `theirWantToWork`/`theirMustBeOff`/`theirKeep` from the peer's `TradeProfile` (was only `seekingDayIDs`). Edge: unmarked day → nil (no tint); a day in multiple sets shows the strongest. Red proven → 6 fail-tests green, build green. | ✅ proven by test (device-check colors on peer calendar) |
| R3-G3 | **n-way offers split-the-weekend loops** (img 43/44) | ✅ `NWayRoute.bookendCount` (legs anchored for their receiver) → circular package `bookendTotal` = real count (was all-or-nothing); `rankPackages` already sorts by bookendTotal, so split-heavy loops drop below clean ones. `TradeScore.routeDesirability` (pure) penalizes splits / rewards 🔥 for later best-first+threshold. Red proven → 3 tests green. Pairs with A8 (which *prevents* no-profile splits at `canCover`). | ✅ proven by test (device-check ordering) |
| R3-A1/A2 | **No on-demand "Lucky" search shaping** | ⚠️ Lucky button + `MasterFilterSheet` (engine / max-people / force-include person) + chips; `SearchFilter.filter().prefix(100)` applied to results. Pure filter harness-proven (6 tests); the UI is **build-verified**. Post-search filter (not in-DFS) — see assumptions. | ⚠️ build-verified (device-check) |
| R3-H1/G3 | **Split trades + no scoring model** | ✅ `TradeScore` (log-joint-acceptance, 8 tests) + `routeDesirability` + `NWayRoute.bookendCount` → split loops demoted. | ✅ proven by test |
| R3-G4 | **No check that an import parsed correctly** (root of "660615") | ✅ `ImportAudit.validate(workers:selfID:)` (pure, `ScheduleParser`) → `ImportReport{ok,workerCount,namelessWorkers,duplicateIDs,selfFound,warnings}`. Flags name-less (reuses `TradeNames.isAllDigits`), missing-self, dupes, empty. Advisory only — never blocks the import; `HomeView.handleImport` appends the result to the import banner. Red proven → 5 fail-tests green. | ✅ proven by test (device-check banner) |
| R3-D5 | **Qual-swap packages can outrank clean ones** | ✅ `TradePackage.needsQualSwap` + `rankPackages` key after peopleCount: same N → clean before qual (even if qual has more 🔥/bookends); 🔥/bookend/date order applies within each group; N dominates (qual 2-way still beats clean 3-way). Red proven (assertion) → 3 fail-tests green. | ✅ proven by test |
| R3-D4 | **Just-2 says "Propose to All" for a single person** | ✅ `proposeButtonTitle(count:name:)` (pure SSOT in `TradeEngineModels`): 1 → "Propose to {Name}", 2+ → "Propose to All", 0/nameless → "Propose". Wired into `PackageCard`. Red proven → 5 fail-tests green. | ✅ proven by test |
| R3-D1/G2a | **Peer shows as employee # not name** (img 42 "660615") | ✅ `TradeNames.resolved(displayName:rosterName:workerID:)` — ONE pure resolver (real displayName → real roster name → #; rejects empty/blank/all-digits/==id). `TwoWaySheet.peerName` wired into the nav title, the peer calendar header, and the sent/no-bridge messages; `peerDisplayName` loaded from the profile. Red proven (`cannot find 'TradeNames'`) → 5 fail-tests green. | ✅ proven by test (device-check name) |
| R3-D1/F1 | **Trades show blue/red instead of per-user themes** (img 42) | ✅ `TradeColors.forWorker(workerID:myID:)` — ONE stable per-worker color (deterministic UTF8 hash → `traderThemes`; you = blue) used by `TwoWaySheet` (was hardcoded red), `PackageCard`, `PackageDetailView`, `HandoffChain`. 6 fail-tests + empty-palette guard; **teeth proven** by breaking `forWorker` (peer-≠-blue went red) then reverting. First sub-step of D1 (unified calendar). | ✅ proven by test (device-check colors) |
| R2-#5 | **Non-bookend day labeled "bookend"; no intent key** (img 29) | ✅ (1) `TwoWaySheet.legCard` printed **"bookend" unconditionally** — now gated on `leg.bookend`. Engine was correct (`TwoWayLeg.bookend = check.isBookend`); proved via a new test that exposed `TradeMatcher.anchored` and asserts an **isolated give-day → bookend == false**, an adjacent-to-work day → true. (2) New reusable **`IntentColorKey`** (same calendar hues: Trade away / Want to work / Keep / Must be off + 🔥 mutual / 📖 bookend) added to the **two-way sheet** and **ECB** views. | ✅ proven by test (legend device-check) |
| R2-#6 | **ECB: 1-col, unsorted bookends, single broadcast** (img 30) | ✅ Names now **2 columns on regular width** (1 on compact, via `horizontalSizeClass`); candidate list **sorted bookend-first**; the single "Request all" replaced with **two buttons — "Bookends (N)"** and **"All N"** (`requestAll(bookendsOnly:)`). Build-verified (async/roster UI). | ✅ done (device-check) |

## Round-3 assumptions (explicit — flag if any are wrong)
- **A3 is a no-op.** There was an "intent-only vs all-eligible" toggle planned for the Lucky popup;
  the search already uses **all-eligible** (intent only ranks, never gates — R-A/A8), so there is no
  toggle to remove. A3 ships as "nothing to do."
- **A1 filter is post-search.** "I'm Feeling Lucky" currently **filters the already-computed**
  Trade-Solutions results (engine/max-people/required-person) and caps to **100** via `prefix`. The
  deeper design — gating the heavy search behind the button, **best-first seeding inside the DFS**, a
  **cancellable Task + spinner**, and **N-Way capped to 60 when "Both"** — is **not yet wired** (follow-on).
- **A2 "Both" caption** says results are "capped for speed" — the *60-best-when-Both* cap is not yet
  enforced in the engine; today the post-filter `prefix(100)` is the only cap.
- **`TradeScore` weights are hand-tuned**, not fitted from data. H2 person-prior ships at **θ=0**
  (disabled). When acceptance data exists, fit the weights + enable θ with the H2 failsafes.
- **A8 "unpublished" = no published `TradeProfile`.** Such peers default to **Bookends Only**; an
  explicitly-published `.all` profile is untouched.
- **Required-person dropdown = distinct roster** over the next 12 months (`RosterStore.entries`),
  names resolved via `TradeNames` (G2a).

## Build 4 assumptions (flag if wrong)
- **B4-5 RE-ENABLED as a hard blacklist (2026-07-08, user decision).** Reverted 07-07 (over-pruned), then
  the user explicitly chose the hard restriction: profileless peers with ≥6 worked shifts/60d are limited
  to their worked **regions + shift types + weekends** (weekend blacklist only if zero worked). Accepted
  tradeoff: fewer 3-way/multi-day covers (shift-type is the biggest reducer; `minSample` is the dial).
  Published profile overrides. This is intended behavior, not a regression.
- **B4-5 scope + tunables.** Inference (60-day lookback, min 3 shifts) shapes the A8 default ONLY for
  profileless peers in the **main matching universe** (`TradeRouter.MatchContext.profile(for:)`). Other
  `defaultForUnpublished` call sites (two-way sheet load, qual-bridge, `qualSwapOptions.openProfile`) keep
  the plain bookends A8 default. Cores tested; the matching-behavior change (a profileless peer is no
  longer offered a shift type/region they haven't worked in 60d) is **build-verified via composition**
  (inferred profile tested + matcher-respects-blacklist tested), not a roster fixture. Device-verify; flag
  if 60d/min-3 needs tuning or if inference should apply to the other default sites too.
- **B4-2 needed a schema field (CORRECTED).** My earlier "full fidelity via the existing PrivateState
  payload, no deploy" was WRONG — `PrivateState` has discrete fields, not a `payload`. Full-fidelity intent
  sync adds `intents` + `intentsUpdatedAt` to the private `PrivateState` record → **one small Prod deploy**
  (no index; see CLOUDKIT_DEPLOY.md, PENDING). Code is built + snapshot round-trip tested; **live sync is
  inert until the deploy**. Discharge: deploy, then 2-device verify (DEP5-style).
- **B4-2 adopt-vs-edit safety.** Remote adoption (`applyRemoteSnapshot`) refuses when
  `hasUnsavedChanges` (INV-9) so a mid-edit sync can't clobber unsaved marks. Launch sync runs before any
  edit, so normal launches adopt cleanly.
- **B4-3 painting precedence (built on this default; flag to change).** An **explicit per-day intent
  color wins** — the Blackout tint shows only on days with **no** explicit working/off intent
  (`HomeCalendar.background` checks `intentTint` before `blackoutTint`). One-line reversible.
- **B4-3 off-day Blackout (built on this default).** **Weekday** blacklist applies to any date incl. days
  off (so "Blackout weekends" tints Sat/Sun even when off); **desk/type/region** apply only to **working**
  shifts (off days have no desk). See `HomeCalendar.blackoutTint`.
- **B4-3 scope = Home calendar only (decision).** Painting is on the **Home** calendar (the user's
  schedule overview — what items 2/12/7 mean by "your calendar"). The **give-day pickers**
  (`ShiftSelectCalendar`, ECB/trade pickers in `AvailabilityView`) are intentionally **excluded**: they
  select your OWN shifts to give away, where the *accept*-blacklist is irrelevant and would confuse.
  Flag if you want Blackout on the pickers too.

## Build 6 assumptions (flag if wrong)
- **B6-INTENTS — robot gate is Mutual-only.** The active-account filter was gating BOTH modes → the
  Intents feed went empty whenever no peer had claimed an account (test env). Fix: pure
  `TradeRouter.peerEligibleForIntents(isActiveAccount:mutualOnly:)` (`!mutualOnly || isActiveAccount`),
  wired at both guard sites (2-way loop + circular). **All** shows every peer; **Mutual** keeps real
  accounts only. Proven by test (unclaimed→eligible in All, excluded in Mutual; claimed→eligible in Mutual).
  Assumption: robots never publish a claimed profile, so Mutual stays robot-free in production. ✅ proven by test
- **B6-VAC-FINAL — BOTH `V` and `w` (ECB VC) are OFF-day leave codes; printed shift ≠ worked.** Verified
  against the user's real CSV: `L,V` (Vacation) AND `L,w` (ECB VC) both print a base-rotation shift yet the
  worker is OFF (May 11-13 `w` = off; Dec 15-18 `V` = off). ECB VC is just another way to obtain vacation
  days; neither code says whether you picked up. So `resolveVacations` flips EVERY `V`/`w` day OFF
  (`Shift.vacationLeaveCodes = {V,w}`, `isVacationOrigin`), start/desk preserved, and the per-day override
  ("I worked this day") is the ONLY signal for a picked-up leave day (e.g. July 26-29 `V` picked up →
  working). ✅ proven by test (B6-VAC-ECB). Supersedes the desk-heuristic and the "w stays working" attempts.
- **B6-VAC — a V-day ALWAYS defaults to vacation OFF (heuristic dropped).** First attempt kept the
  home-desk heuristic (foreign desk → working); user reported December vacations STILL showed working.
  Root cause: a genuine vacation prints whatever desk that **month's rotation** uses, which differs from
  the summer-sampled "home" desk → misread as a foreign/traded-in pickup. The desk simply can't
  distinguish genuine vacation from traded-in. **Fix:** `resolveVacations` now flips EVERY `V`-day to OFF
  (printed start/desk preserved for the override); no desk logic. Traded-in is the rare per-day manual
  toggle. Tests rewritten (December seasonal desk 74 + blank + foreign 43/45 → ALL OFF). ✅ proven by test.
  **Residual (flag):** if December still shows working after this build it is NOT the resolver — it's
  either (a) **stale cached** shifts predating the fix → re-sync/re-import once, or (b) those days aren't
  tagged `L|V` in the source CSV → needs the current CSV to fix the parse. ⚠️ user re-sync / send CSV if it persists
- **B6-LAYER — shift-type visibility toggle.** New `LayerVisibility.shiftType` + a "Shift type (AM/PM/MID)"
  toggle in `VisibilityToolbar`. `HomeCalendar.dayContent` composes the worked-day label from the two
  independent flags (type + desk); both off → blank (the day circle still marks worked). ⚠️ device-verify
- **B6-STATS placement fix.** `.safeAreaInset(edge:.bottom)` on the **TabView** rendered the strip OVER the
  tab bar. Moved the inset onto each **tab's content** (HomeView/TradesView) so it sits within the screen's
  safe area, above the native tab bar. ⚠️ device-verify (no overlap on all devices)
- **B6-HOME — normal-view day tap opens `DayDetailSheet`.** `handleTap` `.off` was `break` (no-op), and
  the vacation toggle only lived behind a Mark-Intents long-press → unreachable. Now a tap sets
  `detailTarget` → `DayDetailSheet` (shift summary + the "Vacation Traded In" toggle → `setVacationOverride`,
  which re-syncs Apple Calendar + trades). Assumption: read-only detail is the desired normal-view tap (no
  accidental intent edits). ⚠️ device-verify (tap opens; toggle flips + calendar re-syncs)
- **B6-CARD — PackageCard is presentation-only.** Replaced the dual `TraderChips` (Gives/Gets, each day
  shown twice) with one `● Name — dates` line per participant (days they GIVE; loop/swap conveys
  direction). No engine/data change — harness GREEN after. `TraderChips` still used by the inbox. Assumption:
  users read the give-only line correctly given the swap context. ⚠️ device-verify (clarity + no truncation at large Dynamic Type)
- **B6-ECB — hand-picked multi-recipient send.** Tap a candidate cell to toggle it into
  `selectedRecipients` (reuses the cell's existing `isSelected`/`onTap`/`selectionCheck`); a prominent
  "Send to Selected (N)" button sits alongside Bookends/All. Extracted `sendECB(to:)`; `requestAll`/
  `requestSelected` both call it; selection clears on a new search. ⚠️ device-verify (select 1+ → sends only to them)
- **B6-STATS — stats relocated to `TradeStatsBar`.** Moved the You+Company successful-trade metric out of
  the Home header into a slim bar pinned via `.safeAreaInset(edge:.bottom)` on the `TabView` (above the
  tab bar, all tabs). Same data source (`MetricsStore.globalEvents` + `Metrics.count` + `MetricPeriod`);
  tap = period menu. `HomeMetricsHeader` deleted (relocated, not duplicated). Assumption: `safeAreaInset`
  sits above the native tab bar without overlap on all devices. ⚠️ device-verify (placement, no overlap, period switch)

## Build 6 batch-3 assumptions (flag if wrong)
- **B6-VAC-DEDUP — overlapping strips were fighting (root cause of the July 26-29 bug).** The expanded
  schedule repeats a date window across multiple strips; the user's row appears in each. Two strips both
  covered Jul 3–Aug 2 but annotated DIFFERENT days as vacation (strip A: `L,V` on 28-29; strip B: `L,V` on
  26-27). `dedup`'s old rule (a working copy replaces an OFF copy, first-seen wins) kept strip A's plain
  working 26-27 and DISCARDED strip B's `L,V` → 26-27 showed working, 28-29 vacation (exact symptom).
  **Fix:** `dedup`+`mergeDuplicate` now UNION leave codes across duplicate dates (a `V`/`w` in any copy
  survives) while keeping the printed shift. Teeth proven: OLD `26:work 27:work 28:VAC 29:VAC` → NEW
  `26:VAC 27:VAC 28:VAC 29:VAC`. ✅ proven by test (B6-VAC-DEDUP). Verified both ingest paths
  (`RosterStore.syncMasterIfNewer`, `WebController`) share `parseAllWorkers`→`dedup` — one dedup, no
  second conflicting parser.
- **B6-UI-3 — Intents tally + cushion.** `IntentTallyBar(centered:)`; shown ONLY on the Intents segment
  (was on all trade tabs) and also under the Home "Mark Intents" button (placed UNDER, not inline — the
  full labels wrap on iPhone). Segmented control gained `.padding(.top,6)` off the top bar. Toggle renamed
  "Trade Picked Up". ⚠️ device-verify

## Build 6 batch-2 assumptions (flag if wrong)
- **B6-TOGGLE — Mutual/All is an instant cached flip.** The toggle used to re-run the engine. Now `reload`
  computes BOTH modes in one pass (`intentSolutions` ×2: All superset + Mutual subset), caches both in the
  `TradeFeedCache.Snapshot` (`packages` + `mutualPackages`), and the toggle just picks which cached set to
  show (`activePackages`). Re-runs only on intent/whatIf/max-people change. Cost: ~2× per data-change (not
  per toggle). ⚠️ device-verify (toggle is instant; counts correct)
- **B6-TAP — normal-view tap opens the FULL editor.** Per user, the `.off` tap now opens `DayIntentEditor`
  (intent + reason + note + significant + vacation), not the lighter read-only sheet. `DayDetailSheet`
  deleted. ⚠️ device-verify
- **B6-CARD-INBOX — inbox trade card uses the shared `TradeParticipantLines`.** Extracted the feed's
  per-participant line into a reusable view; the inbox ThreadView card now renders the identical
  `● Name — dates` format for both chains and 2-way. **Visibility note:** a circular trade you propose is
  sent per-participant with `fromID == me`, so it lands in the inbox **"Sent"** section (`outgoing`). If it
  seems missing it's the **sandbox** (see B6-PROPOSE) or it's under Sent, not "Needs your reply". ⚠️ device-verify
- **B6-PROPOSE — the robot send-gate is real; sandbox masks it.** `MessagingStore.sendRequest(to:)` blocks
  any recipient without `accountClaimed == true` (`blockedRecipient` alert) — 2-way, N-way, ECB, intents all
  funnel through it. In single-account sandbox testing the "robots" were published by the dev account, so
  they're `accountClaimed` and pass. In production only real accounts pass. NOT a code leak. ✅ gate confirmed by read
- **B6-STATS-2 — stats bar moved BELOW the tab bar.** `.safeAreaInset` on the TabView overlapped in-tab
  controls (the ECB Send button); the bar is now a sibling placed after the `TabView` in the root VStack,
  centered, so it sits under the Home/Trades buttons. ⚠️ device-verify (doesn't cover the home indicator awkwardly)
- **B6-SETTINGS — synced info + version moved to App Settings.** `SyncTag` deleted from Home; App Settings
  gained a top "App info" section (`AppInfo.version`/`.build` + last `ShiftStore.lastFetchDate`). ⚠️ device-verify
- **B6-CLEARNOTE — clear-note brush.** New `clearNoteMode` (eraser toggle right of the note-stamp field). While
  on, a tap in Mark-Intents ONLY clears that day's note (short-circuits before intent paint); mutually
  exclusive with the note-stamp. ⚠️ device-verify
- **B6-LUCKY — renamed to "More: 3+ & loops".** Same on-demand heavy 3+/circular search; label + sheet title
  + empty-state copy updated. Functionality unchanged. ✅ label-only

## How I'll stop doing this (process change)

**New rule: I never say "already there." I prove it.** Concretely:
1. **Prove-by-failing-test.** When I suspect a behavior exists, I write a test that asserts the *exact*
   behavior. If it passes, it was genuinely there (proven, not assumed). If it fails, it wasn't — and I
   build it. (This is exactly how F1's gap surfaced.)
2. **Enumerate against the type, not a sample.** UI that must cover a set is driven by a `CaseIterable`
   enum + a completeness test (e.g. `IntentBrushes` vs `OffIntentState.allCases`). A new case → test
   fails. No "I think the brush covers it."
3. **Per-feature sub-behavior checklist.** Each requirement is split into its atomic sub-behaviors in
   `ARCHITECTURE_MAP.md`/`SPEC_*`; each sub-behavior maps to a test ID or a `USER_TEST_LIST` item. "There
   is a brush" is not a feature; "every intent is paintable" is, and it has a test.
4. **This file is a gate.** Nothing moves from ⚠️/❌ to ✅ without a discharge (test or your device
   confirmation). I update it whenever I catch myself assuming.
</content>
