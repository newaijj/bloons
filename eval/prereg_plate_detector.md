```yaml
slug: plate-occupancy-flicker
date: 2026-08-16
question: >
  Does a state-based detector — per-half temporal plate, occupancy against it, and
  frame-to-frame flicker — find opponent towers that the current arrival-based
  detector misses entirely?
families: [tower-detection]

prior: >
  The shipped detector (BoardWatcher + TrackScanner absorption) scores 0/8 opponent
  towers and 0/10 own-board purchases on 20260816T124547. Two things are already
  measured and constrain this attempt:
    - `looksLikeSprite`'s darkFrac term is ANTI-correlated with being a tower
      (background darkness scores higher than real sprites), so any texture gate
      inherited from it starts poisoned. The plate detector drops it entirely.
    - Plate-difference occupancy ALONE does not work: on the Koru session a dense
      round-1 bloon stream held 2000+ cells above 90% occupancy, because bloons keep
      the path covered continuously. Adding frame-to-frame flicker cut that to 46.
      So flicker is not an optional refinement, it is the load-bearing axis, and the
      arm without it is already known dead — it is included only as the ablation.
  What differs from the mirror-plate idea tried earlier today: that one is dead. The
  board mirror is geometric but NOT photometric (directional lighting does not
  mirror; residual 30-35% on a map with relief), so the plate must be per-half and
  temporal. The mirror survives only as a way to move the PATH MASK between boards.

arms:
  - name: baseline_shipped
    what: current detector, already frozen at 0/8 and 0/10. Not re-run.
  - name: baseline_trivial
    what: >
      the dumbest rule that could work — every off-path connected blob that differs
      from the plate in >=90% of a window, no flicker test, no size/shape gate.
      This is the honest comparator: "beats zero" is a meaningless bar when zero is
      what a broken gate produces.
  - name: candidate_plate_flicker
    what: same pipeline, plus the flicker axis and a footprint-size gate.
  - name: placement_null
    what: >
      same NUMBER of sites the candidate emitted, placed uniformly at random in the
      board's off-path area, scored identically. Run 200+ draws. This is the control
      that catches "emit 40 blobs, 8 land near towers".

power:
  independent_units: >
    NOT the 18 checkpoint-instances. The same towers persist across checkpoints, so
    there are 8 UNIQUE opponent towers, and they are spatially clustered — 4 bomb
    shooters in a row along the bottom, 2 tack shooters adjacent — so roughly 4
    independent spatial clusters. Own-board: 10 purchases, of which an unknown
    subset are upgrades that cannot produce a new site.
    Held-out block (t>=180) carries 8 tower-presences over 2 checkpoints and 4
    purchases.
  min_detectable_effect: >
    With 8 units, binomial SE at p=0.5 is 0.18, so this design resolves 0/8 vs 6/8
    and CANNOT resolve 4/8 vs 6/8. Only large effects are readable. Any conclusion
    of the form "candidate A is somewhat better than candidate B" is unsupportable
    here and I will not make one.

selection: >
  Thresholds (occupancy cutoff, flicker cutoff, window length, min blob size) are
  chosen ONLY on t < 180s of 20260816T124547 plus the two Hero Challenge own-board
  sessions. The reported evaluation is t >= 180s: checkpoints at t=220 and t=330,
  and the 4 purchases at t=215.4, 267.6, 268.5, 296.3. Nothing tuned touches those.

read_rule: >
  PASS requires ALL of:
    (a) held-out opponent checkpoint recall >= 5 of 8 tower-presences at t=220/330;
    (b) candidate recall strictly above the 95th percentile of the placement null
        drawn at the candidate's own site count;
    (c) precision >= 0.5 on the held-out checkpoints, i.e. it is not achieving
        recall by carpeting the board.
  KILL if held-out recall <= the placement null's median, or if the candidate emits
  more than 40 sites at any checkpoint (carpeting).
  AMBIGUOUS (recall 1-4 of 8, or precision 0.2-0.5) is recorded as ambiguous and NOT
  written up as a win; the design cannot resolve it.

decision: >
  PASS -> wire the plate detector into BoardWatcher, re-run the full baseline, and
  move to step 4 (the firing-tower flicker risk).
  KILL -> record which arm died and at what stage. The specific thing I would then
  suspect is the flicker axis failing on FIRING towers, whose turrets animate; the
  repair is the path mask as a third axis, which is a different experiment.
  AMBIGUOUS -> the honest next step is more labelled matches, not more tuning.
```

## Structural risk identified before running

A plate seeded from a frame that already contains towers makes those towers
**invisible by construction** — they are part of the plate. The opponent already has
2 towers at t=60, and the census only starts around t=41. So the plate must be
seeded from the earliest in-match frame with an empty board, and if no such frame
exists in the recording, the towers standing at seed time are a structural zero and
must be excluded from the denominator rather than counted as detector misses.

I will check for an empty-board seed frame FIRST and record what I find, because
this determines whether the denominator is 8 or fewer.
