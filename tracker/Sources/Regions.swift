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
// MIRRORING. The window CHROME is not symmetric: there is roughly 155px of dead
// space at the left edge with no counterpart on the right, where the panel runs
// flush to the border. So chrome regions are never computed as `1 - x - w` when
// a measured partner exists — those pairs are SWAPPED instead, which is measured
// truth rather than inference.
//
// The PLAY AREA is a different matter, and the two were previously conflated.
// The two boards are exact geometric reflections about the frame's vertical
// centre: `rx = W - 1 - x`, `dy = 0`, with the axis pinned to one pixel (mean
// abs luma 7.36 at x=(W-1)/2 against 8.61 one pixel either side and ~21 for any
// non-mirrored translation, measured on the desert capture). Per-column mirror
// residual puts the left board's low-residual band at x 204–1241 of 2560 and the
// centre divider at 1241–1319.
//
// The separately measured `myTrack` was therefore WRONG: at 0.5000–0.9102 it
// began on the divider and clipped ~40px off the board's outer edge. Both boards
// now derive from one measured band and its exact reflection, so they cannot
// drift apart again.
//
// The reflection is GEOMETRIC ONLY. Directional lighting stays fixed in screen
// space, so mirroring puts a block's highlight onto its own shadow — on a map
// with relief the mirror difference is 30-35% and never cancels. Use this to map
// POSITIONS between boards, never as a background plate.

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
        /// The LEFT board, measured. The right board is its exact reflection and
        /// is derived rather than measured a second time — see the header.
        static let leftTrack  = HUDRegion(name: "left_track",
                                          rect: CGRect(x: 0.0742, y: 0.1102, width: 0.4102, height: 0.8816))
        static let rightTrack = reflect(leftTrack, "right_track")

        /// Reflect about the frame's vertical centre. Exact for the play area:
        /// the axis was measured at x=(W-1)/2 to within one pixel.
        static func reflect(_ r: HUDRegion, _ name: String) -> HUDRegion {
            HUDRegion(name: name,
                      rect: CGRect(x: 1 - r.rect.minX - r.rect.width, y: r.rect.minY,
                                   width: r.rect.width, height: r.rect.height))
        }
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

    // The play area is symmetric, so a track is named by which side owns it
    // rather than swapped between two independently measured rectangles. That
    // is what stopped the pair drifting 40px apart — see the header.
    static var myTrack:  HUDRegion {
        renamed(mirrored ? M.leftTrack : M.rightTrack, "my_track")
    }
    static var oppTrack: HUDRegion {
        renamed(mirrored ? M.rightTrack : M.leftTrack, "opp_track")
    }
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

    /// Centre chrome that overhangs both play bands, to be excluded from any
    /// scan of either board. Not a play region: it is the strip to THROW AWAY.
    ///
    /// The boards are mirror-derived and must not be perturbed to dodge chrome,
    /// so the chrome is subtracted at sample time instead — see TrackScanner.
    ///
    /// Measured on 20260816T124547 at 2560x1588. Two separate things live on the
    /// divider, and they occupy nearly the same columns:
    ///
    ///   button cluster (trophy/chat/surrender)  x 1235-1324, y 1187-1479
    ///   send-queue cards                        x 1238-1318, y  280- 875
    ///
    /// Against boards at 190-1240 and 1319-2369, that is a 6px overhang onto the
    /// right board and 6px onto the left. Note it is the BUTTONS that reach the
    /// right board — the queue stops at 1318, one pixel short of it — so masking
    /// `myQueue` would have missed the overhang entirely while discarding 22px of
    /// real board that has no chrome on it.
    ///
    /// One column covers both, full play height, since they share their columns
    /// and nothing else is ever drawn there. 1232-1328 gives ~3px of margin.
    /// A tower sprite is ~150px wide, so its centre can never sit in the 6px the
    /// mask takes from a board; nothing detectable is lost.
    static let centreChrome = HUDRegion(name: "centre_chrome",
                                        rect: CGRect(x: 0.4813, y: 0.1102,
                                                     width: 0.0375, height: 0.8816))

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

    /// The two lives readouts BY SCREEN POSITION rather than by owner. They are
    /// mirror images of each other, so whichever side you are on, both of these
    /// positions hold a number during a match and neither does in a menu.
    /// Used to establish that a match is up before the side is decided — which
    /// has to happen without knowing the side, or it is circular.
    static var leftLives: HUDRegion { renamed(M.oppLives, "left_lives") }
    static var rightLives: HUDRegion { renamed(M.myLives, "right_lives") }

    static var hudText: [HUDRegion] { [oppName, oppLives, myCash, myEco, round, myLives, myName] }
    static var all: [HUDRegion] { hudText + [myQueue, sendMenu, myTrack, oppTrack] }
}
