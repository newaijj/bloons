# Run: replication on match 2 (20260816T152152)

- **Date**: 2026-08-16
- **Data**: desert/oasis map, opponent PERSIAN, user left, user won. 1121 frames,
  301.9s, median gap 0.250s (the `--fps 8` fix landed).
- **Design**: pure replication. Parameters frozen from the previous two runs.
  **Nothing was tuned on this session and nothing may be.**
- **Plate seed**: t=40.0, verified empty on the opponent board by eye.

## Headline: the detector replicates out of sample

| | match 1 (temple, held-out t>=180) | match 2 (desert, whole match) |
|---|---|---|
| no-split | 10/13 = 76.9%, precision 83.3% | **9/11 = 81.8%, precision 90.0%** |
| with splitter | 11/13 = 84.6%, precision 78.6% | 9/11 = 81.8%, precision 90.0% |
| placement null p95 | 23.1% | **63.6%** |

New map, new opponent, zero tuning: 81.8% recall at 90.0% precision. That is the
result worth having.

**But match 2 is WEAKER evidence than it looks.** The opponent built only 3
towers all match, so random placement scores a median of 45.5% and a p95 of
63.6%. Recall clears the null, but by ~18 points rather than match 1's ~54. A
board with few towers is an easy board to hit by accident.

## The splitter did nothing here

Both arms produced **identical** opponent output — 12 sites ever, same hits, same
misses. The splitter never fired on their board, because `--split-min-cells 200`
was derived from match 1's geometry and this map's blobs peak at 94 cells.

So after two matches the splitter is **still untested on opponent data**, and its
eligibility threshold is now known not to transfer between maps.

Meanwhile its cost replicated exactly: own-board sites went 36 -> 63 (**+75%**),
against +62% on match 1. Consistent over-segmentation, no demonstrated benefit.
**Recommendation stands: do not ship the splitter.**

## The firing-tower failure is now the dominant failure mode

Both of this match's misses are the *same tower*: `red_hero`, which has a visible
muzzle flash in essentially every frame. It is HIT at t=140 and t=260, MISSED at
t=80 and t=200. Its site is repeatedly destroyed and recreated — `firstSeen`
resets from 133.9 to 250.6 — and when it does appear it is at the size floor
(area 20-25 cells against 74-94 for the stable towers).

That is the same mechanism as match 1's `bomb_1`, now with four observations
instead of one. Across both matches, firing-tower rejection accounts for 3 of the
5 total misses; merging accounts for 1; latency for 1.

**The next experiment should target firing towers, not splitting.**

## A defect in my own metric

The own-board arrival metric is **degenerate at these site counts** and must not
be read:

| arm | own recall | chance |
|---|---|---|
| no-split | 71.4% | 86.1% |
| split | 100.0% | 97.3% |

With 36-63 sites emitted against 7 purchases, a purely temporal match is almost
guaranteed. The metric cannot discriminate and one arm scores *below* chance. The
fix is to require a positional match as well as a temporal one, the way the
opponent checkpoint metric already does. Until then, own-board arrival recall
should be dropped from reporting rather than quoted.

Also noted: `own_truth.py` writes its summary to stderr, so redirecting with
`2>&1` corrupts the JSON. Cost one debugging cycle.

## Verdict

- Plate detector at the frozen no-split settings: **replicated, ship-ready.**
- Splitter: **not justified.** Does nothing where the merge occurs on a second
  map, costs +75% churn.
- Firing towers: **the priority.**
- Own-board arrival metric: **broken, fix before reuse.**
