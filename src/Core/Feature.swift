import AppKit
import SwiftUI

/// One feature (terminal, agents, clipboard, …). Created by AppDelegate, started once
/// after launch, stopped at quit. Features register their tab body and Home card through
/// the context, and post activities to `context.activities`.
@MainActor
protocol Feature: AnyObject {
    func start()
    func stop()
    /// A few facts about the feature's live state, for `notch state` (diagnostics).
    func debugState() -> [String: Any]
}

extension Feature {
    func stop() {}
    func debugState() -> [String: Any] { [:] }
}

/// What every feature shares. One instance, created in AppDelegate.
@MainActor
final class AppContext {
    let model: NotchModel
    let activities: ActivityCenter
    let bridge: BridgeServer
    let hotkeys: HotkeyCenter
    let statusItem: StatusItemController
    /// The notch window, for features that host AppKit views inside it (the terminal).
    let notchWindow: NSPanel

    init(model: NotchModel, activities: ActivityCenter, bridge: BridgeServer,
         hotkeys: HotkeyCenter, statusItem: StatusItemController, notchWindow: NSPanel) {
        self.model = model
        self.activities = activities
        self.bridge = bridge
        self.hotkeys = hotkeys
        self.statusItem = statusItem
        self.notchWindow = notchWindow
    }

    var config: Config { model.config }

    /// Extra tabs in the menu bar terminal's dropdown, beside Terminal (Usage).
    var dropdownTabs: [(title: String, symbol: String, view: () -> AnyView)] = []

    /// Set by the terminal: shows the terminal tab running `pid` (or one of its child
    /// processes) and returns true, or returns false if no terminal tab owns it.
    var revealTerminal: ((pid_t) -> Bool)?

    /// Set by the terminal: opens a new tab in the menu bar terminal and types this command
    /// into it (signing the `claude` command in, for usage limits).
    var runInTerminal: ((String) -> Void)?

    /// Set by the terminal: whether `pid` runs in the terminal tab you're looking at.
    var terminalShowing: ((pid_t) -> Bool)?

    /// Set by the shelf: adds files to it.
    var addToShelf: (([URL]) -> Void)?

    /// Set by the terminal: whether its dropdown is on screen showing the extra tab with
    /// this title.
    var dropdownTabVisible: ((String) -> Bool)?

    /// Called when the dropdown shows an extra tab, by title (Usage refreshes its numbers).
    var onDropdownTabShown: [String: () -> Void] = [:]

    func registerDropdownTab<V: View>(_ title: String, symbol: String, @ViewBuilder _ view: @escaping () -> V) {
        dropdownTabs.append((title, symbol, { AnyView(view()) }))
    }

    /// ~/Library/Application Support/DynamicNotch/<name>, creating the folder if needed.
    func dataURL(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        return Config.directory.appendingPathComponent(name)
    }

    /// Shows `view` as the body of `tab` in the open notch.
    func registerTab<V: View>(_ tab: NotchTab, @ViewBuilder _ view: @escaping () -> V) {
        model.tabViews[tab] = { AnyView(view()) }
    }

    /// Adds a card to the Home tab, in registration order (at most 4 fit).
    func registerHomeCard<V: View>(@ViewBuilder _ view: @escaping () -> V) {
        model.homeCards.append { AnyView(view()) }
    }
}

/// Reads and writes one Codable value as a JSON file, atomically. For small state
/// (clipboard history, shelf, battery history).
struct JSONFile<Value: Codable> {
    let url: URL

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.notch.decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.notch.encode(value).write(to: url, options: .atomic)
        } catch {
            Log.app.error("could not save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension JSONDecoder {
    static var notch: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var notch: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

/// Shared look for the open panel's tabs, so every feature matches.
enum NotchStyle {
    static let card = Color.white.opacity(0.07)
    static let cardHover = Color.white.opacity(0.12)
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.4)
    static let cornerRadius: CGFloat = 14
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let bodyFont = Font.system(size: 12)
    static let smallFont = Font.system(size: 11)
    static let monoFont = Font.system(size: 11, design: .monospaced)
}
