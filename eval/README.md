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

`arrival recall` is a LOWER bound. An upgrade is a cash drop with flat eco
exactly like a new placement, and cash cannot separate them, so some purchases
in the truth set can never produce a new site however good the detector is.

`chance recall` is the number that stops the others being self-congratulatory:
what a detector emitting the same number of sites at uniformly random times
would have scored against these same purchase times. Recall at or below it means
nothing was demonstrated.
