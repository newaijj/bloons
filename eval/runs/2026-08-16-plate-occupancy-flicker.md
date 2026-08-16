# Run: plate-occupancy-flicker

- **Date**: 2026-08-16
- **Prereg**: `eval/prereg_plate_detector.md` (written before any number was seen)
- **Code**: `tools/plate_detect.swift`, scored by `tools/score.py`
- **Data**: `tracker/out/20260816T124547` (real 2-player match, temple map, user left)
- **Status**: **PASS on the preregistered rule**, with one prior claim retracted.

## Protocol actually followed

Plate seeded at t=42.0, verified **empty on both halves by eye** before running —
the prereg flagged that a plate containing towers makes them invisible by
construction. It was empty, so all 8 opponent towers arrive after the seed and
the denominator stays intact.

Parameters chosen on **t < 180s only**. Reported evaluation is **t >= 180s**:
checkpoints t=220 and t=330 (13 tower-presences over 8 unique towers), and the 4
purchases at t=215.4 / 267.6 / 268.5 / 296.3. Nothing tuned touched those.

Final parameters: `--plate-t 42 --occ-thresh 90 --occ-frac 0.90 --flicker-max 15
--window 2.5 --census-period 2.0 --step 8 --min-cells 20 --max-cells 4000
--max-aspect 2.0 --inset 2 --min-age 6`

## Held-out results

| arm | opp recall | opp precision | own arrival recall |
|---|---|---|---|
| baseline_shipped (frozen) | 0 / 13 | — | 0 / 10 |
| candidate (plate+flicker) | **10 / 13 = 76.9%** | **83.3%** | 4 / 4 |
| ablation (no flicker gate) | **10 / 13 = 76.9%** | 71.4% | 1 / 4 |
| placement null @ same site counts | median 7.7%, p95 23.1% | — | chance 72.2% |

Read rule: (a) recall >= 62.5% — **met**, 76.9%. (b) above the null's p95 —
**met**, 76.9% vs 23.1%. (c) precision >= 0.5 — **met**, 83.3%. No kill condition
tripped (max 7 sites at a checkpoint, bar was 40).

## Retraction

**The prereg asserted flicker is "the load-bearing axis". On the held-out
opponent board it is not, and I am withdrawing that claim.** The ablation with
the flicker gate disabled scores the *identical* opponent recall, 10/13. What
flicker measurably buys is:

- precision 83.3% vs 71.4% — a difference of **one blob** (5/6 vs 5/7), well
  inside noise at this sample size;
- own-board arrival recall 4/4 vs 1/4 — N=4, and 4/4 has probability 0.27 under
  the 72.2% chance rate, so this is **not significant** either.

The evidence says the work is being done by the plate, the persistence gate
(`--min-age`), and the aspect/inset gates. The earlier Koru measurement that
motivated flicker (2000+ occupied cells cut to 46) was real, but persistence
turns out to remove the same family — a dense bloon pack clears in seconds
whether or not it flickers. The two mechanisms are largely redundant, and that
was not anticipated.

## Mechanistic breakdown of every held-out miss (added after rendering overlays)

The "all three misses are merging" claim below was written from distances alone
and is **wrong**. Rendering the overlays (`eval/fail_t220.png`, `fail_t330.png`)
and tracing each miss through both arms gives three distinct causes:

| miss | cause |
|---|---|
| `tack_blue` @220 | **merge** — one 184x232 blob spans both tacks; the one-to-one matcher can only credit it to one, so the neighbour reads as missed |
| `orange_top` @330 | **flicker rejection** in the candidate (nothing ever within 158px). In the ablation it IS found — id=84 at 39px — but `firstSeen=325.3` and `--min-age 6` withholds it until 331.3, and the checkpoint is 329.5. A **1.8s latency miss** |
| `bomb_1` @330 | **flicker rejection** — the tower is mid-muzzle-flash in the frame. The ablation finds it |

So flicker is not the no-op the headline suggested: it is a **trade**. It costs
`bomb_1` (a firing tower) and buys `tack_blue`@330 (its extra rejection splits
the merged tack blob). Net zero recall at this sample size, which is exactly why
both arms scored 10/13 — the same total by different routes. That is a sharper
statement than "flicker does nothing", and it is the one the evidence supports.

The firing-tower risk flagged as step 4's open question is therefore **confirmed
real** and now has a named instance.

Also note `--min-age 6` sits close enough to the edge that 1.8s flips a result.
It was tuned on train, but its sensitivity was not measured, and should be.

## Failure mode found

All three held-out misses are **adjacent towers merging into one blob**, not
towers going undetected:

- `tack_blue` missed at t=220 (nearest 312px) but hit at t=330 — it sits ~100px
  from `tack_red`;
- `orange_top` missed at t=330, nearest detection 158px;
- `bomb_1` missed at t=330 — the four bombs are ~140-155px apart.

So recall is limited by blob splitting, not by sensitivity. That is a different
repair from anything in the prereg's contingency list, and it is the obvious
next experiment: watershed or peak-splitting on blobs whose area or extent
exceeds one footprint.

One persistent false positive at (1777,750), area 24 cells, appears at both
checkpoints. Real towers here measured 38-94+ cells, so `--min-cells 30` would
likely remove it — but that threshold would then have been chosen on the
reported block, so it must be validated on a new match, not adopted here.

## Caveats that bound all of the above

- **One match, one map, 8 unique opponent towers in ~4 spatial clusters.** The
  design resolves 0/13 vs 10/13 and nothing finer. No claim of the form "A is
  somewhat better than B" is supportable, which is exactly why the flicker
  comparison above is reported as inconclusive rather than as a small win.
- Own-board numbers rest on N=4 purchases and are not evidence on their own.
- 52 sites were confirmed on the opponent board across the match while only 8
  towers ever existed. Per-checkpoint precision is good; total site churn is not
  measured by this metric and should be.
