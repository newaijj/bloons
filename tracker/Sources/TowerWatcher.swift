// What the opponent's board is worth, from the census of what is standing on it.
//
// Board value is recomputed from the current census every cycle, never
// accumulated. That is the property that matters: a site which was never a
// tower stops being counted the moment it fails verification, so a bad reading
// costs a few seconds of error instead of permanently inflating the books.
// Summing build EVENTS instead has no way back down — a logged match run that
// way reached $12,461 against a $2,302 ceiling and stayed there.
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
    /// Sites counted at the fallback estimate rather than a learned price — how
    /// much of the figure is still guesswork.
    var unpricedSites = 0

    var total: Int { boardValue + sunkFromSells }
}

final class TowerWatcher {
    private let board: BoardWatcher
    private let library: SpriteLibrary

    /// Fraction of a tower's cost returned when it is sold. BTD-family games
    /// refund most but not all of it. This is only the starting assumption:
    /// SpriteHarvester overwrites it with a running mean as soon as a sell on
    /// your own board pairs a vanished site with a plausible cash rise.
    static var sellRefundRatio = 0.75

    /// Cost assumed for a tower whose appearance is not in the library yet: the
    /// median base cost of the 22 towers that exist (PriceTable), flat.
    ///
    /// Flat, deliberately: scaling it by blob area is the obvious-looking move
    /// and does not work. Tested against the learned library on 2026-08-16, area
    /// vs cumulative cost came out at **r = −0.219, n = 6** — the wrong sign, on
    /// far too few points to read as a real negative. A multiplier fitted to that
    /// carries no information and turns noise into apparent detail.
    ///
    /// n = 6 is not enough to have settled this. The upgrade path is to take the
    /// prior from the distribution of learned cumulative costs once the library
    /// is large enough to have one — that is drawn from real play instead of
    /// from base costs, and it needs no table at all.
    static var fallbackCost = PriceTable.medianTowerCost

    private(set) var valuation = BoardValuation()
    private var sunkFromSells = 0

    init(library: SpriteLibrary) {
        self.library = library
        board = BoardWatcher(region: Regions.oppTrack, name: "opponent")
    }

    func retarget() {
        board.retarget(Regions.oppTrack)
        sunkFromSells = 0
        valuation = BoardValuation()
    }

    var sceneChanges: Int { board.sceneChanges }
    var trace: BoardWatcher.Trace { board.trace }
    /// The census itself, for offline scoring. A site count alone cannot be
    /// scored against ground truth — you need to know WHERE the detector
    /// thought the towers were to say whether it was right.
    var sites: [TowerSite] { board.confirmedSites }

    /// Scan their board and revalue it. Returns human-readable change notes.
    @discardableResult
    func update(_ frame: Frame, round: Int) -> [String] {
        let changes = board.update(frame)
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
        return notes
    }

    /// Board value from scratch, every time.
    private func revalue() {
        var v = BoardValuation()
        v.sunkFromSells = sunkFromSells
        for s in board.confirmedSites {
            v.sites += 1
            if library.match(s.descriptor) == nil { v.unpricedSites += 1 }
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
