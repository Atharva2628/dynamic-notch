import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Clipboard history: records each copy, lists them in the Clipboard tab and on Home, and
/// copies one back, optionally pasting it into the front app.
@MainActor
final class ClipboardFeature: Feature {
    private let context: AppContext
    let store: ClipboardStore
    let state = ClipboardViewState()
    private let watcher = ClipboardWatcher()
    private let menuTarget = ClipboardMenuTarget()
    private var pauseItem: NSMenuItem?
    private var hotkeyID: UInt32?
    private var hotkeyText: String?
    private var keyMonitor: Any?
    private var bag = Set<AnyCancellable>()
    private var stopped = false
    private var toldAboutAccessibility = false
    private var toldAboutAccess = false
    private var caretToEndOnFocus = false
    /// The last auto-paste setting seen; nil until the first config arrives at launch.
    private var autoPaste: Bool?
    /// Bumped by each copy request and by Esc or the hotkey, so a copy that finishes late
    /// pastes only if nothing came after it.
    private var copyGeneration = 0

    private static let accessActivityID = "clipboard.access"

    /// Taken when a copy is asked for: which request it was, and the app the paste is for.
    /// The panel never activates, so that's the app in front.
    private struct CopyRequest {
        let generation: Int
        let target: pid_t?
    }

    init(context: AppContext) {
        self.context = context
        store = ClipboardStore(fileURL: context.dataURL("clipboard.json"),
                               imagesDirectory: context.dataURL("clipboard-images/"),
                               limit: context.config.clipboardLimit)
    }

    func start() {
        let actions = ClipboardActions(
            copy: { [weak self] in self?.copy($0) },
            remove: { [weak self] in self?.delete($0) },
            togglePin: { [weak self] in self?.store.togglePin(id: $0) },
            open: { [weak self] in self?.open($0) },
            showTab: { [weak self] in self?.context.model.select(.clipboard) },
            searchFocused: { [weak self] in self?.searchDidFocus() },
            openPrivacySettings: { Self.openPrivacySettings() },
            clear: { [weak self] in self?.clearHistory() })
        let store = store, state = state
        context.registerTab(.clipboard) { ClipboardTabView(store: store, state: state, actions: actions) }
        context.registerHomeCard { ClipboardHomeCard(store: store, state: state, actions: actions) }
        context.model.onTabShown[.clipboard] = { [weak self] in
            self?.caretToEndOnFocus = false
            self?.state.prepareForShow()
            self?.watcher.checkAccess()
        }

        // Fires now with the current settings, then on every change (hotkey, limit).
        context.model.$config
            .sink { [weak self] config in MainActor.assumeIsolated { self?.apply(config) } }
            .store(in: &bag)
        // The Home card and the tab show whether macOS lets history read copies; look again
        // each time the notch opens, so that clears as soon as the setting changes.
        context.model.$isOpen
            .filter { $0 }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.watcher.checkAccess() } }
            .store(in: &bag)
        installKeyMonitor()
        addMenu()

        watcher.onCapture = { [weak self] capture, source in self?.record(capture, source: source) }
        watcher.onAccessChange = { [weak self] access in self?.accessChanged(access) }
        // Read the saved history off the main thread, then start watching.
        let fileURL = store.fileURL, imagesDirectory = store.imagesDirectory
        store.io.async { [weak self] in
            let saved = ClipboardStore.loadSaved(fileURL: fileURL, imagesDirectory: imagesDirectory)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    self.store.restore(saved)
                    self.watcher.start()
                    ClipboardLog.logger.info("watching the clipboard, \(saved.count) saved items")
                }
            }
        }
    }

    func stop() {
        stopped = true
        watcher.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let hotkeyID { context.hotkeys.unregister(hotkeyID) }
        hotkeyID = nil
        bag.removeAll()
        context.model.onTabShown[.clipboard] = nil
        context.activities.removeAll(prefix: "clipboard.")
        store.flush()
    }

    private func apply(_ config: Config) {
        if config.clipboardHotkey != hotkeyText {
            if let hotkeyID { context.hotkeys.unregister(hotkeyID) }
            hotkeyText = config.clipboardHotkey
            hotkeyID = context.hotkeys.register(config.clipboardHotkey) { [weak self] in
                self?.copyGeneration += 1      // a copy still finishing no longer pastes
                self?.context.model.toggle(tab: .clipboard)
            }
        }
        store.limit = max(1, config.clipboardLimit)
        // Turning auto-paste on (not the setting at launch) asks for Accessibility, which
        // also lists the app there.
        if autoPaste == false, config.clipboardAutoPaste, !AXIsProcessTrusted() { Self.requestAccessibility() }
        autoPaste = config.clipboardAutoPaste
    }

    // MARK: Access

    private func accessChanged(_ access: ClipboardAccess) {
        if state.access != access { state.access = access }
        if access == .asks { tellAboutClipboardAccess() } else { context.activities.remove(id: Self.accessActivityID) }
    }

    /// Once per launch: macOS asks before each read, so history is off until Paste from
    /// Other Apps is set to Always Allow. Stays until that changes or it's dismissed.
    private func tellAboutClipboardAccess() {
        guard !toldAboutAccess else { return }
        toldAboutAccess = true
        let id = Self.accessActivityID
        context.activities.post(Activity(
            id: id, priority: .info, symbol: "doc.on.clipboard", tint: .orange, accessory: .symbol("hand.raised.fill"),
            title: "Clipboard history is off", subtitle: "Set Paste from Other Apps to Always Allow",
            actions: [ActivityAction(id: "settings", title: "Open Settings", style: .primary),
                      ActivityAction(id: "dismiss", title: "Later")],
            opensTab: .clipboard)
        ) { [weak self] action in
            if action == "settings" { Self.openPrivacySettings() } else { self?.context.activities.remove(id: id) }
        }
    }

    /// Privacy & Security. The SDK documents no anchor for Paste from Other Apps.
    private static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Recording

    /// Hashing, PNG and thumbnail work happens on the store's queue; the entry lands on main.
    private func record(_ capture: ClipboardCapture, source: String?, retry: Bool = false) {
        let known: Set<String> = retry ? [] : store.fingerprints
        let directory = store.imagesDirectory
        store.io.async { [weak self] in
            let item = ClipboardWatcher.makeItem(capture, source: source, imagesDirectory: directory, known: known)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let item else { return }
                    // The image was in the history when read, but has been dropped since:
                    // read it again, this time saving its file.
                    if item.kind == .image, item.imageFile == nil, !self.store.fingerprints.contains(item.fingerprint) {
                        if !retry { self.record(capture, source: source, retry: true) }
                        return
                    }
                    self.store.add(item)
                }
            }
        }
    }

    // MARK: Copying back

    /// Puts an entry on the pasteboard and moves it to the top. With auto-paste on (and
    /// Accessibility allowed) the notch closes and ⌘V goes to the front app. An image's
    /// file is read on the store's queue first; meanwhile its row is dimmed and other copy
    /// requests are ignored.
    func copy(_ item: ClipboardItem) {
        guard state.copyingID == nil else { return }
        copyGeneration += 1
        let request = CopyRequest(generation: copyGeneration,
                                  target: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        guard item.kind == .image else { finishCopy(item, image: nil, request: request); return }
        guard let url = store.imageURL(for: item) else { copyFailed(item); return }
        state.copyingID = item.id
        store.io.async { [weak self] in
            let image = ClipboardWatcher.imageData(at: url)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    self.state.copyingID = nil
                    if let image { self.finishCopy(item, image: image, request: request) } else { self.copyFailed(item) }
                }
            }
        }
    }

    private func copyFailed(_ item: ClipboardItem) {
        ClipboardLog.logger.error("could not copy back a \(item.kind.rawValue, privacy: .public) item")
        NSSound.beep()
    }

    /// Always copies. Pastes only if the request is still the latest (no Esc, hotkey or
    /// other copy since) and the app it was meant for is still in front; otherwise it just
    /// says "Copied".
    private func finishCopy(_ item: ClipboardItem, image: ClipboardImageData?, request: CopyRequest) {
        guard watcher.write(item, image: image) else { copyFailed(item); return }
        store.touch(id: item.id)
        state.selectedID = nil
        let model = context.model
        let autoPaste = context.config.clipboardAutoPaste
        let pasteWanted = request.generation == copyGeneration
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == request.target
        if autoPaste && pasteWanted {
            if AXIsProcessTrusted() {
                model.close()
                let target = request.target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.pasteIntoFrontApp(target) }
                return
            }
            tellAboutAccessibility()
        }
        let closes = model.isOpen && !model.pinned
        if closes { model.close() }
        if closes || (autoPaste && !pasteWanted) {
            context.activities.post(Activity(
                id: "clipboard.copied", priority: .transient, symbol: "doc.on.clipboard.fill",
                accessory: .symbol("checkmark"), title: "Copied", subtitle: item.previewLine, duration: 1.2))
        }
    }

    /// ⌘V, as if typed, unless another app came to the front meanwhile. Needs
    /// Accessibility; the caller checks.
    private static func pasteIntoFrontApp(_ target: pid_t?) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Once per launch: auto-paste is on but Accessibility isn't allowed, so it only copied.
    private func tellAboutAccessibility() {
        guard !toldAboutAccessibility else { return }
        toldAboutAccessibility = true
        let id = "clipboard.accessibility"
        context.activities.post(Activity(
            id: id, priority: .info, symbol: "keyboard", tint: .orange, accessory: .text("Copied"),
            title: "Auto-paste needs Accessibility", subtitle: "Allow Dynamic Notch in Privacy & Security",
            duration: 10, actions: [ActivityAction(id: "settings", title: "Open Settings", style: .primary),
                                    ActivityAction(id: "dismiss", title: "Later")])
        ) { [weak self] action in
            if action == "settings",
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                Self.requestAccessibility()       // so the app is in the list when the pane opens
                NSWorkspace.shared.open(url)
            }
            self?.context.activities.remove(id: id)
        }
    }

    /// Shows the system's Accessibility prompt and adds the app to that list, switched off.
    /// The literal key avoids the global kAXTrustedCheckOptionPrompt var.
    private static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary)
    }

    /// Opens a link in the browser, or shows files in Finder.
    private func open(_ item: ClipboardItem) {
        switch item.kind {
        case .link:
            guard let url = ClipboardWatcher.link(from: item.text) else { return }
            NSWorkspace.shared.open(url)
        case .files:
            let urls = (item.paths ?? []).map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { NSSound.beep(); return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        default:
            return
        }
        if !context.model.pinned { context.model.close() }
    }

    /// Deletes an entry and selects the one that took its place.
    private func clearHistory() {
        store.clearUnpinned()
        state.selectedID = nil
        state.requestFocus()
    }

    private func delete(_ id: UUID) {
        let visible = ClipboardStore.filter(store.items, query: state.query, pinnedOnly: state.pinnedOnly)
        let index = visible.firstIndex { $0.id == id }
        store.remove(id: id)
        let after = ClipboardStore.filter(store.items, query: state.query, pinnedOnly: state.pinnedOnly)
        if let index, !after.isEmpty { state.selectedID = after[min(index, after.count - 1)].id }
    }

    // MARK: Keyboard

    private static let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// Keys reach the panel only while it's the key window, which core arranges for the
    /// Clipboard tab. The monitor sees them before the search field does.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handleKey(event) == true }
            return used ? nil : event
        }
    }

    /// ↑↓ select, Return copies, ⌘1–9 copies the Nth, ⌘⌦ deletes (⌘⌫ too while the search
    /// is empty; with text it deletes to the start of the line), ⌘P pins, ⌘F searches, Esc
    /// clears the search, then closes. Returns true when the key was used.
    private func handleKey(_ event: NSEvent) -> Bool {
        let model = context.model
        guard model.isOpen, model.currentTab == .clipboard, event.window === context.notchWindow else { return false }
        // While an input method is composing (Japanese, Chinese, …), Return, arrows and
        // Esc belong to it.
        if let editor = context.notchWindow.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = Int(event.keyCode)
        let visible = ClipboardStore.filter(store.items, query: state.query, pinnedOnly: state.pinnedOnly)
        let selected = state.selection(in: visible)

        if flags.isEmpty {
            switch key {
            case kVK_UpArrow: state.move(-1, in: visible)
            case kVK_DownArrow: state.move(1, in: visible)
            case kVK_Return, kVK_ANSI_KeypadEnter: if let selected, !event.isARepeat { copy(selected) }
            case kVK_Escape:
                copyGeneration += 1                // a copy still finishing no longer pastes
                if state.query.isEmpty { model.close() } else { state.query = "" }
            default: return typeIntoSearch(event)
            }
            return true
        }
        if flags == .command {
            if let n = Self.digitKeys.firstIndex(of: key) {
                if n < visible.count { copy(visible[n]) }
                return true
            }
            switch key {
            case kVK_Delete, kVK_ForwardDelete:
                if key == kVK_Delete, let editor = context.notchWindow.firstResponder as? NSTextView, !editor.string.isEmpty {
                    return false                   // let the field run deleteToBeginningOfLine:
                }
                if let selected { delete(selected.id) }
                return true
            default:
                break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "p":
                if let selected { store.togglePin(id: selected.id) }
                return true
            case "f":
                state.requestFocus()
                return true
            default:
                return false
            }
        }
        return flags == .shift ? typeIntoSearch(event) : false
    }

    /// Typing while the search field isn't focused (after a click on a row) still searches.
    private func typeIntoSearch(_ event: NSEvent) -> Bool {
        guard !(context.notchWindow.firstResponder is NSTextView) else { return false }
        if Int(event.keyCode) == kVK_Delete {
            if !state.query.isEmpty { state.query.removeLast() }
        } else {
            guard let chars = event.characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { return false }
            state.query += chars
        }
        caretToEndOnFocus = true
        state.requestFocus()
        return true
    }

    /// The search field just took focus. After typing moved text into it, put the caret at
    /// the end; AppKit selects a field's whole text when it takes focus, so the next key
    /// would replace the query.
    private func searchDidFocus() {
        guard caretToEndOnFocus else { return }
        caretToEndOnFocus = false
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let editor = self?.context.notchWindow.firstResponder as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }

    // MARK: Menu

    private func addMenu() {
        let submenu = NSMenu()
        submenu.addItem(menuTarget.item("Open Clipboard") { [weak self] in self?.context.model.open(tab: .clipboard) })
        let pause = menuTarget.item("Pause History") { [weak self] in self?.togglePause() }
        pauseItem = pause
        submenu.addItem(pause)
        submenu.addItem(.separator())
        submenu.addItem(menuTarget.item("Clear History (Keeps Pins)") { [weak self] in self?.store.clearUnpinned() })
        let root = NSMenuItem(title: "Clipboard", action: nil, keyEquivalent: "")
        root.submenu = submenu
        context.statusItem.extraItems.append(root)
    }

    /// Stops recording until resumed (or the app restarts); copies made meanwhile are never read.
    private func togglePause() {
        state.paused.toggle()
        watcher.paused = state.paused
        pauseItem?.state = state.paused ? .on : .off
        ClipboardLog.logger.info("history \(self.state.paused ? "paused" : "resumed", privacy: .public)")
    }
}

/// Runs a closure per menu item (NSMenuItem needs an Objective-C target).
@MainActor
private final class ClipboardMenuTarget: NSObject {
    private var actions: [() -> Void] = []

    func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions.append(action)
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        if actions.indices.contains(sender.tag) { actions[sender.tag]() }
    }
}

extension ClipboardFeature {
    func debugState() -> [String: Any] { ["items": store.items.count] }
}
