#!/usr/bin/env python3
"""Score a replayed census against ground truth.

    ./tracker --replay <session> --census-log census.jsonl
    tools/own_truth.py hud.csv > truth_own.json
    tools/score.py census.jsonl --own truth_own.json [--checkpoints truth_opp.json]

Three things are reported, and the third is the one that stops a number being
self-congratulatory:

  arrival recall   of the purchases known to have happened on YOUR board, how
                   many produced a new confirmed site in the window after them
  false positives  confirmed sites that match no purchase, per minute
  chance baseline  what a detector that emitted the SAME NUMBER of sites at
                   uniformly random times would have scored

Without the third, "found 3 of 7" is unreadable. Sites cluster near the path and
purchases are spread over a few minutes, so a generous window plus a few random
guesses can look like a working detector. The null is computed by simulation
against the real purchase times, not from a formula, so it inherits whatever
clustering the real timeline has.

Opponent-side checkpoints are optional and positional:

    {"checkpoints": [{"t": 120.0, "towers": [{"cx": 1800, "cy": 700}, ...]}]}

Positions are FRAME pixels, matching the census log. There is no way to derive
these from the game, so they come from a human looking at frames.
"""
import json, sys, argparse, random


def load_census(path):
    recs = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                recs.append(json.loads(line))
    recs.sort(key=lambda r: r["t"])
    return recs


def first_appearances(recs, board):
    """When each site id was first CONFIRMED, keyed by id.

    The census log only ever contains confirmed sites, so the first record a
    site appears in is the moment it became part of the books. `firstSeen` is
    earlier — it is when the candidate was created — and is kept alongside
    because a purchase is better matched against candidate creation than
    against confirmation two census cycles later.
    """
    seen = {}
    for r in recs:
        for s in r[board]:
            if s["id"] not in seen:
                seen[s["id"]] = {"confirmed_t": r["t"], "first_seen": s["firstSeen"],
                                 "cx": s["cx"], "cy": s["cy"], "cost": s["cost"],
                                 "priced": s["priced"]}
    return seen


def match_arrivals(purchases, arrivals, pre, post):
    """Greedy one-to-one match of purchases to site arrivals.

    One-to-one matters: without it a single spurious site sitting in the middle
    of a busy stretch could be credited with satisfying every purchase around
    it, and recall would rise with the detector's error rate.
    """
    unused = sorted(arrivals.items(), key=lambda kv: kv[1]["first_seen"])
    hits, misses = [], []
    for p in sorted(purchases, key=lambda p: p["t"]):
        best = None
        for sid, a in unused:
            gap = a["first_seen"] - p["t"]
            if -pre <= gap <= post and (best is None or gap < best[1]["first_seen"] - p["t"]):
                best = (sid, a)
        if best:
            hits.append({"purchase": p, "site": best[0], "gap": best[1]["first_seen"] - p["t"]})
            unused = [(s, a) for s, a in unused if s != best[0]]
        else:
            misses.append(p)
    return hits, misses, dict(unused)


def chance_recall(purchases, n_sites, t0, t1, pre, post, trials=2000, seed=0):
    """Recall a detector would get emitting n_sites at uniformly random times."""
    if not purchases or n_sites == 0:
        return 0.0
    rng = random.Random(seed)
    total = 0
    for _ in range(trials):
        fake = {i: {"first_seen": rng.uniform(t0, t1)} for i in range(n_sites)}
        hits, _, _ = match_arrivals(purchases, fake, pre, post)
        total += len(hits) / len(purchases)
    return total / trials


def score_checkpoints(recs, checkpoints, tol, max_gap=5.0):
    """Score each labelled board state against the nearest census record.

    A checkpoint the census does not actually cover is SKIPPED, not scored
    against whatever record happens to be closest. Silently comparing a t=330
    label against a t=90 frame would report a real-looking zero that says
    nothing about the detector.
    """
    out = []
    for cp in checkpoints:
        near = min(recs, key=lambda r: abs(r["t"] - cp["t"]))
        gap = abs(near["t"] - cp["t"])
        if gap > max_gap:
            out.append({"t": cp["t"], "frame_t": near["t"], "gap": gap,
                        "skipped": True, "truth": len(cp["towers"])})
            continue
        det = near["theirs"]
        truth = cp["towers"]
        unused = list(det)
        tp = 0
        for t in truth:
            best, bd = None, tol + 1
            for d in unused:
                dist = ((d["cx"] - t["cx"]) ** 2 + (d["cy"] - t["cy"]) ** 2) ** 0.5
                if dist < bd:
                    best, bd = d, dist
            if best is not None and bd <= tol:
                tp += 1
                unused.remove(best)
        out.append({"t": cp["t"], "frame_t": near["t"], "gap": gap,
                    "skipped": False, "truth": len(truth),
                    "detected": len(det), "matched": tp,
                    "recall": tp / len(truth) if truth else None,
                    "precision": tp / len(det) if det else None})
    return out


def placement_null(recs, checkpoints, tol, draws=300, seed=0, max_gap=5.0):
    """What recall you get by scattering the SAME number of sites at random.

    This is the control that catches recall bought by carpeting: a detector that
    emits forty blobs across a board will cover a lot of it by accident. Sites
    are drawn uniformly over the board's bounding box, which is generous to the
    null in one direction (it can land on the path, where no tower can be) and
    stingy in another (real towers cluster). It is a floor, not a perfect model.
    """
    xs = [s["cx"] for r in recs for s in r["theirs"]]
    ys = [s["cy"] for r in recs for s in r["theirs"]]
    if not xs:
        return None
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    rng = random.Random(seed)
    out = []
    for _ in range(draws):
        tp = tot = 0
        for cp in checkpoints:
            near = min(recs, key=lambda r: abs(r["t"] - cp["t"]))
            if abs(near["t"] - cp["t"]) > max_gap:
                continue
            n = len(near["theirs"])
            fake = [{"cx": rng.uniform(x0, x1), "cy": rng.uniform(y0, y1)} for _ in range(n)]
            for t in cp["towers"]:
                hit = None
                for d in fake:
                    if ((d["cx"]-t["cx"])**2 + (d["cy"]-t["cy"])**2) ** 0.5 <= tol:
                        hit = d
                        break
                if hit:
                    tp += 1
                    fake.remove(hit)
            tot += len(cp["towers"])
        out.append(tp / tot if tot else 0.0)
    out.sort()
    return {"median": out[len(out)//2], "p95": out[int(0.95*len(out))], "draws": draws}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("census")
    ap.add_argument("--own", help="truth_own.json from own_truth.py")
    ap.add_argument("--checkpoints", help="hand-labelled opponent board states")
    ap.add_argument("--pre", type=float, default=1.0)
    ap.add_argument("--post", type=float, default=15.0)
    ap.add_argument("--tol", type=float, default=90.0,
                    help="frame px a detected site may be from a labelled one")
    args = ap.parse_args()

    recs = load_census(args.census)
    if not recs:
        print("census log is empty — did the replay run?")
        return 1
    t0, t1 = recs[0]["t"], recs[-1]["t"]
    dur = t1 - t0
    mine = first_appearances(recs, "mine")
    theirs = first_appearances(recs, "theirs")

    print(f"census: {len(recs)} frames, {dur:.1f}s, side={recs[0].get('side')}")
    print(f"  sites ever confirmed:  yours {len(mine)}   theirs {len(theirs)}")
    peak_mine = max(len(r["mine"]) for r in recs)
    peak_theirs = max(len(r["theirs"]) for r in recs)
    print(f"  peak simultaneous:     yours {peak_mine}   theirs {peak_theirs}")

    if args.own:
        truth = json.load(open(args.own))
        purchases = truth["purchases"]
        hits, misses, spurious = match_arrivals(purchases, mine, args.pre, args.post)
        n = len(purchases)
        print(f"\nown-board arrival recall  (window -{args.pre}s .. +{args.post}s)")
        print(f"  purchases in truth:    {n}")
        print(f"  matched by a site:     {len(hits)}"
              + (f"   recall {len(hits)/n:.1%}" if n else ""))
        print(f"  missed:                {len(misses)}")
        print(f"  sites matching nothing:{len(spurious)}"
              + (f"   {len(spurious)/(dur/60):.2f}/min" if dur else ""))
        base = chance_recall(purchases, len(mine), t0, t1, args.pre, args.post)
        print(f"  chance recall at {len(mine)} random sites: {base:.1%}")
        if n and len(hits) / n <= base:
            print("  -> NOT distinguishable from chance")
        # An upgrade is a cash drop with flat eco exactly like a purchase, but it
        # changes an existing tower instead of adding one, so no new site can
        # ever appear for it. Cash cannot tell the two apart, so this recall is a
        # LOWER bound: the true denominator is the number of purchases that were
        # actually new placements, which is at most n.
        print("  note: some purchases are upgrades, which cannot produce a new"
              " site — treat this recall as a lower bound")
        for m in misses[:10]:
            print(f"     missed ${m['cost']} at t={m['t']:.1f}s (R{m['round']})")

    if args.checkpoints:
        cps = json.load(open(args.checkpoints))["checkpoints"]
        print(f"\nopponent census at {len(cps)} checkpoints (tol {args.tol}px)")
        rows = score_checkpoints(recs, cps, args.tol)
        scored = [r for r in rows if not r["skipped"]]
        for r in rows:
            if r["skipped"]:
                print(f"  t={r['t']:6.1f}s  SKIPPED — census only reaches "
                      f"{r['frame_t']:.1f}s ({r['gap']:.1f}s away)")
            else:
                print(f"  t={r['t']:6.1f}s  truth {r['truth']:2d}  detected {r['detected']:2d}"
                      f"  matched {r['matched']:2d}")
        tt = sum(r["truth"] for r in scored)
        td = sum(r["detected"] for r in scored)
        tm = sum(r["matched"] for r in scored)
        if not scored:
            print("  TOTAL  nothing scored — census does not cover any checkpoint")
        else:
            print(f"  TOTAL  recall {tm/tt:.1%} over {len(scored)}/{len(rows)} checkpoints"
                  if tt else "  TOTAL  no truth")
            if td:
                print(f"         precision {tm/td:.1%}")
            null = placement_null(recs, cps, args.tol)
            if null:
                print(f"  placement null at the same site counts:"
                      f" median {null['median']:.1%}, p95 {null['p95']:.1%}"
                      f" ({null['draws']} draws)")
                if tt and tm / tt <= null["p95"]:
                    print("  -> recall does NOT clear the null's 95th percentile")
    else:
        print("\nopponent census: no checkpoint labels — recall on their board is UNMEASURED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
