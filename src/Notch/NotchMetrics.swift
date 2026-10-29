import CoreGraphics

enum NotchMode: Equatable {
    case idle       // exactly the hardware notch: invisible
    case hover      // pointer on an empty notch: grows a little
    case compact    // ears beside the notch for the top activity
    case peek       // pointer on a notch with an activity: title and subtitle below
    case open       // the full panel with tabs
}

/// Sizes, corner radii and pointer areas for each mode. Pure, so the self-test can check it.
struct NotchMetrics: Equatable {
    var notch: CGSize
    var panel: CGSize                          // the open panel, including the top fillets
    var peekExtra: CGFloat = NotchMetrics.peekExtraPlain   // height added below the notch when peeking

    static let ear: CGFloat = 76               // width added on each side when compact
    static let peekExtraPlain: CGFloat = 58    // title and subtitle
    static let peekExtraActions: CGFloat = 104 // title, subtitle and a row of buttons
    static let peekExtraDetail: CGFloat = 156  // plus up to 3 monospaced lines (a command)
    static let shadowMargin: CGFloat = 24
    static let idleSlop = CGSize(width: 6, height: 1)   // hover reach around an idle notch: the menu bar strip

    /// Sizes the open panel from settings, then fits it to the screen: wide enough for the
    /// tab icons on both sides of the notch, and never off the screen.
    static func make(geometry g: NotchGeometry, config: Config, tabCount: Int,
                     peekExtra: CGFloat = peekExtraPlain) -> NotchMetrics {
        let notch = g.notchSize
        let maxWidth = g.screenFrame.width - 2 * shadowMargin
        let width = min(max(config.panelWidth, minPanelWidth(notch: notch.width, tabCount: tabCount)), maxWidth)
        let height = min(config.panelHeight, (g.screenFrame.height * 0.75).rounded(.down))
        return NotchMetrics(notch: notch, panel: CGSize(width: width, height: height), peekExtra: peekExtra)
    }

    /// The narrowest panel whose tab strips (30-pt icons, 4-pt gaps, 14-pt margins; see
    /// OpenPanel) fit beside the notch.
    static func minPanelWidth(notch: CGFloat, tabCount: Int) -> CGFloat {
        let perSide = CGFloat((tabCount + 1) / 2)
        let strip = 14 + perSide * 30 + max(0, perSide - 1) * 4
        return notch + 16 + 2 * strip + 2 * fillet(.open)
    }

    /// The black body, without the top fillets.
    func body(_ mode: NotchMode) -> CGSize {
        switch mode {
        case .idle: notch
        case .hover: CGSize(width: notch.width + 8, height: notch.height + 4)
        case .compact: CGSize(width: notch.width + 2 * Self.ear, height: notch.height)
        case .peek:
            // A full command needs room; only while one is shown (an urgent request).
            CGSize(width: peekExtra >= Self.peekExtraDetail ? max(notch.width + 2 * Self.ear, 480) : notch.width + 2 * Self.ear,
                   height: notch.height + peekExtra)
        case .open: CGSize(width: panel.width - 2 * Self.fillet(.open), height: panel.height)
        }
    }

    /// The concave curve where the shape meets the top edge. None when idle: the idle shape
    /// must stay inside the cutout, where the screen has no pixels, so it's invisible.
    static func fillet(_ mode: NotchMode) -> CGFloat { mode == .idle ? 0 : 6 }

    /// The shape's frame: the body plus a fillet on each side.
    func frame(_ mode: NotchMode) -> CGSize {
        let b = body(mode)
        return CGSize(width: b.width + 2 * Self.fillet(mode), height: b.height)
    }

    /// Idle is rounder than the hardware notch, so it never paints the pixels at the
    /// cutout's corners.
    func bottomRadius(_ mode: NotchMode) -> CGFloat {
        switch mode {
        case .idle: 12
        case .hover, .compact: 11
        case .peek: 20
        case .open: 26
        }
    }

    /// The window holds every mode plus room for the shadow. It doesn't depend on the
    /// current peek height, so it never moves while activities come and go.
    var window: CGSize {
        let open = frame(.open), peek = frame(.peek)
        let tallestPeek = notch.height + max(peekExtra, Self.peekExtraDetail)
        return CGSize(width: max(open.width, peek.width) + 2 * Self.shadowMargin,
                      height: max(open.height, tallestPeek) + Self.shadowMargin)
    }

    /// A rect of `size` hanging from the top edge at `centerX`, in screen coordinates.
    static func hanging(_ size: CGSize, centerX: CGFloat, top: CGFloat) -> CGRect {
        CGRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }

    /// Cocoa's mouse-in-rect rule (like NSMouseInRect, unflipped): the top edge counts and
    /// the bottom doesn't. A pointer pushed against the top of the screen sits exactly on
    /// `top`, which CGRect.contains would leave out.
    static func pointerIn(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x < r.maxX && p.y > r.minY && p.y <= r.maxY
    }

    /// Where the pointer counts as "on the notch". Around an idle notch, the menu bar strip
    /// a little past each side; once it grows, the grown shape plus a small margin.
    func hoverRect(_ mode: NotchMode, centerX: CGFloat, top: CGFloat) -> CGRect {
        let idle = Self.hanging(CGSize(width: notch.width + 2 * Self.idleSlop.width,
                                       height: notch.height + Self.idleSlop.height),
                                centerX: centerX, top: top)
        if mode == .idle { return idle }
        let body = Self.hanging(self.body(mode), centerX: centerX, top: top).insetBy(dx: -4, dy: -4)
        return mode == .open ? body : body.union(idle)
    }

    /// Where the window takes clicks: only the shape's body, so menu bar items beside the
    /// notch stay clickable.
    func captureRect(_ mode: NotchMode, centerX: CGFloat, top: CGFloat) -> CGRect {
        Self.hanging(body(mode), centerX: centerX, top: top)
    }
}
