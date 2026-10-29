import AppKit

/// Process lookups for sessions: which app hosts a Claude Code process, and whether it
/// still runs. The walks take their lookups as closures so the self-test can use a
/// made-up process tree.
enum AgentsProcess {
    struct Info: Equatable {
        var parent: pid_t
        var name: String          // up to 16 characters (the kernel's p_comm)
    }

    /// Parent and name of a process, or nil if it's gone.
    static func info(_ pid: pid_t) -> Info? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return Info(parent: kp.kp_eproc.e_ppid, name: name)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env"]

    /// The hook sends its parent's pid. If Claude Code ran it through a shell that is
    /// still alive, that pid is the shell's; step up to the process that started it.
    /// Nil when `pid` is already gone: a dead pid must not replace the session's known one
    /// (the sweep would then drop a live session).
    static func claudeProcess(from pid: pid_t, info: (pid_t) -> Info?) -> pid_t? {
        guard info(pid) != nil else { return nil }
        var p = pid
        for _ in 0..<4 {
            guard let i = info(p), shells.contains(i.name), i.parent > 1 else { break }
            p = i.parent
        }
        return p
    }

    /// Walks up from `pid` to the first process that is a regular app with a window
    /// (Terminal, iTerm, VS Code, Claude), or this app. Nil when there is none (tmux,
    /// ssh, launchd jobs).
    static func hostApp(from pid: pid_t, own: pid_t, info: (pid_t) -> Info?, isApp: (pid_t) -> Bool) -> pid_t? {
        var p = pid
        var seen: Set<pid_t> = []
        while p > 1, seen.insert(p).inserted, seen.count < 64 {
            if p == own || isApp(p) { return p }
            guard let parent = info(p)?.parent else { return nil }
            p = parent
        }
        return nil
    }
}

/// Agent Away's state, as its menu bar app publishes it to its own hooks: flag files in
/// ~/Library/Application Support/AgentAway/run (`pid`, `away`, `lid`, `hot`, `askfirst`).
struct AgentsAwayStatus: Equatable {
    var running: Bool
    var keepAwake = false
    var lidClosed = false
    var askFirst = false
    var heat: String?            // what the heat guard is doing, while it acts

    /// One line for the tab: "Keep awake on · lid closed · heat guard: slowed ffmpeg".
    var line: String {
        guard running else { return "Agent Away isn't running" }
        guard keepAwake || askFirst else { return "Keep awake off" }
        var parts = [keepAwake ? "Keep awake on" : "Keep awake off"]
        if lidClosed { parts.append("lid closed") }
        if let heat { parts.append("heat guard: \(heat)") } else if keepAwake && lidClosed { parts.append("heat guard watching") }
        if askFirst { parts.append("ask first") }
        return parts.joined(separator: " · ")
    }
}

enum AgentsAway {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentAway")
    }

    static var installed: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("AgentAway.app").path)
    }

    /// Reads the flag files. Flags left by an app that no longer runs mean nothing, as
    /// in its own hook.
    static func read(runDir: URL, isRunning: (pid_t) -> Bool) -> AgentsAwayStatus {
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: runDir.appendingPathComponent(name).path) }
        func text(_ name: String) -> String? { try? String(contentsOf: runDir.appendingPathComponent(name), encoding: .utf8) }
        guard let pidText = text("pid"), let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, isRunning(pid) else { return AgentsAwayStatus(running: false) }
        var s = AgentsAwayStatus(running: true)
        s.keepAwake = exists("away")
        s.lidClosed = exists("lid")
        s.askFirst = exists("askfirst")
        if s.keepAwake, let hot = text("hot") { s.heat = heatSummary(hot) }
        return s
    }

    /// Shortens the heat guard's note (line 1: epoch, then "[Agent Away] Heat guard (…):
    /// slowed to efficiency cores: ffmpeg. Do not start…") to "slowed ffmpeg".
    static func heatSummary(_ note: String) -> String {
        let body = note.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? note
        guard let start = body.range(of: "): ") else { return "acting" }
        var what = String(body[start.upperBound...])
        if let end = what.range(of: ". Do not") { what = String(what[..<end.lowerBound]) }
        let short = what
            .replacingOccurrences(of: "paused until it cools down or the lid opens:", with: "paused")
            .replacingOccurrences(of: "slowed to efficiency cores:", with: "slowed")
            .replacingOccurrences(of: "cooled down, resumed slowly:", with: "resumed")
            .trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "acting" : short
    }

    /// The handoff Agent Away's documented command line uses (`AgentAway --away`, `--off`):
    /// a distributed notification its running copy acts on. `--off` also ends "ask first".
    static func setKeepAwake(_ on: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("local.agentaway.cmd"), object: on ? "--away" : "--off", userInfo: nil,
            deliverImmediately: true)
    }

    /// Whether `pid` is Agent Away's app (its pid file could be stale and the pid reused).
    static func isAgentAway(_ pid: pid_t) -> Bool {
        AgentsProcess.isAlive(pid) && AgentsProcess.info(pid)?.name == "AgentAway"
    }
}
