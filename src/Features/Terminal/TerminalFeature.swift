import AppKit
import Combine
import SwiftTerm
import SwiftUI
import os

/// The terminal: login-shell sessions in tabs, shown in a dropdown under the menu bar
/// icon (the main place) or in the notch's Terminal tab. Both show the same sessions;
/// the active session's view moves to whichever is showing.
@MainActor
final class TerminalFeature: Feature {
    /// For the app delegate's quit check.
    static weak var shared: TerminalFeature?
    private static let log = Logger(subsystem: "local.dynamicnotch", category: "terminal")
    private static let saveQueue = DispatchQueue(label: "local.dynamicnotch.terminal.save", qos: .utility)

    private let context: AppContext
    private let store = TerminalStore()
    private let file: JSONFile<TerminalSavedState>
    private var saved = TerminalSavedState()
    private var sessions: [TerminalSession] = []
    private var closing: [Int: TerminalSession] = [:]     // hung up, waiting for the shell to exit
    private var nextID = 1
    private var surface: TerminalSurface = .dropdown
    private var hosts: [TerminalSurface: TerminalWeakHost] = [:]
    private var dropdown: TerminalDropdownController?
    private var hotkeyID: UInt32?
    private var hotkeyText = ""
    private var keyMonitor: Any?
    private var pollTimer: Timer?
    private var polling = false
    private var pendingCloseReset: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()
    private var fontSize: Double
    private var scrollback: Int
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    init(context: AppContext) {
        self.context = context
        file = JSONFile(url: context.dataURL("terminal.json"))
        fontSize = context.config.terminalFontSize
        scrollback = context.config.terminalScrollback
    }

    func start() {
        Self.shared = self
        saved = file.load() ?? TerminalSavedState()
        wireStore()
        context.registerTab(.terminal) { [store] in TerminalNotchTab(store: store) }
        context.model.onTabShown[.terminal] = { [weak self] in self?.showInNotch() }
        context.statusItem.onPrimaryClick = { [weak self] in self?.toggleFromStatusItem() }
        context.revealTerminal = { [weak self] pid in self?.reveal(pid: pid) ?? false }
        context.terminalShowing = { [weak self] pid in self?.isShowing(pid: pid) ?? false }
        context.runInTerminal = { [weak self] command in self?.run(command) }
        context.dropdownTabVisible = { [weak self] title in
            guard let self, let d = self.dropdown, d.isVisible, let i = self.store.extraTab,
                  self.store.extraTabs.indices.contains(i) else { return false }
            return self.store.extraTabs[i].title == title
        }
        registerHotkey(context.config.terminalHotkey)
        installKeyMonitor()
        context.model.$config
            .dropFirst()
            .sink { [weak self] config in MainActor.assumeIsolated { self?.apply(config) } }
            .store(in: &bag)
        // The publishers fire before the change lands; look once it has.
        Publishers.CombineLatest(context.model.$isOpen, context.model.$tab)
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.notchChanged() } }
            }
            .store(in: &bag)
    }

    func stop() {
        if let id = hotkeyID { context.hotkeys.unregister(id) }
        hotkeyID = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        stopPolling()
        pendingCloseReset?.cancel()
        dropdown?.hide()
        bag.removeAll()
        context.model.onTabShown[.terminal] = nil
        context.statusItem.onPrimaryClick = nil
        context.revealTerminal = nil
        context.terminalShowing = nil
        context.runInTerminal = nil
        context.dropdownTabVisible = nil
        for session in sessions + Array(closing.values) { session.hangUp() }
    }

    // MARK: Showing

    /// The terminal is on screen in the dropdown or the open notch.
    private var terminalVisible: Bool {
        dropdown?.isVisible == true || (context.model.isOpen && context.model.currentTab == .terminal)
    }

    private var activeSession: TerminalSession? { sessions.first { $0.id == store.activeID } }

    private func toggleFromStatusItem() {
        // The hotkey may have been taken at launch (by Notchy, say); try it again.
        if hotkeyID == nil { registerHotkey(hotkeyText) }
        if dropdown?.isVisible == true { hideDropdown() } else { showDropdown() }
    }

    /// The hotkey hides the terminal when you're typing in it (in the dropdown or the
    /// notch), and otherwise brings the dropdown up (or back into focus) on the terminal.
    private func toggleFromHotkey() {
        if let d = dropdown, d.isVisible, d.isKey, store.showsTerminal {
            hideDropdown()
        } else if context.model.isOpen, context.model.currentTab == .terminal, context.notchWindow.isKeyWindow {
            context.model.close()
        } else {
            store.extraTab = nil
            showDropdown()
        }
    }

    private func showDropdown() {
        ensureSession()
        // One place at a time: the notch gives the terminal up. Any open tab closes, not
        // only Terminal: the notch sits above the dropdown and would cover its tab header,
        // and a tab that takes typing (Clipboard, Calendar) would hold on to the keys.
        if context.model.isOpen { context.model.close() }
        surface = .dropdown
        let extras = context.dropdownTabs
        if extras.map({ $0.title }) != store.extraTabs.map({ $0.title }) {
            store.extraTabs = extras.map { TerminalStore.Extra(title: $0.title, symbol: $0.symbol, view: $0.view) }
        }
        if let i = store.extraTab, !store.extraTabs.indices.contains(i) { store.extraTab = nil }
        dropdownController().show(size: CGSize(width: context.config.terminalWidth, height: context.config.terminalHeight))
        mount()
        startPolling()
        if let i = store.extraTab { context.onDropdownTabShown[store.extraTabs[i].title]?() }
    }

    private func hideDropdown() {
        dropdown?.hide()
        store.pendingClose = nil
    }

    /// One place at a time, the other way: the notch opening on another tab that takes
    /// typing (Clipboard, Calendar, Prompter, say from a hotkey) puts an unpinned dropdown
    /// away. (The Terminal tab takes the terminal over in showInNotch.)
    private func notchChanged() {
        let model = context.model
        guard model.isOpen, model.currentTab != .terminal, model.keyboardTabs.contains(model.currentTab),
              dropdown?.isVisible == true, !store.pinned else { return }
        hideDropdown()
    }

    /// The notch opened on, or switched to, the Terminal tab.
    private func showInNotch() {
        ensureSession()
        hideDropdown()
        surface = .notch
        mount()
        // The tab's host view is created on SwiftUI's next pass; focus once it's there.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.mount() }
        }
        startPolling()
    }

    private func dropdownController() -> TerminalDropdownController {
        if let dropdown { return dropdown }
        let d = TerminalDropdownController(store: store) { [weak self] in self?.context.statusItem.buttonScreenFrame }
        d.panel.onKeyEquivalent = { [weak self] event in self?.handleKey(event, in: .dropdown) ?? false }
        d.onResized = { [weak self] size in
            self?.context.model.updateConfig {
                $0.terminalWidth = Double(size.width.rounded())
                $0.terminalHeight = Double(size.height.rounded())
            }
        }
        d.onHidden = { [weak self] in self?.store.pendingClose = nil }
        dropdown = d
        return d
    }

    // MARK: Moving the view between surfaces

    private func hostMoved(_ surface: TerminalSurface, _ host: TerminalHostView) {
        guard host.window != nil else { return }
        hosts[surface] = TerminalWeakHost(view: host)
        guard surface == self.surface else { return }
        // A host joins its window in the middle of SwiftUI's update; move the terminal
        // (and publish the store change) on the next turn instead.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let self, self.surface == surface { self.mount() } }
        }
    }

    private func hostRemoved(_ surface: TerminalSurface, _ host: TerminalHostView) {
        if hosts[surface]?.view === host { hosts[surface] = nil }
    }

    /// Puts the active session's view in the current surface's host and focuses it.
    private func mount() {
        if store.surface != surface { store.surface = surface }
        guard let session = activeSession, let host = hosts[surface]?.view, host.window != nil else { return }
        // The dropdown's host is hidden while a dropdown tab (Usage) shows; SwiftUI unhides
        // it on its next pass, but the terminal should take focus now.
        if surface == .dropdown, store.showsTerminal, host.isHidden { host.isHidden = false }
        host.show(session.view)
        focus()
    }

    private func focus() {
        guard surface == .notch || store.showsTerminal,
              let view = activeSession?.view, let window = view.window else { return }
        if window.firstResponder !== view { window.makeFirstResponder(view) }
    }

    // MARK: Sessions

    private func ensureSession() {
        if sessions.isEmpty { newSession() }
    }

    @discardableResult
    private func newSession() -> TerminalSession {
        let directory = startDirectory()
        let cursor: CursorStyle = saved.cursor == "bar" ? .steadyBar : .steadyBlock
        // The dropdown's body less its header and margins, so the shell starts at about
        // the size it will have; the host fits it exactly once it's on screen.
        let size = CGSize(width: max(context.config.terminalWidth - 14, 200), height: max(context.config.terminalHeight - 50, 100))
        let session = TerminalSession(id: nextID, fontSize: fontSize, scrollback: scrollback, cursor: cursor, size: size)
        nextID += 1
        session.onExit = { [weak self] s in self?.sessionEnded(s) }
        session.onChange = { [weak self] _ in self?.refreshTabs() }
        session.onDirectory = { [weak self] dir in self?.remember(directory: dir) }
        let shell = TerminalShell.login()
        let env = TerminalShell.environment(base: ProcessInfo.processInfo.environment, directory: directory,
                                            version: Bundle.main.version, shell: shell.path)
        session.start(shell: shell.path, execName: shell.execName, environment: env, directory: directory)
        sessions.append(session)
        store.activeID = session.id
        store.extraTab = nil
        refreshTabs()
        Self.log.info("started shell \(session.shellPid, privacy: .public)")
        return session
    }

    /// New tabs start where you last were: the active shell's folder, else the one
    /// remembered in terminal.json, else home.
    private func startDirectory() -> String {
        if let s = activeSession, s.isRunning, let dir = TerminalProcess.directory(of: s.shellPid) {
            remember(directory: dir)
            return dir
        }
        var isDirectory: ObjCBool = false
        if let dir = saved.lastDirectory, FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return dir
        }
        return home
    }

    /// Remembers the folder for new tabs; the file is written off the main thread, in order.
    private func remember(directory: String) {
        guard directory != saved.lastDirectory else { return }
        saved.lastDirectory = directory
        let file = self.file, state = saved
        Self.saveQueue.async { file.save(state) }
    }

    /// A new tab in the dropdown with `command` typed in and Return pressed. The shell reads
    /// it as soon as it has started.
    private func run(_ command: String) {
        newTab()
        guard let session = activeSession else { return }
        session.view.send(data: ArraySlice(Array((command + "\r").utf8)))
    }

    private func newTab() {
        if terminalVisible {
            newSession()
            mount()
        } else {
            let hadSessions = !sessions.isEmpty
            showDropdown()
            if hadSessions {
                newSession()
                mount()
            }
        }
    }

    private func select(id: Int) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        store.activeID = id
        store.extraTab = nil
        if store.pendingClose?.id != id { store.pendingClose = nil }
        mount()
    }

    private func selectExtra(_ index: Int) {
        guard store.extraTabs.indices.contains(index) else { return }
        store.extraTab = index
        store.pendingClose = nil
        dropdown?.panel.makeFirstResponder(nil)
        context.onDropdownTabShown[store.extraTabs[index].title]?()
    }

    private func cycleTab(by step: Int) {
        guard let current = sessions.firstIndex(where: { $0.id == store.activeID }) else { return }
        select(id: sessions[TerminalTabMath.cycle(current, by: step, count: sessions.count)].id)
    }

    /// ⌘W or the tab's ×. A tab running a command, in the foreground or the background
    /// (the hangup ends both), asks for a second press within 3 s.
    private func requestClose(id: Int) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if session.isRunning, store.pendingClose?.id != id,
           let jobs = TerminalJob.summary(TerminalProcess.jobs(shell: session.shellPid, fd: session.ptyFD)) {
            store.pendingClose = (id, jobs)
            pendingCloseReset?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { if self?.store.pendingClose?.id == id { self?.store.pendingClose = nil } }
            }
            pendingCloseReset = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
            return
        }
        store.pendingClose = nil
        remove(session)
        guard !session.ended else {
            session.close()
            return
        }
        closing[id] = session
        session.hangUp()
        // A shell that ignores the hangup is killed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
            MainActor.assumeIsolated {
                guard let self, let session, self.closing[session.id] != nil else { return }
                session.kill9()
            }
        }
    }

    private func sessionEnded(_ session: TerminalSession) {
        Self.log.info("shell \(session.id, privacy: .public) ended")
        if closing.removeValue(forKey: session.id) != nil {
            session.close()
            return
        }
        guard sessions.contains(where: { $0 === session }) else { return }
        remove(session)
        session.close()
    }

    /// Takes a session out of the tabs and shows its neighbour. With none left, the
    /// dropdown hides; the next time the terminal shows, it starts a fresh shell.
    private func remove(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        let active = sessions.firstIndex { $0.id == store.activeID } ?? index
        let next = TerminalTabMath.indexAfterClose(count: sessions.count, active: active, closed: index)
        sessions.remove(at: index)
        session.view.removeFromSuperview()
        if store.pendingClose?.id == session.id { store.pendingClose = nil }
        store.activeID = next.map { sessions[$0].id }
        refreshTabs()
        if sessions.isEmpty {
            if store.showsTerminal { hideDropdown() }
        } else {
            mount()
        }
    }

    private func refreshTabs() {
        let tabs = sessions.map {
            TerminalStore.Tab(id: $0.id, title: $0.title(home: home), busy: $0.foreground != nil)
        }
        if tabs != store.tabs { store.tabs = tabs }
    }

    // MARK: Polling (folders and running commands, while visible)

    /// Reads each shell's folder and foreground job every 2 s while the terminal is on
    /// screen; stops once it isn't.
    private func startPolling() {
        poll()
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.terminalVisible { self.poll() } else { self.stopPolling() }
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard !polling else { return }
        let targets = sessions.filter(\.isRunning)
            .map { TerminalProbeTarget(id: $0.id, pid: $0.shellPid, fd: $0.ptyFD) }
            .filter { $0.pid > 0 }
        guard !targets.isEmpty else { return }
        polling = true
        Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                targets.map { TerminalProbeResult(id: $0.id, probe: TerminalProcess.probe(shell: $0.pid, fd: $0.fd)) }
            }.value
            self?.applyProbes(results)
        }
    }

    private func applyProbes(_ results: [TerminalProbeResult]) {
        polling = false
        var changed = false
        for result in results {
            guard let session = sessions.first(where: { $0.id == result.id }), session.isRunning else { continue }
            if session.apply(result.probe) { changed = true }
        }
        if changed { refreshTabs() }
    }

    // MARK: Keys

    /// Notch tab shortcuts: the notch panel is core's, so its keys are watched here
    /// (the dropdown panel handles its own in performKeyEquivalent).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.context.notchWindow, self.context.model.isOpen,
                      self.context.model.currentTab == .terminal else { return false }
                return self.handleKey(event, in: .notch)
            }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent, in place: TerminalSurface) -> Bool {
        guard let command = TerminalKeyCommand.from(event) else { return false }
        if place == .notch, surface != .notch { showInNotch() }
        let terminalShown = place == .notch || store.showsTerminal
        switch command {
        case .newTab:
            newTab()
        case .closeTab:
            if terminalShown, let id = store.activeID { requestClose(id: id) }
        case .selectTab(let i):
            if sessions.indices.contains(i) { select(id: sessions[i].id) }
        case .nextTab:
            cycleTab(by: 1)
        case .previousTab:
            cycleTab(by: -1)
        case .clear:
            if terminalShown, let s = activeSession, s.isRunning { s.clear(shellIdle: s.isAtPrompt) }
        case .copy, .cut, .paste, .selectAll:
            return edit(command, in: event.window)
        case .fontBigger:
            setFontSize(fontSize + 1)
        case .fontSmaller:
            setFontSize(fontSize - 1)
        case .fontReset:
            setFontSize(Config().terminalFontSize)
        case .find, .findNext, .findPrevious:
            if terminalShown { find(command) }
        }
        return true
    }

    /// Copy, cut, paste and select all go to the terminal, or to a text field that has
    /// focus (the find bar).
    private func edit(_ command: TerminalKeyCommand, in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let terminal = responder as? TerminalView {
            switch command {
            case .copy: if terminal.selectionActive { terminal.copy(self) }   // never clears the clipboard
            case .paste: terminal.paste(self)
            case .selectAll: terminal.selectAll(nil)
            default: break
            }
            return true
        }
        let action: Selector
        switch command {
        case .copy: action = #selector(NSText.copy(_:))
        case .cut: action = #selector(NSText.cut(_:))
        case .paste: action = #selector(NSText.paste(_:))
        default: action = #selector(NSText.selectAll(_:))
        }
        return responder.tryToPerform(action, with: nil)
    }

    /// SwiftTerm's find bar, driven the way its Find menu items would.
    private func find(_ command: TerminalKeyCommand) {
        guard let view = activeSession?.view else { return }
        let item = NSMenuItem()
        switch command {
        case .findNext: item.tag = NSTextFinder.Action.nextMatch.rawValue
        case .findPrevious: item.tag = NSTextFinder.Action.previousMatch.rawValue
        default: item.tag = NSTextFinder.Action.showFindInterface.rawValue
        }
        view.performTextFinderAction(item)
    }

    private func setFontSize(_ size: Double) {
        let clamped = min(max(size.rounded(), 8), 32)
        guard clamped != fontSize else { return }
        applyFont(clamped)
        context.model.updateConfig { $0.terminalFontSize = clamped }
    }

    private func applyFont(_ size: Double) {
        fontSize = size
        let font = TerminalSession.font(size: size)
        for session in sessions { session.view.font = font }
    }

    // MARK: Settings and hotkey

    /// Settings changed (reloaded from the file, or by this feature).
    private func apply(_ config: Config) {
        if config.terminalFontSize != fontSize { applyFont(config.terminalFontSize) }
        if config.terminalScrollback != scrollback {
            scrollback = config.terminalScrollback
            for session in sessions { session.view.changeScrollback(scrollback) }
        }
        if config.terminalHotkey != hotkeyText { registerHotkey(config.terminalHotkey) }
        dropdown?.apply(size: CGSize(width: config.terminalWidth, height: config.terminalHeight))
    }

    private func registerHotkey(_ text: String) {
        if let id = hotkeyID { context.hotkeys.unregister(id) }
        hotkeyText = text
        hotkeyID = context.hotkeys.register(text) { [weak self] in self?.toggleFromHotkey() }
        store.hotkeyLabel = TerminalHotkeyText.label(text) ?? text
    }

    private func wireStore() {
        store.select = { [weak self] id in self?.select(id: id) }
        store.close = { [weak self] id in self?.requestClose(id: id) }
        store.newTab = { [weak self] in self?.newTab() }
        store.selectExtra = { [weak self] i in self?.selectExtra(i) }
        store.togglePin = { [weak self] in self?.store.pinned.toggle() }
        store.hide = { [weak self] in self?.hideDropdown() }
        store.resize = { [weak self] phase in self?.dropdown?.resize(phase) }
        store.showInNotch = { [weak self] in self?.showInNotch() }
        store.hostMoved = { [weak self] surface, host in self?.hostMoved(surface, host) }
        store.hostRemoved = { [weak self] surface, host in self?.hostRemoved(surface, host) }
    }

    // MARK: Other features and quitting

    /// The running session whose shell is `pid` or one of its ancestors (a Claude Code
    /// session started in it).
    private func session(owning pid: pid_t) -> TerminalSession? {
        var shells: [pid_t: TerminalSession] = [:]
        for session in sessions where session.isRunning && session.shellPid > 0 { shells[session.shellPid] = session }
        guard let owner = TerminalProcess.owner(of: pid, shells: Set(shells.keys), parent: TerminalProcess.parent(of:))
        else { return nil }
        return shells[owner]
    }

    /// Shows the tab whose shell is `pid` or one of its ancestors. False if no tab owns it.
    private func reveal(pid: pid_t) -> Bool {
        guard let id = session(owning: pid)?.id else { return false }
        store.activeID = id
        store.extraTab = nil
        if store.pendingClose?.id != id { store.pendingClose = nil }
        showDropdown()
        return true
    }

    /// Whether `pid` runs in the tab in front of you: the shown session, in the dropdown
    /// while it has the keys (a pinned one you've clicked away from doesn't count) or in
    /// the open notch. The done ping stays quiet for it.
    func isShowing(pid: pid_t) -> Bool {
        guard let session = session(owning: pid), session.id == store.activeID else { return false }
        if let d = dropdown, d.isVisible, d.isKey, store.showsTerminal { return true }
        return context.model.isOpen && context.model.currentTab == .terminal
    }

    /// Asks before quitting while commands run in the terminal, in the foreground or the
    /// background (quitting ends them). Returns whether to quit.
    func confirmQuit() -> Bool {
        let running = sessions.filter(\.isRunning).flatMap { session -> [String] in
            let folder = TerminalShell.folderName(session.directory, home: home)
            return TerminalProcess.jobs(shell: session.shellPid, fd: session.ptyFD).map { $0.line(folder: folder) }
        }
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Self.quitTitle(count: running.count)
        alert.informativeText = running.joined(separator: "\n")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        let quit = alert.runModal() == .alertFirstButtonReturn
        if !quit { NSApp.deactivate() }
        return quit
    }

    static func quitTitle(count: Int) -> String {
        count == 1 ? "Quit and end 1 running command?" : "Quit and end \(count) running commands?"
    }
}

private struct TerminalWeakHost {
    weak var view: TerminalHostView?
}

private struct TerminalProbeTarget: Sendable {
    let id: Int
    let pid: pid_t
    let fd: Int32
}

private struct TerminalProbeResult: Sendable {
    let id: Int
    let probe: TerminalProbe
}

// MARK: Checks and snapshots

extension TerminalFeature {
    @MainActor
    static func selfTest(_ check: (Bool, String) -> Void) {
        // Which shell a process belongs to, on a made-up process tree.
        let parents: [pid_t: pid_t] = [900: 800, 800: 700, 700: 100, 100: 1, 555: 1, 41: 42, 42: 41]
        let parent: (pid_t) -> pid_t? = { parents[$0] }
        check(TerminalProcess.owner(of: 900, shells: [100, 200], parent: parent) == 100,
              "terminal: a shell's grandchild belongs to that shell")
        check(TerminalProcess.owner(of: 200, shells: [100, 200], parent: parent) == 200, "terminal: a shell owns itself")
        check(TerminalProcess.owner(of: 555, shells: [100], parent: parent) == nil,
              "terminal: a process outside every shell isn't claimed")
        check(TerminalProcess.owner(of: 41, shells: [100], parent: parent) == nil, "terminal: a parent loop ends the walk")
        check(TerminalProcess.parent(of: getpid()) == getppid(), "terminal: the process table gives this process's parent")
        check(TerminalProcess.details(of: 1)?.name == "launchd",
              "terminal: another user's process (launchd, root) still has a name, as sudo does")

        // Which tab shows after closing one.
        check(TerminalTabMath.indexAfterClose(count: 4, active: 2, closed: 0) == 1,
              "terminal: closing a tab to the left keeps the shown tab")
        check(TerminalTabMath.indexAfterClose(count: 4, active: 2, closed: 2) == 2,
              "terminal: closing the shown tab shows its right neighbour")
        check(TerminalTabMath.indexAfterClose(count: 3, active: 2, closed: 2) == 1,
              "terminal: closing the last tab shows the new last one")
        check(TerminalTabMath.indexAfterClose(count: 1, active: 0, closed: 0) == nil, "terminal: closing the only tab leaves none")
        check(TerminalTabMath.cycle(0, by: -1, count: 3) == 2 && TerminalTabMath.cycle(2, by: 1, count: 3) == 0,
              "terminal: switching tabs wraps around")

        // terminal.json.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynamicnotch-terminal-selftest-\(UUID().uuidString)", isDirectory: true)
        let stateFile = JSONFile<TerminalSavedState>(url: dir.appendingPathComponent("terminal.json"))
        let state = TerminalSavedState(lastDirectory: "/Users/me/Code/my app", cursor: "bar")
        stateFile.save(state)
        check(stateFile.load() == state, "terminal: terminal.json survives a save and load")
        try? Data(#"{"cursor": "triangle"}"#.utf8).write(to: stateFile.url)
        check(stateFile.load() == TerminalSavedState(), "terminal: missing or unknown terminal.json values fall back")
        try? Data("not json".utf8).write(to: stateFile.url)
        check(stateFile.load() == nil, "terminal: a broken terminal.json is ignored")
        try? FileManager.default.removeItem(at: dir)

        // Command-key shortcuts.
        func key(_ k: String, shift: Bool = false, control: Bool = false, command: Bool = true) -> TerminalKeyCommand? {
            TerminalKeyCommand.from(key: k, command: command, shift: shift, option: false, control: control)
        }
        check(key("t") == .newTab && key("w") == .closeTab && key("k") == .clear, "terminal: ⌘T, ⌘W and ⌘K")
        check(key("3") == .selectTab(2) && key("9") == .selectTab(8), "terminal: ⌘1–9 pick a tab")
        check(key("=") == .fontBigger && key("+", shift: true) == .fontBigger && key("-") == .fontSmaller,
              "terminal: ⌘=, ⌘+ and ⌘- change the font size")
        check(key("c") == .copy && key("v") == .paste && key("a") == .selectAll && key("f") == .find,
              "terminal: ⌘C, ⌘V, ⌘A and ⌘F")
        check(key("G", shift: true) == .findPrevious && key("}", shift: true) == .nextTab,
              "terminal: ⌘⇧G finds backwards and ⌘⇧] shows the next tab")
        check(key("t", command: false) == nil && key("c", control: true) == nil && key("T", shift: true) == nil,
              "terminal: plain, Control and unmapped Shift keys go to the shell")

        // Hotkey text.
        check(TerminalHotkeyText.label(Config().terminalHotkey) == "⌃`", "terminal: the default hotkey reads ⌃`")
        check(TerminalHotkeyText.label("cmd+shift+space") == "⇧⌘Space", "terminal: hotkey modifiers in Apple's order")
        check(TerminalHotkeyText.label("hyper+x") == nil, "terminal: an invalid hotkey has no label")

        // The shell's environment, folder and titles.
        let env = TerminalShell.environment(base: ["PATH": "/usr/bin", "CLAUDECODE": "1", "TERM_SESSION_ID": "x",
                                                   "VSCODE_PID": "3"], directory: "/tmp/x", version: "1.0")
        check(env.contains("TERM=xterm-256color") && env.contains("COLORTERM=truecolor")
              && env.contains("TERM_PROGRAM=DynamicNotch") && env.contains("LANG=en_US.UTF-8")
              && env.contains("PATH=/usr/bin") && env.contains("PWD=/tmp/x"),
              "terminal: the shell gets a 256-color, truecolor identity and a LANG")
        check(!env.contains { $0.hasPrefix("CLAUDECODE=") || $0.hasPrefix("TERM_SESSION_ID=") || $0.hasPrefix("VSCODE_") },
              "terminal: another terminal's and Claude Code's variables are dropped")
        check(TerminalShell.environment(base: ["LANG": "de_DE.UTF-8"], directory: "/", version: "1").contains("LANG=de_DE.UTF-8"),
              "terminal: an existing LANG is kept")
        check(TerminalShell.environment(base: [:], directory: "/", version: "1", shell: "/bin/zsh").contains("SHELL=/bin/zsh")
              && TerminalShell.environment(base: ["SHELL": "/opt/fish"], directory: "/", version: "1", shell: "/bin/zsh")
                .contains("SHELL=/opt/fish"),
              "terminal: SHELL is filled in only when missing")
        check(TerminalShell.execName(for: "/bin/zsh") == "-zsh", "terminal: the shell starts as a login shell")
        check(TerminalShell.pathFromOSC7("file://mac.local/Users/me/My%20Dir") == "/Users/me/My Dir"
              && TerminalShell.pathFromOSC7("https://example.com/x") == nil, "terminal: OSC 7 folders are decoded")
        let started = Date(timeIntervalSince1970: 1_000)
        let job = TerminalForeground(pid: 5, name: "claude", started: started)
        check(TerminalShell.title(osc: "✳ Fix tests", oscAt: started.addingTimeInterval(3), foreground: job,
                                  directory: "/x/app", home: "/Users/me") == "✳ Fix tests",
              "terminal: a running program's own title is shown")
        check(TerminalShell.title(osc: "old", oscAt: started.addingTimeInterval(-60), foreground: job,
                                  directory: "/x/app", home: "/Users/me") == "claude",
              "terminal: an earlier program's title is ignored")
        check(TerminalShell.title(osc: "old", oscAt: nil, foreground: nil, directory: "/Users/me/Code/app", home: "/Users/me") == "app"
              && TerminalShell.folderName("/Users/me", home: "/Users/me") == "~",
              "terminal: at the prompt the tab shows the folder")

        // Dropdown placement and resizing (a 1470 × 956 screen, 32-pt menu bar).
        let visible = CGRect(x: 0, y: 0, width: 1470, height: 924)
        let icon = CGRect(x: 1400, y: 924, width: 30, height: 32)
        let frame = TerminalPlacement.dropdownFrame(size: CGSize(width: 720, height: 420), anchor: icon, visible: visible)
        check(frame.size == CGSize(width: 720, height: 420) && frame.maxY == 920 && frame.maxX <= visible.maxX - 8,
              "terminal: the dropdown hangs under the icon, inside the screen")
        let grown = TerminalPlacement.resized(start: frame, dx: 500, dy: -400, visible: visible)
        check(grown.maxY == frame.maxY && grown.height == 200 && grown.width == 1220 && grown.maxX <= visible.maxX - 8,
              "terminal: resizing keeps the top edge, a minimum height and the screen edge")

        check(quitTitle(count: 1) == "Quit and end 1 running command?" && quitTitle(count: 3) == "Quit and end 3 running commands?",
              "terminal: the quit question counts running commands")
        let jobs = [TerminalJob(pid: 50, name: "npm", foreground: true, stopped: false),
                    TerminalJob(pid: 60, name: "sleep", foreground: false, stopped: false),
                    TerminalJob(pid: 70, name: "vim", foreground: false, stopped: true)]
        check(jobs.map { $0.line(folder: "app") } == ["npm in app", "sleep in app (background)", "vim in app (stopped)"],
              "terminal: the quit question lists background and stopped jobs too")
        check(TerminalJob.summary(jobs) == "npm and 2 more" && TerminalJob.summary(Array(jobs.prefix(1))) == "npm"
              && TerminalJob.summary([]) == nil,
              "terminal: closing a tab names what it would end")
    }

    /// The dropdown and the notch tab with sample tabs and text in place of the live
    /// terminal view.
    @MainActor
    static func snapshotViews() -> [(name: String, view: AnyView)] {
        let store = TerminalStore.sample()
        let dropdown = TerminalDropdownChrome(store: store) { TerminalSamplePrompt() }
            .frame(width: 720, height: 420)
        let notch = TerminalNotchChrome(store: store) { TerminalSamplePrompt() }
            .frame(width: 758, height: 186)
            .background(Color.black)
        return [("terminal-dropdown", AnyView(dropdown)), ("terminal-notch", AnyView(notch))]
    }
}

extension TerminalFeature {
    func debugState() -> [String: Any] {
        ["sessions": sessions.map { ["id": $0.id, "shellPid": Int($0.shellPid), "ended": $0.ended, "folder": $0.directory ?? ""] as [String: Any] },
         "dropdownVisible": dropdown?.isVisible ?? false,
         "dropdownKey": dropdown?.isKey ?? false]
    }

    /// For `notch state` checks: shows or hides the menu bar terminal like the icon does.
    func debugToggle() { toggleFromStatusItem() }
}
