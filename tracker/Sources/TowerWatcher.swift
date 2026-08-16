// What the opponent's board is worth, from the census of what is standing on it.
//
// Board value is recomputed from the current census every cycle, never
// accumulated. That is the property that matters: a site which was never a
// tower stops being counted the moment it fails verification, so a bad reading
// costs a few seconds of error instead of permanently inflating the books. The
// previous event-sum design had no way back down — a logged match reached
// $12,461 against a $2,302 ceiling and stayed there.
//
// Pricing comes from the sprite library, which is learned on YOUR board where
// your own cash gives the exact figure (see Sprites.swift). A tower whose
// appearance is not in the library is counted at a fallback estimate and
// reported as unpriced, rather than being quietly given a number that looks as
// authoritative as a learned one.

import Foundation

struct BoardValuation {
    var boardValue = 0
    /// Money spent on towers that are no longer standing. A sell refunds only
    /// part of what went in, and the rest stays spent.
    var sunkFromSells = 0
    var sites = 0
    var pricedSites = 0
    var unpricedSites = 0

    var total: Int { boardValue + sunkFromSells }
    var pricedShare: Double { sites > 0 ? Double(pricedSites) / Double(sites) : 0 }
}

final class TowerWatcher {
    private let board: BoardWatcher
    private let roundData: RoundData
    private let library: SpriteLibrary

    /// Fraction of a tower's cost returned when it is sold. BTD-family games
    /// refund most but not all of it. Measurable on your own board from a cash
    /// rise that is neither an eco tick nor pops; until that is wired up this
    /// stays a stated assumption rather than a measured one.
    static var sellRefundRatio = 0.75

    /// Cost assumed for a tower whose appearance is not in the library yet: the
    /// median base cost of the 22 towers that exist (PriceTable), flat.
    ///
    /// It used to be $400 scaled 0.6x–3.0x by blob area, spanning $240–$1200 on
    /// a relationship nothing had established. Tested against the learned
    /// library on 2026-08-16: area vs cumulative cost came out at **r = −0.219,
    /// n = 6** — the wrong sign, and far too few points to read as a real
    /// negative. So the multiplier was carrying no information and the spread it
    /// produced was noise dressed as detail. A flat published median is a worse
    /// estimate of any individual tower and a more honest one of all of them.
    ///
    /// n = 6 is not enough to have settled this. The upgrade path is to take the
    /// prior from the distribution of learned cumulative costs once the library
    /// is large enough to have one — that is drawn from real play instead of
    /// from base costs, and it needs no table at all.
    static var fallbackCost = PriceTable.medianTowerCost

    private(set) var valuation = BoardValuation()
    private(set) var sunkFromSells = 0
    private(set) var recentChanges: [String] = []

    init(roundData: RoundData, library: SpriteLibrary) {
        self.roundData = roundData
        self.library = library
        board = BoardWatcher(region: Regions.oppTrack, name: "opponent")
    }

    func retarget() {
        board.retarget(Regions.oppTrack)
        sunkFromSells = 0
        valuation = BoardValuation()
        recentChanges.removeAll()
    }

    func calibrate(frameWidth: Int) { board.calibrate(frameWidth: frameWidth) }

    var sceneChanges: Int { board.sceneChanges }
    var trace: BoardWatcher.Trace { board.trace }
    var siteCount: Int { board.confirmedSites.count }
    /// The census itself, for offline scoring. A site count alone cannot be
    /// scored against ground truth — you need to know WHERE the detector
    /// thought the towers were to say whether it was right.
    var sites: [TowerSite] { board.confirmedSites }

    /// Scan their board and revalue it. Returns human-readable change notes.
    ///
    /// The round's natural bloon types go through so the scanner can learn where
    /// the path runs — towers cannot be built there, and that is one of the
    /// filters keeping a bloon stream out of the census.
    @discardableResult
    func update(_ frame: Frame, round: Int) -> [String] {
        let changes = board.update(frame, allowed: roundData.naturalTypes(round))
        var notes: [String] = []

        for c in changes {
            switch c {
            case .appeared(let s):
                notes.append("build: \(describe(s)) @R\(round)")
            case .upgraded(let s, _):
                notes.append("upgrade: \(describe(s)) @R\(round)")
            case .removed(let s):
                // They get most of it back; the remainder stays spent.
                let sunk = Int(Double(cost(of: s)) * (1.0 - Self.sellRefundRatio))
                sunkFromSells += sunk
                notes.append("sold: \(describe(s)) — $\(sunk) stays sunk @R\(round)")
            }
        }

        revalue()
        recentChanges.append(contentsOf: notes)
        if recentChanges.count > 40 { recentChanges.removeFirst(recentChanges.count - 40) }
        return notes
    }

    /// Board value from scratch, every time.
    private func revalue() {
        var v = BoardValuation()
        v.sunkFromSells = sunkFromSells
        for s in board.confirmedSites {
            v.sites += 1
            if library.match(s.descriptor) != nil { v.pricedSites += 1 } else { v.unpricedSites += 1 }
            v.boardValue += cost(of: s)
        }
        valuation = v
    }

    /// Learned price if the appearance is known, otherwise the published prior.
    func cost(of s: TowerSite) -> Int {
        if let m = library.match(s.descriptor) { return m.entry.cumulativeCost }
        return Self.fallbackCost
    }

    private func describe(_ s: TowerSite) -> String {
        if let m = library.match(s.descriptor) {
            return "$\(m.entry.cumulativeCost) (learned, d=\(String(format: "%.2f", m.distance)))"
        }
        return "~$\(cost(of: s)) (unpriced, median prior)"
    }
}
