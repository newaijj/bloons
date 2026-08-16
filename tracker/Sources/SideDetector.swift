// Decides which half of the screen you are playing on, from pixels.
//
// This is not a robustness nicety. Every region in Regions was, until now, a
// compile-time constant fixed to one orientation. If that orientation is wrong
// nothing errors: SendDetector scans what it believes is your track, actually
// reads the opponent's incoming bloons — which are YOUR sends — and books them
// as theirs, while TowerWatcher bills them for your towers. The output stays
// entirely plausible and is inverted.
//
// THE SIGNAL. The tower shop and the send cards render as one column against
// the outer edge of the side you own. That column is dense with price and
// quantity text; the opposite outer column is bare map. Measured over the 20
// calibration frames in calibrate/out, counting text hits below the top bar:
//
//     empty side   0 hits in 20 of 20 frames
//     panel side   1-5 hits in 17 of 20   ("200", "280", "X8", "24", "3")
//
// Zero false positives on the empty side, and it reads from the first frame,
// before any bloon exists — which the persona-name signal cannot do reliably,
// since stylised names OCR badly ("1vegetableninja" came back as
// "OOl IVEGETABLeninJA").
//
// THE CAVEAT that shapes the design: 3 of those 20 frames read 0 on BOTH sides,
// the panel being mid-animation or occluded. So a single frame is not a
// decision. Evidence accumulates and the call is latched once, permanently.
//
// AND THE HONEST GAP: no captured frame shows a mirrored layout, so it is not
// established from data that the layout ever flips. If it never does, this
// detector simply confirms `.right` every match and costs a few seconds of OCR.
// If it does, the alternative was silent inversion. The decision and its
// evidence are printed and logged so a flip, when one occurs, is visible.

import Foundation

final class SideDetector {
    /// Text hits accumulated in each outer column.
    private(set) var leftHits = 0
    private(set) var rightHits = 0
    private(set) var frames = 0
    private var firstSampleAt: Date?

    /// Latched result. Nil until the evidence clears the bar below.
    private(set) var decision: PlayerSide?

    /// Watch for at least this long before calling it, so a panel caught
    /// mid-animation cannot decide the match on its own. Replay sets this to 0:
    /// it feeds frames as fast as it can decode them, so wall-clock is not a
    /// meaningful gate there — the hit count alone has to carry the decision.
    private let minSeconds: Double

    init(minSeconds: Double = 3.0) {
        self.minSeconds = minSeconds
    }
    /// Total hits required across both columns.
    private let minTotalHits = 6
    /// How far ahead the winner must be. The empty column measured a clean
    /// zero, so this only has to survive stray OCR noise, not a close call.
    private let dominance = 3.0

    /// Fold in one frame's probe counts. Returns the side exactly once, on the
    /// frame the decision latches.
    func observe(left: Int, right: Int) -> PlayerSide? {
        guard decision == nil else { return nil }

        let now = Date()
        if firstSampleAt == nil { firstSampleAt = now }
        leftHits += left
        rightHits += right
        frames += 1

        guard now.timeIntervalSince(firstSampleAt ?? now) >= minSeconds,
              leftHits + rightHits >= minTotalHits else { return nil }

        let hi = max(leftHits, rightHits), lo = min(leftHits, rightHits)
        guard Double(hi) >= Double(lo) * dominance || lo == 0 else { return nil }

        // The panel is on the side you own.
        let side: PlayerSide = rightHits > leftHits ? .right : .left
        decision = side
        return side
    }

    /// One line describing what the call was based on.
    var evidence: String {
        "\(frames) frames, panel-column text hits left=\(leftHits) right=\(rightHits)"
    }

    /// If the detector never gets a clean read, say so rather than guessing.
    func timedOut(after seconds: Double) -> Bool {
        guard decision == nil, let t = firstSampleAt else { return false }
        return Date().timeIntervalSince(t) > seconds
    }
}
