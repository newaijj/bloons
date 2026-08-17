// Saves frames to disk when the run is one worth studying afterwards.
//
// The tracker normally persists nothing but a CSV: `Frame` wraps a buffer that
// ScreenCaptureKit recycles the moment the callback returns, so by the time you
// know a run was interesting there is nothing left to look at. That is fine for
// the ordinary case and useless for the one case that matters — a MIRRORED
// layout, which no capture on hand has ever shown.
//
// If the layout does flip, the region constants have to be re-measured against
// real pixels of the flipped board, and `side=left` in a CSV column does not
// give you a single pixel to measure. So: when the side latches left, when the
// top-bar probe comes back inconclusive, or when detection cannot decide at all,
// start writing frames.
//
// Frames land in out/<session>/ named to match the calibrate tool's convention,
// which means the directory can be fed straight back through `--replay` to
// develop against.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class FrameDump {
    enum Policy: String {
        /// Save only when something about the run warrants a second look.
        case auto
        /// Save from the first frame — for building a new calibration set.
        case always
        case off
    }

    private let policy: Policy
    private let maxFrames: Int
    private let baseDir: URL
    private let session: String
    /// PNG encoding a 2560x1588 frame is far too slow for the capture queue.
    private let io = DispatchQueue(label: "tracker.framedump", qos: .utility)

    private(set) var armed = false
    private(set) var written = 0
    private var dir: URL?
    private var burstRemaining = 0
    private var nextAt = Date.distantFuture
    private var capNoticed = false
    /// Frames allowed for this arming. Every latch leaves a short burst behind —
    /// a decision with no pixels behind it is exactly what made the last wrong
    /// call unstudyable — and an anomaly escalates that to the full budget.
    private var limit = 0
    private var periodic = true

    /// A short burst at the moment of interest, then an occasional frame so the
    /// later rounds of the match are represented too.
    private let burstCount = 6
    private let burstEvery: TimeInterval = 1.0
    private let periodicEvery: TimeInterval = 15.0

    init(policy: Policy, maxFrames: Int, baseDir: URL) {
        self.policy = policy
        self.maxFrames = maxFrames
        self.baseDir = baseDir
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        self.session = f.string(from: Date())
    }

    var armsImmediately: Bool { policy == .always }

    /// Begin saving. `note` is written alongside the frames so the dump explains
    /// itself months later without this conversation.
    func arm(reason: String, note: String, limit: Int? = nil, periodic: Bool = true) {
        guard policy != .off else { return }
        // Already running: escalate rather than ignore. A routine latch burst
        // must be able to grow into a full dump when something later goes wrong.
        guard !armed else {
            escalate(reason: reason, note: note, limit: limit, periodic: periodic)
            return
        }
        self.limit = min(maxFrames, limit ?? maxFrames)
        self.periodic = periodic
        let d = baseDir.appendingPathComponent(session, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        } catch {
            print("  frame dump: could not create \(d.path): \(error)")
            return
        }
        dir = d
        armed = true
        burstRemaining = burstCount
        nextAt = Date()

        let header = """
        # tracker frame dump
        # session \(session)
        # reason: \(reason)

        \(note)
        """
        try? header.write(to: d.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        print("  frame dump armed → \(d.path)  (\(reason))")
    }

    /// Widen an arming already in progress: raise the frame budget, re-open the
    /// periodic schedule, start a fresh burst, and append why.
    private func escalate(reason: String, note: String, limit: Int?, periodic: Bool) {
        let newLimit = min(maxFrames, limit ?? maxFrames)
        let grew = newLimit > self.limit || (periodic && !self.periodic)
        guard grew, let d = dir else { return }
        self.limit = max(self.limit, newLimit)
        self.periodic = self.periodic || periodic
        burstRemaining = burstCount
        nextAt = Date()
        capNoticed = false

        let addendum = "\n\n# escalated: \(reason)\n\n\(note)\n"
        if let fh = try? FileHandle(forWritingTo: d.appendingPathComponent("notes.txt")) {
            fh.seekToEndOfFile()
            fh.write(addendum.data(using: .utf8)!)
            try? fh.close()
        }
        print("  frame dump escalated to \(self.limit) frames  (\(reason))")
    }

    func shouldCapture(_ now: Date = Date()) -> Bool {
        guard armed, dir != nil else { return false }
        guard written < limit else {
            if !capNoticed {
                capNoticed = true
                print("  frame dump: reached \(limit) frames, stopping (--dump-max raises the ceiling)")
            }
            return false
        }
        return now >= nextAt
    }

    /// Hand off a detached CGImage. Safe across queues — makeCGImage() renders
    /// into a new backing store rather than aliasing the recycled buffer.
    func capture(_ cg: CGImage) {
        guard armed, let d = dir, written < limit else { return }
        let index = written
        written += 1

        let now = Date()
        if burstRemaining > 0 {
            burstRemaining -= 1
            nextAt = now.addingTimeInterval(burstEvery)
        } else if periodic {
            nextAt = now.addingTimeInterval(periodicEvery)
        } else {
            nextAt = .distantFuture
        }

        let url = d.appendingPathComponent(String(format: "%@_f%03d.png", session, index))
        io.async {
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
