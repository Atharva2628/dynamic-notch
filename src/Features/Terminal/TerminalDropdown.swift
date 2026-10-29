import AppKit
import SwiftUI

/// The menu bar dropdown's window: borderless, never activates the app, on every Space
/// including fullscreen ones. It takes typing while shown, so the terminal works while
/// the app you were in stays active.
final class TerminalDropdownPanel: NSPanel {
    /// Command-key shortcuts; there's no main menu to route them.
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 720, height: 420),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        worksWhenModal = true
        allowsToolTipsWhenApplicationIsInactive = true   // the app is never active
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc belongs to the shell; it never closes the dropdown.
    override func cancelOperation(_ sender: Any?) {}

    /// Typing while a dropdown tab (Usage) shows reaches nothing; no beep.
    override func keyDown(with event: NSEvent) {}
}

/// Shows, hides, places and resizes the dropdown, and hides it on a click elsewhere
/// unless it's pinned.
@MainActor
final class TerminalDropdownController {
    let panel = TerminalDropdownPanel()
    private let store: TerminalStore
    private let statusButtonFrame: () -> CGRect?
    private var monitors: [Any] = []
    private var resizeStart: (mouse: CGPoint, frame: CGRect)?

    /// Called with the final size after a resize, to remember it.
    var onResized: ((CGSize) -> Void)?
    /// Called when a click elsewhere hid the panel.
    var onHidden: (() -> Void)?

    init(store: TerminalStore, statusButtonFrame: @escaping () -> CGRect?) {
        self.store = store
        self.statusButtonFrame = statusButtonFrame
        let host = NotchHostingView(rootView: TerminalDropdownView(store: store))
        host.sizingOptions = []
        // The terminal is an AppKit view, which SwiftUI's clip shape doesn't reach; the
        // layer mask rounds it too.
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }

    /// Places the panel under the menu bar icon and makes it the key window.
    func show(size: CGSize) {
        let wasVisible = panel.isVisible
        place(size: size)
        if !wasVisible {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.invalidateShadow()
        installMonitors()
    }

    func hide() {
        removeMonitors()
        resizeStart = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Resizes a visible panel to `size` (settings reloaded), without taking focus.
    func apply(size: CGSize) {
        guard panel.isVisible, resizeStart == nil,
              abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 else { return }
        place(size: size)
        panel.invalidateShadow()
    }

    private func place(size: CGSize) {
        let anchor = statusButtonFrame()
        guard let screen = Self.screen(for: anchor) else { return }
        let frame = TerminalPlacement.dropdownFrame(size: size, anchor: anchor, visible: screen.visibleFrame)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Follows the grip with the pointer; screen coordinates, so the moving window
    /// doesn't skew the drag.
    func resize(_ phase: TerminalResizePhase) {
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .began:
            resizeStart = (mouse, panel.frame)
        case .changed:
            guard let start = resizeStart, let screen = panel.screen ?? Self.screen(for: start.frame) else { return }
            let visible = screen.visibleFrame
            let frame = TerminalPlacement.resized(start: start.frame, dx: mouse.x - start.mouse.x,
                                                  dy: start.mouse.y - mouse.y, visible: visible)
            if frame != panel.frame {
                panel.setFrame(frame, display: true)
                panel.invalidateShadow()
            }
        case .ended:
            guard resizeStart != nil else { return }
            resizeStart = nil
            onResized?(panel.frame.size)
        }
    }

    // MARK: Click elsewhere

    /// Global: clicks in other apps. Local: clicks in this app's other windows (the
    /// notch), except on the menu bar icon, whose own click toggles the panel.
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedElsewhere() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.localClick(in: event.window) }
            return event
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    private func localClick(in window: NSWindow?) {
        guard window !== panel else { return }
        if let icon = statusButtonFrame(), icon.contains(NSEvent.mouseLocation) { return }
        clickedElsewhere()
    }

    private func clickedElsewhere() {
        guard panel.isVisible, !store.pinned, resizeStart == nil else { return }
        hide()
        onHidden?()
    }

    /// The screen holding `rect` (the menu bar icon), else the one under the pointer.
    private static func screen(for rect: CGRect?) -> NSScreen? {
        if let rect {
            let point = CGPoint(x: rect.midX, y: rect.midY)
            if let s = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) { return s }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
