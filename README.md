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
- build detection against synthetic frames: static ground, animated scenery, and
  a dense bloon stream all register zero builds; a placed tower registers
  exactly one, alone and with both distractors running

**Tower spend used to be unbounded and wrong** — a logged match had it reach
$12,461 by round 2 against a cash ceiling of $2,302, 5.4× more than the opponent
could possibly have earned. Two independent causes, both now fixed.

*The signal did not mean what it claimed.* `TowerWatcher` fired whenever 60% of
a footprint settled anywhere on their half: 51 samples out of the ~91,700 the
region subsamples to, or **0.056%**, in any 2s window. Absorption also reset the
background and left the sample free to absorb again, so animated water, flags,
and shadows re-billed on every cycle, as did a dense bloon stream holding one
pixel the same colour. It sat pinned at its own 1.5s rate limit, worth about
$16k/minute. Four tests now stand between an absorption and a charge: only a
sample's **first** absorption counts, the samples must form one **compact**
tower-sized blob rather than a drizzle, the blob must sit **off the path** the
bloons walk, and it must still be **settled** three seconds later. Persistence
does the most work — a tower is still there three seconds on, and nothing else
on the map is.

Note that the suppression window at match start this file previously called for
would not have helped. `retarget()` throws the background model away and the
next frame reseeds it from whatever is on screen, so their existing board is
already free — the bleed was a constant drizzle all match, not an opening
avalanche.

*Nothing tied the total to income.* They cannot spend money they never had, and
both terms of what they had are recovered rather than estimated, so `cashCeiling`
is a hard bound. It is now applied per build at the moment of the build — not
reconciled once at the end, where an early impossible build could hide behind
later earnings. Clipping is counted and surfaced rather than hidden: `cash` was
`max(0, …)` around an unbounded estimate, which silently absorbed the
contradiction. A rising `builds_clipped` now says the detector is running hot,
and the CSV carries the pre-bound total beside the bounded one so the two can be
compared against a real match.

**Send counts are the weak term.** Converting pixel area to a bloon count
requires knowing how many bloons are on screen at once, which depends entirely on
how fast the defence is popping them — and nothing on screen reveals that. Every
calibration point in the logged match is contaminated by sends, an unknown pop
rate, or both. `--visible-fraction` exposes the constant; the default is an
estimate with a wide error bar, and eco/send-spend inherit that error.

The fix is to count *time* instead of area. Sends dispatch at a fixed cadence,
and your own outgoing queue on the centre divider visibly drains at exactly that
cadence — so a type's presence duration divided by per-send dispatch time yields
a count that never depends on the pop rate. Not yet built.

Known limits:

- **Tower spend is estimated, and the cost model is the weak half.** Detection
  is now gated well enough to mean something; pricing is not. Identifying which
  tower and which upgrade tier needs the asset catalogue, which the game ships
  encrypted, so cost is blob area scaled against a flat $400 — `shopPrices` is
  declared and read but nothing populates it. The overlay shows the cash ceiling
  alongside the estimate so the size of the assumption stays visible.

  The fix is the same move the eco constants already make: your own cash is on
  the HUD, so a drop that isn't a send is a tower purchase of *exactly* that
  amount. Pairing your cash drops with the blobs they produce on your own track
  yields labelled (area, price) pairs live — this match, this map, this
  resolution — and reveals the exact price points in play, so their blob can snap
  to a real catalogue instead of scaling a guess. Not yet built.
- **Builds, upgrades, and sells are charged identically**, and a sell has the
  wrong sign — it returns cash but registers as a purchase. Separating them needs
  a per-site tier model: a blob at a virgin location is a new tower, one
  overlapping a known site is an upgrade, and a site reverting to its
  match-start background is a sell. For now a confirmed site suppresses repeat
  charges for 8s, which biases toward under-counting.
- A send of a type the round also spawns naturally is a weaker signal, caught
  only as an excess over the scheduled count. Marked `?`, scored 0.45.
- Card position→type assumes an unscrolled send menu, which holds while fewer
  than five sends are unlocked.
- Selecting one of your towers opens a panel that covers the opponent's track.
- `--replay` validates parsing, not dynamics: frames captured seconds apart
  cannot exercise a 6s tick or the 2.5s settle window. Builds report zero under
  replay for the same reason — a build must survive a 3s settle window and a 3s
  persistence check — and that zero is correct rather than broken.
