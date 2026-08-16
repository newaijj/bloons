// Draw detector output and ground truth over one board, so a miss can be looked
// at instead of inferred from a distance in a table.
//
//   overlay <frame.png> <left|right> <out.png> [box:x0,y0,x1,y1 ...]
//                                              [hit:cx,cy ...] [miss:cx,cy ...]
//                                              [false:cx,cy ...]
//
// Coordinates are FRAME pixels, the same system the census log and the truth
// files use. Shapes are passed on the command line rather than parsed from JSON
// here, so this stays a renderer and the joining logic lives in one place.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: overlay <frame> <left|right> <out> [shapes...]"); exit(2) }
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("read failed"); exit(1) }
let W = cg.width, H = cg.height

let bandX0 = 0.0742, bandW = 0.4102
let x0 = args[2] == "left" ? Int(bandX0 * Double(W)) : Int((1 - bandX0 - bandW) * Double(W))
let x1 = x0 + Int(bandW * Double(W))
let y0 = Int(0.1102 * Double(H)), y1 = Int(0.9918 * Double(H))
let cw = x1 - x0, ch = y1 - y0

guard let crop = cg.cropping(to: CGRect(x: x0, y: y0, width: cw, height: ch)),
      let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { print("crop failed"); exit(1) }
ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))

// CGContext is bottom-left origin; frame coords are top-left.
func dy(_ frameY: Double) -> Double { Double(ch) - (frameY - Double(y0)) }
func dx(_ frameX: Double) -> Double { frameX - Double(x0) }

func nums(_ s: String) -> [Double] { s.split(separator: ",").compactMap { Double($0) } }

for arg in args.dropFirst(4) {
    let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    let v = nums(parts[1])
    switch parts[0] {
    case "box" where v.count == 4:
        // What the detector actually grouped as one tower.
        ctx.setStrokeColor(red: 0, green: 0.85, blue: 1, alpha: 1)
        ctx.setLineWidth(5)
        ctx.stroke(CGRect(x: dx(v[0]), y: dy(v[3]), width: v[2] - v[0], height: v[3] - v[1]))
    case "hit" where v.count == 2:
        ctx.setStrokeColor(red: 0.2, green: 1, blue: 0.2, alpha: 1)
        ctx.setLineWidth(6)
        ctx.strokeEllipse(in: CGRect(x: dx(v[0]) - 45, y: dy(v[1]) - 45, width: 90, height: 90))
    case "miss" where v.count == 2:
        // Red ring plus a cross, so a miss is unmistakable in greyscale too.
        ctx.setStrokeColor(red: 1, green: 0.1, blue: 0.1, alpha: 1)
        ctx.setLineWidth(8)
        ctx.strokeEllipse(in: CGRect(x: dx(v[0]) - 55, y: dy(v[1]) - 55, width: 110, height: 110))
        ctx.move(to: CGPoint(x: dx(v[0]) - 40, y: dy(v[1]) - 40))
        ctx.addLine(to: CGPoint(x: dx(v[0]) + 40, y: dy(v[1]) + 40))
        ctx.move(to: CGPoint(x: dx(v[0]) - 40, y: dy(v[1]) + 40))
        ctx.addLine(to: CGPoint(x: dx(v[0]) + 40, y: dy(v[1]) - 40))
        ctx.strokePath()
    case "false" where v.count == 2:
        ctx.setStrokeColor(red: 1, green: 0.9, blue: 0, alpha: 1)
        ctx.setLineWidth(6)
        ctx.strokeEllipse(in: CGRect(x: dx(v[0]) - 50, y: dy(v[1]) - 50, width: 100, height: 100))
    default: break
    }
}

guard let out = ctx.makeImage(),
      let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL,
                                                UTType.png.identifier as CFString, 1, nil)
else { print("write failed"); exit(1) }
CGImageDestinationAddImage(dst, out, nil)
CGImageDestinationFinalize(dst)
print("\(args[3]) — cyan box = one detected site, green = hit, red X = miss, yellow = false positive")
