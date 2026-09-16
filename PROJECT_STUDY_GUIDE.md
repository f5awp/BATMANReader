# DX Trader (repo: BATMANReader) — Interview Study Guide

> A deep, code-grounded walkthrough of the project: what it is, how it was built, how it
> actually works, and where its real limits are. Built from reading the source, the git
> history (330 commits, 2026-06-10 → 2026-07-19), and the in-repo docs.
>
> **How to read the certainty flags:**
> - **[FROM CODE]** — I verified this directly in the source or git history.
> - **[INFERRED]** — a reasonable read of the code, but the code doesn't literally say it.
> - **[NEEDS YOU]** — the code can't tell me the "why"; you need to supply it.

---

## 1. Project Overview

**What it is.** A native iOS/iPadOS app for **American Airlines flight dispatchers** (the "BATMAN"/dispatch-desk world; their union is **PAFCA**). It does two things: it **reads the dispatch master schedule** for you (your shifts, days off, vacation, qualifications), and it runs a **shift-trade marketplace and matching engine** on top of that schedule — finding legal, likely-to-succeed trades, ranking them, and coordinating the negotiation. The official schedule change still happens in the company system (ARIS/WorkNet); the app coordinates the *agreement*. **[FROM CODE]**

**The problem.** Dispatcher shift-trading is manual and error-prone. To find one legal trade you have to mentally check, for every candidate and every day: desk qualification, the 8-hour rest gap, valid shift start times, region/desk blacklists, and whether the other person even wants it — then coordinate over text/email. The app replaces that with automatic schedule reading, a rules-correct engine that only surfaces *legal* trades, and an acceptance score that puts the most-likely-to-succeed deals on top. **[FROM CODE — docs + engine confirm this framing]**

**Plain-English summary (zero-context version):**
> "It's an iPhone app for airline dispatchers who need to swap shifts with each other. Normally that means reading a giant schedule spreadsheet by hand and mentally checking a bunch of rules — who's qualified for which desk, whether there's enough rest between shifts, who actually wants the day. My app reads the schedule automatically, then searches the whole roster for trades that are actually legal and that both people are likely to accept, and ranks them best-first. It covers simple two-person swaps all the way up to circular trades where three or four people each cover someone else. Everything syncs across the shop through iCloud, with no server to run."

---

## 2. History & Timeline

Reconstructed from `git log` (all dates 2026). The pace is striking: ~330 commits in ~5.5 weeks, almost all solo. **[FROM CODE — commit dates]**

| Date | Milestone | Evidence |
|------|-----------|----------|
| **Jun 10** | Initial commit. | `c3f9173 Initial Commit` |
| **Jun 13** | **The "v2" ground-up rewrite.** ~20 commits in one day: new trade engine (router, intent-backed profile, history), HomeView intent calendar, TradesView, the "brick"/dispatch palette, Slack-style trade channel, packaged trade solutions (greedy-first + circular). | `d91227c v2 Phase 1: trade engine …` through `ea82983` |
| **Jun 14** | UX overhaul, step-based trade view, unified inbox cards; **build number bumped to 3**. | `e36e98f`, `1ef3d7a Bump build number to 3` |
| **Jun 17–18** | **Domain-driven refactor**: `Sources/` reorganized into `Domain/`, `Data/`, `Services/`, `UI/`; PR #1 merged. Round-3 spec written. | `a37a984 chore: reorganize codebase into domain-driven structure`, `0bbab54 Merge pull request #1` |
| **Jun 19** | **The scoring-engine day.** ~40 commits unifying everything onto one acceptance model: `TradeScore` / `packageLogProb`, best-first N-way DFS, variable score-floor curation, "I'm Feeling Lucky" master filter, qual-swap ↔ base-trade merge. This is where the engine became "one objective, used everywhere." | `60d3eb0 H1: unified TradeScore`, `837d7d5 A1: best-first at EVERY DFS node`, `0664948 Variable score-floor cap` |
| **Jun 20** | **Build 4 — first TestFlight beta.** | `14c7fa2 Changelog: label the current build as Build 4 (first TestFlight beta)` |
| **Jul 7–8** | Build 4/5: compact 2-way cards, image zoom, blacklist calendar, profileless-peer inference, engine-speed passes. | `6270f50 Build 4`, `ea9b084 Build 5` |
| **Jul 9–10** | **Build 6** + ECB Accounting ledger, screen magnifier, vacation leave-code fix. **App renamed to "DX Trader" (build 8).** | `0c674b9 Build 6`, `5469fcb Rename user-facing app name to DX Trader` |
| **Jul 11** | v2.2: auto-complete trades proven by the master schedule. | `94cc289` |
| **Jul 14** | **v2.3** + cross-device prefs sync + the **"U-OBJ" unified-objective refactor** (7 stages) — the flow, DFS, curation, and ranking all put onto the *same* objective. | `5b66826 v2.3`, `1b9c502…7f1d3ad U-OBJ Stage 1–7` |
| **Jul 15** | **Match Radar** (calendar-based opportunity surfacing) built in 11 stages; carryover-vacation model. | `1f0fec4…0f4d806 MATCH-RADAR Stage 1–11` |
| **Jul 16** | Match Radar **v4** (AUTO / Suggested / Day-Detail tiers), **standing conditional offers**, **ECB** stages A–E, N-peer broadcast. | `971878b v4 match classifier`, `1daf779 Build standing conditional offers`, `dea4387…2dc989e ECB Stage A–E` |
| **Jul 17** | Direct Messages (1:1 DM) platform, notification overhaul. | `fa2e418 DM platform …` |
| **Jul 18–19** | Trade Inbox UX, ECB ledger integrity (conflict flag, LWW merge, cap enforcement), Welcome overhaul, **target restricted to iOS-only**. | `b64512b Restrict target to iOS only`, `9aa9df7 ECB ledger integrity` |

**Visible pivots / refactors:**
- **A full "v1 → v2" rewrite** at the very start (a `v2` branch, everything re-scaffolded). The v1 state is only referenced as a "TestFlight beta baseline." **[FROM CODE]** **[NEEDS YOU: what did v1 do, and why rewrite so early?]**
- **Two big engine unifications**: `H1` (Jun 19, one `TradeScore`) then `U-OBJ` (Jul 14, that same score driving *flow costs, DFS pruning, curation, and ranking*). The commit messages show this was deliberate consolidation, not new features. **[FROM CODE]**
- **A brief revert battle** over profileless-peer inference: `3ab1ee2 Revert B4-5 … inferred blacklist over-pruned` immediately followed by `2d804af B4-5 re-enabled (user choice)`. **[FROM CODE]**

---

## 3. Requirements & Specs

**Core functional requirements (inferred from code + docs):** **[FROM CODE]**
1. **Read the master schedule automatically** — no manual import; parse the ARIS "Expanded Schedule" CSV grid into per-day shifts, days off, vacation, and quals.
2. **Let a user mark "intents"** on their calendar: *Trade away*, *Want to work* (pick up), *Keep* (hard: never trade), *Blackout/Must-be-off* (hard: never scheduled).
3. **Find legal trades** across the whole roster: 2-person swaps, multi-person packages, circular loops (A→B→C→A), qual-swaps (a 3-party bridge), and ECB one-way pickups.
4. **Enforce hard rules on every path**: only 0500/1300/2100 start times are tradeable; coverer must be off that day, qualified for the desk, and have 8-hour rest; no training desks (OJT/TR).
5. **Rank by likelihood of acceptance** (one score), best-first; filter out deals below a floor.
6. **Coordinate the deal**: propose → inbox → accept/counter/decline, with a broadcast channel and 1:1 chat.
7. **ECB ledger**: a YNAB-style accounting of credit owed/owned, capped at 144.
8. **Sync the whole shop** through iCloud.

**Technical specs / constraints:** **[FROM CODE]**
- **iOS / iPadOS only.** App deployment target **iOS 26.0**, widget extension **iOS 27.0**. Recently hard-locked (`SUPPORTED_PLATFORMS` iphoneos/simulator; no Catalyst/Mac/visionOS).
- **On-device-first, no traditional backend.** Persistence: **SwiftData** (roster, local), **UserDefaults + Codable** (settings/intents), **CloudKit** (public + private DBs), Keychain.
- **State management: `@Observable` singletons on `@MainActor`**, heavy work moved to actors/`Task.detached` with `Sendable` snapshots. Combine is explicitly avoided.
- **On-device AI**: `FoundationModels` (Apple's on-device LLM) on iOS 27+ for free-text classification and drafting, with keyword fallback.
- Bundle ID `DX.BATMANReader`, CloudKit container `iCloud.com.ervinlee.batmanreader`, App Group `group.com.ervinlee.batmanreader`.

---

## 4. Architecture

**High-level shape.** A layered SwiftUI app: **[FROM CODE]**

```
UI (SwiftUI views)  ── Home calendar, Trades/Find, Inbox, Channel, DM, Settings, Widgets
        │
Data stores (@Observable, @MainActor singletons)
        │  RosterStore, DayIntentStore, SettingsManager, MatchStore,
        │  Messaging/DirectMessages, TradeHistoryStore, StandingOfferStore, DispatcherDirectory
        │
Domain (pure, nonisolated, Sendable value types + logic)
        │  Schedule/ (ScheduleParser, Shift, ScheduleDiff, Holidays)
        │  TradeEngine/ (TradeMatcher, TradeRouter, OptimalMatcher, MinCostFlow, TradeEngineModels)
        │  Intents/ (TradeProfile, ShiftAvailability)
        │
Services (side-effecting)
        │  CloudKit{Roster,Messaging,TradeProfile}Service, CloudPush, EventKitManager,
        │  NotificationManager, AccountService, WidgetData
        │
CloudKit (public + private DB)  ·  SwiftData store  ·  iCloud
```

**Key architectural principle: "parse-once / query-many."** One master roster CSV is published to CloudKit's public DB; every client downloads it, parses it into a SwiftData roster, and derives its own schedule + matching pool locally. The heavy matching runs against in-memory `RosterEntry` snapshots, never live fetches. **[FROM CODE]**

**Data flow for a trade search:**
1. User marks intents on Home → `DayIntentStore` (persisted, published to their `TradeProfile`).
2. On Trades, a search calls `TradeRouter.packages(...)` / `intentSolutions(...)`.
3. The router builds a **`MatchContext` once** (roster maps, everyone's profiles, priors) and passes pure snapshots into three engines: **two-way explore**, **`OptimalMatcher` (min-cost flow)** for fewest-people reciprocal covers, and **`nWayRoutes` DFS** for circular loops.
4. Every candidate leg is gated by the single predicate **`TradeEligibility.canCover`** and scored by the single model **`TradeScore`**.
5. Ranked packages come back; the user taps **Propose**; the request lands in the recipient's inbox via CloudKit.

### The sync/real-time limitation — the actual mechanism **[FROM CODE, verified]**

**The app is not real-time. Cross-user data appears on a *foreground pull*, not a push.** Here is the exact mechanism:

- **The pull triggers live in `ContentView.swift`:**
  - Launch: `.task { … }` runs a fan-out of `refresh()`/`sync…()` calls.
  - **Foreground**: `.onChange(of: scenePhase)` → `if phase == .active { await foregroundRefresh() }`. `foregroundRefresh()` re-pulls messaging, DMs, roster, profiles, intents, ECB, and trade history. **This is what makes a peer's new trade/message appear — you brought the app forward and it re-queried CloudKit.**
- **Every fetch is a plain `CKQuery` / fetch-by-record-ID that re-reads the whole record set and merges locally.** There is **no** `CKDatabaseSubscription`-driven silent sync, **no** change-token/`fetchChanges` delta sync, and **no** polling timer.
- **Push exists but only notifies — it does not carry or fetch data.** `CloudPush.setup()` registers `CKQuerySubscription`s (auto-match, incoming request, ECB, @mention, DM, etc.) whose payload is just a user-facing `alertBody`. **There is no `AppDelegate` / `didReceiveRemoteNotification` anywhere in the project**, so a push physically *cannot* pull data in the background. It shows a banner; on tap it deep-links; the data itself only lands on the next foreground pull.

So the limitation is structural: **push = "hey, something happened"; the data catches up when you open the app.** This is a direct consequence of choosing CloudKit-with-manual-queries and skipping the subscription-delta plumbing. **[FROM CODE]** **[NEEDS YOU: was this a deliberate scope call ("good enough for a shop that checks the app often") or a deferred TODO? The docs mention "radar real-time push" as deferred, which suggests deliberate deferral.]**

### Roster sync is genuinely robust (worth highlighting) **[FROM CODE]**

The *roster import* — the one piece of shared data everyone depends on — is engineered carefully:
- **Server-time versioning**: the comparison key is CloudKit's `CKRecord.modificationDate`, not a client clock. A **two-step probe** fetches system fields only (`desiredKeys: []`) to check the version *before* downloading the multi-MB CSV asset.
- **Atomic generation swap**: new rows are inserted tagged with `importedVersion = version` while the old generation stays live; then a single `UserDefaults` pointer (`readerGeneration`) flips; then old generations are swept. Readers always see one complete generation — never a half-written roster.
- **Anti-wipe guards**: a CSV that parses to ≤1 worker is rejected; a transient empty fetch keeps the local cache (`FetchMerge.keepCacheOnEmpty`) — this was the fix for a documented "P0 data-wipe."
- **Conflict resolution**: **last-write-wins by `updatedAt`** for private/cross-device blobs (with a merge for DM read-state); deterministic whole-record overwrite by `recordName` for public records.

---

## 5. Key Design Decisions & Reasoning

| Decision | What the code shows | Why (reasoning) |
|---|---|---|
| **SwiftUI + `@Observable`, no Combine** | `@Observable @MainActor` singleton stores; async/await everywhere. | **[FROM CODE]** Modern, less boilerplate than Combine; matches the team's stated style. **[NEEDS YOU: personal preference / learning goal?]** |
| **CloudKit as the entire backend, no server** | Hand-written `CKContainer` services; SwiftData CloudKit mirroring explicitly *off* (`cloudKitDatabase: .none`). | **[FROM CODE + docs]** Free, Apple-run, no hosting bill for a volunteer tool; the audience is 100% iPhone/iPad (company iPads + personal iPhones), so "Apple-only" is a fit, not a limit. **[INFERRED from docs, confirm it's your reasoning]** |
| **JSON-payload records + a few flat queryable fields** | Private state stores whole models as JSON blobs with sidecar `…UpdatedAt` fields. | **[FROM CODE]** The data model can evolve without a CloudKit schema migration each time — only fields you *query/subscribe on* need a Console deploy. |
| **One eligibility predicate (`TradeEligibility.canCover`)** | Every path (2-way, intents, ECB, N-way) calls the same function. | **[FROM CODE — explicit comments]** "Because every path calls this exact code, the rules can never diverge between feeds." Correctness-by-construction. |
| **One acceptance objective (`TradeScore` / `packageLogProb`)** | The `U-OBJ` refactor put the *same* score into flow edge costs, DFS pruning, curation floor, and final ranking. | **[FROM CODE]** So the engine optimizes the exact thing the UI sorts by — no "the flow found a cover the ranker hates" mismatch. |
| **Min-cost max-flow for reciprocal covers** | `OptimalMatcher` builds source→giveDay→peer→backDay→sink; flow conservation *forces* balanced reciprocity (days-taken == days-given-back). | **[FROM CODE]** Balance becomes a graph invariant instead of a fragile post-hoc check; edge cost `= −1000·ln(legProb)` makes min-cost-flow return the *max-acceptance* balanced cover. |
| **Hand-tuned logistic score, not learned** | `TradeScore` weights are constants; the per-person prior ships at θ=0 (disabled). | **[FROM CODE]** Deterministic + harness-testable now; comments note it can be re-fit with logistic regression once enough accept/decline data exists. Displayed as *relative* "match strength," deliberately **not** labeled a probability. |
| **On-device AI, keyword fallback** | `ReasonClassifier` uses `FoundationModels` on iOS 27+, else keyword map. | **[FROM CODE]** Free, private, offline; graceful degradation on older OS. AI classifies a free-text reason into an urgency category that then influences ranking. |
| **iOS-only, hard-locked** | `SUPPORTED_PLATFORMS` iphoneos only. | **[FROM CODE]** **[NEEDS YOU: was there a Catalyst/Mac attempt that broke? The recent explicit lock-down commit suggests you hit cross-platform issues.]** |

---

## 6. Core Algorithm(s) — Deep Dive

The heart of the app is the **trade-matching + legality engine**. It has three cooperating solvers, all sharing one legality gate and one score.

### 6.0 The two shared foundations

**Legality gate — `TradeEligibility.canCover(...)`** (`TradeMatcher.swift`). Pure and synchronous (all data passed in). For a `(coverer, day)` pair it checks, in order: **[FROM CODE]**
1. Is this even a tradeable dispatch shift? (start hour ∈ {5,13,21}, not a training desk) — `TradeTiming.isDispatchShift`.
2. Not a self-declared carryover-vacation day; not past the coverer's relief horizon.
3. **Hard physical gates (always):** coverer is *off* that day, *qualified* for the desk (`DeskRules.qualified`), and *8-hour rested* vs their adjacent shifts (`rested`).
4. Computes **bookend** = does covering this day attach to the coverer's existing work (no "floating island" day off)? (`anchored`)
5. **Soft policy gates (optional):** openness, blacklists, availability pills, must-be-off, want-to-work — via `wouldPickUp`.

**Score — `TradeScore`** (`TradeEngineModels.swift`). The objective is **maximize P(the whole trade executes) = ∏ P(each leg accepted)**, worked in log-space so it's additive (which makes DFS pruning admissible). Each leg gets a logistic probability `legProb = σ(weighted features)` over a small feature vector: **[FROM CODE]**
- `intentLevel` (0/1/2 — did the giver mark trade-away, did the receiver mark want-to-work; **2 = "mutual 🔥"**), weight 1.5 each → a mutual leg dominates.
- `bookend` (+0.8) vs a **split penalty that shrinks as intent grows** (`splitBase 2.5 − splitRelief 1.1·intentLevel`): a split barely dents a mutual trade but wrecks a no-intent one.
- `timeValue = exp(−0.05·daysUntil)` — sooner is better.
- `needsQualBridge` (−1.2), `ecbValue` (+), and a tiny learned `personPrior`.

The package score = `Q · π · κ`:
- **Q** = geometric mean of leg probabilities (the "match strength" shown to users, 0–100).
- **π** = an **intent-aware people penalty**: an *all-mutual* loop of any size pays almost nothing (a unanimous 3-way can outrank a 2-person split), but every non-mutual leg raises the penalty, so "growth by coercion" sinks. This replaced a flat `0.85^(N−2)`.
- **κ** = coverage fraction ^2 (Trade Solutions only) — how much of your selected give-days this package covers.

Curation is by an **absolute floor** (0.32 normal / 0.07 under "Lucky"), not top-N.

### 6.1 Solver A — two-way explore
For one peer over a window: build `iGive` (your work days they can legally cover) and `iTake` (their work days you can legally cover), each gated by `canCover`, plus an ECB one-way list. Trade-*kind* is a two-sided filter — your "want a day-for-day swap" must resolve against their "want ECB" (both keyed by ISO day) or it's not a match. **[FROM CODE]**

### 6.2 Solver B — fewest-people reciprocal cover (`OptimalMatcher` + `MinCostFlow`)
This is the elegant one. To cover a set of give-days with the *fewest people* and *highest acceptance*: **[FROM CODE]**
- Build a flow graph: `source → giveDay(cap 1) → peer(takeCost) → backDay(cap 1, global) → sink`. Peer nodes have **no** source/sink edge, so **flow conservation forces days-taken == days-given-back** — balanced reciprocity is a graph invariant. Back-days are *global* unit nodes (you can only receive one shift per calendar date).
- Edge cost = `−1000·ln(legProb) ≥ 0`, so **min-cost max-flow returns the maximum-acceptance balanced cover**. Feasible iff `maxflow == give-day count`.
- **Branch-and-bound over subset size** finds the fewest-people count k\* (scanning each size *exhaustively* for its min-cost member), and rides along the best (k\*+1) subset as an alternative; the unified ranker picks. `MinCostFlow` itself is a textbook successive-shortest-paths (SPFA) solver; forward edges are *structurally tagged* so reading the assignment back is unambiguous even with real costs.

### 6.3 Solver C — circular loops (`nWayRoutes` DFS)
The most complex piece. A depth-first search for 3–4-person loops A→B→C→A where each person gives one shift and receives one (everyone nets the same hours). **[FROM CODE]** Key mechanics:
- **Seeds** = your give-away days, explored **best-first** (`bestFirstSeeds`: urgency, then soonness/qual friction) so the best loops surface *before* a hard route cap (60 normal / 100 Lucky) bites.
- At each node, the current giver hands one of *their* working days to a fresh coverer who passes `canCover`; **mutual receivers (they marked want-to-work) are explored first**.
- The path carries a running **`pathLogSum` = Σ ln(legProb)** — an exact prefix of the final score.
- **Admissible pruning**: `upperBoundMeanLog(partialSum, maxLegs)` computes the best score any completion could reach; if even a perfect finish can't clear the Lucky floor, the branch is cut. Because each remaining leg contributes `ln p ≤ 0`, the bound never over-prunes a valid route. (The people-penalty is deliberately *left out* of the bound — with the intent-aware penalty, adding mutual legs can *shrink* the penalty, so folding it in wouldn't be admissible.)
- **Close** only at ≥3 participants (a 2-cycle is just a 2-way swap, handled elsewhere). Never gives away a *Keep* day or a past-relief shift.
- Runs **off the main actor** (`Task.detached` over preloaded snapshots) and is **cooperatively cancellable** (`Task.isCancelled`) so re-searching supersedes rather than races.

### How the core changed over time (and why) **[FROM CODE — git]**
- **Jun 19 (`H1`)**: collapsed several ad-hoc scores into one `TradeScore` / `packageLogProb` — "the one scoring model."
- **Jun 19 (`A1`)**: made the DFS **best-first at every node** (not just seeds) and added the route cap, so bounding keeps the *best* loops instead of whatever the dictionary yielded first.
- **Jul 14 (`U-OBJ`, 7 stages)**: the big one — put that *same* objective into the **flow edge costs** and **DFS pruning bound**, not just the final sort. Before this, the flow/DFS optimized one thing and the ranker sorted by another. Also flipped the people-penalty to be **intent-aware** so unanimous multi-way loops stop being unfairly buried. **[INFERRED reason: the commits describe fixing a mismatch between what the solver found and what the ranker preferred.]**
- **Net-bookend rule** (`92a74f8`, `f56afca`): a bookend must stop counting if an adjacent give-away in the *same* trade breaks it (`removed:` set in `anchored`) — fixing "bad reciprocal give-backs."

### Plain-English version (for a non-engineer)
> "Think of it like a dating app for shifts. First there's a hard filter — a trade is only even *shown* if it's legal: the other person is off that day, is qualified for that desk, and has enough rest. Then everything that passes gets a score for how likely both people say yes — a day you *both* wanted trades highest, keeping people's weekends together beats splitting them, sooner beats later, and needing an extra person to make it work counts against it. The clever part is the bigger trades: for a group swap it builds a little flow network so the math guarantees nobody ends up working more or fewer days than they started with, and for circular trades — where I cover you, you cover them, they cover me — it searches loops but is smart about giving up early on paths that can't beat what it's already found, so it stays instant even across ~550 dispatchers."

---

## 7. Hurdles & How They Were Resolved

**Visible in code / git (evidence-backed):** **[FROM CODE]**
- **P0 data-wipe from empty fetches** → fixed with `FetchMerge.keepCacheOnEmpty` + rejecting ≤1-worker rosters. Root cause per docs: a Production CloudKit query on an *undeployed/un-indexed* field errors and returns empty, which naively looked like "no data → wipe."
- **Half-written roster / corrupt store** → atomic generation swap + self-heal that wipes and rebuilds a corrupt SwiftData store instead of crashing (`563876a Harden roster store: self-heal…`).
- **Solver/ranker mismatch** → the `U-OBJ` unification (§6).
- **Over-pruning profileless peers** → the `B4-5` revert-then-re-enable-by-user-choice saga.
- **Bad reciprocal give-backs / split weekends** → the net-bookend `removed:` rule and giver-side clean-give-away gate.
- **Search freezing the UI** → moved N-way DFS off-main + made it cancellable (`f3eb9c2 U-PERF`, `55e2e74 cancellable non-freezing search`).
- **Vacation ambiguity** → the "two-line resolveDay" leave-code model (`4f7bbed`), replacing an older dedup/mergeDuplicate pipeline.
- **Calendar event churn / duplicates** → `ScheduleDiff` surgical add/remove + a Reset button (`8aac7e6`).
- **A phone number bug**: iOS read a raw shift-time line in a calendar event as a phone number (`2f10dfd`).
- **Qual normalization** (`Ops` → `O`) so spelled-out master quals don't fail the single-letter desk gate (`47161f1`).

**Won't show up in code — you'll need to fill these in [NEEDS YOU]:**
- App Store / TestFlight review outcomes, rejections, or entitlement/privacy questions.
- CloudKit **production schema deploys** (the docs list several still *pending*: `tradeHistory`, `mentionedIDs` for @mention push, `DMConversation`/`DirectMessage`, auto-match notification fields). Which of these actually shipped to Production and which broke in the field?
- Real-user beta feedback from the dispatcher group (what confused people, what they asked for).
- The **why of the v1→v2 rewrite** and the **iOS-only lock-down**.
- Any data-privacy / union-politics considerations of putting the roster + contact directory in iCloud.

---

## 8. Strengths, Weaknesses & Tradeoffs (honest)

**Strengths:**
- **Correctness-by-construction**: one legality predicate + one score, called by every path. Genuinely hard to get rule-drift between features. This is the best thing about the codebase.
- **Real algorithms, not hand-waving**: a correct min-cost-flow formulation where reciprocity balance is a graph invariant, and an admissibly-pruned best-first DFS. This is legitimately strong for a solo side project.
- **Pure, testable core**: the domain layer is `nonisolated`/`Sendable` with data passed in, so it's unit-testable without CloudKit or the roster. There's an in-repo test harness.
- **Robust roster sync**: atomic generation swap + server-time versioning + anti-wipe guards is more careful than most apps bother with.
- **Pragmatic AI use**: on-device LLM with a deterministic fallback — private, free, and it degrades gracefully.

**Weaknesses / limitations:**
- **Not real-time (the headline tradeoff).** Data propagates on foreground pull; push only notifies. In a fast-moving trade window two people can act on stale views until someone re-foregrounds. Mitigated by staleness checks (`staleDays`) and LWW, but it's a real UX limit. **[FROM CODE]**
- **Platform lock-in (iOS-only).** No Android, no web. Fine *because* the audience is all-Apple, but it's a hard ceiling — reaching anyone outside that group means building the backend you deliberately avoided.
- **CloudKit-as-backend costs**: no server-side logic, no cross-user transactions, no atomic "first-accept-wins" guarantee except what you can approximate with LWW + record overwrites. Schema changes require manual Console deploys, and querying an undeployed field silently returns empty — a sharp edge that already caused a P0.
- **Hand-tuned score, thin data.** Weights are guesses (honest ones, and labeled "relative strength" not a probability), and the personalization prior ships disabled. Ranking quality is unproven at scale.
- **Solo-project seams**: version numbers drift across docs (meta says v1.9, release notes say v2.4/2.5), a hardcoded dev password, and a large "assumed-present / not-yet-device-verified" backlog. Nothing fatal, but it's one person moving fast.
- **Bounded solvers**: `OptimalMatcher` caps at 16 peers / 10 days / subset size 5, and the DFS caps routes at 60–100. Beyond the bounds it falls back to greedy — correct, but the "optimal" label is scoped.

---

## 9. What I'd Improve / What's Next

Prioritized by the weaknesses above: **[INFERRED — my recommendations]**
1. **Close the real-time gap** — the highest-leverage fix. Add an `AppDelegate`/`didReceiveRemoteNotification` and use the existing `CKQuerySubscription`s as *silent* content-available pushes that trigger a scoped `fetchChanges`, so data lands without a manual foreground. This is the single change that most improves the product and directly addresses the known limitation.
2. **Move to change-token delta sync** (`CKFetchRecordZoneChangesOperation`) instead of re-querying whole record sets on every refresh — cheaper, faster, and scales.
3. **Server-authoritative "first-accept-wins"** for ECB/broadcast claims. LWW can't truly arbitrate a race; a small CloudKit-based atomic claim (or a lightweight function) would remove double-accept risk.
4. **Fit the score from real accept/decline data** — the machinery is already there (`PersonPrior`, logit space); turn on θ and re-fit weights once enough inbox history exists.
5. **Harden the CloudKit deploy story** — a checklist/CI guard so you never query an undeployed field again; finish the pending Production deploys (trade history, @mention, DM).
6. **Reconcile versioning/docs** and retire dead scaffolding — small, but it's the difference between "hobby project" and "portfolio piece."
7. **Broaden the solver bounds or add an anytime algorithm** so large give-sets degrade smoothly rather than dropping to greedy.

---

## 10. 90-Second Spoken Summary

> "DX Trader is an iOS app I built for American Airlines dispatchers to swap shifts. The problem is that finding a legal trade is genuinely hard — you're reading a giant schedule grid and mentally checking desk qualifications, an 8-hour rest rule, valid start times, and whether the other person even wants the day, for every candidate. So the app does two things: it reads the master schedule automatically, and it runs a matching engine that only ever surfaces *legal* trades, ranked by how likely both people are to accept.
>
> Architecturally the thing I'm proudest of is that there's exactly one legality function and one scoring model, and every feature — two-person swaps, group covers, circular loops — calls them. So the rules can't drift between features. The engine itself is real: for group trades I use a min-cost max-flow formulation where reciprocity balance is actually a property of the graph, not a check I remembered to write; and for circular loops it's a best-first depth-first search with admissible pruning so it stays instant across ~550 people.
>
> The biggest tradeoff was going server-less on Apple's CloudKit. It's free and perfect for an all-iPhone audience, but it means the app isn't truly real-time — data syncs when you open the app, and push only notifies. If I kept going, closing that real-time gap with silent push and delta sync would be my first move.
>
> And the hardest bug taught me a real lesson: a CloudKit query on a field I hadn't deployed to production came back *empty*, and my code read empty as 'wipe the local data.' I fixed it with a guard that never lets a transient empty result destroy a good cache, plus an atomic, versioned roster import — and it made me a lot more careful about failure modes in a system I don't fully control."

---

## 11. Agentic-AI Learnings (for showing the skillset)

This project's own artifacts make it clear it was built **agentically** — the repo is full of the tells: staged commit messages (`U-OBJ Stage 5`, `MATCH-RADAR Stage 9b`, `B4-10`), "build + harness green" sign-offs, and a `Documentation/` folder of specs, an `ARCHITECTURE_MAP`, an `ASSUMED_PRESENT` ledger, and per-round spec files. That *is* the skillset. Here's how to frame it honestly as a first agentic-AI project: **[INFERRED from repo structure — but this is your story to tell]**

**What the repo shows you already did well:**
- **You worked spec-first, not vibe-first.** There are written specs with IDs (`S-ENG-9`, `U-OBJ`, `A1`) that the code and commits reference back to. Driving an agent from a written spec and tagging the work to it is exactly how you keep a large AI-built codebase coherent. That's a real, demonstrable practice.
- **You built a correctness ratchet the agent had to respect.** A single eligibility predicate, a single score, an `check_arch_map.sh` guard that forbids writing trade-type label strings anywhere but one function, and a test harness ("harness green" gating). When you let an AI write thousands of lines, invariants + guards + tests are what stop it from quietly diverging — and you set those up.
- **You kept an "assumptions are suspect" ledger.** `ASSUMED_PRESENT.md` literally says *"any time I said 'that's already there,' that is suspect and must be re-verified."* That is the single most important habit in agentic coding: distrusting the agent's claim that something is done, and verifying. Talk about this — it's gold in an interview.
- **You staged big refactors.** `U-OBJ` in 7 numbered stages, `MATCH-RADAR` in 11. Decomposing a risky change into small, individually-verifiable agent tasks (each building green) is the difference between an agent that ships and one that makes a mess.
- **You caught the agent over-reaching and reverted.** The `B4-5` revert-then-re-enable and the memory note "no speculative UI — don't add features the user didn't ask for" show you actively reined in scope creep. Reviewing and rejecting agent output is a skill.

**What you learned (and can say you learned):**
- **Invariants + tests are the steering wheel.** The way to control an agent across 330 commits isn't reading every line — it's making the important properties impossible to violate and cheap to check.
- **Distrust "done."** The most expensive bugs (the P0 data-wipe) came from an unverified assumption; the fix was a *verification discipline*, not just a code patch.
- **Failure modes in systems you don't own.** CloudKit's "undeployed field returns empty" is exactly the kind of edge an agent won't warn you about — you learned to design for the platform's failure behavior, not its happy path.
- **Small, tagged, reversible steps** beat big-bang generation.

**To strengthen the story before the interview [NEEDS YOU]:**
- Be ready to say *which* parts you designed vs. which the agent drafted, and how you decided. (E.g. "I specified the min-cost-flow reciprocity invariant; the agent implemented SPFA; I verified balance with harness tests.")
- Have one concrete story of catching the agent being wrong and how you knew.
- Be honest that it's a first agentic project and name what you'd do differently (e.g. tighter CI gates, less doc drift, earlier real-device verification).

---

### Appendix — where to look in the code

| Topic | File |
|---|---|
| Score / objective / features | `Sources/Domain/TradeEngine/TradeEngineModels.swift` (`TradeScore`, `LegFeatures`) |
| Legality gate, qual rules, rest, bookends | `Sources/Domain/TradeEngine/TradeMatcher.swift` (`TradeEligibility.canCover`, `DeskRules`, `QualSwap`) |
| Fewest-people reciprocal cover | `Sources/Domain/TradeEngine/OptimalMatcher.swift` + `MinCostFlow.swift` |
| Circular-loop DFS + orchestration | `Sources/Domain/TradeEngine/TradeRouter.swift` (`nWayRoutes`, `packages`, `intentSolutions`, `radarScan`) |
| On-device AI classification | `Sources/Domain/TradeEngine/ReasonClassifier.swift` |
| Schedule parsing (CSV grid, quals, vacation) | `Sources/Domain/Schedule/ScheduleParser.swift`, `Shift.swift`, `ScheduleDiff.swift`, `Holidays.swift` |
| Sync mechanism (foreground pull, push) | `Sources/App/ContentView.swift`, `Sources/Services/CloudPush.swift`, `CloudKit*Service.swift` |
| Roster atomic import | `Sources/Data/RosterStore.swift`, `Sources/Services/CloudKitRosterService.swift` |
| Trade profile / intents model | `Sources/Domain/Intents/TradeProfile.swift`, `Sources/Data/DayIntentStore.swift` |
</content>
</invoke>
