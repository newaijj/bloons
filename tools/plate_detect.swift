// Offline plate + occupancy/flicker tower detector.
//
// Deliberately NOT wired into the live pipeline yet. Run as an experiment first:
// it reads a recorded session and writes the same CensusRecord JSONL that
// `--census-log` produces, so tools/score.py scores it against the frozen
// baseline with no changes. Iterating on thresholds costs one pass over the
// PNGs instead of a full replay, and nothing about the shipped detector moves
// until a held-out number says it should.
//
// The method, and why each part is there:
//
//   plate      the board with nothing on it, taken from one empty frame. A tower
//              standing at seed time is part of the plate and INVISIBLE by
//              construction, so the seed frame has to be verified empty rather
//              than assumed — on 20260816T124547, t=42.0 is empty on both halves.
//   occupancy  fraction of a window in which a cell differs from the plate.
//              Alone this does NOT work: a dense bloon stream keeps path cells
//              covered ~100% of the time (measured: 2000+ cells above 90%).
//   flicker    mean frame-to-frame colour change in the same window. This is the
//              axis that separates them — a tower's pixels stop changing, a
//              stream of bloons over one spot never does.
//
// Both are computed over a rolling window in RECORDED seconds, not frames, so a
// recording's frame rate cannot change what the thresholds mean.

import Foundation
import CoreGraphics
import ImageIO

// MARK: - options

var sessionDir = ""
var outPath = "census_plate.jsonl"
var mySide = "left"
var plateT = -1.0          // negative = first frame of the scan range
var occThresh = 90.0       // sum |dRGB| over 0-255 channels
var occFrac = 0.90
var flickerMax = 15.0      // 1e9 disables the flicker gate (the ablation arm)
var windowSec = 2.5
var censusPeriod = 2.0
var step = 8
var minCells = 20
var maxCells = 4000
/// Longer side over shorter. The dominant false-positive family on the first
/// train run was board-BORDER artifacts: four strips sitting exactly on the top
/// edge row (16px tall, up to 336 wide) and thin vertical slivers on the outer
/// edge, at aspect ratios of 21:1 and 38:1. Real towers measured 96x128 and
/// 64x72 — 0.75 and 0.89 — so this separates them by an order of magnitude and
/// is not a close call.
var maxAspect = 2.0
/// Cells trimmed from each edge of a board band. The border decoration is
/// chrome, not play area, and it shifts by a pixel or two between frames, which
/// is enough to read as permanently occupied and perfectly still.
var insetCells = 2
/// Seconds a site must survive before it is reported. The remaining false
/// positives on the train block were a family of 5-6 blobs sharing one
/// firstSeen — a dense pack of same-coloured bloons arriving together in the
/// lower right. Flicker does not reject those: packed red-on-red looks
/// identical frame to frame, so a tight stream is occupied AND still. What
/// separates them is that a tower placed is a tower forever, while a pack
/// clears in seconds. Costs detection latency, which the books can afford.
var minAgeSec = 6.0
/// Peak splitting. Only blobs at least this big are eligible, so a lone tower is
/// never fragmented; a seed must sit at least `splitMinDepth` cells from the
/// blob edge; and two seeds closer than `splitPeakSep` cells are the same
/// sprite's plateau. A tower is ~100-150px across, which at step 8 is 12-19
/// cells, so peaks belonging to different towers are several cells apart.
var splitMinCells = 200
var splitMinDepth = 3
var splitPeakSep = 6.0
var fromT = 0.0, toT = Double.greatestFiniteMagnitude

var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    func next() -> String { it.next() ?? "" }
    switch a {
    case "--session": sessionDir = next()
    case "--out": outPath = next()
    case "--my-side": mySide = next()
    case "--plate-t": plateT = Double(next()) ?? plateT
    case "--occ-thresh": occThresh = Double(next()) ?? occThresh
    case "--occ-frac": occFrac = Double(next()) ?? occFrac
    case "--flicker-max": flickerMax = Double(next()) ?? flickerMax
    case "--window": windowSec = Double(next()) ?? windowSec
    case "--census-period": censusPeriod = Double(next()) ?? censusPeriod
    case "--step": step = Int(next()) ?? step
    case "--min-cells": minCells = Int(next()) ?? minCells
    case "--max-cells": maxCells = Int(next()) ?? maxCells
    case "--max-aspect": maxAspect = Double(next()) ?? maxAspect
    case "--inset": insetCells = Int(next()) ?? insetCells
    case "--min-age": minAgeSec = Double(next()) ?? minAgeSec
    case "--split-min-cells": splitMinCells = Int(next()) ?? splitMinCells
    case "--split-min-depth": splitMinDepth = Int(next()) ?? splitMinDepth
    case "--split-peak-sep": splitPeakSep = Double(next()) ?? splitPeakSep
    case "--from": fromT = Double(next()) ?? fromT
    case "--to": toT = Double(next()) ?? toT
    default: FileHandle.standardError.write("unknown arg \(a)\n".data(using: .utf8)!)
    }
}
guard !sessionDir.isEmpty else {
    print("usage: plate_detect --session <dir> --out <jsonl> [--my-side left|right] ...")
    exit(2)
}

// MARK: - session

struct Manifest: Codable {
    struct Entry: Codable { let file: String; let t: Double }
    var frames: [Entry]
    var frameWidth: Int
    var frameHeight: Int
    var side: String?
}
let mURL = URL(fileURLWithPath: sessionDir).appendingPathComponent("manifest.json")
guard let mData = FileManager.default.contents(atPath: mURL.path),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: mData) else {
    print("no readable manifest in \(sessionDir)"); exit(1)
}
let frames = manifest.frames.sorted { $0.t < $1.t }.filter { $0.t >= fromT && $0.t <= toT }
guard !frames.isEmpty else { print("no frames in [\(fromT), \(toT)]"); exit(1) }

let W = manifest.frameWidth, H = manifest.frameHeight

func load(_ file: String) -> [UInt8]? {
    let u = URL(fileURLWithPath: sessionDir).appendingPathComponent(file)
    guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var buf = [UInt8](repeating: 0, count: W * H * 4)
    buf.withUnsafeMutableBytes { p in
        guard let ctx = CGContext(data: p.baseAddress, width: W, height: H,
                                  bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    }
    return buf
}

// MARK: - geometry
//
// Same bands as Regions.swift: the left board measured, the right its exact
// reflection, and the centre chrome column subtracted from both.

struct Band { let name: String, x0: Int, x1: Int }
let leftX0 = Int(0.0742 * Double(W)), bandW = Int(0.4102 * Double(W))
let boardY0 = Int(0.1102 * Double(H)), boardY1 = Int(0.9918 * Double(H))
let rightX0 = W - leftX0 - bandW
let chromeX0 = Int(0.4813 * Double(W)), chromeX1 = Int((0.4813 + 0.0375) * Double(W))

let bands = mySide == "left"
    ? [Band(name: "mine", x0: leftX0, x1: leftX0 + bandW),
       Band(name: "theirs", x0: rightX0, x1: rightX0 + bandW)]
    : [Band(name: "theirs", x0: leftX0, x1: leftX0 + bandW),
       Band(name: "mine", x0: rightX0, x1: rightX0 + bandW)]

// MARK: - per-board state

final class BoardState {
    let band: Band
    let gw: Int, gh: Int
    var plate: [Double]          // rgb triples
    var prev: [Double]
    var hasPrev = false
    /// Rolling window: per cell, the occupancy flags and flicker values still
    /// inside it. Stored as parallel ring buffers keyed by sample index.
    var occRing: [[Bool]] = []
    var flickRing: [[Double]] = []
    var ringT: [Double] = []
    var sites: [Site] = []
    var nextID = 1

    struct Site {
        let id: Int
        var cx: Int, cy: Int, x0: Int, y0: Int, x1: Int, y1: Int
        var area: Int
        var firstSeen: Double
        var misses: Int
    }

    init(band: Band, plateBuf: [UInt8]) {
        self.band = band
        gw = (band.x1 - band.x0) / step
        gh = (boardY1 - boardY0) / step
        plate = [Double](repeating: 0, count: gw * gh * 3)
        prev = [Double](repeating: 0, count: gw * gh * 3)
        for gy in 0..<gh {
            for gx in 0..<gw {
                let x = band.x0 + gx * step, y = boardY0 + gy * step
                let i = (y * W + x) * 4, j = (gy * gw + gx) * 3
                plate[j] = Double(plateBuf[i])
                plate[j+1] = Double(plateBuf[i+1])
                plate[j+2] = Double(plateBuf[i+2])
            }
        }
    }

    /// True when this cell sits under the centre chrome column and must be
    /// thrown away — the buttons and send queue overhang both boards by ~6px.
    func masked(_ gx: Int) -> Bool {
        let x = band.x0 + gx * step
        return x >= chromeX0 && x < chromeX1
    }

    func observe(_ buf: [UInt8], t: Double) {
        var occ = [Bool](repeating: false, count: gw * gh)
        var flick = [Double](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            let y = boardY0 + gy * step
            for gx in 0..<gw {
                let idx = gy * gw + gx
                let x = band.x0 + gx * step
                let i = (y * W + x) * 4, j = idx * 3
                let r = Double(buf[i]), g = Double(buf[i+1]), b = Double(buf[i+2])
                occ[idx] = abs(r - plate[j]) + abs(g - plate[j+1]) + abs(b - plate[j+2]) > occThresh
                if hasPrev {
                    flick[idx] = abs(r - prev[j]) + abs(g - prev[j+1]) + abs(b - prev[j+2])
                }
                prev[j] = r; prev[j+1] = g; prev[j+2] = b
            }
        }
        hasPrev = true
        occRing.append(occ); flickRing.append(flick); ringT.append(t)
        while let f = ringT.first, t - f > windowSec {
            occRing.removeFirst(); flickRing.removeFirst(); ringT.removeFirst()
        }
    }

    /// Cells that were occupied for enough of the window and stayed still.
    func towerMask() -> [Bool] {
        let n = gw * gh
        var out = [Bool](repeating: false, count: n)
        guard ringT.count >= 2 else { return out }
        let samples = Double(occRing.count)
        for idx in 0..<n {
            var hits = 0
            var fsum = 0.0
            for k in 0..<occRing.count {
                if occRing[k][idx] { hits += 1 }
                fsum += flickRing[k][idx]
            }
            guard Double(hits) / samples >= occFrac else { continue }
            guard fsum / samples < flickerMax else { continue }
            let gx = idx % gw, gy = idx / gw
            if masked(gx) { continue }
            // Trim the border rows and columns; see `insetCells`.
            if gx < insetCells || gx >= gw - insetCells { continue }
            if gy < insetCells || gy >= gh - insetCells { continue }
            out[idx] = true
        }
        return out
    }

    func blobs(_ mask: [Bool]) -> [[Int]] {
        var seen = [Bool](repeating: false, count: mask.count)
        var out: [[Int]] = []
        for start in 0..<mask.count where mask[start] && !seen[start] {
            var blob: [Int] = [], stack = [start]
            seen[start] = true
            while let c = stack.popLast() {
                blob.append(c)
                let cx = c % gw, cy = c / gw
                for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, nx < gw, ny >= 0, ny < gh else { continue }
                        let n = ny * gw + nx
                        if mask[n] && !seen[n] { seen[n] = true; stack.append(n) }
                    }
                }
            }
            out.append(blob)
        }
        return out
    }

    /// Split one component at distance-transform peaks.
    ///
    /// Two towers placed next to each other overlap on screen, so erosion does
    /// not separate them and a bounding-box rule cannot say where to cut. The
    /// distance transform does: each sprite has a thick middle, so its centre is
    /// a local maximum of distance-to-background, and the seam between two
    /// sprites is a minimum. Peaks that survive non-maximum suppression become
    /// seeds and every cell goes to its nearest seed.
    ///
    /// Returns the blob unchanged when it finds one peak, so a lone tower is
    /// never fragmented.
    func splitBlob(_ blob: [Int]) -> [[Int]] {
        guard blob.count >= splitMinCells else { return [blob] }
        let member = Set(blob)

        // Distance to the nearest non-member, in cells (BFS from the boundary).
        var dist = [Int: Int]()
        var queue: [Int] = []
        for c in blob {
            let cx = c % gw, cy = c / gw
            var edge = false
            for (dx, dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                let nx = cx + dx, ny = cy + dy
                if nx < 0 || nx >= gw || ny < 0 || ny >= gh || !member.contains(ny * gw + nx) {
                    edge = true; break
                }
            }
            if edge { dist[c] = 1; queue.append(c) }
        }
        var head = 0
        while head < queue.count {
            let c = queue[head]; head += 1
            let cx = c % gw, cy = c / gw
            for (dx, dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                let nx = cx + dx, ny = cy + dy
                guard nx >= 0, nx < gw, ny >= 0, ny < gh else { continue }
                let n = ny * gw + nx
                guard member.contains(n), dist[n] == nil else { continue }
                dist[n] = dist[c]! + 1
                queue.append(n)
            }
        }

        // Candidate seeds, deepest first, with non-maximum suppression so one
        // sprite's plateau cannot contribute two seeds.
        let ranked = blob.filter { (dist[$0] ?? 0) >= splitMinDepth }
                         .sorted { (dist[$0] ?? 0) > (dist[$1] ?? 0) }
        var seeds: [Int] = []
        for c in ranked {
            let cx = c % gw, cy = c / gw
            var tooClose = false
            for s in seeds {
                let sx = s % gw, sy = s / gw
                let d = ((Double(cx - sx) * Double(cx - sx))
                         + Double(cy - sy) * Double(cy - sy)).squareRoot()
                if d < splitPeakSep { tooClose = true; break }
            }
            if !tooClose { seeds.append(c) }
        }
        guard seeds.count > 1 else { return [blob] }

        var parts = [[Int]](repeating: [], count: seeds.count)
        for c in blob {
            let cx = c % gw, cy = c / gw
            var best = 0, bestD = Double.greatestFiniteMagnitude
            for (i, s) in seeds.enumerated() {
                let sx = s % gw, sy = s / gw
                let d = (Double(cx - sx) * Double(cx - sx)) + Double(cy - sy) * Double(cy - sy)
                if d < bestD { bestD = d; best = i }
            }
            parts[best].append(c)
        }
        // A split that produces a scrap is a bad split; keep only parts that
        // could stand alone as sites.
        let kept = parts.filter { $0.count >= minCells }
        return kept.count > 1 ? kept : [blob]
    }

    /// Reconcile this frame's blobs with the standing census. Sites keep their
    /// id across frames so a scorer can ask when a detection ARRIVED, which is
    /// the question recall against a timed purchase actually poses.
    func census(at t: Double) {
        let raw = blobs(towerMask()).filter { blob in
            guard blob.count >= minCells, blob.count <= maxCells else { return false }
            let xs = blob.map { $0 % gw }, ys = blob.map { $0 / gw }
            let w = xs.max()! - xs.min()! + 1, h = ys.max()! - ys.min()! + 1
            return Double(max(w, h)) / Double(max(1, min(w, h))) <= maxAspect
        }
        // Adjacent towers are drawn overlapping, so they arrive as ONE component
        // and the census books one tower where there are two. Splitting happens
        // after the gates rather than before, because the gates are stated in
        // terms of whole sprites.
        let found = raw.flatMap { splitBlob($0) }
        var matched = Set<Int>()
        var updated: [Site] = []

        for blob in found {
            let xs = blob.map { $0 % gw }, ys = blob.map { $0 / gw }
            let cx = band.x0 + ((xs.reduce(0, +) / blob.count) * step)
            let cy = boardY0 + ((ys.reduce(0, +) / blob.count) * step)
            let x0 = band.x0 + xs.min()! * step, x1 = band.x0 + (xs.max()! + 1) * step
            let y0 = boardY0 + ys.min()! * step, y1 = boardY0 + (ys.max()! + 1) * step

            // Nearest standing site within half a footprint is the same tower.
            var best: Int? = nil, bestD = Double.greatestFiniteMagnitude
            for (i, s) in sites.enumerated() where !matched.contains(i) {
                let d = ((Double(s.cx - cx)) * Double(s.cx - cx)
                         + Double(s.cy - cy) * Double(s.cy - cy)).squareRoot()
                if d < bestD && d < 75 { best = i; bestD = d }
            }
            if let i = best {
                matched.insert(i)
                var s = sites[i]
                s.cx = cx; s.cy = cy; s.x0 = x0; s.y0 = y0; s.x1 = x1; s.y1 = y1
                s.area = blob.count; s.misses = 0
                updated.append(s)
            } else {
                updated.append(Site(id: nextID, cx: cx, cy: cy, x0: x0, y0: y0,
                                    x1: x1, y1: y1, area: blob.count,
                                    firstSeen: t, misses: 0))
                nextID += 1
            }
        }
        // Sites the mask lost this cycle survive a couple of cycles; a bloon
        // crossing a tower breaks its occupancy for one window.
        for (i, var s) in sites.enumerated() where !matched.contains(i) {
            s.misses += 1
            if s.misses <= 2 { updated.append(s) }
        }
        sites = updated
    }
}

// MARK: - run

let plateFrame = plateT < 0 ? frames[0] : frames.min { abs($0.t - plateT) < abs($1.t - plateT) }!
guard let plateBuf = load(plateFrame.file) else { print("cannot load plate"); exit(1) }
FileHandle.standardError.write(
    "plate: \(plateFrame.file) at t=\(String(format: "%.1f", plateFrame.t))\n".data(using: .utf8)!)

let boards = bands.map { BoardState(band: $0, plateBuf: plateBuf) }
FileManager.default.createFile(atPath: outPath, contents: nil)
guard let out = FileHandle(forWritingAtPath: outPath) else { print("cannot write \(outPath)"); exit(1) }
let enc = JSONEncoder()
enc.outputFormatting = [.sortedKeys]

struct OutSite: Codable {
    let id: Int, cx: Int, cy: Int, x0: Int, y0: Int, x1: Int, y1: Int
    let area: Int, cost: Int, priced: Bool, firstSeen: Double
}
struct OutRec: Codable {
    let file: String, t: Double
    let round: Int?, side: String?
    let theirs: [OutSite], mine: [OutSite]
}

var lastCensus = -Double.greatestFiniteMagnitude
var written = 0
for f in frames {
    guard let buf = load(f.file) else { continue }
    for b in boards { b.observe(buf, t: f.t) }
    guard f.t - lastCensus >= censusPeriod else { continue }
    lastCensus = f.t
    for b in boards { b.census(at: f.t) }

    func emit(_ b: BoardState) -> [OutSite] {
        b.sites.filter { f.t - $0.firstSeen >= minAgeSec }.map { OutSite(id: $0.id, cx: $0.cx, cy: $0.cy, x0: $0.x0, y0: $0.y0,
                              x1: $0.x1, y1: $0.y1, area: $0.area, cost: 0,
                              priced: false, firstSeen: $0.firstSeen) }
    }
    let theirs = boards.first { $0.band.name == "theirs" }!
    let mine = boards.first { $0.band.name == "mine" }!
    let rec = OutRec(file: f.file, t: f.t, round: nil, side: mySide,
                     theirs: emit(theirs), mine: emit(mine))
    if var d = try? enc.encode(rec) { d.append(0x0A); out.write(d); written += 1 }
}
out.closeFile()
FileHandle.standardError.write("wrote \(written) census records to \(outPath)\n".data(using: .utf8)!)
