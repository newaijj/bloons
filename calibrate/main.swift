// btdb2 calibration capturer
//
// Grabs frames of the Bloons TD Battles 2 window and dumps, for each frame:
//   - a PNG of the window (physical pixels)
//   - every piece of text Vision can find, with top-left pixel bounding boxes
//
// The point is to learn exactly which numbers the HUD exposes and where they sit,
// so the real tracker can read fixed regions instead of OCRing whole frames.
//
// Usage:
//   ./calibrate --list                      list capturable windows
//   ./calibrate                             one frame
//   ./calibrate --frames 20 --interval 3    burst during a live match

import Foundation
import ScreenCaptureKit
import Vision
import AppKit
import CoreImage
import UniformTypeIdentifiers

let BUNDLE_ID = "com.ninjakiwi.bloonstdbattles2"

struct Args {
    var list = false
    var frames = 1
    var interval = 3.0
    var outDir = "out"
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--list": a.list = true
        case "--frames": a.frames = Int(it.next() ?? "1") ?? 1
        case "--interval": a.interval = Double(it.next() ?? "3") ?? 3.0
        case "--out": a.outDir = it.next() ?? "out"
        default: FileHandle.standardError.write("unknown arg: \(arg)\n".data(using: .utf8)!)
        }
    }
    return a
}

struct TextHit {
    let text: String
    let confidence: Float
    let rect: CGRect  // top-left origin, pixel coords
}

func ocr(_ image: CGImage) -> [TextHit] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    req.recognitionLanguages = ["en-US"]

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([req]) } catch {
        FileHandle.standardError.write("OCR failed: \(error)\n".data(using: .utf8)!)
        return []
    }

    let w = CGFloat(image.width), h = CGFloat(image.height)
    var hits: [TextHit] = []
    for obs in (req.results ?? []) {
        guard let cand = obs.topCandidates(1).first else { continue }
        // Vision is normalized with a bottom-left origin; flip to top-left pixels.
        let b = obs.boundingBox
        let rect = CGRect(x: b.minX * w,
                          y: (1 - b.maxY) * h,
                          width: b.width * w,
                          height: b.height * h)
        hits.append(TextHit(text: cand.string, confidence: cand.confidence, rect: rect))
    }
    // Reading order: top to bottom, then left to right.
    return hits.sorted {
        abs($0.rect.minY - $1.rect.minY) > 8 ? $0.rect.minY < $1.rect.minY
                                             : $0.rect.minX < $1.rect.minX
    }
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("could not create PNG destination\n".data(using: .utf8)!)
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func findGameWindow(_ content: SCShareableContent) -> SCWindow? {
    let candidates = content.windows.filter {
        $0.owningApplication?.bundleIdentifier == BUNDLE_ID && $0.frame.width > 200 && $0.frame.height > 200
    }
    // Largest window wins — avoids picking up tooltips or helper windows.
    return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
}

let args = parseArgs()
let sem = DispatchSemaphore(value: 0)

Task {
    defer { sem.signal() }

    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
        print("""
        ERROR: could not enumerate windows — \(error)

        This is almost always the Screen Recording permission. Open
          System Settings > Privacy & Security > Screen & System Audio Recording
        enable the app running this (Claude), then quit and reopen it.
        """)
        return
    }

    if args.list {
        print("Capturable windows:")
        for w in content.windows where (w.frame.width > 100 && w.frame.height > 100) {
            let app = w.owningApplication?.applicationName ?? "?"
            let bid = w.owningApplication?.bundleIdentifier ?? "?"
            print(String(format: "  %-28s %-42s %@  %.0fx%.0f at (%.0f,%.0f)",
                         (app as NSString).utf8String!, (bid as NSString).utf8String!,
                         w.title ?? "", w.frame.width, w.frame.height, w.frame.minX, w.frame.minY))
        }
        return
    }

    guard let win = findGameWindow(content) else {
        print("""
        Bloons TD Battles 2 window not found.

        Launch it first:  open steam://run/1276390
        Then re-run. Use --list to see what is capturable.
        """)
        return
    }

    let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    let pxW = Int(win.frame.width * scale), pxH = Int(win.frame.height * scale)

    print("Window: \(win.title ?? "(untitled)")")
    print("Frame:  \(Int(win.frame.width))x\(Int(win.frame.height)) pts at (\(Int(win.frame.minX)),\(Int(win.frame.minY)))")
    print("Capture: \(pxW)x\(pxH) px (backing scale \(scale))")
    print("")

    let filter = SCContentFilter(desktopIndependentWindow: win)
    let config = SCStreamConfiguration()
    config.width = pxW
    config.height = pxH
    config.showsCursor = false
    config.capturesAudio = false
    config.pixelFormat = kCVPixelFormatType_32BGRA

    let outDir = URL(fileURLWithPath: args.outDir, isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
    let session = stamp.string(from: Date()).replacingOccurrences(of: ":", with: "")

    for i in 0..<args.frames {
        if i > 0 { try? await Task.sleep(nanoseconds: UInt64(args.interval * 1_000_000_000)) }

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            print("frame \(i): capture failed — \(error)")
            continue
        }

        let base = String(format: "%@_f%03d", session, i)
        let png = outDir.appendingPathComponent("\(base).png")
        writePNG(image, to: png)

        let hits = ocr(image)
        var report = "# frame \(i)  t=\(Date())  \(image.width)x\(image.height)px\n"
        report += "# x,y,w,h are top-left origin pixels\n"
        for h in hits {
            report += String(format: "%5.0f %5.0f %5.0f %5.0f  %.2f  %@\n",
                             h.rect.minX, h.rect.minY, h.rect.width, h.rect.height,
                             h.confidence, h.text)
        }
        try? report.write(to: outDir.appendingPathComponent("\(base).txt"), atomically: true, encoding: .utf8)

        print("frame \(i): \(hits.count) text hits -> \(base).png / .txt")
    }

    print("\nDone. Output in \(outDir.path)")
}

sem.wait()
