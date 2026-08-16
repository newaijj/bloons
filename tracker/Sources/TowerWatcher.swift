// Watches the opponent's track for money leaving their pocket.
//
// Every tower placed and every upgrade bought changes their board and then
// settles. TrackScanner's absorption signal fires on "something new stopped
// moving", which is NECESSARY for a purchase but nowhere near sufficient. Four
// tests now stand between an absorption and a charge:
//
//   virgin      only a sample's first absorption counts        (TrackScanner)
//   compact     the samples must form one tower-sized blob, not a drizzle
//   off-path    towers cannot be built where the bloons walk
//   persistent  the blob must still be settled seconds later
//
// The old version had none of them. It summed a bare absorption count over the
// whole half-screen and fired at 60% of one footprint — 51 samples out of the
// ~91,700 the region subsamples to, or 0.056%, in any 2s window. Animated
// scenery and dense bloon streams clear that continuously, so it sat pinned at
// its own 1.5s rate limit and billed roughly $16k/minute. A logged match had it
// reach $12,461 by round 2 against a hard ceiling of $2,302.
//
// Of the four, persistence does the most work: a tower is still settled three
// seconds later, and nothing else on the map is.
//
// What this still CANNOT do is read the price tag. Identifying which tower and
// which upgrade tier from its sprite needs an asset catalogue the game ships
// encrypted. So cost is estimated from blob area, and the result is reported as
// an estimate with a band — never as an exact figure. Charging it against their
// books, and bounding it by what they could actually afford, is IncomeModel's
// job, not this file's.

import Foundation

struct BuildEvent {
    let samples: Int
    let estimatedCost: Int
    let round: Int
    let at: Date
}

final class TowerWatcher {
    private let scanner: TrackScanner
    private let roundData: RoundData

    /// Absorbed samples, pooled briefly so a blob that lands across two frames
    /// is still recognised as one thing.
    private var pool: [(t: Date, idx: Int)] = []
    private let poolSeconds = 2.0

    /// A tower footprint at 2560px wide, after grid subsampling, and its
    /// diameter in samples.
    private var footprintSamples = 120.0
    private var footprintDiameter = 13

    /// A blob that looks like a build but has not yet proved it stayed put.
    private struct Candidate {
        let indices: [Int]
        let centroid: Int
        let at: Date
        let round: Int
    }
    private var pending: [Candidate] = []
    private let confirmSeconds = 3.0
    /// How much of a blob must still be settled at confirmation time.
    private let settledFloor = 0.6

    /// Centroids of confirmed builds. A tower keeps absorbing stray samples as
    /// it finishes fading in, and those must not be charged again.
    private var knownSites: [(idx: Int, at: Date)] = []
    /// ...but a genuine upgrade at the same spot must still register, so the
    /// suppression is a cooldown rather than a permanent veto. Telling an
    /// upgrade from a fade-in properly needs a per-site tier model; this is the
    /// seam where that would go.
    private let siteCooldown = 8.0

    /// Nothing is charged until the background model has had time to seed. On
    /// the first frame of a fresh region every sample is new, and `retarget()`
    /// deliberately throws the model away.
    private var armedAt: Date
    private let settleSeconds = 3.0

    private(set) var builds: [BuildEvent] = []
    /// Raw detector total, before IncomeModel applies the affordability bound.
    private(set) var totalSpend = 0

    /// Shop prices seen on screen, to scale the estimate to the tier actually in
    /// play. Nothing populates this yet — every cost currently falls back to the
    /// mid-range default below.
    var shopPrices: [Int] = []

    init(roundData: RoundData, fps: Int) {
        self.roundData = roundData
        self.armedAt = Date().addingTimeInterval(settleSeconds)
        scanner = TrackScanner(region: Regions.oppTrack, sampleStep: 4,
                               absorbAfterSeconds: 2.5, fps: fps)
    }

    /// Re-point at their track after the side has been decided. Builds counted
    /// before the latch were counted on the wrong board, so they are discarded
    /// rather than carried into the books.
    func retarget() {
        scanner.retarget(Regions.oppTrack)
        pool.removeAll()
        pending.removeAll()
        knownSites.removeAll()
        builds.removeAll()
        totalSpend = 0
        armedAt = Date().addingTimeInterval(settleSeconds)
    }

    func calibrate(frameWidth: Int) {
        let d = 52.0 * Double(frameWidth) / 2560.0
        footprintSamples = max(20, (d * d / 16.0) * 0.5)
        footprintDiameter = max(4, Int(d / 4.0))
    }

    /// Scan their side and return any builds that confirmed this frame.
    ///
    /// The round's natural bloon types are passed through so the scanner can
    /// learn where the path runs. The counts themselves are discarded — this
    /// side's bloons are not the signal, their locations are.
    func update(_ frame: Frame, round: Int) -> [BuildEvent] {
        let result = scanner.scan(frame, allowed: roundData.naturalTypes(round))
        let now = Date()
        let gw = scanner.grid.w
        guard gw > 0 else { return [] }

        guard now >= armedAt else {
            pool.removeAll()
            return []
        }

        for i in result.absorbedAt { pool.append((now, i)) }
        pool.removeAll { now.timeIntervalSince($0.t) > poolSeconds }

        // Promote any pooled blob that is the right shape and in a legal place.
        if Double(pool.count) >= footprintSamples * 0.25 {
            var claimed = Set<Int>()
            for blob in components(pool.map(\.idx), gridW: gw) where isPlausibleBuild(blob, gridW: gw) {
                claimed.formUnion(blob)
                let c = centroid(blob, gridW: gw)
                guard !isRecentlyCharged(c, gridW: gw, now: now) else { continue }
                pending.append(Candidate(indices: blob, centroid: c, at: now, round: round))
            }
            if !claimed.isEmpty { pool.removeAll { claimed.contains($0.idx) } }
        }

        return confirm(now: now)
    }

    /// A candidate becomes a charge only if its samples are still settled after
    /// `confirmSeconds`. Anything that was a passing bloon stream has long since
    /// gone foreground again by then.
    private func confirm(now: Date) -> [BuildEvent] {
        var out: [BuildEvent] = []
        var keep: [Candidate] = []
        for c in pending {
            guard now.timeIntervalSince(c.at) >= confirmSeconds else { keep.append(c); continue }
            guard scanner.settledFraction(c.indices) >= settledFloor else { continue }

            let cost = estimateCost(samples: c.indices.count)
            let e = BuildEvent(samples: c.indices.count, estimatedCost: cost, round: c.round, at: now)
            builds.append(e)
            totalSpend += cost
            knownSites.append((idx: c.centroid, at: now))
            out.append(e)
        }
        pending = keep
        return out
    }

    // MARK: - blob geometry

    /// Group pooled samples into connected blobs. Connectivity has a radius of
    /// 2 rather than 1: a tower's samples do not all absorb on the same frame,
    /// and strict adjacency would shatter one footprint into a dozen fragments
    /// that each fail the size test.
    private func components(_ indices: [Int], gridW: Int) -> [[Int]] {
        let set = Set(indices)
        var seen = Set<Int>()
        var out: [[Int]] = []
        for start in indices where !seen.contains(start) {
            var blob: [Int] = []
            var stack = [start]
            seen.insert(start)
            while let cur = stack.popLast() {
                blob.append(cur)
                let cx = cur % gridW, cy = cur / gridW
                for dy in -2...2 {
                    for dx in -2...2 where !(dx == 0 && dy == 0) {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, nx < gridW, ny >= 0 else { continue }
                        let n = ny * gridW + nx
                        if set.contains(n), !seen.contains(n) {
                            seen.insert(n); stack.append(n)
                        }
                    }
                }
            }
            out.append(blob)
        }
        return out
    }

    /// Shape and placement tests. A tower is a compact disc of roughly known
    /// size, sitting off the path. Scenery drizzle is none of those things.
    private func isPlausibleBuild(_ blob: [Int], gridW: Int) -> Bool {
        // An upgrade redraws less than a whole tower, so the floor is well below
        // one footprint.
        guard Double(blob.count) >= footprintSamples * 0.25 else { return false }

        let xs = blob.map { $0 % gridW }, ys = blob.map { $0 / gridW }
        let w = xs.max()! - xs.min()! + 1, h = ys.max()! - ys.min()! + 1

        // Reject a long smear along the track, and anything several footprints
        // across — both are how a scattering presents.
        let maxSpan = footprintDiameter * 3
        guard w <= maxSpan, h <= maxSpan else { return false }
        guard max(w, h) <= min(w, h) * 3 else { return false }
        // A disc fills ~79% of its bounding box; allow for occlusion and for
        // samples that have not absorbed yet.
        guard Double(blob.count) / Double(w * h) >= 0.30 else { return false }

        // Towers cannot be placed where the bloons walk. A majority test, not an
        // any test: a legal tower sits adjacent to the track and will clip it.
        let onPath = blob.filter { scanner.isOnPath($0) }.count
        return Double(onPath) / Double(blob.count) < 0.6
    }

    private func centroid(_ blob: [Int], gridW: Int) -> Int {
        let cx = blob.map { $0 % gridW }.reduce(0, +) / blob.count
        let cy = blob.map { $0 / gridW }.reduce(0, +) / blob.count
        return cy * gridW + cx
    }

    /// Whether a confirmed build or a pending candidate already covers this
    /// spot. Distance is measured in samples on the grid.
    private func isRecentlyCharged(_ c: Int, gridW: Int, now: Date) -> Bool {
        let cx = c % gridW, cy = c / gridW
        func near(_ other: Int) -> Bool {
            let ox = other % gridW, oy = other / gridW
            return abs(ox - cx) <= footprintDiameter && abs(oy - cy) <= footprintDiameter
        }
        if pending.contains(where: { near($0.centroid) }) { return true }
        return knownSites.contains { near($0.idx) && now.timeIntervalSince($0.at) < siteCooldown }
    }

    // MARK: - cost

    /// Scale a typical shop price by how large the settle was relative to one
    /// footprint. Falls back to a mid-range tower, which — since `shopPrices` is
    /// never populated — is currently every case.
    private func estimateCost(samples: Int) -> Int {
        let base: Double
        if shopPrices.isEmpty {
            base = 400
        } else {
            let sorted = shopPrices.sorted()
            base = Double(sorted[sorted.count / 2])
        }
        let sizeFactor = min(3.0, max(0.6, Double(samples) / footprintSamples))
        return Int(base * sizeFactor)
    }

    var buildCount: Int { builds.count }
    /// Candidates waiting on the persistence check, for diagnostics.
    var pendingCount: Int { pending.count }
}
