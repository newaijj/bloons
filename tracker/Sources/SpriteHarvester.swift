// Learns what tower sprites cost, from your own board.
//
// The encrypted asset catalogue has been treated as the reason tower pricing is
// unknowable. It is not the obstacle it looks like, because the game already
// tells you every price you need — on your own HUD, in cash.
//
// Your cash is parsed every frame. A drop tells you money left your pocket, and
// there are only two ways that happens: a send or a tower. Those are separable
// without ambiguity, because a send also RAISES your eco and a tower does not.
// So a cash drop with flat eco is a tower purchase of exactly that amount, to
// the dollar, with no estimation anywhere in it.
//
// Pair that drop with whatever changed on your board at the same moment and you
// have a sprite labelled with a price. Persist it and the library fills itself
// in over matches. This is the move the eco constants already make — measure it
// on your own side, where truth is free — applied to the one term that was
// still guesswork.
//
// The limit is honest and worth stating: you only learn towers YOU build. An
// opponent playing something you never touch stays unpriced, and is reported as
// unpriced rather than being given a number that looks earned.

import Foundation

final class SpriteHarvester {
    private let board: BoardWatcher
    private let library: SpriteLibrary
    private let roundData: RoundData

    private var lastCash: Int?
    private var lastEco: Double?

    private struct CashMove {
        /// Frame-clock seconds — see `Frame.time`. Pairing a purchase with the
        /// board change that reports it only works if both are measured on the
        /// same clock, and on replay the wall clock is not that clock.
        let at: Double
        let amount: Int      // positive magnitude
        var consumed = false
    }
    /// Cash movements not explained by a send, waiting to be matched with a
    /// board change. A census needs a couple of cycles to confirm a new site, so
    /// the purchase is always some seconds older than the change that reports it.
    private var spends: [CashMove] = []
    private var gains: [CashMove] = []
    private let pairWindow = 12.0
    /// Frame time of the most recent frame, so `take` can age the queues without
    /// a frame in hand.
    private var now = 0.0

    private(set) var learnedThisRun = 0
    private(set) var refundSamples: [Double] = []

    init(roundData: RoundData, library: SpriteLibrary) {
        self.roundData = roundData
        self.library = library
        board = BoardWatcher(region: Regions.myTrack, name: "mine")
    }

    func retarget() {
        board.retarget(Regions.myTrack)
        spends.removeAll(); gains.removeAll()
        lastCash = nil; lastEco = nil
        now = 0
    }

    func calibrate(frameWidth: Int) { board.calibrate(frameWidth: frameWidth) }

    var librarySize: Int { library.count }
    var siteCount: Int { board.confirmedSites.count }
    var trace: BoardWatcher.Trace { board.trace }
    /// Your own census, for offline scoring. This is the side worth scoring
    /// against: a cash drop with flat eco dates and prices every purchase here
    /// exactly, so your own board is fully labelled ground truth for a detector
    /// that has to work on a board where no labels exist at all.
    var sites: [TowerSite] { board.confirmedSites }

    /// Feed your own HUD. Call on every snapshot that parsed cash and eco,
    /// passing the time of the frame it was read from.
    func observe(cash: Int, eco: Double, at time: Double) {
        now = time
        defer { lastCash = cash; lastEco = eco }
        guard let pc = lastCash, let pe = lastEco else { return }
        let dCash = cash - pc
        let dEco = eco - pe

        if dCash < -5 {
            // A send costs cash AND raises eco. A tower costs cash and leaves
            // eco alone — which is what makes the price unambiguous.
            guard dEco < 0.05 else { return }
            spends.append(CashMove(at: now, amount: -dCash))
        } else if dCash > 5, dEco < 0.05 {
            // Could be an eco tick, pops, or a sell refund. Only ever consumed
            // when a site actually disappears, and then only at a plausible
            // ratio, so a tick sitting in here is harmless.
            gains.append(CashMove(at: now, amount: dCash))
        }
        let cutoff = now - pairWindow
        spends.removeAll { $0.at < cutoff || $0.consumed }
        gains.removeAll { $0.at < cutoff || $0.consumed }
    }

    /// Scan your own board and learn from anything that changed.
    @discardableResult
    func update(_ frame: Frame, round: Int) -> [String] {
        now = frame.time
        let changes = board.update(frame, allowed: roundData.naturalTypes(round))
        var notes: [String] = []

        for c in changes {
            switch c {
            case .appeared(let s):
                guard let price = takeSpend() else { continue }
                switch library.learn(s.descriptor, cumulativeCost: price,
                                     note: "new tower, R\(round)") {
                case .learned:
                    learnedThisRun += 1
                    notes.append("learned: new tower = $\(price) (library \(library.count))")
                case .rejected(let why):
                    // The pairing, not the price, is what went wrong: some cash
                    // move that was not this purchase got matched to it.
                    notes.append("REJECTED new tower: \(why) — cash/board pairing is wrong")
                }

            case .upgraded(let s, let from):
                guard let price = takeSpend() else { continue }
                // Cumulative, not incremental: the total sunk into a tower that
                // now looks like this is what it looked like before plus what
                // this step cost. That is what makes board value a pure
                // function of the census.
                let before = library.match(from)?.entry.cumulativeCost
                guard let base = before else {
                    notes.append("upgrade seen at $\(price) but the prior appearance is unknown — not learned")
                    continue
                }
                switch library.learn(s.descriptor, cumulativeCost: base + price,
                                     note: "upgrade from $\(base), R\(round)") {
                case .learned:
                    learnedThisRun += 1
                    notes.append("learned: upgrade = $\(base + price) cumulative (library \(library.count))")
                case .rejected(let why):
                    notes.append("REJECTED upgrade: \(why) — cash/board pairing is wrong")
                }

            case .removed(let s):
                guard let cost = library.match(s.descriptor)?.entry.cumulativeCost, cost > 0,
                      let refund = takeGain() else { continue }
                let ratio = Double(refund) / Double(cost)
                // A refund is most of the price, never more and never a
                // pittance. Anything outside that is a mispairing — most likely
                // an eco tick — and is dropped rather than learned from.
                guard ratio >= 0.5, ratio <= 1.0 else { continue }
                refundSamples.append(ratio)
                TowerWatcher.sellRefundRatio = refundSamples.reduce(0, +) / Double(refundSamples.count)
                notes.append(String(format: "learned: sell refund %.0f%% (%d samples)",
                                    TowerWatcher.sellRefundRatio * 100, refundSamples.count))
            }
        }
        return notes
    }

    /// Nearest unconsumed spend. Nearest rather than oldest because two
    /// purchases in quick succession are common and the census reports them in
    /// the order they confirmed.
    private func takeSpend() -> Int? { take(&spends) }
    private func takeGain() -> Int? { take(&gains) }

    private func take(_ list: inout [CashMove]) -> Int? {
        var bestIdx: Int?
        var bestGap = Double.greatestFiniteMagnitude
        for (i, m) in list.enumerated() where !m.consumed {
            let gap = now - m.at
            if gap <= pairWindow, gap < bestGap { bestGap = gap; bestIdx = i }
        }
        guard let i = bestIdx else { return nil }
        list[i].consumed = true
        return list[i].amount
    }
}
