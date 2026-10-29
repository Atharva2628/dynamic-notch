import Foundation

extension AgentsFeature {
    /// Prices, model ids, transcript parsing and the incremental scanner.
    @MainActor
    static func costSelfTest(_ check: (Bool, String) -> Void) {
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

        // Model ids to pricing keys.
        let ids: [(String, String?)] = [
            ("claude-opus-5-5", "opus-5-5"), ("claude-opus-5", "opus-5"), ("claude-fable-5-1", "fable-5-1"),
            ("claude-sonnet-5", "sonnet-5"), ("claude-sonnet-4-5-20250929", "sonnet-4-5"),
            ("claude-opus-4-20250514", "opus-4-0"), ("claude-opus-4-1-20250805", "opus-4-1"),
            ("claude-haiku-4-5-20251001", "haiku-4-5"), ("claude-3-5-haiku-20241022", "haiku-3-5"),
            ("claude-3-7-sonnet-20250219", "sonnet-3-7"), ("claude-3-haiku-20240307", "haiku-3"),
            ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", "sonnet-4-5"), ("<synthetic>", nil), ("gpt-5", nil),
        ]
        check(ids.allSatisfy { AgentsPricing.key(for: $0.0) == $0.1 },
              "agents cost: model ids map to prices, dated and cloud ids included, unknown ones don't")

        // Prices per response. A real Opus 5.5 response: 2 input, 957 1-hour cache writes,
        // 845,481 cache reads, 3,318 output tokens.
        let real = AgentsCostUsage(model: "claude-opus-5-5", input: 2, write1h: 957, read: 845_481, output: 3318)
        check(near(AgentsPricing.cost(real), (2 * 4 + 957 * 8 + 845_481 * 0.2 + 3318 * 20) / 1e6),
              "agents cost: Opus 5.5 at $4 in, $8 1-hour writes, $0.20 reads, $20 out")
        check(near(AgentsPricing.cost(AgentsCostUsage(model: "claude-opus-5-5", output: 1_000_000, fast: true)), 40)
              && near(AgentsPricing.cost(AgentsCostUsage(model: "claude-opus-4-8", input: 1_000_000, fast: true)), 10)
              && near(AgentsPricing.cost(AgentsCostUsage(model: "claude-opus-4-7", input: 1_000_000, fast: true)), 5),
              "agents cost: fast mode prices Opus 5.5, 5 and 4.8 only")
        check(near(AgentsPricing.cost(AgentsCostUsage(model: "claude-sonnet-5-5", input: 1_000_000, usOnly: true)), 2.2)
              && near(AgentsPricing.cost(AgentsCostUsage(model: "claude-sonnet-4-5", input: 1_000_000, usOnly: true)), 3),
              "agents cost: US-only inference adds 10% on 4.6 and later models only")
        check(near(AgentsPricing.cost(AgentsCostUsage(model: "claude-haiku-5-5", input: 100_000)), 0.01)
              && near(AgentsPricing.cost(AgentsCostUsage(model: "claude-haiku-5-5", input: 50_000, read: 50_001)),
                      (50_000 * 0.5 + 50_001 * 0.05) / 1e6),
              "agents cost: Haiku 5.5 costs more once the whole prompt passes 100,000 tokens")
        check(near(AgentsPricing.cost(AgentsCostUsage(model: "claude-fable-5-1", read: 1_000_000)), 0.25)
              && near(AgentsPricing.cost(AgentsCostUsage(model: "claude-sonnet-5-5", write5m: 1_000_000)), 2.5)
              && near(AgentsPricing.cost(AgentsCostUsage(model: "claude-opus-4-1", output: 1_000_000)), 75),
              "agents cost: cache reads and writes and older models use their own rates")
        check(near(AgentsPricing.cost(AgentsCostUsage(model: "claude-haiku-4-5", webSearches: 3)), 0.03)
              && AgentsPricing.cost(AgentsCostUsage(model: "<synthetic>", input: 5)) == nil,
              "agents cost: web searches are $0.01 each, and unknown models have no price")

        // Parsing `usage`.
        let parsed = AgentsCostUsage(model: "m", usage: [
            "input_tokens": 3, "output_tokens": 9, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 50,
            "cache_creation": ["ephemeral_5m_input_tokens": 20, "ephemeral_1h_input_tokens": 30],
            "speed": "fast", "inference_geo": "us", "server_tool_use": ["web_search_requests": 2],
        ])
        let unsplit = AgentsCostUsage(model: "m", usage: ["cache_creation_input_tokens": 40])
        check(parsed == AgentsCostUsage(model: "m", input: 3, write5m: 20, write1h: 30, read: 100, output: 9,
                                        fast: true, usOnly: true, webSearches: 2)
              && unsplit?.write5m == 40 && unsplit?.write1h == 0,
              "agents cost: usage fields parse, and cache writes without a split count as 5-minute writes")

        // The scanner, on made-up transcripts.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dynamicnotch-cost-\(UUID().uuidString)", isDirectory: true)
        let project = dir.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26 in UTC
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ id: String, _ request: String, _ model: String, _ output: Int, daysAgo: Double, session: String = "s1") -> String {
            let stamp = iso.string(from: now.addingTimeInterval(-daysAgo * 86_400))
            return #"{"type":"assistant","sessionId":"\#(session)","requestId":"\#(request)","timestamp":"\#(stamp)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":0,"output_tokens":\#(output)}}}"#
        }
        let userLine = #"{"type":"user","timestamp":"2026-10-26T00:00:00.000Z","message":{"content":"text with \"type\":\"assistant\" inside"}}"#
        let a = project.appendingPathComponent("a.jsonl"), b = project.appendingPathComponent("b.jsonl")
        let m1 = line("m1", "r1", "claude-opus-5-5", 1_000_000, daysAgo: 0.1)       // $20, written three times
        try? ([m1, m1, m1, userLine, line("x", "rx", "<synthetic>", 10, daysAgo: 0.1),
               line("old", "ro", "claude-opus-5-5", 1_000_000, daysAgo: 40)].joined(separator: "\n") + "\n").write(to: a, atomically: true, encoding: .utf8)
        try? ([m1, line("m2", "r2", "claude-sonnet-5-5", 1_000_000, daysAgo: 1.1, session: "s2"),   // $10, yesterday
               line("m9", "r9", "claude-mystery-1", 1000, daysAgo: 0.2)].joined(separator: "\n") + "\n").write(to: b, atomically: true, encoding: .utf8)
        let scanner = AgentsCostScanner(root: dir, store: nil, calendar: utc)
        var r = scanner.scan(now: now, save: false)
        check(near(r.today, 20) && near(r.week, 30) && near(r.month, 30) && r.unpriced == 1,
              "agents cost: each response counts once across repeated lines and copied files; old, synthetic and user lines don't")
        check(r.models.map(\.id) == ["opus-5-5", "sonnet-5-5"] && r.days.count == 14 && near(r.days.last?.cost, 20)
              && near(r.sessions["s1"], 20) && near(r.sessions["s2"], 10),
              "agents cost: per-model, per-day and per-session totals")

        // Appended lines are read on the next scan, and a partial last line waits.
        if let h = try? FileHandle(forWritingTo: a) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data((line("m3", "r3", "claude-haiku-5-5", 1_000_000, daysAgo: 0.05) + "\n" + #"{"type":"assistant","#).utf8))
            try? h.close()
        }
        r = scanner.scan(now: now, save: false)
        check(near(r.today, 20.5), "agents cost: the next scan reads only what was appended")
        // A rewritten (shorter) file is read again, without counting anything twice.
        try? (line("m2", "r2", "claude-sonnet-5-5", 1_000_000, daysAgo: 1.1, session: "s2") + "\n").write(to: b, atomically: true, encoding: .utf8)
        r = scanner.scan(now: now, save: false)
        check(near(r.week, 30.5), "agents cost: a rewritten transcript isn't counted twice")
        // Saved and loaded again, it picks up where it left off.
        let indexURL = dir.appendingPathComponent("index.json")
        let saving = AgentsCostScanner(root: dir, store: indexURL, calendar: utc)
        saving.scan(now: now, save: true)
        let reloaded = AgentsCostScanner(root: dir, store: indexURL, calendar: utc)
        check(near(reloaded.report(now: now).week, 30.5) && near(reloaded.scan(now: now, save: false).week, 30.5),
              "agents cost: the saved index survives a restart and isn't added again")

        // A streamed response's earlier lines carry partial output counts; the largest wins,
        // whichever order the files are read in. WebSearch calls add an estimate each.
        let streamed = dir.appendingPathComponent("streamed", isDirectory: true)
        try? FileManager.default.createDirectory(at: streamed, withIntermediateDirectories: true)
        func partial(_ id: String, _ output: Int, search: String? = nil) -> String {
            let stamp = iso.string(from: now.addingTimeInterval(-3600))
            let content = search.map { #","content":[{"type":"tool_use","id":"\#($0)","name":"WebSearch","input":{}}]"# } ?? ""
            return #"{"type":"assistant","sessionId":"s9","requestId":"r-\#(id)","timestamp":"\#(stamp)","message":{"id":"\#(id)","model":"claude-opus-5-5"\#(content),"usage":{"input_tokens":0,"output_tokens":\#(output)}}}"#
        }
        try? ([partial("p1", 5), partial("p1", 5, search: "toolu_1"), partial("p1", 500_000),
               partial("p2", 400_000), partial("p2", 7, search: "toolu_1")].joined(separator: "\n") + "\n")
            .write(to: streamed.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let streamScan = AgentsCostScanner(root: streamed, store: nil, calendar: utc).scan(now: now, save: false)
        check(near(streamScan.today, 10 + 8 + AgentsPricing.webSearchCall)
              && streamScan.models.first(where: { $0.id == "opus-5-5" })?.tokens == 900_000
              && near(streamScan.sessions["s9"], 18 + AgentsPricing.webSearchCall),
              "agents cost: a streamed response counts its final output, whatever order its lines come in, and each WebSearch call counts once")
        try? FileManager.default.removeItem(at: dir)

        check(AgentsCostFormat.dollars(0.42) == "$0.42" && AgentsCostFormat.dollars(184.2) == "$184"
              && AgentsCostFormat.dollars(1240.4) == "$1,240" && AgentsCostFormat.dollars(96.3, compact: true) == "$96" && AgentsCostFormat.modelName("opus-5-5") == "Opus 5.5"
              && AgentsCostFormat.tokens(612_000_000) == "612.0M" && AgentsCostFormat.tokens(45_000) == "45K",
              "agents cost: dollars, model names and token counts read naturally")
    }
}
