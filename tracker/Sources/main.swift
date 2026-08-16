// btdb2 opponent income tracker
//
// Reads only pixels the game already draws on your screen: no memory access, no
// packet capture, no input automation.
//
// Pipeline per frame:
//   capture (SCStream, window-targeted)
//     -> track scan: background-subtracted bloon colours on YOUR track
//     -> send detection: colours the round does not schedule are their sends
//     -> HUD OCR (throttled): round, your cash/eco, both lives, send cards
//     -> income model: their eco, income, spend, and a cash ceiling
//     -> click-through overlay
//
// Usage:
//   ./tracker                 run with the overlay
//   ./tracker --headless      console only
//   ./tracker --log run.csv   also write a per-second CSV for tuning

import Foundation
import AppKit
import ScreenCaptureKit
import ImageIO

struct Options {
    var headless = false
    var logPath: String?
    var fps = 10
    var dataPath = "../data/btd6_derived_rounds.json"
    /// Skip panel detection and force an orientation. Mainly for exercising the
    /// mirrored path, which no captured frame exhibits.
    var forcedSide: PlayerSide?
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--headless": o.headless = true
        case "--log":      o.logPath = it.next()
        case "--fps":      o.fps = Int(it.next() ?? "10") ?? 10
        case "--data":     o.dataPath = it.next() ?? o.dataPath
        case "--replay":   _ = it.next()   // handled before startup
        case "--visible-fraction":
            if let v = Double(it.next() ?? "") { SendDetector.visibleFraction = v }
        case "--side":
            let v = it.next() ?? ""
            guard let s = PlayerSide(rawValue: v.lowercased()) else {
                FileHandle.standardError.write("--side takes left or right, got \"\(v)\"\n".data(using: .utf8)!)
                exit(2)
            }
            o.forcedSide = s
        default: FileHandle.standardError.write("unknown arg: \(a)\n".data(using: .utf8)!)
        }
    }
    return o
}

let opts = parseOptions()

// Resolve the round table relative to the binary if the default path misses.
func resolveDataPath(_ p: String) -> String? {
    if FileManager.default.fileExists(atPath: p) { return p }
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent().standardizedFileURL
    for candidate in ["../data/btd6_derived_rounds.json", "data/btd6_derived_rounds.json"] {
        let u = exeDir.appendingPathComponent(candidate).standardizedFileURL
        if FileManager.default.fileExists(atPath: u.path) { return u.path }
    }
    return nil
}

guard let dataPath = resolveDataPath(opts.dataPath), let roundData = RoundData(path: dataPath) else {
    print("""
    Could not load the round table.
    Expected data/btd6_derived_rounds.json next to the tracker directory.
    """)
    exit(1)
}
print("round table: \(roundData.loadedRounds) rounds from \(dataPath)")

let hud = HUDReader()
let detector = SendDetector(roundData: roundData, fps: opts.fps)
let towers = TowerWatcher(fps: opts.fps)
let model = IncomeModel(roundData: roundData)
let capture = WindowCapture()
let sideDetector = SideDetector()
var sideWarned = false

var overlay: OverlayPanel?
var logHandle: FileHandle?
if let lp = opts.logPath {
    FileManager.default.createFile(atPath: lp, contents: nil)
    logHandle = FileHandle(forWritingAtPath: lp)
    // Raw per-type track counts are included so the pixels-per-bloon constant
    // and the eco tick can be fitted from a real match afterwards.
    // `side` is appended last so existing column indices stay put. It is empty
    // until the side latches, so a row can never claim an orientation that was
    // merely the default rather than a decision.
    logHandle?.write("t,round,my_cash,my_eco,opp_eco,opp_eco_income,opp_send_spend,opp_tower_spend,opp_cash,opp_cash_ceiling,sends,tick_period,payout_ratio,trk_red,trk_blue,trk_green,trk_yellow,trk_pink,side\n".data(using: .utf8)!)
}

// Shared state between the capture queue and the main thread.
final class State: @unchecked Sendable {
    var latest: HUDSnapshot = HUDSnapshot()
    var frameCount = 0
    var gameFrame: CGRect = .zero
    var lastEventText: [String] = []
    var started = Date()
    let lock = NSLock()

    /// Scoped variant — safe to call from async contexts, unlike bare lock().
    func withLock<T>(_ body: (State) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(self)
    }
}
let state = State()

let ocrEveryNFrames = max(1, opts.fps / 3)   // HUD numbers need ~3Hz, not 10

@Sendable func formatMoney(_ v: Double) -> String {
    v >= 10000 ? String(format: "$%.1fk", v / 1000) : String(format: "$%.0f", v)
}

@Sendable func buildOverlayLines() -> [OverlayLine] {
    state.lock.lock(); defer { state.lock.unlock() }
    let b = model.books
    let snap = state.latest
    var lines: [OverlayLine] = []

    let opp = (snap.oppName?.isEmpty == false) ? snap.oppName! : "opponent"
    lines.append(OverlayLine(text: "\(opp.prefix(22))  ·  R\(snap.round.map(String.init) ?? "?")", style: .title))

    guard model.isSeeded else {
        lines.append(OverlayLine(text: "waiting for round 1…", style: .dim))
        lines.append(OverlayLine(text: "seeds from your cash/eco at match start", style: .dim))
        return lines
    }

    // Headline pair: what they hold now, and what lands each disbursement —
    // the same number and cadence the game's own eco counter shows.
    lines.append(OverlayLine(text: "cash  \(formatMoney(b.cash))", style: .big))
    lines.append(OverlayLine(text: "eco   \(String(format: "%.0f", b.eco))  →  +\(formatMoney(b.payoutPerTick)) / \(String(format: "%.1fs", b.tickPeriod))", style: .good))
    lines.append(OverlayLine(text: "", style: .dim))
    lines.append(OverlayLine(text: "generated   \(formatMoney(b.totalGenerated))", style: .key))
    lines.append(OverlayLine(text: "into sends  \(formatMoney(b.sendSpend))  (\(String(format: "%.0f%%", b.ecoShare * 100)))", style: .key))
    lines.append(OverlayLine(text: "into towers \(formatMoney(b.towerSpend))  (\(b.buildCount) builds)", style: .key))
    lines.append(OverlayLine(text: "if they'd built nothing: \(formatMoney(b.cashCeiling))", style: .dim))
    lines.append(OverlayLine(text: "tower cost is estimated from footprint", style: .dim))

    if !model.calibrator.calibrated {
        lines.append(OverlayLine(text: "calibrating eco tick (\(model.calibrator.ticksSeen)/3)…", style: .warn))
    } else {
        lines.append(OverlayLine(text: String(format: "tick %.1fs · %.2f$/eco", model.calibrator.period, model.calibrator.payoutRatio), style: .dim))
    }

    let sends = model.recentSends(3)
    if !sends.isEmpty {
        lines.append(OverlayLine(text: "", style: .dim))
        lines.append(OverlayLine(text: "recent sends", style: .title))
        for e in sends {
            let mark = e.confidence < 0.6 ? "?" : ""
            lines.append(OverlayLine(text: "R\(e.round)  \(e.sends)× \(e.type.display)\(mark)", style: .key))
        }
    }
    if b.lowConfidenceSends > 0 {
        lines.append(OverlayLine(text: "? = type also natural this round", style: .dim))
    }
    return lines
}

/// Commit to a side and re-point everything that reads a half of the screen.
@Sendable func latchSide(_ side: PlayerSide, image cg: CGImage, evidence: String) {
    // Whether the top bar mirrors along with the play area is settled by
    // reading, not by assuming — nothing in the captures on hand answers it, and
    // "ROUND n/40" is distinctive enough that only the correct position parses.
    var topBarMirrors = false
    if side == .left {
        if let hit = Regions.roundCandidates.first(where: { hud.probeRound(cg, $0.region) != nil }) {
            topBarMirrors = hit.topBarMirrors
        } else {
            print("  warning: round counter parsed at neither top-bar position — assuming the bar does not mirror")
        }
    }

    state.lock.lock()
    Regions.adopt(side: side, topBarMirrors: topBarMirrors)
    detector.retarget()
    towers.retarget()
    hud.resetHistory()
    state.lock.unlock()

    func span(_ r: HUDRegion) -> String {
        String(format: "x %.3f–%.3f", r.rect.minX, r.rect.maxX)
    }
    print("""
    side: YOU are on the \(side.rawValue.uppercased()) — \(evidence)
      your track   \(span(Regions.myTrack))
      their track  \(span(Regions.oppTrack))
      send panel   \(span(Regions.sendMenu))
      top bar      \(topBarMirrors ? "mirrored with the play area" : "unchanged")
    """)
}

@Sendable func handleFrame(_ frame: Frame) {
    state.lock.lock()
    state.frameCount += 1
    let n = state.frameCount
    state.lock.unlock()

    if n == 1 {
        detector.calibrate(frameWidth: frame.width)
        towers.calibrate(frameWidth: frame.width)
    }

    // Which half of the screen is ours is settled before a single pixel is
    // attributed to anybody. Scanning earlier would only build a background
    // model on a region that is about to move, and scoring earlier would risk
    // crediting the opponent with your own sends.
    if !Regions.latched {
        guard n % ocrEveryNFrames == 0, let cg = frame.makeCGImage() else { return }
        if let forced = opts.forcedSide {
            latchSide(forced, image: cg, evidence: "forced by --side, panel detection skipped")
            return
        }
        let probe = hud.panelHits(cg)
        if let side = sideDetector.observe(left: probe.left, right: probe.right) {
            latchSide(side, image: cg, evidence: sideDetector.evidence)
        } else if !sideWarned, sideDetector.timedOut(after: 20) {
            sideWarned = true
            print("""
            still deciding which side you are on (\(sideDetector.evidence)).
            Expected if you are in a menu or lobby — the shop and send panel are
            not on screen there. Tracking starts once a match does.
            """)
        }
        return
    }

    let counts = detector.scan(frame)

    var snap: HUDSnapshot?
    if n % ocrEveryNFrames == 0, let cg = frame.makeCGImage() {
        snap = hud.read(cg)
    }

    state.lock.lock()
    if let s = snap {
        // Send cards are only re-read when the menu produced a clean parse.
        let keptCards = s.sendCards.isEmpty ? state.latest.sendCards : s.sendCards
        state.latest = s
        state.latest.sendCards = keptCards
    }
    let current = state.latest
    state.lock.unlock()

    // Only score frames that are actually a match in progress. Menus, the
    // lobby, and the post-game screen all contain saturated artwork that reads
    // as bloons and would otherwise credit the opponent with phantom sends.
    guard let round = current.round, round >= 1,
          current.myLives != nil, current.oppLives != nil else { return }

    // Detector and model are written here on the capture queue but read from
    // the timer thread, so both stay under the same lock.
    state.lock.lock()
    detector.noteRound(round)
    detector.setAvailable(cards: current.sendCards)
    let events = detector.update(counts: counts, cards: current.sendCards)
    let build = towers.update(frame, round: round)
    model.noteTowerSpend(total: towers.totalSpend, builds: towers.buildCount)
    model.update(snap: current, events: events)
    state.lock.unlock()

    if let bd = build {
        print("  build: ~\(formatMoney(Double(bd.estimatedCost))) @R\(bd.round) (\(bd.samples) samples)")
    }

    if !events.isEmpty {
        for e in events {
            let tag = e.confidence < 0.6 ? " (low confidence)" : ""
            print("  send: \(e.sends)× \(e.type.display) @R\(e.round)\(tag)")
        }
    }
}

// One-second cadence for the overlay, console summary, and CSV row.
@Sendable func tick() {
    state.lock.lock()
    let b = model.books
    let snap = state.latest
    let gf = state.gameFrame
    let period = model.calibrator.period
    let ratio = model.calibrator.payoutRatio
    let counts = detector.lastCounts
    state.lock.unlock()

    if let o = overlay {
        if gf != .zero { o.reposition(gameFrame: gf) }
        o.render(buildOverlayLines())
    }

    if let lh = logHandle {
        // Built in pieces: one 16-element literal defeats the type checker.
        var fields: [String] = []
        fields.append(String(format: "%.1f", Date().timeIntervalSince(state.started)))
        fields.append(snap.round.map(String.init) ?? "")
        fields.append(snap.myCash.map(String.init) ?? "")
        fields.append(snap.myEco.map { String(format: "%.0f", $0) } ?? "")
        fields.append(String(format: "%.1f", b.eco))
        fields.append(String(format: "%.0f", b.ecoIncome))
        fields.append(String(format: "%.0f", b.sendSpend))
        fields.append(String(format: "%.0f", b.towerSpend))
        fields.append(String(format: "%.0f", b.cash))
        fields.append(String(format: "%.0f", b.cashCeiling))
        fields.append(String(b.sendsDetected))
        fields.append(String(format: "%.2f", period))
        fields.append(String(format: "%.3f", ratio))
        for t in [BloonType.red, .blue, .green, .yellow, .pink] {
            fields.append(String(counts[t] ?? 0))
        }
        fields.append(Regions.latched ? Regions.mySide.rawValue : "")
        lh.write((fields.joined(separator: ",") + "\n").data(using: .utf8)!)
    }
}

// MARK: - replay
//
// Push recorded PNGs through the live pipeline. Validates HUD parsing, send-card
// reading, and the track scan without needing a match in progress. Send timing
// is wall-clock in replay, so burst counts are indicative rather than exact.

func runReplay(_ dir: String) -> Never {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".png") && !$0.contains("annotated") }.sorted()
    guard !files.isEmpty else { print("no PNGs in \(dir)"); exit(1) }
    print("replaying \(files.count) frames from \(dir)\n")

    for (i, f) in files.enumerated() {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(f)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let pb = makePixelBuffer(from: cg), let frame = Frame(pb)
        else { print("\(f): could not decode"); continue }

        if i == 0 {
            detector.calibrate(frameWidth: frame.width)
            towers.calibrate(frameWidth: frame.width)
        }
        let counts = detector.scan(frame)
        let snap = hud.read(cg)
        if let r = snap.round { detector.noteRound(r) }
        detector.setAvailable(cards: snap.sendCards)
        let events = detector.update(counts: counts, cards: snap.sendCards)
        _ = towers.update(frame, round: snap.round ?? 0)
        model.noteTowerSpend(total: towers.totalSpend, builds: towers.buildCount)
        model.update(snap: snap, events: events)

        let cards = snap.sendCards
            .map { "\($0.type.rawValue) x\($0.quantity) +\($0.eco) $\($0.cost)" }
            .joined(separator: ", ")
        let seen = counts.filter { $0.value > 20 }
            .sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue):\($0.value)" }.joined(separator: " ")

        print("\(f)")
        print("  round=\(snap.round.map(String.init) ?? "?") cash=\(snap.myCash.map(String.init) ?? "?") eco=\(snap.myEco.map { String(format: "%.0f", $0) } ?? "?") lives=\(snap.myLives.map(String.init) ?? "?")/\(snap.oppLives.map(String.init) ?? "?")")
        print("  opp=\"\(snap.oppName ?? "")\" me=\"\(snap.myName ?? "")\"")
        if !cards.isEmpty { print("  cards: \(cards)") }
        if !seen.isEmpty  { print("  track: \(seen)") }
        for e in events { print("  >> SEND \(e.sends)x \(e.type.display) conf=\(String(format: "%.2f", e.confidence))") }
    }

    let b = model.books
    print("""

    ── reconstructed opponent books ──
    eco            \(String(format: "%.1f", b.eco))  (+\(formatMoney(b.payoutPerTick)) per \(String(format: "%.1fs", b.tickPeriod)))
    sends detected \(b.sendsDetected) (\(b.lowConfidenceSends) low confidence)
    into sends     \(formatMoney(b.sendSpend))
    into towers    \(formatMoney(b.towerSpend))  (\(b.buildCount) builds)
    generated      \(formatMoney(b.totalGenerated))
    cash           \(formatMoney(b.cash))
    cash ceiling   \(formatMoney(b.cashCeiling))
    eco tick       \(String(format: "%.1fs @ %.2f $/eco", model.calibrator.period, model.calibrator.payoutRatio)) (\(model.calibrator.ticksSeen) ticks, calibrated=\(model.calibrator.calibrated))
    """)
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--replay"),
   idx + 1 < CommandLine.arguments.count {
    runReplay(CommandLine.arguments[idx + 1])
}

// MARK: - startup

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon, never steals focus

Task {
    guard let win = await WindowCapture.findWindow() else {
        print("""
        Battles 2 window not found.
          open steam://run/1276390
        Then start the tracker again.
        """)
        exit(1)
    }
    let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    state.withLock { $0.gameFrame = win.frame }

    do {
        try await capture.start(window: win, fps: opts.fps, scale: scale, onFrame: handleFrame)
    } catch {
        print("could not start capture: \(error)")
        print("Grant Screen Recording in System Settings > Privacy & Security, then retry.")
        exit(1)
    }

    print("tracking \(Int(win.frame.width))x\(Int(win.frame.height)) at \(opts.fps)fps")
    print("reading pixels only — no memory access, no packet capture, no input\n")

    await MainActor.run {
        if !opts.headless {
            let o = OverlayPanel()
            o.reposition(gameFrame: win.frame)
            o.show()
            overlay = o
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in tick() }
        // Follow the window if it is moved or resized.
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task {
                if let w = await WindowCapture.findWindow() {
                    state.withLock { $0.gameFrame = w.frame }
                }
            }
        }
    }
}

app.run()
