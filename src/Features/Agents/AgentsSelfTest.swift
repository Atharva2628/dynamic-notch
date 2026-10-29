import SwiftUI

extension AgentsFeature {
    /// Pure-logic checks: hook parsing, the session state machine, decisions, usage
    /// parsing and alerts, the parent walk, Agent Away's flags. No UI, network or waiting.
    @MainActor
    static func selfTest(_ check: (Bool, String) -> Void) {
        costSelfTest(check)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        /// A message as the bridge hands it over: JSON text through JSONSerialization.
        func message(_ json: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        }
        func hook(_ event: String, _ payload: String, wait: Bool = false) -> AgentsHookEvent? {
            AgentsHookEvent(message: message(
                #"{"type":"hook","event":"\#(event)","pid":4242,"wait":\#(wait),"payload":{"session_id":"s1","cwd":"/Users/me/Code/dynamic-notch"\#(payload.isEmpty ? "" : ",")\#(payload)}}"#))
        }
        func json(_ object: Any?) -> String {
            guard let object, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        // Hook messages.
        let permission = hook("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"rm -rf node_modules\nnpm install","description":"Reinstall"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}]"#, wait: true)
        check(permission?.name == "PermissionRequest" && permission?.pid == 4242 && permission?.wait == true
              && permission?.sessionID == "s1" && permission?.permissionSuggestions.count == 1,
              "agents: a hook message parses (event, pid, wait, session, suggestions)")
        check(AgentsHookEvent(message: message(#"{"type":"hook","pid":1,"payload":{}}"#)) == nil,
              "agents: a message without an event is rejected")

        // Session state machine.
        var book = AgentsSessionBook()
        var pings: [AgentsPing?] = []
        func apply(_ e: AgentsHookEvent?, _ s: TimeInterval) { if let e { pings.append(book.apply(e, now: at(s))) } }
        apply(hook("SessionStart", #""source":"startup""#), 0)
        let started = book.sessions["s1"]
        check(started?.project == "dynamic-notch" && started?.state == .idle && started?.pid == 4242 && started?.started == t0,
              "agents: SessionStart adds an idle session named after its folder")
        apply(hook("UserPromptSubmit", #""prompt":"run the tests""#), 5)
        apply(hook("PreToolUse", #""tool_name":"Bash","tool_input":{"command":"npm test"}"#), 6)
        check(book.sessions["s1"]?.state == .working && book.sessions["s1"]?.tool == "Bash: npm test",
              "agents: a prompt and a tool make it working, with the tool shown")
        apply(hook("PostToolUse", #""tool_name":"Bash","tool_input":{"command":"npm test"}"#), 9)
        check(book.sessions["s1"]?.state == .working && book.sessions["s1"]?.tool == nil, "agents: after the tool it's still working")
        apply(permission, 10)
        check(book.sessions["s1"]?.state == .waiting && book.sessions["s1"]?.tool == "Bash: rm -rf node_modules …",
              "agents: a permission request makes it wait for you")
        pings.removeAll()
        apply(hook("Stop", #""stop_hook_active":false"#), 20)
        apply(hook("Notification", #""notification_type":"idle_prompt","message":"Claude is waiting""#), 80)
        check(pings == [.finished, nil] && book.sessions["s1"]?.state == .idle,
              "agents: Stop pings once; the idle reminder a minute later doesn't ping again")
        pings.removeAll()
        apply(hook("UserPromptSubmit", #""prompt":"go on""#), 100)
        apply(hook("Notification", #""notification_type":"idle_prompt""#), 160)
        apply(hook("Notification", #""notification_type":"agent_needs_input""#), 170)
        apply(hook("Notification", #""notification_type":"auth_success""#), 171)
        check(pings == [nil, .idle, .needsInput, nil] && book.sessions["s1"]?.state == .waiting,
              "agents: idle_prompt pings without a Stop; agent_needs_input pings and waits; others don't")
        check(book.sessions["s1"]?.started == t0 && book.sessions["s1"]?.lastEvent == at(171), "agents: start and last-event times")
        pings.removeAll()
        apply(hook("Notification", #""notification_type":"elicitation_dialog""#), 172)
        apply(hook("Notification", #""notification_type":"permission_prompt""#), 173)
        check(pings == [.needsInput, nil] && book.sessions["s1"]?.state == .waiting,
              "agents: an elicitation dialog pings; Claude Code's permission dialog doesn't (its request already sounded)")
        if let s = book.sessions["s1"] {
            let done = pingActivity(.finished, s, sound: "Sosumi")
            check(done.id == "agents.done.s1" && done.priority == .agent && done.duration == 8 && done.sound == "Sosumi"
                  && done.opensTab == .agents && done.actions.map(\.id) == ["open"] && done.subtitle == "dynamic-notch"
                  && pingActivity(.idle, s, sound: "").sound == nil,
                  "agents: the done ping lasts 8 s, plays the sound (none for \"\"), opens the Agents tab")
            let waiting = hook("PermissionRequest", #""tool_name":"Edit","tool_input":{"file_path":"/a/Foo.swift"}"#)
                .map { waitingActivity(s, event: $0) }
            check(waiting?.id == "agents.wait.s1" && waiting?.title == "Waiting for you in dynamic-notch"
                  && waiting?.subtitle == "Edit: Foo.swift" && waiting?.actions.map(\.id) == ["open"] && waiting?.expands == false,
                  "agents: without approvals a request only says the session waits, with Open")
            let question = hook("PermissionRequest", #""tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?","options":[{"label":"SQLite"}]}]}"#, wait: true)
            let plan = hook("PermissionRequest", #""tool_name":"ExitPlanMode","tool_input":{"plan":"1. Do it"}"#, wait: true)
            check(question.map { answersInNotch($0, approvals: true) } == false && plan.map { answersInNotch($0, approvals: true) } == false,
                  "agents: questions and plans are never answered from the notch (Claude Code ignores a bare Allow)")
            let asked = question.map { waitingActivity(s, event: $0) }
            check(asked?.title == "Claude has a question in dynamic-notch" && asked?.subtitle == "AskUserQuestion: Which database?"
                  && asked?.actions.map(\.id) == ["open"]
                  && plan.map { waitingActivity(s, event: $0).title } == "Claude has a plan for you in dynamic-notch",
                  "agents: a question or plan only says Claude waits, with Open")
        } else {
            check(false, "agents: session s1 before SessionEnd")
        }
        apply(hook("SessionEnd", #""reason":"prompt_input_exit""#), 200)
        check(book.sessions.isEmpty, "agents: SessionEnd removes the session")
        check(AgentsSession.project(for: "") == "Claude Code" && AgentsSession.project(for: "/") == "/"
              && AgentsSession.project(for: "/Users/me/x/") == "x", "agents: project names, even without a folder")

        // Dead sessions.
        var sweepBook = AgentsSessionBook()
        for (sid, pid) in [("alive", 100), ("dead", 200)] {
            sweepBook.apply(AgentsHookEvent(name: "SessionStart", pid: pid_t(pid), payload: ["session_id": sid, "cwd": "/x/\(sid)"]), now: t0)
        }
        sweepBook.apply(AgentsHookEvent(name: "SessionStart", payload: ["session_id": "nopid", "cwd": "/x"]), now: t0)
        let gone = sweepBook.sweep(now: at(4 * 3600), isAlive: { $0 == 100 })
        check(Set(gone) == ["dead", "nopid"] && sweepBook.sessions.keys.sorted() == ["alive"],
              "agents: the sweep drops sessions whose process is gone, and silent ones without a pid")

        // Tool text.
        check(AgentsToolText.summary(tool: "Edit", input: ["file_path": "/a/b/Foo.swift"]) == "Edit: Foo.swift"
              && AgentsToolText.summary(tool: "WebFetch", input: ["url": "https://docs.swift.org/x"]) == "WebFetch: docs.swift.org"
              && AgentsToolText.summary(tool: "mcp__github__create_issue", input: [:]) == "github: create_issue",
              "agents: tool summaries (file name, host, MCP tool)")
        let long = AgentsToolText.summary(tool: "Bash", input: ["command": String(repeating: "x", count: 100)])
        check(long.count == 6 + 60 && long.hasSuffix("…"), "agents: long commands are shortened in the list")
        check(AgentsToolText.detail(tool: "Bash", input: ["command": "a\nb"]) == "a\nb"
              && AgentsToolText.detail(tool: "Write", input: ["file_path": "/tmp/x/y.txt", "content": "z"]) == "/tmp/x/y.txt"
              && AgentsToolText.detail(tool: "Custom", input: ["b": 1, "a": "x"]) == #"{"a":"x","b":1}"#,
              "agents: permission details show the full command, path, or input")

        // Requests and decisions.
        guard let permission else { check(false, "agents: sample permission request"); return }
        let request = AgentsPermissionRequest(id: 1, event: permission, project: "dynamic-notch", received: t0)
        check(request.detail == "rm -rf node_modules\nnpm install" && request.note == "Reinstall" && request.canAlwaysAllow,
              "agents: a request keeps the full command, its description and whether a rule is suggested")
        let suggestions = permission.permissionSuggestions
        check(json(AgentsAnswer.allow.reply(suggestions: suggestions))
              == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#,
              "agents: Allow answers behavior allow")
        check(json((AgentsAnswer.always.reply(suggestions: suggestions)?["hookSpecificOutput"] as? [String: Any])?["decision"])
              == json(["behavior": "allow", "updatedPermissions": suggestions] as [String: Any]),
              "agents: Always allow passes Claude's suggested rules back as updatedPermissions")
        check(json(AgentsAnswer.deny.reply(suggestions: suggestions))
              == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied from the notch"},"hookEventName":"PermissionRequest"}}"#
              && AgentsAnswer.open.reply(suggestions: suggestions) == nil,
              "agents: Deny sends its message; Open answers nothing")
        let activity = requestActivity(request, others: 2)
        check(activity.actions.map(\.id) == ["allow", "always", "deny", "open"] && activity.actions[0].style == .primary
              && activity.actions[2].style == .destructive && activity.priority == .permission && activity.expands
              && activity.urgent && activity.id.hasPrefix("agents.") && activity.subtitle?.hasSuffix("+2 more waiting") == true,
              "agents: the request activity: Allow first, Deny destructive, urgent, expanding, counting the rest")
        let detailPeek = NotchMetrics(notch: CGSize(width: 179, height: 32), panel: CGSize(width: 806, height: 250),
                                      peekExtra: NotchMetrics.peekExtraDetail)
        check(activity.title == "Bash wants to run" && activity.detail == request.detail && detailPeek.body(.peek).width == 480,
              "agents: the request peek shows the whole command in the 480-pt detail peek")
        check(activity.actions[1].title == "Always allow" && activity.sound == nil
              && activity.subtitle == "dynamic-notch · Always allow Bash(rm -rf node_modules) in this project · Reinstall · +2 more waiting",
              "agents: the peek says what Always allow allows; re-showing a queued request is silent (it sounded on arrival)")
        check(answersInNotch(permission, approvals: true) && !answersInNotch(permission, approvals: false)
              && hook("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"ls"}"#, wait: false)
                  .map { answersInNotch($0, approvals: true) } == false,
              "agents: the notch answers only a waiting request, with approvals on")
        func bash(_ command: String) -> AgentsPermissionRequest {
            AgentsPermissionRequest(id: 3, event: AgentsHookEvent(name: "PermissionRequest", wait: true, payload: [
                "session_id": "s1", "tool_name": "Bash", "tool_input": ["command": command],
                "permission_suggestions": permission.permissionSuggestions,
            ]), project: "p", received: t0)
        }
        let fitting = ["npm test", "a\nb\nc", String(repeating: "x", count: 120)].map { requestActivity(bash($0), others: 0) }
        check(fitting.allSatisfy { $0.actions.map(\.id) == ["allow", "always", "deny", "open"] },
              "agents: a command that fits the peek's 3 lines gets Allow there")
        let tooLong = ["a\nb\nc\nd", String(repeating: "x", count: 250)].map { requestActivity(bash($0), others: 0) }
        check(tooLong.allSatisfy { $0.actions.map(\.id) == ["review", "deny", "open"] && $0.actions[0].style == .primary
                                   && $0.subtitle == "p · Too long to show here" },
              "agents: a command cut off in the peek gets no Allow there, only Review (the tab shows it all), Deny and Open")
        let plain = hook("PermissionRequest", #""tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}"#, wait: true)
        check(plain.map { requestActivity(AgentsPermissionRequest(id: 2, event: $0, project: "p", received: t0), others: 0) }?
              .actions.map(\.id) == ["allow", "deny", "open"], "agents: no Always allow without a suggested rule")
        var queue = AgentsRequestQueue()
        queue.add(request)
        if let plain { queue.add(AgentsPermissionRequest(id: 2, event: plain, project: "p", received: at(1))) }
        check(queue.oldest?.id == 1 && queue.othersCount == 1, "agents: the oldest request shows first, the rest are counted")
        let ranElsewhere = hook("PostToolUse", #""tool_name":"Bash","tool_input":{"command":"rm -rf node_modules\nnpm install"}"#)
        let otherTool = hook("PostToolUse", #""tool_name":"Bash","tool_input":{"command":"ls"}"#)
        check(ranElsewhere.flatMap { queue.settled(by: $0) } == 1 && otherTool.flatMap { queue.settled(by: $0) } == nil
              && permission.name == "PermissionRequest" && queue.settled(by: permission) == nil,
              "agents: the same tool and command running means the request was answered in Claude Code")
        queue.remove(1)
        check(queue.oldest?.id == 2 && queue.othersCount == 0, "agents: answering it shows the next one")
        var agentQueue = AgentsRequestQueue()
        agentQueue.add(request)
        let sub = hook("PermissionRequest", #""agent_id":"a7","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules\nnpm install"}"#, wait: true)
        if let sub { agentQueue.add(AgentsPermissionRequest(id: 3, event: sub, project: "p", received: at(2))) }
        let subRan = hook("PostToolUse", #""agent_id":"a7","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules\nnpm install"}"#)
        let failed = hook("PostToolUseFailure", #""tool_name":"Bash","tool_input":{"command":"rm -rf node_modules\nnpm install"}"#)
        check(sub?.agentID == "a7" && request.agentID == nil && subRan.flatMap { agentQueue.settled(by: $0) } == 3
              && ranElsewhere.flatMap { agentQueue.settled(by: $0) } == 1 && failed.flatMap { agentQueue.settled(by: $0) } == 1,
              "agents: a tool that ran (or failed) settles the request of the same agent only")
        func stale(_ event: String, _ payload: String = "") -> [Int]? { hook(event, payload).map { agentQueue.stale(after: $0) } }
        check(stale("Stop") == [1] && stale("UserPromptSubmit", #""prompt":"next""#) == [1]
              && stale("Notification", #""notification_type":"idle_prompt""#) == [1]
              && stale("Stop", #""agent_id":"a7""#) == [] && stale("PreToolUse", #""tool_name":"Bash""#) == []
              && stale("Notification", #""notification_type":"permission_prompt""#) == [],
              "agents: the main thread's Stop, prompt or idle clears its own requests (answered in Claude Code), never a subagent's")

        // What Always allow allows.
        func scope(_ json: String) -> AgentsAllowScope? {
            AgentsAllowScope(suggestions: (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Any] ?? [])
        }
        let edits = scope(#"[{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#)
        let folder = scope(#"[{"type":"addRules","rules":[{"toolName":"Read","ruleContent":"//Users/me/dir/**"}],"behavior":"allow","destination":"session"}]"#)
        check(edits?.button == "Allow all edits" && edits?.text == "Allow all edits this session"
              && folder?.button == "Allow folder" && folder?.text == "Allow reading dir this session",
              "agents: Always allow names an edit mode or a folder for what it is")
        let both = scope(#"[{"type":"addDirectories","directories":["/Users/me/other/"],"destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#)
        let whole = scope(#"[{"type":"addRules","rules":[{"toolName":"WebSearch"}],"behavior":"allow","destination":"userSettings"}]"#)
        let odd = scope(#"[{"type":"replaceRules","rules":[]}]"#)
        check(both?.button == "Allow all edits" && both?.text == "Allow access to other this session; Allow all edits this session"
              && whole?.button == "Always allow" && whole?.text == "Always allow WebSearch in every project"
              && odd?.button == "Always allow" && odd?.text == #"{"rules":[],"type":"replaceRules"}"# && scope("[]") == nil,
              "agents: several suggestions are all named; an unknown one shows as JSON; none means no Always allow")

        // Usage.
        let usageJSON = #"""
        {"five_hour":{"utilization":42.0,"resets_at":"2027-01-15T18:00:00.127573+00:00"},
         "seven_day":{"utilization":"81","resets_at":"2027-01-19T11:00:00Z"},
         "seven_day_opus":null,"seven_day_oauth_apps":null,"seven_day_sonnet":{"utilization":12,"resets_at":null},
         "limits":[{"kind":"weekly_scoped","percent":73,"resets_at":"2027-01-19T11:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"}}},
                   {"kind":"other","percent":5}]}
        """#
        let snapshot = AgentsUsageParser.snapshot(from: Data(usageJSON.utf8), now: t0)
        let reset5h = AgentsUsageParser.date("2027-01-15T18:00:00Z")
        check(snapshot?.fiveHour?.percent == 42 && snapshot?.fiveHour?.resetsAt == reset5h && reset5h != nil
              && snapshot?.weekly?.percent == 81, "agents: usage reply parses (percent as number or string, microsecond dates)")
        check(snapshot?.scoped.map(\.title) == ["Sonnet weekly", "Fable weekly"] && snapshot?.scoped.last?.percent == 73,
              "agents: model weekly limits come from per-model keys and the limits list; nulls are skipped")
        check(AgentsUsageParser.snapshot(from: Data("{}".utf8), now: t0) == nil
              && AgentsUsageParser.snapshot(from: Data("nope".utf8), now: t0) == nil, "agents: an empty or broken reply gives nothing")
        let ms = (t0.timeIntervalSince1970 + 3600) * 1000
        check(AgentsUsageParser.token(from: Data(#"{"claudeAiOauth":{"accessToken":"test-token","expiresAt":\#(ms)}}"#.utf8), now: t0) == .ok("test-token")
              && AgentsUsageParser.token(from: Data(#"{"claudeAiOauth":{"accessToken":"test-token","expiresAt":\#(ms)}}"#.utf8), now: at(7200)) == .expired(canRefresh: false)
              && AgentsUsageParser.token(from: Data(#"{"claudeAiOauth":{"accessToken":"test-token","refreshToken":"test-refresh","expiresAt":\#(ms)}}"#.utf8), now: at(7200)) == .expired(canRefresh: true)
              && AgentsUsageParser.token(from: Data(), now: t0) == .missing,
              "agents: the Keychain credentials give a token, expired (renewable by Claude Code or not), or missing")
        check(AgentsUsageClient.keychainProblem(status: 0) == nil && AgentsUsageClient.keychainProblem(status: 44) == nil
              && AgentsUsageClient.keychainProblem(status: 51) == .keychainDenied
              && AgentsUsageClient.keychainProblem(status: -1) == .keychainDenied,
              "agents: a refused Keychain read pauses polling; a missing item doesn't")
        check(AgentsUsageParser.date(NSNumber(value: 1.8e12)) == Date(timeIntervalSince1970: 1.8e9)
              && AgentsUsageParser.date(NSNumber(value: 1e300)) == nil && AgentsUsageParser.date(NSNumber(value: -5)) == nil
              && AgentsFormat.duration(.infinity) == "0 s" && AgentsFormat.duration(.nan) == "0 s"
              && AgentsFormat.reset(Date.distantFuture, now: t0).hasPrefix("resets in"),
              "agents: epoch dates in ms are read; junk dates and durations never trap")

        var alerts = AgentsUsageAlerts()
        func usage(_ p: Double, resets: TimeInterval = 18000) -> AgentsUsageSnapshot {
            AgentsUsageSnapshot(fiveHour: AgentsUsageWindow(id: "five_hour", title: "5-hour", percent: p, resetsAt: at(resets)), fetchedAt: t0)
        }
        let fired = [70, 85, 90, 96, 97].map { alerts.check(usage($0), thresholds: [95, 80]).map(\.threshold) }
        check(fired == [[], [80], [], [95], []], "agents: alerts fire once per threshold when crossed upward")
        let afterReset = [30, 82].map { alerts.check(usage($0, resets: 36000), thresholds: [95, 80]).map(\.threshold) }
        check(afterReset == [[], [80]], "agents: a new window (new reset time) alerts again")
        let state = AgentsUsageState(enabled: true, snapshot: usage(10), problem: nil)
        check(!state.isStale(now: at(60)) && state.isStale(now: at(1000))
              && AgentsUsageState(enabled: true, snapshot: usage(10), problem: .signedOut).status(now: at(120))
              == "Sign in to Claude Code again · updated 2 min ago", "agents: usage goes stale after 15 min or an error")
        check(AgentsUsageState(enabled: true, snapshot: usage(10), problem: .waitingForClaudeCode).status(now: at(120))
              == "Updates when Claude Code next runs · updated 2 min ago"
              && !AgentsUsageProblem.waitingForClaudeCode.isError && AgentsUsageProblem.signedOut.isError,
              "agents: an idle Claude Code's expired token waits for its next run, not shown as an error")

        // Process tree.
        let tree: [pid_t: AgentsProcess.Info] = [
            500: .init(parent: 400, name: "claude"), 400: .init(parent: 300, name: "zsh"),
            300: .init(parent: 200, name: "login"), 200: .init(parent: 1, name: "Terminal"),
            600: .init(parent: 500, name: "sh"), 800: .init(parent: 700, name: "claude"),
            700: .init(parent: 1, name: "DynamicNotch"), 900: .init(parent: 901, name: "claude"),
            901: .init(parent: 900, name: "tmux"),
        ]
        let info: (pid_t) -> AgentsProcess.Info? = { tree[$0] }
        check(AgentsProcess.hostApp(from: 500, own: 700, info: info, isApp: { $0 == 200 }) == 200,
              "agents: the parent walk finds the terminal app above the shell")
        check(AgentsProcess.hostApp(from: 800, own: 700, info: info, isApp: { $0 == 200 }) == 700,
              "agents: a session in the notch's own terminal finds this app")
        check(AgentsProcess.hostApp(from: 900, own: 700, info: info, isApp: { $0 == 200 }) == nil,
              "agents: no app (a loop, or tmux under launchd) gives nothing")
        check(AgentsProcess.claudeProcess(from: 600, info: info) == 500 && AgentsProcess.claudeProcess(from: 500, info: info) == 500,
              "agents: a hook started through a shell reports the Claude Code process")
        check(AgentsProcess.claudeProcess(from: 4242, info: info) == nil,
              "agents: a hook pid that is already gone gives no pid (the session keeps its known one)")
        var keep = AgentsSessionBook()
        keep.apply(AgentsHookEvent(name: "SessionStart", pid: 500, payload: ["session_id": "k", "cwd": "/k"]), now: t0)
        keep.apply(AgentsHookEvent(name: "PreToolUse", pid: nil, payload: ["session_id": "k", "cwd": "/k"]), now: at(1))
        check(keep.sessions["k"]?.pid == 500, "agents: an event without a usable pid keeps the session's pid")
        check(AgentsProcess.info(getpid())?.name.isEmpty == false && AgentsProcess.isAlive(getpid()),
              "agents: sysctl reads this process")

        // Agent Away's flag files.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agents-selftest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "4321\n".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
            try "".write(to: dir.appendingPathComponent("away"), atomically: true, encoding: .utf8)
            try "".write(to: dir.appendingPathComponent("lid"), atomically: true, encoding: .utf8)
            try "1800000000\n[Agent Away] Heat guard (lid closed, laptop likely in a bag, Mac is hot): slowed to efficiency cores: ffmpeg. Do not start more heavy work."
                .write(to: dir.appendingPathComponent("hot"), atomically: true, encoding: .utf8)
            let on = AgentsAway.read(runDir: dir, isRunning: { $0 == 4321 })
            check(on == AgentsAwayStatus(running: true, keepAwake: true, lidClosed: true, askFirst: false, heat: "slowed ffmpeg")
                  && on.line == "Keep awake on · lid closed · heat guard: slowed ffmpeg",
                  "agents: Agent Away's flags read as keep awake, lid closed and the heat guard's action")
            check(AgentsAway.read(runDir: dir, isRunning: { _ in false }) == AgentsAwayStatus(running: false),
                  "agents: flags left by an Agent Away that isn't running are ignored")
        } catch {
            check(false, "agents: temp dir for Agent Away flags (\(error.localizedDescription))")
        }
        try? FileManager.default.removeItem(at: dir)

        check(AgentsFormat.duration(45) == "45 s" && AgentsFormat.duration(125) == "2 min"
              && AgentsFormat.duration(3900) == "1 h 5 min" && AgentsFormat.duration(2 * 86400 + 4 * 3600 + 59) == "2 d 4 h"
              && AgentsFormat.reset(at(7500), now: t0) == "resets in 2 h 5 min" && AgentsFormat.reset(t0, now: at(1)) == "reset",
              "agents: durations and reset countdowns read naturally")
    }

    /// The tab, Home card and Usage dropdown, from sample data.
    @MainActor
    static func snapshotViews() -> [(name: String, view: AnyView)] {
        let busy = sampleStore(withRequest: true)
        let calm = sampleStore(withRequest: false)
        let actions = AgentsActions()
        func tab(_ store: AgentsStore) -> AnyView {
            AnyView(AgentsTabView(store: store, actions: actions, scrolls: false)
                .frame(width: 758, height: 186)
                .clipped()
                .background(Color.black)
                .environment(\.colorScheme, .dark))
        }
        return [
            ("agents-tab-request", tab(busy)),
            ("agents-tab-sessions", tab(calm)),
            ("agents-tab-empty", tab(AgentsStore())),
            ("agents-home-card", AnyView(AgentsHomeCard(store: busy, actions: actions)
                .frame(width: 145, height: 186)
                .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: NotchStyle.cornerRadius, style: .continuous))
                .background(Color.black)
                .environment(\.colorScheme, .dark))),
            ("agents-usage-dropdown", AnyView(AgentsUsagePanel(store: calm, actions: actions).frame(width: 720, height: 380))),
        ]
    }

    @MainActor
    private static func sampleStore(withRequest: Bool) -> AgentsStore {
        let store = AgentsStore()
        let now = Date()
        func event(_ name: String, _ session: String, _ folder: String, _ extra: [String: Any] = [:]) -> AgentsHookEvent {
            AgentsHookEvent(name: name, payload: ["session_id": session, "cwd": "/Users/me/Code/\(folder)"].merging(extra) { $1 })
        }
        var book = AgentsSessionBook()
        book.apply(event("SessionStart", "a", "dynamic-notch"), now: now - 4300)
        book.apply(event("UserPromptSubmit", "a", "dynamic-notch"), now: now - 600)
        book.apply(event("PreToolUse", "a", "dynamic-notch", ["tool_name": "Bash", "tool_input": ["command": "swift build -c release"]]), now: now - 20)
        book.apply(event("SessionStart", "c", "skim"), now: now - 9000)
        book.apply(event("Stop", "c", "skim"), now: now - 300)
        let ask = event("PermissionRequest", "b", "agent-away", [
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf .build && swift test --parallel"],
            "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "swift test:*"]],
                                        "behavior": "allow", "destination": "localSettings"]],
        ])
        if withRequest {
            book.apply(event("SessionStart", "b", "agent-away"), now: now - 1500)
            book.apply(ask, now: now - 12)
            store.queue.add(AgentsPermissionRequest(id: 1, event: ask, project: "agent-away", received: now - 12))
        } else {
            book.apply(event("SessionStart", "d", "tools-and-optimizations"), now: now - 800)
            book.apply(event("PreToolUse", "d", "tools-and-optimizations", ["tool_name": "Edit", "tool_input": ["file_path": "/x/AgentsFeature.swift"]]), now: now - 4)
        }
        store.book = book
        store.usage = AgentsUsageState(enabled: true, snapshot: AgentsUsageSnapshot(
            fiveHour: AgentsUsageWindow(id: "five_hour", title: "5-hour", percent: 42, resetsAt: now + 7500),
            weekly: AgentsUsageWindow(id: "seven_day", title: "Weekly", percent: 81, resetsAt: now + 3 * 86400 + 4 * 3600),
            scoped: [AgentsUsageWindow(id: "scoped.fable", title: "Fable weekly", percent: 12, resetsAt: now + 3 * 86400 + 4 * 3600)],
            fetchedAt: now - 120), problem: nil)
        store.away = AgentsAwayStatus(running: true, keepAwake: true, lidClosed: false, askFirst: false, heat: nil)
        store.cost = AgentsCostReport(
            today: 18.42, week: 96.30, month: 412.75,
            models: [.init(id: "opus-5-5", cost: 380.10, tokens: 612_000_000),
                     .init(id: "sonnet-5-5", cost: 28.40, tokens: 41_000_000),
                     .init(id: "haiku-5-5", cost: 4.25, tokens: 9_800_000)],
            days: [8, 22, 14, 31, 5, 0, 12, 19, 27, 9, 16, 24, 11, 18.42].enumerated().map { .init(id: "day\($0.offset)", cost: $0.element) },
            sessions: ["a": 6.12, "b": 2.40, "c": 0.85])
        return store
    }
}
