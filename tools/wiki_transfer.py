#!/usr/bin/env python3
"""Wiki-transfer test: can wiki tower art alone train a classifier that names a
tower in an in-match capture crop?

This is arm (B) of docs/tower-pricing-handoff.md section 5, preregistered in
eval/prereg_wiki_transfer.md. Read the prereg before reading any number this
prints — the read rule and the noise floor were fixed before the first run.

    tools/wiki_transfer.py --power        # exact null enumeration, no model
    tools/wiki_transfer.py --run          # all arms

Requires a venv with torch/torchvision/Pillow/numpy; pass --python to point at it.

The one design point worth defending: the test set's labels never come from
looking at the sprite. Every instance is named by cash arithmetic or by the
driver's own click log. Labelling in-match crops by eye would mean supplying the
classifier's answer from the same source that is supposed to be tested.
"""
import argparse, json, os, random, sys
from collections import Counter, defaultdict
from fractions import Fraction
from itertools import product, permutations

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = ROOT + "/tracker/out/"
SEED = 20260816

# --- test set -------------------------------------------------------------
# id -> session, centre x, centre y, t_lo, t_hi, class, how identity was established
INSTANCES = {
    "dart_114514": ("20260816T114514", 988, 357, 164, 176, "dart_monkey",
                    "truth.jsonl place event + cash 3900->3950 (+250 eco -200 dart)"),
    "boom_m1a":    ("20260816T124547", 498, 725,  61,  76, "boomerang_monkey",
                    "$325 purchase t=59.2; $325 is Boomerang base and no upgrade costs it"),
    "boom_m1b":    ("20260816T124547", 679, 714, 169, 195, "boomerang_monkey",
                    "$325 purchase t=167.9"),
    "boom_m2":     ("20260816T152152", 787, 928, 192, 196, "boomerang_monkey",
                    "$325 purchase t=190.5, different map"),
    "tack_koru":   ("20260816T115134", 467, 452,  98, 110, "tack_shooter",
                    "truth.jsonl preview_not_placed; RED-TINTED invalid-placement preview"),
    "bomb_koru":   ("20260816T115134", 350, 945, 147, 159, "bomb_shooter",
                    "truth.jsonl preview_not_placed; RED-TINTED preview under DEFEAT overlay"),
}
# EXPLORATORY, not part of the preregistered test set. Same two boomerangs after
# their upgrades landed, when the sprite has turned purple with a yellow X and no
# longer resembles the base portrait the wiki supplies. Identity is still solid —
# a tower's identity does not change when it is upgraded, and both were bought for
# $325 — but these were added AFTER the primary result was read, so they are
# reported separately and do not touch the headline.
UPGRADED = {
    "boom_m1a_up": ("20260816T124547", 498, 725, 170, 210, "boomerang_monkey",
                    "$325 at t=59.2, then upgrades $198/$982/$400 at t=80/116/130"),
    "boom_m1b_up": ("20260816T124547", 679, 714, 220, 290, "boomerang_monkey",
                    "$325 at t=167.9, then $480 at t=215.4"),
}
CLASSES = ["dart_monkey", "boomerang_monkey", "tack_shooter", "bomb_shooter"]
BOX = 128
FRAMES_PER_INSTANCE = 8

# in-game shop-panel cards, for the control arm. Labelled by the printed price,
# not by eye. Art region only — the price badge sits bottom-left and is excluded.
SHOP_CARDS = [
    ("20260816T114514", "f00560.png",      95, 355, 90, 62, "dart_monkey"),
    ("20260816T114514", "f00560.png",      95, 467, 90, 62, "tack_shooter"),
    ("20260816T114514", "f00560.png",      95, 579, 90, 62, "bomb_shooter"),
    ("20260816T124547", "f000071909.png",  95, 355, 90, 62, "boomerang_monkey"),
    ("20260816T124547", "f000071909.png",  95, 467, 90, 62, "bomb_shooter"),
    ("20260816T124547", "f000071909.png",  95, 579, 90, 62, "tack_shooter"),
]

# Board regions VERIFIED empty of towers, for background patches. Each was checked
# by rendering the board band, not assumed: the first pass at this used t=5 and
# t=20, which land on the loadout/hero-select MENU in three of the four sessions,
# so the "background" patches were full of shop icons and hero portraits — i.e.
# pictures of towers pasted behind the tower being learned. Bloons in frame are
# fine and wanted; they occur in the test crops too.
EMPTY_BG = [
    ("20260816T124547",  42.0), ("20260816T152152",  36.0),
    ("20260816T114514", 120.0), ("20260816T115134",  63.0),
]
BAND = (0.0742, 0.4844, 0.1102, 0.9918)   # left board x0,x1,y0,y1 normalised


# --- exact null -----------------------------------------------------------
def balanced_accuracy(truth, pred):
    per = []
    for c in CLASSES:
        idx = [i for i, t in enumerate(truth) if t == c]
        if not idx:
            continue
        per.append(Fraction(sum(1 for i in idx if pred[i] == c), len(idx)))
    return sum(per) / len(per)


def null_distribution(truth):
    """Every outcome of an information-free classifier, enumerated exactly."""
    dist = Counter()
    for pred in product(CLASSES, repeat=len(truth)):
        dist[balanced_accuracy(truth, pred)] += 1
    return dist


def p_value(dist, observed):
    tot = sum(dist.values())
    return sum(n for v, n in dist.items() if v >= observed) / tot


def cmd_power():
    truth = [INSTANCES[k][5] for k in INSTANCES]
    dist = null_distribution(truth)
    tot = sum(dist.values())
    print(f"test set: {len(truth)} instances, {len(CLASSES)} classes")
    print(f"  per class: {dict(Counter(truth))}")
    print(f"outcomes enumerated: {tot} = {len(CLASSES)}^{len(truth)}")
    print(f"E[balanced acc | null] = {float(sum(v * n for v, n in dist.items()) / tot):.4f}\n")
    print(f"{'bal_acc':>9} {'p(>=)':>10}")
    cum = 0
    for v in sorted(dist, reverse=True):
        cum += dist[v]
        print(f"{float(v):>9.4f} {cum / tot:>10.5f}   {'p<0.05' if cum / tot < 0.05 else ''}")


# --- imaging (only imported for --run) ------------------------------------
def _frames(session):
    d = OUT + session + "/"
    m = json.load(open(d + "manifest.json"))
    have = set(os.listdir(d))
    return d, [f for f in m["frames"] if f["file"] in have]


def load_test_crops(Image, jitter=0, rng=None):
    """id -> (class, [PIL crop] * FRAMES_PER_INSTANCE)

    `jitter` offsets each crop's centre by up to +-jitter px. The crop centres in
    INSTANCES were chosen by hand off a rendered frame, so they are an
    experimenter degree of freedom; jittering them tests whether the result rests
    on that choice."""
    out = {}
    for iid, (sess, cx, cy, lo, hi, cls, _) in INSTANCES.items():
        d, fr = _frames(sess)
        sel = [f for f in fr if lo <= f["t"] <= hi]
        step = max(1, len(sel) // FRAMES_PER_INSTANCE)
        sel = sel[::step][:FRAMES_PER_INSTANCE]
        crops = []
        for f in sel:
            dx = rng.randint(-jitter, jitter) if jitter and rng else 0
            dy = rng.randint(-jitter, jitter) if jitter and rng else 0
            x, y = cx + dx, cy + dy
            crops.append(Image.open(d + f["file"]).convert("RGB")
                         .crop((x - BOX // 2, y - BOX // 2, x + BOX // 2, y + BOX // 2)))
        out[iid] = (cls, crops)
    return out


def load_backgrounds(Image, rng, n=64):
    """Patches from board area of frames with no towers standing."""
    pats = []
    for sess, t in EMPTY_BG:
        d, fr = _frames(sess)
        f = min(fr, key=lambda f: abs(f["t"] - t))
        im = Image.open(d + f["file"]).convert("RGB")
        W, H = im.size
        x0, x1 = int(BAND[0] * W), int(BAND[1] * W)
        y0, y1 = int(BAND[2] * H), int(BAND[3] * H)
        for _ in range(n // len(EMPTY_BG)):
            px = rng.randint(x0, x1 - BOX)
            py = rng.randint(y0, y1 - BOX)
            pats.append(im.crop((px, py, px + BOX, py + BOX)))
    return pats


def trim_alpha(Image, im):
    im = im.convert("RGBA")
    bb = im.getbbox()
    return im.crop(bb) if bb else im


def augment(Image, ImageEnhance, src, bgs, n, rng, has_alpha):
    """One training image -> n composited 128px samples. Same policy for both arms;
    the wiki arm additionally gets true alpha, which is an advantage recorded in
    the prereg rather than corrected for."""
    outs = []
    for _ in range(n):
        s = src.copy()
        frac = rng.uniform(0.45, 0.85)
        target = int(BOX * frac)
        w, h = s.size
        k = target / max(w, h)
        s = s.resize((max(1, int(w * k)), max(1, int(h * k))), Image.LANCZOS)
        s = s.rotate(rng.uniform(0, 360), resample=Image.BICUBIC, expand=True)
        if rng.random() < 0.5:
            s = s.transpose(Image.FLIP_LEFT_RIGHT)
        bg = rng.choice(bgs).copy()
        ox = rng.randint(0, max(0, BOX - s.width))
        oy = rng.randint(0, max(0, BOX - s.height))
        if has_alpha:
            bg.paste(s.convert("RGB"), (ox, oy), s.split()[-1])
        else:
            bg.paste(s.convert("RGB"), (ox, oy))
        bg = ImageEnhance.Brightness(bg).enhance(rng.uniform(0.82, 1.18))
        bg = ImageEnhance.Color(bg).enhance(rng.uniform(0.80, 1.20))
        outs.append(bg)
    return outs


def build_extractor(torch, torchvision):
    m = torchvision.models.resnet18(
        weights=torchvision.models.ResNet18_Weights.IMAGENET1K_V1)
    m.fc = torch.nn.Identity()
    m.eval()
    return m


def featurise(torch, transforms, model, images, bs=64):
    tf = transforms.Compose([
        transforms.Resize((224, 224)),
        transforms.ToTensor(),
        transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
    ])
    outs = []
    with torch.no_grad():
        for i in range(0, len(images), bs):
            batch = torch.stack([tf(im) for im in images[i:i + bs]])
            f = model(batch)
            outs.append(torch.nn.functional.normalize(f, dim=1))
    return torch.cat(outs)


def centroids(torch, feats, labels):
    cs = {}
    for c in CLASSES:
        idx = [i for i, l in enumerate(labels) if l == c]
        if idx:
            cs[c] = torch.nn.functional.normalize(feats[idx].mean(0), dim=0)
    return cs


def predict(torch, cs, feats):
    names = list(cs)
    M = torch.stack([cs[n] for n in names])
    sim = feats @ M.T
    return [names[i] for i in sim.argmax(1).tolist()], sim


def cmd_run(args):
    import numpy as np, torch, torchvision
    from PIL import Image, ImageEnhance
    from torchvision import transforms

    random.seed(SEED); np.random.seed(SEED); torch.manual_seed(SEED)
    torch.use_deterministic_algorithms(False)
    rng = random.Random(SEED)

    print(f"seed={SEED}  torch={torch.__version__}  backbone=resnet18/IMAGENET1K_V1\n")

    test = load_test_crops(Image)
    truth = [test[k][0] for k in INSTANCES]
    dist = null_distribution(truth)

    bgs = load_backgrounds(Image, rng)
    model = build_extractor(torch, torchvision)

    all_test = [im for k in INSTANCES for im in test[k][1]]
    test_feats = featurise(torch, transforms, model, all_test)
    owner = [k for k in INSTANCES for _ in test[k][1]]

    def score(tag, train_imgs, train_labels):
        f = featurise(torch, transforms, model, train_imgs)
        cs = centroids(torch, f, train_labels)
        pred, _ = predict(torch, cs, test_feats)
        votes = defaultdict(list)
        for o, p in zip(owner, pred):
            votes[o].append(p)
        inst_pred = {k: Counter(v).most_common(1)[0][0] for k, v in votes.items()}
        pr = [inst_pred[k] for k in INSTANCES]
        ba = balanced_accuracy(truth, pr)
        p = p_value(dist, ba)
        print(f"--- arm {tag}")
        for k in INSTANCES:
            frac = Counter(votes[k]).most_common(1)[0][1] / len(votes[k])
            ok = "OK " if inst_pred[k] == test[k][0] else "   "
            print(f"  {ok}{k:13s} true={test[k][0]:17s} pred={inst_pred[k]:17s} "
                  f"({frac:.0%} of frames agree)")
        plain = sum(1 for k in INSTANCES if inst_pred[k] == test[k][0]) / len(INSTANCES)
        hit = sum(1 for c in CLASSES
                  if any(inst_pred[k] == c and test[k][0] == c for k in INSTANCES))
        print(f"  balanced_accuracy={float(ba):.4f}  plain_accuracy={plain:.4f}  "
              f"classes_with_a_hit={hit}/4  exact_p={p:.5f}")
        print(f"  prediction histogram: {dict(Counter(pr))}")
        return ba, p, hit, inst_pred

    # ---- arm A: wiki only (PRIMARY) ----
    wiki_dir = args.wiki
    wiki_files = {"dart_monkey": "000-DartMonkey.png",
                  "boomerang_monkey": "000-BoomerangMonkey.png",
                  "tack_shooter": "000-TackShooter.png",
                  "bomb_shooter": "000-BombShooter.png"}
    imgs, labs = [], []
    for cls, fn in wiki_files.items():
        src = trim_alpha(Image, Image.open(os.path.join(wiki_dir, fn)))
        for a in augment(Image, ImageEnhance, src, bgs, args.n_aug, rng, True):
            imgs.append(a); labs.append(cls)
    ba_a, p_a, hit_a, pred_a = score("A_wiki (PRIMARY)", imgs, labs)

    # ---- arm B: in-game shop icons ----
    imgs, labs = [], []
    for sess, fn, x, y, w, h, cls in SHOP_CARDS:
        src = Image.open(OUT + sess + "/" + fn).convert("RGB").crop((x, y, x + w, y + h))
        for a in augment(Image, ImageEnhance, src, bgs, args.n_aug // 2, rng, False):
            imgs.append(a); labs.append(cls)
    ba_b, p_b, hit_b, _ = score("B_shop_icons (control)", imgs, labs)

    # ---- arm I: instrument check, no training ----
    print("--- arm I_instrument (no training; can the features group same-class "
          "in-match crops at all?)")
    ic = {}
    for k in INSTANCES:
        idx = [i for i, o in enumerate(owner) if o == k]
        ic[k] = torch.nn.functional.normalize(test_feats[idx].mean(0), dim=0)
    keys = list(INSTANCES)
    print("      " + "".join(f"{k[:9]:>11s}" for k in keys))
    for a in keys:
        row = "".join(f"{float(ic[a] @ ic[b]):>11.3f}" for b in keys)
        print(f"  {a[:9]:>9s} {row}")
    nn_ok = 0
    boom = [k for k in keys if test[k][0] == "boomerang_monkey"]
    for a in boom:
        others = [b for b in keys if b != a]
        nn = max(others, key=lambda b: float(ic[a] @ ic[b]))
        same = test[nn][0] == test[a][0]
        nn_ok += same
        print(f"  nearest-other of {a}: {nn} (same class: {same})")
    print(f"  boomerang nearest-neighbour-same-class: {nn_ok}/{len(boom)}")

    # ---- arm C: label-permutation null on the wiki mapping ----
    print("\n--- arm C_null (secondary: all 4! permutations of wiki image -> class name)")
    srcs = {cls: trim_alpha(Image, Image.open(os.path.join(wiki_dir, fn)))
            for cls, fn in wiki_files.items()}
    perm_scores = []
    base_imgs = {cls: augment(Image, ImageEnhance, srcs[cls], bgs, args.n_aug, rng, True)
                 for cls in CLASSES}
    base_feats = {cls: featurise(torch, transforms, model, base_imgs[cls])
                  for cls in CLASSES}
    for perm in permutations(CLASSES):
        cs = {name: torch.nn.functional.normalize(base_feats[src].mean(0), dim=0)
              for name, src in zip(CLASSES, perm)}
        pred, _ = predict(torch, cs, test_feats)
        votes = defaultdict(list)
        for o, p in zip(owner, pred):
            votes[o].append(p)
        ip = {k: Counter(v).most_common(1)[0][0] for k, v in votes.items()}
        perm_scores.append(float(balanced_accuracy(truth, [ip[k] for k in INSTANCES])))
    ident = perm_scores[0]
    better = sum(1 for s in perm_scores if s >= ident)
    print(f"  identity mapping balanced_acc={ident:.4f}")
    print(f"  permutation scores: {sorted(round(s,3) for s in perm_scores)}")
    print(f"  rank of identity: {better}/24  -> permutation p={better/24:.4f}")

    # ---- verdict against the preregistered read rule ----
    print("\n=== READ RULE (eval/prereg_wiki_transfer.md) ===")
    print(f"  PASS needs balanced_acc>=0.75 AND exact_p<0.05 AND classes_with_a_hit>=3")
    v = ("PASS" if (ba_a >= Fraction(3, 4) and p_a < 0.05 and hit_a >= 3)
         else "FAIL" if ba_a <= Fraction(1, 2) else "INCONCLUSIVE")
    print(f"  arm A: balanced_acc={float(ba_a):.4f} exact_p={p_a:.5f} hits={hit_a}/4 "
          f"-> {v}")
    print(f"  arm B (control): balanced_acc={float(ba_b):.4f} exact_p={p_b:.5f}")


def _mc_null(truth, n_candidates, draws=200000, seed=7):
    """Balanced-accuracy null when the classifier picks uniformly among
    n_candidates classes. Enumeration is only tractable for small candidate
    sets, so this is Monte Carlo with a stated draw count."""
    r = random.Random(seed)
    idx = {c: [i for i, t in enumerate(truth) if t == c] for c in set(truth)}
    out = []
    for _ in range(draws):
        pred = [r.randrange(n_candidates) for _ in truth]
        # candidate 0 stands for "the true class of this instance"
        acc = []
        for c, ii in idx.items():
            acc.append(sum(1 for i in ii if pred[i] == 0) / len(ii))
        out.append(sum(acc) / len(acc))
    out.sort()
    return out


def _colour_feats(np, images, bins=8):
    """The dumbest baseline that could work: a coarse RGB histogram, L2-normalised.
    If this scores as well as the CNN, the four towers are separable on colour
    alone and the CNN result says nothing about a harder label space."""
    import numpy as _np
    out = []
    for im in images:
        a = _np.asarray(im).reshape(-1, 3)
        h, _ = _np.histogramdd(a, bins=(bins, bins, bins),
                               range=((0, 256), (0, 256), (0, 256)))
        h = h.ravel().astype("float32")
        n = (h ** 2).sum() ** 0.5
        out.append(h / (n + 1e-9))
    return _np.stack(out)


def cmd_expand(args):
    """Same 6 in-match crops, same wiki training recipe, but the candidate set
    grows from the 4 owned towers to all 22. No new labels are needed — only the
    number of ways to be wrong changes. This is the test of whether the 4-class
    result means anything for the real target."""
    import numpy as np, torch, torchvision
    from PIL import Image, ImageEnhance
    from torchvision import transforms

    seed = SEED
    random.seed(seed); np.random.seed(seed); torch.manual_seed(seed)
    rng = random.Random(seed)
    model = build_extractor(torch, torchvision)
    bgs = load_backgrounds(Image, rng)
    test = load_test_crops(Image)
    truth = [test[k][0] for k in INSTANCES]
    all_test = [im for k in INSTANCES for im in test[k][1]]
    owner = [k for k in INSTANCES for _ in test[k][1]]
    tfeat = featurise(torch, transforms, model, all_test)

    files = sorted(os.listdir(args.wiki22))
    names = [f.replace("000-", "").replace(".png", "") for f in files]
    # map wiki file names onto the class names this test set uses
    alias = {"DartMonkey": "dart_monkey", "BoomerangMonkey": "boomerang_monkey",
             "TackShooter": "tack_shooter", "BombShooter": "bomb_shooter"}
    labels = [alias.get(n, n) for n in names]
    print(f"candidate set: {len(labels)} towers")

    imgs, labs = [], []
    for fn, lab in zip(files, labels):
        src = trim_alpha(Image, Image.open(os.path.join(args.wiki22, fn)))
        for a in augment(Image, ImageEnhance, src, bgs, args.n_aug, rng, True):
            imgs.append(a); labs.append(lab)
    f = featurise(torch, transforms, model, imgs)
    cs = {}
    for c in set(labs):
        ii = [i for i, l in enumerate(labs) if l == c]
        cs[c] = torch.nn.functional.normalize(f[ii].mean(0), dim=0)
    nm = list(cs)
    M = torch.stack([cs[n] for n in nm])
    sim = tfeat @ M.T
    pred = [nm[i] for i in sim.argmax(1).tolist()]
    votes = defaultdict(list)
    for o, p in zip(owner, pred):
        votes[o].append(p)
    ip = {k: Counter(v).most_common(1)[0][0] for k, v in votes.items()}
    for k in INSTANCES:
        ok = "OK " if ip[k] == test[k][0] else "   "
        top = Counter(votes[k]).most_common(3)
        print(f"  {ok}{k:13s} true={test[k][0]:17s} pred={ip[k]:17s}  frame votes={top}")
    ba = balanced_accuracy(truth, [ip[k] for k in INSTANCES])
    plain = sum(1 for k in INSTANCES if ip[k] == test[k][0]) / len(INSTANCES)
    null = _mc_null(truth, len(cs))
    p = sum(1 for v in null if v >= float(ba)) / len(null)
    print(f"\n  balanced_accuracy={float(ba):.4f}  plain_accuracy={plain:.4f}")
    print(f"  null (uniform over {len(cs)} candidates, 200k draws): "
          f"mean={sum(null)/len(null):.4f} p95={null[int(.95*len(null))]:.4f}")
    print(f"  p={p:.5f}")


def cmd_dumb(args):
    """Arm A re-run with an 8x8x8 RGB histogram in place of the CNN."""
    import numpy as np
    from PIL import Image, ImageEnhance

    random.seed(SEED); rng = random.Random(SEED)
    bgs = load_backgrounds(Image, rng)
    test = load_test_crops(Image)
    truth = [test[k][0] for k in INSTANCES]
    all_test = [im for k in INSTANCES for im in test[k][1]]
    owner = [k for k in INSTANCES for _ in test[k][1]]
    tf = _colour_feats(np, all_test)
    wiki_files = {"dart_monkey": "000-DartMonkey.png",
                  "boomerang_monkey": "000-BoomerangMonkey.png",
                  "tack_shooter": "000-TackShooter.png",
                  "bomb_shooter": "000-BombShooter.png"}
    imgs, labs = [], []
    for cls, fn in wiki_files.items():
        src = trim_alpha(Image, Image.open(os.path.join(args.wiki, fn)))
        for a in augment(Image, ImageEnhance, src, bgs, args.n_aug, rng, True):
            imgs.append(a); labs.append(cls)
    f = _colour_feats(np, imgs)
    cs, nm = [], []
    for c in CLASSES:
        ii = [i for i, l in enumerate(labs) if l == c]
        v = f[ii].mean(0); cs.append(v / (np.linalg.norm(v) + 1e-9)); nm.append(c)
    M = np.stack(cs)
    pred = [nm[i] for i in (tf @ M.T).argmax(1)]
    votes = defaultdict(list)
    for o, p in zip(owner, pred):
        votes[o].append(p)
    ip = {k: Counter(v).most_common(1)[0][0] for k, v in votes.items()}
    for k in INSTANCES:
        ok = "OK " if ip[k] == test[k][0] else "   "
        print(f"  {ok}{k:13s} true={test[k][0]:17s} pred={ip[k]}")
    ba = balanced_accuracy(truth, [ip[k] for k in INSTANCES])
    dist = null_distribution(truth)
    print(f"\n  colour-histogram balanced_accuracy={float(ba):.4f} "
          f"exact_p={p_value(dist, ba):.5f}")


def cmd_upgraded(args):
    """EXPLORATORY. Arm A's wiki-trained classifier applied to the same towers
    after they were upgraded. The wiki carries base-tier portraits only, and the
    opponent's board — the board this whole system exists to price — is mostly
    upgraded towers, so this is the case that decides whether the base-tier PASS
    is worth anything operationally."""
    import numpy as np, torch, torchvision
    from PIL import Image, ImageEnhance
    from torchvision import transforms

    random.seed(SEED); np.random.seed(SEED); torch.manual_seed(SEED)
    rng = random.Random(SEED)
    model = build_extractor(torch, torchvision)
    bgs = load_backgrounds(Image, rng)

    saved = dict(INSTANCES)
    INSTANCES.clear(); INSTANCES.update(UPGRADED)
    try:
        test = load_test_crops(Image)
        all_test = [im for k in UPGRADED for im in test[k][1]]
        owner = [k for k in UPGRADED for _ in test[k][1]]
    finally:
        INSTANCES.clear(); INSTANCES.update(saved)

    tf = featurise(torch, transforms, model, all_test)
    alias = {"DartMonkey": "dart_monkey", "BoomerangMonkey": "boomerang_monkey",
             "TackShooter": "tack_shooter", "BombShooter": "bomb_shooter"}
    if args.wide:
        d = args.wiki22
        pairs = [(alias.get(f.replace("000-", "").replace(".png", ""),
                            f.replace("000-", "").replace(".png", "")), f)
                 for f in sorted(os.listdir(d))]
    else:
        d = args.wiki
        pairs = [("dart_monkey", "000-DartMonkey.png"),
                 ("boomerang_monkey", "000-BoomerangMonkey.png"),
                 ("tack_shooter", "000-TackShooter.png"),
                 ("bomb_shooter", "000-BombShooter.png")]
    print(f"  candidate set: {len(pairs)} towers")
    imgs, labs = [], []
    for cls, fn in pairs:
        src = trim_alpha(Image, Image.open(os.path.join(d, fn)))
        for a in augment(Image, ImageEnhance, src, bgs, args.n_aug, rng, True):
            imgs.append(a); labs.append(cls)
    f = featurise(torch, transforms, model, imgs)
    cs = {}
    for c in set(labs):
        ii = [i for i, l in enumerate(labs) if l == c]
        cs[c] = torch.nn.functional.normalize(f[ii].mean(0), dim=0)
    pred, _ = predict(torch, cs, tf)
    votes = defaultdict(list)
    for o, p in zip(owner, pred):
        votes[o].append(p)
    right = 0
    for k in UPGRADED:
        ip = Counter(votes[k]).most_common(1)[0][0]
        ok = ip == UPGRADED[k][5]
        right += ok
        print(f"  {'OK ' if ok else '   '}{k:13s} true={UPGRADED[k][5]:17s} "
              f"pred={ip:17s} frame votes={Counter(votes[k]).most_common(3)}")
    print(f"\n  upgraded-tier instances correct: {right}/{len(UPGRADED)} "
          f"(chance 1/4 each; descriptive only, too few for a significance claim)")


def cmd_robust(args):
    """Stability of arm A across augmentation seeds and test-crop jitter.

    A result that only holds for one seed, or only for the crop boxes the
    experimenter drew by hand, is not a result. This is the S1 gate."""
    import numpy as np, torch, torchvision
    from PIL import Image, ImageEnhance
    from torchvision import transforms

    model = build_extractor(torch, torchvision)
    wiki_files = {"dart_monkey": "000-DartMonkey.png",
                  "boomerang_monkey": "000-BoomerangMonkey.png",
                  "tack_shooter": "000-TackShooter.png",
                  "bomb_shooter": "000-BombShooter.png"}
    truth = [INSTANCES[k][5] for k in INSTANCES]
    dist = null_distribution(truth)
    print(f"{'seed':>6} {'jitter':>7} {'bal_acc':>9} {'plain':>7} {'p':>9}   per-instance")
    rows = []
    wrong = Counter()
    for jit in args.jitters:
        for s in range(args.seeds):
            seed = SEED + s
            random.seed(seed); np.random.seed(seed % (2**31)); torch.manual_seed(seed)
            rng = random.Random(seed)
            bgs = load_backgrounds(Image, rng)
            test = load_test_crops(Image, jitter=jit, rng=rng)
            all_test = [im for k in INSTANCES for im in test[k][1]]
            owner = [k for k in INSTANCES for _ in test[k][1]]
            tf = featurise(torch, transforms, model, all_test)
            imgs, labs = [], []
            for cls, fn in wiki_files.items():
                src = trim_alpha(Image, Image.open(os.path.join(args.wiki, fn)))
                for a in augment(Image, ImageEnhance, src, bgs, args.n_aug, rng, True):
                    imgs.append(a); labs.append(cls)
            f = featurise(torch, transforms, model, imgs)
            cs = centroids(torch, f, labs)
            pred, _ = predict(torch, cs, tf)
            votes = defaultdict(list)
            for o, p in zip(owner, pred):
                votes[o].append(p)
            ip = {k: Counter(v).most_common(1)[0][0] for k, v in votes.items()}
            pr = [ip[k] for k in INSTANCES]
            ba = balanced_accuracy(truth, pr)
            plain = sum(1 for k in INSTANCES if ip[k] == INSTANCES[k][5]) / len(INSTANCES)
            for k in INSTANCES:
                if ip[k] != INSTANCES[k][5]:
                    wrong[k] += 1
            rows.append(float(ba))
            marks = "".join("." if ip[k] == INSTANCES[k][5] else "X" for k in INSTANCES)
            print(f"{seed:>6} {jit:>7} {float(ba):>9.4f} {plain:>7.3f} "
                  f"{p_value(dist, ba):>9.5f}   {marks}")
    n = len(rows)
    print(f"\n  instance order: {list(INSTANCES)}")
    print(f"  runs={n}  balanced_acc min={min(rows):.4f} median="
          f"{sorted(rows)[n//2]:.4f} max={max(rows):.4f} mean={sum(rows)/n:.4f}")
    print(f"  runs meeting the PASS bar (>=0.75): "
          f"{sum(1 for r in rows if r >= 0.75)}/{n}")
    print(f"  runs at or below the FAIL bar (<=0.50): "
          f"{sum(1 for r in rows if r <= 0.50)}/{n}")
    print(f"  per-instance error counts (out of {n}): {dict(wrong)}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--power", action="store_true")
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--robust", action="store_true")
    ap.add_argument("--expand22", action="store_true")
    ap.add_argument("--dumb", action="store_true")
    ap.add_argument("--upgraded", action="store_true")
    ap.add_argument("--wide", action="store_true",
                    help="with --upgraded: score against all 22 candidates")
    ap.add_argument("--wiki22", default="wiki22", help="dir with all 22 portraits")
    ap.add_argument("--seeds", type=int, default=10)
    ap.add_argument("--jitters", type=int, nargs="+", default=[0, 8, 16])
    ap.add_argument("--wiki", default="wiki", help="dir with 000-*.png wiki portraits")
    ap.add_argument("--n-aug", type=int, default=200)
    a = ap.parse_args()
    if a.power:
        cmd_power()
    elif a.run:
        cmd_run(a)
    elif a.robust:
        cmd_robust(a)
    elif a.expand22:
        cmd_expand(a)
    elif a.dumb:
        cmd_dumb(a)
    elif a.upgraded:
        cmd_upgraded(a)
    else:
        ap.print_help()
