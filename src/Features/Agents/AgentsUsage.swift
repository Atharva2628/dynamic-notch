import AppKit
import os

/// One usage limit: the 5-hour window, the weekly one, or a model's weekly one.
struct AgentsUsageWindow: Codable, Equatable, Identifiable {
    var id: String          // "five_hour", "seven_day", "seven_day_opus", "scoped.fable"
    var title: String       // "5-hour", "Weekly", "Opus weekly"
    var percent: Double     // 0...100
    var resetsAt: Date?
}

struct AgentsUsageSnapshot: Codable, Equatable {
    var fiveHour: AgentsUsageWindow?
    var weekly: AgentsUsageWindow?
    var scoped: [AgentsUsageWindow] = []
    var fetchedAt: Date

    var windows: [AgentsUsageWindow] { [fiveHour, weekly].compactMap { $0 } + scoped }
}

enum AgentsUsageProblem: Equatable {
    case signedOut          // the token was refused, or expired with no way to renew it
    case waitingForClaudeCode   // the token expired; Claude Code renews it the next time it runs
    case notSignedIn        // no Claude Code credentials in the Keychain
    case keychainDenied     // Keychain access refused (or locked); only Refresh asks again
    case offline
    case rateLimited
    case badResponse
    case http(Int)

    var message: String {
        switch self {
        case .signedOut: "Sign in to Claude Code again"
        case .waitingForClaudeCode: "Updates when Claude Code next runs"
        case .notSignedIn: "Sign in to Claude Code to see limits"
        case .keychainDenied: "No Keychain access; click to retry"
        case .offline: "Offline"
        case .rateLimited: "Usage check is rate-limited"
        case .badResponse: "Unexpected usage reply"
        case .http(let code): "Usage check failed (HTTP \(code))"
        }
    }

    /// Shown in orange. An idle Claude Code's expired token is expected, not an error.
    var isError: Bool { self != .waitingForClaudeCode }
}

/// What the views show: the last values, and why they may be old.
struct AgentsUsageState: Equatable {
    var enabled = true
    var snapshot: AgentsUsageSnapshot?
    var problem: AgentsUsageProblem?

    /// No usable sign-in for the `claude` command: the views offer Sign in.
    var needsSignIn: Bool { problem == .notSignedIn || problem == .signedOut }

    /// The last check failed, or the values are more than 15 minutes old.
    func isStale(now: Date) -> Bool {
        problem != nil || snapshot.map { now.timeIntervalSince($0.fetchedAt) > 900 } ?? false
    }

    /// "Updated 3 min ago", or why the values may be old.
    func status(now: Date) -> String {
        let age = snapshot.map { s -> String in
            let seconds = now.timeIntervalSince(s.fetchedAt)
            return seconds < 60 ? "updated just now" : "updated \(AgentsFormat.duration(seconds)) ago"
        }
        if let problem { return ([problem.message] + [age].compactMap { $0 }).joined(separator: " · ") }
        guard let age else { return "Checking…" }
        return age.prefix(1).uppercased() + age.dropFirst()
    }
}

/// Claude Code's sign-in, read from its Keychain item. The token is never logged,
/// stored or shown.
enum AgentsTokenState: Equatable {
    case ok(String)
    case expired(canRefresh: Bool)   // Claude Code renews it (with its refresh token) when it runs
    case missing
}

/// Parses the undocumented /api/oauth/usage reply (the endpoint behind Claude Code's
/// /usage), defensively: any field may be missing, null, a number or a string.
enum AgentsUsageParser {
    static func token(from data: Data, now: Date) -> AgentsTokenState {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return .missing }
        // expiresAt is in epoch milliseconds; allow 30 s for the request itself.
        if let expires = number(oauth["expiresAt"]), expires / 1000 <= now.timeIntervalSince1970 + 30 {
            return .expired(canRefresh: (oauth["refreshToken"] as? String).map { !$0.isEmpty } ?? false)
        }
        return .ok(token)
    }

    static func snapshot(from data: Data, now: Date) -> AgentsUsageSnapshot? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let fiveHour = window(json["five_hour"], id: "five_hour", title: "5-hour")
        let weekly = window(json["seven_day"], id: "seven_day", title: "Weekly")
        var scoped: [AgentsUsageWindow] = []
        // Older replies: one key per model, most of them null.
        for key in json.keys.sorted() where key.hasPrefix("seven_day_") {
            let name = String(key.dropFirst("seven_day_".count))
            guard !["oauth_apps", "cowork"].contains(name),
                  let w = window(json[key], id: key, title: modelTitle(name) + " weekly") else { continue }
            scoped.append(w)
        }
        // Newer replies: a list of limits, which wins over the per-model keys.
        for limit in json["limits"] as? [[String: Any]] ?? [] {
            guard limit["kind"] as? String == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                  let percent = number(limit["percent"] ?? limit["utilization"]) else { continue }
            let name = (model["display_name"] as? String) ?? (model["id"] as? String) ?? "Model"
            let w = AgentsUsageWindow(id: "scoped." + name.lowercased(), title: "\(name) weekly",
                                      percent: clamp(percent), resetsAt: date(limit["resets_at"]))
            scoped.removeAll { $0.title.lowercased() == w.title.lowercased() }
            scoped.append(w)
        }
        guard fiveHour != nil || weekly != nil || !scoped.isEmpty else { return nil }
        return AgentsUsageSnapshot(fiveHour: fiveHour, weekly: weekly, scoped: scoped, fetchedAt: now)
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            return Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
        default: return nil
        }
    }

    /// ISO 8601, with or without fractional seconds (the API sends microseconds, which
    /// ISO8601DateFormatter can't read), or epoch seconds or milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber {
            let v = n.doubleValue
            guard v.isFinite, v > 0 else { return nil }
            let seconds = v > 1e12 ? v / 1000 : v
            return seconds < 1e11 ? Date(timeIntervalSince1970: seconds) : nil   // past year 5000: junk
        }
        guard var s = value as? String, !s.isEmpty else { return nil }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func window(_ value: Any?, id: String, title: String) -> AgentsUsageWindow? {
        guard let w = value as? [String: Any], let percent = number(w["utilization"]) else { return nil }
        return AgentsUsageWindow(id: id, title: title, percent: clamp(percent), resetsAt: date(w["resets_at"]))
    }

    private static func modelTitle(_ key: String) -> String {
        switch key {
        case "omelette": "Design"
        default: key.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    private static func clamp(_ p: Double) -> Double { p.isFinite ? min(max(p, 0), 100) : 0 }
}

/// Which alert thresholds each window has already announced, so an alert goes out once
/// per threshold per window, again only after the window resets. Saved with the last values.
struct AgentsUsageAlerts: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var resetsAt: Date?
        var percent: Double
        var alerted: Int
    }
    var windows: [String: Entry] = [:]

    /// The alerts to post: per window, the highest threshold newly reached.
    mutating func check(_ snapshot: AgentsUsageSnapshot, thresholds: [Int]) -> [(window: AgentsUsageWindow, threshold: Int)] {
        var alerts: [(AgentsUsageWindow, Int)] = []
        for w in snapshot.windows {
            var entry = windows[w.id] ?? Entry(resetsAt: w.resetsAt, percent: w.percent, alerted: 0)
            if Self.isNewWindow(entry, w) { entry.alerted = 0 }
            entry.resetsAt = w.resetsAt
            entry.percent = w.percent
            if let reached = thresholds.filter({ w.percent >= Double($0) }).max(), reached > entry.alerted {
                alerts.append((w, reached))
                entry.alerted = reached
            }
            windows[w.id] = entry
        }
        return alerts
    }

    /// A different reset time, or a big drop, means the window started over.
    private static func isNewWindow(_ old: Entry, _ w: AgentsUsageWindow) -> Bool {
        switch (old.resetsAt, w.resetsAt) {
        case let (a?, b?) where abs(a.timeIntervalSince(b)) > 900: return true
        case (nil, _?), (_?, nil): return true
        default: return w.percent + 20 < old.percent
        }
    }
}

/// What survives a restart: the last values (shown as stale until the next check) and
/// which alerts went out.
struct AgentsUsageCache: Codable {
    var snapshot: AgentsUsageSnapshot?
    var alerts = AgentsUsageAlerts()
}

/// Reads Claude Code's token and asks the usage endpoint. All off the main thread.
enum AgentsUsageClient {
    enum Result {
        case ok(AgentsUsageSnapshot)
        case problem(AgentsUsageProblem, retryAfter: TimeInterval?)
    }

    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// No cache and no cookies: a cached reply would copy the Authorization header to disk.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    static func fetch() async -> Result {
        let (credentials, status) = await withCheckedContinuation { (done: CheckedContinuation<(Data, Int32), Never>) in
            DispatchQueue.global(qos: .utility).async { done.resume(returning: readKeychain()) }
        }
        if let problem = keychainProblem(status: status) { return .problem(problem, retryAfter: nil) }
        let token: String
        switch AgentsUsageParser.token(from: credentials, now: Date()) {
        case .ok(let t): token = t
        // The app never renews the token itself: Claude Code's renewal can replace the refresh
        // token, and a second writer to its Keychain item could sign you out for real.
        case .expired(canRefresh: true): return .problem(.waitingForClaudeCode, retryAfter: nil)
        case .expired(canRefresh: false): return .problem(.signedOut, retryAfter: nil)
        case .missing: return .problem(.notSignedIn, retryAfter: nil)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DynamicNotch/\(Bundle.main.version) (personal)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .problem(.badResponse, retryAfter: nil) }
            switch http.statusCode {
            case 200:
                guard let snapshot = AgentsUsageParser.snapshot(from: data, now: Date()) else {
                    return .problem(.badResponse, retryAfter: nil)
                }
                return .ok(snapshot)
            case 401, 403: return .problem(.signedOut, retryAfter: nil)
            case 429:
                let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                return .problem(.rateLimited, retryAfter: wait)
            default: return .problem(.http(http.statusCode), retryAfter: nil)
            }
        } catch {
            return .problem(.offline, retryAfter: nil)
        }
    }

    /// `security` exits 44 when there is no such item (Claude Code isn't signed in). Any
    /// other failure means access was refused or the Keychain is locked: polling on would
    /// bring a refused Keychain prompt back every few minutes.
    static func keychainProblem(status: Int32) -> AgentsUsageProblem? {
        switch status {
        case 0, 44: nil
        default: .keychainDenied
        }
    }

    /// The same access path Claude Code itself uses, so macOS asks at most once. Returns the
    /// password data (empty on failure) and `security`'s exit status.
    private static func readKeychain() -> (Data, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (Data(), -1) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? (data, 0) : (Data(), p.terminationStatus)
    }
}

/// Checks usage every 5 minutes, and 30 s after a turn ends (at most once a minute).
/// Errors keep the last values, marked stale. Calls `onAlerts` when a window crosses a
/// threshold in `config.usageAlerts`.
@MainActor
final class AgentsUsageMonitor {
    private let store: AgentsStore
    private let file: JSONFile<AgentsUsageCache>
    private var alerts = AgentsUsageAlerts()
    private var next: DispatchWorkItem?
    private var nextAt = Date.distantFuture
    private var fetching = false
    private var running = false
    private var checked = false               // a check answered, so the saved alert state is older
    private var paused = false                // Keychain access refused: only Refresh checks again
    private var delay: TimeInterval = AgentsUsageMonitor.interval
    private var lastStopTrigger = Date.distantPast
    private var lastManual = Date.distantPast
    private var signInUntil = Date.distantPast   // checking often while you sign in
    private var wakeObserver: NSObjectProtocol?

    var thresholds: () -> [Int] = { [] }
    var onAlerts: ([(window: AgentsUsageWindow, threshold: Int)]) -> Void = { _ in }

    static let interval: TimeInterval = 300

    init(store: AgentsStore, fileURL: URL) {
        self.store = store
        self.file = JSONFile(url: fileURL)
    }

    func start() {
        guard !running else { return }
        running = true
        paused = false
        store.usage.enabled = true
        let file = self.file
        DispatchQueue.global(qos: .utility).async {
            let cache = file.load()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let cache, !self.checked else { return }
                    self.alerts = cache.alerts
                    // Shown as stale (by its age) until the first check answers.
                    if self.store.usage.snapshot == nil, let s = cache.snapshot { self.store.usage.snapshot = s }
                }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke() }
        }
        schedule(after: 2)
    }

    /// The timer's clock stops during sleep, so check soon after waking, unless backing
    /// off from a rate limit or error, or paused.
    private func woke() {
        guard running, !paused, delay <= Self.interval else { return }
        schedule(after: 10)
    }

    func stop() {
        running = false
        next?.cancel()
        next = nil
        nextAt = .distantFuture
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        store.usage.enabled = false
    }

    /// A turn ended: limits moved, so check again soon.
    func turnEnded() {
        let now = Date()
        guard running, !paused, delay <= Self.interval, now.timeIntervalSince(lastStopTrigger) >= 60 else { return }
        lastStopTrigger = now
        if nextAt.timeIntervalSince(now) > 30 { schedule(after: 30) }
    }

    /// The Refresh button. At most every 30 s, and never while rate-limited. Also the only
    /// way out of a pause after Keychain access was refused.
    func refreshNow() {
        let now = Date()
        guard running, delay <= Self.interval, now.timeIntervalSince(lastManual) >= 30 else { return }
        lastManual = now
        paused = false
        schedule(after: 0)
    }

    /// You're signing the `claude` command in: check every 10 s for 5 minutes, so the limits
    /// show as soon as the sign-in lands, then go back to the usual pace.
    func expectSignIn() {
        guard running else { return }
        signInUntil = Date().addingTimeInterval(300)
        paused = false
        schedule(after: 10)
    }

    private func schedule(after seconds: TimeInterval) {
        guard running else { return }
        next?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.fetch() } }
        next = work
        nextAt = Date().addingTimeInterval(seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func fetch() {
        guard running, !fetching else { return }
        fetching = true
        Task { [weak self] in
            let result = await AgentsUsageClient.fetch()
            self?.finish(result)
        }
    }

    private func finish(_ result: AgentsUsageClient.Result) {
        fetching = false
        guard running else { return }
        switch result {
        case .ok(let snapshot):
            checked = true
            signInUntil = .distantPast
            delay = Self.interval
            store.usage.snapshot = snapshot
            store.usage.problem = nil
            let fired = alerts.check(snapshot, thresholds: thresholds())
            if !fired.isEmpty { onAlerts(fired) }
            let cache = AgentsUsageCache(snapshot: snapshot, alerts: alerts)
            let file = self.file
            DispatchQueue.global(qos: .utility).async { file.save(cache) }
        case .problem(let problem, let retryAfter):
            store.usage.problem = problem
            switch problem {
            case .rateLimited:
                delay = min(6 * 3600, max(retryAfter ?? 0, min(1800, max(delay * 2, 600))))
            case .http, .badResponse:
                delay = min(1800, max(delay * 2, Self.interval))
            case .signedOut, .notSignedIn:
                delay = Date() < signInUntil ? 10 : Self.interval
            case .offline, .waitingForClaudeCode:
                delay = Self.interval       // a local check, or the network comes back
            case .keychainDenied:
                delay = Self.interval
                paused = true
            }
            AgentsFeature.log.info("usage check: \(problem.message, privacy: .public)")
        }
        if paused {
            next?.cancel()
            next = nil
            nextAt = .distantFuture
        } else {
            schedule(after: delay)
        }
    }
}
