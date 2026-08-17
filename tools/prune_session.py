#!/usr/bin/env python3
"""Shrink a recorded session to the frames that actually exercise the census.

A continuously-recorded match is mostly a static board photographed hundreds of
times. What the detector needs is the seconds around each placement, plus some
deliberately quiet stretches to measure false positives against. Everything else
is storage.

The window cannot come from the labels alone. A driver writes its label only
after the click has gone through, so the bracket it records is tens of seconds
wide — on these sessions, wide enough to cover most of the match. But a tower
costs a known amount and the money leaves the instant it lands, so a cash drop
of the right size inside the bracket dates the placement to a single frame. That
is what makes a tight window possible.

Placements whose cash drop cannot be found keep their whole (wide) bracket
rather than being trimmed on a guess — losing the frames would be irreversible,
and a session that is merely large is a smaller problem than one missing the
event it was recorded for.

  prune_session.py <session-dir> --cash <csv>            dry run
  prune_session.py <session-dir> --cash <csv> --apply    delete
"""
import argparse, datetime, json, os, shutil, sys

PRE_MARGIN = 5.0      # seconds kept before the placement
POST = 15.0           # after; the census needs ~8-10s to confirm a site
QUIET_EVERY = 60.0    # sample a stretch of nothing happening this often
QUIET_FOR = 3.0


def parse_iso(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


def load(d):
    m = json.load(open(os.path.join(d, "manifest.json")))
    frames = sorted(m["frames"], key=lambda f: f["t"])
    labels = []
    tp = os.path.join(d, "truth.jsonl")
    if os.path.exists(tp):
        labels = [json.loads(l) for l in open(tp) if l.strip()]
    return m, frames, labels


def cash_series(path):
    """Frame time and cash for each row of a `--scan-cash` dump.

    Located by the header, not by column position: the tracker prints startup
    lines before the CSV begins, and the dump carries eco and round beside cash.
    A positional parser silently matched nothing once the eco column landed, and
    a run with no cash series is not an error — every placement just keeps its
    whole untrimmed bracket.
    """
    out, cols = [], None
    for line in open(path):
        parts = [p.strip() for p in line.strip().split(",")]
        if parts[0] == "file":
            cols = parts
            continue
        if cols is None or len(parts) != len(cols):
            continue
        row = dict(zip(cols, parts))
        if not row.get("cash"):
            continue
        try:
            out.append((float(row["t"]), int(row["cash"])))
        except ValueError:
            pass
    return out


def find_drop(series, lo, hi, cost):
    """Frame time of the cash drop closest in size to `cost`, inside [lo, hi]."""
    best, best_err = None, None
    for (t0, c0), (t1, c1) in zip(series, series[1:]):
        if not (lo <= t1 <= hi):
            continue
        delta = c0 - c1
        if delta <= 0:
            continue
        err = abs(delta - cost)
        # A tower's price is exact; allow only OCR-scale slop, not "roughly".
        if err > max(20, 0.10 * cost):
            continue
        if best_err is None or err < best_err:
            best, best_err = (t1, delta), err
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session")
    ap.add_argument("--cash", required=True)
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    d = a.session
    m, frames, labels = load(d)
    series = cash_series(a.cash)
    t0 = parse_iso(m["startedAt"])
    print(f"{m['session']}: {len(frames)} frames, "
          f"{frames[-1]['t']:.1f}s, {len(series)} cash readings")

    keep_spans, notes = [], []
    for e in labels:
        if e.get("event") != "place":
            continue
        lo = (parse_iso(e["t_before"]) - t0).total_seconds()
        hi = (parse_iso(e["t_after"]) - t0).total_seconds()
        hit = find_drop(series, lo, hi, e["cost"])
        if hit:
            t, delta = hit
            keep_spans.append((t - PRE_MARGIN, t + POST, f"{e['tower']}@{t:.1f}s"))
            notes.append(f"  {e['tower']:<14} ${e['cost']:<4} bracket {lo:6.1f}-{hi:6.1f}s"
                         f"  → cash -${delta} at t={t:.1f}s"
                         f"  keep {t-PRE_MARGIN:.1f}-{t+POST:.1f}s")
            e["t_placed"] = round(t, 3)
            e["t_placed_source"] = f"cash drop of ${delta}"
        else:
            keep_spans.append((lo - PRE_MARGIN, hi + POST, f"{e['tower']}(unrefined)"))
            notes.append(f"  {e['tower']:<14} ${e['cost']:<4} bracket {lo:6.1f}-{hi:6.1f}s"
                         f"  → NO MATCHING CASH DROP, keeping whole bracket")
    print("\n".join(notes) if notes else "  (no placement labels)")

    # Quiet samples, skipping anything already inside a placement window.
    t, quiet = 0.0, []
    end = frames[-1]["t"]
    while t < end:
        if not any(s <= t <= e for s, e, _ in keep_spans):
            quiet.append((t, t + QUIET_FOR, "quiet"))
        t += QUIET_EVERY
    keep_spans += quiet

    keep, why = set(), {}
    for f in frames:
        for s, e, tag in keep_spans:
            if s <= f["t"] <= e:
                keep.add(f["file"])
                why[f["file"]] = "quiet" if tag == "quiet" else "placement"
                break

    drop = [f for f in frames if f["file"] not in keep]
    size = lambda fs: sum(os.path.getsize(os.path.join(d, f))
                          for f in fs if os.path.exists(os.path.join(d, f)))
    kept_b, drop_b = size(keep), size([f["file"] for f in drop])
    print(f"\n  keep {len(keep)} frames ({kept_b/2**30:.2f} GB), "
          f"drop {len(drop)} ({drop_b/2**30:.2f} GB) — "
          f"{100*len(keep)/max(1,len(frames)):.0f}% retained")

    if not a.apply:
        print("\n  dry run; pass --apply to delete")
        return

    # The full frame list is preserved even though the pixels are not, so the
    # record of what was captured survives the pruning.
    shutil.copyfile(os.path.join(d, "manifest.json"),
                    os.path.join(d, "manifest.full.json"))
    for f in drop:
        p = os.path.join(d, f["file"])
        if os.path.exists(p):
            os.remove(p)

    m["frames"] = [{**f, "why": why.get(f["file"], "placement")}
                   for f in frames if f["file"] in keep]
    m["windowed"] = True
    m["note"] = m.get("note", "") + (
        f"\n\nPruned to placement windows (-{PRE_MARGIN}s/+{POST}s around each "
        f"cash-dated placement, plus {QUIET_FOR}s every {QUIET_EVERY}s of quiet). "
        f"{len(drop)} frames removed; manifest.full.json lists the original set.")
    json.dump(m, open(os.path.join(d, "manifest.json"), "w"),
              indent=2, sort_keys=True)

    if labels:
        with open(os.path.join(d, "truth.jsonl"), "w") as fh:
            for e in labels:
                fh.write(json.dumps(e) + "\n")
    print(f"  pruned; freed {drop_b/2**30:.2f} GB")


main()
