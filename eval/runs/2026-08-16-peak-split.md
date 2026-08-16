# Run: peak-split

- **Date**: 2026-08-16
- **Prereg**: `eval/prereg_peak_split.md` (written before any number was seen)
- **Status**: **mechanism confirmed, aggregate improvement NOT demonstrated.**
  One hypothesis falsified. Not recommended for shipping on this evidence.

## Parameters were fixed a priori, not tuned

The train block (t<180) contains no merged blob whose splitting changes a
checkpoint score — sweeping `--split-peak-sep` over 4/6/8 left train recall and
precision completely flat at 60%/60%. So the splitter's parameters **could not
be selected on train**, and were instead fixed from measured sprite geometry: a
tower is 100-150px across, which at step 8 is 12-19 cells, so seeds of distinct
towers are >= 6 cells apart; a seed sits >= 3 cells inside the sprite; only blobs
>= 200 cells are eligible, since single towers measured 24-179 cells.

This is a stronger position than tuning, not a weaker one: no parameter touched
the reported block, so no selection leak is possible.

## Held-out results (t >= 180)

| arm | opp recall | precision | sites ever | own arrivals |
|---|---|---|---|---|
| plate_full (previous winner) | 10/13 = 76.9% | 83.3% | 52 | 4/4 |
| **split_flicker_on** | 11/13 = 84.6% | 78.6% | 84 | 4/4 |
| split_flicker_off | 12/13 = 92.3% | **41.4%** | 108 | 1/4 |
| placement null (on) | — | median 7.7%, p95 23.1% | | |
| placement null (off) | — | median 23.1%, p95 46.2% | | |

## Reading against the preregistered rule

**(a) Mechanistic prediction — PARTIALLY satisfied.** The prediction was that the
blob spanning (1993,406)-(2177,638) at t=220 would split into TWO sites within
90px of (2094,469) and (2049,559).

- The *positional* half holds: both towers now have their own site, at 31px and
  28px. Before, one 184x232 blob covered both and only one could be credited.
  Visible in `eval/split_t220.png` — two green rings where there was one.
- The *cardinality* half fails: it split into **three**, not two. The extra
  fragment sits between the towers and scores as a false positive.

**(b) No regression, precision >= 0.5 — met** for `split_flicker_on`
(11/13, 78.6%).

**Stronger pass (recall >= 12/13) — not met.**

**`split_flicker_off` is KILLED** by the precision floor: 41.4% < 0.5.

## The aggregate change is within noise, by prior commitment

The prereg states: *"A one-tower change (10/13 -> 11/13) is INSIDE the noise and
proves nothing... Any recall change of exactly one tower is reported as 'within
noise' and is NOT claimed as an improvement."*

`split_flicker_on` moved recall by exactly one tower and precision by one blob.
**So this run does not demonstrate an improvement in either direction.** What it
demonstrates is that the named defect has a working fix — which is why the
mechanistic read was made primary in advance.

## Falsified: "splitting makes flicker droppable"

The prior hypothesis was that a real splitter would subsume what flicker was
accidentally providing, letting flicker be dropped and recovering the firing
tower for free. It does not. With splitting on and flicker off, site count goes
52 -> 108, precision halves to 41.4%, and own-board arrival recall collapses from
4/4 to 1/4. Flicker is still doing real work suppressing transients; splitting
addresses a different failure entirely. **Recorded as dead.**

## New defect introduced

Over-segmentation. Total sites confirmed across the match rose 52 -> 84 (+62%)
while only 8 towers ever existed. The splitter fragments sprites that should
stay whole. Tightening `--split-peak-sep` or requiring a deeper seed would
plausibly fix it, but **both would be selected on the reported block**, so
neither can be adopted here. That needs a second match.

## Verdict

Do not ship. The plate detector at `plate_full` settings remains the best
supported configuration. The splitter is a verified mechanism with an unresolved
cost, and the deciding evidence — whether the extra fragment is systematic or a
one-off — requires labelled data this campaign does not have.
