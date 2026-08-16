// Bloon types, their screen colours, and their cash value when fully popped.
//
// The hues are what the classifier matches against at the track entrance. They
// were sampled from real capture frames, not guessed from the wiki art.
//
// `popValue` is red-bloon-equivalent, which BTD-family games pay out at roughly
// $1 per layer. It is an approximation and the single loosest number in the
// model — it feeds the opponent's pop income, not their eco, so errors here
// widen the cash band without touching the eco figure.

import Foundation
import AppKit

enum BloonType: String, CaseIterable, Codable {
    case red, blue, green, yellow, pink
    case black, white, purple, lead, zebra
    case rainbow, ceramic, moab

    /// Hue in degrees, and how far a sample may sit from it and still match.
    var hue: (center: Double, tolerance: Double)? {
        switch self {
        case .red:     return (2, 11)
        case .blue:    return (208, 15)
        case .green:   return (108, 17)
        case .yellow:  return (48, 10)
        case .pink:    return (330, 14)
        case .purple:  return (280, 17)
        // Achromatic, patterned, or — in ceramic's case — sitting right on top
        // of the sand/dirt track colour. Hue alone cannot separate these, and
        // trying produced thousands of phantom ceramics on a round-1 desert map.
        case .ceramic, .black, .white, .lead, .zebra, .rainbow, .moab: return nil
        }
    }

    /// Minimum saturation and brightness for a pixel to count as this bloon.
    var satBrightFloor: (sat: Double, bright: Double) {
        switch self {
        case .white:   return (0.00, 0.80)
        case .black:   return (0.00, 0.00)
        case .lead:    return (0.00, 0.30)
        // Green bloons render as a muted olive, well below the gloss floor the
        // other colours need. At 0.68 they were rejected and the card's blue
        // background won the vote instead.
        case .green:   return (0.42, 0.30)
        // Bloons are glossy and vivid; map scenery is muted. A high saturation
        // floor is the cheapest way to separate them.
        default:       return (0.68, 0.50)
        }
    }

    var popValue: Int {
        switch self {
        case .red: return 1
        case .blue: return 2
        case .green: return 3
        case .yellow: return 4
        case .pink: return 5
        case .black, .white, .purple: return 11
        case .lead, .zebra: return 23
        case .rainbow: return 47
        case .ceramic: return 104
        case .moab: return 616
        }
    }

    /// Round-data files use capitalised names ("Red", "Moab").
    static func fromRoundData(_ s: String) -> BloonType? {
        BloonType(rawValue: s.lowercased())
    }

    var display: String { rawValue.capitalized }

    var swatch: NSColor {
        guard let h = hue else {
            switch self {
            case .white: return .white
            case .black: return NSColor(white: 0.15, alpha: 1)
            case .lead:  return NSColor(white: 0.45, alpha: 1)
            default:     return NSColor(white: 0.6, alpha: 1)
            }
        }
        return NSColor(hue: CGFloat(h.center / 360.0), saturation: 0.85, brightness: 0.9, alpha: 1)
    }
}

/// A pixel reduced to hue/saturation/brightness, which is all the classifier needs.
struct HSB {
    let h: Double  // degrees
    let s: Double
    let b: Double

    init(r: Double, g: Double, b bl: Double) {
        let maxV = max(r, g, bl), minV = min(r, g, bl)
        let delta = maxV - minV
        var hue = 0.0
        if delta > 0.0001 {
            if maxV == r        { hue = 60 * ((g - bl) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxV == g   { hue = 60 * (((bl - r) / delta) + 2) }
            else                { hue = 60 * (((r - g) / delta) + 4) }
        }
        if hue < 0 { hue += 360 }
        self.h = hue
        self.s = maxV < 0.0001 ? 0 : delta / maxV
        self.b = maxV
    }

    /// Back to linear channels. Classification works in HSB, but the background
    /// model and the sprite descriptor both compare colours by summed channel
    /// difference, and every threshold either one uses was measured that way.
    var rgb: (r: Double, g: Double, b: Double) {
        let c = self.b * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = self.b - c
        let (r, g, bl): (Double, Double, Double)
        switch h {
        case ..<60:  (r, g, bl) = (c, x, 0)
        case ..<120: (r, g, bl) = (x, c, 0)
        case ..<180: (r, g, bl) = (0, c, x)
        case ..<240: (r, g, bl) = (0, x, c)
        case ..<300: (r, g, bl) = (x, 0, c)
        default:     (r, g, bl) = (c, 0, x)
        }
        return (r + m, g + m, bl + m)
    }

    func matches(_ type: BloonType) -> Bool {
        let floor = type.satBrightFloor
        guard s >= floor.sat, b >= floor.bright else { return false }
        guard let hueSpec = type.hue else { return false }
        var d = abs(h - hueSpec.center)
        if d > 180 { d = 360 - d }  // wrap around the colour wheel
        return d <= hueSpec.tolerance
    }
}
