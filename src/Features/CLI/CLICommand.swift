import Foundation

/// One `notch` command, checked. `parse` builds it from a socket message
/// ({"type":"cli","cmd":"post",...}, token already removed) and rejects anything malformed:
/// unknown commands or fields, wrong types, bad ids, numbers out of range.
enum CLICommand: Equatable {
    case post(id: String, text: String, title: String?, icon: String?, tint: ActivityTint?, seconds: Double?)
    case progress(id: String, fraction: Double, title: String?)
    case done(id: String, text: String?)
    case remove(id: String)
    case open(tab: NotchTab?)

    /// What a rejected message says, sent back as {"ok":false,"error":...}.
    struct Failure: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static let defaultID = "message"
    static let maxText = 500
    static let maxTitle = 120
    static let maxSeconds: Double = 86_400

    /// Fields each command takes, besides "type" and "cmd".
    private static let fields: [String: Set<String>] = [
        "post": ["text", "title", "icon", "tint", "for", "id"],
        "progress": ["id", "fraction", "title"],
        "done": ["id", "text"],
        "remove": ["id"],
        "open": ["tab"],
    ]

    /// `symbolExists` says whether an SF Symbol name is real (AppKit in the app, a stub in tests).
    static func parse(_ message: [String: Any], symbolExists: (String) -> Bool) -> Result<CLICommand, Failure> {
        do {
            return .success(try make(message, symbolExists: symbolExists))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(Failure("bad message"))
        }
    }

    private static func make(_ m: [String: Any], symbolExists: (String) -> Bool) throws -> CLICommand {
        guard let cmd = m["cmd"] as? String else { throw Failure("missing \"cmd\"") }
        guard let allowed = fields[cmd] else {
            throw Failure("unknown command \"\(clip(cmd))\" (post, progress, done, remove, open)")
        }
        for key in m.keys.sorted() where key != "type" && key != "cmd" && !allowed.contains(key) {
            throw Failure("\(cmd) doesn't take \"\(clip(key))\"")
        }

        switch cmd {
        case "post":
            let text = try requiredText(m, "text", max: maxText)
            let title = try optionalText(m, "title", max: maxTitle)
            let id = try optionalID(m) ?? defaultID
            var icon: String?
            if let name = try string(m, "icon") {
                guard isSymbolName(name), symbolExists(name) else { throw Failure("unknown SF Symbol \"\(clip(name))\"") }
                icon = name
            }
            var tint: ActivityTint?
            if let name = try string(m, "tint") {
                guard let t = ActivityTint(rawValue: name.lowercased()) else {
                    throw Failure("unknown tint \"\(clip(name))\" (white, green, orange, red, blue, purple, yellow)")
                }
                tint = t
            }
            var seconds: Double?
            if m["for"] != nil {
                let s = try number(m, "for")
                guard s >= 0, s <= maxSeconds else { throw Failure("--for must be 0 to \(Int(maxSeconds)) seconds") }
                seconds = s
            }
            return .post(id: id, text: text, title: title, icon: icon, tint: tint, seconds: seconds)

        case "progress":
            guard let id = try optionalID(m) else { throw Failure("progress needs an id") }
            guard m["fraction"] != nil else { throw Failure("progress needs a fraction") }
            let fraction = try number(m, "fraction", allowPercent: true)
            guard (0...1).contains(fraction) else { throw Failure("the fraction must be 0 to 1 (or 0% to 100%)") }
            return .progress(id: id, fraction: fraction, title: try optionalText(m, "title", max: maxTitle))

        case "done":
            guard let id = try optionalID(m) else { throw Failure("done needs an id") }
            return .done(id: id, text: try optionalText(m, "text", max: maxText))

        case "remove":
            guard let id = try optionalID(m) else { throw Failure("remove needs an id") }
            return .remove(id: id)

        default: // open
            guard let name = try string(m, "tab") else { return .open(tab: nil) }
            guard let tab = NotchTab(rawValue: name.lowercased()) else {
                let names = NotchTab.allCases.map(\.rawValue).joined(separator: ", ")
                throw Failure("unknown tab \"\(clip(name))\" (\(names))")
            }
            return .open(tab: tab)
        }
    }

    // MARK: Field checks

    private static func string(_ m: [String: Any], _ key: String) throws -> String? {
        guard let value = m[key] else { return nil }
        guard let s = value as? String else { throw Failure("\"\(key)\" must be a string") }
        return s
    }

    private static func requiredText(_ m: [String: Any], _ key: String, max: Int) throws -> String {
        guard let text = try optionalText(m, key, max: max) else { throw Failure("missing \"\(key)\"") }
        return text
    }

    /// One line of display text (see `oneLine`). A field that is given must have some text.
    private static func optionalText(_ m: [String: Any], _ key: String, max: Int) throws -> String? {
        guard let raw = try string(m, key) else { return nil }
        let text = oneLine(raw)
        guard !text.isEmpty else { throw Failure("\(key) is empty") }
        guard text.count <= max else { throw Failure("\(key) is longer than \(max) characters") }
        return text
    }

    private static func optionalID(_ m: [String: Any]) throws -> String? {
        guard let id = try string(m, "id") else { return nil }
        guard isID(id) else {
            throw Failure("bad id \"\(clip(id))\": use up to 64 letters, digits, dots, dashes and underscores")
        }
        return id
    }

    /// A JSON number (not true/false), or a string of digits with at most one dot, as the
    /// shell client sends. With `allowPercent`, "40%" means 0.4.
    private static func number(_ m: [String: Any], _ key: String, allowPercent: Bool = false) throws -> Double {
        let bad = Failure("\"\(key)\" must be a number")
        if let n = m[key] as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw bad }
            return n.doubleValue
        }
        guard var s = m[key] as? String else { throw bad }
        var divisor = 1.0
        if allowPercent, s.hasSuffix("%") {
            s.removeLast()
            divisor = 100
        }
        guard isDecimal(s), let value = Double(s) else { throw bad }
        return value / divisor
    }

    static func isID(_ s: String) -> Bool {
        guard (1...64).contains(s.utf8.count), let first = s.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// SF Symbol names: lowercase words joined by dots ("bell.fill", "arrow.down.circle").
    static func isSymbolName(_ s: String) -> Bool {
        guard (1...80).contains(s.utf8.count), !s.hasPrefix("."), !s.hasSuffix("."), !s.contains("..") else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." }
    }

    private static func isDecimal(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s.filter { $0 == "." }.count <= 1 && s.allSatisfy { $0 == "." || $0.isASCII && $0.isNumber }
    }

    /// The text on one line: line breaks, other control characters and runs of whitespace
    /// become one space (see `displayScalar`). Also used for Quick Capture.
    static func oneLine(_ s: String) -> String {
        let spaced = String(String.UnicodeScalarView(s.unicodeScalars.compactMap(displayScalar)))
        return spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A scalar as one line of display text shows it: control characters, line and
    /// paragraph separators (Cc, Zl, Zp) become a space, and bidi embeddings, overrides and
    /// isolates (U+202A–U+202E, U+2066–U+2069), which can make text read backwards, are
    /// dropped (nil). Other format characters stay: the zero-width joiner holds 🧑‍💻
    /// together, and tag characters make up flags like England's.
    static func displayScalar(_ s: Unicode.Scalar) -> Unicode.Scalar? {
        switch s.value {
        case 0x202A...0x202E, 0x2066...0x2069: return nil
        default: break
        }
        switch s.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return " "
        default: return s
        }
    }

    /// Echoed input in an error stays short and on one line.
    private static func clip(_ s: String) -> String {
        let line = oneLine(s)
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }
}
