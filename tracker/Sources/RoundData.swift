// The round table: what each round sends at both players naturally, and when.
//
// Loaded from data/btd6_derived_rounds.json (BTD6 DefaultRoundSet round 2N).
// BTDB2 alters some rounds, so every lookup is treated as a prior rather than as
// truth: a type on the track that this table does not schedule is read as an
// opponent send (see SendDetector), which means a wrong row here shows up as a
// phantom send rather than as a silent miss.

import Foundation

struct BloonGroup: Codable {
    let bloon: String
    let count: Int
    let start_s: Double
    let end_s: Double

    var type: BloonType? { BloonType.fromRoundData(bloon) }
}

struct RoundEntry: Codable {
    let btd6_round: Int
    let groups: [BloonGroup]
    let total_bloons: Int
}

final class RoundData {
    private var rounds: [Int: RoundEntry] = [:]

    init?(path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let raw = try? JSONDecoder().decode([String: RoundEntry].self, from: data)
        else { return nil }
        for (k, v) in raw { if let n = Int(k) { rounds[n] = v } }
    }

    var loadedRounds: Int { rounds.count }

    func entry(_ round: Int) -> RoundEntry? { rounds[round] }

    /// Bloon types this round spawns naturally, at any point.
    func naturalTypes(_ round: Int) -> Set<BloonType> {
        Set((rounds[round]?.groups ?? []).compactMap(\.type))
    }

    /// Types that should be entering the track `elapsed` seconds into the round.
    /// A grace window absorbs spawn jitter and the lag between spawn and the
    /// bloon actually reaching the sampling band.
    func expectedTypes(_ round: Int, elapsed: Double, grace: Double = 2.5) -> Set<BloonType> {
        guard let e = rounds[round] else { return [] }
        var out = Set<BloonType>()
        for g in e.groups {
            guard let t = g.type else { continue }
            if elapsed >= g.start_s - grace && elapsed <= g.end_s + grace { out.insert(t) }
        }
        return out
    }

    /// Total cash both players earn from popping this round's natural bloons.
    /// Identical for both sides, which is what makes it usable as a shared term.
    func naturalPopIncome(_ round: Int) -> Int {
        (rounds[round]?.groups ?? []).reduce(0) { sum, g in
            sum + (g.type.map { $0.popValue * g.count } ?? 0)
        }
    }
}
