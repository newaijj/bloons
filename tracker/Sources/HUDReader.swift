// Reads numbers off the HUD with Vision, and reads the send cards for the
// current round's cost/eco table.
//
// Vision is fed small crops rather than whole frames — that is what keeps OCR
// cheap enough to run alongside a game. Stylised game fonts also produce
// predictable garbage (the eco triangle reads as a "1", "X" and "×" and "Х"
// all appear), so every parse is cleaned and then sanity-checked against the
// previous value before it is accepted.

import Foundation
import Vision
import CoreGraphics

struct SendCard {
    let type: BloonType
    let quantity: Int
    let eco: Double
    let cost: Int
}

struct HUDSnapshot {
    var round: Int?
    var myCash: Int?
    var myEco: Double?
    var myLives: Int?
    var oppLives: Int?
    var oppName: String?
    var myName: String?
    var sendCards: [SendCard] = []
}

final class HUDReader {
    /// Last accepted values, used to reject implausible OCR jumps.
    private var lastCash: Int?
    private var lastEco: Double?
    private var lastRound: Int?

    private func recognize(_ image: CGImage, _ rect: CGRect, accurate: Bool = false) -> [(String, CGRect)] {
        guard rect.width > 4, rect.height > 4,
              let crop = image.cropping(to: rect) else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = accurate ? .accurate : .fast
        req.usesLanguageCorrection = false
        req.recognitionLanguages = ["en-US"]
        guard (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([req])) != nil else { return [] }

        let w = CGFloat(crop.width), h = CGFloat(crop.height)
        return (req.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            return (c.string, CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
        }
    }

    private func text(_ image: CGImage, _ region: HUDRegion) -> String {
        recognize(image, region.pixels(image.width, image.height), accurate: true)
            .map(\.0).joined(separator: " ")
    }

    /// Keep digits and at most one decimal point; drop the "X", stray glyphs,
    /// and the coin/triangle icons that Vision hallucinates into characters.
    private func digits(_ s: String) -> String {
        var out = "", seenDot = false
        for ch in s {
            if ch.isNumber { out.append(ch) }
            else if ch == "." && !seenDot && !out.isEmpty { out.append(ch); seenDot = true }
        }
        return out
    }

    private func parseInt(_ s: String) -> Int? { Int(digits(s).split(separator: ".").first ?? "") }
    private func parseDouble(_ s: String) -> Double? { Double(digits(s)) }

    /// Drop the accepted-value history. Called when the side latches, because
    /// anything read before that came from regions that may have been pointed
    /// at the wrong half of the screen.
    func resetHistory() {
        lastCash = nil; lastEco = nil; lastRound = nil
    }

    /// Text hits in each outer column, below the top bar — the panel signal that
    /// decides which side you are on. Only digit-bearing hits count: the shop
    /// prices and send quantities are numeric, whereas the stray glyphs Vision
    /// hallucinates out of map scenery generally are not.
    ///
    /// Accurate mode, deliberately. The fast recogniser misses the panel
    /// entirely on roughly the first third of frames — measured on the
    /// calibration set, it needed 8 frames to reach the same call accurate mode
    /// reaches in 3. This only runs until the side latches, so the cost is a few
    /// seconds at startup and then nothing.
    func panelHits(_ image: CGImage) -> (left: Int, right: Int) {
        func hits(_ region: HUDRegion) -> Int {
            recognize(image, region.pixels(image.width, image.height), accurate: true)
                .filter { $0.0.contains(where: \.isNumber) }.count
        }
        return (hits(Regions.leftProbe), hits(Regions.rightProbe))
    }

    /// Read the round counter at a specific candidate region. Used once, at
    /// latch time, to settle whether the top bar mirrors with the play area.
    /// Requires the "n/40" form, which nothing else on screen produces.
    func probeRound(_ image: CGImage, _ region: HUDRegion) -> Int? {
        let t = text(image, region)
        guard let slash = t.firstIndex(of: "/"),
              let n = parseInt(String(t[t.startIndex..<slash])),
              (1...50).contains(n) else { return nil }
        return n
    }

    /// Relax the two-lives requirement to one, for opponents whose lives are not
    /// a number.
    ///
    /// Solo modes put an infinity glyph where a lives count goes — T.D. in Hero
    /// Challenge renders `∞`, and the region OCRs as empty — so the two-lives
    /// test can never pass and the tracker stays dark for the whole match, live
    /// or replaying a corpus recorded in it.
    ///
    /// Opt-in rather than the default, because the strict test is what keeps a
    /// menu from deciding the side (see `matchProbe`). Solo runs force the side
    /// anyway, so the failure it guards against is not reachable there.
    static var soloMode = false

    /// Whether a match is actually on screen, and where the top bar sits.
    ///
    /// Deliberately side-independent — deciding the side requires knowing a
    /// match is up, so this cannot itself depend on the side without being
    /// circular. The round counter reads "n/40" in exactly one of two known
    /// places and in neither the menu nor the lobby, and the two lives readouts
    /// are mirror images of each other, so testing both positions covers either
    /// orientation.
    ///
    /// This gate exists because a run once latched the side off menu chrome 43
    /// seconds before the board came up, and got it backwards.
    func matchProbe(_ image: CGImage) -> (round: Int, topBarMirrors: Bool)? {
        for cand in Regions.roundCandidates {
            guard let r = probeRound(image, cand.region) else { continue }
            let left = parseInt(text(image, Regions.leftLives)) != nil
            let right = parseInt(text(image, Regions.rightLives)) != nil
            guard Self.soloMode ? (left || right) : (left && right) else { continue }
            return (r, cand.topBarMirrors)
        }
        return nil
    }

    func read(_ image: CGImage) -> HUDSnapshot {
        var snap = HUDSnapshot()

        // "ROUND 3/40" — take the numerator only.
        let roundText = text(image, Regions.round)
        if let slash = roundText.firstIndex(of: "/") {
            snap.round = parseInt(String(roundText[roundText.startIndex..<slash]))
        } else {
            snap.round = parseInt(roundText)
        }
        // Rounds only ever advance, and never by more than one at a time.
        if let r = snap.round, let prev = lastRound, r < prev || r > prev + 1 { snap.round = prev }
        if let r = snap.round, (1...50).contains(r) { lastRound = r } else { snap.round = lastRound }

        snap.myLives  = parseInt(text(image, Regions.myLives))
        snap.oppLives = parseInt(text(image, Regions.oppLives))
        snap.oppName  = text(image, Regions.oppName).trimmingCharacters(in: .whitespaces)
        snap.myName   = text(image, Regions.myName).trimmingCharacters(in: .whitespaces)

        // Cash can move fast but not arbitrarily; reject wild single-frame jumps.
        if let cash = parseInt(text(image, Regions.myCash)), cash < 1_000_000 {
            if let prev = lastCash, abs(cash - prev) > max(5000, prev) {
                snap.myCash = prev
            } else {
                snap.myCash = cash; lastCash = cash
            }
        } else { snap.myCash = lastCash }

        // Eco is monotonic upward in practice and never jumps hundreds at once.
        if let eco = parseDouble(text(image, Regions.myEco)), eco < 100_000 {
            if let prev = lastEco, abs(eco - prev) > 300 {
                snap.myEco = prev
            } else {
                snap.myEco = eco; lastEco = eco
            }
        } else { snap.myEco = lastEco }

        snap.sendCards = readSendCards(image)
        return snap
    }

    /// Upscale before OCR. Card text is only ~20px tall in the source frame,
    /// which is right at Vision's limit; 3x makes it read reliably.
    private func upscale(_ image: CGImage, _ factor: Int) -> CGImage? {
        let w = image.width * factor, h = image.height * factor
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The send menu is a two-column grid of cards. Each card carries a
    /// quantity ("X8"), an eco gain, and a cash cost, stacked in that order.
    /// The bloon type comes from the icon's hue, not from OCR.
    func readSendCards(_ image: CGImage) -> [SendCard] {
        let region = Regions.sendMenu.pixels(image.width, image.height)
        guard let crop = image.cropping(to: region),
              let big = upscale(crop, 3) else { return [] }

        let hits = recognize(big, CGRect(x: 0, y: 0, width: big.width, height: big.height), accurate: true)
        guard !hits.isEmpty else { return [] }

        // Work in fractions of the region so the upscale factor drops out.
        let bw = CGFloat(big.width), bh = CGFloat(big.height)
        let norm = hits.map { ($0.0, CGRect(x: $0.1.minX / bw, y: $0.1.minY / bh,
                                            width: $0.1.width / bw, height: $0.1.height / bh)) }

        var cards: [(column: Int, hits: [(String, CGRect)])] = []
        for column in [0, 1] {
            let colHits = norm.filter { column == 0 ? $0.1.midX < 0.5 : $0.1.midX >= 0.5 }
                              .sorted { $0.1.minY < $1.1.minY }
            var current: [(String, CGRect)] = []
            var lastY: CGFloat = -10
            for hit in colHits {
                // Lines within a card sit ~0.07 apart; the gap between rows of
                // cards is ~0.30. Split at 0.16.
                if hit.1.minY - lastY > 0.16, !current.isEmpty {
                    cards.append((column, current)); current = []
                }
                current.append(hit); lastY = hit.1.minY
            }
            if !current.isEmpty { cards.append((column, current)) }
        }

        // Parse each card's numbers, keeping its grid position.
        struct Parsed { let row: CGFloat; let column: Int; let qty: Int; let eco: Double; let cost: Int }
        var parsed: [Parsed] = []
        for card in cards where card.hits.count >= 3 {
            let sorted = card.hits.sorted { $0.1.minY < $1.1.minY }
            guard let qty = parseInt(sorted[0].0),
                  var eco = parseDouble(sorted[1].0),
                  let cost = parseInt(sorted[2].0),
                  qty > 0, qty < 100, eco > 0, cost > 0
            else { continue }

            // Send eco values all sit under ~5. Anything above that means Vision
            // dropped the decimal point ("1.1" -> "11", "0.9" -> "9").
            if eco >= 5 { eco /= 10 }
            guard eco < 5 else { continue }

            parsed.append(Parsed(row: sorted[0].1.minY, column: card.column,
                                 qty: qty, eco: eco, cost: cost))
        }

        // Type comes from position, not colour. The menu lays sends out in a
        // fixed unlock order in reading order (red, blue / green, yellow / …),
        // and that ordering survives lighting, gloss, and the muted olive green
        // that hue voting kept losing to the card's blue background.
        //
        // Index from ABSOLUTE grid geometry, not from position among the cards
        // that happened to parse — one failed OCR would otherwise shift every
        // card after it onto the wrong bloon.
        //
        // Caveat: this assumes the menu is unscrolled, which holds while fewer
        // than five sends are unlocked. Scroll state is logged so a live run can
        // settle how to detect it.
        var out: [SendCard] = []
        for p in parsed {
            let rowIndex = Int(((p.row - Self.firstRowY) / Self.rowPitch).rounded())
            guard rowIndex >= 0 else { continue }
            let idx = rowIndex * 2 + p.column
            guard idx < Self.sendOrder.count else { continue }
            out.append(SendCard(type: Self.sendOrder[idx], quantity: p.qty, eco: p.eco, cost: p.cost))
        }
        return out.sorted { Self.sendOrder.firstIndex(of: $0.type)! < Self.sendOrder.firstIndex(of: $1.type)! }
    }

    /// Normalised y of the first card row's quantity line, and the row-to-row
    /// pitch, both measured from capture frames.
    static let firstRowY: CGFloat = 0.276
    static let rowPitch: CGFloat = 0.414

    /// Order the send menu unlocks cards in, read left-to-right then down.
    static let sendOrder: [BloonType] = [.red, .blue, .green, .yellow, .pink,
                                         .black, .white, .purple, .lead, .zebra,
                                         .rainbow, .ceramic]
}
