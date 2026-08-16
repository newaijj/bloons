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

    /// Cost assumed for a tower whose appearance is not in the library yet.
    /// Scaled by blob area against one footprint, which is a weak signal — hence
    /// `unpricedSites` being reported alongside the total.
    private static let fallbackBase = 400.0

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

    /// Learned price if the appearance is known, otherwise a scaled fallback.
    private func cost(of s: TowerSite) -> Int {
        if let m = library.match(s.descriptor) { return m.entry.cumulativeCost }
        let d = BoardWatcher.spriteDiameterAt2560
        let footprint = max(40.0, (d * d / 16.0) * 0.5)
        let sizeFactor = min(3.0, max(0.6, Double(s.areaSamples) / footprint))
        return Int(Self.fallbackBase * sizeFactor)
    }

    private func describe(_ s: TowerSite) -> String {
        if let m = library.match(s.descriptor) {
            return "$\(m.entry.cumulativeCost) (learned, d=\(String(format: "%.2f", m.distance)))"
        }
        return "~$\(cost(of: s)) (unpriced)"
    }
}
