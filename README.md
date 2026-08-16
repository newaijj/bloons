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

Build with `swiftc -O Sources/*.swift -o tracker`. Needs Screen Recording
permission for whatever launches it.

## Layout

| path | role |
|---|---|
| `tracker/` | the tracker itself |
| `calibrate/` | frame grabber + full-frame OCR dump, used to map the HUD |
| `probe/` | region-map verifier: annotated frame + per-second region CSV |
| `data/btd6_derived_rounds.json` | round table, all 40 rounds |

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
- census against synthetic frames, 7 scenarios: static ground, animated scenery
  and a dense bloon stream all hold zero sites; a placed tower registers exactly
  one, alone and with both distractors running; a match-start curtain is
  reseeded through rather than billed, and a tower placed after it is still
  caught; a sold tower leaves the census
- the sprite descriptor on real capture pixels: a separating gap exists between
  the same tower re-read (≤0.224) and different towers (≥0.302), and the library
  recalls a learned price, rejects a stranger, and survives a round trip to disk

**Tower spend used to be unbounded and wrong** — a logged match had it reach
$12,461 by round 2 against a cash ceiling of $2,302, 5.4× more than the opponent
could possibly have earned. It is now a census rather than a running total, which
is the structural fix; the history is worth keeping because each failure taught
the constraint that replaced it.

*The signal did not mean what it claimed.* `TowerWatcher` fired whenever 60% of a
footprint settled anywhere on their half: 51 samples out of the ~91,700 the
region subsamples to, or **0.056%**, in any 2s window. Absorption also reset the
background and left the sample free to absorb again, so animated scenery re-billed
on every cycle. Absorption is now one-shot per sample, must form a compact
tower-sized blob off the bloon path, and must still be settled seconds later.

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
seconds later. Absorption above 2.5% of the board in one frame now reseeds
instead of billing, and the count is in the log.

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
  touch stays unpriced and falls back to blob area against a flat $400. Those
  sites are counted as `tower_unpriced` and called out on the overlay rather
  than being given a number that looks as earned as a learned one.
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
