import AppKit

/// The menu bar icon. Left click runs `onPrimaryClick` (the terminal drops down from it);
/// right click, or Control-click, shows the menu. With no primary action, any click shows
/// the menu.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: NotchModel
    private let activities: ActivityCenter
    private lazy var menu = buildMenu()

    var onPrimaryClick: (() -> Void)?

    /// Extra menu items features add above Quit (Quick Capture, Prompter, …).
    var extraItems: [NSMenuItem] = [] { didSet { menu = buildMenu() } }

    init(model: NotchModel, activities: ActivityCenter) {
        self.model = model
        self.activities = activities
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Dynamic Notch")
                ?? NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Dynamic Notch")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// The icon's frame in screen coordinates, for placing a dropdown under it.
    var buttonScreenFrame: CGRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if !secondary, let onPrimaryClick {
            onPrimaryClick()
        } else {
            statusItem.menu = menu
            sender.performClick(nil)       // opens the menu; it stays attached only while open
            statusItem.menu = nil
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Open Notch", #selector(openNotch)))

        let tests = NSMenu()
        for sample in TestActivities.all {
            let item = menuItem(sample.menuTitle, #selector(postTest(_:)))
            item.representedObject = sample.activity.id
            tests.addItem(item)
        }
        tests.addItem(.separator())
        tests.addItem(menuItem("Clear All", #selector(clearTests)))
        let testsItem = NSMenuItem(title: "Test Activities", action: nil, keyEquivalent: "")
        testsItem.submenu = tests
        menu.addItem(testsItem)

        if !extraItems.isEmpty {
            menu.addItem(.separator())
            for item in extraItems {
                item.menu?.removeItem(item)      // an item can only be in one menu
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Open Settings File", #selector(openSettings)))
        menu.addItem(menuItem("Reload Settings", #selector(reloadSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Dynamic Notch", #selector(quit), key: "q"))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openNotch() { model.open() }

    @objc private func postTest(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let activity = TestActivities.sample(id) else { return }
        activities.post(activity) { [weak activities] action in
            if action == "dismiss" { activities?.remove(id: id) }
        }
    }

    @objc private func clearTests() { activities.removeAll(prefix: "test.") }
    @objc private func openSettings() { NSWorkspace.shared.open(Config.fileURL) }
    @objc private func reloadSettings() { model.reloadConfig() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension StatusItemController: NSMenuItemValidation {
    /// "Open Notch" is greyed out while there's no notch to show (lid closed).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(openNotch) ? model.geometry != nil : true
    }
}
