// Background-subtracted scanning of one track, for BLOONS.
//
// Used once, by SendDetector, on YOUR track: the bloon colours arriving there
// are what the opponent sent you. Tower detection is PlateCensus's job and no
// part of it comes through here.
//
// The subtlety is what counts as background. Absorbing by APPEARANCE — updating
// the model only on pixels that already look like background — keeps bloons
// from slowly erasing themselves, but makes anything placed mid-match
// permanently foreground: one yellow tower placed at round 3 read as ~4000
// yellow bloon samples for the rest of the game, in rounds that spawn no yellow.
//
// Absorbing by STABILITY avoids that. A sample whose colour stops changing for a
// couple of seconds is scenery, whatever it looks like. Bloons move, so they
// never hold one pixel long enough to be absorbed; towers do, so they leave the
// bloon counts alone once they have settled.

import Foundation
import CoreGraphics

final class TrackScanner {
    private var region: HUDRegion
    private let sampleStep: Int
    /// Absorption is measured in RECORDED SECONDS, off `Frame.time`, not in
    /// frames. Counting frames tied the meaning of "held still for 2.5s" to the
    /// rate frames happen to arrive at, so the same recording replayed at a
    /// different rate absorbed at a different point — and a 20-frame capture
    /// taken at 0.26fps could never absorb at all, because 2.5s at 10fps is 25
    /// frames and there were only 20 in existence.
    private let absorbAfterSeconds: Double
    /// Stability also has to clear a minimum number of OBSERVATIONS. Time alone
    /// is too cheap on a sparse recording: two samples 4s apart would satisfy a
    /// 2.5s window while saying almost nothing about whether the pixel held
    /// still in between.
    private static let absorbMinObservations = 3

    private var bgR: [Double] = [], bgG: [Double] = [], bgB: [Double] = []
    private var prevR: [Double] = [], prevG: [Double] = [], prevB: [Double] = []
    /// Frame time at which each sample last started holding still, or -1 when it
    /// is not currently stable.
    private var stableSince: [Double] = []
    private var stableObs: [Int] = []
    private var gridW = 0, gridH = 0
    private let driftAlpha = 0.02

    /// Samples that land on centre chrome rather than on the board. Skipped
    /// outright: they never seed a background and never absorb, so nothing
    /// downstream can see them.
    ///
    /// Both play bands run right up to the divider, and the button cluster
    /// overhangs each of them by ~6px — persistent, off-path, and sprite-shaped.
    /// See `Regions.centreChrome`.
    private var masked: [Bool] = []

    init(region: HUDRegion, sampleStep: Int = 4, absorbAfterSeconds: Double = 2.5) {
        self.region = region
        self.sampleStep = sampleStep
        self.absorbAfterSeconds = absorbAfterSeconds
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
        stableSince = []; stableObs = []
        masked = []
    }

    func scan(_ frame: Frame, allowed: Set<BloonType>) -> [BloonType: Int] {
        let now = frame.time
        let px = region.pixels(frame.width, frame.height)
        let x0 = Int(px.minX), y0 = Int(px.minY)
        let gw = Int(px.width) / sampleStep, gh = Int(px.height) / sampleStep
        guard gw > 0, gh > 0 else { return [:] }

        if gw != gridW || gh != gridH {
            gridW = gw; gridH = gh
            let n = gw * gh
            bgR = .init(repeating: -1, count: n); bgG = .init(repeating: -1, count: n); bgB = .init(repeating: -1, count: n)
            prevR = .init(repeating: -1, count: n); prevG = .init(repeating: -1, count: n); prevB = .init(repeating: -1, count: n)
            stableSince = .init(repeating: -1, count: n)
            stableObs = .init(repeating: 0, count: n)

            let chrome = Regions.centreChrome.pixels(frame.width, frame.height)
            masked = .init(repeating: false, count: n)
            for gy in 0..<gh {
                let py = y0 + gy * sampleStep
                for gx in 0..<gw {
                    masked[gy * gw + gx] = chrome.contains(CGPoint(x: x0 + gx * sampleStep, y: py))
                }
            }
        }

        var counts: [BloonType: Int] = [:]
        for gy in 0..<gh {
            let py = y0 + gy * sampleStep
            for gx in 0..<gw {
                let idx = gy * gw + gx
                if masked[idx] { continue }
                guard let hsb = frame.hsb(x: x0 + gx * sampleStep, y: py) else { continue }
                let (r, g, b) = hsb.rgb

                if bgR[idx] < 0 {
                    bgR[idx] = r; bgG[idx] = g; bgB[idx] = b
                    prevR[idx] = r; prevG[idx] = g; prevB[idx] = b
                    continue
                }

                let fgDist = abs(r - bgR[idx]) + abs(g - bgG[idx]) + abs(b - bgB[idx])
                if fgDist <= 0.28 {
                    // Ordinary slow drift for lighting and animated scenery.
                    bgR[idx] += driftAlpha * (r - bgR[idx])
                    bgG[idx] += driftAlpha * (g - bgG[idx])
                    bgB[idx] += driftAlpha * (b - bgB[idx])
                    stableSince[idx] = -1
                    stableObs[idx] = 0
                    prevR[idx] = r; prevG[idx] = g; prevB[idx] = b
                    continue
                }

                // Foreground, but is it holding still? Compare against the last
                // frame rather than the background.
                let frameDelta = abs(r - prevR[idx]) + abs(g - prevG[idx]) + abs(b - prevB[idx])
                if frameDelta < 0.06 {
                    if stableSince[idx] < 0 { stableSince[idx] = now }
                    stableObs[idx] += 1
                    if now - stableSince[idx] >= absorbAfterSeconds,
                       stableObs[idx] >= Self.absorbMinObservations {
                        // Settled. Treat it as scenery from now on.
                        bgR[idx] = r; bgG[idx] = g; bgB[idx] = b
                        stableSince[idx] = -1
                        stableObs[idx] = 0
                        prevR[idx] = r; prevG[idx] = g; prevB[idx] = b
                        continue
                    }
                } else {
                    stableSince[idx] = -1
                    stableObs[idx] = 0
                }
                prevR[idx] = r; prevG[idx] = g; prevB[idx] = b

                for t in allowed where hsb.matches(t) {
                    counts[t, default: 0] += 1
                    break
                }
            }
        }
        return counts
    }
}
