import Foundation

/// One Claude Code hook event as hooks/notch-hook.sh forwards it:
/// {"type":"hook","event":E,"pid":P,"wait":Bool,"payload":{…the hook's stdin…}}.
struct AgentsHookEvent {
    var name: String
    var pid: pid_t?
    var wait: Bool
    var payload: [String: Any]

    init(name: String, pid: pid_t? = nil, wait: Bool = false, payload: [String: Any]) {
        self.name = name
        self.pid = pid
        self.wait = wait
        self.payload = payload
    }

    init?(message: [String: Any]) {
        guard let name = message["event"] as? String, !name.isEmpty else { return nil }
        self.init(name: name, pid: Self.pidValue(message["pid"]), wait: message["wait"] as? Bool ?? false,
                  payload: message["payload"] as? [String: Any] ?? [:])
    }

    var sessionID: String? { (payload["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var cwd: String? { (payload["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var toolName: String? { payload["tool_name"] as? String }
    var toolInput: [String: Any] { payload["tool_input"] as? [String: Any] ?? [:] }
    var notificationType: String? { payload["notification_type"] as? String }
    /// The subagent the event comes from; nil for the session's main thread.
    var agentID: String? { (payload["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    /// Rules Claude Code offers for "always allow", passed back unchanged.
    var permissionSuggestions: [Any] { payload["permission_suggestions"] as? [Any] ?? [] }

    private static func pidValue(_ value: Any?) -> pid_t? {
        let n: Int?
        switch value {
        case let v as NSNumber: n = v.intValue
        case let v as String: n = Int(v)
        default: n = nil
        }
        guard let n, n > 1, n <= Int(Int32.max) else { return nil }
        return pid_t(n)
    }
}

enum AgentsSessionState: String {
    case working, waiting, idle

    var title: String {
        switch self {
        case .working: "Working"
        case .waiting: "Waiting for you"
        case .idle: "Idle"
        }
    }

    /// List order: what needs you first.
    var rank: Int {
        switch self {
        case .waiting: 0
        case .working: 1
        case .idle: 2
        }
    }
}

/// A Claude Code session (CLI or desktop app), keyed by its session_id.
struct AgentsSession: Identifiable, Equatable {
    let id: String
    var project: String
    var cwd: String
    var state: AgentsSessionState = .idle
    var tool: String?                 // "Bash: npm test" while a tool runs or waits for approval
    var started: Date
    var lastEvent: Date
    var pid: pid_t?                   // the Claude Code process
    var pingedSincePrompt = false     // a done ping went out since the last prompt

    /// The folder's name. An empty cwd must not reach URL(fileURLWithPath:), which would
    /// name this app's own working directory instead.
    static func project(for cwd: String) -> String {
        guard !cwd.isEmpty else { return "Claude Code" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? cwd : name
    }
}

/// What a hook event asks the notch to announce, besides updating the session.
enum AgentsPing: Equatable {
    case finished        // Stop: the turn is over
    case idle            // idle_prompt: finished a minute ago and nobody typed
    case needsInput      // agent_needs_input

    var title: String {
        switch self {
        case .finished: "Claude finished"
        case .idle: "Claude is waiting for you"
        case .needsInput: "Claude needs your input"
        }
    }
}

/// The running sessions and the state machine that hook events drive.
struct AgentsSessionBook {
    private(set) var sessions: [String: AgentsSession] = [:]

    /// Waiting first, then working, then idle; most recent activity first within each.
    var ordered: [AgentsSession] {
        sessions.values.sorted {
            $0.state.rank != $1.state.rank ? $0.state.rank < $1.state.rank
                : $0.lastEvent != $1.lastEvent ? $0.lastEvent > $1.lastEvent : $0.id < $1.id
        }
    }

    func count(_ state: AgentsSessionState) -> Int { sessions.values.filter { $0.state == state }.count }

    /// Applies one event. Returns the ping to show, if the event calls for one.
    @discardableResult
    mutating func apply(_ e: AgentsHookEvent, now: Date) -> AgentsPing? {
        guard let id = e.sessionID else { return nil }
        if e.name == "SessionEnd" {
            sessions[id] = nil
            return nil
        }
        let cwd = e.cwd ?? ""
        var s = sessions[id] ?? AgentsSession(id: id, project: AgentsSession.project(for: cwd), cwd: cwd,
                                              started: now, lastEvent: now, pid: e.pid)
        s.lastEvent = now
        if let pid = e.pid { s.pid = pid }
        if s.cwd.isEmpty, !cwd.isEmpty {
            s.cwd = cwd
            s.project = AgentsSession.project(for: cwd)
        }
        var ping: AgentsPing?
        switch e.name {
        case "SessionStart":
            s.state = .idle
            s.tool = nil
        case "UserPromptSubmit":
            s.state = .working
            s.tool = nil
            s.pingedSincePrompt = false
        case "PreToolUse":
            s.state = .working
            s.tool = e.toolName.map { AgentsToolText.summary(tool: $0, input: e.toolInput) }
        case "PostToolUse", "PostToolUseFailure":
            s.state = .working
            s.tool = nil
        case "PermissionRequest":
            s.state = .waiting
            s.tool = e.toolName.map { AgentsToolText.summary(tool: $0, input: e.toolInput) }
        case "Stop":
            s.state = .idle
            s.tool = nil
            s.pingedSincePrompt = true
            ping = .finished
        case "Notification":
            switch e.notificationType {
            case "permission_prompt":
                // The PermissionRequest hook already announced this dialog.
                s.state = .waiting
            case "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog":
                s.state = .waiting
                s.pingedSincePrompt = true
                ping = .needsInput
            case "idle_prompt":
                s.state = .idle
                s.tool = nil
                // Stop already pinged for this turn; a minute later is no news.
                if !s.pingedSincePrompt { ping = .idle }
                s.pingedSincePrompt = true
            default:
                break
            }
        default:
            break
        }
        sessions[id] = s
        return ping
    }

    mutating func setState(_ id: String, _ state: AgentsSessionState) {
        sessions[id]?.state = state
        if state != .waiting { sessions[id]?.tool = nil }
    }

    mutating func remove(_ id: String) { sessions[id] = nil }

    /// Drops sessions whose Claude Code process is gone, and ones without a pid that
    /// have been silent for 3 hours. Returns the ids removed.
    mutating func sweep(now: Date, isAlive: (pid_t) -> Bool) -> [String] {
        let dead = sessions.values.filter { s in
            if let pid = s.pid { return !isAlive(pid) }
            return now.timeIntervalSince(s.lastEvent) > 3 * 3600
        }.map(\.id)
        for id in dead { sessions[id] = nil }
        return dead
    }
}

/// A permission request waiting for Allow or Deny in the notch.
struct AgentsPermissionRequest: Identifiable, Equatable {
    let id: Int
    let sessionID: String
    let agentID: String?             // the subagent asking; nil for the main thread
    let project: String
    let tool: String
    let detail: String               // the full command, path or URL
    let note: String?                // Claude's description of the command
    let alwaysScope: AgentsAllowScope?   // what "Always allow" allows; nil without a suggestion
    let received: Date

    var canAlwaysAllow: Bool { alwaysScope != nil }   // Claude Code suggested a rule

    init(id: Int, event: AgentsHookEvent, project: String, received: Date) {
        let tool = event.toolName ?? "Tool"
        self.id = id
        self.sessionID = event.sessionID ?? ""
        self.agentID = event.agentID
        self.project = project
        self.tool = tool
        self.detail = AgentsToolText.detail(tool: tool, input: event.toolInput)
        self.note = (event.toolInput["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.alwaysScope = AgentsAllowScope(suggestions: event.permissionSuggestions)
        self.received = received
    }
}

/// What "Always allow" allows, read from Claude Code's suggestions, which go back unchanged
/// as its own dialog sends them. They are not always one narrow rule: an edit's is usually
/// "accept all edits this session", a path outside the project adds a whole folder.
struct AgentsAllowScope: Equatable {
    var button: String       // short, for the button: "Always allow", "Allow all edits", "Allow folder"
    var text: String         // the whole scope, on one line: "Always allow Bash(npm test:*) in this project"

    private enum Kind { case edits, folder, rule, other }

    init?(suggestions: [Any]) {
        guard !suggestions.isEmpty else { return nil }
        let parts = suggestions.map(Self.describe)
        let kinds = parts.map { $0.kind }
        if kinds.contains(.other) { button = "Always allow" }
        else if kinds.contains(.edits) { button = "Allow all edits" }
        else if kinds.allSatisfy({ $0 == .folder }) { button = "Allow folder" }
        else { button = "Always allow" }
        text = parts.map { $0.text }.joined(separator: "; ")
    }

    /// One suggestion in words. Anything unfamiliar is shown as its JSON.
    private static func describe(_ value: Any) -> (kind: Kind, text: String) {
        guard let s = value as? [String: Any] else { return (.other, raw(value)) }
        let place = scope(s["destination"] as? String)
        func with(_ text: String) -> String { place.map { "\(text) \($0)" } ?? text }
        switch s["type"] as? String {
        case "setMode" where s["mode"] as? String == "acceptEdits":
            return (.edits, with("Allow all edits"))
        case "addDirectories":
            let names = (s["directories"] as? [String] ?? []).map(folderName).filter { !$0.isEmpty }
            if !names.isEmpty { return (.folder, with("Allow access to \(names.joined(separator: ", "))")) }
        case "addRules" where (s["behavior"] as? String ?? "allow") == "allow":
            let rules = (s["rules"] as? [[String: Any]] ?? []).map(rule)
            guard !rules.isEmpty else { break }
            let folders = rules.allSatisfy { $0.folder }
            return (folders ? .folder : .rule,
                    with((folders ? "Allow " : "Always allow ") + rules.map { $0.text }.joined(separator: ", ")))
        default:
            break
        }
        return (.other, raw(s))
    }

    /// "Bash(npm test:*)", "WebSearch", or "reading dir" for a rule over a folder ("…/dir/**").
    private static func rule(_ r: [String: Any]) -> (folder: Bool, text: String) {
        let tool = (r["toolName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Tool"
        guard let content = (r["ruleContent"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            return (false, AgentsToolText.displayName(tool))
        }
        if content.hasSuffix("/**") {
            let name = folderName(String(content.dropLast(3)))
            if !name.isEmpty {
                switch tool {
                case "Read", "Glob", "Grep": return (true, "reading \(name)")
                case "Edit", "Write", "MultiEdit", "NotebookEdit": return (true, "editing \(name)")
                default: return (true, "\(AgentsToolText.displayName(tool)) in \(name)")
                }
            }
        }
        return (false, "\(tool)(\(content))")
    }

    /// Where Claude Code saves it.
    private static func scope(_ destination: String?) -> String? {
        switch destination {
        case "session", "cliArg": "this session"
        case "localSettings", "projectSettings": "in this project"
        case "userSettings": "in every project"
        default: nil
        }
    }

    private static func folderName(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        guard !p.isEmpty else { return "" }
        let name = (p as NSString).lastPathComponent
        return name.isEmpty ? p : name
    }

    private static func raw(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .withoutEscapingSlashes]),
              var text = String(data: data, encoding: .utf8) else { return "Claude Code's suggested rule" }
        text = String(text.dropFirst().dropLast())           // the array around it
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
}

/// Pending requests in arrival order: the notch shows the oldest and counts the rest.
struct AgentsRequestQueue {
    private(set) var items: [AgentsPermissionRequest] = []

    var oldest: AgentsPermissionRequest? { items.first }
    var othersCount: Int { max(0, items.count - 1) }

    func item(_ id: Int) -> AgentsPermissionRequest? { items.first { $0.id == id } }
    mutating func add(_ request: AgentsPermissionRequest) { items.append(request) }
    mutating func remove(_ id: Int) { items.removeAll { $0.id == id } }

    /// The oldest request a PostToolUse(Failure) shows was settled in Claude Code's own
    /// prompt: same session, agent, tool and command or path. The tool ran, so nobody waits on it.
    func settled(by e: AgentsHookEvent) -> Int? {
        guard e.name == "PostToolUse" || e.name == "PostToolUseFailure",
              let session = e.sessionID, let tool = e.toolName else { return nil }
        let detail = AgentsToolText.detail(tool: tool, input: e.toolInput)
        return items.first {
            $0.sessionID == session && $0.agentID == e.agentID && $0.tool == tool && $0.detail == detail
        }?.id
    }

    /// Requests that can no longer be open in Claude Code: once a session's main thread ends
    /// its turn, takes a prompt or sits idle, its own requests were answered in Claude Code's
    /// dialog (which runs beside the hook and doesn't cancel it). A subagent's requests stay:
    /// they share the session, and Claude Code waits on their hook before showing a dialog.
    func stale(after e: AgentsHookEvent) -> [Int] {
        guard e.agentID == nil, let session = e.sessionID else { return [] }
        switch e.name {
        case "Stop", "UserPromptSubmit": break
        case "Notification" where e.notificationType == "idle_prompt": break
        default: return []
        }
        return items.filter { $0.sessionID == session && $0.agentID == nil }.map(\.id)
    }
}

/// How the notch answers a permission request.
enum AgentsAnswer: String {
    case allow, always, deny, open

    /// The hook's stdout for this answer; nil for Open, which answers nothing so Claude
    /// Code shows its own prompt.
    func reply(suggestions: [Any]) -> [String: Any]? {
        var decision: [String: Any]
        switch self {
        case .allow: decision = ["behavior": "allow"]
        case .always: decision = ["behavior": "allow", "updatedPermissions": suggestions]
        case .deny: decision = ["behavior": "deny", "message": "Denied from the notch"]
        case .open: return nil
        }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    }
}

/// Short and full descriptions of a tool call.
enum AgentsToolText {
    /// One short line for the sessions list: "Bash: npm test", "Edit: Foo.swift".
    static func summary(tool: String, input: [String: Any]) -> String {
        guard let arg = shortArgument(tool: tool, input: input), !arg.isEmpty else { return displayName(tool) }
        return "\(displayName(tool)): \(arg)"
    }

    /// Everything a permission decision depends on: the full command, path or URL.
    static func detail(tool: String, input: [String: Any]) -> String {
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch tool {
        case "Bash", "PowerShell":
            if let command = string("command") { return command }
        case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit":
            if let path = string("file_path") ?? string("notebook_path") { return path }
        case "WebFetch":
            if let url = string("url") { return url }
        case "WebSearch":
            if let query = string("query") { return query }
        case "Grep", "Glob":
            if let pattern = string("pattern") { return string("path").map { "\(pattern)  in \($0)" } ?? pattern }
        default:
            break
        }
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return displayName(tool) }
        return text.count > 2000 ? String(text.prefix(2000)) + "…" : text
    }

    /// What a permission request asks for, as a heading: "Bash wants to run".
    static func verb(tool: String) -> String {
        switch tool {
        case "Bash", "PowerShell": "\(tool) wants to run"
        case "Edit", "MultiEdit", "NotebookEdit": "\(tool) wants to change"
        case "Write": "Write wants to create"
        case "Read": "Read wants to open"
        case "WebFetch": "WebFetch wants to load"
        default: "\(displayName(tool)) needs permission"
        }
    }

    /// "mcp__github__create_issue" reads as "github: create_issue".
    static func displayName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? "\(parts[0]): \(parts.dropFirst().joined(separator: "__"))" : String(tool.dropFirst(5))
    }

    private static func shortArgument(tool: String, input: [String: Any]) -> String? {
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let raw: String?
        switch tool {
        case "Bash", "PowerShell":
            raw = string("command").map { command in
                let lines = command.split(whereSeparator: \.isNewline)
                let first = lines.first.map(String.init) ?? ""
                return lines.count > 1 ? first + " …" : first
            }
        case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit":
            raw = (string("file_path") ?? string("notebook_path")).map { URL(fileURLWithPath: $0).lastPathComponent }
        case "WebFetch":
            raw = string("url").map { URLComponents(string: $0)?.host ?? $0 }
        case "WebSearch":
            raw = string("query")
        case "Grep", "Glob":
            raw = string("pattern")
        case "Task", "Agent":
            raw = string("description") ?? string("subagent_type")
        case "Skill":
            raw = string("skill") ?? string("name")
        case "AskUserQuestion":
            raw = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
        case "ExitPlanMode":
            raw = "plan ready"
        default:
            raw = string("description") ?? string("command") ?? string("file_path") ?? string("url") ?? string("query")
        }
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 60 ? String(collapsed.prefix(59)) + "…" : collapsed
    }
}

/// Durations as the tab shows them.
enum AgentsFormat {
    /// "45 s", "12 min", "1 h 12 min", "3 d 4 h".
    static func duration(_ seconds: TimeInterval) -> String {
        // Int(_:) traps on infinity or values past Int.max (a bogus reset date): clamp first.
        let s = seconds.isFinite ? Int(min(max(seconds, 0), 1e10).rounded(.down)) : 0
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h) h" : "\(h) h \(m % 60) min" }
        return h % 24 == 0 ? "\(h / 24) d" : "\(h / 24) d \(h % 24) h"
    }

    /// "resets in 2 h 5 min", or "reset" once the time has passed.
    static func reset(_ date: Date?, now: Date) -> String {
        guard let date else { return "no reset time" }
        let left = date.timeIntervalSince(now)
        if left <= 0 { return "reset" }
        return "resets in " + duration(max(60, left))
    }
}
