import AppKit
import Combine
import SwiftUI
import os

/// What the Agents tab, the Home card and the Usage dropdown draw from.
@MainActor
final class AgentsStore: ObservableObject {
    @Published var book = AgentsSessionBook()
    @Published var queue = AgentsRequestQueue()
    @Published var usage = AgentsUsageState()
    @Published var away: AgentsAwayStatus?       // nil hides the Agent Away line
    @Published var approvals = true
    @Published var cost: AgentsCostReport?        // nil while the estimate is off
}

/// Claude Code in the notch: sessions, permission requests answered from the notch, done
/// pings, jump to session, usage limits and Agent Away. Fed by hooks/notch-hook.sh over
/// the bridge ("hook" messages).
@MainActor
final class AgentsFeature: Feature {
    nonisolated static let log = Logger(subsystem: "local.dynamicnotch", category: "agents")

    let store: AgentsStore
    private let context: AppContext
    private let usage: AgentsUsageMonitor
    private let cost: AgentsCostMonitor
    private var pending: [Int: Pending] = [:]
    private var nextRequestID = 1
    private var shownRequest: Int?                // the request the notch shows (the oldest)
    private var hosts: [pid_t: pid_t] = [:]       // Claude Code pid → the app that hosts it
    private var lastSound: [String: Date] = [:]   // session → when its sound last played
    private var sweepTimer: DispatchSourceTimer?
    private var awayTimer: DispatchSourceTimer?
    private var bag = Set<AnyCancellable>()

    /// A permission request whose hook is still waiting on the connection.
    private struct Pending {
        let connection: BridgeConnection
        let suggestions: [Any]
        let expiry: DispatchWorkItem
    }

    init(context: AppContext) {
        self.context = context
        let store = AgentsStore()
        self.store = store
        usage = AgentsUsageMonitor(store: store, fileURL: context.dataURL("agents-usage.json"))
        cost = AgentsCostMonitor(store: store, indexURL: context.dataURL("agents-cost.json"))
    }

    func start() {
        let store = self.store
        let actions = makeActions()
        context.registerTab(.agents) { AgentsTabView(store: store, actions: actions) }
        context.registerHomeCard { AgentsHomeCard(store: store, actions: actions) }
        context.registerDropdownTab("Usage", symbol: "gauge.with.dots.needle.50percent") {
            AgentsUsagePanel(store: store, actions: actions)
        }
        context.bridge.on("hook") { [weak self] message, connection in
            guard let self else { connection.close(); return }
            self.handle(message, connection)
        }
        context.model.onTabShown[.agents] = { [weak self] in self?.refreshAway() }

        usage.thresholds = { [weak self] in self?.context.config.usageAlerts ?? [] }
        usage.onAlerts = { [weak self] in self?.postUsageAlerts($0) }
        cost.isVisible = { [weak self] in
            guard let context = self?.context else { return false }
            let m = context.model
            return (m.isOpen && (m.currentTab == .agents || m.currentTab == .home))
                || context.dropdownTabVisible?("Usage") == true
        }
        context.onDropdownTabShown["Usage"] = { [weak self] in self?.cost.scan() }
        apply(context.config)
        // @Published sends the new value before it lands, so use the values passed in. Only
        // these settings matter here; others (a terminal resize) change often.
        context.model.$config
            .removeDuplicates { a, b in
                a.agentApprovals == b.agentApprovals && a.usageSource == b.usageSource
                    && a.agentAwayStatus == b.agentAwayStatus && a.apiCostEstimate == b.apiCostEstimate
            }
            .dropFirst()
            .sink { [weak self] config in MainActor.assumeIsolated { self?.apply(config) } }
            .store(in: &bag)
        context.model.$isOpen.combineLatest(context.model.$tab)
            .sink { [weak self] open, tab in
                MainActor.assumeIsolated {
                    self?.tabVisible(open && tab == .agents)
                    if open && (tab == .agents || tab == .home) { self?.cost.scan() }
                }
            }
            .store(in: &bag)
    }

    func stop() {
        bag.removeAll()
        context.model.onTabShown[.agents] = nil
        context.onDropdownTabShown["Usage"] = nil
        usage.stop()
        cost.stop()
        sweepTimer?.cancel()
        sweepTimer = nil
        awayTimer?.cancel()
        awayTimer = nil
        // No answer: Claude Code shows its own prompt.
        for p in pending.values {
            p.expiry.cancel()
            p.connection.close()
        }
        pending.removeAll()
        context.activities.removeAll(prefix: "agents.")
    }

    private func apply(_ config: Config) {
        store.approvals = config.agentApprovals
        if config.usageSource == "keychain" { usage.start() } else { usage.stop() }
        if config.apiCostEstimate { cost.start() } else { cost.stop() }
        refreshAway(enabled: config.agentAwayStatus)
    }

    private func makeActions() -> AgentsActions {
        AgentsActions(
            open: { [weak self] id in self?.jump(to: id) },
            answer: { [weak self] id, answer in self?.answer(id, answer) },
            refreshUsage: { [weak self] in self?.usage.refreshNow() },
            signIn: { [weak self] in self?.signIn() },
            setKeepAwake: { [weak self] on in self?.setKeepAwake(on) },
            showTab: { [weak self] in self?.context.model.select(.agents) })
    }

    // MARK: Hook events

    private func handle(_ message: [String: Any], _ connection: BridgeConnection) {
        guard var event = AgentsHookEvent(message: message), let sessionID = event.sessionID else {
            connection.close()
            return
        }
        if let pid = event.pid { event.pid = AgentsProcess.claudeProcess(from: pid, info: AgentsProcess.info) }
        let asks = Self.answersInNotch(event, approvals: context.config.agentApprovals)
        if !asks { connection.close() }

        let ping = store.book.apply(event, now: Date())
        // Any later sign of life from the session ends its "waiting for you" notice.
        if event.name != "PermissionRequest", event.notificationType != "permission_prompt" {
            removeActivity(Self.waitID(sessionID))
        }
        // The main thread moved on, so its requests were answered in Claude Code's dialog.
        for id in store.queue.stale(after: event) { drop(id) }
        switch event.name {
        case "PermissionRequest":
            if asks { enqueue(event, connection) } else { postWaiting(sessionID, event) }
        case "SessionEnd":
            ended(sessionID)
        case "PostToolUse", "PostToolUseFailure":
            // Answered in Claude Code's prompt while the hook was still waiting.
            if let id = store.queue.settled(by: event) { drop(id) }
        case "Stop":
            usage.turnEnded()
            cost.turnEnded()
        default:
            break
        }
        if let ping, let session = store.book.sessions[sessionID] { announce(ping, session) }
        updateSweep()
    }

    private func ended(_ sessionID: String) {
        removeActivity(Self.waitID(sessionID))
        for request in store.queue.items where request.sessionID == sessionID { drop(request.id) }
        lastSound[sessionID] = nil
        pruneHosts()
    }

    /// Tools Claude Code asks the person about itself (a question, a plan to approve). It
    /// ignores an Allow from a hook that doesn't carry their answers, so the notch only says
    /// that Claude waits.
    static let personOnlyTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Whether the notch answers this event: a permission request whose hook waits for it.
    static func answersInNotch(_ event: AgentsHookEvent, approvals: Bool) -> Bool {
        event.name == "PermissionRequest" && event.wait && approvals
            && !personOnlyTools.contains(event.toolName ?? "")
    }

    /// Removing always republishes the activities (and redraws the notch), so only remove
    /// what is there: tool events can come several times a second.
    private func removeActivity(_ id: String) {
        if context.activities.activity(id: id) != nil { context.activities.remove(id: id) }
    }

    // MARK: Permission requests

    private func enqueue(_ event: AgentsHookEvent, _ connection: BridgeConnection) {
        let id = nextRequestID
        nextRequestID += 1
        let project = event.sessionID.flatMap { store.book.sessions[$0]?.project }
            ?? AgentsSession.project(for: event.cwd ?? "")
        // The hook gives up after 110 s. Drop the request then, even if the close went unseen.
        let expiry = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.drop(id) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 115, execute: expiry)
        pending[id] = Pending(connection: connection, suggestions: event.permissionSuggestions, expiry: expiry)
        // Claude Code answered in its own prompt, or the hook timed out.
        connection.onClose = { [weak self] in self?.drop(id) }
        let request = AgentsPermissionRequest(id: id, event: event, project: project, received: Date())
        store.queue.add(request)
        // Once per request, even one queued behind another; showing it later is silent.
        alertSound(for: request.sessionID)
        showOldestRequest()
    }

    private func answer(_ id: Int, _ answer: AgentsAnswer) {
        guard let p = pending.removeValue(forKey: id), let request = store.queue.item(id) else { return }
        p.expiry.cancel()
        if let reply = answer.reply(suggestions: p.suggestions) {
            p.connection.reply(reply)
            store.book.setState(request.sessionID, .working)
        } else {
            p.connection.close()
            jump(to: request.sessionID)
        }
        store.queue.remove(id)
        showOldestRequest()
        Self.log.info("permission request for \(request.tool, privacy: .public): \(answer.rawValue, privacy: .public)")
    }

    /// Forgets a request without answering it (Claude Code shows its own prompt).
    private func drop(_ id: Int) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.expiry.cancel()
        p.connection.close()
        store.queue.remove(id)
        showOldestRequest()
    }

    /// The notch shows the oldest request, with how many more wait behind it.
    private func showOldestRequest() {
        guard let first = store.queue.oldest else {
            if let shown = shownRequest { context.activities.remove(id: Self.requestID(shown)) }
            shownRequest = nil
            return
        }
        let others = store.queue.othersCount
        if shownRequest == first.id {
            context.activities.update(id: Self.requestID(first.id)) {
                $0.subtitle = Self.requestSubtitle(first, others: others)
                $0.accessory = Self.requestAccessory(others: others)
            }
            return
        }
        if let shown = shownRequest { context.activities.remove(id: Self.requestID(shown)) }
        shownRequest = first.id
        context.activities.post(Self.requestActivity(first, others: others)) { [weak self] action in
            if action == Self.reviewAction { self?.context.model.open(tab: .agents); return }
            guard let answer = AgentsAnswer(rawValue: action) else { return }
            self?.answer(first.id, answer)
        }
    }

    static func requestID(_ id: Int) -> String { "agents.permission.\(id)" }
    static func waitID(_ session: String) -> String { "agents.wait.\(session)" }

    /// The peek's button that opens the Agents tab, whose card shows a long command whole.
    static let reviewAction = "review"

    /// The peek shows the full command in its 3-line box. Allow and Always allow appear only
    /// when all of it fits there; otherwise Review opens the tab's card, which shows it all.
    static func requestActivity(_ r: AgentsPermissionRequest, others: Int) -> Activity {
        let fits = fitsPeek(r.detail)
        var actions: [ActivityAction] = []
        if fits {
            // A request can pop up under a pointer already on its way to click something.
            actions.append(ActivityAction(id: AgentsAnswer.allow.rawValue, title: "Allow", style: .primary, armDelay: 0.6))
            if let scope = r.alwaysScope {
                actions.append(ActivityAction(id: AgentsAnswer.always.rawValue, title: scope.button, armDelay: 0.6))
            }
        } else {
            actions.append(ActivityAction(id: reviewAction, title: "Review", style: .primary))
        }
        actions.append(ActivityAction(id: AgentsAnswer.deny.rawValue, title: "Deny", style: .destructive))
        actions.append(ActivityAction(id: AgentsAnswer.open.rawValue, title: "Open"))
        return Activity(id: requestID(r.id), priority: .permission, symbol: "hand.raised.fill", tint: .orange,
                        accessory: requestAccessory(others: others), title: AgentsToolText.verb(tool: r.tool),
                        subtitle: requestSubtitle(r, others: others), detail: r.detail, urgent: true,
                        actions: actions, expands: true, opensTab: .agents)
    }

    private static func requestSubtitle(_ r: AgentsPermissionRequest, others: Int) -> String {
        var parts = [r.project]
        if !fitsPeek(r.detail) { parts.append("Too long to show here") }
        else if let scope = r.alwaysScope { parts.append(scope.text) }
        if let note = r.note { parts.append(note) }
        if others > 0 { parts.append("+\(others) more waiting") }
        return parts.joined(separator: " · ")
    }

    /// The width of the peek's command box: the detail peek at its narrowest (NotchMetrics)
    /// less PeekDetail's 16-pt margins and the box's 10-pt padding on each side.
    private static let peekTextWidth = NotchMetrics(notch: .zero, panel: .zero, peekExtra: NotchMetrics.peekExtraDetail)
        .body(.peek).width - 2 * 16 - 2 * 10

    /// Whether `detail` fits the peek's box (3 lines of 11-pt monospaced text) without being
    /// cut off, measured as the box lays it out. A few points narrower than the box, so a
    /// borderline command counts as too long.
    static func fitsPeek(_ detail: String) -> Bool {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        func height(_ s: String) -> CGFloat {
            NSAttributedString(string: s, attributes: [.font: font])
                .boundingRect(with: NSSize(width: peekTextWidth - 4, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin]).height
        }
        let line = height("X")
        return line > 0 && height(detail) <= 3 * line + 0.5
    }

    private static func requestAccessory(others: Int) -> ActivityAccessory {
        .text(others > 0 ? "\(others + 1) waiting" : "Allow?")
    }

    /// Approvals off, Notchy answering, or a question or plan Claude Code asks about itself:
    /// only say that the session waits.
    private func postWaiting(_ sessionID: String, _ event: AgentsHookEvent) {
        guard let s = store.book.sessions[sessionID] else { return }
        let fresh = context.activities.activity(id: Self.waitID(sessionID)) == nil
        context.activities.post(Self.waitingActivity(s, event: event)) { [weak self] action in
            if action == "open" { self?.jump(to: sessionID) }
        }
        // `wait` means Notchy isn't running, so it isn't playing its own sound.
        if event.wait, fresh { alertSound(for: sessionID) }
    }

    /// No Allow or Deny here: Claude Code (or Notchy) asks in its own prompt.
    static func waitingActivity(_ s: AgentsSession, event: AgentsHookEvent) -> Activity {
        let tool = event.toolName.map { AgentsToolText.summary(tool: $0, input: event.toolInput) }
        let title = switch event.toolName {
        case "AskUserQuestion": "Claude has a question in \(s.project)"
        case "ExitPlanMode": "Claude has a plan for you in \(s.project)"
        default: "Waiting for you in \(s.project)"
        }
        return Activity(id: waitID(s.id), priority: .permission, symbol: "hand.raised.fill",
                        tint: .orange, accessory: .text("Waiting"), title: title,
                        subtitle: tool, actions: [ActivityAction(id: "open", title: "Open")], opensTab: .agents)
    }

    // MARK: Done ping and jump to session

    /// Flashes the notch and plays the sound, unless the session's own window is in front.
    private func announce(_ ping: AgentsPing, _ s: AgentsSession) {
        if sessionInFront(s) { return }
        let activity = Self.pingActivity(ping, s, sound: claimSound(s.id) ? context.config.agentSound : "")
        context.activities.post(activity) { [weak self] action in
            guard action == "open" else { return }
            self?.context.activities.remove(id: activity.id)
            self?.jump(to: s.id)
        }
    }

    /// The done ping: 8 s in the notch with the user's sound ("" is silent).
    static func pingActivity(_ ping: AgentsPing, _ s: AgentsSession, sound: String) -> Activity {
        Activity(id: "agents.done.\(s.id)", priority: .agent, symbol: "sparkles", tint: .purple,
                 accessory: .text(ping == .finished ? "Done" : "Waiting"), title: ping.title,
                 subtitle: s.project, duration: 8,
                 actions: [ActivityAction(id: "open", title: "Open")], opensTab: .agents,
                 sound: sound.isEmpty ? nil : sound)
    }

    /// Whether the session's own window is in front: its terminal app, or this app's
    /// terminal tab while the panel is open on it. No ping or sound then.
    private func sessionInFront(_ s: AgentsSession) -> Bool {
        guard let pid = s.pid, let host = hostApp(for: pid) else { return false }
        if host == getpid() {
            return context.terminalShowing?(pid) ?? (context.model.isOpen && context.model.currentTab == .terminal)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == host
    }

    /// Claude needs you: plays the user's sound, unless the session's window is in front.
    private func alertSound(for sessionID: String) {
        guard let s = store.book.sessions[sessionID], !sessionInFront(s), claimSound(sessionID) else { return }
        NSSound(named: NSSound.Name(context.config.agentSound))?.play()
    }

    /// Whether a sound may play for the session now: one is set, and none played for it in
    /// the last 2 s (parallel subagents asking at once, a ping right after a request).
    private func claimSound(_ sessionID: String) -> Bool {
        guard !context.config.agentSound.isEmpty else { return false }
        let now = Date()
        if let last = lastSound[sessionID], now.timeIntervalSince(last) < 2 { return false }
        lastSound[sessionID] = now
        return true
    }

    /// The app whose window shows this Claude Code process: Terminal, iTerm, VS Code,
    /// Claude, or this app's own terminal. Remembered per process.
    private func hostApp(for pid: pid_t) -> pid_t? {
        if let known = hosts[pid] { return known }
        let host = AgentsProcess.hostApp(from: pid, own: getpid(), info: AgentsProcess.info) { p in
            NSRunningApplication(processIdentifier: p)?.activationPolicy == .regular
        }
        if let host { hosts[pid] = host }
        return host
    }

    private func pruneHosts() {
        let live = Set(store.book.sessions.values.compactMap(\.pid))
        hosts = hosts.filter { live.contains($0.key) }
    }

    /// Brings the session's terminal or Claude window to the front.
    private func jump(to sessionID: String) {
        guard let pid = store.book.sessions[sessionID]?.pid else { return }
        guard let host = hostApp(for: pid) else {
            Self.log.info("no app window found for Claude Code pid \(pid)")
            return
        }
        let app = NSRunningApplication(processIdentifier: host)
        if host == getpid() || (app?.bundleIdentifier != nil && app?.bundleIdentifier == Bundle.main.bundleIdentifier) {
            if context.revealTerminal?(pid) != true { Self.log.info("no terminal tab owns pid \(pid)") }
            return
        }
        guard let app else { return }
        // Through Launch Services, like a Dock click: an app in the background may not
        // activate another one directly.
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        } else {
            app.activate(options: [])
        }
    }

    // MARK: Dead sessions

    /// Every 30 s while any session is listed: drop the ones whose process is gone.
    private func updateSweep() {
        if store.book.sessions.isEmpty {
            sweepTimer?.cancel()
            sweepTimer = nil
            return
        }
        guard sweepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.sweep() } }
        timer.resume()
        sweepTimer = timer
    }

    private func sweep() {
        var book = store.book
        let gone = book.sweep(now: Date(), isAlive: AgentsProcess.isAlive)
        if !gone.isEmpty {
            store.book = book
            for id in gone { ended(id) }
        }
        updateSweep()
    }

    // MARK: Usage alerts

    private func postUsageAlerts(_ alerts: [(window: AgentsUsageWindow, threshold: Int)]) {
        for (w, threshold) in alerts {
            let percent = Int(w.percent.rounded())
            let name = w.id == "seven_day" ? "weekly" : w.title
            let reset = AgentsFormat.reset(w.resetsAt, now: Date())
            context.activities.post(Activity(
                id: "agents.usage.\(w.id)", priority: .alert, symbol: "gauge.with.dots.needle.67percent",
                tint: threshold >= 95 ? .red : .orange, accessory: .text("\(percent)%"),
                title: "Claude \(name) limit at \(percent)%",
                subtitle: reset.prefix(1).uppercased() + reset.dropFirst(), duration: 15, opensTab: .agents))
        }
    }

    // MARK: Agent Away

    /// Agent Away's line refreshes every 5 s while the Agents tab is on screen.
    private func tabVisible(_ visible: Bool) {
        guard visible else {
            awayTimer?.cancel()
            awayTimer = nil
            return
        }
        refreshAway()
        guard awayTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refreshAway() } }
        timer.resume()
        awayTimer = timer
    }

    private func refreshAway(enabled: Bool? = nil) {
        guard enabled ?? context.config.agentAwayStatus else {
            if store.away != nil { store.away = nil }
            return
        }
        let run = AgentsAway.folder.appendingPathComponent("run", isDirectory: true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = AgentsAway.installed ? AgentsAway.read(runDir: run, isRunning: AgentsAway.isAgentAway) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.store.away != status else { return }
                    self.store.away = status
                }
            }
        }
    }

    private func setKeepAwake(_ on: Bool) {
        AgentsAway.setKeepAwake(on)
        for delay in [0.4, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.refreshAway() }
            }
        }
    }
}

extension AgentsFeature {
    func debugState() -> [String: Any] {
        ["sessions": store.book.ordered.map { ["project": $0.project, "state": $0.state.rawValue, "tool": $0.tool ?? ""] },
         "pendingRequests": pending.count,
         "approvals": store.approvals,
         "usage": store.usage.snapshot.map { String(describing: $0) } ?? "none",
         "usageProblem": store.usage.problem.map { String(describing: $0) } ?? "none",
         "agentAway": store.away.map { String(describing: $0) } ?? "hidden",
         "cost": store.cost.map { c in
             c.scanning ? "scanning" : "today \(AgentsCostFormat.dollars(c.today)), 7 days \(AgentsCostFormat.dollars(c.week)), 30 days \(AgentsCostFormat.dollars(c.month))"
         } ?? "off"]
    }
}

extension AgentsFeature {
    /// The notch reads usage limits from the `claude` command's sign-in, which the desktop
    /// app doesn't create. This signs it in, in a terminal tab (`claude auth login` opens the
    /// browser), then watches for the sign-in to land.
    func signIn() {
        guard let run = context.runInTerminal else { return }
        context.model.close()
        run("claude auth login")
        usage.expectSignIn()
    }
}
