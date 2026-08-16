// btdb2 region probe
//
// Second calibration pass. Two jobs:
//   1. Verify the HUD region map — writes ONE annotated frame with every region
//      boxed and labelled, so a wrong box is obvious at a glance.
//   2. Log what each region reads, once per second, to a CSV — so the dynamics
//      (eco ticks, send queue draining, cost/eco values changing by round)
//      can be checked against what actually happened in the match.
//
// Regions are stored normalised to the captured frame, so they survive the
// window being moved or resized.
//
// Usage:
//   ./probe --frames 60 --interval 1

import Foundation
import ScreenCaptureKit
import Vision
import AppKit
import CoreText
import UniformTypeIdentifiers

let BUNDLE_ID = "com.ninjakiwi.bloonstdbattles2"

struct Region {
    let name: String
    let rect: CGRect      // normalised, top-left origin
    let multiline: Bool   // join several OCR hits instead of taking one
}

// Derived from the first calibration pass at 2560x1588.
let REGIONS: [Region] = [
    Region(name: "opp_name",   rect: CGRect(x: 0.0078, y: 0.0705, width: 0.1484, height: 0.0365), multiline: false),
    Region(name: "opp_lives",  rect: CGRect(x: 0.3086, y: 0.0705, width: 0.0547, height: 0.0365), multiline: false),
    Region(name: "my_cash",    rect: CGRect(x: 0.3848, y: 0.0705, width: 0.0684, height: 0.0365), multiline: false),
    Region(name: "my_eco",     rect: CGRect(x: 0.4707, y: 0.0705, width: 0.0645, height: 0.0365), multiline: false),
    Region(name: "round",      rect: CGRect(x: 0.5332, y: 0.0705, width: 0.0879, height: 0.0365), multiline: false),
    Region(name: "my_lives",   rect: CGRect(x: 0.6328, y: 0.0705, width: 0.0547, height: 0.0365), multiline: false),
    Region(name: "my_name",    rect: CGRect(x: 0.8594, y: 0.0705, width: 0.1289, height: 0.0365), multiline: false),
    Region(name: "queue_col",  rect: CGRect(x: 0.4785, y: 0.1795, width: 0.0449, height: 0.3715), multiline: true),
    Region(name: "send_menu",  rect: CGRect(x: 0.9277, y: 0.5038, width: 0.0742, height: 0.1826), multiline: true),
    Region(name: "eco_popup",  rect: CGRect(x: 0.9297, y: 0.4597, width: 0.0742, height: 0.0693), multiline: true),
]

struct Args {
    var frames = 60
    var interval = 1.0
    var outDir = "out"
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--frames":   a.frames = Int(it.next() ?? "60") ?? 60
        case "--interval": a.interval = Double(it.next() ?? "1") ?? 1.0
        case "--out":      a.outDir = it.next() ?? "out"
        default: FileHandle.standardError.write("unknown arg: \(arg)\n".data(using: .utf8)!)
        }
    }
    return a
}

func pixelRect(_ r: CGRect, _ w: Int, _ h: Int) -> CGRect {
    CGRect(x: r.minX * CGFloat(w), y: r.minY * CGFloat(h),
           width: r.width * CGFloat(w), height: r.height * CGFloat(h)).integral
}

func ocrRegion(_ image: CGImage, _ px: CGRect, multiline: Bool) -> String {
    guard let crop = image.cropping(to: px) else { return "" }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    req.recognitionLanguages = ["en-US"]

    let handler = VNImageRequestHandler(cgImage: crop, options: [:])
    guard (try? handler.perform([req])) != nil else { return "" }
    let results = req.results ?? []

    if multiline {
        // Preserve top-to-bottom order so a draining queue reads in sequence.
        let sorted = results.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        return sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "|")
    }
    return results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
}

func annotate(_ image: CGImage, regions: [Region]) -> CGImage? {
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setLineWidth(4)

    let font = CTFontCreateWithName("Menlo-Bold" as CFString, 26, nil)
    for (i, reg) in regions.enumerated() {
        let px = pixelRect(reg.rect, w, h)
        // CGContext origin is bottom-left; our rects are top-left.
        let flipped = CGRect(x: px.minX, y: CGFloat(h) - px.maxY, width: px.width, height: px.height)
        let hue = CGFloat(i) / CGFloat(regions.count)
        let color = NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor
        ctx.setStrokeColor(color)
        ctx.stroke(flipped)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.black.cgColor,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: reg.name, attributes: attrs))
        let bg = CGRect(x: flipped.minX, y: flipped.maxY, width: CGFloat(reg.name.count) * 16 + 10, height: 32)
        ctx.setFillColor(color)
        ctx.fill(bg)
        ctx.textPosition = CGPoint(x: flipped.minX + 5, y: flipped.maxY + 8)
        CTLineDraw(line, ctx)
    }
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let args = parseArgs()
let sem = DispatchSemaphore(value: 0)

Task {
    defer { sem.signal() }

    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
          let win = content.windows
            .filter({ $0.owningApplication?.bundleIdentifier == BUNDLE_ID && $0.frame.width > 200 })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    else {
        print("Battles 2 window not found. Launch it (open steam://run/1276390) and get into a match.")
        return
    }

    let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    let pxW = Int(win.frame.width * scale), pxH = Int(win.frame.height * scale)
    print("Capturing \(pxW)x\(pxH) — \(args.frames) frames at \(args.interval)s\n")

    let filter = SCContentFilter(desktopIndependentWindow: win)
    let config = SCStreamConfiguration()
    config.width = pxW
    config.height = pxH
    config.showsCursor = false
    config.pixelFormat = kCVPixelFormatType_32BGRA

    let outDir = URL(fileURLWithPath: args.outDir, isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    var csv = "frame,elapsed_s," + REGIONS.map(\.name).joined(separator: ",") + "\n"
    let t0 = Date()

    for i in 0..<args.frames {
        if i > 0 { try? await Task.sleep(nanoseconds: UInt64(args.interval * 1_000_000_000)) }
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            print("frame \(i): capture failed"); continue
        }

        if i == 0, let ann = annotate(image, regions: REGIONS) {
            writePNG(ann, to: outDir.appendingPathComponent("regions_annotated.png"))
            print("wrote regions_annotated.png — check every box lands on its target\n")
        }

        var row = ["\(i)", String(format: "%.1f", Date().timeIntervalSince(t0))]
        for reg in REGIONS {
            let text = ocrRegion(image, pixelRect(reg.rect, image.width, image.height), multiline: reg.multiline)
            row.append("\"\(text.replacingOccurrences(of: "\"", with: "'"))\"")
        }
        csv += row.joined(separator: ",") + "\n"

        if i % 10 == 0 { print("frame \(i)/\(args.frames)") }
    }

    try? csv.write(to: outDir.appendingPathComponent("probe.csv"), atomically: true, encoding: .utf8)
    print("\nDone -> \(outDir.path)/probe.csv")
}

sem.wait()
