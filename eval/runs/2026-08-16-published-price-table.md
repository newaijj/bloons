# Run: wiring published prices in as a bound

- **Date**: 2026-08-16
- **Change**: `data/btdb2_costs.json` + generated `tracker/Sources/PriceTable.swift`
  (`tools/gen_price_table.py`). `SpriteLibrary` gained a bounds check and a
  purge-at-load; `SpriteHarvester` reports rejections; `TowerWatcher.cost(of:)`
  lost its area-scaled fallback; `IncomeModel` gained a census-floor falsifier.
- **Question**: the sprite library learns prices from your own cash, but nothing
  checks the result. Does a published price table catch anything the pipeline
  gets wrong — and can it price the opponent's towers?

## Second question first: no, and this is preregistered as dead

The table is keyed by tower NAME. `SpriteDescriptor` deliberately cannot produce
one. The obvious workaround is to snap a learned or estimated price to the
nearest legal cumulative cost, so that was tested before being built.

Lattice: base + upgrade prefixes under the 5-2-0 crosspath rule, **838 distinct
values**, median gap **$15** below $3000.

Null — how often an arbitrary integer lands near a legal value:

| within | share of all integers $100–$3000 | $100–$10000 |
|---|---|---|
| $1 | 17.8% | 12.4% |
| $5 | 54.5% | 40.4% |
| **$10** | **84.1%** | 68.1% |
| $25 | 97.7% | 94.0% |

All six entries in `sprites.json` landed within $10 of a legal value. Against an
84.1% null that is evidence of nothing. **Do not build a validator, corrector, or
confidence score on lattice agreement.** Exact in-game data did not change this:
the lattice is dense because the game has many cheap upgrades.

## What the table can do: bounds

Only the extremes are informative, and they are, because they are falsifiers
rather than estimators.

**Floor, on learned prices.** Replaying both labelled matches against a fresh
copy of the real library each time:

| corpus | at load | rejections, run 1 | run 2 |
|---|---|---|---|
| `20260816T152152` | dropped $24 | 4 ($24, $24, $35, $40) | **5** |
| `20260816T124547` | dropped $24 | 3 ($24, $40, $40) | **4** |

Three to five impossible prices per match. These are not pricing errors — they
are `SpriteHarvester` pairing a cash move to the wrong board change, which the
library was averaging into real entries in silence. The library ends every replay
entirely plausible (e.g. `[390, 433, 621, 947, 1047]`).

**Second finding, unplanned: the replay is not deterministic.** Run 2 of each
corpus used the same binary and the same input library as run 1 and produced a
different count. That contradicts the fidelity property established for the books
block, and it means **rejection counts must not be used as a metric to tune
against**. The known hash-seed nondeterminism is `SendDetector` iterating a
`Set`, which does not obviously reach the harvester, so the cause is unidentified.
This is the more important of the two results here: a pipeline that does not
reproduce cannot support any of the scoring the rest of `eval/runs/` depends on.

**The floor is not the sticker price — this was a bug, found by reading the
game's own upgrade text.** Monkey Business takes 5% off monkeys in radius; Monkey
Commerce adds 5% "stacking with up to 2 other Villages" — 20% at the limit. A
real Glue Gunner can cost **$80**. The first implementation rejected below $100
and would have deleted true observations of a village-discounted board.
`minPaidCost = 80` is the tested bound; `minTowerCost = 100` bounds nothing.

**Count falsifier.** `sites × minPaidCost > cashCeiling` says the census reports
more towers than any board could hold at any price, so the surplus is false
positives. Strictly stronger than the existing affordability clip, which can also
fire merely because the fallback price is too high. Did not fire on either replay
(both end with zero standing sites, which `--replay` cannot avoid — see the
README note on settle windows), so it is **implemented and unexercised**. It
needs a live match to earn its place.

## The fallback: a multiplier removed, not replaced

`TowerWatcher` priced unpriced sites at `$400 × (blob area / footprint)`, clamped
0.6–3.0, so $240–$1200. Tested against the learned library: area vs cumulative
cost is **r = −0.219, n = 6** — wrong sign, and nowhere near enough points to
read as a real negative. The multiplier carried no information, so its spread was
noise dressed as detail. Now flat `medianTowerCost = $475`.

n = 6 does not settle this. The right prior is the distribution of learned
cumulative costs once the library is large enough to have one — drawn from real
play, needing no table.

## Provenance of the numbers

All **330 upgrade costs read from the game itself** at v4.13, via the Monkeys
menu's `INGAME COST` field. Blooncyclopedia agreed on **324/330**. The six
exceptions are structural, not wrong values: five slots carry a retired upgrade
alongside the live one (so a tower/path/tier join picks wrong ~half the time),
and Monkeyopolis is `20000 + 5000 × villages absorbed`, not the flat $20000 the
wiki records.

**Base costs are wiki-sourced for 19 of 22** and flagged as such per-entry. The
tower menu never prices the tower; the in-match shop shows only loadout monkeys,
and this account owns four starters. Verified in-game: Dart $200, Tack $280, Bomb
$525, all matching. **Glue Gunner's $100 — which sets `minPaidCost` — is
unverified**, and it is padlocked, so verifying it costs a purchase.

## Next

1. **Find the nondeterminism.** It blocks everything else here: no rejection
   count, and no detector score computed the same way, means what it says while
   the same input can produce two answers.
2. Fix the harvester pairing the floor test exposed — 3–5 impossible prices per
   match is a rate, not a fluke.
3. Exercise the count falsifier on a live match; it has never fired.
4. Replace the flat fallback with the learned-cost distribution once n allows.
