// HUD region map, normalised to the captured frame so it survives the game
// window being moved or resized.
//
// Coordinates were measured from real capture frames at 2560x1588, in the
// orientation where YOU own the right track and the opponent owns the left.
// That orientation is no longer assumed: `mySide` is decided at runtime by
// SideDetector, and every region below resolves through it.
//
// Only your own cash and eco are ever displayed — the opponent's are not, which
// is the whole reason the income model exists.
//
// MIRRORING. The captured frame is NOT symmetric: there is roughly 155px of
// dead space at the left edge with no counterpart on the right, where the panel
// runs flush to the border. So a mirrored region is never computed as
// `1 - x - w` when a measured partner exists — the paired regions are SWAPPED
// instead, which is measured truth rather than inference. Arithmetic flipping is
// used only for UI chrome that has no partner (the send/shop panel, and the
// top bar if it turns out to mirror), because that chrome is laid out against
// the window edge rather than against the play area.

import Foundation
import CoreGraphics

/// Which half of the screen YOU own.
enum PlayerSide: String {
    case right, left

    var opposite: PlayerSide { self == .right ? .left : .right }
}

struct HUDRegion {
    let name: String
    let rect: CGRect  // normalised, top-left origin

    func pixels(_ w: Int, _ h: Int) -> CGRect {
        CGRect(x: rect.minX * CGFloat(w), y: rect.minY * CGFloat(h),
               width: rect.width * CGFloat(w), height: rect.height * CGFloat(h)).integral
    }
}

enum Regions {

    // MARK: - Measured layout (you on the right)

    private enum M {
        static let oppName  = HUDRegion(name: "opp_name",  rect: CGRect(x: 0.0078, y: 0.0705, width: 0.1484, height: 0.0365))
        static let oppLives = HUDRegion(name: "opp_lives", rect: CGRect(x: 0.3086, y: 0.0705, width: 0.0547, height: 0.0365))
        static let myCash   = HUDRegion(name: "my_cash",   rect: CGRect(x: 0.3848, y: 0.0705, width: 0.0684, height: 0.0365))
        // Narrowed to stop the green eco triangle bleeding in — it OCRs as a
        // trailing "1" and silently turns 301 into 3011.
        static let myEco    = HUDRegion(name: "my_eco",    rect: CGRect(x: 0.4707, y: 0.0705, width: 0.0449, height: 0.0365))
        static let round    = HUDRegion(name: "round",     rect: CGRect(x: 0.5332, y: 0.0705, width: 0.0879, height: 0.0365))
        static let myLives  = HUDRegion(name: "my_lives",  rect: CGRect(x: 0.6328, y: 0.0705, width: 0.0547, height: 0.0365))
        static let myName   = HUDRegion(name: "my_name",   rect: CGRect(x: 0.8594, y: 0.0705, width: 0.1289, height: 0.0365))
        static let myQueue  = HUDRegion(name: "my_queue",  rect: CGRect(x: 0.4785, y: 0.1795, width: 0.0449, height: 0.3715))
        static let sendMenu = HUDRegion(name: "send_menu", rect: CGRect(x: 0.9277, y: 0.5038, width: 0.0742, height: 0.1826))
        static let myTrack  = HUDRegion(name: "my_track",  rect: CGRect(x: 0.5000, y: 0.1102, width: 0.4102, height: 0.8816))
        static let oppTrack = HUDRegion(name: "opp_track", rect: CGRect(x: 0.0742, y: 0.1102, width: 0.4102, height: 0.8816))
    }

    // MARK: - Resolved orientation

    /// Which side YOU are on. Defaults to the measured orientation so replay and
    /// the first few frames have something coherent to work with; SideDetector
    /// overwrites it once, from pixels.
    private(set) static var mySide: PlayerSide = .right

    /// Whether the top bar mirrors along with the play area. Settled empirically
    /// at latch time by reading the round counter at both candidate positions,
    /// because nothing in the captures on hand answers it.
    private(set) static var topBarMirrors = false

    /// True once the side has been decided from pixels rather than assumed.
    private(set) static var latched = false

    static func adopt(side: PlayerSide, topBarMirrors tb: Bool) {
        mySide = side
        topBarMirrors = tb
        latched = true
    }

    /// Test-only escape hatch; also lets --replay force an orientation.
    static func forceSide(_ side: PlayerSide, topBarMirrors tb: Bool) {
        adopt(side: side, topBarMirrors: tb)
    }

    private static var mirrored: Bool { mySide == .left }

    /// Flip about the window centre. For UI chrome only — see the header note.
    private static func flipX(_ r: HUDRegion, _ name: String) -> HUDRegion {
        HUDRegion(name: name,
                  rect: CGRect(x: max(0, 1 - r.rect.minX - r.rect.width), y: r.rect.minY,
                               width: r.rect.width, height: r.rect.height))
    }

    private static func renamed(_ r: HUDRegion, _ name: String) -> HUDRegion {
        HUDRegion(name: name, rect: r.rect)
    }

    // MARK: - Regions

    // Paired regions swap wholesale. Both halves were measured, so a swap
    // introduces no inference.
    static var myTrack:  HUDRegion { mirrored ? renamed(M.oppTrack, "my_track")  : M.myTrack }
    static var oppTrack: HUDRegion { mirrored ? renamed(M.myTrack,  "opp_track") : M.oppTrack }
    static var myLives:  HUDRegion { mirrored ? renamed(M.oppLives, "my_lives")  : M.myLives }
    static var oppLives: HUDRegion { mirrored ? renamed(M.myLives,  "opp_lives") : M.oppLives }
    static var myName:   HUDRegion { mirrored ? renamed(M.oppName,  "my_name")   : M.myName }
    static var oppName:  HUDRegion { mirrored ? renamed(M.myName,   "opp_name")  : M.oppName }

    /// The send/shop panel is window chrome with no measured partner, so it is
    /// flipped arithmetically to the opposite edge.
    static var sendMenu: HUDRegion { mirrored ? flipX(M.sendMenu, "send_menu") : M.sendMenu }

    /// Your outgoing queue sits centred ON the divider — its own mirror image.
    /// It does not move with the side.
    static var myQueue: HUDRegion { M.myQueue }

    // The centre triple has no partner either. Whether it moves is decided by
    // `topBarMirrors`, which is measured at latch time rather than assumed.
    static var myCash: HUDRegion { mirrored && topBarMirrors ? flipX(M.myCash, "my_cash") : M.myCash }
    static var myEco:  HUDRegion { mirrored && topBarMirrors ? flipX(M.myEco,  "my_eco")  : M.myEco }
    static var round:  HUDRegion { mirrored && topBarMirrors ? flipX(M.round,  "round")   : M.round }

    /// Both candidate positions for the round readout. Probed once, at latch
    /// time, to settle whether the top bar mirrors with the play area.
    /// "ROUND n/40" is distinctive enough that exactly one of these parses.
    static var roundCandidates: [(topBarMirrors: Bool, region: HUDRegion)] {
        [(false, M.round), (true, flipX(M.round, "round"))]
    }

    // MARK: - Side probes
    //
    // The outer column on each side, below the top bar. On the side you own,
    // this is the tower shop and the send cards — a dense column of price and
    // quantity text. On the other side it is bare map. Measured across the 20
    // calibration frames: 0 text hits on the empty side in 20/20 frames, 1-5 on
    // the panel side in 17/20. Absolute, not side-dependent — these are what
    // DECIDE the side.

    static let leftProbe  = HUDRegion(name: "probe_left",  rect: CGRect(x: 0.0,   y: 0.15, width: 0.075, height: 0.77))
    static let rightProbe = HUDRegion(name: "probe_right", rect: CGRect(x: 0.925, y: 0.15, width: 0.075, height: 0.77))

    static var hudText: [HUDRegion] { [oppName, oppLives, myCash, myEco, round, myLives, myName] }
    static var all: [HUDRegion] { hudText + [myQueue, sendMenu, myTrack, oppTrack] }
}
