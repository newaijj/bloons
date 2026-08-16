// A census of the towers on one board, maintained over time.
//
// Membership comes from PlateCensus — occupancy against a plate of the empty
// board, gated on stillness. This file owns everything ABOVE that: turning
// blobs into tracked sites with stable identities, pricing them by descriptor,
// and reporting what changed.
//
// Two designs have been replaced here, both for measured reasons:
//
//   Event sums. Board value was once a running total of build EVENTS, so every
//   false positive was permanent and drift was monotone — a logged match reached
//   $12,461 against a $2,302 ceiling and never came back down. Value is now a
//   pure function of the sites currently standing, so a bad reading costs a few
//   seconds instead of the rest of the match, and a sell simply leaves the
//   census rather than registering as another purchase.
//
//   Absorption detection. Sites were found by watching pixels settle, which
//   could only ever see a tower ARRIVE. Anything standing before the tracker
//   latched was invisible by design, and every scene change wiped the board. On
//   a real logged match it found 0 of 13 opponent towers. PlateCensus asks what
//   is standing there instead, and scores 10/13 and 9/11 held-out on two maps.
//
// What this file still decides, and why each is not free:
//
//   is it the same   a blob near a known site is that site, so identity — and
//                    therefore arrival time — survives a frame where the mask
//                    breaks up
//   is it new        confirmed only after several censuses agree, because a
//                    bloon pack can hold still for one window
//   is it different  descriptor distance, which is what separates an upgrade
//                    from a passing bloon
//
// Used for both boards. On theirs it books spending; on yours it harvests
// priced templates, because your own cash tells you exactly what each change
// was worth.

import Foundation
import CoreGraphics

struct TowerSite {
    let id: Int
    var centreX: Int, centreY: Int
    var x0: Int, y0: Int, x1: Int, y1: Int
    var descriptor: SpriteDescriptor
    var areaSamples: Int
    var confirmations: Int
    var misses: Int
    /// Frame-clock seconds, not wall clock — see `Frame.time`.
    var firstSeen: Double
    /// A reading that disagrees with the stored descriptor, held until a second
    /// census agrees with it. A bloon crossing the sprite changes the descriptor
    /// for a moment; an upgrade changes it for good.
    var pending: SpriteDescriptor?

    var isConfirmed: Bool { confirmations >= BoardWatcher.confirmationsNeeded }
}

enum CensusChange {
    case appeared(TowerSite)
    case upgraded(site: TowerSite, from: SpriteDescriptor)
    case removed(TowerSite)
}

final class BoardWatcher {
    let name: String
    private let plate: PlateCensus
    private var region: HUDRegion

    /// Real measured sprite extent at 2560px wide. Kept because TowerWatcher
    /// scales its unpriced fallback cost by it.
    static let spriteDiameterAt2560 = 150.0
    /// Sentinel for "this site has aged in". Confirmation is decided by AGE, not
    /// by how many censuses happened to see the site — see `minAgeSeconds`.
    static let confirmationsNeeded = 3
    private let maxMisses = 3
    private let censusPeriod = 2.0
    /// Descriptor distance that counts as a different appearance. Above both the
    /// library's match threshold and the measured within-tower noise floor of
    /// 0.224, so firing animation and a passing bloon cannot read as an upgrade,
    /// while a genuinely different sprite (never closer than 0.302 in the same
    /// measurement) still does.
    private let upgradeDistance = 0.30
    /// Frame pixels within which a blob is taken to be an existing site. Half a
    /// footprint: close enough that a mask breaking up across a sprite does not
    /// mint a second site, far enough that two real towers ~100px apart are not
    /// collapsed.
    private let sameSiteRadius = 75.0
    /// How long a site must have existed before it enters the books.
    ///
    /// AGE, deliberately, not a count of sightings. Both held-out evaluations
    /// were run this way and the distinction is not cosmetic: a firing tower
    /// drops out of the mask intermittently, so a rule that demands N
    /// consecutive sightings can take arbitrarily long to confirm it, or never.
    /// Requiring sightings instead of age cost 2 of 11 towers on
    /// 20260816T152152 — precision rose to 100% and recall fell to 63.6% —
    /// because the tower it dropped was the one that spends its life
    /// muzzle-flashing.
    private let minAgeSeconds = 6.0
    /// How long the board may read as mostly-occupied before the plate itself is
    /// judged wrong rather than the view being blocked. Long enough to sit out a
    /// banner, short enough that a bad plate is replaced within one round.
    private let staleplateSeconds = 3.0

    /// When the current run of high occupancy began, or nil when the board reads
    /// normally.
    private var sceneSince: Double?

    private(set) var sites: [TowerSite] = []
    private var nextID = 1
    private var lastCensus = -Double.greatestFiniteMagnitude

    /// Whole-scene changes seen. Surfaced because a run with several is a run
    /// whose books deserve suspicion.
    var sceneChanges: Int { plate.sceneChanges }

    init(region: HUDRegion, name: String) {
        self.region = region
        self.name = name
        plate = PlateCensus(region: region)
    }

    func retarget(_ r: HUDRegion) {
        region = r
        plate.retarget(r)
        sites.removeAll()
        sceneSince = nil
        lastCensus = -Double.greatestFiniteMagnitude
    }

    /// Nothing to scale any more — the plate detector works in its own grid and
    /// its thresholds are absolute. Kept so callers need not change.
    func calibrate(frameWidth: Int) {}

    var confirmedSites: [TowerSite] { sites.filter(\.isConfirmed) }

    /// Why the census produced what it did, for the frame just scanned. Without
    /// these, a run that finds nothing is indistinguishable from a run where
    /// nothing happened — the ambiguity that made tuning detection guesswork.
    struct Trace {
        var blobs = 0             // occupied-and-still regions this census
        var rejectedNearby = 0    // ... that matched an existing site
        var sites = 0             // tracked, including unconfirmed
        var confirmed = 0
        var armed = false         // plate seeded, window full
        var occupiedFraction = 0.0
    }
    private(set) var trace = Trace()

    /// Where to write every candidate crop with the verdict passed on it. A gate
    /// that rejects everything and a board with nothing on it produce identical
    /// output — a zero — so the only way to tell a correctly quiet detector from
    /// a broken one is to look at what it threw away.
    static var cropSink: ((CGImage, String) -> Void)?

    /// Scan the board and reconcile it with the standing census.
    ///
    /// `allowed` is unused now that path learning is gone; it stays in the
    /// signature so callers are untouched.
    func update(_ frame: Frame, allowed: Set<BloonType>) -> [CensusChange] {
        trace = Trace()

        // The plate has to come from a board with nothing on it. At match start
        // that is simply the first frame; anything already built at seed time is
        // absorbed into the plate and stays invisible for the life of the plate.
        if !plate.hasPlate {
            plate.seedPlate(frame)
            reportStanding()
            return []
        }

        guard plate.observe(frame) else {
            // Frame skipped for rate — see PlateCensus.sampleInterval. Report
            // the standing census rather than an empty trace.
            reportStanding()
            return []
        }
        trace.occupiedFraction = plate.occupiedFraction
        let now = frame.time

        // A banner, a panel, or the end-of-match overlay makes a large fraction
        // of the board differ from the plate at once. SUSPEND while that lasts:
        // skip the census so no site accrues a miss, and leave the plate alone.
        //
        // The obvious-looking alternative — reseed, the way the old absorption
        // scanner did — is actively destructive here, and measurably so. On
        // 20260816T124547 an overlay pushed occupancy to ~44% near t=326; a
        // reseed there rebuilt the plate from a frame with eight towers
        // standing on it, baking them into the background so they could never
        // be seen again. The board read 7 towers at t=315 and 0 at t=330, and
        // held-out recall fell from 76.9% to 30.8%. A plate is only ever valid
        // if it was taken from an empty board, so the only safe reseed is at
        // retarget, when a match is starting.
        if plate.isSceneChange() {
            plate.noteSceneChange()
            // Transient or stale? The two look identical in one frame and are
            // told apart by how long they last.
            //
            // A banner or panel covers the board for a second or two and then
            // goes; the plate underneath is still good, so suspending is right.
            // But a plate taken from the WRONG LIGHTING never recovers — on
            // 20260816T152152 the side latched during the match-start countdown,
            // which dims the whole screen, so the plate was geometrically
            // perfect and photometrically useless. Every later frame differed
            // from it everywhere, occupancy pinned high, and suspend-forever
            // meant the detector never ran at all: 0 of 11 towers.
            //
            // So sustained high occupancy is evidence about the PLATE, not the
            // board, and the only repair is to take a new one.
            let since = sceneSince ?? now
            sceneSince = since
            if now - since >= staleplateSeconds {
                plate.seedPlate(frame)
                sites.removeAll()
                lastCensus = -Double.greatestFiniteMagnitude
                sceneSince = nil
            }
            reportStanding()
            return []
        }
        sceneSince = nil
        trace.armed = true

        guard now - lastCensus >= censusPeriod else {
            trace.sites = sites.count
            trace.confirmed = sites.filter(\.isConfirmed).count
            return []
        }
        lastCensus = now
        return runCensus(frame, now: now)
    }

    /// Fill the trace from the standing census on a frame that ran no census.
    ///
    /// Every early return above used to leave `trace.sites` at zero, so the
    /// console showed an empty board on any frame that was skipped for rate or
    /// suspended — which is exactly how the reseed bug above stayed hidden: the
    /// frames where the damage happened printed nothing at all.
    private func reportStanding() {
        trace.sites = sites.count
        trace.confirmed = sites.filter(\.isConfirmed).count
        trace.armed = plate.hasPlate
        trace.occupiedFraction = plate.occupiedFraction
    }

    // MARK: - census

    /// Match this census's blobs to the standing sites, then reconcile.
    private func runCensus(_ frame: Frame, now: Double) -> [CensusChange] {
        let found = plate.blobs()
        trace.blobs = found.count

        var changes: [CensusChange] = []
        var matchedSite = Set<Int>()
        var keep: [TowerSite] = []

        // Existing sites first, so a blob prefers the identity it already had.
        for blob in found {
            var best: Int? = nil, bestD = Double.greatestFiniteMagnitude
            for (i, s) in sites.enumerated() where !matchedSite.contains(i) {
                let dx = Double(s.centreX - blob.cx), dy = Double(s.centreY - blob.cy)
                let d = (dx * dx + dy * dy).squareRoot()
                if d < bestD && d < sameSiteRadius { best = i; bestD = d }
            }

            let d = describeSprite(frame, x0: blob.x0, y0: blob.y0, x1: blob.x1, y1: blob.y1,
                                   areaSamples: blob.cells)
            if let sink = Self.cropSink, let cg = frame.makeCGImage()?.cropping(
                    to: CGRect(x: blob.x0, y: blob.y0,
                               width: blob.x1 - blob.x0, height: blob.y1 - blob.y0)) {
                sink(cg, String(format: "%@_t%.1f_cells%d_%dx%d", name, now, blob.cells,
                                blob.x1 - blob.x0, blob.y1 - blob.y0))
            }

            if let i = best {
                matchedSite.insert(i)
                trace.rejectedNearby += 1
                var s = sites[i]
                s.centreX = blob.cx; s.centreY = blob.cy
                s.x0 = blob.x0; s.y0 = blob.y0; s.x1 = blob.x1; s.y1 = blob.y1
                s.areaSamples = blob.cells
                s.misses = 0
                if !s.isConfirmed {
                    if let d { s.descriptor = d }
                    if now - s.firstSeen >= minAgeSeconds {
                        s.confirmations = Self.confirmationsNeeded
                        changes.append(.appeared(s))
                    }
                } else if let d {
                    let dist = d.distance(to: s.descriptor)
                    if dist > upgradeDistance {
                        // Needs a second census to agree. A bloon crossing the
                        // sprite moves the descriptor for one reading; an
                        // upgrade moves it for good.
                        if let p = s.pending, d.distance(to: p) <= upgradeDistance {
                            let from = s.descriptor
                            s.descriptor = d
                            s.pending = nil
                            changes.append(.upgraded(site: s, from: from))
                        } else {
                            s.pending = d
                        }
                    } else {
                        s.pending = nil
                    }
                }
                keep.append(s)
            } else {
                guard let d else { continue }
                sites.append(TowerSite(id: nextID, centreX: blob.cx, centreY: blob.cy,
                                       x0: blob.x0, y0: blob.y0, x1: blob.x1, y1: blob.y1,
                                       descriptor: d, areaSamples: blob.cells,
                                       confirmations: 1, misses: 0, firstSeen: now,
                                       pending: nil))
                matchedSite.insert(sites.count - 1)
                keep.append(sites[sites.count - 1])
                nextID += 1
            }
        }

        // Sites no blob claimed. They survive a couple of censuses, because the
        // mask breaks up when a bloon crosses a sprite or a tower fires.
        for (i, var s) in sites.enumerated() where !matchedSite.contains(i) {
            s.misses += 1
            s.pending = nil
            if s.misses >= maxMisses {
                // Gone. On their board that is a sell, and its cost leaves the
                // census with it — which an event sum could never do.
                if s.isConfirmed { changes.append(.removed(s)) }
                continue
            }
            keep.append(s)
        }

        sites = keep
        trace.sites = sites.count
        trace.confirmed = sites.filter(\.isConfirmed).count
        return changes
    }
}
