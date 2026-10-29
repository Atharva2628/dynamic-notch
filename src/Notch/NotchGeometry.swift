import AppKit

/// The notch's place on a screen, in global screen coordinates (origin bottom-left).
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchRect: CGRect        // the hardware cutout

    var notchSize: CGSize { notchRect.size }
    var centerX: CGFloat { notchRect.midX }
    var top: CGFloat { screenFrame.maxY }

    /// Pure so it can be checked without a notched screen. `leftWidth` and `rightWidth`
    /// are the widths of the menu bar areas beside the notch (`auxiliaryTopLeftArea` and
    /// `auxiliaryTopRightArea`); `safeTop` is the screen's top safe-area inset.
    static func compute(screenFrame f: CGRect, safeTop: CGFloat,
                        leftWidth: CGFloat?, rightWidth: CGFloat?) -> NotchGeometry? {
        guard safeTop > 0, let l = leftWidth, let r = rightWidth else { return nil }
        let width = f.width - l - r
        guard width >= 40, width <= f.width / 3 else { return nil }
        return NotchGeometry(screenFrame: f,
                             notchRect: CGRect(x: f.minX + l, y: f.maxY - safeTop, width: width, height: safeTop))
    }

    static func forScreen(_ s: NSScreen) -> NotchGeometry? {
        compute(screenFrame: s.frame, safeTop: s.safeAreaInsets.top,
                leftWidth: s.auxiliaryTopLeftArea?.width, rightWidth: s.auxiliaryTopRightArea?.width)
    }

    /// The built-in display's notch, or nil when that display is off (lid closed) or has none.
    /// Read fresh every time: the areas change with display scaling.
    static func current() -> NotchGeometry? {
        for screen in NSScreen.screens where screen.isBuiltIn {
            if let g = forScreen(screen) { return g }
        }
        return nil
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var isBuiltIn: Bool { displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
}

/// `--geometry`: what the app sees on each screen.
@MainActor
enum GeometryReport {
    static func print() {
        let screens = NSScreen.screens
        Swift.print("\(screens.count) screen(s)")
        for s in screens {
            Swift.print("""
            - \(s.localizedName) id=\(s.displayID.map(String.init) ?? "?") builtIn=\(s.isBuiltIn) scale=\(s.backingScaleFactor)
              frame=\(s.frame) visible=\(s.visibleFrame)
              safeTop=\(s.safeAreaInsets.top) left=\(s.auxiliaryTopLeftArea.map { "\($0)" } ?? "nil") right=\(s.auxiliaryTopRightArea.map { "\($0)" } ?? "nil")
              notch=\(NotchGeometry.forScreen(s).map { "\($0.notchRect)" } ?? "none")
            """)
        }
        Swift.print("target: \(NotchGeometry.current().map { "\($0.notchRect)" } ?? "none (built-in display off or no notch)")")
    }
}
