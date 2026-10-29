import AppKit
import SwiftTerm

/// The terminal view a session draws in. The same view moves between the menu bar
/// dropdown and the notch.
final class TerminalSessionView: LocalProcessTerminalView {
    /// The first click on an inactive panel goes to the terminal (selects, positions).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One shell in a pseudo-terminal. Lives until its shell exits or its tab is closed.
@MainActor
final class TerminalSession: LocalProcessTerminalViewDelegate {
    let id: Int
    let view: TerminalSessionView
    /// The shell's folder, from OSC 7 or the process table.
    private(set) var directory: String?
    private(set) var oscTitle: String?
    private(set) var oscTitleAt: Date?
    /// The job in the foreground, as of the last probe.
    var foreground: TerminalForeground?
    /// The shell exited or failed to start; its view stays until the tab goes.
    private(set) var ended = false
    private var reportsDirectory = false

    var onExit: ((TerminalSession) -> Void)?
    var onChange: ((TerminalSession) -> Void)?
    var onDirectory: ((String) -> Void)?

    init(id: Int, fontSize: Double, scrollback: Int, cursor: CursorStyle, size: CGSize) {
        self.id = id
        let options = TerminalOptions(termName: "xterm-256color", cursorStyle: cursor, scrollback: scrollback)
        view = TerminalSessionView(frame: CGRect(origin: .zero, size: size),
                                   font: Self.font(size: fontSize), options: options)
        view.processDelegate = self
        TerminalPalette.apply(to: view)
    }

    var shellPid: pid_t { view.process.shellPid }
    var ptyFD: Int32 { view.process.childfd }
    var isRunning: Bool { !ended && view.process.running }

    /// The shell itself owns the terminal: no command is running in the foreground.
    var isAtPrompt: Bool {
        let fd = ptyFD, shell = shellPid
        guard isRunning, fd >= 0, shell > 0 else { return false }
        return tcgetpgrp(fd) == shell
    }

    static func font(size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    func start(shell: String, execName: String, environment: [String], directory: String) {
        self.directory = directory
        view.startProcess(executable: shell, args: [], environment: environment,
                          execName: execName, currentDirectory: directory)
        // forkpty's primary side isn't close-on-exec, so every later tab's shell (and all
        // it runs) would inherit this terminal. Sessions start on the main thread, so no
        // other tab forks before the flag is set.
        let fd = ptyFD
        if fd >= 0 {
            let flags = fcntl(fd, F_GETFD)
            if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
        }
    }

    func title(home: String) -> String {
        TerminalShell.title(osc: oscTitle, oscAt: oscTitleAt, foreground: foreground, directory: directory, home: home)
    }

    /// Applies a probe from the process table; returns true if anything shown changed.
    /// Once the shell reports its folder itself (OSC 7), that wins: the process table
    /// has the resolved path (/private/tmp for /tmp).
    @discardableResult
    func apply(_ probe: TerminalProbe) -> Bool {
        var changed = false
        if !reportsDirectory, let dir = probe.directory, dir != directory {
            directory = dir
            onDirectory?(dir)
            changed = true
        }
        if probe.foreground != foreground {
            foreground = probe.foreground
            changed = true
        }
        return changed
    }

    /// ⌘K: drops the scrollback; at the prompt, also has the shell clear the screen and
    /// redraw its prompt (Control-L), keeping anything typed.
    func clear(shellIdle: Bool) {
        view.clearScrollback()
        if shellIdle { view.send(txt: "\u{0c}") }
    }

    /// Ends the shell the way closing a terminal window does: a hangup to its foreground
    /// job and to the shell, which passes it on to its other jobs.
    func hangUp() {
        let shell = shellPid
        guard shell > 0, !ended else { return }
        let fd = ptyFD
        if fd >= 0 {
            let group = tcgetpgrp(fd)
            if group > 0, group != shell { kill(-group, SIGHUP) }
        }
        kill(shell, SIGHUP)
    }

    /// Forces a shell that ignored the hangup to quit.
    func kill9() {
        let shell = shellPid
        if shell > 0 { kill(shell, SIGKILL) }
    }

    /// Releases the view's renderers for good.
    func close() {
        view.removeFromSuperview()
        view.processDelegate = nil
        view.updateUiClosed()
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        oscTitle = title
        oscTitleAt = Date()
        onChange?(self)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let path = TerminalShell.pathFromOSC7(directory) else { return }
        reportsDirectory = true
        guard path != self.directory else { return }
        self.directory = path
        onDirectory?(path)
        onChange?(self)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !ended else { return }
        ended = true
        onExit?(self)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        // SwiftTerm prints the error in the view; keep the tab so it can be read.
        ended = true
        foreground = nil
        onChange?(self)
    }
}

/// Colors for a black panel: a soft white foreground and an ANSI palette that stays
/// readable on black (bright black is dim but legible, for autosuggestions).
enum TerminalPalette {
    static let ansi: [(UInt16, UInt16, UInt16)] = [
        (0x3A, 0x3D, 0x43), (0xFF, 0x5F, 0x59), (0x5F, 0xD0, 0x68), (0xF5, 0xC4, 0x51),
        (0x5E, 0xA3, 0xFF), (0xC7, 0x92, 0xEA), (0x4F, 0xD6, 0xD6), (0xD0, 0xD3, 0xD8),
        (0x6B, 0x70, 0x79), (0xFF, 0x7B, 0x72), (0x7E, 0xE7, 0x87), (0xFF, 0xD8, 0x66),
        (0x79, 0xB8, 0xFF), (0xD2, 0xA8, 0xFF), (0x76, 0xE4, 0xE4), (0xFF, 0xFF, 0xFF),
    ]

    @MainActor
    static func apply(to view: TerminalView) {
        view.installColors(ansi.map { Color(red8: $0.0, green8: $0.1, blue8: $0.2) })
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = NSColor(srgbRed: 0.90, green: 0.91, blue: 0.92, alpha: 1)
        view.caretColor = NSColor(white: 0.92, alpha: 1)
        view.caretTextColor = .black
        view.selectedTextBackgroundColor = NSColor(srgbRed: 0.22, green: 0.34, blue: 0.56, alpha: 1)
        view.selectedTextForegroundColor = .white
        view.appearance = NSAppearance(named: .darkAqua)
    }
}
