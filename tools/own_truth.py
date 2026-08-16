#!/usr/bin/env python3
"""Derive ground-truth tower purchases on YOUR board from the HUD scan.

Your own board is the only labelled board in existence. The opponent's cash is
never displayed, so nothing about their spending can be recovered directly — but
a drop in YOUR cash with YOUR eco flat is a tower purchase of exactly that
amount, to the dollar, at a known time. That makes your half a fully supervised
copy of the same detection problem, on the same renderer at the same scale.

    ./tracker --scan-cash <session> > hud.csv
    tools/own_truth.py hud.csv > truth_own.json

The awkward part is OCR noise. A single misread digit produces a fake drop
followed by a fake recovery, which would enter the truth set as a purchase that
never happened and then be counted against the detector forever. So a cash level
is only believed once it has been read the same way on consecutive frames, and
deltas are taken between believed levels rather than between raw readings.
"""
import csv, json, sys, argparse


def believed_levels(rows, runlen):
    """Collapse the raw per-frame readings into levels that held still.

    A reading is promoted to a level once `runlen` consecutive frames agree on
    it. Anything that flickers for a single frame never becomes a level and so
    can never generate a delta.
    """
    levels = []
    run_val, run_start, run_n = None, None, 0
    for r in rows:
        if r["cash"] is None:
            run_val, run_n = None, 0
            continue
        if r["cash"] == run_val:
            run_n += 1
        else:
            run_val, run_start, run_n = r["cash"], r, 1
        if run_n == runlen:
            levels.append({"t": run_start["t"], "cash": run_val,
                           "eco": run_start["eco"], "round": run_start["round"],
                           "file": run_start["file"]})
    # Collapse consecutive levels that carry the same value.
    out = []
    for lv in levels:
        if out and out[-1]["cash"] == lv["cash"]:
            continue
        out.append(lv)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("hud_csv")
    ap.add_argument("--runlen", type=int, default=2,
                    help="consecutive equal readings before a cash level is believed")
    ap.add_argument("--min-cost", type=int, default=100,
                    help="ignore drops below this; the cheapest tower is 200")
    ap.add_argument("--eco-tol", type=float, default=1.0,
                    help="eco change tolerated within a purchase; a send raises eco")
    args = ap.parse_args()

    # The tracker prints startup lines to stdout before the CSV header, so the
    # file is not a bare CSV. Find the header rather than assuming line 1 —
    # DictReader would otherwise silently adopt "round table: 40 rounds ..." as
    # the field names and yield nothing usable.
    with open(args.hud_csv) as f:
        lines = f.read().splitlines()
    start = next((i for i, l in enumerate(lines) if l.startswith("file,t,cash")), None)
    if start is None:
        print(f"no 'file,t,cash...' header found in {args.hud_csv}", file=sys.stderr)
        return 1

    def num(r, k, cast):
        try:
            return cast((r.get(k) or "").strip())
        except (ValueError, TypeError):
            return None

    rows = []
    for r in csv.DictReader(lines[start:]):
        rows.append({"file": r["file"], "t": float(r["t"]),
                     "cash": num(r, "cash", int), "eco": num(r, "eco", float),
                     "round": num(r, "round", int)})

    levels = believed_levels(rows, args.runlen)
    purchases, sends, skipped_eco = [], [], 0
    for a, b in zip(levels, levels[1:]):
        d = b["cash"] - a["cash"]
        if d >= -args.min_cost:
            continue
        # A send costs cash AND raises eco. A tower costs cash and leaves eco
        # alone — that is the whole basis of the label.
        if a["eco"] is None or b["eco"] is None:
            skipped_eco += 1
            continue
        if b["eco"] - a["eco"] > args.eco_tol:
            sends.append({"t": b["t"], "cost": -d, "eco_gain": b["eco"] - a["eco"]})
            continue
        purchases.append({"t": b["t"], "cost": -d, "round": b["round"],
                          "file": b["file"], "cash_before": a["cash"],
                          "cash_after": b["cash"]})

    out = {
        "source": args.hud_csv,
        "frames": len(rows),
        "frames_with_cash": sum(1 for r in rows if r["cash"] is not None),
        "believed_levels": len(levels),
        "purchases": purchases,
        "sends_excluded": len(sends),
        "drops_skipped_no_eco": skipped_eco,
    }
    json.dump(out, sys.stdout, indent=2)
    print(file=sys.stderr)
    print(f"{len(rows)} frames, {out['frames_with_cash']} with cash, "
          f"{len(levels)} believed levels", file=sys.stderr)
    print(f"{len(purchases)} tower purchases, {len(sends)} sends excluded, "
          f"{skipped_eco} drops dropped for missing eco", file=sys.stderr)
    if purchases:
        costs = sorted(p["cost"] for p in purchases)
        print(f"costs: {costs}", file=sys.stderr)


if __name__ == "__main__":
    main()
