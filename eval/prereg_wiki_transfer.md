```yaml
slug: wiki-transfer
date: 2026-08-16
question: >
  Are Blooncyclopedia/Bloons-wiki tower images sufficient, on their own, to train a
  classifier that names a tower from an in-match capture crop — for the small set of
  towers this corpus actually has confirmed captures of?
  This is test (B) from docs/tower-pricing-handoff.md section 5, the experiment that
  gates whether the classifier arm (C) is worth building at all.
families: [tower-classification, pricing]

prior: >
  The handoff's stated expectation is that wiki art is "portrait art rather than
  in-match pixels — rotated, animated, occluded, composited over varied map
  backgrounds and lighting", and that this is what makes the classifier arm
  label-blocked. Two things found while building this test change the setup:
    - The wiki DOES carry a small number of actual BTDB2 gameplay screenshots
      (e.g. File:Dartmonkeybtdb2.png), not only portraits. They are too few to train
      on but they show the premise is not strictly true.
    - The distinguishing marks of two of the four towers survive the viewpoint
      change intact: Boomerang Monkey's yellow helmet with a red V, and Tack
      Shooter's pink drum with a black crossed-hammers decal, are both visible in
      the wiki portrait AND in the top-down in-match sprite. So there is a real
      mechanism by which transfer could work, and this is worth measuring rather
      than assuming.
  Nothing about the sprite library (Sprites.swift) or PriceTable is touched by this;
  the arm under test is a REPLACEMENT for appearance->price learning, not a tweak.

test_set: >
  6 tower instances, 4 classes, 8 frames each = 48 crops, 128px boxes at capture
  scale (2560px-wide frames).
    dart_monkey       x1  20260816T114514  salmon_ladder (bright green)  base tier
    boomerang_monkey  x3  20260816T124547 (x2, temple/tan), 20260816T152152 (desert)
    tack_shooter      x1  20260816T115134  koru (dark)
    bomb_shooter      x1  20260816T115134  koru (dark)
  IDENTITY IS ESTABLISHED WITHOUT LOOKING AT THE SPRITE. Every label comes from cash
  arithmetic or from truth.jsonl written by the driver at click time, never from
  "it looks like a boomerang". That is deliberate: labelling the test set by eye
  would leak the very knowledge the classifier is being asked to supply.
    - dart: truth.jsonl place event, corroborated by cash 3900->3950 (+250 eco,
      -200 dart) between t=157.1 and t=163.2.
    - boomerang x3: $325 purchases at t=59.2 and t=167.9 (124547) and t=190.5
      (152152). $325 is the Boomerang Monkey base cost and NO upgrade in
      data/btdb2_costs.json costs exactly $325, so among the four towers this
      account owns the price is unambiguous.
    - tack, bomb: truth.jsonl preview_not_placed events.

known_test_set_defects: >
  Recorded now, before any result, so they cannot be recruited afterwards to explain
  away whichever way it goes:
    - The tack and bomb instances are DRAG PREVIEWS over invalid terrain. They carry
      the game's red invalid-placement tint and a red outline, which saturates the
      sprite's true colours; the bomb one additionally sits under the DEFEAT overlay
      and is partly bloon-occluded. These are degraded samples and a miss on them is
      weaker evidence than a miss on a clean one.
    - 2 of the 3 boomerang instances are from the SAME session and map at the same
      tier, so they are near-duplicates. Effective independent boomerang evidence is
      closer to 2 than 3.
    - Class is confounded with map: each class appears on its own background. The
      training side is wiki art on transparent alpha, so background cannot be learned
      as a shortcut, but it remains an uncontrolled nuisance.
    - No Bomb Shooter or Tack Shooter was ever PLACED anywhere in this corpus. The
      two previews are the only tack/bomb pixels that exist.

arms:
  - name: A_wiki           # PRIMARY. This is the arm the question is about.
    what: >
      Train on the four wiki base-tower portraits (000-DartMonkey, 000-BoomerangMonkey,
      000-BombShooter, 000-TackShooter) ONLY. Augment each into 200 samples: random
      in-plane rotation, random scale to 45-85% of the box, random flip, mild
      brightness/saturation jitter, alpha-composited over background patches sampled
      from EMPTY board regions of this corpus. ImageNet-pretrained ResNet-18
      penultimate features (512-d, L2-normalised), nearest class centroid by cosine.
  - name: B_shop_icons     # isolates "wiki" from "portrait viewpoint"
    what: >
      Identical pipeline, but trained on the in-game shop-panel icons cropped from the
      captures themselves (labelled by their printed price tags, not by eye). If this
      also fails, the failure is the portrait->top-down viewpoint gap and is NOT
      specific to the wiki being a wiki.
  - name: I_instrument     # instrument check, no training, no labels used to fit
    what: >
      Cosine geometry of the 48 test crops among themselves. Are the 3 boomerang
      instances closer to each other than to dart/tack/bomb? If the features cannot
      even group same-class in-match crops, they cannot support ANY training source
      and arm A's number would be uninformative about the wiki.
  - name: C_null
    what: >
      Exact enumeration of balanced accuracy under an information-free classifier
      (each instance assigned a uniform random class), all 4^6 = 4096 outcomes.
      Secondary: all 4! = 24 permutations of the wiki-image -> class-name mapping,
      which holds the pipeline fixed and destroys only the labelling.

metric: >
  BALANCED ACCURACY over the 4 classes (mean of per-class instance recall), with one
  vote per INSTANCE decided by majority over that instance's 8 frames.
  Plain accuracy is rejected as the headline on purpose: 3 of 6 instances are
  boomerang, so a classifier that always answers "boomerang" scores 50% while
  carrying zero information. Balanced accuracy sends that degenerate answer to 0.25,
  exactly the null mean.

power:
  independent_units: >
    6 instances, NOT 48 crops. The 8 frames of an instance are the same tower a
    fraction of a second apart and are near-perfectly correlated; they measure
    within-instance stability and contribute essentially nothing to independent N.
    Counting near-duplicate boomerangs honestly, effective N is ~5.
  noise_floor: >
    Computed by exact enumeration BEFORE running (tools/wiki_transfer.py --power):
    balanced accuracy 0.667 -> p=0.0376; 0.750 -> p=0.0178; 1.000 -> p=0.00024.
    So the smallest effect this design can resolve at p<0.05 is 0.667 against a
    null mean of 0.25 — a very large effect.
  what_this_design_CANNOT_do: >
    It cannot estimate accuracy to any useful precision, cannot compare arm A against
    arm B for a small difference, and cannot say anything about the 18 towers this
    account does not own or about upgrade tiers/crosspaths. Any conclusion of the
    form "wiki training reaches roughly X%" is unsupportable and will not be made.
    A PASS here is evidence about a 4-way problem between visually very distinct
    towers; the real target is 1403 states, and a PASS does NOT transfer to it.

selection: >
  Arm A's configuration (backbone, augmentation ranges, sample count, centroid rule)
  is fixed HERE, before any test crop is scored, and is not tuned afterwards. There
  is no validation set to tune on — with N=6 any tuning would be tuning on the
  reported block. If a variant is tried later it is reported as exploratory, labelled
  as such, and does not replace the headline number.

read_rule:
  PASS: >
    balanced accuracy >= 0.75 AND exact p < 0.05 under the C_null enumeration AND at
    least 3 of the 4 classes get at least one instance right (so a near-degenerate
    predictor cannot pass).
  FAIL: >
    balanced accuracy <= 0.50.
  INCONCLUSIVE: >
    anything between, or any outcome where arm I shows the features cannot group
    same-class in-match crops — in which case the instrument, not the wiki, is what
    was measured, and arm A's number is withdrawn rather than reported as a null.

consequence: >
  PASS  -> handoff arm (C) is unblocked to the extent a 4-class result can unblock it;
           the next required experiment is upgrade-tier and crosspath readability,
           which is where the 19.2% price ambiguity lives, NOT more base-tower work.
  FAIL  -> wiki art alone is not sufficient; the honest options are hand-labelling
           in-match crops or the self-supervised embedding, handoff arm (A), which
           needs no labels at all.
```
