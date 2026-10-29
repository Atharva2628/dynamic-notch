import AppKit
import Combine
import SwiftUI

/// File shelf: drop files on the notch to hold them, drag them out anywhere. Keeps
/// references (paths, with bookmarks that follow renames and moves), not copies, in
/// shelf.json, so it survives restarts. Files come off it `shelfKeepHours` after they were
/// added (checked at launch, when the Shelf shows and every few minutes); the files
/// themselves are never touched.
@MainActor
final class ShelfFeature: Feature {
    private let context: AppContext
    private let store: ShelfStore
    private let drags: ShelfDragMonitor
    private var keyMonitor: Any?
    private var bag = Set<AnyCancellable>()
    private var shelfShowing = false
    private var armedKeyboard = false
    private var airDropReturn: ShelfAirDropReturn?
    private var expiryTimer: Timer?
    /// Seconds between checks for files that have been on the shelf long enough.
    private static let expiryCheck: TimeInterval = 300

    init(context: AppContext) {
        self.context = context
        store = ShelfStore(fileURL: context.dataURL("shelf.json"))
        drags = ShelfDragMonitor(model: context.model, store: store)
    }

    private var model: NotchModel { context.model }

    func start() {
        store.keepFor = ShelfStore.keepFor(hours: context.config.shelfKeepHours)
        store.load()
        let store = self.store
        let actions = makeActions()
        context.registerTab(.shelf) { ShelfTabView(store: store, actions: actions) }
        model.onTabShown[.shelf] = { [weak store] in
            store?.removeExpired()
            store?.pruneMissing()
        }
        // $config fires before the model's value changes, so the new value is used.
        model.$config
            .map(\.shelfKeepHours)
            .removeDuplicates()
            .sink { [weak store] hours in
                MainActor.assumeIsolated {
                    store?.keepFor = ShelfStore.keepFor(hours: hours)
                    store?.removeExpired()
                }
            }
            .store(in: &bag)
        let timer = Timer(timeInterval: Self.expiryCheck, repeats: true) { [weak store] _ in
            MainActor.assumeIsolated { store?.removeExpired() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
        // Files dropped anywhere on the open panel (tab icons, margins) land here too.
        model.panelDrop[.shelf] = { [weak store] providers in store?.addDropped(providers) ?? false }
        context.addToShelf = { [weak self] urls in self?.addFromFeature(urls) }
        drags.start()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
        // objectWillChange fires before the change lands; look once it has.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.modelChanged() } }
            .store(in: &bag)
    }

    func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        drags.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        bag.removeAll()
        disarmKeyboard()
        context.addToShelf = nil
        model.onTabShown[.shelf] = nil
        model.panelDrop[.shelf] = nil
        context.activities.removeAll(prefix: "shelf.")
        store.flush()
    }

    // MARK: Actions

    private func makeActions() -> ShelfActions {
        ShelfActions(
            airDrop: { [weak self] urls in self?.airDrop(urls) },
            copy: { urls in Self.copy(urls) },
            reveal: { [weak self] urls in
                guard !urls.isEmpty else { return }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                self?.closePanel()
            },
            open: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.closePanel()
            },
            tileClicked: { [weak self] in self?.armKeyboard() })
    }

    /// The AirDrop window belongs to this app, which is otherwise never active, so it comes
    /// forward for it; the app you were in gets activation back once that window closes.
    private func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            ShelfLog.logger.error("AirDrop isn't available for these files")
            return
        }
        closePanel()
        let front = NSWorkspace.shared.frontmostApplication
        let back = ShelfAirDropReturn(previous: front?.processIdentifier == getpid() ? nil : front) { [weak self] in
            self?.airDropReturn = nil
        }
        airDropReturn = back                  // the service holds its delegate weakly
        service.delegate = back
        NSApp.activate()
        service.perform(withItems: urls)
    }

    /// Puts the files on the clipboard as files, as Finder's Copy does.
    static func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    private func closePanel() {
        if !model.pinned { model.close() }
    }

    /// Other features (downloads) add files here. A short note shows in the notch unless the
    /// Shelf is already in view.
    private func addFromFeature(_ urls: [URL]) {
        let added = store.add(urls)
        guard added > 0, !(model.isOpen && model.currentTab == .shelf) else { return }
        context.activities.post(Activity(
            id: "shelf.added", priority: .transient, symbol: "tray.and.arrow.down.fill",
            accessory: .text("\(store.items.count)"),
            title: added == 1 ? "Added to Shelf" : "Added \(added) files to Shelf",
            subtitle: added == 1 ? store.items.first?.name : nil,
            duration: 2, opensTab: .shelf))
    }

    // MARK: Keyboard

    /// After a click on a tile the panel takes keys, so ⌘A selects every file. Leaving with
    /// the pointer still closes it, as on any non-typing tab.
    private func armKeyboard() {
        guard !model.keyOnlyTabs.contains(.shelf) else { return }
        model.keyOnlyTabs.insert(.shelf)
        armedKeyboard = true
        model.objectWillChange.send()      // the window controller re-checks key status on changes
    }

    private func disarmKeyboard() {
        guard armedKeyboard else { return }
        armedKeyboard = false
        model.keyOnlyTabs.remove(.shelf)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard model.isOpen, model.currentTab == .shelf, event.window === context.notchWindow,
              Self.isSelectAll(event.modifierFlags, event.charactersIgnoringModifiers) else { return false }
        store.selectAll()
        return true
    }

    /// ⌘A, whatever Caps Lock and the Fn key are doing.
    nonisolated static func isSelectAll(_ flags: NSEvent.ModifierFlags, _ characters: String?) -> Bool {
        flags.intersection([.command, .shift, .option, .control]) == .command && characters?.lowercased() == "a"
    }

    /// When the Shelf leaves the screen (the panel closes or another tab shows), the
    /// selection is forgotten and the panel stops taking keys for it.
    private func modelChanged() {
        let showing = model.isOpen && model.currentTab == .shelf
        defer { shelfShowing = showing }
        guard shelfShowing, !showing else { return }
        store.deselectAll()
        disarmKeyboard()
    }

    // MARK: Self-test

    static func selfTest(_ check: (Bool, String) -> Void) {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)      // whole seconds survive ISO 8601
        func file(_ path: String) -> URL { URL(filePath: path, directoryHint: .notDirectory) }
        let a = file("/shelf-selftest/a.txt"), b = file("/shelf-selftest/b.png")

        // Adding.
        var items = ShelfStore.adding([a, b, a], to: [], now: t0)
        check(items.map(\.path) == [a.path, b.path], "shelf: a drop keeps its order and drops repeats")
        items = ShelfStore.adding([file("/shelf-selftest/x/../b.png"), file("/shelf-selftest/c")], to: items, now: t0)
        check(items.map(\.path) == ["/shelf-selftest/c", a.path, b.path],
              "shelf: new files go first; one already there keeps its place, however it's spelled")
        check(ShelfStore.adding([URL(string: "https://example.com/f.pdf")!], to: items, now: t0) == items,
              "shelf: web links are ignored")

        // Selection.
        var selection = ShelfSelection()
        selection.toggle(a.path)
        selection.toggle(b.path)
        selection.toggle(a.path)
        check(selection.ids == [b.path], "shelf: a click selects a tile, a second click deselects it")
        check(ShelfSelection().targets(in: items) == items, "shelf: with nothing selected, actions take every file")
        selection.selectAll(items)
        check(selection.targets(in: items) == items, "shelf: ⌘A selects every file, in shelf order")
        selection.retain(Array(items.dropFirst()))
        check(selection.count == items.count - 1 && !selection.contains(items[0].id),
              "shelf: files that leave the shelf leave the selection")
        check(isSelectAll([.command, .capsLock], "A") && !isSelectAll([.command, .shift], "a")
              && !isSelectAll([], "a"), "shelf: only ⌘A selects all")

        // The store, in memory.
        let store = ShelfStore(fileURL: nil, live: false)
        check(store.add([a, b]) == 2 && store.add([a]) == 0, "shelf: adding counts only new files")
        store.toggle(a.path)
        store.remove([a.path])
        let afterRemove = store.items.map(\.path) == [b.path] && store.selection.isEmpty
        store.clear()
        check(afterRemove && store.items.isEmpty, "shelf: Remove takes a selected file off the selection; Clear empties it")

        // Clearing after a while: off the shelf only, by when each file was added.
        let day: TimeInterval = 24 * 3600
        let fresh = ShelfItem(path: "/shelf-selftest/fresh.txt", added: t0.addingTimeInterval(-day + 60))
        let stale = ShelfItem(path: "/shelf-selftest/stale.txt", added: t0.addingTimeInterval(-day))
        check(ShelfStore.expired([fresh, stale], keepFor: day, now: t0) == [stale.id],
              "shelf: a file comes off 24 hours after it was added, not before")
        check(ShelfStore.keepFor(hours: 24) == day && ShelfStore.keepFor(hours: 0) == nil,
              "shelf: shelfKeepHours 0 keeps files until removed")
        let aging = ShelfStore(fileURL: nil, live: false, items: [fresh, stale])
        aging.toggle(stale.id)
        aging.removeExpired(now: t0)
        let keptWithoutLimit = aging.items == [fresh, stale]
        aging.keepFor = day
        aging.removeExpired(now: t0)
        check(keptWithoutLimit && aging.items == [fresh] && aging.selection.isEmpty,
              "shelf: expired files leave the shelf and the selection; with no limit set, nothing leaves")

        // Following moves, with stand-ins for bookmarks.
        let old = ShelfItem(path: "/shelf-selftest/old.txt", added: t0, bookmark: Data([1]))
        let deleted = ShelfItem(path: "/shelf-selftest/deleted.txt", added: t0, bookmark: Data([2]))
        let unplugged = ShelfItem(path: "/Volumes/ShelfSelfTest-none/clip.mov", added: t0, bookmark: Data([3]))
        let move = ShelfMove(path: "/shelf-selftest/new.txt", bookmark: Data([4]))
        let moves = ShelfStore.scan([old, deleted, unplugged], exists: { _ in false },
                                    resolve: { $0.id == deleted.id ? nil : move })
        check(moves.moved == [old.id: move] && moves.missing == [deleted.id] && moves.offline == [unplugged.id],
              "shelf: a renamed file is followed, a deleted one pruned, one on a disconnected drive kept as is")
        let plain = ShelfItem(path: b.path, added: t0)
        let followed = ShelfStore.moving([plain, old], [old.id: move])
        check(followed.map(\.path) == [b.path, move.path] && followed[1].bookmark == move.bookmark,
              "shelf: a moved file keeps its place under its new path, with the fresh bookmark")
        let merged = ShelfStore.moving([ShelfItem(path: move.path, added: t0), plain, old], [old.id: move])
        check(merged.map(\.path) == [move.path, b.path] && merged[0].bookmark == move.bookmark,
              "shelf: a moved file that's on the shelf again merges into that one")
        check(ShelfStore.storing([b.path: Data([5]), old.id: Data([6])], in: [plain, old]).map(\.bookmark)
              == [Data([5]), Data([1])], "shelf: new bookmarks go only to files that have none")
        var movedSelection = ShelfSelection()
        movedSelection.toggle(old.id)
        movedSelection.toggle(b.path)
        movedSelection.follow([old.id: move.path])
        check(movedSelection.ids == [move.path, b.path], "shelf: a selected file that moves stays selected")

        // Pruning and saving, in a temporary folder.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("shelf-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let kept = dir.appendingPathComponent("kept.txt"), gone = dir.appendingPathComponent("gone.txt")
            let folder = dir.appendingPathComponent("Folder", isDirectory: true)
            try Data("kept".utf8).write(to: kept)
            try Data("gone".utf8).write(to: gone)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var saved = ShelfStore.adding([kept, gone, folder], to: [], now: t0)
            try fm.removeItem(at: gone)
            let drive = "/Volumes/ShelfSelfTest-\(UUID().uuidString)/clip.mov"
            saved.append(ShelfItem(path: drive, added: t0))
            let scan = ShelfStore.scan(saved, exists: ShelfStore.fileExists)
            check(scan.missing == [saved[1].id], "shelf: deleted files are pruned, files and folders still there stay")
            check(scan.offline == [drive], "shelf: files on a disconnected drive are kept, not pruned")
            let locked = ShelfStore.scan(saved, exists: { $0 == saved[0].path ? nil : ShelfStore.fileExists($0) })
            check(!locked.missing.contains(saved[0].id) && !locked.offline.contains(saved[0].id),
                  "shelf: a file in a folder this app may not read is kept, not pruned")

            if let reference = (kept as NSURL).fileReferenceURL(), let back = ShelfStore.pathURL(reference) {
                check(!back.path.hasPrefix("/.file/") && back.lastPathComponent == "kept.txt"
                      && ShelfStore.pathURL(kept) == kept,
                      "shelf: a dropped file reference URL is kept as the file's path; path URLs are untouched")
            } else {
                check(false, "shelf: file reference URL for a temporary file")
            }

            let original = dir.appendingPathComponent("original.txt"), renamed = dir.appendingPathComponent("renamed.txt")
            try Data("move".utf8).write(to: original)
            var marked = ShelfItem(path: original.path, added: t0)
            marked.bookmark = ShelfStore.makeBookmarks(for: [marked])[marked.id]
            try fm.moveItem(at: original, to: renamed)
            let found = ShelfStore.resolveBookmark(marked).map { URL(filePath: $0.path).resolvingSymlinksInPath().path }
            check(marked.bookmark != nil && found == renamed.resolvingSymlinksInPath().path,
                  "shelf: a bookmarked file is found again after a rename")
            let trash = dir.appendingPathComponent(".Trash", isDirectory: true)
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)
            try fm.moveItem(at: renamed, to: trash.appendingPathComponent("renamed.txt"))
            check(ShelfStore.resolveBookmark(marked) == nil, "shelf: a file moved to the Trash counts as deleted")

            let json = JSONFile<[ShelfItem]>(url: dir.appendingPathComponent("shelf.json"))
            let before = json.load()
            json.save(saved)
            check(before == nil && json.load() == saved, "shelf: items survive a save and load; no file loads as nothing")
        } catch {
            check(false, "shelf: temporary folder (\(error.localizedDescription))")
        }

        // Drags.
        var tracker = ShelfDragTracker()
        tracker.mouseDown(changeCount: 5, onOpenPanel: false)
        check(!tracker.dragged(inZone: true, changeCount: { 5 }, carriesFiles: { true }),
              "shelf: moving a window over the notch doesn't open the Shelf, whatever an old drag left")
        check(!tracker.dragged(inZone: false, changeCount: { 6 }, carriesFiles: { true }),
              "shelf: a file drag away from the notch doesn't open it")
        check(tracker.dragged(inZone: true, changeCount: { 6 }, carriesFiles: { true }) && tracker.reached,
              "shelf: a file drag reaching the notch opens the Shelf")
        check(!tracker.dragged(inZone: false, changeCount: { 6 }, carriesFiles: { true }) && tracker.reached
              && tracker.dragged(inZone: true, changeCount: { 6 }, carriesFiles: { true }),
              "shelf: a file drag that leaves and comes back opens it again")
        tracker.mouseUp()
        check(!tracker.reached && !tracker.watching, "shelf: releasing the button ends the drag")
        tracker.mouseDown(changeCount: 6, onOpenPanel: false)
        check(!tracker.dragged(inZone: true, changeCount: { 7 }, carriesFiles: { false }) && !tracker.watching,
              "shelf: a text drag doesn't open it, and its later events are skipped")
        tracker.mouseDown(changeCount: 7, onOpenPanel: true)
        check(!tracker.dragged(inZone: true, changeCount: { 8 }, carriesFiles: { true }),
              "shelf: dragging a tile out of the open panel doesn't reopen it")
        check(ShelfDragTracker.baseline(live: 9, idle: 3, lag: 0.002) == 9
              && ShelfDragTracker.baseline(live: 9, idle: 3, lag: -0.001) == 9,
              "shelf: a press handled promptly measures from its own read, whatever a missed mouse-up left")
        let lateBaseline = ShelfDragTracker.baseline(live: 9, idle: 8, lag: 0.05)
        tracker.mouseDown(changeCount: lateBaseline, onOpenPanel: false)
        check(lateBaseline == 8 && tracker.dragged(inZone: true, changeCount: { 9 }, carriesFiles: { true }),
              "shelf: a press handled late still sees its own quick drag")

        let m = NotchMetrics(notch: CGSize(width: 179, height: 32), panel: CGSize(width: 806, height: 250))
        if let g = NotchGeometry.compute(screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                         safeTop: 32, leftWidth: 645.5, rightWidth: 645.5) {
            let zone = ShelfDragZone.rect(m, g)
            check(NotchMetrics.pointerIn(zone, CGPoint(x: 735, y: 956))
                  && NotchMetrics.pointerIn(zone, CGPoint(x: 735 - 89.5 - NotchMetrics.ear, y: 940)),
                  "shelf: the drop zone covers the notch and its ears")
            check(!NotchMetrics.pointerIn(zone, CGPoint(x: 735, y: 800)) && !NotchMetrics.pointerIn(zone, CGPoint(x: 200, y: 950)),
                  "shelf: the drop zone stays near the notch")
        } else {
            check(false, "shelf: sample notch geometry")
        }
    }

    // MARK: Snapshots

    static func snapshotViews() -> [(name: String, view: AnyView)] {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let names = ["Pitch deck.pdf", "Screenshot 2026-10-26 at 10.41.22.png", "teleprompter.md", "build.zip",
                     "Invoices", "demo take 3.mov", "notes.txt", "logo.svg", "SwiftTerm.zip"]
        let items = names.enumerated().map { i, name in
            ShelfItem(path: "/Users/sample/Desktop/" + name, added: t0.addingTimeInterval(Double(-60 * i)))
        }
        let full = ShelfStore(fileURL: nil, live: false, items: items)
        full.toggle(items[1].id)
        full.toggle(items[3].id)
        let empty = ShelfStore(fileURL: nil, live: false)

        func sized(_ store: ShelfStore) -> AnyView {
            AnyView(ShelfTabView(store: store, scrolls: false)
                .frame(width: 758, height: 186)
                .background(Color.black)
                .environment(\.colorScheme, .dark))
        }
        return [("shelf-tab", sized(full)), ("shelf-empty", sized(empty))]
    }
}

/// Gives activation back to the app you were in once the AirDrop window closes, whether
/// the files were sent or not.
@MainActor
private final class ShelfAirDropReturn: NSObject, NSSharingServiceDelegate {
    private let previous: NSRunningApplication?
    private let done: () -> Void

    init(previous: NSRunningApplication?, done: @escaping () -> Void) {
        self.previous = previous
        self.done = done
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish()
    }

    /// Only while this app is still the active one: if you switched apps meanwhile, that stays.
    private func finish() {
        if NSApp.isActive, let previous, !previous.isTerminated {
            _ = previous.activate(from: .current, options: [])
        }
        done()
    }
}
