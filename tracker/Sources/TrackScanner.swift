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

    struct Result {
        var counts: [BloonType: Int] = [:]
        /// Samples absorbed into the background this frame — a proxy for
        /// "something was just built here and stopped moving".
        var absorbed: Int = 0
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
                        out.absorbed += 1
                        prevR[idx] = r; prevG[idx] = g; prevB[idx] = b
                        continue
                    }
                } else {
                    stableFor[idx] = 0
                }
                prevR[idx] = r; prevG[idx] = g; prevB[idx] = b

                for t in allowed where hsb.matches(t) {
                    out.counts[t, default: 0] += 1
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
