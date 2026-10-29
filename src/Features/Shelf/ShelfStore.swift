import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import os

enum ShelfLog {
    static let logger = Logger(subsystem: "local.dynamicnotch", category: "shelf")
}

/// One file on the shelf: a reference by path, never a copy. The bookmark finds the file
/// again after a rename or move; shelf.json files from before it decode without one.
struct ShelfItem: Codable, Equatable, Identifiable {
    var path: String
    var added: Date
    var bookmark: Data? = nil

    var id: String { path }
    /// Built from the path alone, without asking the disk whether it's a folder.
    var url: URL { URL(filePath: path, directoryHint: .inferFromPath) }
    var name: String { (path as NSString).lastPathComponent }
}

/// Which tiles are selected. Actions work on the selection, or on every item when nothing
/// is selected.
struct ShelfSelection: Equatable {
    private(set) var ids: Set<String> = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    mutating func toggle(_ id: String) {
        if ids.remove(id) == nil { ids.insert(id) }
    }

    mutating func selectAll(_ items: [ShelfItem]) { ids = Set(items.map(\.id)) }
    mutating func clear() { ids = [] }

    /// Forgets ids that are no longer on the shelf.
    mutating func retain(_ items: [ShelfItem]) { ids.formIntersection(items.map(\.id)) }

    /// Selected files that moved (old id to new id) stay selected under their new paths.
    mutating func follow(_ moves: [String: String]) {
        if !moves.isEmpty { ids = Set(ids.map { moves[$0] ?? $0 }) }
    }

    /// The items an action works on, in shelf order.
    func targets(in items: [ShelfItem]) -> [ShelfItem] {
        ids.isEmpty ? items : items.filter { ids.contains($0.id) }
    }
}

/// Where a renamed or moved file is now, with its bookmark (a fresh one if the old went stale).
struct ShelfMove: Equatable {
    var path: String
    var bookmark: Data?
}

/// What a scan found: files gone for good, files on a drive that isn't connected, and
/// files that moved, by their old id.
typealias ShelfScan = (missing: Set<String>, offline: Set<String>, moved: [String: ShelfMove])

/// The shelf's files, selection, icons and previews. Saves shelf.json after every change;
/// existence checks and file IO run on a background queue.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem]
    @Published private(set) var selection = ShelfSelection()
    /// Files on a drive that isn't connected: kept, and shown dimmed.
    @Published private(set) var offline: Set<String> = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    /// A file drag is on its way to the notch (set by the drag monitor), so the whole open
    /// panel takes the drop.
    @Published var dragInProgress = false
    /// Counts drops onto the Shelf, so the drag monitor can tell whether a drag landed here.
    private(set) var dropCount = 0

    private let file: JSONFile<[ShelfItem]>?
    private let live: Bool
    private let io = DispatchQueue(label: "local.dynamicnotch.shelf", qos: .utility)
    private var icons: [String: NSImage] = [:]
    private var thumbnailsAsked: Set<String> = []
    private var loaded: Bool
    /// How long a file stays after it's added; nil keeps it until removed. Set by the
    /// feature from `shelfKeepHours`.
    var keepFor: TimeInterval?

    /// `fileURL` nil keeps everything in memory (self-test, snapshots). `live` false skips
    /// the disk for icons, previews and existence checks.
    init(fileURL: URL?, live: Bool = true, items: [ShelfItem] = []) {
        file = fileURL.map { JSONFile(url: $0) }
        self.live = live
        self.items = items
        loaded = fileURL == nil
    }

    // MARK: Loading and saving

    /// Reads shelf.json, follows files that moved and prunes files that are gone. Files added
    /// before it finishes stay first; nothing is written until then, so an early add can't
    /// overwrite the file. Files saved before bookmarks existed get one here.
    func load() {
        guard let file, !loaded else { return }
        io.async { [weak self] in
            let saved = file.load() ?? []
            let scan = ShelfStore.scan(saved, exists: ShelfStore.fileExists, resolve: ShelfStore.resolveBookmark)
            let made = ShelfStore.makeBookmarks(for: saved)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishLoad(saved: saved, scan: scan, bookmarks: made) }
            }
        }
    }

    private func finishLoad(saved: [ShelfItem], scan: ShelfScan, bookmarks: [String: Data]) {
        loaded = true
        let kept = Self.moving(saved.filter { !scan.missing.contains($0.id) }, scan.moved)
        items = Self.storing(bookmarks, in: Self.merged(items + kept))
        offline = scan.offline
        selection.retain(items)
        if !scan.missing.isEmpty { ShelfLog.logger.info("pruned \(scan.missing.count) missing file(s)") }
        if !scan.moved.isEmpty { ShelfLog.logger.info("followed \(scan.moved.count) moved file(s)") }
        if items != saved { save() }
        removeExpired()
    }

    private func save() {
        guard let file, loaded else { return }
        let snapshot = items
        io.async { file.save(snapshot) }
    }

    /// Waits for pending writes; called at quit.
    func flush() { io.sync {} }

    /// Follows files renamed or moved since they were added, and drops files deleted or put
    /// in the Trash. Runs whenever the Shelf tab shows.
    func pruneMissing() {
        guard live, loaded, !items.isEmpty else { return }
        let snapshot = items
        io.async { [weak self] in
            let scan = ShelfStore.scan(snapshot, exists: ShelfStore.fileExists, resolve: ShelfStore.resolveBookmark)
            let made = ShelfStore.makeBookmarks(for: snapshot)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.offline != scan.offline { self.offline = scan.offline }
                    self.apply(moved: scan.moved, bookmarks: made)
                    if !scan.missing.isEmpty {
                        ShelfLog.logger.info("pruned \(scan.missing.count) missing file(s)")
                        self.remove(scan.missing)
                    }
                }
            }
        }
    }

    // MARK: Changing the shelf

    /// Adds file URLs (anything else is ignored). Returns how many were new.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        let next = Self.adding(urls.compactMap(Self.pathURL), to: items, now: Date())
        let added = next.count - items.count
        guard added > 0 else { return 0 }
        items = next
        save()
        bookmarkSoon(Array(next.prefix(added)))
        ShelfLog.logger.info("added \(added) file(s)")
        return added
    }

    /// Makes bookmarks for newly added files on the IO queue, then stores them on the ones
    /// still on the shelf by then.
    private func bookmarkSoon(_ fresh: [ShelfItem]) {
        guard live else { return }
        io.async { [weak self] in
            let made = ShelfStore.makeBookmarks(for: fresh)
            guard !made.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(moved: [:], bookmarks: made) }
            }
        }
    }

    /// Points files that moved at their new paths and stores new bookmarks. An item's id is
    /// its path, so a moved file's selection follows it and its icon and preview are made
    /// again; one already on the shelf under the new path (dropped again after the rename)
    /// keeps its place, and the old entry goes.
    private func apply(moved: [String: ShelfMove], bookmarks: [String: Data]) {
        let next = Self.storing(bookmarks, in: Self.moving(items, moved))
        guard next != items else { return }
        let present = Set(items.map(\.id))
        let gone = Set(moved.keys.filter(present.contains))
        selection.follow(moved.filter { gone.contains($0.key) }.mapValues(\.path))
        for old in gone {
            icons[old] = nil
            thumbnailsAsked.remove(old)
        }
        if thumbnails.keys.contains(where: gone.contains) { thumbnails = thumbnails.filter { !gone.contains($0.key) } }
        if !offline.isDisjoint(with: gone) { offline.subtract(gone) }
        items = next
        selection.retain(items)
        if !gone.isEmpty { ShelfLog.logger.info("followed \(gone.count) moved file(s)") }
        save()
    }

    /// Adds the files in a drop as their URLs load. False when the drop carries no files.
    func addDropped(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        dropCount += 1
        let box = ShelfDropBox(count: files.count)
        let group = DispatchGroup()
        for (i, provider) in files.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { box.urls[i] = url }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated { _ = self?.add(box.urls.compactMap { $0 }) }
        }
        return true
    }

    func remove(_ ids: Set<String>) {
        guard items.contains(where: { ids.contains($0.id) }) else { return }
        items.removeAll { ids.contains($0.id) }
        for id in ids {
            icons[id] = nil
            thumbnailsAsked.remove(id)
        }
        if thumbnails.keys.contains(where: ids.contains) { thumbnails = thumbnails.filter { !ids.contains($0.key) } }
        if !offline.isDisjoint(with: ids) { offline.subtract(ids) }
        selection.retain(items)
        save()
    }

    func clear() { remove(Set(items.map(\.id))) }

    /// Takes files off the shelf once they've been on it for `keepFor`. Only off the shelf:
    /// it holds references, so the files themselves stay where they are.
    func removeExpired(now: Date = Date()) {
        guard loaded, let keepFor else { return }
        let old = Self.expired(items, keepFor: keepFor, now: now)
        guard !old.isEmpty else { return }
        ShelfLog.logger.info("cleared \(old.count) file(s) after \(Int(keepFor / 3600)) h")
        remove(old)
    }

    // MARK: Selection

    func toggle(_ id: String) { selection.toggle(id) }
    func selectAll() { selection.selectAll(items) }
    func deselectAll() { if !selection.isEmpty { selection.clear() } }

    /// What the header's actions work on: the selection, or everything.
    var targets: [ShelfItem] { selection.targets(in: items) }

    /// What AirDrop, Copy and Show in Finder work on: the targets, without files on a drive
    /// that isn't connected. Remove and Clear still take those.
    var actionable: [ShelfItem] { targets.filter { !offline.contains($0.id) } }

    // MARK: Icons and previews

    /// The Finder icon, cached. Snapshots use the icon for the file's type instead.
    func icon(for item: ShelfItem) -> NSImage {
        if let cached = icons[item.id] { return cached }
        let image: NSImage
        if live {
            image = NSWorkspace.shared.icon(forFile: item.path)
        } else {
            let ext = (item.path as NSString).pathExtension
            image = NSWorkspace.shared.icon(for: ext.isEmpty ? .folder : UTType(filenameExtension: ext) ?? .data)
        }
        icons[item.id] = image
        return image
    }

    /// Asks Quick Look once per file for a preview (images, PDFs, movies). The icon shows
    /// until it's ready, and stays for files that have none.
    func requestThumbnail(for item: ShelfItem) {
        guard live, !thumbnailsAsked.contains(item.id), !offline.contains(item.id) else { return }
        thumbnailsAsked.insert(item.id)
        let id = item.id
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 40, height: 40),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.items.contains(where: { $0.id == id }) else { return }
                    self.thumbnails[id] = image
                }
            }
        }
    }

    // MARK: Pure helpers (self-tested)

    /// New files go first, in the order given; a file already on the shelf keeps its place,
    /// however its path was spelled. Only file URLs count.
    nonisolated static func adding(_ urls: [URL], to items: [ShelfItem], now: Date) -> [ShelfItem] {
        var seen = Set(items.map(\.id))
        var fresh: [ShelfItem] = []
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            fresh.append(ShelfItem(path: path, added: now))
        }
        return fresh + items
    }

    /// Files added `keepFor` or longer ago.
    nonisolated static func expired(_ items: [ShelfItem], keepFor: TimeInterval, now: Date) -> Set<String> {
        Set(items.filter { now.timeIntervalSince($0.added) >= keepFor }.map(\.id))
    }

    /// `shelfKeepHours` as a duration; 0 (or less) keeps files until removed.
    nonisolated static func keepFor(hours: Double) -> TimeInterval? {
        hours > 0 ? hours * 3600 : nil
    }

    /// The path URL for a file reference URL (file:///.file/id=…, which Finder drags can
    /// carry), nil if it no longer resolves; any other URL unchanged. Asks the disk only for
    /// reference URLs.
    nonisolated static func pathURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/.file/id=") || (url as NSURL).isFileReferenceURL() else { return url }
        return (url as NSURL).filePathURL
    }

    /// Sorts the files that aren't there into offline (on a drive under /Volumes that isn't
    /// mounted, so they come back when it is), moved (`resolve` found them elsewhere) and
    /// missing (pruned). Offline comes first, so a disconnected drive never looks deleted.
    /// Files the disk won't answer for (`exists` nil) are none of these.
    nonisolated static func scan(_ items: [ShelfItem], exists: (String) -> Bool?,
                                 resolve: (ShelfItem) -> ShelfMove? = { _ in nil }) -> ShelfScan {
        var missing = Set<String>(), offline = Set<String>(), moved: [String: ShelfMove] = [:]
        for item in items where exists(item.path) == false {
            if let volume = volumeRoot(item.path), exists(volume) != true {
                offline.insert(item.id)
            } else if let move = resolve(item) {
                moved[item.id] = move
            } else {
                missing.insert(item.id)
            }
        }
        return (missing, offline, moved)
    }

    /// Items with their moved paths. One whose new path is already on the shelf merges into
    /// that one.
    nonisolated static func moving(_ items: [ShelfItem], _ moved: [String: ShelfMove]) -> [ShelfItem] {
        guard !moved.isEmpty else { return items }
        return merged(items.map { item in
            guard let move = moved[item.id] else { return item }
            var item = item
            item.path = move.path
            item.bookmark = move.bookmark ?? item.bookmark
            return item
        })
    }

    /// One item per path: the first keeps its place, and a bookmark it lacks from a later one.
    nonisolated static func merged(_ items: [ShelfItem]) -> [ShelfItem] {
        var result: [ShelfItem] = [], index: [String: Int] = [:]
        for item in items {
            if let i = index[item.id] {
                if result[i].bookmark == nil { result[i].bookmark = item.bookmark }
            } else {
                index[item.id] = result.count
                result.append(item)
            }
        }
        return result
    }

    /// Gives items that have no bookmark the one made for their path.
    nonisolated static func storing(_ bookmarks: [String: Data], in items: [ShelfItem]) -> [ShelfItem] {
        guard !bookmarks.isEmpty else { return items }
        return items.map { item in
            guard item.bookmark == nil, let data = bookmarks[item.id] else { return item }
            var item = item
            item.bookmark = data
            return item
        }
    }

    /// Bookmarks for the items that have none and are at their path. Runs on the IO queue.
    nonisolated static func makeBookmarks(for items: [ShelfItem]) -> [String: Data] {
        var made: [String: Data] = [:]
        for item in items where item.bookmark == nil && fileExists(item.path) == true {
            made[item.id] = try? item.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        return made
    }

    /// Where a file that isn't at its path went, from its bookmark (a fresh one when it went
    /// stale). Nil when it has none, it no longer resolves, or the file is in the Trash:
    /// deleting in Finder is a move there. Never mounts a drive or shows UI.
    nonisolated static func resolveBookmark(_ item: ShelfItem) -> ShelfMove? {
        guard let data = item.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let path = url.standardizedFileURL.path
        guard !path.isEmpty, path != item.path, !inTrash(url) else { return nil }
        var fresh: Data?
        if stale { fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        return ShelfMove(path: path, bookmark: fresh ?? data)
    }

    /// Whether a file is in a Trash: the home folder's, a drive's or iCloud Drive's.
    nonisolated static func inTrash(_ url: URL) -> Bool {
        let parts = url.pathComponents
        if parts.contains(".Trash") || parts.contains(".Trashes") { return true }
        // No domain lets the file manager pick the Trash on the file's own volume.
        var relation = FileManager.URLRelationship.other
        guard (try? FileManager.default.getRelationship(&relation, of: .trashDirectory, in: [], toItemAt: url)) != nil
        else { return false }
        return relation == .contains
    }

    /// "/Volumes/SSD" for a path on an external drive, nil for anything else.
    nonisolated static func volumeRoot(_ path: String) -> String? {
        let parts = (path as NSString).pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return "/Volumes/" + parts[2]
    }

    /// Whether a file is there, or nil when the disk won't say: a protected folder such as
    /// Desktop that this app may not read after a restart. Those files are kept, not pruned.
    nonisolated static func fileExists(_ path: String) -> Bool? {
        var info = stat()
        if stat(path, &info) == 0 { return true }
        let code = errno
        return code == ENOENT || code == ENOTDIR ? false : nil
    }
}

/// Holds a drop's URLs in drop order while their providers load.
@MainActor
private final class ShelfDropBox {
    var urls: [URL?]
    init(count: Int) { urls = Array(repeating: nil, count: count) }
}
