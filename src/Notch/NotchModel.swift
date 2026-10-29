import Foundation
import Combine
import SwiftUI

/// The notch's state: where it is, whether the pointer is on it, whether it's open.
@MainActor
final class NotchModel: ObservableObject {
    @Published var geometry: NotchGeometry?
    @Published private(set) var hovering = false
    @Published private(set) var isOpen = false
    @Published var inFullscreenSpace = false
    @Published var pinned = false                 // clicking elsewhere doesn't close it
    @Published var tab: NotchTab = .home
    @Published var config: Config

    let activities: ActivityCenter

    /// Tab bodies and Home cards, registered by the features at launch. Tabs with no view
    /// show a placeholder.
    var tabViews: [NotchTab: () -> AnyView] = [:]
    var homeCards: [() -> AnyView] = []

    /// Tabs that take typing while open (terminal, clipboard search, prompter keys). The
    /// panel becomes the key window for them, and leaving with the pointer doesn't close them.
    var keyboardTabs: Set<NotchTab> = [.terminal, .clipboard]

    /// Tabs that take keys (Cmd-A on the shelf) but still close when the pointer leaves.
    var keyOnlyTabs: Set<NotchTab> = [.prompter]

    /// Files dropped anywhere on the open panel go to the current tab's handler, if it has one.
    var panelDrop: [NotchTab: ([NSItemProvider]) -> Bool] = [:]

    /// Called right after the panel opens on, or switches to, a tab, so a feature can
    /// focus a view (the terminal, the clipboard search field).
    var onTabShown: [NotchTab: () -> Void] = [:]

    /// Set by the window controller. `open(tab:)` and `select(_:)` call it when the tab
    /// takes typing, so a hotkey or click focuses the panel and a pointer move never does.
    var onKeyRequest: (() -> Void)?

    private var pointerInside = false
    private var configErrorShown = false   // the "config.json has an error" note, once per breakage
    private var enterWork: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var exitCloses = false      // the pointer has been on the open panel, so leaving closes it
    private var bag = Set<AnyCancellable>()

    init(activities: ActivityCenter, config: Config) {
        self.activities = activities
        self.config = config
        activities.objectWillChange
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
            .store(in: &bag)
    }

    var metrics: NotchMetrics? {
        guard let g = geometry else { return nil }
        let shown = shownActivity
        let extra: CGFloat
        if shown?.detail != nil { extra = NotchMetrics.peekExtraDetail }
        else if shown?.actions.isEmpty == false { extra = NotchMetrics.peekExtraActions }
        else { extra = NotchMetrics.peekExtraPlain }
        return NotchMetrics.make(geometry: g, config: config, tabCount: visibleTabs.count, peekExtra: extra)
    }

    /// The activity the collapsed notch shows. A fullscreen Space shows only urgent ones.
    var shownActivity: Activity? { inFullscreenSpace ? activities.topUrgent : activities.top }

    var mode: NotchMode {
        if isOpen { return .open }
        guard let shown = shownActivity else {
            return hovering && config.hoverToPeek ? .hover : .idle
        }
        if shown.expands || (hovering && config.hoverToPeek) { return .peek }
        return .compact
    }

    /// Tabs to show, in the user's order, without hidden ones.
    var visibleTabs: [NotchTab] {
        let shown = config.tabs.filter { !config.hiddenTabs.contains($0) }
        return shown.isEmpty ? [.settings] : shown
    }

    /// The selected tab, or the first visible one if the selected tab is hidden.
    var currentTab: NotchTab { visibleTabs.contains(tab) ? tab : visibleTabs[0] }

    /// Whether the open panel should be the key window right now.
    var wantsKeyboard: Bool { isOpen && (keyboardTabs.contains(currentTab) || keyOnlyTabs.contains(currentTab)) }

    /// Leaving the open panel closes it only after the pointer has been on it.
    var closesOnLeave: Bool { exitCloses }

    /// Called on every pointer move. Entering takes effect after `hoverDelay`, so sweeping
    /// across the menu bar doesn't flash the notch; leaving waits `collapseDelay`, so a quick
    /// slip off the edge doesn't close anything. Clicks don't wait for either.
    func pointerMoved(inside: Bool) {
        pointerInside = inside
        if inside {
            leaveWork?.cancel()
            leaveWork = nil
            if hovering {
                if isOpen { exitCloses = true }
                // An activity that shows up while you're already on the notch waits too.
                if let id = shownActivity?.id { activities.pauseExpiry(id: id) }
            } else if enterWork == nil {
                if config.hoverDelay <= 0 {
                    pointerEntered()
                } else {
                    enterWork = schedule(after: config.hoverDelay) { $0.pointerEntered() }
                }
            }
        } else {
            enterWork?.cancel()
            enterWork = nil
            if hovering, leaveWork == nil {
                leaveWork = schedule(after: config.collapseDelay) { $0.pointerLeft() }
            }
        }
    }

    private func pointerEntered() {
        enterWork = nil
        guard pointerInside, !hovering else { return }
        hovering = true
        if isOpen { exitCloses = true }
        if let id = shownActivity?.id { activities.pauseExpiry(id: id) }
    }

    /// Tabs that take typing stay open when the pointer wanders off; so does a pinned panel.
    private func pointerLeft() {
        leaveWork = nil
        hovering = false
        activities.resumeExpiry()
        if isOpen && exitCloses && !pinned && !keyboardTabs.contains(currentTab) { close() }
    }

    private func schedule(after delay: Double, _ action: @escaping (NotchModel) -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    /// Does nothing while there's no notch to show (lid closed). Opening from the menu bar
    /// or a hotkey doesn't arm "leave to close": the pointer isn't on the notch yet, or is
    /// on its way out.
    func open(tab: NotchTab? = nil) {
        guard geometry != nil else { return }
        if let tab { self.tab = tab }
        exitCloses = hovering && leaveWork == nil
        if !isOpen { isOpen = true }
        onTabShown[currentTab]?()
        if wantsKeyboard { onKeyRequest?() }
    }

    /// A click on the collapsed notch: opens the shown activity's tab, or the last tab.
    func openFromClick() {
        open(tab: shownActivity?.opensTab)
    }

    func select(_ tab: NotchTab) {
        self.tab = tab
        if isOpen { onTabShown[currentTab]?() }
        if wantsKeyboard { onKeyRequest?() }
    }

    func toggle(tab: NotchTab) {
        if isOpen && currentTab == tab { close() } else { open(tab: tab) }
    }

    func close() {
        exitCloses = false
        if isOpen { isOpen = false }
    }

    /// Changes a setting and saves the file (features remember sizes and toggles this way).
    /// The change is made to what's on disk, so edits you haven't reloaded yet are kept.
    /// While the file has a syntax error, the change applies but isn't saved: writing would
    /// replace your file with the in-memory settings.
    func updateConfig(_ change: (inout Config) -> Void) {
        switch Config.read() {
        case .ok(let disk):
            configErrorShown = false
            var c = disk
            change(&c)
            if c != disk { c.save() }
            if c != config { config = c }
        case .missing:
            configErrorShown = false
            var c = config
            change(&c)
            if c != config { config = c }
            c.save()
        case .unreadable:
            var c = config
            change(&c)
            guard c != config else { return }
            config = c
            if !configErrorShown {
                configErrorShown = true
                reportConfigError("Changes aren't saved until it's fixed")
            }
        }
    }

    /// Applies the file. A file that doesn't parse leaves the current settings alone; a
    /// deleted one comes back with the defaults.
    func reloadConfig() {
        switch Config.read() {
        case .ok(let fresh):
            configErrorShown = false
            if fresh != config { config = fresh }
        case .missing:
            configErrorShown = false
            let fresh = Config()
            fresh.save()
            if fresh != config { config = fresh }
        case .unreadable:
            configErrorShown = true
            reportConfigError("Settings not reloaded")
        }
    }

    private func reportConfigError(_ subtitle: String) {
        Log.app.error("config.json is unreadable: \(subtitle, privacy: .public)")
        activities.post(Activity(id: "app.config-error", priority: .info, symbol: "exclamationmark.triangle.fill",
                                 tint: .orange, title: "config.json has an error", subtitle: subtitle,
                                 duration: 4))
    }

    /// For snapshots only: set the hover state without the delays.
    func setHoveringForSnapshot(_ value: Bool) { hovering = value }
}
