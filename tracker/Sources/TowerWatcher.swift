// Watches the opponent's track for money leaving their pocket.
//
// Every tower placed and every upgrade bought changes their board and then
// settles. TrackScanner's absorption signal fires exactly on "something new
// stopped moving", so each settle is a purchase event.
//
// What this CANNOT do is read the price tag. Identifying which tower and which
// upgrade tier from its sprite needs an asset catalogue the game ships
// encrypted. So cost is estimated from the shop prices actually on screen, and
// the result is reported as an estimate with a band — never as a exact figure.
//
// The footprint area is used as a weak tier signal: a bigger settle is usually a
// bigger tower or a higher upgrade.

import Foundation

struct BuildEvent {
    let samples: Int
    let estimatedCost: Int
    let round: Int
    let at: Date
}

final class TowerWatcher {
    private let scanner: TrackScanner
    /// Absorbed samples accumulate over a short window; a purchase is a cluster,
    /// not a single stray pixel settling.
    private var window: [(t: Date, samples: Int)] = []
    private let windowSeconds = 2.0

    /// A tower footprint at 2560px wide, after grid subsampling.
    private var footprintSamples = 120.0
    private var lastEventAt = Date.distantPast

    private(set) var builds: [BuildEvent] = []
    private(set) var totalSpend = 0

    /// Shop prices seen on screen, used to scale the cost estimate to whatever
    /// tier of tower is actually in play.
    var shopPrices: [Int] = []

    init(fps: Int) {
        scanner = TrackScanner(region: Regions.oppTrack, sampleStep: 4,
                               absorbAfterSeconds: 2.5, fps: fps)
    }

    /// Re-point at their track after the side has been decided. Builds counted
    /// before the latch were counted on the wrong board, so they are discarded
    /// rather than carried into the books.
    func retarget() {
        scanner.retarget(Regions.oppTrack)
        window.removeAll()
        builds.removeAll()
        totalSpend = 0
        lastEventAt = Date()
    }

    func calibrate(frameWidth: Int) {
        let d = 52.0 * Double(frameWidth) / 2560.0
        footprintSamples = max(20, (d * d / 16.0) * 0.5)
    }

    /// Scan their side. Bloon colours are irrelevant here; only settling matters.
    func update(_ frame: Frame, round: Int) -> BuildEvent? {
        let result = scanner.scan(frame, allowed: [])
        let now = Date()
        if result.absorbed > 0 { window.append((now, result.absorbed)) }
        window.removeAll { now.timeIntervalSince($0.t) > windowSeconds }

        let clustered = window.reduce(0) { $0 + $1.samples }
        // Require most of a footprint to have settled, and space events out so a
        // single build does not register three times as it fades in.
        guard Double(clustered) >= footprintSamples * 0.6,
              now.timeIntervalSince(lastEventAt) > 1.5 else { return nil }

        window.removeAll()
        lastEventAt = now

        let cost = estimateCost(samples: clustered)
        let e = BuildEvent(samples: clustered, estimatedCost: cost, round: round, at: now)
        builds.append(e)
        totalSpend += cost
        return e
    }

    /// Scale a typical shop price by how large the settle was relative to one
    /// footprint. Falls back to a mid-range tower when the shop is unreadable.
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
}
