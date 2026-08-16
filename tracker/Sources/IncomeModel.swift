// The opponent's books, reconstructed.
//
// Nothing here is hardcoded from a wiki. Every constant the model needs is
// learned from YOUR side of the screen, which is legitimate because the game is
// symmetric — you both start with the same cash and eco, both face the same
// natural rounds, and both get paid on the same tick.
//
//   starting cash/eco  <- read off your HUD in the opening seconds
//   eco tick period    <- measured from the spacing of your cash jumps
//   payout per eco     <- fitted from jump size against your eco at the time
//
// Cash-on-hand is reported as an UPPER BOUND, and deliberately so: their income
// is recoverable but their tower spending is not fully observable, so the honest
// statement is "they have at most this much". That is also the form the
// affordability question actually needs.

import Foundation

struct EcoTick {
    let at: Date
    let payout: Double
    let ecoAtTick: Double
}

/// Learns the eco tick period and payout ratio from your own cash trajectory.
final class EcoCalibrator {
    private var samples: [(t: Date, cash: Int, eco: Double)] = []
    private var ticks: [EcoTick] = []

    private(set) var period: Double = 6.0      // seconds; 4.2 in Speed Battles
    private(set) var payoutRatio: Double = 1.0 // cash per point of eco, per tick
    private(set) var calibrated = false

    func observe(cash: Int, eco: Double) {
        let now = Date()
        if let last = samples.last {
            let jump = cash - last.cash
            // An eco tick is a discrete upward step. Pops trickle; spending is
            // negative. Require the step to clear both noise and pop income.
            if jump > 20, last.eco > 0 {
                if let lastTick = ticks.last, now.timeIntervalSince(lastTick.at) < 1.5 {
                    // Same tick seen twice across adjacent samples; keep the larger.
                    if Double(jump) > lastTick.payout {
                        ticks[ticks.count - 1] = EcoTick(at: lastTick.at, payout: Double(jump), ecoAtTick: last.eco)
                    }
                } else {
                    ticks.append(EcoTick(at: now, payout: Double(jump), ecoAtTick: last.eco))
                }
                recompute()
            }
        }
        samples.append((now, cash, eco))
        if samples.count > 400 { samples.removeFirst(samples.count - 400) }
        if ticks.count > 80 { ticks.removeFirst(ticks.count - 80) }
    }

    private func recompute() {
        guard ticks.count >= 3 else { return }
        // Period: median gap between consecutive ticks.
        var gaps: [Double] = []
        for i in 1..<ticks.count {
            let g = ticks[i].at.timeIntervalSince(ticks[i - 1].at)
            if g > 1.0, g < 20.0 { gaps.append(g) }
        }
        if gaps.count >= 2 { period = median(gaps) }

        // Ratio: median of payout / eco, which shrugs off ticks contaminated by
        // a simultaneous pop or purchase.
        let ratios = ticks.filter { $0.ecoAtTick > 1 }.map { $0.payout / $0.ecoAtTick }
        if ratios.count >= 3 {
            payoutRatio = median(ratios)
            calibrated = true
        }
    }

    private func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : (s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
    }

    var ticksSeen: Int { ticks.count }
}

struct OpponentBooks {
    var eco: Double = 0
    var ecoIncome: Double = 0
    var popIncome: Double = 0
    var sendSpend: Double = 0
    var towerSpend: Double = 0
    var sendsDetected: Int = 0
    var lowConfidenceSends: Int = 0
    var buildCount: Int = 0

    var totalGenerated: Double { ecoIncome + popIncome }

    /// What they actually have, best estimate. Tower spend is the estimated
    /// term, so this is softer than the ceiling below it.
    var cash: Double { max(0, totalGenerated - sendSpend - towerSpend) }

    /// What they could have if they had built nothing. A hard ceiling: income
    /// and send costs are both recovered rather than estimated.
    var cashCeiling: Double { max(0, totalGenerated - sendSpend) }

    /// Cash paid out per eco disbursement — the same number and timescale the
    /// game's own eco counter uses.
    var payoutPerTick: Double = 0
    var tickPeriod: Double = 6.0

    /// Share of everything they have earned that went back into sends.
    var ecoShare: Double { totalGenerated > 0 ? sendSpend / totalGenerated : 0 }
}

final class IncomeModel {
    private let roundData: RoundData
    let calibrator = EcoCalibrator()

    private(set) var books = OpponentBooks()
    private(set) var baseCash: Int?
    private(set) var baseEco: Double?

    private var lastTickAt: Date?
    private var completedRounds = Set<Int>()
    private var currentRound = 0
    private var sendLog: [SendEvent] = []
    /// Cost and eco per send type, as read from the cards this round.
    private var cardTable: [BloonType: SendCard] = [:]

    init(roundData: RoundData) { self.roundData = roundData }

    var isSeeded: Bool { baseEco != nil }

    /// Seed both players' starting position from your own HUD, early in round 1
    /// before either side has moved the numbers much.
    func seedIfNeeded(_ snap: HUDSnapshot) {
        guard baseEco == nil, let round = snap.round, round <= 1,
              let cash = snap.myCash, let eco = snap.myEco, eco > 0
        else { return }
        baseCash = cash
        baseEco = eco
        books.eco = eco
        books.popIncome = 0
    }

    func update(snap: HUDSnapshot, events: [SendEvent]) {
        if let cards = Optional(snap.sendCards), !cards.isEmpty {
            for c in cards { cardTable[c.type] = c }
        }
        if let cash = snap.myCash, let eco = snap.myEco {
            calibrator.observe(cash: cash, eco: eco)
        }
        seedIfNeeded(snap)
        guard isSeeded else { return }

        // Their eco grows by the eco value of every send we attribute to them.
        for e in events {
            let gain = cardTable[e.type]?.eco ?? 1.0
            let cost = Double(cardTable[e.type]?.cost ?? 20)
            books.eco += gain * Double(e.sends)
            books.sendSpend += cost * Double(e.sends)
            books.sendsDetected += e.sends
            if e.confidence < 0.6 { books.lowConfidenceSends += e.sends }
            sendLog.append(e)
        }

        // Pay them on the same tick cadence we measured on our own side.
        let period = calibrator.period
        let now = Date()
        if let last = lastTickAt {
            if now.timeIntervalSince(last) >= period {
                let n = floor(now.timeIntervalSince(last) / period)
                books.ecoIncome += books.eco * calibrator.payoutRatio * n
                lastTickAt = last.addingTimeInterval(period * n)
            }
        } else {
            lastTickAt = now
        }
        // Reported per disbursement, matching the game's own eco counter. The
        // logged match measured the ratio at exactly 1.000, i.e. eco value IS
        // the cash paid each tick — but it stays measured rather than assumed.
        books.payoutPerTick = books.eco * calibrator.payoutRatio
        books.tickPeriod = period

        // Both players face the same natural round, so its pop income is shared.
        if let r = snap.round {
            if r != currentRound {
                if currentRound > 0 { completedRounds.insert(currentRound) }
                currentRound = r
            }
            let earned = completedRounds.reduce(0) { $0 + roundData.naturalPopIncome($1) }
            books.popIncome = Double(earned) + Double(baseCash ?? 0)
        }
    }

    func recentSends(_ n: Int) -> [SendEvent] { Array(sendLog.suffix(n).reversed()) }

    /// Fold in what the tower watcher has seen them build.
    func noteTowerSpend(total: Int, builds: Int) {
        books.towerSpend = Double(total)
        books.buildCount = builds
    }

    /// Whether they can cover a price. Uses the best estimate; the ceiling is
    /// available separately for the "could they possibly" version.
    func canAfford(_ price: Int) -> Bool { books.cash >= Double(price) }
}
