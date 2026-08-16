// The click-through readout pinned to the game window.
//
// A non-activating, mouse-transparent NSPanel: it floats above the game, never
// takes focus, and never eats a click meant for a tower. It tracks the game
// window's frame so it stays put when the window moves.
//
// Numbers are labelled with what they actually are. The cash figure is a
// ceiling, not a balance, and it says so on screen — a tracker that quietly
// presents an estimate as fact is worse than no tracker.

import AppKit

final class OverlayPanel {
    private let panel: NSPanel
    private let textView: NSTextField
    private let width: CGFloat = 268

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let bg = NSVisualEffectView(frame: panel.contentView!.bounds)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.autoresizingMask = [.width, .height]
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true

        textView = NSTextField(labelWithAttributedString: NSAttributedString(string: ""))
        textView.frame = NSRect(x: 12, y: 10, width: width - 24, height: 280)
        textView.autoresizingMask = [.width, .height]
        textView.lineBreakMode = .byWordWrapping
        textView.maximumNumberOfLines = 0

        bg.addSubview(textView)
        panel.contentView = bg
    }

    func show() { panel.orderFrontRegardless() }

    /// Which bottom corner of the game window to sit in.
    ///
    /// The overlay is opaque enough to hide whatever is under it, so it belongs
    /// over the OPPONENT's half: a reconstruction of their books is worth less
    /// than an unobstructed view of your own defence. Which corner that is
    /// depends on the side, so this follows the latch.
    enum Corner { case bottomLeft, bottomRight }

    /// Pin to a bottom corner of the game window, inset from the edge.
    func reposition(gameFrame: CGRect, corner: Corner) {
        guard let screen = NSScreen.main else { return }
        // SCWindow frames are top-left origin; AppKit windows are bottom-left,
        // so gameFrame.maxY is the window's BOTTOM edge and has to be flipped.
        let inset: CGFloat = 14
        let y = screen.frame.height - gameFrame.maxY + inset
        let x: CGFloat
        switch corner {
        case .bottomLeft:  x = gameFrame.minX + inset
        // Never push the panel off the left edge if the window is narrower than
        // the panel itself — a windowed game can be resized to anything.
        case .bottomRight: x = max(gameFrame.minX + inset, gameFrame.maxX - width - inset)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func render(_ lines: [OverlayLine]) {
        let s = NSMutableAttributedString()
        for line in lines { s.append(line.attributed) }
        textView.attributedStringValue = s

        let h = s.boundingRect(with: NSSize(width: width - 24, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        var f = panel.frame
        let newH = ceil(h) + 22
        f.origin.y += f.height - newH
        f.size.height = newH
        panel.setFrame(f, display: true)
        textView.frame = NSRect(x: 12, y: 10, width: width - 24, height: newH - 20)
    }
}

struct OverlayLine {
    enum Style { case title, key, big, dim, warn, good }
    let text: String
    let style: Style

    var attributed: NSAttributedString {
        let (font, color): (NSFont, NSColor) = {
            switch style {
            case .title: return (.systemFont(ofSize: 12, weight: .bold), .white)
            case .big:   return (.monospacedDigitSystemFont(ofSize: 19, weight: .bold), .white)
            case .key:   return (.monospacedDigitSystemFont(ofSize: 12, weight: .medium), NSColor(white: 0.93, alpha: 1))
            case .dim:   return (.systemFont(ofSize: 10, weight: .regular), NSColor(white: 0.62, alpha: 1))
            case .warn:  return (.systemFont(ofSize: 10, weight: .medium), NSColor.systemOrange)
            case .good:  return (.monospacedDigitSystemFont(ofSize: 12, weight: .medium), NSColor.systemGreen)
            }
        }()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 1
        return NSAttributedString(string: text + "\n", attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: para,
        ])
    }
}
