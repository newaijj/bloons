#!/usr/bin/env python3
"""Map a recording's wall-clock labels onto its frames.

The manifest times frames from zero; ground truth is written in wall clock by a
driver outside the process. `startedAt` is the only thing joining them, so every
question of the form "what did the board look like when I clicked" goes through
this conversion.

  frame_at.py <session-dir>                 list labels with their frame windows
  frame_at.py <session-dir> --t <seconds>   nearest frame to a frame-time
"""
import json, os, sys, datetime


def parse(ts):
    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))


def load(d):
    m = json.load(open(os.path.join(d, "manifest.json")))
    frames = sorted(m["frames"], key=lambda f: f["t"])
    return m, frames


def nearest(frames, t):
    return min(frames, key=lambda f: abs(f["t"] - t))


def main():
    d = sys.argv[1]
    m, frames = load(d)
    t0 = parse(m["startedAt"])

    if "--t" in sys.argv:
        t = float(sys.argv[sys.argv.index("--t") + 1])
        print(nearest(frames, t)["file"])
        return

    print(f"{m['session']}  {len(frames)} frames  "
          f"{frames[-1]['t']:.1f}s  started {m['startedAt']}")
    tp = os.path.join(d, "truth.jsonl")
    if not os.path.exists(tp):
        print("no truth.jsonl")
        return

    for line in open(tp):
        e = json.loads(line)
        if e["event"] != "place":
            print(f"  [{e['event']}] {e.get('name') or e.get('text')}")
            continue
        a = (parse(e["t_before"]) - t0).total_seconds()
        b = (parse(e["t_after"]) - t0).total_seconds()
        fa, fb = nearest(frames, a), nearest(frames, b)
        print(f"  {e['tower']:<14} ${e['cost']:<4} @({e['screen_x']},{e['screen_y']})"
              f"  window {a:7.1f}s → {b:7.1f}s   {fa['file']} → {fb['file']}"
              f"  ({sum(1 for f in frames if a <= f['t'] <= b)} frames)")


main()
