#!/usr/bin/env bash
# Append a ground-truth label to a recording session.
#
# Placement labels come from OUTSIDE the tracker process: whoever drives the
# game knows what it clicked, where, and what the shop said it cost, and that is
# strictly better information than anything recovered from pixels afterwards.
# The tracker never sees these — they exist to score it against.
#
# Times are wall clock, converted to frame time later through the manifest's
# `startedAt` anchor. Each label brackets the click with a before/after pair
# rather than claiming a single instant, because the driver's timestamp and the
# actual click are separated by a tool round-trip of unknown length. Scoring
# treats the bracket as the window the placement happened in, and can pin it
# exactly by finding the matching cash drop inside it.
#
# Usage:
#   label.sh <session-dir> place  <tower> <cost> <x> <y> <t_before> [note]
#   label.sh <session-dir> map    <name>
#   label.sh <session-dir> note   <text>
#
# t_before is captured by the caller immediately BEFORE the click, from this
# same script so both ends use one clock and one format:
#   T=$(label.sh now)    # then click, then: label.sh <dir> place ... "$T"

set -euo pipefail

# BSD date has no %N, so `date -u +%...%3NZ` yields a literal "3N" and silently
# produces an unparseable stamp. Python is the portable source of subsecond
# time here.
now() { python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z")'; }

if [ "${1:-}" = "now" ]; then now; exit 0; fi

die() { echo "label.sh: $*" >&2; exit 2; }

[ $# -ge 2 ] || die "usage: label.sh <session-dir> <place|map|note> ..."

DIR="$1"; KIND="$2"; shift 2
[ -d "$DIR" ] || die "no such session dir: $DIR"
OUT="$DIR/truth.jsonl"

case "$KIND" in
  place)
    [ $# -ge 5 ] || die "place needs <tower> <cost> <x> <y> <t_before> [note]"
    tower="$1"; cost="$2"; x="$3"; y="$4"; tb="$5"; note="${6:-}"
    printf '{"event":"place","tower":"%s","cost":%s,"screen_x":%s,"screen_y":%s,"t_before":"%s","t_after":"%s","note":"%s"}\n' \
      "$tower" "$cost" "$x" "$y" "$tb" "$(now)" "$note" >> "$OUT"
    ;;
  map)
    [ $# -ge 1 ] || die "map needs <name>"
    printf '{"event":"map","name":"%s","t":"%s"}\n' "$1" "$(now)" >> "$OUT"
    ;;
  note)
    [ $# -ge 1 ] || die "note needs <text>"
    printf '{"event":"note","text":"%s","t":"%s"}\n' "$1" "$(now)" >> "$OUT"
    ;;
  *) die "unknown kind: $KIND" ;;
esac

echo "$(wc -l < "$OUT" | tr -d ' ') labels in $OUT"
