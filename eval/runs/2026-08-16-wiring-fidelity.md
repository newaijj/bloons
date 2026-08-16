# Run: wiring the plate detector into the live pipeline

- **Date**: 2026-08-16
- **Change**: `PlateCensus.swift` added; `BoardWatcher` rewritten to use it.
  `TrackScanner` is no longer used for detection (SendDetector still owns it).
  Public API unchanged, so `TowerWatcher`, `SpriteHarvester` and `main.swift`
  were untouched apart from the trace printer.
- **Question**: does the wired pipeline reproduce the offline tool's held-out
  numbers? Wiring that silently changes results is not wiring, it is a new
  experiment with no run record.

## Fidelity against the offline tool

| | offline tool | wired pipeline |
|---|---|---|
| match 1, temple (t>=180) | 76.9% recall / 83.3% precision | **76.9% / 83.3%** — exact |
| match 2, desert (all) | 81.8% / 90.0% | **63.6% / 100.0%** |

Match 1 reproduces to the digit. Match 2 does not: the wired version finds 7 of
11 where the tool found 9, but emits **zero false positives** against the tool's
one. It is strictly more conservative, not differently wrong.

## Three real bugs found by demanding fidelity

None of these would have been visible without the comparison.

**1. Reseeding on a scene change destroys the plate.** Ported straight from the
old absorption scanner, where reseeding was correct. Here it is catastrophic: an
overlay pushed occupancy to ~44% near t=326 on match 1, the reseed rebuilt the
plate from a frame with eight towers standing, and those towers were baked into
the background permanently. The board read 7 towers at t=315 and 0 at t=330;
held-out recall fell 76.9% -> 30.8%. Fixed by SUSPENDING on a scene change —
skip the census, touch nothing — since a banner is transient and the plate
underneath is still good.

**2. Suspend-forever on a bad plate.** The fix for (1) introduced its own
failure. On match 2 the side latched during the match-start countdown, which
DIMS the whole screen. The plate was geometrically perfect and photometrically
useless: every later frame differed from it everywhere, occupancy pinned high,
and the detector suspended for the entire match. 0 of 11 towers. Fixed by
telling the two cases apart on DURATION — high occupancy for under 3s is a
blocked view, sustained beyond that is evidence about the plate itself, and the
only repair is a new one.

**3. Flicker is sample-rate dependent.** It is a frame-to-frame delta, so its
magnitude depends on frame spacing. Every threshold was calibrated on 4fps
recordings; feeding a 10fps live stream in directly would shrink flicker 2-3x and
turn `flickerMax` into a gate that passes almost everything. Ingestion is now
throttled to 0.22s — just under a 4fps recording's 0.25s so float jitter cannot
drop alternate samples, which on its own would halve the window and silently
tighten `occFrac` well past what it was measured at.

A fourth, smaller one: every early return left `trace.sites` at zero, so the
console reported an empty board on any suspended or rate-skipped frame. That is
precisely why bug (1) hid — the frames where the damage happened printed nothing.

## Unresolved

The 2-tower gap on match 2. The offline tool seeded its plate from an explicitly
chosen bright, empty frame at t=40; the wired version seeds at latch (t=34.7,
dimmed) and self-corrects ~3s later, landing on a slightly worse plate.

I am **not** tuning the seed-timing rule to close this, because the only data to
tune it against is the two blocks these numbers are reported on, and selecting on
the reported block is how a result stops being evidence. The options are a
principled seed rule validated on a third match, or accepting the conservative
behaviour. For a tool that books an opponent's spending, trading recall for zero
false positives is the safer of the two errors, so accepting it is defensible.

## Status

Wired, building clean, reproducing on one of two matches and conservative on the
other. The old absorption path is gone from detection.
