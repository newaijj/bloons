// Background-subtracted scanning of one track.
//
// Used twice: on YOUR track to find the opponent's bloons, and on THEIR track to
// find towers going down.
//
// The subtlety is what counts as background. A first version only updated the
// model on pixels that already looked like background, so bloons could not
// slowly erase themselves — but that made anything placed mid-match permanently
// "foreground". A single yellow tower placed at round 3 then read as ~4000
// bloon samples for the rest of the game, in rounds that spawn no yellow at all.
//
// The fix is to absorb by STABILITY rather than by appearance: a sample whose
// colour stops changing for a couple of seconds is scenery, whatever it looks
// like. Bloons move, so they never hold one pixel long enough to be absorbed.
// Towers do — and the moment of absorption is itself the signal that something
// was built, which is how tower spending becomes observable.
//
// Two things that signal needs before a caller can trust it:
//
//   - Absorption must be ONE-SHOT per sample. Absorbing sets the background to
//     the current colour, so a sample that drifts back out — animated water, a
//     flag, a shadow, a steady stream of same-coloured bloons over one spot —
//     settles and absorbs again, forever. Billing each cycle as a purchase is
//     what made tower spend diverge to 5x the opponent's possible income.
//   - Absorptions must carry their LOCATION. A tower is a compact blob; scenery
//     is a drizzle spread over the whole half-screen. A bare count cannot tell
//     the two apart, so the indices go out with the result.

import Foundation
import CoreGraphics

final class TrackScanner {
    private var region: HUDRegion
    private let sampleStep: Int
    private let absorbAfterFrames: Int

    private var bgR: [Double] = [], bgG: [Double] = [], bgB: [Double] = []
    private var prevR: [Double] = [], prevG: [Double] = [], prevB: [Double] = []
    private var stableFor: [Int] = []
    private var gridW = 0, gridH = 0
    private let driftAlpha = 0.02

    /// Absorption is one-shot per sample. Re-absorptions are still applied to
    /// the background model — that part was right — but they are not reported,
    /// because only the first one can possibly mean "something arrived here".
    private var absorbedEver: [Bool] = []
    /// Whether each sample was foreground on the last scan, so a caller can ask
    /// whether a blob it saw absorb has actually stayed put.
    private var foregroundNow: [Bool] = []
    /// How often each sample has been a moving bloon colour. Where the bloons
    /// walk is the track, and towers cannot be built on the track.
    private var bloonHits: [Int] = []

    /// Bloon-coloured frames before a sample counts as track rather than
    /// ground. Low enough to learn a path within the first round, high enough
    /// that a bloon passing over a tower spot once does not mask it.
    static let pathHits = 8

    struct Result {
        var counts: [BloonType: Int] = [:]
        /// Samples absorbed into the background for the FIRST time this frame —
        /// a proxy for "something was just built here and stopped moving".
        /// Re-absorptions are excluded; see the note at the top of the file.
        var absorbed: Int = 0
        /// Grid indices of those absorptions, so the caller can test whether
        /// they form one tower-sized blob rather than a scattering.
        var absorbedAt: [Int] = []
        var foreground: Int = 0
    }

    init(region: HUDRegion, sampleStep: Int = 4, absorbAfterSeconds: Double = 2.5, fps: Int = 10) {
        self.region = region
        self.sampleStep = sampleStep
        self.absorbAfterFrames = max(5, Int(absorbAfterSeconds * Double(fps)))
    }

    /// Point this scanner at a different region and throw away everything it
    /// learned. The background model is per-pixel and the two tracks are
    /// entirely different pixels, so it cannot carry over. Note that the grid
    /// dimensions are IDENTICAL between the two halves, so the realloc check in
    /// scan() would not fire on its own — the reset has to be explicit.
    func retarget(_ r: HUDRegion) {
        region = r
        gridW = 0; gridH = 0
        bgR = []; bgG = []; bgB = []
        prevR = []; prevG = []; prevB = []
        stableFor = []
        absorbedEver = []; foregroundNow = []; bloonHits = []
    }

    /// Grid dimensions, so a caller can turn indices into coordinates.
    var grid: (w: Int, h: Int) { (gridW, gridH) }

    /// Fraction of these samples that are settled right now — background rather
    /// than foreground. A tower is still settled seconds after it lands; a
    /// bloon stream that briefly held one spot still is foreground again the
    /// moment it moves on. This is the strongest build/not-build discriminator
    /// available, and it costs one array lookup per sample.
    func settledFraction(_ indices: [Int]) -> Double {
        guard !indices.isEmpty, !foregroundNow.isEmpty else { return 0 }
        var settled = 0
        for i in indices where i < foregroundNow.count && !foregroundNow[i] { settled += 1 }
        return Double(settled) / Double(indices.count)
    }

    /// Whether this sample sits on the bloon path. Learned from where bloon
    /// colours keep moving through, not configured per map.
    func isOnPath(_ idx: Int) -> Bool {
        idx < bloonHits.count && bloonHits[idx] >= Self.pathHits
    }

    func scan(_ frame: Frame, allowed: Set<BloonType>) -> Result {
        let px = region.pixels(frame.width, frame.height)
        let x0 = Int(px.minX), y0 = Int(px.minY)
        let gw = Int(px.width) / sampleStep, gh = Int(px.height) / sampleStep
        guard gw > 0, gh > 0 else { return Result() }

        if gw != gridW || gh != gridH {
            gridW = gw; gridH = gh
            let n = gw * gh
            bgR = .init(repeating: -1, count: n); bgG = .init(repeating: -1, count: n); bgB = .init(repeating: -1, count: n)
            prevR = .init(repeating: -1, count: n); prevG = .init(repeating: -1, count: n); prevB = .init(repeating: -1, count: n)
            stableFor = .init(repeating: 0, count: n)
            absorbedEver = .init(repeating: false, count: n)
            foregroundNow = .init(repeating: false, count: n)
            bloonHits = .init(repeating: 0, count: n)
        }

        var out = Result()
        for gy in 0..<gh {
            let py = y0 + gy * sampleStep
            for gx in 0..<gw {
                let idx = gy * gw + gx
                guard let hsb = frame.hsb(x: x0 + gx * sampleStep, y: py) else { continue }
                let (r, g, b) = hsbToRGB(hsb)

                if bgR[idx] < 0 {
                    bgR[idx] = r; bgG[idx] = g; bgB[idx] = b
                    prevR[idx] = r; prevG[idx] = g; prevB[idx] = b
                    continue
                }

                let fgDist = abs(r - bgR[idx]) + abs(g - bgG[idx]) + abs(b - bgB[idx])
                let isForeground = fgDist > 0.28
                foregroundNow[idx] = isForeground

                if !isForeground {
                    // Ordinary slow drift for lighting and animated scenery.
                    bgR[idx] += driftAlpha * (r - bgR[idx])
                    bgG[idx] += driftAlpha * (g - bgG[idx])
                    bgB[idx] += driftAlpha * (b - bgB[idx])
                    stableFor[idx] = 0
                    prevR[idx] = r; prevG[idx] = g; prevB[idx] = b
                    continue
                }

                out.foreground += 1

                // Foreground, but is it holding still? Compare against the last
                // frame rather than the background.
                let frameDelta = abs(r - prevR[idx]) + abs(g - prevG[idx]) + abs(b - prevB[idx])
                if frameDelta < 0.06 {
                    stableFor[idx] += 1
                    if stableFor[idx] >= absorbAfterFrames {
                        // Settled. Treat it as scenery from now on.
                        bgR[idx] = r; bgG[idx] = g; bgB[idx] = b
                        stableFor[idx] = 0
                        // The background update above happens every time; the
                        // REPORT happens once. A sample that keeps cycling
                        // through here is animated scenery, not a tower being
                        // rebought every few seconds.
                        if !absorbedEver[idx] {
                            absorbedEver[idx] = true
                            out.absorbed += 1
                            out.absorbedAt.append(idx)
                        }
                        foregroundNow[idx] = false
                        prevR[idx] = r; prevG[idx] = g; prevB[idx] = b
                        continue
                    }
                } else {
                    stableFor[idx] = 0
                }
                prevR[idx] = r; prevG[idx] = g; prevB[idx] = b

                for t in allowed where hsb.matches(t) {
                    out.counts[t, default: 0] += 1
                    // Moving bloon colour here — evidence this sample is track.
                    bloonHits[idx] += 1
                    break
                }
            }
        }
        return out
    }

    private func hsbToRGB(_ c: HSB) -> (Double, Double, Double) {
        let cVal = c.b * c.s
        let x = cVal * (1 - abs((c.h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = c.b - cVal
        let (r, g, b): (Double, Double, Double)
        switch c.h {
        case ..<60:  (r, g, b) = (cVal, x, 0)
        case ..<120: (r, g, b) = (x, cVal, 0)
        case ..<180: (r, g, b) = (0, cVal, x)
        case ..<240: (r, g, b) = (0, x, cVal)
        case ..<300: (r, g, b) = (x, 0, cVal)
        default:     (r, g, b) = (cVal, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}
