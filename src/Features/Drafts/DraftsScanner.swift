import Foundation

/// One Markdown file with open asks.
struct DraftsFile: Identifiable, Equatable {
    var path: String
    var asks: Int
    var modified: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    /// The file name without ".md".
    var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

/// What the Home card shows.
struct DraftsSummary: Equatable {
    var files: [DraftsFile] = []        // only files with asks, most asks first
    var roots: [String] = []            // folders (or single files) that were scanned
    var fromSkim = false                // roots came from skim's recent folders, not settings
    var scannedFiles = 0
    var scanned = false                 // false until the first scan finishes

    var totalAsks: Int { files.reduce(0) { $0 + $1.asks } }
}

/// Counts open `[!ASK]` callouts the way skim does: a blockquote whose first non-blank line
/// is `[!ASK]` (any case, optionally `[!ASK]-` or `[!ASK]+`). Fenced code (``` or ~~~) and
/// HTML comment blocks don't count. An ask is open while it's in the file; agents delete
/// the box once it's answered.
enum DraftsAsks {
    static func count(in text: String) -> Int {
        var count = 0
        var fence: (char: Character, length: Int)?
        var inComment = false
        var inQuote = false
        var decided = false             // the current quote's first line has been looked at

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if let open = fence {
                if closesFence(line, open) { fence = nil }
                continue
            }
            if inComment {
                if line.contains("-->") { inComment = false }
                continue
            }
            if let inner = quoteContent(line) {
                if !inQuote {
                    inQuote = true
                    decided = false
                }
                if !decided, !isBlank(inner) {
                    decided = true
                    if isAskMarker(inner) { count += 1 }
                }
                continue
            }
            inQuote = false
            if let open = opensFence(line) {
                fence = open
                continue
            }
            let lead = line.drop { $0 == " " }
            if line.count - lead.count <= 3, lead.hasPrefix("<!--"), !lead.dropFirst(4).contains("-->") {
                inComment = true
            }
        }
        return count
    }

    /// The text after `>` (and one optional space) when the line is a blockquote line.
    private static func quoteContent(_ line: Substring) -> Substring? {
        let lead = line.drop { $0 == " " }
        guard line.count - lead.count <= 3, lead.first == ">" else { return nil }
        let rest = lead.dropFirst()
        return rest.first == " " ? rest.dropFirst() : rest
    }

    private static func isAskMarker(_ s: Substring) -> Bool {
        let lead = s.drop { $0 == " " }
        guard s.count - lead.count <= 3, lead.hasPrefix("[!") else { return false }
        let body = lead.dropFirst(2)
        guard let close = body.firstIndex(of: "]") else { return false }
        return body[..<close].uppercased() == "ASK"
    }

    private static func isBlank(_ s: Substring) -> Bool { s.allSatisfy(\.isWhitespace) }

    /// ``` or ~~~ (3 or more), indented at most 3 spaces; a backtick fence's info string
    /// can't contain a backtick.
    private static func opensFence(_ line: Substring) -> (char: Character, length: Int)? {
        let lead = line.drop { $0 == " " }
        guard line.count - lead.count <= 3, let c = lead.first, c == "`" || c == "~" else { return nil }
        let run = lead.prefix { $0 == c }.count
        guard run >= 3 else { return nil }
        if c == "`", lead.dropFirst(run).contains("`") { return nil }
        return (c, run)
    }

    private static func closesFence(_ line: Substring, _ open: (char: Character, length: Int)) -> Bool {
        let lead = line.drop { $0 == " " }
        guard line.count - lead.count <= 3 else { return false }
        let run = lead.prefix { $0 == open.char }.count
        return run >= open.length && lead.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }
}

/// Finds the folders you've opened in skim, from its state in ~/.skim (read-only):
/// `roots.json` lists every folder (or file) skim was pointed at, and each `seen/*.json`
/// starts with the path of a file and when you last looked at it.
enum DraftsDiscovery {
    static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".skim", isDirectory: true)
    }

    /// roots.json: {"<path>": {"first": "<ISO date>"}, ...}. A root with no date counts as old.
    static func parseRoots(_ data: Data) -> [String: Date] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var roots: [String: Date] = [:]
        for (path, value) in json where path.hasPrefix("/") {
            let first = ((value as? [String: Any])?["first"] as? String).flatMap(date) ?? .distantPast
            roots[path] = first
        }
        return roots
    }

    private static let seenHead = try? NSRegularExpression(
        pattern: #"^\s*\{\s*"path"\s*:\s*("(?:[^"\\]|\\.)*")\s*,\s*"at"\s*:\s*"([^"]+)""#)

    /// The path and time at the start of a seen file, from its first few KB. Falls back to
    /// decoding the whole thing when the keys come in another order.
    static func parseSeen(_ data: Data) -> (path: String, at: Date)? {
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        if let m = seenHead?.firstMatch(in: text, range: range),
           let quoted = Range(m.range(at: 1), in: text), let stamp = Range(m.range(at: 2), in: text),
           let path = (try? JSONSerialization.jsonObject(with: Data(text[quoted].utf8), options: .fragmentsAllowed)) as? String,
           let at = date(String(text[stamp])) {
            return (path, at)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let path = json["path"] as? String, let at = (json["at"] as? String).flatMap(date) else { return nil }
        return (path, at)
    }

    /// Most recently used first: a root's time is when skim first opened it or when you
    /// last looked at a file inside it, whichever is later.
    static func rank(roots: [String: Date], seen: [(path: String, at: Date)]) -> [String] {
        var latest = roots
        for s in seen {
            for root in roots.keys where s.path == root || s.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
                if s.at > latest[root, default: .distantPast] { latest[root] = s.at }
            }
        }
        return latest.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Folders macOS asks about before an app may read them, lowercased. When the folders
    /// come from skim, roots inside these are skipped and walks don't go into them, so the
    /// card never triggers a permission prompt on its own.
    static func guardedPaths(home: String) -> [String] {
        ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
         "Library/Mobile Documents", "Library/CloudStorage"].map { (home + "/" + $0).lowercased() } + ["/volumes"]
    }

    /// What a walk from a skim folder doesn't go into (lowercased): the guarded folders, and
    /// ~/Library, where other apps keep their data (some of it guarded too) and drafts don't
    /// live. Only a walk from your home folder itself reaches these.
    static func walkSkips(home: String) -> Set<String> {
        Set(guardedPaths(home: home) + [(home + "/Library").lowercased()])
    }

    /// Whether a path is inside a guarded folder. Case-insensitive, like the disk:
    /// `skim ~/documents/x` is still in Documents.
    static func isProtected(_ path: String, home: String) -> Bool {
        let p = path.lowercased()
        return guardedPaths(home: home).contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// Whether your home folder is inside the path ("/", "/Users"): a walk from there would
    /// cover the whole disk or other people's folders, every couple of minutes.
    static func isAboveHome(_ path: String, home: String) -> Bool {
        let p = path.lowercased()
        return home.lowercased().hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    /// Up to `limit` folders from skim's state, newest first, that still exist and aren't
    /// protected or above your home folder. Blocking file IO.
    static func recentRoots(state: URL = stateDirectory, home: String = NSHomeDirectory(), limit: Int = 8) -> [String] {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: state.appendingPathComponent("roots.json")) else { return [] }
        let roots = parseRoots(data)
        guard !roots.isEmpty else { return [] }
        var seen: [(path: String, at: Date)] = []
        let seenDir = state.appendingPathComponent("seen", isDirectory: true)
        for url in (try? fm.contentsOfDirectory(at: seenDir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "json" {
            if let s = readSeen(url) { seen.append(s) }
        }
        // The protected check comes first: even looking up a path inside Documents can prompt.
        return Array(rank(roots: roots, seen: seen)
            .filter { !isProtected($0, home: home) && !isAboveHome($0, home: home) && fm.fileExists(atPath: $0) }
            .prefix(limit))
    }

    private static func readSeen(_ url: URL) -> (path: String, at: Date)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if let head = try? handle.read(upToCount: 4096), let s = parseSeen(head) { return s }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        return parseSeen(data)
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Walks the roots for Markdown files and counts their asks, re-reading only files whose
/// size or date changed since the last scan. Use it only on `queue`.
final class DraftsScanner: @unchecked Sendable {
    static let maxFiles = 5_000
    static let maxFileSize = 4_000_000

    let queue = DispatchQueue(label: "local.dynamicnotch.drafts", qos: .utility)
    private var cache: [String: (modified: Date, size: Int, asks: Int)] = [:]

    /// `configured` is the skimFolders setting; empty means "use skim's recent folders".
    /// Folders you set are walked in full; skim's skip the guarded folders inside them.
    func scan(configured: [String], skimState: URL = DraftsDiscovery.stateDirectory,
              home: String = NSHomeDirectory()) -> DraftsSummary {
        var summary = DraftsSummary()
        summary.fromSkim = configured.isEmpty
        summary.roots = configured.isEmpty
            ? DraftsDiscovery.recentRoots(state: skimState, home: home)
            : configured.map { Config.expand($0).standardizedFileURL.path }
        let skip = summary.fromSkim ? DraftsDiscovery.walkSkips(home: home) : []
        var visited = Set<String>()
        for root in summary.roots {
            for (url, modified, size) in Self.markdownFiles(under: URL(fileURLWithPath: root), limit: Self.maxFiles - visited.count,
                                                            skip: skip) {
                let path = url.path
                guard visited.insert(path).inserted else { continue }
                let asks: Int
                if let hit = cache[path], hit.modified == modified, hit.size == size {
                    asks = hit.asks
                } else {
                    asks = size > Self.maxFileSize ? 0 : (try? Data(contentsOf: url))
                        .map { DraftsAsks.count(in: String(decoding: $0, as: UTF8.self)) } ?? 0
                    cache[path] = (modified, size, asks)
                }
                if asks > 0 { summary.files.append(DraftsFile(path: path, asks: asks, modified: modified)) }
            }
        }
        cache = cache.filter { visited.contains($0.key) }
        summary.files.sort { $0.asks != $1.asks ? $0.asks > $1.asks : $0.modified > $1.modified }
        summary.scannedFiles = visited.count
        summary.scanned = true
        return summary
    }

    /// `.md` files under a folder (or the root itself when it's one), skipping hidden files
    /// and folders, packages, node_modules and the folders in `skip` (lowercased paths). A
    /// skipped folder is never opened: listing it is what would ask for permission.
    static func markdownFiles(under root: URL, limit: Int, skip: Set<String> = []) -> [(URL, Date, Int)] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard limit > 0, fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        func entry(_ url: URL, _ v: URLResourceValues?) -> (URL, Date, Int) {
            (url, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
        }
        guard isDirectory.boolValue else {
            guard root.pathExtension.lowercased() == "md" else { return [] }
            return [entry(root, try? root.resourceValues(forKeys: keys))]
        }
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else { return [] }
        var found: [(URL, Date, Int)] = []
        let skip = Set(skip.map(canonical))
        while let url = walker.nextObject() as? URL {
            let v = try? url.resourceValues(forKeys: keys)
            if v?.isDirectory == true {
                if url.lastPathComponent == "node_modules" || skip.contains(canonical(url.path.lowercased())) { walker.skipDescendants() }
                continue
            }
            guard v?.isRegularFile == true, url.pathExtension.lowercased() == "md" else { continue }
            found.append(entry(url, v))
            if found.count >= limit { break }
        }
        return found
    }

    /// One spelling for paths under /var, /tmp and /etc, which the walker may report as
    /// /private/var/… while the skip list says /var/… (or the other way round).
    private static func canonical(_ path: String) -> String {
        for alias in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(alias) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}
