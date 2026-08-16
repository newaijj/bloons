// Recovers the opponent's sends from your own track.
//
// The idea validated during calibration: a round has a known natural bloon
// composition, so any bloon type on your track that the round does not schedule
// came from your opponent. Round 3 spawns green/red/blue — the grouped yellows
// sitting on the track were a send.
//
// Two refinements on top of that:
//   - Static scenery and your own towers are removed by a per-sample background
//     model, so a pink tack shooter is not mistaken for pink bloons. Towers
//     placed mid-match fade into the background within a few seconds.
//   - A type the round DOES schedule can still be sent. That case is caught by
//     comparing the observed count against the count the round schedules, and
//     treating a large excess as sends — a weaker signal, reported as such.

import Foundation
import CoreGraphics

struct SendEvent {
    let type: BloonType
    let sends: Int
    let confidence: Double   // 0-1; unscheduled types score high, excess-of-expected low
    let round: Int
    let at: Date
}

final class SendDetector {
    private let roundData: RoundData
    private let scanner: TrackScanner

    /// Open bursts, per bloon type.
    private struct Burst {
        var peakSamples: Int
        var framesBelow: Int
        var scheduled: Bool
        /// Sends already credited for this burst. A sustained stream must pay
        /// out as it arrives — waiting for the burst to end would leave the
        /// opponent's eco stale for the whole time they are pressuring you.
        var credited: Int
    }
    private var bursts: [BloonType: Burst] = [:]

    private var currentRound = 0
    private var roundStart = Date()

    /// Samples one bloon occupies after grid subsampling and typical occlusion.
    /// Scaled from frame width; approximate, and the reason quantity carries a
    /// confidence band rather than being reported as exact.
    private var samplesPerBloon: Double = 40

    private(set) var lastCounts: [BloonType: Int] = [:]

    /// Only types that could actually be on screen this round are counted. A
    /// bloon is plausible if the round spawns it naturally or it is purchasable
    /// as a send right now. Without this, warm map scenery reads as ceramics
    /// from round 1.
    private var allowedTypes: Set<BloonType> = [.red, .blue, .green, .yellow]

    init(roundData: RoundData, fps: Int = 10) {
        self.roundData = roundData
        self.scanner = TrackScanner(region: Regions.myTrack, sampleStep: 4,
                                    absorbAfterSeconds: 2.5)
    }

    /// Re-point at your track after the side has been decided. Any burst state
    /// accumulated before the latch was read off the wrong half, so it goes.
    func retarget() {
        scanner.retarget(Regions.myTrack)
        bursts.removeAll()
        lastCounts = [:]
    }

    func noteRound(_ round: Int) {
        guard round != currentRound else { return }
        currentRound = round
        roundStart = Date()
        bursts.removeAll()
    }

    func setAvailable(cards: [SendCard]) {
        var allowed = roundData.naturalTypes(currentRound)
        for c in cards { allowed.insert(c.type) }
        // Sends already seen this match stay live even if the card scroll moved.
        for t in bursts.keys { allowed.insert(t) }
        if allowed.isEmpty { allowed = [.red, .blue, .green, .yellow] }
        allowedTypes = allowed
    }

    /// Visible fraction of a bloon's area once overlap, tacks, and projectiles
    /// are accounted for.
    ///
    /// NOT pinned down. Converting pixel area to a bloon count needs to know how
    /// many bloons are on screen concurrently, and neither the round table nor
    /// the pixels tell you that — bloons are popped at a rate that depends
    /// entirely on the defence. Every value derivable from the logged match
    /// (round 1's 35 reds, round 5's 102 blues) is contaminated by sends and by
    /// an unknown pop rate, so this is an estimate with a wide error bar and
    /// send COUNTS inherit that error. Override with --visible-fraction.
    ///
    /// The real fix is to stop counting area and start counting time: sends
    /// dispatch at a fixed cadence, and your own outgoing queue on the centre
    /// divider shows tiles draining at exactly that cadence. Duration of a
    /// type's presence divided by per-send dispatch time gives a count that
    /// never depends on how fast bloons are being popped.
    static var visibleFraction = 0.40

    func calibrate(frameWidth: Int) {
        let d = 40.0 * Double(frameWidth) / 2560.0
        samplesPerBloon = max(6, (d * d / 16.0) * Self.visibleFraction)
    }

    /// Scan your track for bloons the round did not put there.
    func scan(_ frame: Frame) -> [BloonType: Int] {
        let counts = scanner.scan(frame, allowed: allowedTypes).counts
        lastCounts = counts
        return counts
    }

    /// Fold this frame's counts into burst state and emit completed sends.
    func update(counts: [BloonType: Int], cards: [SendCard]) -> [SendEvent] {
        let elapsed = Date().timeIntervalSince(roundStart)
        let expectedNow = roundData.expectedTypes(currentRound, elapsed: elapsed)
        let scheduledCount = scheduledCounts()
        var events: [SendEvent] = []

        let presenceFloor = Int(samplesPerBloon * 0.8)

        for type in allowedTypes {
            let n = counts[type] ?? 0
            let scheduled = expectedNow.contains(type)

            // For a scheduled type, only the excess over what the round spawns
            // counts as a send.
            let effective: Int
            if scheduled {
                let allowance = Int(Double(scheduledCount[type] ?? 0) * samplesPerBloon * 1.6) + presenceFloor * 2
                effective = max(0, n - allowance)
            } else {
                effective = n
            }

            let perSend = cards.first { $0.type == type }?.quantity ?? 5

            if effective > presenceFloor {
                var b = bursts[type] ?? Burst(peakSamples: 0, framesBelow: 0,
                                              scheduled: scheduled, credited: 0)
                b.peakSamples = max(b.peakSamples, effective)
                b.framesBelow = 0

                // Credit sends as the stream grows, not when it finally stops.
                let bloons = Double(b.peakSamples) / samplesPerBloon
                let implied = max(1, Int((bloons / Double(perSend)).rounded()))
                if implied > b.credited {
                    events.append(SendEvent(
                        type: type,
                        sends: implied - b.credited,
                        confidence: b.scheduled ? 0.45 : 0.85,
                        round: currentRound,
                        at: Date()))
                    b.credited = implied
                }
                bursts[type] = b
            } else if var b = bursts[type] {
                b.framesBelow += 1
                bursts[type] = b
                // Closed once the type has been gone for roughly a second.
                if b.framesBelow >= 8 { bursts[type] = nil }
            }
        }
        return events
    }

    /// How many of each type this round has spawned so far.
    private func scheduledCounts() -> [BloonType: Int] {
        guard let entry = roundData.entry(currentRound) else { return [:] }
        let elapsed = Date().timeIntervalSince(roundStart)
        var out: [BloonType: Int] = [:]
        for g in entry.groups {
            guard let t = g.type else { continue }
            guard elapsed >= g.start_s else { continue }
            let span = max(0.001, g.end_s - g.start_s)
            let frac = min(1.0, (elapsed - g.start_s) / span)
            out[t, default: 0] += Int(Double(g.count) * frac)
        }
        return out
    }
}
