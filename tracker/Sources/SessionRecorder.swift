// Records a session to disk as a replayable corpus.
//
// This is a different job from FrameDump, which exists to preserve evidence
// when a run does something suspicious: it arms on an anomaly, writes a short
// burst, and stops. What tuning detection needs is frames covering the moments
// a tower actually arrives, carrying enough metadata that pushing them back
// through the pipeline reproduces the live dynamics rather than approximating
// them.
//
// Recording is EVENT-WINDOWED, not continuous. A continuous 4fps capture of a
// four-minute match is ~850 frames and 2.4GB, of which the handful of seconds
// around each placement is the only part that exercises the census — the rest
// is a static board being photographed 800 times. Windowing cuts that by
// roughly an order of magnitude, which is the difference between a session you
// can leave running and one you have to babysit for disk.
//
// The awkward part is that the trigger arrives LATE. Whatever drives the game
// can only write its label after the click has gone through, and a tool
// round-trip is many seconds; by the time the label lands, the placement is
// already history. So frames are held in a ring buffer and the trigger flushes
// backwards in time. `preSeconds` has to comfortably exceed the driver's
// latency or the very frames the corpus exists for are the ones already
// discarded.
//
// Quiet windows are kept too, on a slow schedule. A corpus of nothing but
// placements can measure recall and says nothing at all about false positives,
// and false positives are the failure mode that actually corrupts the books.
//
// The format is PNG, and that was measured rather than assumed. JPEG is ~5x
// smaller at quality 60 and its effect on the descriptor looked harmless at
// first glance — median distance 0.03 against a within-tower noise floor of
// 0.224. But `looksLikeSprite` is a hard threshold on edgeDensity, which is a
// 2px local gradient, and that is precisely what JPEG smooths: the gate flipped
// on 9-19% of boxes across three frames, even at quality 80. Tuning thresholds
// against a corpus that reads sprites differently from the live stream would
// produce numbers that do not transfer.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Written beside the frames, and read back by `--replay`.
struct SessionManifest: Codable {
    struct Entry: Codable {
        let file: String
        /// Seconds since session start, on the capture clock.
        let t: Double
        /// Why this frame was kept: `pre`, `post`, `quiet`, or `all`. Lets a
        /// scorer tell a frame near a labelled placement from one deliberately
        /// sampled while nothing was happening, without re-deriving it from the
        /// labels.
        ///
        /// Optional, not defaulted: Swift's synthesized decoder ignores default
        /// values and throws on a missing key, so declaring this with `= "all"`
        /// silently made every manifest written before it existed undecodable.
        /// A corpus outlives the code that reads it; new fields have to be
        /// additive.
        var why: String?
    }
    var session: String
    /// Wall-clock instant of the first recorded frame, ISO8601 with fractional
    /// seconds.
    ///
    /// Frame times are relative to the first frame's presentation timestamp,
    /// which makes them self-consistent but unanchored — and anything labelling
    /// this session from OUTSIDE the process (a placement driver noting what it
    /// clicked and when) only has the wall clock to go on. Without this field
    /// there is no conversion between the two, and external ground truth cannot
    /// be aligned to frames at all.
    var startedAt: String
    /// Rate the frames were recorded at.
    var fps: Int
    var frameWidth: Int
    var frameHeight: Int
    /// Layout the recording was made under, so replay need not re-derive it.
    var side: String?
    var topBarMirrors: Bool
    var note: String
    /// Gaps are expected in a windowed recording; say so in the manifest rather
    /// than letting a reader infer a stall. Optional for the same
    /// backwards-compatibility reason as `Entry.why`.
    var windowed: Bool?
    var frames: [Entry]
}

final class SessionRecorder {
    /// How much to keep either side of a trigger, and how often to sample a
    /// stretch of nothing happening.
    struct Policy {
        /// How far back the ring reaches. This is latency tolerance, NOT how
        /// much gets kept — it only has to exceed the driver's round-trip so
        /// the placement is still in memory when its label finally lands.
        var pre = 30.0
        /// How much before the CLICK to actually commit, measured from the
        /// label's own `t_before`. Conflating this with the ring length is why
        /// a first cut kept ~50s per placement and saved almost nothing on a
        /// four-minute match: the ring has to be long, the keep does not.
        var margin = 5.0
        var post = 15.0
        var quietEvery = 90.0
        var quietFor = 4.0
        /// Keep everything and ignore triggers entirely.
        var all = false
    }

    private let dir: URL
    private let fps: Int
    private let maxFrames: Int
    private let interval: Double
    private let policy: Policy
    /// Growth of this file is the trigger. Using the label file itself means the
    /// act of recording ground truth IS the signal — there is no second step for
    /// a driver to forget.
    private let triggerPath: URL

    private let io = DispatchQueue(label: "tracker.recorder", qos: .utility)
    /// Bounds how far PNG encoding may fall behind capture. Frames that cannot
    /// be queued are dropped and counted, never silently skipped.
    private let inFlight = DispatchSemaphore(value: 8)

    private let lock = NSLock()
    private var entries: [SessionManifest.Entry] = []
    private var nextAt = 0.0
    private var started = false
    private var startedAt: Date?
    private(set) var dropped = 0

    /// Encoded frames not yet committed to disk, newest last. Held as PNG data
    /// rather than pixel buffers: the encode has to happen anyway, and holding
    /// 30s of 2560x1588 BGRA would be several gigabytes of resident memory
    /// against roughly 350MB encoded.
    private var ring: [(t: Double, data: Data)] = []
    /// Frames are written straight through until this time.
    private var keepUntil = -Double.greatestFiniteMagnitude
    private var quietUntil = -Double.greatestFiniteMagnitude
    private var nextQuietAt = 0.0
    private var lastTriggerSize = -1
    private var triggers = 0

    var location: String { dir.path }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    init?(baseDir: URL, session: String, fps: Int, maxFrames: Int, policy: Policy) {
        self.dir = baseDir.appendingPathComponent(session, isDirectory: true)
        self.fps = max(1, fps)
        self.maxFrames = maxFrames
        self.interval = 1.0 / Double(max(1, fps))
        self.policy = policy
        self.triggerPath = dir.appendingPathComponent("truth.jsonl")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("recorder: could not create \(dir.path): \(error)")
            return nil
        }
    }

    /// Offer a frame. Returns true if it was taken, so the caller can avoid the
    /// CGImage conversion when it would only be thrown away.
    func due(at time: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard entries.count + dropped < maxFrames else { return false }
        if !started { return true }
        return time >= nextAt
    }

    func record(_ cg: CGImage, at time: Double) {
        lock.lock()
        guard entries.count + dropped < maxFrames else { lock.unlock(); return }
        if !started {
            started = true; nextAt = time; startedAt = Date()
            nextQuietAt = time
        }
        guard time >= nextAt else { lock.unlock(); return }
        nextAt = time + interval
        lock.unlock()

        guard inFlight.wait(timeout: .now()) == .success else {
            lock.lock(); dropped += 1; lock.unlock()
            return
        }

        io.async { [self] in
            defer { inFlight.signal() }
            guard let data = encode(cg) else {
                lock.lock(); dropped += 1; lock.unlock()
                return
            }
            file(data, at: time)
        }
    }

    private func encode(_ cg: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Decide whether this frame goes to disk now, waits in the ring, or is
    /// dropped. Runs on the io queue, one frame at a time.
    private func file(_ data: Data, at time: Double) {
        if policy.all {
            write(data, at: time, why: "all")
            return
        }

        // A label was written since the last check: commit the part of the ring
        // around the click, which is where the placement itself is sitting.
        if triggerFired() {
            // The label says when the click went in. Keep from a little before
            // that and drop the rest of the ring, rather than committing every
            // second the driver happened to spend getting back to us.
            let from = (labelClickTime() ?? time).advanced(by: -policy.margin)
            lock.lock()
            let flush = ring.filter { $0.t >= from }
            ring.removeAll()
            keepUntil = max(keepUntil, time + policy.post)
            triggers += 1
            lock.unlock()
            for f in flush { write(f.data, at: f.t, why: "pre") }
        }

        lock.lock()
        let inPost = time <= keepUntil
        if time >= nextQuietAt {
            quietUntil = time + policy.quietFor
            nextQuietAt = time + policy.quietEvery
        }
        let inQuiet = time <= quietUntil
        lock.unlock()

        if inPost { write(data, at: time, why: "post"); return }
        if inQuiet { write(data, at: time, why: "quiet"); return }

        lock.lock()
        ring.append((time, data))
        // Trim to the pre-roll. This is the only place frames are discarded by
        // policy rather than by failure, so it is not counted as a drop.
        while let first = ring.first, time - first.t > policy.pre { ring.removeFirst() }
        lock.unlock()
    }

    /// Has the label file grown since we last looked? A size comparison is
    /// enough — labels are only ever appended — and costs one stat per frame.
    private func triggerFired() -> Bool {
        let size = (try? FileManager.default.attributesOfItem(
            atPath: triggerPath.path)[.size] as? Int) ?? nil ?? 0
        defer { lastTriggerSize = size }
        // First observation establishes a baseline instead of firing: a session
        // resumed over an existing label file would otherwise trigger at once.
        guard lastTriggerSize >= 0 else { return false }
        return size > lastTriggerSize
    }

    /// Frame time of the click described by the most recent label, from its
    /// `t_before` stamp. Returns nil for labels that mark no click (a map name,
    /// a note) and for anything unparseable, in which case the caller falls back
    /// to the trigger instant.
    private func labelClickTime() -> Double? {
        guard let started = startedAt,
              let text = try? String(contentsOf: triggerPath, encoding: .utf8) else { return nil }
        guard let last = text.split(separator: "\n").last,
              let data = last.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = obj["t_before"] as? String else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let when = iso.date(from: stamp) else { return nil }
        return when.timeIntervalSince(started)
    }

    private func write(_ data: Data, at time: Double, why: String) {
        // Named by millisecond so the filename sorts chronologically and stays
        // unique regardless of what order encodes finish in.
        let name = String(format: "f%09d.png", Int((time * 1000).rounded()))
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            lock.lock()
            entries.append(SessionManifest.Entry(file: name, t: time, why: why))
            lock.unlock()
        } catch {
            lock.lock(); dropped += 1; lock.unlock()
        }
    }

    /// Flush pending encodes and write the manifest. Safe to call more than once
    /// so a session that ends by signal and one that ends normally both land a
    /// readable manifest.
    func finish(side: String?, topBarMirrors: Bool, note: String) {
        // A trailing trigger may still have its window open, and the ring holds
        // the frames before it. Commit them rather than losing the last
        // placement of every session.
        io.sync {
            if !policy.all && triggerFired() {
                lock.lock(); let flush = ring; ring.removeAll(); triggers += 1; lock.unlock()
                for f in flush { write(f.data, at: f.t, why: "pre") }
            }
        }

        lock.lock()
        let sorted = entries.sorted { $0.t < $1.t }
        let d = dropped, tr = triggers, ringLeft = ring.count
        lock.unlock()

        guard let first = sorted.first else {
            print("recorder: no frames written to \(dir.path)")
            return
        }
        var w = 0, h = 0
        if let src = CGImageSourceCreateWithURL(
                dir.appendingPathComponent(first.file) as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            w = img.width; h = img.height
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let m = SessionManifest(
            session: dir.lastPathComponent,
            startedAt: iso.string(from: startedAt ?? Date()), fps: fps,
            frameWidth: w, frameHeight: h,
            side: side, topBarMirrors: topBarMirrors,
            note: note, windowed: !policy.all, frames: sorted)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(m) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        }

        var byWhy: [String: Int] = [:]
        for e in sorted { byWhy[e.why ?? "all", default: 0] += 1 }
        let breakdown = byWhy.sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        let span = (sorted.last?.t ?? 0) - first.t
        print("""

        recorded \(sorted.count) frames over \(String(format: "%.1fs", span)) → \(dir.path)
          kept: \(breakdown)\(policy.all ? "" : "  (\(tr) triggers, \(ringLeft) still in ring)")
          \(d > 0 ? "\(d) frames dropped (encoder behind capture)" : "no frames dropped")
          started \(iso.string(from: startedAt ?? Date()))
          replay with: --replay \(dir.path)
        """)
    }
}
