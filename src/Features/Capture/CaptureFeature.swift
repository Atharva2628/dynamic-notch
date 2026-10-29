import AppKit
import Combine
import os

/// Quick Capture: a small box under the notch (hotkey ctrl+alt+n, or "Quick Capture…" in the
/// menu bar menu) that appends what you type to `quickCaptureFile` as an open to-do, then
/// shows "Captured" for 2 s. See `CaptureWriter` for the line format.
@MainActor
final class CaptureFeature: Feature {
    static let log = Logger(subsystem: "local.dynamicnotch", category: "capture")
    static let savedSeconds: Double = 2
    private static let filesAndFolders = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")

    /// The running instance, so other features (the Drafts card) can open the box.
    private(set) static weak var shared: CaptureFeature?
    static var isAvailable: Bool { shared != nil }

    /// Opens the capture box, if the feature is running.
    static func present() { shared?.show() }

    let context: AppContext
    private let menuTarget = CaptureMenuTarget()
    private var menuItem: NSMenuItem?
    private var notchyItem: NSMenuItem?
    private var panel: CapturePanelController?
    private var hotkeyID: UInt32?
    private var hotkeyText: String?
    private var bag = Set<AnyCancellable>()
    private let io = DispatchQueue(label: "local.dynamicnotch.capture", qos: .userInitiated)

    init(context: AppContext) {
        self.context = context
    }

    func start() {
        Self.shared = self
        // Fires now with the current settings, then on every change.
        context.model.$config
            .sink { [weak self] config in MainActor.assumeIsolated { self?.apply(config) } }
            .store(in: &bag)
        // The box sits over the open panel, and a click on the notch is this app's own click,
        // which the box's outside-click monitor doesn't see. Opening the notch hides it.
        context.model.$isOpen
            .filter { $0 }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.panel?.hide() } }
            .store(in: &bag)
        let item = menuTarget.item("Quick Capture…") { [weak self] in self?.show() }
        menuItem = item
        context.statusItem.extraItems.append(item)
        let notchy = menuTarget.item("Import Notchy To-dos") { [weak self] in self?.importNotchyTodos() }
        notchyItem = notchy
        context.statusItem.extraItems.append(notchy)
    }

    func stop() {
        if Self.shared === self { Self.shared = nil }
        if let hotkeyID { context.hotkeys.unregister(hotkeyID) }
        hotkeyID = nil
        bag.removeAll()
        if let menuItem { context.statusItem.extraItems.removeAll { $0 === menuItem } }
        if let notchyItem { context.statusItem.extraItems.removeAll { $0 === notchyItem } }
        menuItem = nil
        notchyItem = nil
        panel?.hide()
        context.activities.removeAll(prefix: "capture.")
    }

    /// The shortcut from settings, trimmed (the settings file isn't). Empty turns it off.
    static func hotkey(in config: Config) -> String {
        config.quickCaptureHotkey.trimmingCharacters(in: .whitespaces)
    }

    private func apply(_ config: Config) {
        let text = Self.hotkey(in: config)
        guard text != hotkeyText else { return }
        if let hotkeyID { context.hotkeys.unregister(hotkeyID) }
        hotkeyID = nil
        hotkeyText = text
        guard !text.isEmpty else { return }
        hotkeyID = context.hotkeys.register(text) { [weak self] in self?.toggle() }
    }

    private var fileURL: URL { Config.expand(context.config.quickCaptureFile) }

    /// Opens the box. The open notch would cover it, so it closes first.
    func show() {
        context.model.close()
        let controller = panel ?? makePanel()
        controller.show(fileName: fileURL.lastPathComponent)
    }

    private func toggle() {
        if panel?.isVisible == true { panel?.hide() } else { show() }
    }

    private func makePanel() -> CapturePanelController {
        let controller = CapturePanelController()
        controller.onSubmit = { [weak self] text in self?.save(text) ?? false }
        panel = controller
        return controller
    }

    /// Writes off the main thread; the result comes back as a "Captured" activity, or an
    /// error with the text put back in the box.
    private func save(_ text: String) -> Bool {
        guard let line = CaptureWriter.line(for: text, at: Date()) else { return false }
        let url = fileURL
        io.async {
            let result = Result { try CaptureWriter.append(line, to: url) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CaptureFeature.shared?.finished(result, text: text, file: url) }
            }
        }
        return true
    }

    /// Both results are urgent, so they show over fullscreen apps too, where the box also
    /// opens: you just pressed Return and expect to see what happened.
    private func finished(_ result: Result<Void, Error>, text: String, file: URL) {
        switch result {
        case .success:
            context.activities.remove(id: "capture.error")
            context.activities.post(Activity(
                id: "capture.saved", priority: .transient, symbol: "square.and.pencil", tint: .green,
                accessory: .symbol("checkmark"), title: "Captured", subtitle: CaptureWriter.clean(text),
                duration: Self.savedSeconds, urgent: true))
        case .failure(let error):
            Self.log.error("could not append to \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            panel?.restore(text)
            // Peeks on its own. When macOS blocked the folder (Documents, say), trying again
            // fails the same way, so the buttons lead to the fix instead.
            let id = "capture.error"
            let blocked = Self.isPermissionError(error)
            let folder = file.deletingLastPathComponent().lastPathComponent
            let actions = blocked
                ? [ActivityAction(id: "privacy", title: "Privacy Settings", style: .primary),
                   ActivityAction(id: "settings", title: "Settings File"),
                   ActivityAction(id: "dismiss", title: "Dismiss")]
                : [ActivityAction(id: "retry", title: "Try Again", style: .primary),
                   ActivityAction(id: "dismiss", title: "Dismiss")]
            context.activities.post(Activity(
                id: id, priority: .info, symbol: "exclamationmark.triangle.fill", tint: .orange,
                title: "Couldn't save to \(file.lastPathComponent)",
                subtitle: blocked ? "macOS blocked access to \(folder)" : error.localizedDescription, duration: 10,
                urgent: true, actions: actions, expands: true)
            ) { [weak self] action in
                self?.context.activities.remove(id: id)
                switch action {
                case "retry": self?.show()
                case "privacy": if let url = Self.filesAndFolders { NSWorkspace.shared.open(url) }
                case "settings": NSWorkspace.shared.open(Config.fileURL)    // to change quickCaptureFile
                default: break
                }
            }
        }
    }

    /// True when the write was refused for lack of permission: a folder macOS guards
    /// (Desktop, Documents, Downloads) that this app wasn't allowed into, or plain file
    /// permissions. Looks through underlying errors too.
    static func isPermissionError(_ error: Error) -> Bool {
        let e = error as NSError
        switch e.domain {
        case NSCocoaErrorDomain where e.code == NSFileWriteNoPermissionError || e.code == NSFileReadNoPermissionError:
            return true
        case NSPOSIXErrorDomain where e.code == Int(EPERM) || e.code == Int(EACCES):
            return true
        default:
            return (e.userInfo[NSUnderlyingErrorKey] as? Error).map(isPermissionError) ?? false
        }
    }
}

/// Runs a closure per menu item (NSMenuItem needs an Objective-C target).
@MainActor
private final class CaptureMenuTarget: NSObject {
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
