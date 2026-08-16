// Machine-readable census state, one JSON object per replayed frame.
//
// The replay printout is for a human reading a run; it cannot be scored. A
// detector that finds four towers and a detector that finds four wrong towers
// produce the same console line, and the difference between them is the entire
// question. So the census goes out as data: where each site is, how big, what
// it was priced at, on both boards, at every frame.
//
// Positions are FRAME pixels, not normalised and not screen coordinates. Frame
// pixels are the only coordinate system that ground truth and detector output
// can both be expressed in — the recording has no window origin, so absolute
// screen coordinates from a placement driver cannot be converted, and
// normalised coordinates would silently change meaning if the capture size
// ever did.

import Foundation

struct CensusRecord: Codable {
    struct Site: Codable {
        let id: Int
        let cx: Int, cy: Int
        let x0: Int, y0: Int, x1: Int, y1: Int
        let area: Int
        let cost: Int
        let priced: Bool
        /// Frame time the site was first seen, so a scorer can ask when a
        /// detection ARRIVED rather than only that it is present now. Recall
        /// against a timed purchase is a question about arrival.
        let firstSeen: Double
    }
    let file: String
    let t: Double
    let round: Int?
    let side: String?
    /// The opponent's board — the thing being predicted.
    let theirs: [Site]
    /// Your own board — the thing that carries labels.
    let mine: [Site]
}

final class CensusLog {
    private let handle: FileHandle
    private let encoder = JSONEncoder()

    init?(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        handle = h
        encoder.outputFormatting = [.sortedKeys]
    }

    func write(_ r: CensusRecord) {
        guard var d = try? encoder.encode(r) else { return }
        d.append(0x0A)
        handle.write(d)
    }

    func close() { try? handle.close() }

    /// Build a record from the two watchers. Pricing goes through the same
    /// path the books use, so a scorer sees the numbers the tracker would have
    /// acted on rather than a parallel estimate.
    static func record(file: String, t: Double, round: Int?, side: String?,
                       towers: TowerWatcher, harvester: SpriteHarvester,
                       library: SpriteLibrary) -> CensusRecord {
        func site(_ s: TowerSite, cost: Int) -> CensusRecord.Site {
            CensusRecord.Site(id: s.id, cx: s.centreX, cy: s.centreY,
                              x0: s.x0, y0: s.y0, x1: s.x1, y1: s.y1,
                              area: s.areaSamples, cost: cost,
                              priced: library.match(s.descriptor) != nil,
                              firstSeen: s.firstSeen)
        }
        return CensusRecord(
            file: file, t: t, round: round, side: side,
            theirs: towers.sites.map { site($0, cost: towers.cost(of: $0)) },
            // Your own sites are not priced by the books — they are what PRICES
            // the books — so they carry the library's figure or zero.
            mine: harvester.sites.map { site($0, cost: library.match($0.descriptor)?.entry.cumulativeCost ?? 0) })
    }
}
