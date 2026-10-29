import AppKit
import Darwin

/// What a session's shell is doing, read from the kernel.
struct TerminalProbe: Sendable, Equatable {
    var directory: String?
    var foreground: TerminalForeground?
}

/// The command running in a session's foreground; nil while the shell waits at its prompt.
struct TerminalForeground: Sendable, Equatable {
    var pid: pid_t
    var name: String
    var started: Date
}

/// A job a hangup would end: one process group on a session's terminal, other than the
/// shell's own.
struct TerminalJob: Sendable, Equatable {
    var pid: pid_t          // the process group
    var name: String
    var foreground: Bool
    var stopped: Bool

    /// A line of the quit warning: "npm in app", "vim in app (stopped)".
    func line(folder: String) -> String {
        let state = stopped ? " (stopped)" : foreground ? "" : " (background)"
        return "\(name) in \(folder)\(state)"
    }

    /// What closing a tab would end, for its "press again" text: "npm", "npm and 2 more".
    static func summary(_ jobs: [TerminalJob]) -> String? {
        guard let first = jobs.first else { return nil }
        return jobs.count == 1 ? first.name : "\(first.name) and \(jobs.count - 1) more"
    }
}

/// Process-table lookups: parents, working folders and foreground jobs. Each is a few
/// cheap syscalls, safe on any thread.
enum TerminalProcess {
    /// The parent of `pid` (sysctl KERN_PROC_PID, `e_ppid`), or nil if it's gone.
    static func parent(of pid: pid_t) -> pid_t? {
        guard let info = entry(of: pid) else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// The process-table entry of `pid` (sysctl KERN_PROC_PID). Unlike proc_pidinfo's
    /// task details, it's there for every user's processes (root, setuid sudo).
    private static func entry(of pid: pid_t) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size else { return nil }
        return info
    }

    /// Every process-table entry `query` (KERN_PROC_PGRP, KERN_PROC_TTY and its argument)
    /// lists; empty if the table can't be read.
    private static func entries(_ query: [Int32]) -> [kinfo_proc] {
        var mib = [CTL_KERN, KERN_PROC] + query
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [] }
            guard size > 0 else { return [] }
            // Room for processes started between the two calls.
            var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
            size = list.count * stride
            let result = list.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
            if result == 0 { return Array(list.prefix(size / stride)) }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    /// The shell in `shells` that `pid` is, or descends from, walking up through `parent`.
    /// Stops at launchd, on a loop, or after 64 steps.
    static func owner(of pid: pid_t, shells: Set<pid_t>, parent: (pid_t) -> pid_t?) -> pid_t? {
        var current = pid
        var seen: Set<pid_t> = []
        for _ in 0..<64 {
            guard current > 1, seen.insert(current).inserted else { return nil }
            if shells.contains(current) { return current }
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }

    /// The current folder of `pid` (proc_pidinfo PROC_PIDVNODEPATHINFO).
    static func directory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { Self.string(from: $0) }
        return path.isEmpty ? nil : path
    }

    /// The name and start time of `pid`. proc_pidinfo PROC_PIDTBSDINFO has the longer
    /// name but only answers for this user's processes; the process table covers the
    /// rest (sudo and the root command it runs).
    static func details(of pid: pid_t) -> (name: String, started: Date)? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            var name = withUnsafeBytes(of: &info.pbi_name) { Self.string(from: $0) }
            if name.isEmpty { name = withUnsafeBytes(of: &info.pbi_comm) { Self.string(from: $0) } }
            let started = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
            return (name, started)
        }
        return entry(of: pid).map(details(from:))
    }

    private static func details(from entry: kinfo_proc) -> (name: String, started: Date) {
        var entry = entry
        let name = withUnsafeBytes(of: &entry.kp_proc.p_comm) { Self.string(from: $0) }
        let start = entry.kp_proc.p_un.__p_starttime
        return (name, Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000))
    }

    /// Live processes only: a zombie has ended, its parent just hasn't collected it.
    private static func isLive(_ entry: kinfo_proc) -> Bool {
        Int32(entry.kp_proc.p_stat) != SZOMB
    }

    /// The shell's folder, and the job in the terminal's foreground if it isn't the shell
    /// itself. `fd` is the pseudo-terminal's primary side.
    static func probe(shell: pid_t, fd: Int32) -> TerminalProbe {
        var probe = TerminalProbe(directory: directory(of: shell))
        guard fd >= 0 else { return probe }
        let group = tcgetpgrp(fd)
        guard group > 0, group != shell else { return probe }
        // Named after the group's leader; in a pipeline (cat f | less) the shell may have
        // collected the leader already, so then after a member still running. A group
        // with no process left (the terminal reports none while the shell takes it back)
        // isn't a job.
        let d = details(of: group)
            ?? entries([KERN_PROC_PGRP, group]).first(where: isLive).map(details(from:))
        if let d { probe.foreground = TerminalForeground(pid: group, name: d.name, started: d.started) }
        return probe
    }

    /// Every job on the shell's terminal, the foreground one first: what a hangup ends.
    /// Background and stopped jobs count too (the shell passes the hangup on to them).
    /// One entry per process group, named after its leader; processes in the shell's
    /// own group and prompt helpers aren't jobs. `fd` is the pseudo-terminal's primary
    /// side. Reads the whole terminal's process list: for quitting and closing, not polls.
    static func jobs(shell: pid_t, fd: Int32) -> [TerminalJob] {
        guard let shellEntry = entry(of: shell) else { return [] }
        let tty = shellEntry.kp_eproc.e_tdev
        guard tty != -1 else { return [] }             // NODEV: the shell has no terminal
        var members: [pid_t: [kinfo_proc]] = [:]
        for p in entries([KERN_PROC_TTY, tty]) where isLive(p) {
            let group = p.kp_eproc.e_pgid
            guard p.kp_proc.p_pid != shell, group != shell, group > 0 else { continue }
            members[group, default: []].append(p)
        }
        let front = fd >= 0 ? tcgetpgrp(fd) : -1
        var jobs: [TerminalJob] = []
        for (group, list) in members {
            guard let leader = list.first(where: { $0.kp_proc.p_pid == group })
                    ?? list.min(by: { $0.kp_proc.p_pid < $1.kp_proc.p_pid }) else { continue }
            let name = details(of: group)?.name ?? details(from: leader).name
            guard !helperPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            let stopped = list.allSatisfy { Int32($0.kp_proc.p_stat) == SSTOP }
            jobs.append(TerminalJob(pid: group, name: name, foreground: group == front, stopped: stopped))
        }
        jobs.sort { $0.pid < $1.pid }
        return jobs.filter(\.foreground) + jobs.filter { !$0.foreground }
    }

    /// Background helpers a prompt theme starts (powerlevel10k's git status daemon),
    /// which would otherwise make every quit ask.
    private static let helperPrefixes = ["gitstatusd"]

    private static func string(from raw: UnsafeRawBufferPointer) -> String {
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// The user's login shell and the environment it starts with.
enum TerminalShell {
    /// The account's shell (falls back to /bin/zsh) and its argv[0], which starts with a
    /// dash so the shell runs as a login shell and reads your profile.
    static func login() -> (path: String, execName: String) {
        var path = "/bin/zsh"
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let candidate = String(cString: shell)
            if !candidate.isEmpty, access(candidate, X_OK) == 0 { path = candidate }
        }
        return (path, execName(for: path))
    }

    static func execName(for path: String) -> String {
        "-" + ((path as NSString).lastPathComponent.isEmpty ? "zsh" : (path as NSString).lastPathComponent)
    }

    /// Variables from whatever launched the app that would mislead programs in the shell
    /// (another terminal's identity, a Claude Code session the app was started from).
    private static let dropped: Set<String> = [
        "TERM_SESSION_ID", "TERM_PROGRAM_VERSION", "ITERM_SESSION_ID", "ITERM_PROFILE", "LC_TERMINAL",
        "LC_TERMINAL_VERSION", "KITTY_WINDOW_ID", "KITTY_PID", "ALACRITTY_WINDOW_ID", "ALACRITTY_SOCKET",
        "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET", "TMUX", "TMUX_PANE", "STY", "INSIDE_EMACS",
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "SHLVL", "OLDPWD", "_",
        "__CFBundleIdentifier", "COLORFGBG",
    ]
    private static let droppedPrefixes = ["VSCODE_", "GHOSTTY_"]

    /// `base` plus the terminal's identity, as KEY=VALUE lines for the child process.
    /// `shell` fills in SHELL when whatever launched the app didn't set it.
    static func environment(base: [String: String], directory: String, version: String, shell: String? = nil) -> [String] {
        var env = base.filter { key, _ in
            !dropped.contains(key) && !droppedPrefixes.contains { key.hasPrefix($0) }
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "DynamicNotch"
        env["TERM_PROGRAM_VERSION"] = version
        env["PWD"] = directory
        if (env["LANG"] ?? "").isEmpty { env["LANG"] = "en_US.UTF-8" }
        if let shell, (env["SHELL"] ?? "").isEmpty { env["SHELL"] = shell }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// The path in an OSC 7 report ("file://host/Users/me/My%20Dir"), or a bare path.
    static func pathFromOSC7(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { return trimmed }
        guard let url = URL(string: trimmed), url.scheme == "file" || url.scheme == "kitty-shell-cwd" else { return nil }
        let path = url.path(percentEncoded: false)
        return path.isEmpty ? nil : path
    }

    /// "~" for home, "/" for the root, otherwise the folder's own name.
    static func folderName(_ path: String?, home: String) -> String {
        guard let path, !path.isEmpty else { return "~" }
        let clean = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if clean == home { return "~" }
        if clean == "/" { return "/" }
        return (clean as NSString).lastPathComponent
    }

    /// A session's tab title. While a command runs: the title it set (only one set after
    /// it started counts, so a finished program's title doesn't stick), else its name.
    /// At the prompt: the folder name.
    static func title(osc: String?, oscAt: Date?, foreground: TerminalForeground?, directory: String?, home: String) -> String {
        if let foreground {
            if let osc = osc?.trimmingCharacters(in: .whitespacesAndNewlines), !osc.isEmpty,
               let at = oscAt, at.timeIntervalSince(foreground.started) > -1 {
                return osc
            }
            return foreground.name
        }
        return folderName(directory, home: home)
    }
}

/// Command-key shortcuts the terminal handles itself (there's no main menu to do it).
enum TerminalKeyCommand: Equatable {
    case newTab, closeTab, selectTab(Int), nextTab, previousTab
    case clear, copy, cut, paste, selectAll
    case fontBigger, fontSmaller, fontReset
    case find, findNext, findPrevious

    static func from(_ event: NSEvent) -> TerminalKeyCommand? {
        guard event.type == .keyDown, let key = event.charactersIgnoringModifiers else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return from(key: key, command: flags.contains(.command), shift: flags.contains(.shift),
                    option: flags.contains(.option), control: flags.contains(.control))
    }

    /// `key` is the character typed without modifiers other than Shift, as AppKit's
    /// `charactersIgnoringModifiers` reports it.
    static func from(key: String, command: Bool, shift: Bool, option: Bool, control: Bool) -> TerminalKeyCommand? {
        guard command, !option, !control, key.count == 1 else { return nil }
        let k = key.lowercased()
        switch k {
        case "=", "+": return .fontBigger
        case "-", "_": return .fontSmaller
        case "{": return .previousTab
        case "}": return .nextTab
        case "[": return shift ? .previousTab : nil
        case "]": return shift ? .nextTab : nil
        case "g": return shift ? .findPrevious : .findNext
        default: break
        }
        guard !shift else { return nil }
        if let n = Int(k), (1...9).contains(n) { return .selectTab(n - 1) }
        switch k {
        case "t": return .newTab
        case "w": return .closeTab
        case "k": return .clear
        case "c": return .copy
        case "x": return .cut
        case "v": return .paste
        case "a": return .selectAll
        case "f": return .find
        case "0": return .fontReset
        default: return nil
        }
    }
}

enum TerminalTabMath {
    /// The index of the tab to show after closing tab `closed` of `count`, while tab
    /// `active` was shown; nil when no tabs remain. Closing the shown tab shows its right
    /// neighbour, or the new last tab.
    static func indexAfterClose(count: Int, active: Int, closed: Int) -> Int? {
        let remaining = count - 1
        guard remaining > 0 else { return nil }
        if closed < active { return active - 1 }
        if closed > active { return min(active, remaining - 1) }
        return min(closed, remaining - 1)
    }

    /// The next (`step` 1) or previous (`step` -1) tab, wrapping around.
    static func cycle(_ index: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + step) % count + count) % count
    }
}

enum TerminalHotkeyText {
    /// "ctrl+`" as macOS writes it: "⌃`". Modifiers in Apple's order (⌃⌥⇧⌘); nil when the
    /// text isn't a valid hotkey.
    static func label(_ text: String) -> String? {
        guard HotkeyCenter.parse(text) != nil else { return nil }
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let names = Set(parts.dropLast())
        var label = ""
        if names.contains("ctrl") || names.contains("control") { label += "⌃" }
        if names.contains("alt") || names.contains("opt") || names.contains("option") { label += "⌥" }
        if names.contains("shift") { label += "⇧" }
        if names.contains("cmd") || names.contains("command") { label += "⌘" }
        let key = parts.last ?? ""
        switch key {
        case "space": label += "Space"
        case "return", "enter": label += "↩"
        case "tab": label += "⇥"
        case "escape", "esc": label += "⎋"
        default: label += key.uppercased()
        }
        return label
    }
}

/// terminal.json: what the terminal remembers between launches.
struct TerminalSavedState: Codable, Equatable {
    var lastDirectory: String?
    var cursor = "block"                 // "block" or "bar"

    init(lastDirectory: String? = nil, cursor: String = "block") {
        self.lastDirectory = lastDirectory
        self.cursor = cursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastDirectory = try? c.decodeIfPresent(String.self, forKey: .lastDirectory)
        let style = (try? c.decodeIfPresent(String.self, forKey: .cursor)) ?? "block"
        cursor = ["block", "bar"].contains(style) ? style : "block"
    }
}

/// Where the menu bar dropdown goes and how its grip resizes it. Screen coordinates.
enum TerminalPlacement {
    static let minimumSize = CGSize(width: 360, height: 200)
    static let gap: CGFloat = 4
    static let margin: CGFloat = 8

    /// Centered under `anchor` (the menu bar icon), kept inside `visible` (the screen's
    /// visible frame). Without an anchor: centered at the top of the screen.
    static func dropdownFrame(size: CGSize, anchor: CGRect?, visible: CGRect) -> CGRect {
        let width = min(max(size.width, minimumSize.width), visible.width - 2 * margin)
        let top = min(anchor?.minY ?? visible.maxY, visible.maxY) - gap
        let height = min(max(size.height, minimumSize.height), top - visible.minY - margin)
        let centerX = anchor?.midX ?? visible.midX
        let x = min(max(centerX - width / 2, visible.minX + margin), visible.maxX - margin - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// The frame while dragging the bottom-right grip by (`dx`, `dy`) points from `start`
    /// (`dy` positive downward). The top edge stays put; the panel shifts left rather
    /// than leave the screen.
    static func resized(start: CGRect, dx: CGFloat, dy: CGFloat, visible: CGRect) -> CGRect {
        let width = min(max(start.width + dx, minimumSize.width), visible.width - 2 * margin)
        let height = min(max(start.height + dy, minimumSize.height), max(start.maxY - visible.minY - margin, minimumSize.height))
        let x = min(start.minX, visible.maxX - margin - width)
        return CGRect(x: max(x, visible.minX + margin), y: start.maxY - height, width: width, height: height)
    }
}
