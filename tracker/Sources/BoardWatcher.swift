// A census of the towers on one board, maintained over time.
//
// This replaces counting build EVENTS, and the difference is the whole point.
// An event total is a running sum, so every false positive is permanent and
// drift is monotone — which is exactly how a logged match reached $12,461
// against a $2,302 ceiling and never came back down. A census is recomputed:
// board value is a pure function of the sites currently standing, so a site that
// was never a tower is dropped the next time it fails verification and its cost
// leaves the total with it. The books heal instead of drifting.
//
// It also gets sells right, which an event sum structurally cannot: a tower
// disappearing simply leaves the census, where before it registered as another
// purchase — the correct magnitude with the wrong sign.
//
// Sites come from change detection, which is still the cheap way to notice that
// something happened. But membership and value come from repeated descriptor
// verification, and that is what a change blob alone could never provide:
//
//   is it there      the site still reads as a sprite, not flat map
//   is it the same   its descriptor still matches what was stored
//   is it new        it was not in the previous census
//
// Used for both boards. On theirs it books spending; on yours it harvests
// priced templates, because your own cash tells you exactly what each change
// was worth.

import Foundation
import CoreGraphics

struct TowerSite {
    let id: Int
    var centreX: Int, centreY: Int
    var x0: Int, y0: Int, x1: Int, y1: Int
    var descriptor: SpriteDescriptor
    var areaSamples: Int
    var confirmations: Int
    var misses: Int
    /// Frame-clock seconds, not wall clock — see `Frame.time`.
    var firstSeen: Double
    /// A reading that disagrees with the stored descriptor, held until a second
    /// census agrees with it. A bloon crossing the sprite changes the descriptor
    /// for a moment; an upgrade changes it for good.
    var pending: SpriteDescriptor?

    var isConfirmed: Bool { confirmations >= BoardWatcher.confirmationsNeeded }
}

enum CensusChange {
    case appeared(TowerSite)
    case upgraded(site: TowerSite, from: SpriteDescriptor)
    case removed(TowerSite)
}

final class BoardWatcher {
    let name: String
    private let scanner: TrackScanner
    private var region: HUDRegion

    /// Real measured sprite extent at 2560px wide. The previous value was 52px,
    /// which is roughly the placement footprint rather than the drawn sprite —
    /// ~10x too small in area, so the shape gate accepted blobs an order of
    /// magnitude below any real tower. Measured from a capture by diffing an
    /// empty board against one with towers: 613 and 1053 samples, 120x148 and
    /// 168x268 px.
    static let spriteDiameterAt2560 = 150.0
    static let confirmationsNeeded = 2
    private let maxMisses = 3
    private let censusPeriod = 2.0
    /// Descriptor distance that counts as a different appearance. Above both
    /// the library's match threshold and the measured within-tower noise floor
    /// of 0.224, so firing animation and a passing bloon cannot read as an
    /// upgrade, while a genuinely different sprite (never closer than 0.302 in
    /// the same measurement) still does.
    private let upgradeDistance = 0.30

    private var footprintSamples = 703.0
    private var footprintDiameter = 37

    private var pool: [(t: Double, idx: Int)] = []
    private let poolSeconds = 2.0

    private(set) var sites: [TowerSite] = []
    private var nextID = 1
    private var lastCensus = -Double.greatestFiniteMagnitude

    /// Whole-scene changes seen. Surfaced because a run with several is a run
    /// whose books deserve suspicion.
    private(set) var sceneChanges = 0
    /// Absorption above this fraction of the board in ONE frame is a scene
    /// change, not purchases. A tower is ~1000 of ~91,700 samples, or 1.1%, so
    /// 2.5% still allows two landing together; the match-start curtain cleared
    /// 64-70% of the board over a second or so.
    private let sceneChangeFrameFraction = 0.025

    /// nil means "arm relative to the next frame that arrives". The watcher is
    /// built, and retargeted, at moments that have no frame in hand, so the
    /// settle window cannot be anchored until one shows up. Anchoring it to the
    /// wall clock instead is what made replay meaningless: every frame in a
    /// recorded set arrives within milliseconds of construction, so the window
    /// had always already expired.
    private var armedAt: Double?
    private let settleSeconds = 3.0

    init(region: HUDRegion, name: String) {
        self.region = region
        self.name = name
        scanner = TrackScanner(region: region, sampleStep: 4, absorbAfterSeconds: 2.5)
    }

    func retarget(_ r: HUDRegion) {
        region = r
        scanner.retarget(r)
        pool.removeAll()
        sites.removeAll()
        lastCensus = -Double.greatestFiniteMagnitude
        armedAt = nil
    }

    func calibrate(frameWidth: Int) {
        let d = Self.spriteDiameterAt2560 * Double(frameWidth) / 2560.0
        footprintSamples = max(40, (d * d / 16.0) * 0.5)
        footprintDiameter = max(6, Int(d / 4.0))
    }

    var confirmedSites: [TowerSite] { sites.filter(\.isConfirmed) }

    /// Why the census produced what it did, for the frame just scanned. Without
    /// these the only observable is the site count, and a run that finds nothing
    /// is indistinguishable from a run where nothing happened — which is exactly
    /// the ambiguity that makes tuning detection guesswork.
    struct Trace {
        var absorbed = 0          // samples absorbed this frame
        var poolSize = 0          // absorptions still inside the pool window
        var blobs = 0             // connected components formed from them
        var blobsPlausible = 0    // ... that passed the size/shape/path gate
        var rejectedTexture = 0   // ... that then failed looksLikeSprite
        var rejectedNearby = 0    // ... that landed on an existing site
        var sites = 0             // tracked, including unconfirmed
        var confirmed = 0
        var armed = false
    }
    private(set) var trace = Trace()

    /// Where to write every candidate crop with the verdict that was passed on
    /// it. A gate that rejects everything and a board with nothing on it produce
    /// identical output — a zero — so the only way to tell a correctly quiet
    /// detector from a broken one is to look at what it threw away.
    static var cropSink: ((CGImage, String) -> Void)?

    func update(_ frame: Frame, allowed: Set<BloonType>) -> [CensusChange] {
        let result = scanner.scan(frame, allowed: allowed)
        let now = frame.time
        let gw = scanner.grid.w
        trace = Trace()
        trace.absorbed = result.absorbed
        defer {
            trace.poolSize = pool.count
            trace.sites = sites.count
            trace.confirmed = sites.filter(\.isConfirmed).count
        }
        guard gw > 0, scanner.sampleCount > 0 else { return [] }

        // Scene change: reseed rather than bill it.
        let frac = Double(result.absorbed) / Double(scanner.sampleCount)
        if frac > sceneChangeFrameFraction {
            scanner.declareSceneChange()
            sceneChanges += 1
            pool.removeAll()
            armedAt = now + settleSeconds
            return []
        }

        let armAt = armedAt ?? (now + settleSeconds)
        armedAt = armAt
        guard now >= armAt else { pool.removeAll(); return [] }
        trace.armed = true

        for i in result.absorbedAt { pool.append((now, i)) }
        pool.removeAll { now - $0.t > poolSeconds }

        let px = region.pixels(frame.width, frame.height)
        if Double(pool.count) >= footprintSamples * 0.25 {
            var claimed = Set<Int>()
            let all = components(pool.map(\.idx), gridW: gw)
            trace.blobs = all.count
            for blob in all where isPlausibleSprite(blob, gridW: gw) {
                trace.blobsPlausible += 1
                claimed.formUnion(blob)
                addCandidate(blob, gridW: gw, frame: frame, regionPx: px, now: now)
            }
            if !claimed.isEmpty { pool.removeAll { claimed.contains($0.idx) } }
        }

        guard now - lastCensus >= censusPeriod else { return [] }
        lastCensus = now
        return runCensus(frame, now: now)
    }

    // MARK: - candidates

    private func addCandidate(_ blob: [Int], gridW: Int, frame: Frame,
                              regionPx: CGRect, now: Double) {
        let xs = blob.map { $0 % gridW }, ys = blob.map { $0 / gridW }
        let step = 4
        // Grid coords back to frame pixels, padded a little so the sprite's
        // outline is inside the box rather than clipped by it.
        let padX = max(4, (xs.max()! - xs.min()!) / 8), padY = max(4, (ys.max()! - ys.min()!) / 8)
        let x0 = Int(regionPx.minX) + (xs.min()! - padX) * step
        let x1 = Int(regionPx.minX) + (xs.max()! + padX) * step
        let y0 = Int(regionPx.minY) + (ys.min()! - padY) * step
        let y1 = Int(regionPx.minY) + (ys.max()! + padY) * step

        guard let d = describeSprite(frame, x0: x0, y0: y0, x1: x1, y1: y1,
                                     areaSamples: blob.count) else { return }

        if let sink = Self.cropSink, let cg = frame.makeCGImage()?.cropping(
                to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) {
            sink(cg, String(format: "%@_t%.1f_%@_edge%.3f_dark%.3f_area%d_%dx%d",
                            name, now, d.looksLikeSprite ? "PASS" : "FLAT",
                            d.edgeDensity, d.darkFrac, blob.count, x1 - x0, y1 - y0))
        }

        // Texture gate. Flat things are not towers: the curtain measured 0.005
        // and bare map 0.067 against 0.147+ for every real tower.
        guard d.looksLikeSprite else { trace.rejectedTexture += 1; return }

        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        // Already covered? Then this is the same tower still fading in, or an
        // upgrade — either way the census handles it, not a second site.
        let near = footprintDiameter * 4
        if sites.contains(where: { abs($0.centreX - cx) < near && abs($0.centreY - cy) < near }) {
            trace.rejectedNearby += 1
            return
        }

        sites.append(TowerSite(id: nextID, centreX: cx, centreY: cy,
                               x0: x0, y0: y0, x1: x1, y1: y1,
                               descriptor: d, areaSamples: blob.count,
                               confirmations: 0, misses: 0, firstSeen: now, pending: nil))
        nextID += 1
    }

    // MARK: - census

    /// Re-read every site and reconcile it with what is stored.
    private func runCensus(_ frame: Frame, now: Double) -> [CensusChange] {
        var changes: [CensusChange] = []
        var keep: [TowerSite] = []

        for var s in sites {
            guard let d = describeSprite(frame, x0: s.x0, y0: s.y0, x1: s.x1, y1: s.y1,
                                         areaSamples: s.areaSamples), d.looksLikeSprite else {
                s.misses += 1
                s.pending = nil
                if s.misses >= maxMisses {
                    // Gone. On their board that is a sell, and its cost leaves
                    // the census with it — which an event sum could never do.
                    if s.isConfirmed { changes.append(.removed(s)) }
                    continue
                }
                keep.append(s); continue
            }

            s.misses = 0
            if !s.isConfirmed {
                s.confirmations += 1
                s.descriptor = d
                if s.isConfirmed { changes.append(.appeared(s)) }
                keep.append(s); continue
            }

            let dist = d.distance(to: s.descriptor)
            if dist > upgradeDistance {
                // Needs a second census to agree before it counts. A bloon
                // crossing the sprite moves the descriptor for one reading.
                if let p = s.pending, d.distance(to: p) <= upgradeDistance {
                    let from = s.descriptor
                    s.descriptor = d
                    s.pending = nil
                    changes.append(.upgraded(site: s, from: from))
                } else {
                    s.pending = d
                }
            } else {
                s.pending = nil
            }
            keep.append(s)
        }

        sites = keep
        return changes
    }

    // MARK: - geometry

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
                        if set.contains(n), !seen.contains(n) { seen.insert(n); stack.append(n) }
                    }
                }
            }
            out.append(blob)
        }
        return out
    }

    /// Size, shape, and placement. Sprites are taller than wide rather than
    /// disc-shaped — measured 42x67 and 30x37 samples — so the fill floor is
    /// looser than a disc would want.
    private func isPlausibleSprite(_ blob: [Int], gridW: Int) -> Bool {
        guard Double(blob.count) >= footprintSamples * 0.25 else { return false }
        let xs = blob.map { $0 % gridW }, ys = blob.map { $0 / gridW }
        let w = xs.max()! - xs.min()! + 1, h = ys.max()! - ys.min()! + 1
        let maxSpan = footprintDiameter * 3
        guard w <= maxSpan, h <= maxSpan else { return false }
        guard max(w, h) <= min(w, h) * 3 else { return false }
        guard Double(blob.count) / Double(w * h) >= 0.25 else { return false }
        let onPath = blob.filter { scanner.isOnPath($0) }.count
        return Double(onPath) / Double(blob.count) < 0.6
    }
}
