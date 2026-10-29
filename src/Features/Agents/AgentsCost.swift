import Foundation

/// What Claude Code's tokens would cost at Anthropic's API prices (platform.claude.com
/// pricing page, checked 2026-10-26). An estimate of value, not of what you pay: a
/// subscription doesn't bill per token.
enum AgentsPricing {
    /// Dollars per million tokens.
    struct Rates: Equatable {
        var input: Double
        var write5m: Double
        var write1h: Double
        var read: Double
        var output: Double

        /// Cache writes at 1.25x and 2x input, reads at `readFactor` x input.
        static func standard(_ input: Double, _ output: Double, readFactor: Double = 0.1) -> Rates {
            Rates(input: input, write5m: input * 1.25, write1h: input * 2, read: input * readFactor, output: output)
        }
    }

    /// The pricing key for a model id ("claude-opus-5-5", "claude-sonnet-4-5-20250929",
    /// "claude-3-5-haiku-20241022", "us.anthropic.claude-opus-4-1-20250805-v1:0"):
    /// "opus-5-5", "sonnet-4-5", "haiku-3-5". Nil for anything else ("<synthetic>").
    static func key(for model: String) -> String? {
        let m = model.lowercased()
        let families = ["fable", "mythos", "opus", "sonnet", "haiku"]
        // Current style: claude-<family>-<major>[-<minor>], then a date or nothing. A minor is
        // one digit not followed by another (dates are 8 digits).
        for family in families {
            guard let r = m.range(of: "claude-\(family)-") else { continue }
            let rest = Array(m[r.upperBound...])
            guard let major = rest.first, major.isNumber else { continue }
            var minor: Character?
            if rest.count >= 3, rest[1] == "-", rest[2].isNumber, rest.count == 3 || !rest[3].isNumber {
                minor = rest[2]
            }
            let version = minor.map { "\(major)-\($0)" } ?? (major == "4" ? "4-0" : String(major))
            return "\(family)-\(version)"
        }
        // Claude 3 style: claude-3-5-sonnet, claude-3-7-sonnet, claude-3-haiku.
        for family in families {
            if m.contains("claude-3-7-\(family)") { return "\(family)-3-7" }
            if m.contains("claude-3-5-\(family)") { return "\(family)-3-5" }
            if m.contains("claude-3-\(family)") { return "\(family)-3" }
        }
        return nil
    }

    /// Rates for a pricing key. `promptTokens` is the request's whole prompt (input plus cache
    /// reads and writes): Claude Haiku 5.5 costs more above 100,000. `fast` is fast mode.
    static func rates(for key: String, promptTokens: Int = 0, fast: Bool = false) -> Rates? {
        switch key {
        case "fable-5-1", "mythos-5-1": return .standard(10, 50, readFactor: 0.025)
        case "fable-5", "mythos-5": return .standard(10, 50)
        case "opus-5-5": return fast ? .standard(8, 40, readFactor: 0.05) : .standard(4, 20, readFactor: 0.05)
        case "opus-5", "opus-4-8": return fast ? .standard(10, 50) : .standard(5, 25)
        case "opus-4-7", "opus-4-6", "opus-4-5": return .standard(5, 25)
        case "opus-4-1", "opus-4-0", "opus-3": return .standard(15, 75)
        case "sonnet-5-5": return .standard(2, 10, readFactor: 0.05)
        case "sonnet-5": return .standard(2, 10)
        case "sonnet-4-6", "sonnet-4-5", "sonnet-4-0", "sonnet-3-7", "sonnet-3-5": return .standard(3, 15)
        case "haiku-5-5": return promptTokens > 100_000 ? .standard(0.5, 2.5) : .standard(0.1, 0.5)
        case "haiku-4-5": return .standard(1, 5)
        case "haiku-3-5": return .standard(0.8, 4)
        case "haiku-3": return Rates(input: 0.25, write5m: 0.3, write1h: 0.5, read: 0.03, output: 1.25)  // last published rates
        default: return nil
        }
    }

    /// US-only inference (`inference_geo: "us"`) costs 1.1x on Claude 4.6 and later models.
    static func hasGeoPremium(_ key: String) -> Bool {
        !["opus-4-5", "opus-4-1", "opus-4-0", "opus-3", "sonnet-4-5", "sonnet-4-0", "sonnet-3-7",
          "sonnet-3-5", "haiku-4-5", "haiku-3-5", "haiku-3"].contains(key)
    }

    static let webSearchEach = 0.01   // $10 per 1,000 searches

    /// Claude Code's WebSearch tool runs its searches in a separate request that its
    /// transcripts don't record, so each call is an estimate: about 1.3 searches at $0.01,
    /// plus that request's tokens.
    static let webSearchCall = 0.02

    /// The API price of one response, or nil for a model with no known price.
    static func cost(_ u: AgentsCostUsage) -> Double? {
        guard let key = key(for: u.model),
              let r = rates(for: key, promptTokens: u.input + u.write5m + u.write1h + u.read, fast: u.fast) else { return nil }
        var tokens = Double(u.input) * r.input + Double(u.write5m) * r.write5m + Double(u.write1h) * r.write1h
        tokens += Double(u.read) * r.read + Double(u.output) * r.output
        var dollars = tokens / 1_000_000
        if u.usOnly && hasGeoPremium(key) { dollars *= 1.1 }
        return dollars + Double(u.webSearches) * webSearchEach
    }
}

/// The billable parts of one assistant message's `usage` in a Claude Code transcript.
struct AgentsCostUsage: Equatable {
    var model: String
    var input = 0
    var write5m = 0
    var write1h = 0
    var read = 0
    var output = 0
    var fast = false
    var usOnly = false
    var webSearches = 0

    var tokens: Int { input + write5m + write1h + read + output }

    init(model: String, input: Int = 0, write5m: Int = 0, write1h: Int = 0, read: Int = 0, output: Int = 0,
         fast: Bool = false, usOnly: Bool = false, webSearches: Int = 0) {
        self.model = model
        self.input = input
        self.write5m = write5m
        self.write1h = write1h
        self.read = read
        self.output = output
        self.fast = fast
        self.usOnly = usOnly
        self.webSearches = webSearches
    }

    /// From `message.model` and `message.usage`. Cache writes without the 5-minute/1-hour
    /// split count as 5-minute writes, the default.
    init?(model: String, usage u: [String: Any]) {
        func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
        self.model = model
        input = int(u["input_tokens"])
        output = int(u["output_tokens"])
        read = int(u["cache_read_input_tokens"])
        let created = int(u["cache_creation_input_tokens"])
        if let split = u["cache_creation"] as? [String: Any] {
            write5m = int(split["ephemeral_5m_input_tokens"])
            write1h = int(split["ephemeral_1h_input_tokens"])
            if write5m + write1h < created { write5m += created - write5m - write1h }
        } else {
            write5m = created
        }
        fast = (u["speed"] as? String) == "fast"
        usOnly = (u["inference_geo"] as? String) == "us"
        webSearches = int((u["server_tool_use"] as? [String: Any])?["web_search_requests"])
    }
}

/// Totals for one model on one day.
struct AgentsCostTotals: Codable, Equatable {
    var cost: Double = 0
    var tokens: Int = 0
    var output: Int = 0
    var messages: Int = 0

    mutating func add(_ dollars: Double, _ u: AgentsCostUsage) {
        cost += dollars
        tokens += u.tokens
        output += u.output
        messages += 1
    }
}

/// What the views show.
struct AgentsCostReport: Equatable {
    struct Model: Equatable, Identifiable {
        var id: String          // pricing key
        var cost: Double
        var tokens: Int
    }

    struct Day: Equatable, Identifiable {
        var id: String          // yyyy-MM-dd
        var cost: Double
    }

    var today: Double = 0
    var week: Double = 0        // the last 7 days, today included
    var month: Double = 0       // the last 30 days
    var models: [Model] = []    // the last 30 days, most expensive first
    var days: [Day] = []        // the last 14 days, oldest first
    var sessions: [String: Double] = [:]   // session id -> cost in the last 35 days
    var unpriced = 0            // responses from models with no known price (30 days)
    var scanning = false        // the first scan hasn't finished
}

/// Reads Claude Code's transcripts (~/.claude/projects/**/*.jsonl) and adds up what each
/// response would cost at API prices. Incremental: it remembers how far it read each file,
/// so after the first scan it only reads what was appended. Each response is counted once
/// (Claude Code writes one line per content block, and resumed sessions copy history).
/// Confined to one serial queue; not thread-safe on its own.
final class AgentsCostScanner {
    struct Index: Codable {
        struct File: Codable { var offset: Int64; var size: Int64 }
        struct Session: Codable { var cost: Double; var day: String }
        /// A response already read: its day, the largest output count so far (a streamed
        /// response's earlier lines carry partial counts), and whether it was counted.
        struct Seen: Codable { var day: String; var output: Int; var counted: Bool }
        var version = 2
        var zone: String? = nil                                // the time zone the days are in
        var files: [String: File] = [:]
        var days: [String: [String: AgentsCostTotals]] = [:]   // day -> pricing key -> totals
        var unpriced: [String: Int] = [:]                      // day -> responses with no price
        var sessions: [String: Session] = [:]
        var seen: [String: Seen] = [:]                         // message id + request id (or tool use id) -> what was counted
    }

    static let keepDays = 35
    private(set) var index = Index()
    private let root: URL
    private let file: JSONFile<Index>?
    private var dirty = false
    private var loaded = false
    private var calendar: Calendar
    private let followsSystemZone: Bool
    private let dayFormat: DateFormatter
    private let isoFractional = ISO8601DateFormatter()
    private let iso = ISO8601DateFormatter()

    /// `calendar` fixes the time zone (tests); without it the scanner follows the system's.
    init(root: URL, store: URL?, calendar: Calendar? = nil) {
        self.root = root
        self.calendar = calendar ?? .current
        followsSystemZone = calendar == nil
        file = store.map { JSONFile<Index>(url: $0) }
        dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.calendar = self.calendar
        dayFormat.timeZone = self.calendar.timeZone
        dayFormat.dateFormat = "yyyy-MM-dd"
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Loads the saved index on first use, on the scanner's queue (it can be a few MB).
    /// An older version, or days in another time zone, start over with a full read.
    private func loadIfNeeded() {
        if followsSystemZone, TimeZone.current.identifier != calendar.timeZone.identifier {
            calendar.timeZone = .current
            dayFormat.timeZone = .current
        }
        if !loaded {
            loaded = true
            if let saved = file?.load(), saved.version == Index().version { index = saved }
        }
        if index.zone != calendar.timeZone.identifier {
            index = Index()
            index.zone = calendar.timeZone.identifier
            dirty = true
        }
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    func day(_ date: Date) -> String { dayFormat.string(from: date) }

    /// Reads what's new, saves the index when asked, and returns the report for `now`.
    @discardableResult
    func scan(now: Date = Date(), save: Bool = true) -> AgentsCostReport {
        loadIfNeeded()
        let cutoff = day(calendar.date(byAdding: .day, value: -Self.keepDays, to: now) ?? now)
        prune(before: cutoff)
        let oldest = calendar.date(byAdding: .day, value: -Self.keepDays, to: now) ?? .distantPast
        var present = Set<String>()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .creationDateKey]
        var found: [(url: URL, size: Int64, modified: Date, created: Date)] = []
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            while let url = walker.nextObject() as? URL {
                guard url.pathExtension == "jsonl", let v = try? url.resourceValues(forKeys: Set(keys)),
                      let size = v.fileSize.map(Int64.init), let modified = v.contentModificationDate else { continue }
                found.append((url, size, modified, v.creationDate ?? modified))
            }
        }
        // Oldest first: a resumed or forked session copies earlier history, which then
        // counts for the session it was first written in.
        found.sort { $0.created != $1.created ? $0.created < $1.created : $0.url.path < $1.url.path }
        for (url, size, modified, _) in found {
            let path = url.path
            present.insert(path)
            var state = index.files[path] ?? Index.File(offset: 0, size: 0)
            if size < state.offset { state = Index.File(offset: 0, size: 0) }   // rewritten: read again; dedupe skips repeats
            guard size > state.offset else { continue }
            if state.offset == 0 && modified < oldest {
                index.files[path] = Index.File(offset: size, size: size)      // nothing in the window
                dirty = true
                continue
            }
            state.offset = read(path, from: state.offset, cutoff: cutoff)
            state.size = size
            index.files[path] = state
            dirty = true
        }
        for path in index.files.keys where !present.contains(path) {
            index.files[path] = nil
            dirty = true
        }
        if save, dirty, let file {
            file.save(index)
            dirty = false
        }
        return report(now: now)
    }

    /// Reads complete lines from `offset` and returns the offset after the last one.
    private func read(_ path: String, from offset: Int64, cutoff: String) -> Int64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(offset)) } catch { return offset }
        var position = offset
        var carry = Data()
        let marker = Data(#""type":"assistant""#.utf8)
        while true {
            let chunk = autoreleasepool { (try? handle.read(upToCount: 1 << 20)) ?? Data() }
            if chunk.isEmpty { break }
            carry.append(chunk)
            var start = carry.startIndex
            while let newline = carry[start...].firstIndex(of: 0x0A) {
                let line = carry[start..<newline]
                // Each parsed line's objects go as soon as it's counted; a transcript can hold
                // thousands of large lines.
                if line.range(of: marker) != nil { autoreleasepool { take(line, cutoff: cutoff) } }
                position += Int64(newline - start + 1)
                start = carry.index(after: newline)
            }
            // A partial last line waits for the next chunk (or the next scan).
            carry.removeSubrange(carry.startIndex..<start)
        }
        return position
    }

    /// Counts one transcript line if it's a priced assistant response not seen before.
    private func take(_ line: Data, cutoff: String) {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usageJSON = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              let stamp = json["timestamp"] as? String,
              let date = isoFractional.date(from: stamp) ?? iso.date(from: stamp) else { return }
        let day = day(date)
        guard day >= cutoff else { return }
        let session = json["sessionId"] as? String
        // Each content block is its own line, so a WebSearch call can be on any of them.
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where block["type"] as? String == "tool_use" && block["name"] as? String == "WebSearch" {
                guard let toolID = block["id"] as? String, index.seen[toolID] == nil else { continue }
                index.seen[toolID] = Index.Seen(day: day, output: 0, counted: true)
                var t = index.days[day, default: [:]]["web-search", default: AgentsCostTotals()]
                t.cost += AgentsPricing.webSearchCall
                t.messages += 1
                index.days[day, default: [:]]["web-search"] = t
                addToSession(session, AgentsPricing.webSearchCall, day: day)
            }
        }
        let id = (message["id"] as? String) ?? ""
        let request = (json["requestId"] as? String) ?? ""
        let key = id.isEmpty && request.isEmpty ? "\(stamp)|\(model)" : "\(id):\(request)"
        guard let usage = AgentsCostUsage(model: model, usage: usageJSON) else { return }
        let pricing = AgentsPricing.key(for: model)
        let dollars = AgentsPricing.cost(usage)

        // Seen before: a later line of the same response. Its input and cache counts are the
        // same; only the output may have grown (earlier lines carry partial counts).
        if let prev = index.seen[key] {
            if prev.counted {
                guard usage.output > prev.output, let pricing, let dollars else { return }
                var before = usage
                before.output = prev.output
                let extra = dollars - (AgentsPricing.cost(before) ?? dollars)
                let more = usage.output - prev.output
                index.seen[key]?.output = usage.output
                if var t = index.days[prev.day]?[pricing] {
                    t.cost += extra
                    t.tokens += more
                    t.output += more
                    index.days[prev.day]?[pricing] = t
                }
                addToSession(session, extra, day: prev.day)
                return
            }
            // Its first line had no tokens; count this one if it has.
            guard usage.tokens > 0, let pricing, let dollars else { return }
            index.seen[key] = Index.Seen(day: prev.day, output: usage.output, counted: true)
            index.days[prev.day, default: [:]][pricing, default: AgentsCostTotals()].add(dollars, usage)
            addToSession(session, dollars, day: prev.day)
            return
        }

        guard usage.tokens > 0, let pricing, let dollars else {
            index.seen[key] = Index.Seen(day: day, output: usage.output, counted: false)
            if usage.tokens > 0, model != "<synthetic>" { index.unpriced[day, default: 0] += 1 }
            return
        }
        index.seen[key] = Index.Seen(day: day, output: usage.output, counted: true)
        index.days[day, default: [:]][pricing, default: AgentsCostTotals()].add(dollars, usage)
        addToSession(session, dollars, day: day)
    }

    private func addToSession(_ session: String?, _ dollars: Double, day: String) {
        guard let session else { return }
        var s = index.sessions[session] ?? Index.Session(cost: 0, day: day)
        s.cost += dollars
        s.day = max(s.day, day)
        index.sessions[session] = s
    }

    private func prune(before cutoff: String) {
        let days = index.days.keys.filter { $0 < cutoff }
        let seen = index.seen.filter { $0.value.day < cutoff }.map(\.key)
        let sessions = index.sessions.filter { $0.value.day < cutoff }.map(\.key)
        let unpriced = index.unpriced.keys.filter { $0 < cutoff }
        guard !days.isEmpty || !seen.isEmpty || !sessions.isEmpty || !unpriced.isEmpty else { return }
        for d in days { index.days[d] = nil }
        for k in seen { index.seen[k] = nil }
        for s in sessions { index.sessions[s] = nil }
        for d in unpriced { index.unpriced[d] = nil }
        dirty = true
    }

    func report(now: Date) -> AgentsCostReport {
        loadIfNeeded()
        func dayKey(_ back: Int) -> String { day(calendar.date(byAdding: .day, value: -back, to: now) ?? now) }
        let today = dayKey(0), weekStart = dayKey(6), monthStart = dayKey(29)
        var r = AgentsCostReport()
        var models: [String: AgentsCostReport.Model] = [:]
        for (d, perModel) in index.days where d >= monthStart && d <= today {
            let total = perModel.values.reduce(0) { $0 + $1.cost }
            r.month += total
            if d >= weekStart { r.week += total }
            if d == today { r.today += total }
            for (key, t) in perModel {
                var m = models[key] ?? AgentsCostReport.Model(id: key, cost: 0, tokens: 0)
                m.cost += t.cost
                m.tokens += t.tokens
                models[key] = m
            }
        }
        r.models = models.values.sorted { $0.cost > $1.cost }
        r.days = (0..<14).reversed().map { back in
            let d = dayKey(back)
            return AgentsCostReport.Day(id: d, cost: index.days[d]?.values.reduce(0) { $0 + $1.cost } ?? 0)
        }
        r.sessions = index.sessions.mapValues(\.cost)
        r.unpriced = index.unpriced.filter { $0.key >= monthStart }.values.reduce(0, +)
        return r
    }
}

enum AgentsCostFormat {
    /// "$0.42", "$12.30", "$184", "$1,240". `compact` drops the cents from $10 up ("$96").
    static func dollars(_ value: Double, compact: Bool = false) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        let whole = value >= (compact ? 10 : 100)
        f.maximumFractionDigits = whole ? 0 : 2
        f.minimumFractionDigits = whole ? 0 : 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    /// "Opus 5.5" from "opus-5-5".
    static func modelName(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard let family = parts.first else { return key }
        let version = parts.dropFirst().joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    /// "1.2M", "845K", "312".
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...: return "\(n / 1000)K"
        case 1000...: return String(format: "%.1fK", Double(n) / 1000)
        default: return "\(n)"
        }
    }
}

/// Runs the scanner off the main thread: every minute while you're looking at usage,
/// every 5 minutes otherwise, and soon after a Claude turn ends.
@MainActor
final class AgentsCostMonitor {
    private let store: AgentsStore
    private let scanner: AgentsCostScanner
    private let queue = DispatchQueue(label: "local.dynamicnotch.agents.cost", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var running = false
    private var scanning = false
    private var lastSave = Date.distantPast
    var isVisible: () -> Bool = { false }

    init(store: AgentsStore, root: URL = AgentsCostScanner.defaultRoot, indexURL: URL?) {
        self.store = store
        scanner = AgentsCostScanner(root: root, store: indexURL)
    }

    func start() {
        guard !running else { return }
        running = true
        if store.cost == nil { store.cost = AgentsCostReport(scanning: true) }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        var ticks = 0
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                ticks += 1
                if self.isVisible() || ticks % 5 == 0 { self.scan() }
            }
        }
        t.resume()
        timer = t
        scan()
    }

    func stop() {
        running = false
        timer?.cancel()
        timer = nil
        pending?.cancel()
        pending = nil
        store.cost = nil
    }

    /// A turn ended: its tokens are in the transcript now. Waits for the burst to settle.
    func turnEnded() {
        guard running else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    func scan() {
        guard running, !scanning else { return }
        scanning = true
        // The index is written at most every 5 minutes; it can be a few MB.
        let save = Date().timeIntervalSince(lastSave) > 300
        if save { lastSave = Date() }
        let scanner = self.scanner
        queue.async { [weak self] in
            let report = scanner.scan(now: Date(), save: save)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanning = false
                    guard self.running else { return }
                    if self.store.cost != report { self.store.cost = report }
                }
            }
        }
    }
}
