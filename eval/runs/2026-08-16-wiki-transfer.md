# Wiki-transfer test: can wiki tower art alone name a tower in an in-match crop?

- **Date**: 2026-08-16
- **Prereg**: `eval/prereg_wiki_transfer.md` (written and committed before the first
  test crop was scored)
- **Tool**: `tools/wiki_transfer.py`
- **Code revision**: `a95b6b7`
- **Data fingerprint**: sessions+filecount sha256 `81cea4ad8592a8f4`;
  `truth_own_124547.json` `bfff3b7c`, `truth_own_152152.json` `b2981b0e`,
  `btdb2_costs.json` `4e46fe5b`
- **Environment**: torch 2.13.0 CPU, torchvision ResNet-18 `IMAGENET1K_V1`,
  seed 20260816. Deterministic across re-runs (verified: the primary arm was run
  twice, before and after the background fix in section 5, and returned the same
  balanced accuracy and the same per-instance pattern).
- **Answers**: handoff arm (B), `docs/tower-pricing-handoff.md` section 5.

## 1. Verdict

**PASS on the preregistered read rule, and the pass is worth much less than it
looks.** Both halves of that sentence are load-bearing.

| arm | balanced acc | plain | p | note |
|---|---|---|---|---|
| **A_wiki (primary)** | **0.9167** | 5/6 | **0.00244** | PASS: >=0.75, p<0.05, 4/4 classes hit |
| B_shop_icons (control) | 0.7500 | 3/6 | 0.01782 | in-game icons do *worse* than the wiki |
| **dumb colour histogram** | **1.0000** | **6/6** | 0.00024 | **beats the CNN** |
| A_wiki, 22 candidates | 0.5833 | 3/6 | 0.00088 | vs a 22-way null of 0.045 |
| upgraded tier, 4 candidates | — | 2/2 | — | descriptive only |
| **upgraded tier, 22 candidates** | — | **0/2** | — | both confidently `NinjaMonkey` |

The read rule was met. The reason it does not mean what the handoff hoped is
line 3: **an 8x8x8 RGB histogram scores 6/6, better than ImageNet ResNet-18
features.** The four towers this account owns are a brown monkey, a
yellow-helmeted monkey, a pink drum and a dark blue cannon. They are separable on
coarse colour. So arm A measures "these four towers have different palettes", not
"wiki features transfer to in-match pixels". Any extrapolation from 4 classes to
the 22-tower / 1403-state target is not supported by this run — and the 22-class
expansion below shows the degradation directly.

## 2. What the test set actually is, and why it is the binding constraint

**6 tower instances. That is the entire name-confirmed in-match tower population
of this corpus.** Not 11,828 site observations — 6 towers.

| instance | class | session / map | how the NAME was established |
|---|---|---|---|
| `dart_114514` | dart_monkey | 114514 salmon_ladder | truth.jsonl place + cash 3900->3950 (+250 eco, -200 dart) |
| `boom_m1a` | boomerang_monkey | 124547 temple | $325 purchase t=59.2 |
| `boom_m1b` | boomerang_monkey | 124547 temple | $325 purchase t=167.9 |
| `boom_m2` | boomerang_monkey | 152152 desert | $325 purchase t=190.5 |
| `tack_koru` | tack_shooter | 115134 koru | truth.jsonl preview_not_placed |
| `bomb_koru` | bomb_shooter | 115134 koru | truth.jsonl preview_not_placed |

**No label came from looking at the sprite.** Identity is from cash arithmetic or
the driver's click log. Labelling in-match crops by eye would have supplied the
classifier's own answer from the same source being tested, so it was not done —
which is also why the opponent's boards, and the pre-placed towers in
`calibrate/out/20260816T005044`, contribute nothing here.

$325 is safe as a Boomerang identifier: it is the Boomerang base cost and **no
upgrade in `data/btdb2_costs.json` costs exactly $325** (nor exactly $525 for
Bomb). $200 is *not* safe — 13 upgrades cost exactly $200 — and both $200
purchases in `152152` are upgrades, not Dart Monkeys, because that match's
loadout was Boomerang/Bomb/Tack with no Dart in it.

Three facts about this corpus that constrain everything above:

- **No Bomb Shooter or Tack Shooter was ever *placed* anywhere in the corpus.**
  The two koru drag previews are the only tack/bomb pixels that exist, and both
  carry the game's red invalid-placement tint; the bomb one additionally sits
  under the DEFEAT overlay. They are degraded samples, recorded as such in the
  prereg before scoring.
- **`boom_m1a` and `boom_m1b` are genuinely two towers** (verified by rendering
  both at t=180), but they are the same tier on the same map and sit at cosine
  0.961 — near-duplicates. Effective independent N is closer to 5 than 6.
- Class is confounded with map: each class appears on its own background.
  Training is wiki art on transparent alpha over randomised backgrounds, so
  background cannot act as a class shortcut, but it is an uncontrolled nuisance.

## 3. Noise floor, computed before the run

Exact enumeration of all 4^6 = 4096 outcomes of an information-free classifier
(`tools/wiki_transfer.py --power`):

```
bal_acc 1.0000 -> p=0.00024      bal_acc 0.6667 -> p=0.03760
bal_acc 0.9167 -> p=0.00244      bal_acc 0.5833 -> p=0.09692
bal_acc 0.8333 -> p=0.00903      bal_acc 0.5000 -> p=0.16284
bal_acc 0.7500 -> p=0.01782      E[bal_acc|null] = 0.2500
```

Smallest resolvable effect at p<0.05 is 0.667 against a null mean of 0.25. **This
design can separate "works well" from "does not work" and nothing finer.** It
cannot estimate accuracy, and it cannot rank arm A against arm B on a small gap.

Balanced accuracy, not plain accuracy, is the headline on purpose: 3 of 6
instances are boomerang, so "always answer boomerang" scores 50% plain while
carrying zero information. Balanced accuracy sends that to 0.25, the null mean.
Arm A's prediction histogram was `{dart 2, boomerang 2, tack 1, bomb 1}` — not
degenerate.

## 4. Stability

Arm A across 6 augmentation seeds x {0, 12}px test-crop jitter (the crop centres
were drawn by hand off a rendered frame, so they are an experimenter degree of
freedom and had to be jittered):

- **12/12 runs meet the PASS bar (>=0.75). 0/12 reach the FAIL bar (<=0.50).**
- balanced accuracy min 0.9167, median 0.9167, max 1.0000, mean 0.9444.
- **`boom_m1a` is the only instance ever wrong** (8 of 12 runs). The other five
  are correct in all 12 runs at both jitter levels.

`boom_m1a` failing while the near-identical `boom_m1b` never does is not
explained; both are base-tier boomerangs on the same map at cosine 0.961. It is
recorded as unexplained rather than rationalised.

Run on the pre-fix backgrounds of section 5 the same sweep gave min 0.7500 /
mean 0.8611 with errors spread over all three boomerangs, so the background
defect was costing roughly 0.08 balanced accuracy and adding variance. Both
sweeps clear the PASS bar in 12/12; the fix tightened the result rather than
creating it.

## 5. A defect found and fixed mid-run

The first pass sampled "empty board" background patches at t=5 and t=20, which
land on the **loadout / hero-select menu** in three of the four sessions — so the
backgrounds were full of shop icons and hero portraits, i.e. pictures of towers
pasted behind the tower being learned. Caught by rendering the patches instead of
trusting the timestamps. Fixed to verified-empty board frames
(124547 t=42, 152152 t=36, 114514 t=120, 115134 t=63).

**The fix did not change the result** — arm A gave balanced accuracy 0.9167 with
the same single error (`boom_m1a`) both before and after. Recorded because
"the training data contained pictures of other towers" is exactly the kind of
defect that can manufacture a result, and because it makes the primary number a
verified re-run rather than a single measurement.

## 6. The controls, and what each one killed

**B_shop_icons — the wiki is not the weak link at base tier.** Training on the
in-game shop-panel icons (labelled by their printed price tags, not by eye)
scored 0.7500 / 3-of-6, *below* the wiki's 0.9167 / 5-of-6. The gap is one to two
instances and the prereg forbids reading a small arm-vs-arm difference as real,
so the claim made is only the negative one: **there is no evidence that
wiki-sourced art is worse than in-game art here.** The handoff's framing —
"portrait art rather than in-match pixels" — is not what limits this task at base
tier. (The shop icons carry a blue card background and no alpha, which handicaps
them; that asymmetry is why the difference is not claimed as a finding.)

**I_instrument — the features can do the task, so a null would have meant
something.** With no training at all, all 3 boomerang instances have a boomerang
as their nearest other instance (3/3); within-boomerang cosine runs 0.830-0.961
against 0.694-0.766 to the other classes. The measuring instrument works, so arm
A's number is about the wiki rather than about a broken feature space.

**C_null — the pipeline is not structurally biased.** Across all 4! = 24
permutations of the wiki-image -> class-name mapping, the identity mapping ranks
**1st of 24** (permutation p = 0.0417); the next best permutation scores 0.583.

**Dumb colour histogram — this is the control that reframes the whole result.**
An 8x8x8 RGB histogram over the same augmented wiki images, nearest centroid,
scores **6/6, balanced accuracy 1.0000** — strictly better than ResNet-18. The
CNN is not doing work the task requires. Reported as a baseline, not as a
candidate: the point is that the task is too easy to license extrapolation, not
that colour histograms should be shipped.

## 7. The scaling test: 4 candidates -> 22

Same 6 test crops, same wiki recipe, but the candidate set grows to all 22 base
towers. **No new labels are needed — only the number of ways to be wrong changes.**

```
  OK dart_114514  -> dart_monkey       (5/8 frames; 3 frames say EngineerMonkey)
     boom_m1a     -> dart_monkey       (5/8; 3 say boomerang_monkey)
  OK boom_m1b     -> boomerang_monkey  (8/8)
     boom_m2      -> SpikeFactory      (4/8; 3 say NinjaMonkey)
  OK tack_koru    -> tack_shooter      (8/8)
     bomb_koru    -> tack_shooter      (3/8; 3 say SpikeFactory, 2 say bomb_shooter)

  balanced_accuracy = 0.5833   plain = 3/6
  null over 22 candidates (200k draws): mean 0.0453, p95 0.2500   ->  p = 0.00088
```

Balanced accuracy falls **0.9167 -> 0.5833** when 18 distractor classes are added.
It remains far above the 22-way null, so there is real signal — but the drop is
the honest measure of how much the 4-class PASS owes to having only three ways to
be wrong. New confusions appear exactly where colour stops separating: bomb ->
tack/SpikeFactory, boomerang -> Ninja/SpikeFactory/Engineer, dart -> Engineer.

## 8. Upgraded tier (EXPLORATORY — added after the primary result was read)

The wiki carries **base-tier portraits only**, and the opponent's board — the
board this system exists to price — is mostly upgraded towers. `boom_m1a` after
its $198/$982/$400 upgrades is purple with a yellow X and looks nothing like the
yellow-helmeted base portrait.

| candidate set | result |
|---|---|
| 4 (the owned towers) | **2/2 correct**, 8/8 frames each |
| 22 (all base towers) | **0/2 correct** — both confidently `NinjaMonkey`, 8/8 frames each |

**The 2/2 was an artifact of having only three ways to be wrong.** Given a
realistic candidate set the same crops are misclassified, unanimously across
frames and with no boomerang vote anywhere in the top-3. This is the sharpest
single result in the run, and it points the opposite way to the headline: on the
case that actually matters for opponent pricing — an upgraded tower, chosen from
the full tower list — wiki base portraits do not merely degrade, they fail.

Still N=2, one class, one map, and added post hoc, so it is not a preregistered
finding and no p-value is quoted. It is enough to stop anyone reading section 1's
PASS as licence to build (C).

## 9. What this run does and does not settle

Settled:

- Wiki base-tier portraits **are** sufficient to name a tower in an in-match crop
  for the 4 towers this account owns, at base tier, at capture scale. Stable
  across seeds and crop jitter.
- The failure the handoff predicted — wiki portrait art being too far from
  in-match pixels — **did not happen** at base tier, and in-game art did no better.
- Labelled in-match data, not wiki data, is the scarce resource: 6 instances.

Not settled, and not addressable by more of this experiment:

- Anything about the other 18 towers. They cannot be tested; the account cannot
  build them.
- Anything about upgrade tiers or crosspaths, which is where the measured 19.2%
  median price ambiguity lives. The N=2 upgraded probe is a warning, not a
  measurement: it says the question is live, not that the answer is known.
- Whether the 4-class result reflects transfer or palette separation. The colour
  baseline says palette; the 22-class drop says the same.

## 10. Recommended next step

**Do not spend more effort on base-tier tower identity.** It works and it is the
easy part. The handoff ordered (C) after (B) on the assumption that (B) was the
risk; (B) passed, and the run says the risk moved rather than disappeared.

The decisive open measurement is **upgrade-tier and crosspath readability at
capture scale**, which the handoff already argues is where the money is (it
reports 307 of 351 (tower, path, tier) groups as crosspath-ambiguous at a median
$650 / 19.2% spread — that figure is quoted from the handoff, not re-derived
here; a quick independent enumeration disagreed with it, so whoever relies on it
should re-run it through `gen_price_table.py:legal_cumulative_costs` rather than
trust either number). That is untestable on wiki art alone,
because the wiki has no per-crosspath in-match sprites, and it is where pricing
error actually enters. It needs labelled upgraded towers on your own board, which
this corpus can generate cheaply: your own upgrades are already labelled to the
dollar by cash deltas.

Handoff arm (A), the self-supervised embedding, remains unblocked and is
untouched by this result.

## 11. Figures and logs

In `eval/runs/2026-08-16-wiki-transfer-logs/`:

| file | what it shows |
|---|---|
| `fig_wiki_vs_inmatch.png` | the 4 wiki portraits over the in-match crops. Boomerang's yellow helmet + red V and Tack's pink drum + crossed-hammers decal survive the viewpoint change; Dart is a plain brown monkey with no such mark |
| `fig_base_vs_upgraded.png` | one Boomerang as wiki portrait, as base in-match sprite, and as the same tower after upgrades — purple with a yellow X, nothing like the portrait |
| `fig_testset_48_crops.png` | the whole test set, 6 rows x 8 frames, in the order listed in section 2 |
| `arms_primary.log` | arms A/B/I/C, colour baseline, upgraded tier, 22-class expansion |
| `upgraded_wide_and_stability.log` | upgraded vs 22 candidates, and the stability sweep |
| `stability_prefix_backgrounds.log` | the stability sweep on the pre-fix backgrounds of section 5, kept for the comparison in section 4 |

## 12. Reproduce

```bash
tools/wiki_transfer.py --power                              # noise floor, no model
tools/wiki_transfer.py --run       --wiki <dir>             # arms A, B, I, C
tools/wiki_transfer.py --dumb      --wiki <dir>             # colour baseline
tools/wiki_transfer.py --robust    --wiki <dir> --seeds 6 --jitters 0 12
tools/wiki_transfer.py --expand22  --wiki22 <dir22>         # 22 candidates
tools/wiki_transfer.py --upgraded  --wiki <dir> [--wide]    # upgraded tier
```

Wiki images are the `000-<TowerName>.png` files from `bloons.fandom.com`, fetched
through the MediaWiki API (`action=query&prop=imageinfo`) with a browser
user-agent; the CDN serves them as WebP regardless of the `.png` name, which
Pillow reads directly. All 22 resolve. They are not committed here — refetching
is one API call and pinning someone else's art into this repo is not wanted.
