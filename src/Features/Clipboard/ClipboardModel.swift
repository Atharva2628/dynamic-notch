import AppKit
import CryptoKit
import os
import SwiftUI

enum ClipboardLog {
    static let logger = Logger(subsystem: "local.dynamicnotch", category: "clipboard")
}

/// What a history entry holds; decides its icon and how it's copied back.
enum ClipboardKind: String, Codable, Sendable {
    case text, link, files, image, color

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .files: "doc.fill"
        case .image: "photo"
        case .color: "paintpalette.fill"
        }
    }
}

/// An sRGB color, 0...1 per channel.
struct ClipboardRGBA: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    /// "#RRGGBB", or "#RRGGBBAA" when not opaque.
    var hex: String {
        func byte(_ v: Double) -> String { String(format: "%02X", Self.byte(v)) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }

    /// A channel as 0...255. Out-of-range or non-finite values (a hand-edited file) are
    /// clamped instead of crashing the conversion.
    static func byte(_ v: Double) -> Int { v.isFinite ? Int((min(max(v, 0), 1) * 255).rounded()) : 0 }

    /// "#123" is more likely an issue or PR number than a color, so copied text like it
    /// stays text. Codes with a letter ("#f80") or one repeated digit ("#333") are colors.
    static func isIssueNumber(_ text: String) -> Bool {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst()
        return digits.count == 3 && digits.allSatisfy { $0.isASCII && $0.isNumber } && Set(digits).count > 1
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    /// Parses "#RGB", "#RRGGBB" or "#RRGGBBAA". The # is required, so a copied 6-digit
    /// code is never taken for a color.
    static func parse(hex text: String) -> ClipboardRGBA? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("#") else { return nil }
        var digits = String(s.dropFirst())
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let v = hasAlpha ? value : (value << 8) | 0xFF
        return ClipboardRGBA(red: Double((v >> 24) & 0xFF) / 255, green: Double((v >> 16) & 0xFF) / 255,
                             blue: Double((v >> 8) & 0xFF) / 255, alpha: Double(v & 0xFF) / 255)
    }
}

/// One entry in the history.
struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var kind: ClipboardKind
    /// The text; a link's URL; files' paths, one per line; a color's text ("#FF9F0A");
    /// an image's description ("Image 1470 × 956").
    var text: String
    var paths: [String]? = nil
    var color: ClipboardRGBA? = nil
    var imageFile: String? = nil         // PNG in clipboard-images/
    var thumbnail: Data? = nil           // small PNG for the list
    var source: String? = nil            // the app it was copied in
    var fingerprint: String              // same content, same fingerprint
    var copiedAt = Date()
    var pinned = false

    /// SHA-256 of the kind and content, so the same copy is recognized again.
    static func fingerprint(_ kind: ClipboardKind, _ content: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: content)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func make(_ kind: ClipboardKind, text: String, source: String? = nil) -> ClipboardItem {
        ClipboardItem(kind: kind, text: text, source: source, fingerprint: fingerprint(kind, Data(text.utf8)))
    }

    /// The file names, for files.
    var fileNames: [String] { (paths ?? []).map { ($0 as NSString).lastPathComponent } }

    /// One line for the list: whitespace collapsed, at most 300 characters.
    var previewLine: String {
        switch kind {
        case .files:
            let names = fileNames
            guard let first = names.first else { return "Files" }
            return names.count == 1 ? first : "\(first) and \(names.count - 1) more"
        default:
            let collapsed = text.prefix(2000).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return String(collapsed.prefix(300))
        }
    }

    /// What search looks at: the start of long text, so typing stays quick.
    var searchText: String {
        [String(text.prefix(20_000)), fileNames.joined(separator: " "), source ?? ""].joined(separator: "\n")
    }
}

/// The saved file. Entries that don't decode are dropped one by one, so a single bad
/// entry never costs the whole history.
struct ClipboardArchive: Codable {
    var version = 1
    var items: [ClipboardItem] = []

    init(items: [ClipboardItem]) { self.items = items }

    private enum CodingKeys: String, CodingKey { case version, items }
    /// Decodes, and so steps over, any JSON value (an object, a number, a string).
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        guard var list = try? c.nestedUnkeyedContainer(forKey: .items) else { return }
        while !list.isAtEnd {
            if let item = try? list.decode(ClipboardItem.self) {
                items.append(item)
            } else if (try? list.decode(Skip.self)) == nil {
                break
            }
        }
    }
}

/// The history: newest first, one entry per content, trimmed to the limit (pins don't
/// count). Saved as JSON a moment after each change; image files of dropped entries are
/// deleted. File work runs on `io`, a serial queue shared with image capture.
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    let fileURL: URL
    let imagesDirectory: URL
    let io = DispatchQueue(label: "local.dynamicnotch.clipboard", qos: .utility)
    var limit: Int { didSet { if limit != oldValue { trim(); changed() } } }
    /// Off in tests and snapshots: nothing is written unless `flush()` is called.
    var autosave = true
    var saveDelay: TimeInterval = 1

    private var saveWork: DispatchWorkItem?
    /// Nothing is written before the saved history is back, so an early quit can't erase it.
    private(set) var isLoaded = false

    init(fileURL: URL, imagesDirectory: URL, limit: Int) {
        self.fileURL = fileURL
        self.imagesDirectory = imagesDirectory
        self.limit = max(1, limit)
    }

    var fingerprints: Set<String> { Set(items.map(\.fingerprint)) }

    func item(id: UUID) -> ClipboardItem? { items.first { $0.id == id } }

    /// Adds a capture, or moves the entry with the same content to the top (keeping its
    /// pin). Returns the entry now on top.
    @discardableResult
    func add(_ item: ClipboardItem) -> ClipboardItem {
        if let i = items.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            var existing = items.remove(at: i)
            existing.copiedAt = item.copiedAt
            if let source = item.source { existing.source = source }
            if existing.thumbnail == nil { existing.thumbnail = item.thumbnail }
            if let file = item.imageFile, file != existing.imageFile {
                if existing.imageFile == nil { existing.imageFile = file } else { deleteFiles([file]) }
            }
            items.insert(existing, at: 0)
            changed()
            return existing
        }
        items.insert(item, at: 0)
        trim()
        changed()
        return item
    }

    /// Moves an entry to the top after it was copied back.
    func touch(id: UUID, at date: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: i)
        item.copiedAt = date
        items.insert(item, at: 0)
        changed()
    }

    func remove(id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: i)
        deleteFiles([item.imageFile].compactMap { $0 })
        changed()
    }

    /// Unpinning can push the oldest entry over the limit.
    func togglePin(id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        trim()
        changed()
    }

    /// Clears the history but keeps pinned entries. Also deletes a history set aside as
    /// unreadable, so cleared text doesn't live on there.
    func clearUnpinned() {
        let broken = Self.brokenURLs(fileURL: fileURL, imagesDirectory: imagesDirectory)
        io.async {
            try? FileManager.default.removeItem(at: broken.file)
            try? FileManager.default.removeItem(at: broken.images)
        }
        let dropped = items.filter { !$0.pinned }
        guard !dropped.isEmpty else { return }
        items.removeAll { !$0.pinned }
        deleteFiles(dropped.compactMap(\.imageFile))
        changed()
    }

    /// Puts saved entries under anything captured since launch, dropping repeats.
    func restore(_ saved: [ClipboardItem]) {
        isLoaded = true
        var seen = fingerprints
        var merged = items
        for item in saved where !seen.contains(item.fingerprint) {
            seen.insert(item.fingerprint)
            merged.append(item)
        }
        items = merged
        if trim() { changed() }
    }

    /// Keeps every pinned entry and the newest `limit` others.
    nonisolated static func trimmed(_ items: [ClipboardItem], limit: Int) -> (kept: [ClipboardItem], dropped: [ClipboardItem]) {
        var kept: [ClipboardItem] = []
        var dropped: [ClipboardItem] = []
        var unpinned = 0
        for item in items {
            if item.pinned {
                kept.append(item)
            } else if unpinned < limit {
                unpinned += 1
                kept.append(item)
            } else {
                dropped.append(item)
            }
        }
        return (kept, dropped)
    }

    /// Returns whether anything was dropped.
    @discardableResult
    private func trim() -> Bool {
        let (kept, dropped) = Self.trimmed(items, limit: limit)
        guard !dropped.isEmpty else { return false }
        items = kept
        deleteFiles(dropped.compactMap(\.imageFile))
        return true
    }

    /// Every word of the query must appear (ignoring case and accents) in the text, the
    /// file names or the app it was copied in.
    nonisolated static func filter(_ items: [ClipboardItem], query: String, pinnedOnly: Bool) -> [ClipboardItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            if pinnedOnly && !item.pinned { return false }
            guard !words.isEmpty else { return true }
            let haystack = item.searchText
            return words.allSatisfy { haystack.localizedStandardContains($0) }
        }
    }

    /// The image file, if the saved name is a plain file name (never a path out of the folder).
    func imageURL(for item: ClipboardItem) -> URL? {
        guard let name = item.imageFile, Self.isPlainFileName(name) else { return nil }
        return imagesDirectory.appendingPathComponent(name)
    }

    nonisolated static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
    }

    private func deleteFiles(_ names: [String]) {
        let urls = names.filter(Self.isPlainFileName).map { imagesDirectory.appendingPathComponent($0) }
        guard !urls.isEmpty else { return }
        io.async {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Saving

    private func changed() {
        guard autosave else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.write(wait: false) }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// Writes now and waits for it (quit, tests).
    func flush() { write(wait: true) }

    /// Waits for queued file work (image writes and deletes) to finish.
    func drainIO() { io.sync {} }

    private func write(wait: Bool) {
        saveWork?.cancel()
        saveWork = nil
        guard isLoaded else { return }
        let file = JSONFile<ClipboardArchive>(url: fileURL)
        let archive = ClipboardArchive(items: items)
        if wait { io.sync { file.save(archive) } } else { io.async { file.save(archive) } }
    }

    /// Where an unreadable history and its images are set aside: clipboard.json.broken and
    /// clipboard-images.broken/, next to the originals.
    nonisolated static func brokenURLs(fileURL: URL, imagesDirectory: URL) -> (file: URL, images: URL) {
        (fileURL.appendingPathExtension("broken"),
         imagesDirectory.deletingLastPathComponent()
            .appendingPathComponent(imagesDirectory.lastPathComponent + ".broken", isDirectory: true))
    }

    /// Reads the saved history (call on `io`). A file that exists but doesn't decode is set
    /// aside with the images folder, as one pair that can still be recovered (replacing an
    /// earlier pair), instead of being overwritten later. Otherwise image files no entry
    /// refers to are deleted.
    nonisolated static func loadSaved(fileURL: URL, imagesDirectory: URL) -> [ClipboardItem] {
        let fm = FileManager.default
        var items: [ClipboardItem] = []
        if fm.fileExists(atPath: fileURL.path) {
            if let archive = JSONFile<ClipboardArchive>(url: fileURL).load() {
                items = archive.items
            } else {
                // Image capture makes the folder again before it writes.
                let broken = brokenURLs(fileURL: fileURL, imagesDirectory: imagesDirectory)
                try? fm.removeItem(at: broken.file)
                try? fm.moveItem(at: fileURL, to: broken.file)
                try? fm.removeItem(at: broken.images)
                try? fm.moveItem(at: imagesDirectory, to: broken.images)
                ClipboardLog.logger.error("clipboard.json is unreadable; moved aside with its images")
                return []
            }
        }
        let referenced = Set(items.compactMap(\.imageFile))
        if let names = try? fm.contentsOfDirectory(atPath: imagesDirectory.path) {
            for name in names where name.hasSuffix(".png") && !referenced.contains(name) {
                try? fm.removeItem(at: imagesDirectory.appendingPathComponent(name))
            }
        }
        return items
    }
}
