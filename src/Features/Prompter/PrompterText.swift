import Foundation
import os

enum PrompterLog {
    static let logger = Logger(subsystem: "local.dynamicnotch", category: "prompter")
}

/// Turning a script file into what the prompter shows, counting its words and timing it.
/// Pure, so the self-test can check it.
enum PrompterText {
    /// Markdown to prompter text: headings lose their `#`, list markers become bullets,
    /// quotes lose their `>`, and comments, front matter, code fences and rules go.
    /// Inline emphasis (`**bold**`) is kept for `attributed(_:)`.
    static func display(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // A comment on a line of its own takes the line with it.
        text = text.replacingOccurrences(of: "(?m)^[ \\t]*<!--(?:(?!-->)[\\s\\S])*-->[ \\t]*\\n", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        if text.hasPrefix("---\n") {
            let bodyStart = text.index(text.startIndex, offsetBy: 4)
            if let end = text.range(of: "\n---\n", range: bodyStart..<text.endIndex),
               isFrontMatter(text[bodyStart..<end.lowerBound]) {
                text = String(text[end.upperBound...])
            }
        }
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            while line.last?.isWhitespace == true { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { continue }
            if trimmed.count >= 3, Set(trimmed.filter { $0 != " " }).count == 1, let c = trimmed.first, "-*_".contains(c) {
                lines.append("")
                continue
            }
            if let heading = trimmed.firstMatch(of: #/^#{1,6}\s+(.*?)\s*#*$/#) {
                line = String(heading.1)
            } else if let item = trimmed.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
                line = "• " + item.1
            } else if let quote = trimmed.firstMatch(of: #/^>\s?(.*)$/#) {
                line = String(quote.1)
            }
            lines.append(line)
        }
        // At most one blank line between paragraphs, none at the ends.
        var out: [String] = []
        for line in lines {
            if line.isEmpty && (out.last?.isEmpty ?? true) { continue }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// YAML front matter opens with a "key:" line. A script that merely starts with a rule
    /// ("---", then text, then another rule) keeps its first section.
    private static func isFrontMatter(_ block: Substring) -> Bool {
        guard let first = block.split(separator: "\n").first(where: { !$0.allSatisfy(\.isWhitespace) }) else { return true }
        return first.firstMatch(of: #/^[A-Za-z0-9_-]+:(\s|$)/#) != nil
    }

    /// The display text with inline Markdown applied (bold, italic, code), line breaks kept.
    static func attributed(_ display: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: display, options: options)) ?? AttributedString(display)
    }

    /// Words are runs without spaces that hold at least one letter or digit, so a lone
    /// dash or bullet doesn't count.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .count
    }

    /// Seconds to say `words` at `wordsPerMinute`.
    static func duration(words: Int, wordsPerMinute: Double) -> TimeInterval {
        guard wordsPerMinute > 0 else { return 0 }
        return Double(max(0, words)) / wordsPerMinute * 60
    }

    /// "0:45", "2:05", "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded())
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    /// The first few hundred characters, for the tab's preview.
    static func preview(_ display: String, limit: Int = 700) -> String {
        display.count <= limit ? display : String(display.prefix(limit)) + "…"
    }

    /// A safe, unique file name for a script title: no slashes, colons or control
    /// characters, no leading dots (hidden files), at most 80 characters, "Untitled" when
    /// nothing is left. `taken` holds lowercased names already in the folder (APFS
    /// ignores case), and a clash gets " 2", " 3", … before the extension.
    static func fileName(for title: String, taken: Set<String>, ext: String = "md") -> String {
        var name = String(title.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            if "/:\\".unicodeScalars.contains(scalar) { return "-" }
            return Character(scalar)
        })
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let first = name.first, first == "." || first == " " { name.removeFirst() }
        if name.count > 80 { name = String(name.prefix(80)) }
        while let last = name.last, last == "." || last == " " { name.removeLast() }
        if name.isEmpty { name = "Untitled" }
        var candidate = "\(name).\(ext)"
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) \(n).\(ext)"
            n += 1
        }
        return candidate
    }
}

/// One script imported from Notchy's Cuely.
struct PrompterImport: Equatable {
    var title: String
    var body: String
}

/// Reads Notchy's teleprompter ("Cuely") scripts from its settings, read-only.
enum PrompterNotchy {
    static let domain = "dev.notchy.app"
    static let fallbackTitle = "Notchy Script"

    /// The scripts in `defaults export dev.notchy.app -` output: "cuely.library" is JSON
    /// `[{id, title, body}]` (as data, or a string), and "cuely.script" a single script
    /// used when the library is missing or empty. Empty and repeated bodies are skipped.
    static func scripts(fromPlist data: Data) -> [PrompterImport] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return [] }
        return scripts(fromDefaults: dict)
    }

    static func scripts(fromDefaults dict: [String: Any]) -> [PrompterImport] {
        var found: [PrompterImport] = []
        func add(_ title: String, _ body: String) {
            let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !found.contains(where: { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == clean }) else { return }
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(PrompterImport(title: name.isEmpty ? fallbackTitle : name, body: body))
        }
        let raw = dict["cuely.library"]
        let json = (raw as? Data) ?? (raw as? String).map { Data($0.utf8) }
        if let json, let list = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] {
            for entry in list {
                add(entry["title"] as? String ?? "", entry["body"] as? String ?? "")
            }
        }
        if found.isEmpty, let single = dict["cuely.script"] as? String {
            add(fallbackTitle, single)
        }
        return found
    }

    /// Runs `/usr/bin/defaults export dev.notchy.app -` and returns its output, or nil when
    /// Notchy has no settings. Blocks for a moment: call it off the main thread.
    nonisolated static func exportDefaults() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["export", domain, "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            PrompterLog.logger.error("defaults export failed to run: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // A stuck `defaults` must not hold the queue forever.
        let timeout = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}
