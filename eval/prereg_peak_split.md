```yaml
slug: peak-split
date: 2026-08-16
question: >
  Does splitting oversized blobs at distance-transform peaks recover the merged
  adjacent towers, and does it then make the flicker gate droppable — which
  would recover the firing tower for free?
families: [tower-detection]

prior: >
  Run 2026-08-16-plate-occupancy-flicker reached 10/13 held-out at 83.3%
  precision. Its three misses were traced to three distinct causes:
    - tack_blue@220: MERGE, one 184x232 blob spanning two towers ~100px apart
    - bomb_1@330:    FLICKER rejection of a tower mid-muzzle-flash
    - orange_top@330: flicker rejection in the candidate; in the no-flicker arm
                      it IS found but --min-age 6 withholds it 1.8s past the
                      checkpoint
  Flicker was shown to be a TRADE, not a no-op: it costs bomb_1 and buys the
  tack split at t=330. The hypothesis here is that a real splitter subsumes what
  flicker was accidentally providing, after which flicker can be dropped and
  bomb_1 returns.

arms:
  - name: prev_candidate
    what: last run's winner, 10/13 at 83.3%. Frozen, not re-tuned.
  - name: split_flicker_on
    what: prev_candidate + peak splitting. Isolates the splitter's effect.
  - name: split_flicker_off
    what: peak splitting with the flicker gate disabled. Tests the "splitting
          makes flicker droppable" claim directly.

power:
  independent_units: >
    13 tower-presences over 8 unique towers in ~4 spatial clusters. Binomial SE
    at this N is about 0.11, i.e. +/-1.4 towers.
  min_detectable_effect: >
    A one-tower change (10/13 -> 11/13) is INSIDE the noise and proves nothing.
    Two towers is marginal. This aggregate cannot adjudicate small differences,
    so the aggregate is NOT the primary read.

primary_read_is_mechanistic: >
  Because the aggregate cannot resolve one or two towers, the primary evidence
  is a specific pre-committed prediction about a named object:

    The blob at t=220 spanning (1993,406)-(2177,638) must split into TWO sites
    whose centres land within 90px of (2094,469) and (2049,559) respectively.

  That is a targeted prediction that a mechanism either satisfies or does not,
  and it is far stronger at N=13 than a recall delta.

selection: >
  Splitter parameters (peak separation, minimum peak depth, size above which a
  blob is eligible) are chosen on t < 180s only. Reported evaluation is
  t >= 180s. All other parameters stay at the previous run's frozen values.

read_rule: >
  PASS requires BOTH:
    (a) the mechanistic prediction above is satisfied at t=220; AND
    (b) held-out recall >= 10/13 (does not regress) with precision >= 0.5.
  STRONGER PASS additionally has recall >= 12/13, which would be outside noise.
  KILL if the merged blob does not split, or if precision falls below 0.5, or if
  recall drops below 10/13.
  Any recall change of exactly one tower is reported as "within noise" and is
  NOT claimed as an improvement.

decision: >
  PASS -> drop flicker if arm B >= arm A on both reads, then wire into
  BoardWatcher and re-baseline.
  KILL -> splitting is the wrong mechanism for overlapping sprites; the next
  candidate is a per-tower template/footprint fit rather than blob geometry.
```
