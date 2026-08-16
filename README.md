# BTDB2 opponent income tracker

Live reconstruction of your opponent's economy in Bloons TD Battles 2, as a
click-through overlay on the game window.

Reads only pixels the game already draws on your screen. No memory access, no
packet capture, no input automation. The game binary ships a `Cash/Lives
Injection` anti-cheat check — staying screen-only is deliberate.

## Why reconstruction

The HUD shows your cash and eco, and both players' lives and names. It does
**not** show the opponent's cash or eco. But their sends land on *your* track,
and a round's natural bloon composition is known, so anything on your track that
the round doesn't schedule came from them. Each send has a cost and eco gain
readable off the send cards, and eco pays on a fixed tick — which is enough to
rebuild their books.

## Which side am I on

Decided at runtime, from pixels, before anything is attributed to anybody.

This is not a robustness nicety. If the side is wrong nothing errors: the send
detector scans what it believes is your track, actually reads the opponent's
incoming bloons — which are *your* sends — and books them as theirs, while the
tower watcher bills them for your towers. The output stays entirely plausible
and is inverted.

**The signal is the panel.** The tower shop and send cards render as one column
against the outer edge of the side you own; the opposite outer column is bare
map. Counting digit-bearing text hits below the top bar across the 20
calibration frames:

| | text hits |
|---|---|
| empty side | **0 in 20 of 20 frames** |
| panel side | 1–5 in 17 of 20 |

No false positives on the empty side, and it reads from the first frame, before
any bloon exists — which the persona name can't do reliably, since stylised
names OCR badly (`1vegetableninja` → `OOl IVEGETABLeninJA`). Three of those 20
frames read zero on *both* sides, so a single frame is never a decision:
evidence accumulates over ~3s and the call is latched once. On the calibration
set it latches on frame 2.

**Mirroring is a swap, not a flip.** The captured frame isn't symmetric — there
is ~155px of dead space at the left edge with no counterpart on the right, where
the panel runs flush to the border. So paired regions (both tracks, both lives,
both names) are swapped, which is measured truth. Arithmetic flipping is used
only for chrome with no measured partner — the send panel, which is laid out
against the window edge.

Whether the **top bar** mirrors too is settled by reading rather than assuming:
at latch time the round counter is probed at both candidate positions, and
`ROUND n/40` is distinctive enough that only the correct one parses.

**Only during a match.** The side cannot be decided from a menu, and the code
refuses to try. A run latched `right` at t=5.8s — no round, no cash, pure menu
chrome — for a match that did not start until t=48.8s, and the player was on the
**left**. Forty-three seconds of confident, inverted books. So detection now
waits for a live board, established side-independently: the round counter reads
`n/40` in exactly one of two known positions and in neither menu nor lobby, and
the two lives readouts are mirror images so testing both covers either
orientation. Which round position hit also yields the top-bar answer for free.
Evidence gathered outside a match is discarded, not merely ignored.

**The latch is a hypothesis, not a fact.** After latching, the panel columns are
re-checked every few seconds. Four consecutive conclusive disagreements overturn
the call, discard the books, and re-point every scanner — because inverted books
are worth less than none.

**Confirmed on a real mirrored board** (session `20260815T232736`, 10 frames).
The panel does move with the side: on a left board the tower shop and send cards
render in the left column. Replaying those frames with detection unaided gives
**left=8, right=0**, latching on frame 3 — the same clean zero-false-positive
separation measured on the right-side set, on a different map. The menu gate was
the entire defect; given match frames the signal was never in doubt.

The mirrored region layout checks out against those pixels on every count:

| | expected | observed |
|---|---|---|
| names | swapped | `me="BEHIND BOXES"` (left), `opp="AYDinFiSH"` (right) |
| tracks | swapped | yours left, theirs right |
| send panel | flipped to x 0–0.074 | panel occupies exactly that column |
| cash / eco / round | **not** mirrored | all three read correctly in place |

So "swap the paired regions, flip only unpartnered chrome, and probe the top bar
rather than assuming" was right in each part. `--side left` is no longer needed
as a workaround.

### If a mirrored match happens, it gets saved

The tracker otherwise persists nothing but the CSV — `Frame` wraps a buffer
ScreenCaptureKit recycles the instant the callback returns, so by the time you
know a run was interesting there is nothing left to look at. That is fine for
the ordinary case and useless for the one case there are no captures of.

So frames are written to `tracker/out/<session>/`. **Every** latch leaves a short
burst behind, right-side included — the wrong call that started all this armed
nothing, because the dump only fired on outcomes already suspected of being
wrong, which is exactly the set a false negative is not in. Anomalies escalate
that burst to the full budget: side latches **left**, detection **cannot decide**
20s into a live match, or the latch is **overturned** by post-latch verification.
Six frames a second apart at the moment of interest, then one every 15s, capped
at `--dump-max`. Encoding happens off the capture queue.

Each dump carries a `notes.txt` recording the detection evidence and every
resolved region, so the frames are interpretable later without the console
output that produced them. Filenames match the calibrate tool's convention,
so a dump replays straight back:

```bash
./tracker --replay out/<session>
```

That matters because a mirrored layout is exactly the case whose region
constants would need re-measuring against real pixels, and `side=left` in a CSV
column is not a pixel.

### The overlay follows the side too

It sits in a bottom corner of the game window, always on the **opponent's** half
— a reconstruction of their books is worth less than an unobstructed view of
your own defence. Bottom-left when you are on the right, bottom-right when you
are on the left. `tick()` re-applies the position every second, so the panel
relocates itself within a second of the side latching rather than needing to be
told. Before the latch it uses the right-side default, which is bottom-left.

Send card cost/eco values scale with round number, so they're re-read live
rather than hardcoded.

## Running

```bash
cd tracker && ./tracker
```

- `--headless` console only, no overlay
- `--log run.csv` per-second CSV including raw track counts, for tuning
- `--replay <dir>` push recorded PNGs through the live pipeline
- `--fps N` capture rate (default 10)
- `--side left|right` skip panel detection and force an orientation
- `--sprites <path>` learned tower prices (default `sprites.json` beside the binary)
- `--dump auto|always|off` save frames for later study (default `auto`)
- `--dump-max N` frame cap per session (default 20, ~4MB each)

Recording a match as a replayable corpus:

- `--record` write the session to `tracker/out/<session>/` with a manifest
- `--record-all` keep every frame; without it recording is windowed around
  ground-truth labels, which a real match has none of
- `--record-fps N` recording rate (default 4). It is quantised to `--fps`, so
  use `--fps 8` for a true 4 — at the default 10 you get 3.3
- `--record-max N` frame cap (default 4000, ~2.9MB each)
- `--record-note "..."` free text stored in the manifest

Offline evaluation (see `eval/README.md`):

- `--scan-cash <dir>` emit `file,t,cash,eco,round` per frame and exit. Eco is
  what separates a tower purchase from a send, so cash alone cannot make labels
- `--census-log <path>` write the per-frame census as JSONL during a replay, so
  it can be scored rather than only read
- `--solo` relax the match guard for Hero Challenge, whose opponent has `∞` lives

Build with `swiftc -O Sources/*.swift -o tracker`. Needs Screen Recording
permission for whatever launches it.

## Layout

| path | role |
|---|---|
| `tracker/` | the tracker itself |
| `calibrate/` | frame grabber + full-frame OCR dump, used to map the HUD |
| `probe/` | region-map verifier: annotated frame + per-second region CSV |
| `data/btd6_derived_rounds.json` | round table, all 40 rounds |
| `data/btdb2_costs.json` | published prices, read from the game — source of record |
| `tools/gen_price_table.py` | regenerates `tracker/Sources/PriceTable.swift` from it |

## The round table

Derived from BTD6's `DefaultRoundSet` at round 2N — BTDB2 round N tracks BTD6
round 2N. Verified at the edges: BTDB2 r1 = 35×Red matches capture, and r3's
green/red/blue composition is what exposed the opponent's grouped yellows as a
send.

BTDB2 alters some rounds, so treat it as a prior. The tracker logs observed
types against expected ones, which is both the send signal and the correction
signal for the table.

## Eco mechanics, measured

From a logged 13-round match, the calibrator independently recovered:

- **tick period 5.97–5.99s** → the disbursement is every 6 seconds
- **payout ratio 1.000** → eco value *is* the cash paid each disbursement
- **starting cash 650, starting eco 250**, read off your own HUD at match start

So the overlay reports income the way the game does: eco value, and `+$N` per
disbursement. Nothing here is hardcoded — it is re-measured every match from your
own cash jumps, so a balance patch cannot silently invalidate it.

## Status

Validated:

- window-targeted capture, ~10fps, follows the window when moved
- HUD parsing — round, cash, eco, both lives
- send card parsing — quantity, eco gain, cost, and bloon type
- eco tick period and payout ratio (above)
- match guard: menus and lobby register no phantom sends
- side detection from the panel column, and the mirrored layout it selects
- tower detection, against **hand-labelled real matches** rather than synthetic
  frames — see "Detecting the opponent's towers" below for the numbers
- the sprite descriptor on real capture pixels: a separating gap exists between
  the same tower re-read (≤0.224) and different towers (≥0.302), and the library
  recalls a learned price, rejects a stranger, and survives a round trip to disk
- the published price floor, which rejects **3–5 impossible learned prices per
  replay** on each of the two labelled matches — see "The published price table"
  below. The count varies between runs of the same binary over the same corpus,
  which is a second finding and not yet explained.

Implemented but **not yet exercised**: the census-floor falsifier
(`sites × minPaidCost > cashCeiling`). Replays end with zero standing sites by
construction, so only a live match can fire it.

**Tower spend used to be unbounded and wrong** — a logged match had it reach
$12,461 by round 2 against a cash ceiling of $2,302, 5.4× more than the opponent
could possibly have earned. It is now a census rather than a running total, which
is the structural fix; the history is worth keeping because each failure taught
the constraint that replaced it.

*The signal did not mean what it claimed.* `TowerWatcher` fired whenever 60% of a
footprint settled anywhere on their half: 51 samples out of the ~91,700 the
region subsamples to, or **0.056%**, in any 2s window. Absorption also reset the
background and left the sample free to absorb again, so animated scenery re-billed
on every cycle. Absorption was made one-shot per sample, required to form a
compact tower-sized blob off the bloon path, and required to still be settled
seconds later — and it still detected **nothing at all** on real match data.
Detection is no longer done this way; see the next section.

*The footprint constant was ~10× too small.* The code assumed a 52px tower — near
the placement footprint, not the drawn sprite. Diffing an empty board against one
with towers measured **613 and 1053 samples, 120×148 and 168×268 px**. The shape
gate had been accepting blobs an order of magnitude below any real tower.

*A single frame seeded the background, and at match start that frame is a
curtain.* Session `20260815T232736` shows it: the tracker latched at t=30.4 the
moment the round counter read `1/40`, but the match-start doors were still closed,
so the background was seeded from them. Two seconds later they slid away, the
whole board appeared, held still, and absorbed at once — **$7,980 in a single
one-second row at t=38.4**, then near-silence for 55 seconds. Diffing the seed
frame against the rest measures 64–70% of the half changed, permanently.
Persistence cannot catch this: a scene change really is still settled three
seconds later. This lesson outlived the design that produced it — the plate
detector faces the same problem when it seeds, and handles it differently.

*Nothing tied the total to income.* They cannot spend money they never had, and
both terms of what they had are recovered rather than estimated, so `cashCeiling`
is a hard bound. `cash` was `max(0, …)` around an unbounded estimate, which
silently absorbed the contradiction; clipping is now counted and surfaced.

*And an event sum can never come back down.* Every false positive was permanent,
so error only grew. Board value is now recomputed from the sites currently
standing, so a site that was never a tower leaves the total the moment it fails
verification, and a **sold** tower leaves it too rather than being charged again
as a purchase — the right magnitude with the wrong sign, which is what an event
sum structurally produces.

## Detecting the opponent's towers

Their cash is never shown, so their board has no ground truth anywhere in the
game. The detector is therefore developed against **your** half — where a cash
drop with flat eco dates and prices every purchase exactly — and confirmed
against hand-labelled checkpoints on theirs.

**How it works.** `PlateCensus` keeps a *plate*: the board with nothing on it,
taken from one frame at match start. Every cell is then scored on two axes over a
rolling 2.5s window — *occupancy*, the fraction of the window it differs from the
plate, and *flicker*, its mean frame-to-frame colour change. A tower is a region
that is occupied and still. `BoardWatcher` turns those regions into sites with
stable identities, and a site enters the books once it is 6 seconds old.

This is a **state** query, not an event query, and that is the whole point. The
absorption design it replaced could only see a tower *arrive*, so anything
standing before the tracker latched was invisible by design and every scene
change wiped the board.

**Measured, held-out, parameters frozen** (`eval/runs/`):

| | opponent recall | precision | placement null p95 |
|---|---|---|---|
| old absorption detector | 0 / 13 | — | — |
| plate detector, match 1 (temple) | 10 / 13 | 83.3% | 23.1% |
| plate detector, match 2 (desert, new opponent) | 9 / 11 | 90.0% | 63.6% |

Match 2 was a pure replication: nothing tuned, different map, different opponent.
Its null is high because that opponent only ever built three towers, and a sparse
board is easy to hit by accident — the margin there is ~18 points, against ~54 on
match 1.

**What it gets wrong, and why the numbers are small.** Across both matches there
are five misses: three are **firing towers** — a muzzle flash is exactly a large
frame-to-frame change at a fixed spot, so the stillness test rejects it — one is
two adjacent towers **merging** into a single blob, and one is **latency**, a
tower found 1.8s after the checkpoint that scored it. Firing towers are the
largest known weakness and the obvious thing to fix next.

Eight unique towers in ~4 spatial clusters on one match, three on the other. The
design resolves 0/13 versus 10/13 and nothing finer, so **one-tower differences
are noise** and are reported as such.

**Three things that will break it if you touch them.**

- *Never reseed the plate on a scene change.* An overlay pushing occupancy to
  ~44% once triggered a reseed from a frame with eight towers standing, baking
  them into the background permanently — the board read 7 towers at t=315 and 0
  at t=330. Suspend instead; a banner is transient and the plate underneath is
  still good.
- *But never suspend forever either.* Seeding during the match-start countdown,
  which dims the whole screen, gives a plate that is geometrically perfect and
  photometrically useless. Occupancy pins high and the detector never runs at
  all. The two cases are told apart by **duration**: over 3s of high occupancy is
  evidence about the plate, not the view.
- *Flicker is sample-rate dependent.* It is a frame-to-frame delta, so a 10fps
  live stream shrinks it 2–3× against the 4fps recordings every threshold was
  measured on. Ingestion is throttled to 0.22s regardless of capture rate.

**Rejected, with evidence.** A distance-transform blob splitter fixes the merge
case and was still cut: on the second map it never fired at all (its size
threshold does not transfer) while costing +62% and +75% site churn on the two
matches. Two matches, consistent cost, no demonstrated benefit —
`eval/runs/2026-08-16-peak-split.md` before reintroducing it.

**Reproducing any of this** is `eval/README.md`. Every run has a preregistration
written before the numbers were seen, and the ledger records the retractions too:
flicker was claimed load-bearing and is not, and own-board arrival recall is a
broken metric that must not be quoted.

## Pricing towers without the assets

The encrypted asset catalogue was treated three times in this file as the reason
tower pricing is unknowable. It is not the obstacle it looked like, because the
game already shows you every price you need — on your own HUD, in cash.

Your cash is parsed every frame, and money leaves your pocket in exactly two
ways. A send also **raises your eco**; a tower does not. So a cash drop with flat
eco is a tower purchase of exactly that amount, to the dollar, with nothing
estimated. Pair it with whatever changed on your board at that moment and you
have a sprite labelled with a price. `sprites.json` persists beside the binary,
so the library fills itself in across matches.

Entries store **cumulative** cost — everything sunk into a tower that currently
looks like this — which is what makes board value a pure function of the census
rather than a sum of transitions.

The descriptor is deliberately not a classifier of tower names. It only answers
"is this the same appearance I priced before", and is built from a hue histogram,
concentric saturation and brightness rings, outline darkness, and edge density —
every component rotation-invariant, because towers turn to face their target.

Measured separation on real capture pixels, three towers across three frames:

| | distance |
|---|---|
| same tower, re-read 15s later | ≤ **0.224** (5 pairs) |
| different towers | ≥ **0.302** (16 pairs) |

The match threshold sits in that gap at 0.26. It was 0.16 first, below the noise
floor, which made a tower fail to match *itself* and every site read as unpriced.
Treat the numbers as provisional: one map, one dump, and the largest
within-distance may itself be a real upgrade rather than noise, which would mean
the gap is wider than it looks.

Texture is what separates a sprite from a transition, and it needs no library at
all. Labelled regions of a real frame:

| region | edge density |
|---|---|
| match-start curtain | **0.005** |
| bare map | 0.068 |
| tower sprites | **0.131 – 0.334** |
| dense bloon stream | 0.366 |

The curtain is rejected by two orders of magnitude, which is the entire $11,820
burst gone on one test. Bloons are **not** separable this way — a dense stream has
a hard edge at every boundary and scores highest of anything measured. They are
excluded by the path mask, by moving between censuses, and by failing descriptor
verification, not by texture.

Known limits:

- **You only learn towers you build.** An opponent playing something you never
  touch stays unpriced and falls back to the published median base cost, $475
  flat. Those sites are counted as `tower_unpriced` and called out on the overlay
  rather than being given a number that looks as earned as a learned one. The
  fallback used to scale blob area against $400, spanning $240–$1200; tested
  against the learned library, area vs cumulative cost came out at **r = −0.219,
  n = 6** — wrong sign, and far too few points to read as a real negative. The
  multiplier was carrying no information, so the spread it produced was noise
  dressed as detail. n = 6 has not settled this; the upgrade path is to take the
  prior from the distribution of learned costs once the library is big enough to
  have one, which needs no table at all.
- **The sell refund ratio is assumed at 75%**, not measured, until a sell on your
  own board pairs with a cash rise. The pairing is implemented; it has not yet
  fired on a real match.
- **Adjacent tiers within one path are the confusable case.** The two snipers in
  the capture are wildly different and separate easily, but a 3-0-0 against a
  4-0-0 may not, which bounds tier accuracy without breaking the approach.
- **Pairing a cash drop to a board change is nearest-in-time**, over a 12s
  window. Two purchases in quick succession can be matched to each other's
  sprites; the library averages repeated observations, so this dilutes rather
  than corrupts, but it is not exact.
- A send of a type the round also spawns naturally is a weaker signal, caught
  only as an excess over the scheduled count. Marked `?`, scored 0.45.
- Card position→type assumes an unscrolled send menu, which holds while fewer
  than five sends are unlocked.
- Selecting one of your towers opens a panel that covers the opponent's track.
- `--replay` validates parsing, not dynamics: frames captured seconds apart
  cannot exercise a 6s tick or the 2.5s settle window. The census reports zero
  sites under replay for the same reason — a site needs a 3s settle window and
  two confirmations 2s apart — and that zero is correct rather than broken.

## The published price table, and what it is not for

`data/btdb2_costs.json` holds every price the game charges: 22 base tower costs
and all 330 upgrades. The upgrade costs were read **out of the game itself** at
v4.13 — the Monkeys menu prints `INGAME COST` for whichever upgrade is selected,
and locked towers still show theirs, so an account owning four starters can read
all 22 trees. `tools/gen_price_table.py` compiles the JSON into
`tracker/Sources/PriceTable.swift`; edit the JSON, never the Swift.

Blooncyclopedia agreed on **324 of 330**. That is worth stating plainly, because
it means the wiki was not the problem — but the six exceptions are the reason to
read the game anyway, and none of them is a wrong number:

| slot | what the wiki has | what the game charges |
|---|---|---|
| Banana Farm p3t1 | EZ Collect $250 **and** Quality Soil $400 | Quality Soil, **$400** |
| Ice Monkey p1t2 | Metal Freeze $300 **and** Cold Snap $350 | Cold Snap, **$350** |
| Monkey Ace p3t2 | Centered Path **and** Advanced Navigation, both $300 | **$300** either way |
| Monkey Village p3t3 | Monkeyconomy $1500 **and** Monkey Town $5000 | Monkeyconomy, **$1500** |
| Mortar p3t1 | Increased Accuracy $200 **and** Dynamic Targeting $400 | Dynamic Targeting, **$400** |
| Monkey Village p3t5 | Monkeyopolis, flat $20000 | **20000 + 5000 × villages absorbed** |

Five slots carry a retired upgrade alongside the live one, so a join on
tower/path/tier picks wrong about half the time and never says so. The sixth is
not a constant at all.

**Base costs are still wiki-sourced for 19 of 22.** The tower menu prices
upgrades but never the tower, and the in-match shop shows only the three monkeys
in your loadout. Verified in-game: Dart $200, Tack $280, Bomb $525 — all matching
the wiki. Every entry in the JSON carries its own `source`.

### It bounds the census; it does not price it

Pricing stays with the learned sprite library, because the table is keyed by
tower NAME and the descriptor deliberately cannot produce one. What the table
adds is a legal range, which catches a whole class of bug for free: a number no
legal board could produce is wrong without anyone knowing the right answer.

**The floor is not the sticker price.** Monkey Business takes 5% off monkeys in
radius and Monkey Commerce adds 5% *"stacking with up to 2 other Villages"* —
20% at the limit. So the cheapest real purchase is 80% of the cheapest tower:
`minPaidCost = 80`, not the $100 Glue Gunner list price. A floor set at the
sticker deletes true observations of a village-discounted board. `minTowerCost`
is the sticker and bounds nothing.

Two checks run off it:

- **A learned price below the floor is a mispaired cash move.** Rejected at
  `learn`, and purged from `sprites.json` at load. On the two recorded matches
  this drops a stored $24 entry and rejects **3–5 more per replay** at $24–$40 —
  the harvester's cash↔board pairing produces impossible prices several times a
  match, which the library was previously absorbing in silence.

  **The count is not reproducible.** The same binary over the same corpus gave
  4 then 5 rejections on `152152`, and 3 then 4 on `124547`. Replays are supposed
  to be deterministic, and the books block was made byte-identical across
  concurrent runs earlier (see Status). Something in the census or the harvester
  still is not, and the cause is **not yet identified** — the known hash-seed
  nondeterminism is in `SendDetector`'s `Set` iteration, which does not obviously
  reach the harvester. Until that is understood, treat rejection counts as
  indicative and never as a metric to tune against.
- **`sites × minPaidCost > cashCeiling` falsifies the site COUNT.** Strictly
  stronger than the existing affordability clip: clipping can mean the fallback
  price is too high, but a floor breach cannot — it says more towers are being
  reported than any board could hold at any price, so the surplus is false
  positives. Nothing about the learned pricing enters it, which is what makes it
  a test of the detector rather than of the library.

**DEAD: snapping an estimated price to the nearest legal value.** The lattice of
legal cumulative costs has 838 distinct values with a median gap of $15 below
$3000, so **84.1% of all integers in $100–$3000 sit within $10 of one** (54.5%
within $5). Agreement with it is evidence of nothing, and a confidence score
built on it would read near-perfect on noise. Exact data did not change this —
the lattice is dense because the game has many cheap upgrades.
