# DX Trader — How trades rank, with worked examples

A companion to `DX-PRODUCT-BRIEF.md` (§4.3–4.4). This shows *concrete example trades*, **the score each
gets**, **why it's ranked where it is**, and **where it shows up** — in the normal Trade Solutions feed,
only under "I'm Feeling Lucky," or dropped entirely. The numbers are illustrative but computed from the app's
real scoring formula and its actual tie-break rules — faithful to shipping behavior, not made up.

---

## The signals (plain language)

| Signal | Meaning | Effect on rank |
|---|---|---|
| 🔥 Mutual intent | **Both** of you marked the day | Top priority |
| One-sided intent | Only one side marked it | Strong |
| 📖 Bookend | The day you receive attaches to the edge of your days off | Boosts |
| Split | The day you receive breaks up a weekend / stands alone mid-week | Penalized* |
| Sooner date | The trade is coming up soon | Small boost |
| Q — qual bridge needed | A 3rd qualified person must desk-swap to enable it | Small penalty; sorts qual-swaps lower |
| Fewer people | 2-person vs 3–4 person | Preferred |
| Past acceptance | This partner usually says yes | Tiebreak only |

*The split penalty is **intent-scaled**: if both people want the day, the split cost almost disappears; if
nobody marked it, a split is punished hard. That's why a *wanted* split can still rank well but a random
split falls off the bottom.

---

## The formula behind the sort (exact)

```
legLogit = 1.5·intentLevel                      // 0 = neither wants, 1 = one side, 2 = both 🔥
         + (bookend ? +0.8 : −(2.5 − 1.1·intentLevel))   // the intent-scaled split penalty
         + 0.8·timeValue                         // timeValue = exp(−0.05 · daysUntil)  (sooner ⇒ higher)
         − 1.2·(needs qual bridge)
         + 1.5·ecbValue
         + 0.2·personPrior                        // learned per-partner accept history (tiny)

legProb  = 1 / (1 + e^(−legLogit))               // the leg's accept probability, 0–1

packageScore = (geometric mean of the legs) × 0.85^(N − 2)   // N = people in the trade
```

The `0.85` per extra person makes **a smaller clean trade beat a bigger one, all else equal.**

### The floor — this is what decides *where a trade shows up*

| Score | Normal Trade Solutions | "I'm Feeling Lucky" |
|---|:--:|:--:|
| **≥ 0.32** | ✅ shown | ✅ shown |
| **0.07 – 0.32** | ❌ hidden | ✅ shown *(this is the "only in Lucky" band)* |
| **< 0.07** | ❌ never | ❌ never *(except the empty-feed fallback, which shows the best few if nothing clears)* |

> **Qual-swap trades are exempt from the floor** — they can still surface even with a low score, but they
> sort *lower* than clean trades of the same size.

**Worked leg scores** (days-until ≈ 7, so the soonness term ≈ +0.56):

| Leg profile | legLogit | legProb |
|---|---:|---:|
| 🔥🔥 mutual + bookend | 4.36 | **0.99** |
| 🔥🔥 mutual + split | 3.26 | **0.96** |
| one-sided + bookend | 2.86 | **0.95** |
| one-sided + split | 0.66 | **0.66** |
| no intent + bookend | 1.36 | **0.80** |
| no intent + split | −1.94 | **0.13** |
| no intent + split, **needs qual bridge** (−1.2) | −3.14 | **0.04** |
| one-sided + bookend, **needs qual bridge** (−1.2) | 1.66 | **0.84** |

---

## The example chart — score, reason, and where it shows

Nine candidate trades, all giving away **one** working day (so coverage is equal and we're watching *quality
+ shape* decide everything). Days out ≈ 7 unless noted.

| # | Trade | Score | Why it ranks there | Where it shows |
|:--:|---|---:|---|---|
| A | You ↔ Dana, 2-person, 🔥🔥 mutual, 📖 bookend | **0.99** | Best possible: fully mutual, clean bookend, fewest people. | ✅ Trade Solutions (top) |
| B | You ↔ Priya, 2-person, 🔥🔥 mutual, split | **0.96** | Fully mutual, so the split barely costs it; clean 2-person. | ✅ Trade Solutions |
| C | You ↔ Marcus, 2-person, one-sided, 📖 bookend | **0.95** | Clean 2-person bookend, but only one side marked it. | ✅ Trade Solutions |
| D | You ↔ Lena, 2-person, one-sided, 📖 bookend, **45 days out** | **0.92** | Identical to C but far off — soonness tiebreak drops it just below. | ✅ Trade Solutions |
| E | You ↔ Sam, 2-person, no intent, 📖 bookend | **0.80** | Legal and clean, but nobody marked it. | ✅ Trade Solutions |
| F | You → Ravi, **needs a qual bridge (Q)**, one-sided, 📖 bookend | **0.84** | Strong, but an extra person must agree → sorts *last among same-size* trades; floor-exempt. | ✅ Trade Solutions (Q-flagged, lower) |
| G | A→B→C→A loop w/ Kim & Omar, **3-person**, 🔥🔥 mutual, 📖 bookend | **0.84** | Fully mutual & clean, but the extra person (0.85 penalty + fewest-people rule) pushes it below the 2-person trades. | ✅ Trade Solutions |
| H | You ↔ Tess, 2-person, no intent, split | **0.13** | Nobody marked it *and* it splits a weekend — too unlikely for the normal feed. | ⚠️ **Only under "I'm Feeling Lucky"** |
| J | You → Wei, no intent, split, **needs a qual bridge** | **0.04** | Worst case: no intent, split, *and* needs a third person. Below even the Lucky floor. | ❌ **Dropped — never shown** (unless empty-feed fallback) |

---

## Result 1 — Trade Solutions feed (coverage-first ordering)

Trade Solutions ranks by: **fewest un-clean receive-days → fewest people → clean before qual-swap (same
size) → tier (🔥+📖 › 🔥 › 📖) → 🔥 count → bookends → sooner date → urgency.**

| Rank | Trade | Score | Why here |
|:--:|---|---:|---|
| 1 | **A** | 0.99 | Best tier (🔥 *and* 📖), 2-person, clean. Unbeatable. |
| 2 | **B** | 0.96 | Fully mutual & 2-person; the split costs almost nothing, so it beats one-sided trades. |
| 3 | **C** | 0.95 | Clean 2-person bookend; one-sided. |
| 4 | **D** | 0.92 | Same as C but 45 days out — soonness tiebreak. |
| 5 | **E** | 0.80 | Clean but no intent — under every intent-bearing trade. |
| 6 | **G** | 0.84 | Fully mutual, but **fewest-people** pushes the 3-person loop below the 2-person trades. *(The app's own rule: an all-mutual 3-person book sorts below an all-mutual 2-person split.)* |
| 7 | **F** | 0.84 | Qual-swaps sort **last among same-size trades** regardless of score — a bridge must agree. Q-flagged. |
| — | **H** | 0.13 | **Below the 0.32 floor → hidden here.** Appears only under "I'm Feeling Lucky." |
| — | **J** | 0.04 | **Below the 0.07 floor → never shown.** |

> Note G (0.84) outscores E (0.80) but sorts *below* it, because the sort keys (fewest people, clean
> receives) come before raw score — score is a late tiebreak, not the primary key.

---

## Result 2 — Intents feed (intent-first ordering)

The Intents marketplace ranks by: **most 🔥 mutual → fewest un-clean receives → fewest people → most
bookends → partner history → sooner.** Intent leads, and a pairing where **neither** side marked a day is
excluded entirely.

| Rank | Trade | Score | Why here |
|:--:|---|---:|---|
| 1 | **A** | 0.99 | Most mutual (2🔥) + cleanest + fewest people. |
| 2 | **B** | 0.96 | Same mutual count as A; loses only the bookend tiebreak. |
| 3 | **G** | 0.84 | Fully mutual, so it ranks *above* one-sided 2-person trades here — **intent beats headcount** in this feed (opposite of Trade Solutions). |
| 4 | **C** | 0.95 | One-sided — below every fully-mutual trade despite the higher score. |
| 5 | **F** | 0.84 | One-sided *and* needs a bridge → under the clean one-sided trade. |
| — | **D, E, H, J** | — | **Excluded by construction** — no mutual/marked intent, so the Intents feed never builds them (D & E are one-sided-or-none here for the marketplace seed; E, H, J have no marks at all). |

---

## The one thing to take away

Same trades, two feeds, **two orders** — on purpose:

- **Trade Solutions** answers *"cover my day with the least friction"* → **fewest people wins** (B, a
  2-person split, outranks G, a 3-person all-mutual loop).
- **Intents** answers *"where do our wishes overlap"* → **most mutual intent wins** (G jumps ahead of
  one-sided 2-person trades).

Both use the identical legality gates and identical scoring math underneath — only the **sort key** differs.
And in both, the **floor** is the gatekeeper: **≥ 0.32** shows normally, **0.07–0.32** shows *only under "I'm
Feeling Lucky,"* and **< 0.07** is dropped — so what you see is only what has a real chance of a *yes*.

---

*Scoring/rank logic verified against `Sources/Domain/TradeEngine/TradeRouter.swift` (`rankPackages`,
`rankIntentPackages`, `finalize`, floors `floorNormalProb = 0.32` / `floorLuckyProb = 0.07`, qual-swap floor
exemption, `emptyFallbackCount = 5`) and `TradeEngineModels.swift` (`TradeScore`: weights 1.5 / 0.8 / 0.8 /
1.2 / 1.5 / 0.2, split base 2.5, split relief 1.1, N-penalty 0.85, decay −0.05). Names (Dana, Priya, …) are
illustrative; the shapes, scores, and orderings follow the shipping engine.*
