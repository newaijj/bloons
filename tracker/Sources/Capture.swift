// Window-targeted capture of the Battles 2 window.
//
// Uses a persistent SCStream rather than repeated one-shot screenshots: the
// tracker runs for a whole match, and a stream amortises the setup cost that
// SCScreenshotManager pays on every call.
//
// Targeting the window (not the display) means the capture follows the window
// when it moves, excludes the overlay we draw on top of it, and never picks up
// anything else on the desktop.

import Foundation
import ScreenCaptureKit
import CoreImage
import CoreVideo

let GAME_BUNDLE_ID = "com.ninjakiwi.bloonstdbattles2"

/// A single captured frame. Only valid inside the callback that received it —
/// the underlying buffer is recycled once the callback returns.
final class Frame {
    let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
    /// Seconds since the first frame of this session, on the clock the frame was
    /// PRODUCED against rather than the one it is being processed on.
    ///
    /// This is what makes recorded sessions replayable. Anything downstream that
    /// asks `Date()` how much time has passed is measuring how fast frames are
    /// being pushed through it, which live is the capture rate and on replay is
    /// however fast PNGs decode — so a census on a 2s period and a build needing
    /// a 3s settle window could never fire off recorded frames, and `--replay`
    /// reported zero builds by construction. Reading time off the frame instead
    /// makes replay reproduce the live dynamics exactly.
    let time: Double
    private let base: UnsafeMutablePointer<UInt8>?
    private let bytesPerRow: Int

    init?(_ pb: CVPixelBuffer, time: Double) {
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        self.pixelBuffer = pb
        self.time = time
        self.width = CVPixelBufferGetWidth(pb)
        self.height = CVPixelBufferGetHeight(pb)
        self.bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        self.base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self)
        if base == nil {
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            return nil
        }
    }

    deinit { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    /// BGRA pixel as HSB. Out-of-bounds reads return nil rather than trapping.
    func hsb(x: Int, y: Int) -> HSB? {
        guard let base, x >= 0, y >= 0, x < width, y < height else { return nil }
        let p = base + y * bytesPerRow + x * 4
        return HSB(r: Double(p[2]) / 255.0, g: Double(p[1]) / 255.0, b: Double(p[0]) / 255.0)
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Full-frame CGImage. Costs a conversion, so only call it on OCR ticks.
    func makeCGImage() -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return Frame.ciContext.createCGImage(ci, from: ci.extent)
    }
}

/// Wraps a still image as a capture frame, so recorded PNGs can be pushed
/// through the exact same pipeline the live stream feeds.
func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                              kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
          let buffer = pb else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                              width: image.width, height: image.height,
                              bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buffer
}

final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "btdb2.capture", qos: .userInitiated)
    private var onFrame: ((Frame) -> Void)?

    /// Presentation timestamp of the first frame, so `Frame.time` counts from
    /// zero at the start of the session. Taken from the sample buffer rather
    /// than the wall clock because that is the clock the capture is actually
    /// paced on — a frame delayed in the queue still reports when it was taken.
    private var firstPTS: Double?

    static func findWindow() async -> SCWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return nil }
        return content.windows
            .filter { $0.owningApplication?.bundleIdentifier == GAME_BUNDLE_ID && $0.frame.width > 200 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    func start(window: SCWindow, fps: Int, scale: CGFloat, onFrame: @escaping (Frame) -> Void) async throws {
        self.onFrame = onFrame
        self.firstPTS = nil

        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 3

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        self.stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let pb = CMSampleBufferGetImageBuffer(sb)
        else { return }

        // An invalid CMTime yields NaN, which would poison every window and
        // period computed from it downstream, so fall back to the wall clock.
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        let stamp = pts.isFinite ? pts : Date().timeIntervalSinceReferenceDate
        if firstPTS == nil { firstPTS = stamp }

        guard let frame = Frame(pb, time: stamp - (firstPTS ?? stamp)) else { return }
        onFrame?(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("capture stopped: \(error)\n".data(using: .utf8)!)
    }
}
