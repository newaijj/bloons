// Plate-based occupancy detection: where the towers on a board are, right now.
//
// This replaces absorption-event detection, which found nothing at all on real
// match data — 0/13 opponent towers across a whole logged match. Measured
// held-out on two matches with frozen parameters: 10/13 at 83.3% precision on
// one map, 9/11 at 90.0% on a different map against a different opponent. See
// eval/runs/ for the run records.
//
// The mechanism is a state query, not an event query, and that difference is the
// point. Absorption could only ever see a tower ARRIVE, so anything standing
// before the tracker latched was invisible forever and every scene change wiped
// the board. Occupancy against a plate asks what is standing there, so a tower
// is found whether or not its arrival was witnessed.
//
//   plate      the board with nothing on it
//   occupancy  fraction of a window in which a cell differs from the plate
//   flicker    mean frame-to-frame colour change over the same window
//
// Occupancy alone does not work: a dense bloon stream keeps path cells covered
// essentially all the time. Flicker separates them — mostly. It is a TRADE, not
// a pure win, and the tradeoff is documented at `flickerMax` because it is the
// single most important thing to know before touching these numbers.
//
// What is deliberately NOT here:
//
//   - No `looksLikeSprite` texture gate. Its darkFrac term was measured to be
//     ANTI-correlated with being a tower: bare dark map scored higher than real
//     sprites. Existence is decided by occupancy against a known plate, which is
//     a far stronger test than sprite texture heuristics.
//   - No blob splitting. A distance-transform splitter was built and tested; it
//     never fired on the second map (its size threshold does not transfer) while
//     costing +62% and +75% site churn on the two matches. Two matches, no
//     demonstrated benefit, consistent cost. See
//     eval/runs/2026-08-16-peak-split.md before reintroducing it.

import Foundation
import CoreGraphics

/// One connected region of board that is occupied and still.
struct PlateBlob {
    var cx: Int, cy: Int
    var x0: Int, y0: Int, x1: Int, y1: Int
    var cells: Int
}

final class PlateCensus {
    // MARK: - Frozen parameters
    //
    // These are the values two held-out evaluations were run at. Changing one
    // invalidates both run records, so change them together with a new run.

    /// Sum of |dRGB| over 0-255 channels before a cell counts as occupied.
    static let occThresh = 90.0
    /// Fraction of the window a cell must be occupied for.
    static let occFrac = 0.90
    /// Mean frame-to-frame colour change a cell must stay under.
    ///
    /// This gate is a TRADE and both directions are measured. It suppresses
    /// transients — bloon packs, projectiles — and without it precision fell
    /// from 83.3% to 41.4% with site count doubling. But it also rejects towers
    /// that are FIRING, because a muzzle flash is exactly a large frame-to-frame
    /// change at a fixed location. Firing rejection accounts for 3 of the 5
    /// total misses across both evaluated matches and is the largest known
    /// weakness of this detector.
    static let flickerMax = 15.0
    static let windowSeconds = 2.5

    /// Minimum spacing between ingested samples, in recorded seconds.
    ///
    /// Load-bearing, and easy to miss: `flicker` is a FRAME-TO-FRAME delta, so
    /// its magnitude depends on how far apart the frames are. Every threshold
    /// above was calibrated on 4fps recordings, where frames sit ~0.25s apart.
    /// Feeding a 10fps live stream straight in would make consecutive frames
    /// ~0.1s apart, shrink every flicker value by roughly 2-3x, and quietly turn
    /// `flickerMax` into a gate that passes nearly everything. So ingestion is
    /// throttled to the rate the numbers were measured at, whatever the capture
    /// is doing.
    /// Set just under the 0.25s of a 4fps recording so float jitter in frame
    /// timestamps cannot drop every other sample — at exactly 0.25 a gap that
    /// computes as 0.2499 is skipped, halving the window and tightening
    /// `occFrac` far beyond what it was measured at.
    static let sampleInterval = 0.22

    static let step = 8
    static let minCells = 20
    static let maxCells = 4000
    /// Longer side over shorter. The dominant false-positive family was board
    /// BORDER artifacts — strips on the top edge row up to 336px wide and 16px
    /// tall, and slivers on the outer edge, at 21:1 and 38:1 against 0.75-0.89
    /// for real towers.
    static let maxAspect = 2.0
    /// Cells trimmed from each board edge. The border decoration shifts a pixel
    /// or two between frames, which reads as permanently occupied and perfectly
    /// still.
    static let insetCells = 2
    /// Board occupancy above this is a scene change, not a board full of
    /// towers. The defeat screen measured ~90% of cells occupied and still at
    /// once; a real board never approaches it.
    static let sceneChangeFraction = 0.5

    // MARK: - State

    private var region: HUDRegion
    private var gw = 0, gh = 0
    private var frameW = 0, frameH = 0
    private var px = CGRect.zero

    /// The board with nothing on it, as RGB triples. Empty until seeded.
    private var plate: [Double] = []
    private var prev: [Double] = []
    private var hasPrev = false
    private(set) var plateSeededAt: Double?

    private var occRing: [[Bool]] = []
    private var flickRing: [[Double]] = []
    private var ringT: [Double] = []
    private var lastSample = -Double.greatestFiniteMagnitude

    private(set) var sceneChanges = 0
    /// Occupied-and-still fraction of the board on the last sample, so a caller
    /// can surface a run whose plate has gone stale.
    private(set) var occupiedFraction = 0.0

    init(region: HUDRegion) { self.region = region }

    func retarget(_ r: HUDRegion) {
        region = r
        gw = 0; gh = 0
        plate = []; prev = []; hasPrev = false
        plateSeededAt = nil
        occRing.removeAll(); flickRing.removeAll(); ringT.removeAll()
        lastSample = -Double.greatestFiniteMagnitude
    }

    var grid: (w: Int, h: Int) { (gw, gh) }
    var hasPlate: Bool { plateSeededAt != nil }

    /// Take this frame as the empty board.
    ///
    /// A tower standing at seed time becomes part of the plate and is INVISIBLE
    /// for the life of that plate. There is no way to recover it, so seeding is
    /// only ever done at a moment the board is known to be empty: match start,
    /// or immediately after a scene change. Starting the tracker mid-match means
    /// whatever is already built stays unseen — which is why the recording
    /// workflow says to start at the menu.
    func seedPlate(_ frame: Frame) {
        resize(frame)
        guard gw > 0, gh > 0 else { return }
        plate = [Double](repeating: 0, count: gw * gh * 3)
        for gy in 0..<gh {
            for gx in 0..<gw {
                let j = (gy * gw + gx) * 3
                if let c = rgb(frame, gx, gy) { plate[j] = c.0; plate[j+1] = c.1; plate[j+2] = c.2 }
            }
        }
        prev = plate
        hasPrev = false
        occRing.removeAll(); flickRing.removeAll(); ringT.removeAll()
        plateSeededAt = frame.time
    }

    private func resize(_ frame: Frame) {
        let p = region.pixels(frame.width, frame.height)
        let w = Int(p.width) / Self.step, h = Int(p.height) / Self.step
        if w != gw || h != gh || frame.width != frameW || frame.height != frameH {
            gw = w; gh = h; frameW = frame.width; frameH = frame.height
            plate = []; prev = []; hasPrev = false
            plateSeededAt = nil
            occRing.removeAll(); flickRing.removeAll(); ringT.removeAll()
        }
        px = p
    }

    private func rgb(_ frame: Frame, _ gx: Int, _ gy: Int) -> (Double, Double, Double)? {
        let x = Int(px.minX) + gx * Self.step, y = Int(px.minY) + gy * Self.step
        guard let hsb = frame.hsb(x: x, y: y) else { return nil }
        let c = hsb.rgb
        return (c.r * 255, c.g * 255, c.b * 255)
    }

    /// Ingest a frame. Returns false when the frame was skipped for rate.
    @discardableResult
    func observe(_ frame: Frame) -> Bool {
        resize(frame)
        guard hasPlate, gw > 0, gh > 0 else { return false }
        let now = frame.time
        guard now - lastSample >= Self.sampleInterval else { return false }
        lastSample = now

        let n = gw * gh
        var occ = [Bool](repeating: false, count: n)
        var flick = [Double](repeating: 0, count: n)
        var occupied = 0
        for gy in 0..<gh {
            for gx in 0..<gw {
                let idx = gy * gw + gx, j = idx * 3
                guard let c = rgb(frame, gx, gy) else { continue }
                let d = abs(c.0 - plate[j]) + abs(c.1 - plate[j+1]) + abs(c.2 - plate[j+2])
                occ[idx] = d > Self.occThresh
                if occ[idx] { occupied += 1 }
                if hasPrev {
                    flick[idx] = abs(c.0 - prev[j]) + abs(c.1 - prev[j+1]) + abs(c.2 - prev[j+2])
                }
                prev[j] = c.0; prev[j+1] = c.1; prev[j+2] = c.2
            }
        }
        hasPrev = true
        occupiedFraction = Double(occupied) / Double(max(1, n))

        occRing.append(occ); flickRing.append(flick); ringT.append(now)
        while let f = ringT.first, now - f > Self.windowSeconds {
            occRing.removeFirst(); flickRing.removeFirst(); ringT.removeFirst()
        }
        return true
    }

    /// Whether the board just turned into something that is not a board.
    ///
    /// A menu, the defeat screen, or a panel opening over the play area makes
    /// almost every cell differ from the plate at once and then hold still,
    /// which is indistinguishable from a board covered in towers by any local
    /// test. The scale is what gives it away.
    func isSceneChange() -> Bool {
        guard occRing.count >= 2 else { return false }
        return occupiedFraction > Self.sceneChangeFraction
    }

    func noteSceneChange() { sceneChanges += 1 }

    /// Cells occupied for enough of the window and still enough within it.
    private func towerMask() -> [Bool] {
        let n = gw * gh
        var out = [Bool](repeating: false, count: n)
        guard occRing.count >= 2 else { return out }
        let samples = Double(occRing.count)
        for idx in 0..<n {
            var hits = 0
            var fsum = 0.0
            for k in 0..<occRing.count {
                if occRing[k][idx] { hits += 1 }
                fsum += flickRing[k][idx]
            }
            guard Double(hits) / samples >= Self.occFrac else { continue }
            guard fsum / samples < Self.flickerMax else { continue }
            let gx = idx % gw, gy = idx / gw
            if gx < Self.insetCells || gx >= gw - Self.insetCells { continue }
            if gy < Self.insetCells || gy >= gh - Self.insetCells { continue }
            out[idx] = true
        }
        return out
    }

    /// Blobs standing on the board right now, in FRAME pixel coordinates.
    func blobs() -> [PlateBlob] {
        let mask = towerMask()
        guard !mask.isEmpty else { return [] }
        var seen = [Bool](repeating: false, count: mask.count)
        var out: [PlateBlob] = []
        let ox = Int(px.minX), oy = Int(px.minY)

        for start in 0..<mask.count where mask[start] && !seen[start] {
            var blob: [Int] = [], stack = [start]
            seen[start] = true
            while let c = stack.popLast() {
                blob.append(c)
                let cx = c % gw, cy = c / gw
                for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, nx < gw, ny >= 0, ny < gh else { continue }
                        let m = ny * gw + nx
                        if mask[m] && !seen[m] { seen[m] = true; stack.append(m) }
                    }
                }
            }
            guard blob.count >= Self.minCells, blob.count <= Self.maxCells else { continue }
            let xs = blob.map { $0 % gw }, ys = blob.map { $0 / gw }
            let w = xs.max()! - xs.min()! + 1, h = ys.max()! - ys.min()! + 1
            guard Double(max(w, h)) / Double(max(1, min(w, h))) <= Self.maxAspect else { continue }
            out.append(PlateBlob(
                cx: ox + (xs.reduce(0, +) / blob.count) * Self.step,
                cy: oy + (ys.reduce(0, +) / blob.count) * Self.step,
                x0: ox + xs.min()! * Self.step, y0: oy + ys.min()! * Self.step,
                x1: ox + (xs.max()! + 1) * Self.step, y1: oy + (ys.max()! + 1) * Self.step,
                cells: blob.count))
        }
        return out
    }
}
