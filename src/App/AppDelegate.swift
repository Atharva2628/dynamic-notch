import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let activities = ActivityCenter()
    private lazy var model = NotchModel(activities: activities, config: Config.load())
    private var notch: NotchWindowController?
    private var statusItem: StatusItemController?
    private let bridge = BridgeServer()
    private var features: [Feature] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.editMenu()
        let notch = NotchWindowController(model: model)
        self.notch = notch
        let statusItem = StatusItemController(model: model, activities: activities)
        self.statusItem = statusItem
        let context = AppContext(model: model, activities: activities, bridge: bridge,
                                 hotkeys: .shared, statusItem: statusItem, notchWindow: notch.window)
        features = FeatureRegistry.make(context)
        // install.sh asks a running copy to quit this way, so the terminal can ask first.
        // `state` answers with a diagnostic snapshot; `close` and `terminal` drive the UI
        // the way a click would, for checks without a screen.
        bridge.on("app") { [weak self] message, connection in
            let command = message["command"] as? String
            if command == "state" {
                connection.reply(self?.debugState() ?? [:])
                return
            }
            connection.close()
            switch command {
            case "quit":
                // From the run loop, not this main-queue block: the terminal's quit alert
                // runs a nested loop, and main-queue work waits until this block returns.
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            case "close": self?.model.close()
            case "terminal": TerminalFeature.shared?.debugToggle()
            default: break
            }
        }
        bridge.start()
        notch.start()
        for feature in features { feature.start() }
        Log.app.info("started, version \(Bundle.main.version, privacy: .public), \(self.features.count) features")
    }

    /// Asks before ending commands still running in terminal tabs.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TerminalFeature.shared?.confirmQuit() == false ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        for feature in features { feature.stop() }
        bridge.stop()
    }

    /// `notch state`: the notch window, the model and each feature, as JSON.
    private func debugState() -> [String: Any] {
        var state: [String: Any] = [
            "version": Bundle.main.version,
            "mode": String(describing: model.mode),
            "isOpen": model.isOpen,
            "tab": model.currentTab.rawValue,
            "hovering": model.hovering,
            "pinned": model.pinned,
            "inFullscreenSpace": model.inFullscreenSpace,
            "notch": model.geometry.map { NSStringFromRect($0.notchRect) } ?? "none",
            "activities": activities.activities.map { "\($0.id) [\($0.priority)] \($0.title)" },
        ]
        if let panel = notch?.window {
            let b = panel.collectionBehavior
            state["panel"] = [
                "frame": NSStringFromRect(panel.frame), "visible": panel.isVisible, "key": panel.isKeyWindow,
                "level": panel.level.rawValue, "ignoresMouse": panel.ignoresMouseEvents,
                "allSpaces": b.contains(.canJoinAllSpaces), "fullScreenAuxiliary": b.contains(.fullScreenAuxiliary),
                "stationary": b.contains(.stationary), "onActiveSpace": panel.isOnActiveSpace,
            ] as [String: Any]
        }
        var perFeature: [String: Any] = [:]
        for f in features {
            let s = f.debugState()
            if !s.isEmpty { perFeature[String(describing: type(of: f))] = s }
        }
        state["features"] = perFeature
        return state
    }

    /// Never shown (the app has no menu bar), but text fields in other panels (Quick
    /// Capture) find ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z here. Edit items only, so no key can quit the
    /// app or close a panel.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: EditKeys.undo, keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: EditKeys.redo, keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        return main
    }
}
