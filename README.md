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

## Layout facts

The screen is mirrored from the obvious reading: **the opponent owns the left
track, you own the right.** Confirmed via the Steam persona name, which renders
at the far right of the top bar. Send card cost/eco values scale with round
number, so they're re-read live rather than hardcoded.

## Running

```bash
cd tracker && ./tracker
```

- `--headless` console only, no overlay
- `--log run.csv` per-second CSV including raw track counts, for tuning
- `--replay <dir>` push recorded PNGs through the live pipeline
- `--fps N` capture rate (default 10)

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

- **Tower spend is estimated**, from the footprint of things settling on their
  board scaled by shop prices. Identifying which tower and which upgrade tier
  needs the asset catalogue, which the game ships encrypted. The overlay shows
  the cash ceiling alongside the estimate so the size of the assumption is
  visible.
- A send of a type the round also spawns naturally is a weaker signal, caught
  only as an excess over the scheduled count. Marked `?`, scored 0.45.
- Card position→type assumes an unscrolled send menu, which holds while fewer
  than five sends are unlocked.
- Selecting one of your towers opens a panel that covers the opponent's track.
- `--replay` validates parsing, not dynamics: frames captured seconds apart
  cannot exercise a 6s tick or the 2.5s settle window.
