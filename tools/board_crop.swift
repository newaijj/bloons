// Crop one board out of a frame with a coordinate grid drawn over it, so a
// human (or a model looking at the image) can read tower positions off in FRAME
// pixels — the coordinate system the census log and the scorer both use.
//
// Labelling the opponent's board is the only ground truth that exists for the
// side that actually matters. There is no cash trace for them and no driver
// that knows what they clicked, so the positions have to be read off the
// picture. Guessing coordinates from an unscaled screenshot is hopeless; a grid
// every 100px with a heavier line every 500 makes it mechanical.
//
//   swiftc -O tools/board_crop.swift -o /tmp/board_crop
//   /tmp/board_crop <frame.png> <side:left|right> <out.png>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: board_crop <frame.png> <left|right> <out.png>"); exit(2)
}
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("could not read \(args[1])"); exit(1)
}
let W = cg.width, H = cg.height

// Same measured band as Regions.swift: left board 0.0742–0.4844, right board its
// exact reflection.
let bandX0 = 0.0742, bandW = 0.4102
let x0 = args[2] == "left" ? Int(bandX0 * Double(W))
                           : Int((1 - bandX0 - bandW) * Double(W))
let x1 = x0 + Int(bandW * Double(W))
let y0 = Int(0.1102 * Double(H)), y1 = Int(0.9918 * Double(H))
let cw = x1 - x0, ch = y1 - y0

guard let crop = cg.cropping(to: CGRect(x: x0, y: y0, width: cw, height: ch)) else {
    print("crop failed"); exit(1)
}

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("context failed"); exit(1)
}
ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))

// Paint out the centre chrome the scanner masks, so what a labeller sees is what
// the detector sees. Both bands run to the divider and the button cluster
// overhangs each by ~6px; left in, those pixels read as a persistent off-path
// blob. Mirrors Regions.centreChrome — duplicated here for the same reason the
// band above is, since this tool is compiled on its own.
// Rounded OUTWARD, matching HUDRegion.pixels()'s `.integral`, so the strip drawn
// here is the exact strip the scanner drops rather than one a pixel narrower.
let chromeX0 = Int(floor(0.4813 * Double(W)))
let chromeX1 = Int(ceil((0.4813 + 0.0375) * Double(W)))
let mx0 = max(x0, chromeX0), mx1 = min(x1, chromeX1)
if mx1 > mx0 {
    ctx.setFillColor(red: 1, green: 0, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: mx0 - x0, y: 0, width: mx1 - mx0, height: ch))
}

// CGContext's origin is bottom-left; frame coordinates are top-left. Every line
// is placed by converting explicitly rather than by flipping the transform, so
// the arithmetic that produces the label and the arithmetic that produces the
// line cannot drift apart.
func deviceY(_ frameY: Int) -> Double { Double(ch) - Double(frameY - y0) }

ctx.setLineWidth(1)
for fx in stride(from: (x0 / 100) * 100, through: x1, by: 100) {
    guard fx >= x0 else { continue }
    let heavy = fx % 500 == 0
    ctx.setStrokeColor(red: heavy ? 1 : 0, green: heavy ? 0.2 : 1, blue: heavy ? 0.2 : 1,
                       alpha: heavy ? 0.95 : 0.45)
    ctx.setLineWidth(heavy ? 3 : 1)
    let dx = Double(fx - x0)
    ctx.move(to: CGPoint(x: dx, y: 0)); ctx.addLine(to: CGPoint(x: dx, y: Double(ch)))
    ctx.strokePath()
}
for fy in stride(from: (y0 / 100) * 100, through: y1, by: 100) {
    guard fy >= y0 else { continue }
    let heavy = fy % 500 == 0
    ctx.setStrokeColor(red: heavy ? 1 : 0, green: heavy ? 0.2 : 1, blue: heavy ? 0.2 : 1,
                       alpha: heavy ? 0.95 : 0.45)
    ctx.setLineWidth(heavy ? 3 : 1)
    let dy = deviceY(fy)
    ctx.move(to: CGPoint(x: 0, y: dy)); ctx.addLine(to: CGPoint(x: Double(cw), y: dy))
    ctx.strokePath()
}

guard let out = ctx.makeImage(),
      let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL,
                                                UTType.png.identifier as CFString, 1, nil) else {
    print("write failed"); exit(1)
}
CGImageDestinationAddImage(dst, out, nil)
CGImageDestinationFinalize(dst)
// Say what the grid means, so a coordinate read off the picture can be trusted.
print("\(args[3]): board x \(x0)..\(x1)  y \(y0)..\(y1)  (\(cw)x\(ch))")
if mx1 > mx0 { print("  centre chrome masked (magenta): frame x \(mx0)..\(mx1)") }
print("  heavy lines every 500 frame-px, light every 100; first heavy x=\((x0/500+1)*500) y=\((y0/500+1)*500)")
