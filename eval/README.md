# Detection evaluation

Baseline and scoring for opponent tower detection. Everything here is
regenerable from `tracker/out/<session>` — see the commands below.

## Why score on your own board

The opponent's cash is never displayed, so nothing about their spending can be
recovered directly and no ground truth for their board exists. Your own board is
the same detection problem on the same renderer at the same scale, and it IS
labelled: a drop in your cash with your eco flat is a tower purchase of exactly
that amount at a known time. So the detector is developed against your half,
where truth is free, and confirmed against a handful of hand-labelled
checkpoints on theirs.

## Regenerating

    cd tracker
    ./tracker --scan-cash out/<session>            > ../eval/hud_<id>.csv
    ./tracker --replay    out/<session> --census-log ../eval/census_<id>.jsonl
    cd ..
    tools/own_truth.py eval/hud_<id>.csv           > eval/truth_own_<id>.json
    tools/score.py eval/census_<id>.jsonl \
        --own         eval/truth_own_<id>.json \
        --checkpoints eval/truth_opp_<id>.json

`--scan-cash` output is not a bare CSV — the tracker prints startup lines first,
and `own_truth.py` finds the header rather than assuming line 1.

## Opponent labels

`truth_opp_<id>.json` positions are FRAME pixels, read by eye off
`tools/board_crop.swift` output, which draws a 100px grid over one board with a
heavy line every 500. Frame pixels are the only shared coordinate system: the
recording carries no window origin, so absolute screen coordinates from a
placement driver cannot be converted at all.

Add checkpoints with:

    swiftc -O tools/board_crop.swift -o /tmp/board_crop
    /tmp/board_crop tracker/out/<session>/<frame>.png right eval/opp_t<T>.png

## What the numbers mean

> **Open, 2026-08-16: replays are not reproducible, so every number below is
> provisional.** The same binary over the same corpus with the same input library
> produced different results on repeat runs — 4 then 5 price-floor rejections on
> `152152`, 3 then 4 on `124547`. The books block was previously verified
> byte-identical across concurrent runs, so this is either a regression or a
> second source, and the cause is unidentified. The known hash-seed
> nondeterminism (`SendDetector` iterating a `Set`) does not obviously reach the
> census. **Until this is found, a difference of one or two between two arms is
> not evidence of anything** — re-run each arm several times before believing a
> gap that small. See `runs/2026-08-16-published-price-table.md`.

**Opponent checkpoint recall/precision is the metric to read.** It compares
detected site positions against hand-labelled ones at a few points in the match,
one-to-one, within `--tol` pixels.

`placement null` is what stops it being self-congratulatory: the recall a
detector would get by scattering the *same number* of sites at random over the
board, across 300 draws. Recall at or below the null's 95th percentile
demonstrates nothing. This matters most on sparse boards — an opponent with three
towers gives a null median of 45%, so a good-looking recall there means much less
than the same number on a busy board.

A checkpoint the census does not actually cover is **skipped**, not scored
against whatever record happens to be nearest. Comparing a t=330 label against a
t=90 frame would report a real-looking zero that says nothing.

### `own-board arrival recall` is WITHDRAWN — do not quote it

It asks whether a new site appeared within a window after a known purchase, and
it is degenerate at realistic site counts. Measured on match 2: with 36–63 sites
emitted against 7 purchases, chance recall is 86–97%, and one arm scored *below*
chance while another hit 100%. A purely temporal match is nearly guaranteed and
discriminates nothing.

It also carries an unfixable floor even in principle: an upgrade is a cash drop
with flat eco exactly like a new placement, cash cannot separate them, so some
purchases can never produce a new site however good the detector is.

The repair is a positional test alongside the temporal one, as the opponent
checkpoint metric already has. Until that exists the scorer still prints the
number; ignore it.
