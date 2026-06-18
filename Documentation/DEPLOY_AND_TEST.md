# Ship Checklist — CloudKit deploys + device tests

> Everything code-buildable (without a decision) is **done, build-green, harness-green** (incl. all Round-2 items).
> What's left is **your console work** (CloudKit schema) + **on-device verification**. Work top-down.

---

## 1) CloudKit schema deploys (CloudKit Dashboard → your container → Schema)

In **Development** the fields usually auto-create the first time a record saves, but **Production needs an
explicit "Deploy Schema Changes to Production."** Add these, save a test record in Dev, then deploy to Prod.

| Record type | DB | Field | Type | Why |
|---|---|---|---|---|
| `TradeRequest` | Public | `candidateIDs` | String **List**, **Queryable** | qual-swap bridges discover a blast (`candidateIDs CONTAINS me`) |
| `TradeRequest` | Public | `perfectMatch` | Int64, **Queryable** | "Perfect Match" push (`toID == me AND perfectMatch == 1`) |
| `TradeRequest` | Public | `hasQualSwap` | Int64, **Queryable** | taker's qual-swap-response push (`toID == me AND hasQualSwap == 1`, on record update) |
| `MetricEvent` | Public | `payload` | String | global/team metrics on Home (H1) — type must exist before totals populate |
| `PrivateState` | **Private** | `privateNotes` (String), `updatedAt` (Date/Timestamp) | — | private-notes sync across your own devices (A3) |

> The push subscriptions (`CloudPush.setup()`) register on first launch and need the queryable fields
> above to exist, or those specific pushes silently won't fire. Everything else works without them.
> NOTE: `qualValues`, `qualSwapBlacklistDesks`, `reliefThrough` need **NO** deploy — they ride the
> `TradeProfile` JSON payload.

---

## 2) On-device test pass (the T-list — full steps in `USER_TEST_LIST.md`)

**New this release — verify these first:**
- **T38** Qual swaps surface automatically (Q-badge card → blast picker).
- **T32/T33** Qual-swap preferences + the inbox accept/choose/decline flow.
- **T34** Trade Solutions = packages only, with 📖/🔥 badges.
- **T35** "Just 2" tab (date → 2-person swaps + dispatcher filter).
- **T37** Relief Dispatcher — post-relief days blank in calendar, schedule, AND trading; survives re-import.
- **T44** Intents = one flat sorted list (no tier accordions).
- **T36** Inbox 🔥 when a request hits your intents.
- **T42** Email a trade to the dispatch DL (prefilled Outlook draft + blackout days).
- **T43** Attach a photo to a channel post.
- **T31** Reactions on posts/replies/chat.
- **T45** "What's New" sheet on first launch of a new build.

**Cross-device / needs ≥2 accounts or devices:**
- **T25** Private notes sync · **T39** Status sync · **T40** Global metrics · **T41** Qual-swap response push.

**Regression (still-green logic, confirm UI):**
- **T26** Want-to-Work overrides bookends · **T27** Invalid-trade banner + inbox badge · **T30** Search + pin people.
- ~~T29 Others' intents on calendar~~ — **REMOVED (R2-#2)**, was unrequested UI.

**Round-2 device-checks (this release):**
- **R-B** status + intents visible across 2 accounts (publish funnel + Home `refreshOthers` + peer status banner in two-way sheet).
- **#10** mass-action: no lag, overwrite asked once/session, AM/PM/MID inline + bigger brushes, "Shift Availability" label.
- **#10d/e** card fonts scaled up; circular handoff chips per-person colored.
- **#5** two-way: non-bookend days no longer mislabeled "bookend"; intent-color legend shows in two-way + ECB.
- **#2** exactly 3 calendar layers (Notes / Intent colors / Shift availability); availability pills toggleable.
- **Changelog** "What's New" now shows on **every launch** (per request), not once-per-build.

---

## 3) Parked by choice (not blocking)
- **I1** in-app guides refresh.
- **B5** images on replies/chat (channel posts done).
- **G2/G3** deep-links (the mailto flow doesn't need them).

---

## 4) Assumed-Present ⚠️ rows still open (all map to the above)
- Deploys: **#14** PrivateState · **#20** candidateIDs · **#21** perfectMatch · **#29** MetricEvent · **#30** hasQualSwap.
- Device-verify: **#6, 12, 17, 18, 19, 25, 26, 27, 31, 32** — covered by the T-list above.
- Everything else in `ASSUMED_PRESENT.md` is ✅ discharged.
