import AppKit
import Combine
import CoreServices

/// One script file in the prompter folder.
struct PrompterScript: Identifiable, Equatable {
    var id: String { fileName }
    var fileName: String
    var url: URL
    var title: String
    var display: String          // the text as the prompter shows it (see PrompterText.display)
    var words: Int
    var modified: Date

    init(url: URL, source: String, modified: Date) {
        self.url = url
        fileName = url.lastPathComponent
        title = url.deletingPathExtension().lastPathComponent
        display = PrompterText.display(source)
        words = PrompterText.wordCount(display)
        self.modified = modified
    }
}

/// What the prompter remembers between launches.
struct PrompterSavedState: Codable, Equatable {
    var selected: String?            // file name of the selected script
    var notchyChecked = false        // the first-start import from Notchy has run
}

/// Scripts already read, by path, so a reload reads again only the files whose date or size
/// changed. Used only on the library's io queue (and by a self-test's own scans).
final class PrompterScanCache: @unchecked Sendable {
    struct Entry {
        var modified: Date
        var size: Int
        var script: PrompterScript
    }
    var entries: [String: Entry] = [:]
}

/// The scripts in the prompter folder. Reads and writes files on its own queue; the list
/// and selection live on the main thread. Watches the folder, so files added, renamed or
/// saved by an editor (in place or by replacing them) show up without reopening the tab.
@MainActor
final class PrompterLibrary: ObservableObject {
    @Published private(set) var scripts: [PrompterScript] = []
    @Published private(set) var loaded = false
    @Published var selectedID: String? {
        didSet { if selectedID != oldValue { saveState() } }
    }
    private(set) var folder: URL
    let io = DispatchQueue(label: "local.dynamicnotch.prompter", qos: .utility)

    nonisolated static let extensions: Set<String> = ["md", "markdown", "txt"]
    nonisolated private static let maxFiles = 500
    nonisolated private static let maxBytes = 2_000_000

    private let stateFile: JSONFile<PrompterSavedState>?
    private let cache = PrompterScanCache()
    private var state = PrompterSavedState()
    private var watcher: PrompterFolderWatch?
    private var wantsWatch = false               // watching until stopWatching()
    private var reloadWork: DispatchWorkItem?

    init(folder: URL, stateURL: URL?) {
        self.folder = folder
        stateFile = stateURL.map { JSONFile(url: $0) }
    }

    /// For snapshots: fixed scripts, no files.
    init(sample: [PrompterScript], selected: String?) {
        folder = URL(fileURLWithPath: "/tmp/Prompter", isDirectory: true)
        stateFile = nil
        scripts = sample
        selectedID = selected
        loaded = true
    }

    /// The selected script, or the first one when the selection is gone.
    var selected: PrompterScript? { scripts.first { $0.id == selectedID } ?? scripts.first }

    func select(_ script: PrompterScript) { selectedID = script.id }

    /// Moves the selection `delta` rows, stopping at either end.
    func moveSelection(_ delta: Int) {
        guard !scripts.isEmpty else { return }
        let i = selected.flatMap { s in scripts.firstIndex { $0.id == s.id } } ?? 0
        selectedID = scripts[min(max(i + delta, 0), scripts.count - 1)].id
    }

    // MARK: Loading

    /// First load: reads the saved state and the folder, and when the folder has no scripts
    /// and Notchy was never checked, imports Notchy's. Then watches the folder.
    func loadInitial() {
        let folder = folder, stateFile = stateFile, cache = cache
        io.async { [weak self] in
            Self.ensureFolder(folder)
            var saved = stateFile?.load() ?? PrompterSavedState()
            var scripts = Self.scan(folder, cache: cache)
            if scripts.isEmpty && !saved.notchyChecked {
                let found = PrompterNotchy.exportDefaults().map(PrompterNotchy.scripts(fromPlist:)) ?? []
                let written = Self.write(found, to: folder)
                PrompterLog.logger.info("first start: imported \(written) of \(found.count) Notchy scripts")
                saved.notchyChecked = true
                stateFile?.save(saved)
                if written > 0 { scripts = Self.scan(folder, cache: cache) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state = saved
                    self.apply(scripts, folder: folder)
                    if self.selectedID == nil { self.selectedID = saved.selected }
                    self.watch()
                }
            }
        }
    }

    /// Reads the folder again; `then` runs on the main thread with the fresh list.
    func reload(then: (([PrompterScript]) -> Void)? = nil) {
        reloadWork?.cancel()
        reloadWork = nil
        let folder = folder, cache = cache
        io.async { [weak self] in
            let scripts = Self.scan(folder, cache: cache)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apply(scripts, folder: folder)
                    // The watch couldn't start before: try again.
                    if self.wantsWatch, self.watcher == nil, folder == self.folder { self.watch() }
                    then?(self.scripts)
                }
            }
        }
    }

    /// Switches to another folder (the setting changed). Compares paths, not URLs: the same
    /// folder gains a trailing slash once it exists, which would make every settings save
    /// look like a switch.
    func setFolder(_ url: URL) {
        guard !Self.samePath(url, folder) else { return }
        folder = url
        scripts = []
        stopWatching()
        io.async { Self.ensureFolder(url) }
        reload { [weak self] _ in self?.watch() }
    }

    nonisolated static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    private func apply(_ list: [PrompterScript], folder: URL) {
        guard folder == self.folder else { return }      // the folder changed meanwhile
        if list != scripts { scripts = list }
        loaded = true
    }

    /// The newest 500 scripts in `folder`, newest first. Skips hidden files, other types,
    /// files over 2 MB and files it can't read. Lists and sorts before reading, so the cap
    /// keeps the newest; with `cache`, reads only files that changed since the last scan.
    nonisolated static func scan(_ folder: URL, cache: PrompterScanCache? = nil) -> [PrompterScript] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        var files: [(url: URL, title: String, modified: Date, size: Int)] = []
        for url in urls where extensions.contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  (values.fileSize ?? 0) <= maxBytes else { continue }
            files.append((url, url.deletingPathExtension().lastPathComponent,
                          values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
        }
        files.sort { a, b in
            a.modified != b.modified ? a.modified > b.modified
                : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        var scripts: [PrompterScript] = []
        var kept: [String: PrompterScanCache.Entry] = [:]
        for file in files {
            let key = file.url.standardizedFileURL.path
            let script: PrompterScript
            if let hit = cache?.entries[key], hit.modified == file.modified, hit.size == file.size {
                script = hit.script
            } else if let source = read(file.url) {
                script = PrompterScript(url: file.url, source: source, modified: file.modified)
            } else {
                continue
            }
            kept[key] = PrompterScanCache.Entry(modified: file.modified, size: file.size, script: script)
            scripts.append(script)
            if scripts.count >= maxFiles { break }
        }
        cache?.entries = kept                    // drops files that are gone or no longer listed
        return scripts
    }

    /// A text file as UTF-8, or whatever encoding Foundation detects.
    nonisolated static func read(_ url: URL) -> String? {
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) { return text }
        var encoding = String.Encoding.utf8
        return try? String(contentsOf: url, usedEncoding: &encoding)
    }

    nonisolated private static func ensureFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: Writing

    /// Writes imported scripts as "<title>.md", skipping any whose text is already in the
    /// folder and numbering names that clash. Returns how many were written.
    nonisolated static func write(_ imports: [PrompterImport], to folder: URL) -> Int {
        guard !imports.isEmpty else { return 0 }
        ensureFolder(folder)
        let existing = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var taken = Set(existing.map { $0.lastPathComponent.lowercased() })
        var bodies = Set(existing.filter { extensions.contains($0.pathExtension.lowercased()) }
            .compactMap { read($0)?.trimmingCharacters(in: .whitespacesAndNewlines) })
        var written = 0
        for item in imports {
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, !bodies.contains(body) else { continue }
            let name = PrompterText.fileName(for: item.title, taken: taken)
            do {
                try Data((item.body.hasSuffix("\n") ? item.body : item.body + "\n").utf8)
                    .write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
                taken.insert(name.lowercased())
                bodies.insert(body)
                written += 1
            } catch {
                PrompterLog.logger.error("could not write \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return written
    }

    /// Creates "Untitled.md" (or "Untitled 2.md", …) with a line of starter text and
    /// selects it. `done` gets its URL, or nil if it couldn't be written.
    func createScript(done: @escaping (URL?) -> Void) {
        let folder = folder, cache = cache
        io.async { [weak self] in
            Self.ensureFolder(folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let name = PrompterText.fileName(for: "Untitled", taken: Set(names.map { $0.lowercased() }))
            let url = folder.appendingPathComponent(name)
            let starter = "Write what you want to say here. Blank lines start a new paragraph.\n"
            var ok = true
            do {
                try Data(starter.utf8).write(to: url, options: .withoutOverwriting)
            } catch {
                ok = false
                PrompterLog.logger.error("could not create a script: \(error.localizedDescription, privacy: .public)")
            }
            let scripts = Self.scan(folder, cache: cache)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apply(scripts, folder: folder)
                    if ok { self.selectedID = name }
                    done(ok ? url : nil)
                }
            }
        }
    }

    /// Imports Notchy's scripts now (the menu item). `done` gets how many were new, or nil
    /// when Notchy has no scripts.
    func importNotchy(done: @escaping (Int?) -> Void) {
        let folder = folder, cache = cache
        io.async { [weak self] in
            let found = PrompterNotchy.exportDefaults().map(PrompterNotchy.scripts(fromPlist:)) ?? []
            let written = Self.write(found, to: folder)
            let scripts = Self.scan(folder, cache: cache)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apply(scripts, folder: folder)
                    if written > 0, let newest = scripts.first { self.selectedID = newest.id }
                    done(found.isEmpty ? nil : written)
                }
            }
        }
    }

    /// The script's current text, read fresh (it may have been edited since the list was
    /// read). `done` gets nil when the file is gone.
    func freshCopy(of script: PrompterScript, done: @escaping (PrompterScript?) -> Void) {
        let url = script.url
        io.async {
            let source = Self.read(url)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    done(source.map { PrompterScript(url: url, source: $0, modified: modified ?? script.modified) })
                }
            }
        }
    }

    // MARK: State and watching

    private func saveState() {
        guard let stateFile else { return }
        state.selected = selectedID
        let snapshot = state
        io.async { stateFile.save(snapshot) }
    }

    /// File events (files added, removed, renamed, or saved in place or atomically by an
    /// editor) reload the list after a short pause. The watch follows the path, so a folder
    /// that is moved or deleted and comes back is still watched.
    private func watch() {
        cancelWatcher()
        wantsWatch = true
        watcher = PrompterFolderWatch(folder: folder) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func stopWatching() {
        wantsWatch = false
        cancelWatcher()
        reloadWork?.cancel()
        reloadWork = nil
    }

    private func cancelWatcher() {
        watcher?.cancel()
        watcher = nil
    }
}

/// An FSEvents stream on one folder with file-level events: unlike a watch on the folder
/// itself, it also sees a file rewritten in place (VS Code, `echo >>`). WatchRoot reports
/// the folder being moved, deleted or created again. Delivers on the main queue, which is
/// also where it is created and cancelled, so no callback runs after `cancel()`.
private final class PrompterFolderWatch {
    private var stream: FSEventStreamRef?
    private let changed: () -> Void

    init?(folder: URL, changed: @escaping () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<PrompterFolderWatch>.fromOpaque(info).takeUnretainedValue().changed()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    func cancel() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { cancel() }
}
