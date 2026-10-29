import AppKit
import Combine
import SwiftUI

/// A borderless, transparent panel above the menu bar.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        allowsToolTipsWhenApplicationIsInactive = true   // the app is never active
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    /// Off by default, so clicking the notch never pulls typing away from your app. On
    /// while a tab that takes typing is open (terminal, clipboard search, prompter).
    var allowsKey = false
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Esc closes the notch unless a view inside (the terminal) used the key itself.
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z in text fields (clipboard search, calendar quick add).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditKeys.perform(event, in: self) || super.performKeyEquivalent(with: event)
    }
}

/// Lets the first click on the notch work while another app is active.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Keeps the panel over the notch and decides, on every pointer move, whether the pointer
/// is on the notch and whether the panel takes clicks.
@MainActor
final class NotchWindowController {
    private let model: NotchModel
    private let panel = NotchPanel()
    private let probe = NotchWindowController.makeProbe()
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var bag = Set<AnyCancellable>()
    private var placedMetrics: NotchMetrics?
    private var keyClaimedFor: NotchTab?        // the typing tab the panel last took key for

    init(model: NotchModel) {
        self.model = model
        let host = NotchHostingView(rootView: NotchRootView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.onEscape = { [weak model] in model?.close() }
        // Opening or switching to a typing tab (a hotkey, a click, the menu) asks for key,
        // even when it's already showing: pressing the hotkey again refocuses a pinned notch.
        // Waits a turn, like refresh, so the open and tab changes have landed.
        model.onKeyRequest = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.claimKey() }
            }
        }
    }

    /// The notch panel, for features that host AppKit views in it (the terminal).
    var window: NSPanel { panel }

    func start() {
        layout()
        installMonitors()
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.layout() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) {
            $0.model.activities.pruneExpired()
            $0.layout()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) {
            $0.layout()
        }
        // Typing moved elsewhere without a click (⌘-Tab, Spotlight, the terminal dropdown).
        // Checked a turn later, once key status has settled.
        observe(NotificationCenter.default, NSWindow.didResignKeyNotification, object: panel) { controller in
            DispatchQueue.main.async { [weak controller] in
                MainActor.assumeIsolated { controller?.keyResigned() }
            }
        }
        // objectWillChange fires before the change lands; look again once it has.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &bag)
    }

    /// Places the panel over the notch, or hides it when the built-in display is off.
    func layout() {
        guard let g = NotchGeometry.current() else {
            if model.geometry != nil {
                model.geometry = nil
                Log.notch.info("no notched built-in display; hiding")
            }
            model.close()
            panel.orderOut(nil)
            probe.orderOut(nil)
            placedMetrics = nil
            return
        }
        if model.geometry != g {
            if model.geometry == nil { model.close() }    // never come back already open
            model.geometry = g
            Log.notch.info("notch at \(String(describing: g.notchRect), privacy: .public)")
        }
        guard let m = model.metrics else { return }
        let size = m.window
        let frame = CGRect(x: g.centerX - size.width / 2, y: g.top - size.height,
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        placedMetrics = m
        panel.orderFrontRegardless()
        probe.setFrameOrigin(CGPoint(x: g.screenFrame.minX, y: g.screenFrame.minY))
        probe.orderFrontRegardless()
        // Space membership settles after the notification; read it on the next turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateFullscreenSpace() }
        }
        refresh()
    }

    private func refresh() {
        guard let g = model.geometry, let m = model.metrics else { return }
        if m != placedMetrics { layout(); return }      // settings or tabs changed the panel size
        let p = NSEvent.mouseLocation
        model.pointerMoved(inside: NotchMetrics.pointerIn(m.hoverRect(model.mode, centerX: g.centerX, top: g.top), p))
        let takesClicks = NotchMetrics.pointerIn(m.captureRect(model.mode, centerX: g.centerX, top: g.top), p)
        if panel.ignoresMouseEvents == takesClicks { panel.ignoresMouseEvents = !takesClicks }
        updateSpaces()
        updateKeyboard()
    }

    /// Lets the panel be key while a typing tab is open, and hands typing back to your app
    /// when it closes. The app itself never activates. Key is taken only when a typing tab
    /// comes up (or the shelf starts taking keys), never on a pointer move or an activity
    /// update, so focus you moved elsewhere stays there.
    private func updateKeyboard() {
        if model.wantsKeyboard {
            if !panel.allowsKey { panel.allowsKey = true }
            if keyClaimedFor != model.currentTab { claimKey() }
        } else {
            keyClaimedFor = nil
            guard panel.allowsKey else { return }
            panel.allowsKey = false
            if panel.isKeyWindow {
                // Re-ordering a window that can't be key makes AppKit give key status back
                // to the active app's window.
                panel.orderOut(nil)
                if model.geometry != nil { panel.orderFrontRegardless() }
            }
        }
    }

    private func claimKey() {
        guard model.wantsKeyboard else { return }
        if !panel.allowsKey { panel.allowsKey = true }
        keyClaimedFor = model.currentTab
        if !panel.isKeyWindow { panel.makeKey() }
    }

    /// Losing key on a typing tab closes the notch, as a click elsewhere does; a pinned notch
    /// stays open without it. The resign that `updateKeyboard` causes when handing typing
    /// back happens after `wantsKeyboard` went false, so it's ignored.
    private func keyResigned() {
        guard model.isOpen, model.wantsKeyboard, !model.pinned, !panel.isKeyWindow else { return }
        model.close()
    }

    /// Fullscreen apps hide the notch, except when you open it or something urgent is
    /// waiting (permission requests, meeting alerts). Spaces only show windows that ask for it.
    private func updateSpaces() {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if model.isOpen || model.activities.hasUrgent { behavior.insert(.fullScreenAuxiliary) }
        guard panel.collectionBehavior != behavior else { return }
        panel.collectionBehavior = behavior
        if model.geometry != nil { panel.orderFrontRegardless() }
    }

    /// A 1-pt invisible window that joins every Space except fullscreen ones. When it isn't
    /// on the active Space, a fullscreen app owns the built-in display.
    private static func makeProbe() -> NSPanel {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.alphaValue = 0
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return p
    }

    private func updateFullscreenSpace() {
        let fullscreen = model.geometry != nil && probe.isVisible && !probe.isOnActiveSpace
        if model.inFullscreenSpace != fullscreen { model.inFullscreenSpace = fullscreen }
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                           .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(m) }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard model.isOpen, !model.pinned, let g = model.geometry, let m = model.metrics else { return }
            if !NotchMetrics.pointerIn(m.captureRect(.open, centerX: g.centerX, top: g.top), NSEvent.mouseLocation) {
                model.close()
            }
        default:
            refresh()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
                         _ action: @escaping (NotchWindowController) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }
}
