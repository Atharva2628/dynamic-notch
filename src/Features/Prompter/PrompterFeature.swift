import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// The teleprompter: scripts are .md and .txt files in a folder, listed in the Prompter tab;
/// Start scrolls the chosen one in a strip right under the notch, with a countdown,
/// progress and time left, and a "prompter.running" activity with a Stop button.
///
/// Keys while the strip has the keyboard: Space plays and pauses, ↑↓ change the speed,
/// ←→ go back or ahead three lines, ⌘+ and ⌘− change the size, Esc stops. Resting the
/// pointer on the strip pauses it; scrolling over it moves the text. Speed and size are
/// saved to the settings. On first start, an empty folder gets Notchy's scripts.
@MainActor
final class PrompterFeature: Feature {
    static let activityID = "prompter.running"
    private static let noticeID = "prompter.notice"

    private let context: AppContext
    let library: PrompterLibrary
    let tabState = PrompterTabState()
    private let window = PrompterWindowController()
    private let menuTarget = PrompterMenuTarget()
    private var startItem: NSMenuItem?
    private var voice: PrompterVoiceFollower?
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var bag = Set<AnyCancellable>()
    private var applied: Config?
    private var pendingSettings: (speed: Double, fontSize: Double)?
    private var persistWork: DispatchWorkItem?
    private var shownSignature: String?
    private var stripHadKeys = false             // the strip had the keys when the notch covered it

    init(context: AppContext) {
        self.context = context
        library = PrompterLibrary(folder: Self.folder(for: context.config, context: context),
                                  stateURL: context.dataURL("prompter.json"))
    }

    /// The scripts folder: the setting, or Application Support/DynamicNotch/Prompter.
    static func folder(for config: Config, context: AppContext) -> URL {
        let path = config.prompterFolder.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? context.dataURL("Prompter/") : Config.expand(path)
    }

    func start() {
        let actions = PrompterActions(
            start: { [weak self] in self?.start($0) },
            stop: { [weak self] in self?.stopPrompter() },
            newScript: { [weak self] in self?.newScript() },
            openFolder: { [weak self] in self?.openFolder() },
            edit: { [weak self] in self?.openInEditor($0.url) },
            reveal: { [weak self] in
                self?.context.model.close()
                NSWorkspace.shared.activateFileViewerSelecting([$0.url])
            },
            importNotchy: { [weak self] in self?.importNotchy() },
            setSpeed: { [weak self] v in self?.context.model.updateConfig { $0.prompterSpeed = min(max(v, 5), 300) } },
            setFontSize: { [weak self] v in self?.context.model.updateConfig { $0.prompterFontSize = min(max(v, 10), 60) } },
            setVoiceFollow: { [weak self] on in self?.context.model.updateConfig { $0.prompterVoiceFollow = on } })
        let library = library, state = tabState
        context.registerTab(.prompter) { PrompterTabView(library: library, state: state, actions: actions) }
        context.model.onTabShown[.prompter] = { [weak self] in self?.library.reload() }

        // Fires now with the current settings, then on every change.
        context.model.$config
            .sink { [weak self] config in MainActor.assumeIsolated { self?.apply(config) } }
            .store(in: &bag)
        // $geometry fires before the value changes; place the strip once it has.
        context.model.$geometry
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.placeWindow() } }
            .store(in: &bag)
        // The open notch and its peeks cover the strip. objectWillChange fires before the
        // change lands: note who has the keys now, and look at the notch once it has.
        context.model.objectWillChange
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.noteKeys() } }
            .store(in: &bag)
        context.model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.syncNotchHold() } }
            .store(in: &bag)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeWindow() }
        }

        window.onFrame = { [weak self] in self?.sessionChanged() }
        window.onAutoClose = { [weak self] in self?.stopPrompter() }
        installKeyMonitor()
        addMenu()
        library.loadInitial()
    }

    func stop() {
        stopPrompter()
        flushSettings()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        bag.removeAll()
        library.stopWatching()
        context.model.onTabShown[.prompter] = nil
        context.activities.removeAll(prefix: "prompter.")
    }

    /// Mirrors the settings into the tab and a running strip. Only values that changed are
    /// passed on, so an unrelated settings save doesn't undo a speed set with the arrow keys.
    private func apply(_ config: Config) {
        let old = applied
        applied = config
        if tabState.speed != config.prompterSpeed { tabState.speed = config.prompterSpeed }
        if tabState.fontSize != config.prompterFontSize { tabState.fontSize = config.prompterFontSize }
        if tabState.wordsPerMinute != config.prompterWordsPerMinute { tabState.wordsPerMinute = config.prompterWordsPerMinute }
        if tabState.voiceFollow != config.prompterVoiceFollow { tabState.voiceFollow = config.prompterVoiceFollow }
        library.setFolder(Self.folder(for: config, context: context))

        guard let old, let session = window.session else { return }
        if old.prompterSpeed != config.prompterSpeed { session.speed = config.prompterSpeed }
        if old.prompterFontSize != config.prompterFontSize { session.fontSize = config.prompterFontSize }
        if old.prompterWordsPerMinute != config.prompterWordsPerMinute { session.wordsPerMinute = config.prompterWordsPerMinute }
        if old.prompterWidth != config.prompterWidth { window.place(stripFrame(config), topInset: stripInset) }
        // Turning voice follow off frees the microphone now; turning it on waits for the next Start.
        if !config.prompterVoiceFollow, voice != nil || session.voice != .off {
            voice?.stop()
            voice = nil
            session.voice = .off
            session.show("Voice follow off")
        }
        window.updateLink()
        sessionChanged()
    }

    // MARK: Running

    /// Reads the script again (it may have been edited) and starts the strip.
    func start(_ script: PrompterScript) {
        library.freshCopy(of: script) { [weak self] fresh in
            guard let self else { return }
            guard let fresh else {
                self.tabState.say("\(script.title) is gone from the folder.")
                self.library.reload()
                return
            }
            guard fresh.words > 0 else {
                self.tabState.say("\(fresh.title) is empty. Add some text first.")
                return
            }
            self.begin(fresh)
        }
    }

    private func begin(_ script: PrompterScript) {
        endSession()
        let c = context.config
        let session = PrompterSession(script: script, speed: c.prompterSpeed, fontSize: c.prompterFontSize,
                                      wordsPerMinute: c.prompterWordsPerMinute, followVoice: c.prompterVoiceFollow)
        library.select(script)
        tabState.runningID = script.id
        context.model.close()
        window.show(session, frame: stripFrame(), topInset: stripInset)
        // show() gave the strip the keys. Starts held when the notch is still peeking; the
        // sink sees only later changes.
        stripHadKeys = true
        syncNotchHold()
        if c.prompterVoiceFollow { startVoice(for: session) }
        sessionChanged()
        updateMenu()
        PrompterLog.logger.info("prompter started: \(session.words) words, voice follow \(c.prompterVoiceFollow ? "on" : "off", privacy: .public)")
    }

    /// Stops the strip, the microphone and the activity.
    func stopPrompter() {
        guard window.isShown || voice != nil else { return }
        endSession()
        flushSettings()
        updateMenu()
    }

    private func endSession() {
        voice?.stop()
        voice = nil
        window.hide()
        context.activities.remove(id: Self.activityID)
        shownSignature = nil
        stripHadKeys = false
        tabState.runningID = nil
    }

    /// Before each notch change lands: whether the strip has the keys, so they can go back
    /// to it once the notch is out of the way. Not while covered, when the notch may have them.
    private func noteKeys() {
        guard let s = window.session, !s.notchHeld else { return }
        stripHadKeys = window.panel.isKeyWindow
    }

    /// Holds the strip while the open notch or a peek covers it: every peek reaches past the
    /// reading line, and the strip gets no hover events under the notch's window. Lid
    /// closed, the strip hangs under the menu bar and nothing covers it.
    private func syncNotchHold() {
        guard let s = window.session else { return }
        let m = context.model
        let covered = m.geometry != nil && (m.isOpen || m.mode == .peek)
        // Only on a change: sessionChanged updates the activity, which fires objectWillChange again.
        guard s.notchHeld != covered else { return }
        s.notchHeld = covered
        window.updateLink()
        sessionChanged()
        // A typing tab took the keys from the strip; give them back. Keys that were in
        // another app stay there.
        if !covered, stripHadKeys, !window.panel.isKeyWindow { window.panel.makeKey() }
    }

    private func startVoice(for session: PrompterSession) {
        let follower = PrompterVoiceFollower()
        follower.onTranscript = { [weak self, weak session] text in
            guard let self, let session, self.window.session === session else { return }
            if session.heard(text) { self.window.updateLink() }
        }
        follower.onState = { [weak self, weak session] state in
            guard let self, let session, self.window.session === session else { return }
            session.voice = state
            if case .failed(let why) = state {
                session.show("Voice follow off")
                self.tabState.say(why)
            }
            self.window.updateLink()
            self.sessionChanged()
        }
        voice = follower
        follower.start(script: session.plain)
    }

    /// `config` when called from the settings sink, which runs before the model has the new value.
    private func stripFrame(_ config: Config? = nil) -> CGRect {
        let fallback = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return PrompterScrollMath.windowFrame(notch: context.model.geometry, fallback: fallback,
                                              width: CGFloat((config ?? context.config).prompterWidth),
                                              height: PrompterSession.stripHeight)
    }

    private func placeWindow() {
        guard window.isShown else { return }
        window.place(stripFrame(), topInset: stripInset)
    }

    /// The notch's row the strip starts with (none with the lid closed).
    private var stripInset: CGFloat { context.model.geometry?.notchSize.height ?? 0 }

    // MARK: Activity

    /// Posts or updates "prompter.running" when what it shows changed (a few times a
    /// second at most, not every frame).
    private func sessionChanged() {
        guard let s = window.session else { return }
        let activity = Self.activity(for: s)
        let signature = "\(activity.subtitle ?? "")|\(Int(s.progress * 100))|\(activity.actions.map(\.title))"
        guard signature != shownSignature else { return }
        shownSignature = signature
        if context.activities.activity(id: Self.activityID) == nil {
            context.activities.post(activity) { [weak self] id in self?.activityAction(id) }
        } else {
            context.activities.update(id: Self.activityID) {
                $0.subtitle = activity.subtitle
                $0.accessory = activity.accessory
                $0.actions = activity.actions
            }
        }
    }

    static func activity(for s: PrompterSession) -> Activity {
        let left = "\(PrompterText.clock(s.timeLeft)) left"
        let subtitle: String
        switch s.phase {
        case .countdown: subtitle = s.userPaused ? "Paused" : "Starting…"
        case .finished: subtitle = "Finished"
        case .running:
            if s.userPaused || s.hoverPaused { subtitle = "Paused · \(left)" }
            else if s.notchHeld { subtitle = "Paused while the notch is open" }   // the button still says Pause
            else { subtitle = left }
        }
        let paused = s.userPaused || s.phase == .finished
        return Activity(
            id: activityID, priority: .info, symbol: "text.aligncenter",
            accessory: .progress(s.progress), title: s.title, subtitle: subtitle,
            actions: [ActivityAction(id: "pause", title: s.phase == .finished ? "Again" : (paused ? "Resume" : "Pause")),
                      ActivityAction(id: "stop", title: "Stop", style: .destructive)],
            opensTab: .prompter)
    }

    private func activityAction(_ id: String) {
        switch id {
        case "stop": stopPrompter()
        case "pause":
            window.session?.togglePause()
            window.updateLink()
            sessionChanged()
        default: break
        }
    }

    // MARK: Keyboard

    /// Keys reach the strip while it's the key window, and the tab while the notch is (core
    /// arranges that for the Prompter tab).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) == true }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.window === window.panel, let session = window.session { return handleStripKey(event, session) }
        let model = context.model
        guard model.isOpen, model.currentTab == .prompter, event.window === context.notchWindow else { return false }
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_UpArrow: library.moveSelection(-1)
        case kVK_DownArrow: library.moveSelection(1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if tabState.runningID == nil, let selected = library.selected { start(selected) }
        default: return false
        }
        return true
    }

    /// Space, ↑↓, ←→, ⌘+/⌘−, Esc. Other plain keys are swallowed so they don't beep.
    private func handleStripKey(_ event: NSEvent, _ s: PrompterSession) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = Int(event.keyCode)
        if flags.contains(.command) {
            guard flags.isSubset(of: [.command, .shift]) else { return false }
            let chars = event.charactersIgnoringModifiers ?? ""
            if chars == "=" || chars == "+" || key == kVK_ANSI_KeypadPlus {
                s.changeFontSize(by: PrompterSession.fontStep)
            } else if chars == "-" || chars == "_" || key == kVK_ANSI_KeypadMinus {
                s.changeFontSize(by: -PrompterSession.fontStep)
            } else {
                return false
            }
            rememberSettings(s)
            return true
        }
        guard flags.isSubset(of: [.shift]) else { return false }
        switch key {
        case kVK_Escape:
            stopPrompter()
            return true
        case kVK_Space: s.togglePause()
        case kVK_UpArrow:
            s.changeSpeed(by: PrompterSession.speedStep)
            rememberSettings(s)
        case kVK_DownArrow:
            s.changeSpeed(by: -PrompterSession.speedStep)
            rememberSettings(s)
        case kVK_LeftArrow: s.seek(by: -s.lineStep)
        case kVK_RightArrow: s.seek(by: s.lineStep)
        default: return true
        }
        window.updateLink()
        sessionChanged()
        return true
    }

    /// Saves speed and size to the settings once the keys rest, not on every repeat.
    private func rememberSettings(_ s: PrompterSession) {
        pendingSettings = (s.speed, s.fontSize)
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushSettings() }
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func flushSettings() {
        persistWork?.cancel()
        persistWork = nil
        guard let pending = pendingSettings else { return }
        pendingSettings = nil
        context.model.updateConfig {
            $0.prompterSpeed = pending.speed
            $0.prompterFontSize = pending.fontSize
        }
    }

    // MARK: Files

    private func newScript() {
        library.createScript { [weak self] url in
            guard let self else { return }
            guard let url else {
                self.tabState.say("Couldn't create a script in \(PrompterTabView.shortPath(self.library.folder)).")
                return
            }
            self.openInEditor(url)
        }
    }

    /// Opens in the app that handles the file type, or TextEdit when none does.
    private func openInEditor(_ url: URL) {
        context.model.close()
        let workspace = NSWorkspace.shared
        if workspace.urlForApplication(toOpen: url) != nil {
            workspace.open(url)
        } else if let textEdit = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            workspace.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func openFolder() {
        context.model.close()
        NSWorkspace.shared.open(library.folder)
    }

    private func importNotchy() {
        library.importNotchy { [weak self] count in
            guard let self else { return }
            let text: String
            switch count {
            case nil: text = "Notchy has no prompter scripts on this Mac."
            case 0?: text = "Notchy's scripts are already here."
            case 1?: text = "Imported 1 script from Notchy."
            case let n?: text = "Imported \(n) scripts from Notchy."
            }
            self.tabState.say(text)
            let model = self.context.model
            if !(model.isOpen && model.currentTab == .prompter) {
                self.context.activities.post(Activity(
                    id: Self.noticeID, priority: .info, symbol: "square.and.arrow.down",
                    title: "Prompter", subtitle: text, duration: 4, opensTab: .prompter))
            }
        }
    }

    // MARK: Menu

    private func addMenu() {
        let start = menuTarget.item("Start Prompter") { [weak self] in self?.menuStart() }
        let importItem = menuTarget.item("Import Notchy Scripts") { [weak self] in self?.importNotchy() }
        startItem = start
        context.statusItem.extraItems += [start, importItem]
    }

    /// Opens the tab to pick a script. With no notch on screen (lid closed) or the tab
    /// hidden, starts the selected script instead, or shows the empty folder. While
    /// running, the same item stops it.
    private func menuStart() {
        let model = context.model
        if window.isShown {
            stopPrompter()
        } else if model.geometry != nil && model.visibleTabs.contains(.prompter) {
            model.open(tab: .prompter)
        } else if let selected = library.selected {
            start(selected)
        } else {
            openFolder()
        }
    }

    private func updateMenu() {
        startItem?.title = window.isShown ? "Stop Prompter" : "Start Prompter"
    }

    // MARK: Snapshots

    /// The tab with sample scripts, the tab with none, and the strip running and counting down.
    static func snapshotViews() -> [(name: String, view: AnyView)] {
        let samples = sampleScripts()
        let state = PrompterTabState()
        let tab = PrompterTabView(library: PrompterLibrary(sample: samples, selected: samples[0].id), state: state,
                                  actions: PrompterActions(), scrolls: false)
        let empty = PrompterTabView(library: PrompterLibrary(sample: [], selected: nil), state: PrompterTabState(),
                                    actions: PrompterActions(), scrolls: false)

        let running = PrompterSession(script: samples[0], speed: 40, fontSize: 20, wordsPerMinute: 150, followVoice: false)
        running.setForSnapshot(phase: .running, position: 64, contentHeight: 560)
        let countdown = PrompterSession(script: samples[0], speed: 40, fontSize: 20, wordsPerMinute: 150, followVoice: true)
        countdown.setForSnapshot(phase: .countdown, position: 0, contentHeight: 560, countdown: 2.4)

        func panel<V: View>(_ view: V, _ size: CGSize) -> AnyView {
            AnyView(view.frame(width: size.width, height: size.height).background(Color.black).environment(\.colorScheme, .dark))
        }
        let tabSize = CGSize(width: 758, height: 186)
        let strip = CGSize(width: 420, height: PrompterSession.stripHeight + 32)
        return [
            ("prompter-tab", panel(tab, tabSize)),
            ("prompter-tab-empty", panel(empty, tabSize)),
            ("prompter-strip", AnyView(PrompterStripView(session: running, topInset: 32).frame(width: strip.width, height: strip.height))),
            ("prompter-strip-countdown", AnyView(PrompterStripView(session: countdown, topInset: 32).frame(width: strip.width, height: strip.height))),
        ]
    }

    static func sampleScripts() -> [PrompterScript] {
        let folder = URL(fileURLWithPath: "/tmp/Prompter", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        func script(_ name: String, _ text: String, ago: Double) -> PrompterScript {
            PrompterScript(url: folder.appendingPathComponent(name), source: text, modified: date.addingTimeInterval(-ago))
        }
        return [
            script("Sample script.md", """
            # Sample script

            This is a **sample script** for the prompter. It scrolls at a steady pace, or follows your voice when that is on.

            Blank lines start a new paragraph. Headings, lists and emphasis are cleaned up for reading, so the text stays easy to follow.

            - First point to cover
            - Second point to cover

            Finish with a short summary and thank everyone for their time.
            """, ago: 3600),
            script("Meeting intro.md", "Good morning, everyone, and thanks for joining. I'll start with a quick recap, then we'll go through the agenda and leave time for questions.", ago: 86_400),
            script("Notes.txt", "Plain text files work too. Each paragraph shows as written.", ago: 3 * 86_400),
        ]
    }
}

/// Runs a closure per menu item (NSMenuItem needs an Objective-C target).
@MainActor
private final class PrompterMenuTarget: NSObject {
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
