// Tower sprites: describing them, matching them, and learning what they cost.
//
// The asset catalogue is encrypted, which this project has more than once
// treated as the end of the road for identifying towers. It is not — the assets
// are not needed. YOUR cash is on the HUD and parsed every frame, so a drop of
// exactly $X that is not a send is a purchase of exactly $X, and at that instant
// something on YOUR board changed. Crop it and you have a sprite labelled with a
// price, harvested from pixels the game already drew. Persist that across
// matches and the library fills itself in. This is the same move the eco
// constants already make: measure it on your own side, where truth is free.
//
// The descriptor has to survive three things the game does to a sprite:
//
//   rotation   towers face their target, so every component here is computed
//              over radial rings or global histograms — nothing depends on
//              which way the monkey is pointing
//   animation  firing changes the sprite frame to frame, so the descriptor is
//              coarse on purpose; exact pixels would never match twice
//   occlusion  bloons and projectiles pass over, so no single bin is decisive
//
// What it deliberately does NOT try to be is a classifier of tower NAMES. It
// only has to answer "is this the same appearance as something I have priced
// before", which is a much easier question and the only one the books need.

import Foundation

/// A rotation-invariant summary of one tower's appearance.
struct SpriteDescriptor: Codable {
    /// Hue occupancy in 12 bins of 30°, over saturated pixels only. This is the
    /// component that separates a green-helmet sniper from a black/orange one.
    var hueHist: [Double]
    /// Mean saturation and brightness in 4 concentric rings, outermost last.
    /// Captures layout — a dark hat over a bright body — without caring which
    /// way it is turned.
    var ringSat: [Double]
    var ringBright: [Double]
    /// Fraction of dark pixels. Cartoon sprites carry heavy outlines; flat map
    /// and bloons do not.
    var darkFrac: Double
    /// Mean local gradient. The single strongest "is this a sprite at all"
    /// signal: measured 0.005 on the match-start curtain, 0.067 on bare map,
    /// 0.147–0.334 on real towers.
    var edgeDensity: Double
    /// Blob size in grid samples, as a weak scale cue.
    var areaSamples: Int

    static let rings = 4
    static let hueBins = 12

    /// Distance in [0, ~1]. Weighted so appearance dominates and size is only a
    /// tiebreak — an upgrade can change a sprite's size a lot without it
    /// becoming a different tower.
    func distance(to o: SpriteDescriptor) -> Double {
        var hueD = 0.0
        for i in 0..<min(hueHist.count, o.hueHist.count) { hueD += abs(hueHist[i] - o.hueHist[i]) }
        hueD /= 2.0   // two normalised histograms differ by at most 2 in L1

        var ringD = 0.0
        for i in 0..<min(ringSat.count, o.ringSat.count) {
            ringD += abs(ringSat[i] - o.ringSat[i]) + abs(ringBright[i] - o.ringBright[i])
        }
        ringD /= Double(max(1, ringSat.count) * 2)

        let darkD = abs(darkFrac - o.darkFrac)
        let edgeD = min(1.0, abs(edgeDensity - o.edgeDensity) / 0.35)
        let areaD = min(1.0, abs(Double(areaSamples - o.areaSamples))
                             / Double(max(areaSamples, o.areaSamples, 1)))

        return 0.42 * hueD + 0.28 * ringD + 0.12 * darkD + 0.10 * edgeD + 0.08 * areaD
    }
}

/// One priced appearance. `cumulativeCost` is TOTAL money sunk into a tower that
/// currently looks like this — base plus every upgrade — which is what makes
/// board value a pure function of the census rather than a running sum.
struct SpriteEntry: Codable {
    var descriptor: SpriteDescriptor
    var cumulativeCost: Int
    var timesSeen: Int
    /// Where it was learned, for auditing a library that looks wrong.
    var learnedNote: String
}

/// Persisted across matches, because a library that resets every launch never
/// gets past the towers you happened to build in the first two minutes.
final class SpriteLibrary {
    private(set) var entries: [SpriteEntry] = []
    /// Entries dropped at load for holding a price no legal board could produce,
    /// and learn attempts rejected for the same reason. Both are reported rather
    /// than swallowed: a rejection means the harvester paired a cash move with
    /// the wrong board change, and that is a bug worth seeing, not a tidy-up.
    private(set) var purgedAtLoad: [String] = []
    private(set) var rejectedLearns = 0
    private let path: String
    /// Below this distance two appearances are considered the same thing.
    ///
    /// Set from a measured separation, not picked: across three towers seen in
    /// three capture frames 15s apart, the same tower re-read at most 0.224
    /// away from itself, while different towers were never closer than 0.302.
    /// This sits in that gap. An earlier value of 0.16 was below the noise
    /// floor, so a tower failed to match ITSELF and every site read as unpriced.
    ///
    /// The evidence is thin — 5 within-pairs and 16 between-pairs, one map, one
    /// dump — so treat it as provisional. The largest within-distance (0.224)
    /// may itself be a real upgrade rather than noise, which would mean the gap
    /// is considerably wider than it looks here.
    static let matchThreshold = 0.26

    init(path: String) {
        self.path = path
        if let d = FileManager.default.contents(atPath: path),
           let e = try? JSONDecoder().decode([SpriteEntry].self, from: d) {
            // The library persists across matches, so one bad pairing survives
            // every launch until something removes it. Bounds are the published
            // ones (PriceTable) — a stored price outside them is not a debatable
            // estimate, it is arithmetic that cannot have happened.
            entries = e.filter {
                guard PriceTable.isPlausibleCumulative($0.cumulativeCost) else {
                    purgedAtLoad.append("$\($0.cumulativeCost) (\($0.learnedNote), seen \($0.timesSeen)x)")
                    return false
                }
                return true
            }
            if !purgedAtLoad.isEmpty { save() }
        }
    }

    var count: Int { entries.count }

    /// Closest known appearance, if anything is close enough.
    func match(_ d: SpriteDescriptor) -> (index: Int, entry: SpriteEntry, distance: Double)? {
        var best: (Int, SpriteEntry, Double)?
        for (i, e) in entries.enumerated() {
            let dist = d.distance(to: e.descriptor)
            if dist < (best?.2 ?? .greatestFiniteMagnitude) { best = (i, e, dist) }
        }
        guard let b = best, b.2 <= Self.matchThreshold else { return nil }
        return (b.0, b.1, b.2)
    }

    enum LearnOutcome {
        case learned
        /// The price is outside what any legal board could produce, so the cash
        /// move was paired with the wrong board change. Reported, never stored.
        case rejected(reason: String)
    }

    /// Record an appearance and what it cost in total. An existing entry is
    /// averaged into rather than replaced, so one noisy crop cannot poison a
    /// price that many observations agree on.
    @discardableResult
    func learn(_ d: SpriteDescriptor, cumulativeCost: Int, note: String) -> LearnOutcome {
        guard PriceTable.isPlausibleCumulative(cumulativeCost) else {
            rejectedLearns += 1
            let bound = cumulativeCost < PriceTable.minPaidCost
                ? "below the $\(PriceTable.minPaidCost) cheapest possible purchase (\(PriceTable.minTowerCost) less max village discount)"
                : "above the $\(PriceTable.maxLegalCumulative) dearest legal site"
            return .rejected(reason: "$\(cumulativeCost) is \(bound)")
        }
        if let m = match(d) {
            var e = entries[m.index]
            let n = Double(e.timesSeen)
            e.cumulativeCost = Int((Double(e.cumulativeCost) * n + Double(cumulativeCost)) / (n + 1))
            e.timesSeen += 1
            entries[m.index] = e
        } else {
            entries.append(SpriteEntry(descriptor: d, cumulativeCost: cumulativeCost,
                                       timesSeen: 1, learnedNote: note))
        }
        save()
        return .learned
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(entries) else { return }
        try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// Build a descriptor by sampling a bounding box on a fixed polar-ish grid.
/// Sampling density is fixed rather than per-pixel so the cost does not grow
/// with sprite size and so two sprites of different size stay comparable.
func describeSprite(_ frame: Frame, x0: Int, y0: Int, x1: Int, y1: Int,
                    areaSamples: Int) -> SpriteDescriptor? {
    let w = x1 - x0, h = y1 - y0
    guard w > 8, h > 8 else { return nil }

    let n = 28                       // n x n samples across the box
    let cx = Double(w) / 2, cy = Double(h) / 2
    let maxR = sqrt(cx * cx + cy * cy)

    var hue = [Double](repeating: 0, count: SpriteDescriptor.hueBins)
    var satSum = [Double](repeating: 0, count: SpriteDescriptor.rings)
    var brtSum = [Double](repeating: 0, count: SpriteDescriptor.rings)
    var ringN = [Double](repeating: 0, count: SpriteDescriptor.rings)
    var dark = 0.0, edge = 0.0, total = 0.0, hueTotal = 0.0

    for iy in 0..<n {
        for ix in 0..<n {
            let fx = Double(ix) / Double(n - 1), fy = Double(iy) / Double(n - 1)
            let px = x0 + Int(fx * Double(w)), py = y0 + Int(fy * Double(h))
            guard let c = frame.hsb(x: px, y: py) else { continue }

            let dx = Double(px - x0) - cx, dy = Double(py - y0) - cy
            let r = sqrt(dx * dx + dy * dy) / max(maxR, 1)
            let ring = min(SpriteDescriptor.rings - 1, Int(r * Double(SpriteDescriptor.rings)))
            satSum[ring] += c.s; brtSum[ring] += c.b; ringN[ring] += 1

            if c.b < 0.25 { dark += 1 }
            if c.s > 0.35, c.b > 0.25 {
                hue[min(SpriteDescriptor.hueBins - 1, Int(c.h / 30))] += 1
                hueTotal += 1
            }

            // Local gradient two pixels out, summed over linear channels —
            // the exact metric the published thresholds were measured with.
            // Computing it in HSB instead halves the numbers and collapses the
            // separation between a tower and bare map from 3x to under 2x.
            if let rr = frame.hsb(x: px + 2, y: py), let dd = frame.hsb(x: px, y: py + 2) {
                let a = c.rgb, b1 = rr.rgb, b2 = dd.rgb
                edge += abs(a.r - b1.r) + abs(a.g - b1.g) + abs(a.b - b1.b)
                      + abs(a.r - b2.r) + abs(a.g - b2.g) + abs(a.b - b2.b)
            }
            total += 1
        }
    }
    guard total > 0 else { return nil }

    if hueTotal > 0 { for i in hue.indices { hue[i] /= hueTotal } }
    for i in 0..<SpriteDescriptor.rings where ringN[i] > 0 {
        satSum[i] /= ringN[i]; brtSum[i] /= ringN[i]
    }

    return SpriteDescriptor(hueHist: hue, ringSat: satSum, ringBright: brtSum,
                            darkFrac: dark / total, edgeDensity: edge / total,
                            areaSamples: areaSamples)
}
