# Tower pricing: how it works, what was measured, what to do next

- **Date**: 2026-08-16
- **Status**: audit + design assessment. No pricing behaviour was changed. The
  only code change in this pass was deleting dead code (section 6).
- **Audience**: whoever picks up opponent-board pricing next.

Everything numeric below was measured on this repo's own corpus and is
reproducible with the snippets given. Read section 0 before trusting any of it.

## 0. The caveat that applies to every number here

`eval/README.md` and `eval/runs/2026-08-16-published-price-table.md` record that
**replays are not reproducible** — the same binary over the same corpus with the
same input library gave different price-floor rejection counts on repeat runs,
cause unidentified. The measurements in section 2 are single runs over
*already-written* JSONL logs, so they are stable as re-analyses of those files,
but the logs themselves came from a pipeline known not to reproduce. **Find the
nondeterminism before scoring any new pricing arm against an old one.**

## 1. How pricing actually works today

Two things look like price sources. Only one prices anything.

**`data/btdb2_costs.json` → `tracker/Sources/PriceTable.swift` is build-time
only.** Nothing in Swift reads the JSON; the tracker builds with
`swiftc -O Sources/*.swift -o tracker` and bundles no resources. The JSON's 22
base costs and 330 upgrade costs are compiled by `tools/gen_price_table.py` into
a handful of Swift constants. Of the 330 upgrade rows, exactly one number
survives into the binary: `maxLegalCumulative = 303100`, the top of the legal
cost lattice.

**The opponent's board is priced entirely by the learned sprite library:**

1. `SpriteHarvester.observe` (`tracker/Sources/SpriteHarvester.swift:80`) watches
   *your* HUD. A cash drop with eco flat is a tower purchase of exactly that
   amount — a send would raise eco, which is what makes it unambiguous.
2. `SpriteHarvester.update` pairs that spend with whatever changed on your board
   and calls `SpriteLibrary.learn` (`tracker/Sources/Sprites.swift:159`), storing
   `descriptor → cumulativeCost` in `tracker/sprites.json`.
3. `TowerWatcher.cost(of:)` (`tracker/Sources/TowerWatcher.swift:129`) prices each
   opponent site by nearest-descriptor match against that library, falling back
   to `PriceTable.medianTowerCost` ($475, flat) when nothing matches.
4. `TowerWatcher.revalue()` recomputes board value from the census every cycle —
   never accumulated, so a bad reading self-corrects.
5. `IncomeModel.noteTowerValuation` (`tracker/Sources/IncomeModel.swift:288`)
   clips the total to `cashCeiling` and feeds
   `opp_cash = earned − sendSpend − towerSpend`.

`PriceTable`'s entire live role is three bounds, not prices:
`isPlausibleCumulative` ($80–$303,100) rejects impossible learned prices,
`medianTowerCost` is the unpriced fallback, and `floorSpend`/`minPaidCost` gives
a site-count falsifier that holds regardless of what the library knows.

**Upgrades are priced only through the library, never through the table.**
`SpriteHarvester`'s `.upgraded` branch stores `base + price` as a new cumulative
entry, but only if the pre-upgrade appearance was already known
(`SpriteHarvester.swift:132`). An upgraded opponent tower whose appearance you
have never built yourself is priced at the flat $475 base-tier median.

## 2. What was measured

### 2a. The library is at the edge of collapse

`tracker/sprites.json` holds 5 entries: `$302 ×4, $1075 ×18, $383 ×22, $621 ×2,
$1049 ×13`. Pairwise descriptor distances, using the metric from
`SpriteDescriptor.distance`:

```
0.262  0.285  0.292  0.298  0.318  0.319  0.339  0.402  0.404  0.452
```

- `SpriteLibrary.matchThreshold` is **0.26**. The closest real pair
  (**$1,075 vs $383 at 0.262**) sits two thousandths above the merge line. One
  more observation landing between them averages those two prices into one.
- The threshold was justified by "different towers were never closer than 0.302"
  (`Sprites.swift:105`). **Four of ten** actual between-entry pairs are below
  0.302, so that separation does not hold on the library it produced.
- `BoardWatcher.upgradeDistance` is 0.30, *above* the 0.26 match threshold, so a
  post-upgrade descriptor can still land inside the pre-upgrade entry's match
  radius and be averaged into it rather than stored as a new state.

Repro:

```bash
python3 - <<'EOF'
import json
lib=json.load(open('tracker/sprites.json'))
def dist(a,b):
    hue=sum(abs(x-y) for x,y in zip(a['hueHist'],b['hueHist']))/2
    ring=sum(abs(x-y)+abs(p-q) for x,y,p,q in zip(a['ringSat'],b['ringSat'],a['ringBright'],b['ringBright']))/(len(a['ringSat'])*2)
    return (0.42*hue + 0.28*ring + 0.12*abs(a['darkFrac']-b['darkFrac'])
            + 0.10*min(1,abs(a['edgeDensity']-b['edgeDensity'])/0.35)
            + 0.08*min(1,abs(a['areaSamples']-b['areaSamples'])/max(a['areaSamples'],b['areaSamples'],1)))
print(sorted(round(dist(lib[i]['descriptor'],lib[j]['descriptor']),3)
             for i in range(len(lib)) for j in range(i+1,len(lib))))
EOF
```

### 2b. The match rate is implausibly high

From `eval/wired4_124547.jsonl` and `eval/wired4_152152.jsonl`:

| corpus | own sites priced | opponent sites priced |
|---|---|---|
| `124547` | 100.0% (2347 obs) | 53.1% (4473 obs) |
| `152152` | 100.0% (3686 obs) | 54.5% (1322 obs) |

A BTDB2 loadout is 3 monkeys and this account owns 4 (see the `btdb2-cost-table`
memory note), so most opponent appearances are towers you have never built. A
~53% hit rate is the matcher saying yes too often, not genuine coverage. 100% on
your own board — where early-match sites should be unpriced until learned —
points the same way.

### 2c. Pricing is the dominant term, not a refinement

Same logs, recomputed with today's $475 fallback in both arms (the `wired4` runs
predate the flat fallback and carry the old area-scaled $240, so the raw `cost`
field understates this):

| corpus | library-priced | flat $475 | ratio |
|---|---|---|---|
| `124547` | median $3,314 | median $2,375 | **1.54×** (1.16–2.36×) |
| `152152` | median $1,550 | median $950 | **1.63×** (1.00–2.26×) |

That difference propagates straight into estimated opponent cash. Pricing is not
a detail that can be defaulted away.

### 2d. The cumulative-upgrade path has never fired

All 5 library entries carry `learnedNote: "new tower"`. Zero entries were learned
from an `.upgraded` event across every session recorded so far, so the cumulative
cost mechanism — the thing that makes board value a pure function of the census —
is untested in real play.

## 3. Given, not measured

The library's stored prices are **taken as correct** for the purposes of the work
below; that is the project owner's stated position. Section 2a is about the
*matching*, not the prices — two correct prices can still be averaged into one
wrong one if the descriptors collide. Recorded here so the next agent knows the
prices are not the thing to re-litigate.

## 4. The classifier question

Asked: would it be better to classify tower crops to name + upgrade level and
price them from the table, instead of learning appearance → price?

**Assessment: right target, blocked on labels rather than on architecture.**

What it buys, and nothing else can: pricing stops depending on what *you* build.
The library can only ever price towers you have personally purchased. A
classifier plus the cost table prices a tower you have never touched. It also
removes entry-merging entirely — `name + tier combo → table lookup` is exact.

What it costs, from `data/btdb2_costs.json` under the 5-2-0 crosspath rule:

- **1,403 valid (tower, tier-combo) states**, mapping to 838 distinct costs. The
  label space is not 22 classes.
- **307 of 351** (tower, primary-path, primary-tier) groups are
  crosspath-ambiguous. A classifier that reads the tower and its main tier but
  not the crosspath still carries a **median $650 price ambiguity — 19.2% of that
  state's own cost**, worst case $4,200 (Super Monkey). So "classifier → exact
  price" is false unless crosspath is resolvable at capture scale (~150px sprites
  at 2560px wide), which is untested.

Repro for those figures: enumerate combos exactly as
`tools/gen_price_table.py:legal_cumulative_costs` does, then group by
`(tower, primary path, primary tier)` and take the cost spread within each group.

**The blocker is labelled data.** Assets are encrypted; the account owns 4 of 22
monkeys; reaching tier 5 requires affording it in-match. Blooncyclopedia is
reachable with a browser UA and has sprite art, but that is portrait art rather
than in-match pixels — rotated, animated, occluded, composited over varied map
backgrounds and lighting.

A classifier also inherits the detector: merged blobs spanning two towers, border
slivers and firing towers are the documented failure modes
(`btdb2-plate-detector` memory note), and a merged blob has no correct class.
Anything built here needs an explicit abstain output, not a forced 1-of-1403.

## 5. Recommended next work, in order

**(A) Self-supervised embedding to replace the hand-designed descriptor.**
Unblocked, needs zero labels, and targets the measured defect in 2a directly.
The current descriptor is 23 hand-designed dimensions (12 hue bins, 4+4 ring
stats, darkFrac, edgeDensity, areaSamples) and its failure is a metric failure.
Train an embedding contrastively on crops already extractable from the corpus:
positives are the same tracked site across nearby frames (the tracker already
supplies that identity via `TowerSite.id`), negatives are different sites in the
same frame. That optimises exactly the property the library needs. Price labels
stay; only the distance function changes.

Available without any labelling: **11,828 site observations** across the two
`wired4` logs, and 1132 + 1121 + 186 + 123 PNG frames under `tracker/out/`.

Pass/fail to write down *before* running: the between-entry minimum distance must
exceed the within-site maximum by a stated margin on held-out sites — the gap
that 0.262-vs-0.26 currently fails.

**(B) The wiki-transfer test — the cheap experiment that decides (C).**
Train on Blooncyclopedia sprite art for **Dart / Boomerang / Bomb / Tack only**
(the towers this account owns), then test on your own in-match crops of those
four. If wiki-trained features transfer to real captures, the classifier is
unblocked for all 22 towers without owning them. If they do not, no architecture
work rescues it and the answer is hand-labelling. Small, and it answers the
larger question before any commitment.

**(C) Classifier, only if (B) passes.** Predict `(tower, path, tier, crosspath)`
with an abstain class, price via `PriceTable`. Measure crosspath readability
separately — it is 19.2% of the price and the subtlest visual distinction.

**(D) Independent of all the above: score pricing on your own board.** Your own
sites are labelled by cash deltas. Hold them out, price them through the library
as if they were the opponent's, compare against actual spend. This is the only
ground truth for *pricing* that exists anywhere in the project, and nothing has
ever been scored against it. Blocked on section 0.

## 6. Dead code removed in this pass

All confirmed unreferenced by grep across `tracker/Sources`, `tools`, `probe`,
`calibrate` before removal, and the tracker still builds.

| symbol | file | note |
|---|---|---|
| `PriceTable.baseCosts` | generated | all 22 rows, never read. `medianTowerCost` etc. are computed by the generator from the JSON, which remains the source of record |
| `PriceTable.maxDiscount` | generated | never read; the 0.8 factor is applied in `gen_price_table.py`, not at runtime |
| `PriceTable.maxTowerCost` | generated | never read |
| `BoardWatcher.spriteDiameterAt2560` | `BoardWatcher.swift` | never read, and its comment claimed `TowerWatcher` scaled the fallback by it — that scaling was removed when the fallback went flat |
| `IncomeModel.canAfford` / `couldPossiblyAfford` | `IncomeModel.swift` | both defined, neither called |
| `BoardValuation.pricedShare` | `TowerWatcher.swift` | never read; `pricedSites`/`unpricedSites` are what the books and overlay use |

`PriceTable.minTowerCost` was **kept** — it is read, though only to build the
rejection message explaining why the floor is $80 and not $100.

Removals in `PriceTable.swift` were made by editing `tools/gen_price_table.py`
and re-running it, since that file is generated.
