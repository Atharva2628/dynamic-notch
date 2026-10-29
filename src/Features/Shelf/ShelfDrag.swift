import AppKit

/// Follows one mouse press: whether it became a drag carrying files, and whether that drag
/// has reached the notch. Pure, so the self-test can drive it.
struct ShelfDragTracker {
    private var pressCount: Int?          // the drag pasteboard's changeCount at mouse down
    private var ignored = false           // the press began on the open panel (a tile dragged out)
    private var carriesFiles: Bool?       // known once the drag pasteboard has changed
    private(set) var reached = false      // the file drag has been over the drop zone

    /// Whether drag events still matter for this press; false skips them before any work.
    var watching: Bool { pressCount != nil && !ignored && carriesFiles != false }

    /// A new press. Drags that start on the open panel never reopen the Shelf.
    mutating func mouseDown(changeCount: Int, onOpenPanel: Bool) {
        self = ShelfDragTracker()
        pressCount = changeCount
        ignored = onOpenPanel
    }

    /// One drag event. True while a drag carrying files is over the drop zone, so a Shelf
    /// that closed mid-drag opens again when the drag comes back. The pasteboard is read
    /// only near the notch, and its types only once per drag.
    mutating func dragged(inZone: Bool, changeCount: () -> Int, carriesFiles hasFiles: () -> Bool) -> Bool {
        guard inZone, !ignored, let pressCount else { return false }
        if carriesFiles == nil {
            // Unchanged since the press: no drag started (a window or a slider being moved),
            // and whatever the pasteboard holds is from an earlier drag.
            guard changeCount() != pressCount else { return false }
            carriesFiles = hasFiles()
        }
        guard carriesFiles == true else { return false }
        reached = true
        return true
    }

    mutating func mouseUp() { self = ShelfDragTracker() }

    /// A handler that ran within this long of the press read the count before any drag
    /// could start: a drag needs at least one move past the drag threshold first.
    static let promptLag: TimeInterval = 0.008

    /// The changeCount a press is measured against. A prompt handler's fresh read; a late
    /// one may already see this press's drag, so the count from when no button was down
    /// (`idle`) stands in.
    static func baseline(live: Int, idle: Int, lag: TimeInterval) -> Int {
        lag < promptLag ? live : idle
    }
}

enum ShelfDragZone {
    static let margin = CGSize(width: 24, height: 14)

    /// Where a file drag opens the Shelf: the compact notch with its ears, a little wider and
    /// deeper so a quick drag doesn't miss it.
    static func rect(_ m: NotchMetrics, _ g: NotchGeometry) -> CGRect {
        m.hoverRect(.compact, centerX: g.centerX, top: g.top).insetBy(dx: -margin.width, dy: -margin.height)
    }
}

/// Opens the Shelf when a file drag from any app reaches the notch, on any Space, and tells
/// the Shelf while that drag lasts so the whole open panel takes the drop.
@MainActor
final class ShelfDragMonitor {
    private let model: NotchModel
    private let store: ShelfStore
    private let pasteboard = NSPasteboard(name: .drag)
    private var monitors: [Any] = []
    private var tracker = ShelfDragTracker()
    private var releaseTimer: Timer?
    private var openedByDrag = false
    private var restoreTab: NotchTab?    // the tab the open panel showed before the drag switched it
    private var dropsAtStart = 0
    private var idleCount = 0            // the drag pasteboard's changeCount with no button down

    init(model: NotchModel, store: ShelfStore) {
        self.model = model
        self.store = store
    }

    /// Mouse-down and drag events only, so nothing runs while the pointer just moves.
    func start() {
        guard monitors.isEmpty else { return }
        idleCount = pasteboard.changeCount
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(m) }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        releaseTimer?.invalidate()
        releaseTimer = nil
        tracker.mouseUp()
        openedByDrag = false
        restoreTab = nil
        if store.dragInProgress { store.dragInProgress = false }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if tracker.reached { finishDrag() }
            // Handled late (the main thread was busy), the count may already include this
            // press's own drag, so the count from the last idle moment stands in. Where the
            // press happened counts, not where the pointer is by now.
            let live = pasteboard.changeCount
            let lag = ProcessInfo.processInfo.systemUptime - event.timestamp
            if lag < ShelfDragTracker.promptLag { idleCount = live }
            tracker.mouseDown(changeCount: ShelfDragTracker.baseline(live: live, idle: idleCount, lag: lag),
                              onOpenPanel: onOpenPanel(Self.screenLocation(event)))
        case .leftMouseDragged:
            guard tracker.watching else { return }
            let first = !tracker.reached
            guard tracker.dragged(inZone: inZone(NSEvent.mouseLocation), changeCount: { pasteboard.changeCount },
                                  carriesFiles: { Self.carriesFiles(pasteboard) }) else { return }
            if first { reachedNotch() }
            showShelf()
        case .leftMouseUp:
            finishDrag()
        default:
            break
        }
    }

    private nonisolated static func carriesFiles(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// The zone around the notch, plus the whole open panel while the Shelf shows. Never
    /// when the Shelf tab is hidden or there's no notch (lid closed).
    private func inZone(_ p: CGPoint) -> Bool {
        guard model.visibleTabs.contains(.shelf), let g = model.geometry, let m = model.metrics else { return false }
        if NotchMetrics.pointerIn(ShelfDragZone.rect(m, g), p) { return true }
        return model.isOpen && model.currentTab == .shelf
            && NotchMetrics.pointerIn(m.captureRect(.open, centerX: g.centerX, top: g.top), p)
    }

    private var pointerOnOpenPanel: Bool { onOpenPanel(NSEvent.mouseLocation) }

    private func onOpenPanel(_ p: CGPoint) -> Bool {
        guard model.isOpen, let g = model.geometry, let m = model.metrics else { return false }
        return NotchMetrics.pointerIn(m.captureRect(.open, centerX: g.centerX, top: g.top), p)
    }

    /// Where an event happened, in screen points: global events carry them already, local
    /// ones are in their window's coordinates.
    private static func screenLocation(_ event: NSEvent) -> CGPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    /// The first time this drag is over the notch.
    private func reachedNotch() {
        dropsAtStart = store.dropCount
        store.dragInProgress = true
        restoreTab = model.isOpen && model.currentTab != .shelf ? model.currentTab : nil
        // The app running the drag may keep the mouse-up to itself, so watch the button too,
        // from now until it's up.
        releaseTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.finishDrag() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    /// Opens the Shelf, or switches the open panel to it, unless it already shows.
    private func showShelf() {
        guard !(model.isOpen && model.currentTab == .shelf) else { return }
        openedByDrag = true
        model.open(tab: .shelf)
    }

    /// The button is up: the files were dropped somewhere, or the drag was cancelled. Unless
    /// the files landed on the Shelf or the pointer is on it, a panel this drag opened closes
    /// again, and one it switched over goes back to its tab.
    private func finishDrag() {
        let reached = tracker.reached
        tracker.mouseUp()
        idleCount = pasteboard.changeCount   // no drag starts until the next press
        releaseTimer?.invalidate()
        releaseTimer = nil
        if store.dragInProgress { endDropTargetSoon() }
        let opened = openedByDrag, previous = restoreTab
        openedByDrag = false
        restoreTab = nil
        guard reached, opened, store.dropCount == dropsAtStart,
              model.isOpen, model.currentTab == .shelf, !pointerOnOpenPanel else { return }
        if let previous {
            model.select(previous)
        } else if !model.pinned {
            model.close()
        }
    }

    /// The drop can land a moment after the button comes up (the app running the drag
    /// delivers it), so the panel-wide drop target stays on a little longer.
    private func endDropTargetSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.tracker.reached, self.store.dragInProgress else { return }
                self.store.dragInProgress = false
            }
        }
    }
}
