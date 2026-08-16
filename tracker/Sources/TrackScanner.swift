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
    /// Samples that land on centre chrome rather than on the board. Skipped
    /// outright: they never seed a background, never absorb, and never learn a
    /// path, so nothing downstream can see them.
    ///
    /// Both play bands run right up to the divider, and the button cluster
    /// overhangs each of them by ~6px — persistent, off-path, and sprite-shaped,
    /// which is precisely the signature a tower is recognised by. Rejecting it
    /// later would mean teaching the tower gate about chrome; not sampling it at
    /// all keeps that knowledge in one place. See `Regions.centreChrome`.
    private var masked: [Bool] = []
    private var liveSamples = 0

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
        absorbedEver = []; foregroundNow = []; bloonHits = []
        masked = []; liveSamples = 0
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

    /// Samples actually scanned, so a caller can judge an absorption count as a
    /// fraction of the board rather than as a bare number. Masked samples are
    /// excluded — they can never absorb, so counting them would quietly deflate
    /// every fraction measured against this.
    var sampleCount: Int { liveSamples }

    /// Throw the background model away and reseed from the next frame, without
    /// forgetting where the path runs.
    ///
    /// For whole-scene changes. The background is seeded from ONE frame, and if
    /// that frame is not the settled board — the match-start curtain, a panel
    /// opening over the track, the end-of-match screen — then everything the
    /// seed hid becomes foreground at once, holds still, and absorbs as one
    /// mass event. Persistence cannot reject it, because a scene change is
    /// permanent: the board really is still settled three seconds later. The
    /// only defence is to notice the scale of it and reseed.
    ///
    /// Path knowledge survives: where the bloons walk does not change when the
    /// curtain lifts.
    func declareSceneChange() {
        let n = gridW * gridH
        guard n > 0 else { return }
        bgR = .init(repeating: -1, count: n)
        bgG = .init(repeating: -1, count: n)
        bgB = .init(repeating: -1, count: n)
        prevR = .init(repeating: -1, count: n)
        prevG = .init(repeating: -1, count: n)
        prevB = .init(repeating: -1, count: n)
        stableSince = .init(repeating: -1, count: n)
        stableObs = .init(repeating: 0, count: n)
        absorbedEver = .init(repeating: false, count: n)
        foregroundNow = .init(repeating: false, count: n)
    }

    func scan(_ frame: Frame, allowed: Set<BloonType>) -> Result {
        let now = frame.time
        let px = region.pixels(frame.width, frame.height)
        let x0 = Int(px.minX), y0 = Int(px.minY)
        let gw = Int(px.width) / sampleStep, gh = Int(px.height) / sampleStep
        guard gw > 0, gh > 0 else { return Result() }

        if gw != gridW || gh != gridH {
            gridW = gw; gridH = gh
            let n = gw * gh
            bgR = .init(repeating: -1, count: n); bgG = .init(repeating: -1, count: n); bgB = .init(repeating: -1, count: n)
            prevR = .init(repeating: -1, count: n); prevG = .init(repeating: -1, count: n); prevB = .init(repeating: -1, count: n)
            stableSince = .init(repeating: -1, count: n)
            stableObs = .init(repeating: 0, count: n)
            absorbedEver = .init(repeating: false, count: n)
            foregroundNow = .init(repeating: false, count: n)
            bloonHits = .init(repeating: 0, count: n)

            // The mask is geometry, not model state, so it is built here with
            // the grid and left alone by declareSceneChange().
            let chrome = Regions.centreChrome.pixels(frame.width, frame.height)
            masked = .init(repeating: false, count: n)
            liveSamples = 0
            for gy in 0..<gh {
                let py = y0 + gy * sampleStep
                for gx in 0..<gw {
                    let m = chrome.contains(CGPoint(x: x0 + gx * sampleStep, y: py))
                    masked[gy * gw + gx] = m
                    if !m { liveSamples += 1 }
                }
            }
        }

        var out = Result()
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
                let isForeground = fgDist > 0.28
                foregroundNow[idx] = isForeground

                if !isForeground {
                    // Ordinary slow drift for lighting and animated scenery.
                    bgR[idx] += driftAlpha * (r - bgR[idx])
                    bgG[idx] += driftAlpha * (g - bgG[idx])
                    bgB[idx] += driftAlpha * (b - bgB[idx])
                    stableSince[idx] = -1
                    stableObs[idx] = 0
                    prevR[idx] = r; prevG[idx] = g; prevB[idx] = b
                    continue
                }

                out.foreground += 1

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
                    stableSince[idx] = -1
                    stableObs[idx] = 0
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

}
