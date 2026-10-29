import CoreServices
import Foundation

/// Tells the Drafts feature when a Markdown file under its folders changes (or skim's list
/// of folders does), through FSEvents: the kernel batches changes, so watching costs nothing
/// while files sit still. Events arrive on a private queue, at most every 2 s. Use it from
/// the main thread.
final class DraftsWatcher {
    private let queue = DispatchQueue(label: "local.dynamicnotch.drafts.events", qos: .utility)
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    private(set) var paths: [String] = []

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    /// The folders to watch for these roots: each folder, the folder of each single-file
    /// root, and skim's state folder when given. Checks the disk: call it off the main thread.
    static func folders(for roots: [String], skimState: String?) -> [String] {
        var folders = roots.map { root -> String in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory)
            return isDirectory.boolValue ? root : (root as NSString).deletingLastPathComponent
        }
        if let skimState { folders.append(skimState) }
        return Array(Set(folders)).sorted()
    }

    /// Watches `folders` (from `folders(for:skimState:)`), where `skimState` is skim's state
    /// folder if it's one of them. Replaces any earlier watch.
    func watch(_ folders: [String], skimState: String?) {
        stop()
        paths = folders
        guard !folders.isEmpty else { return }

        // The stream owns this filter (released with the stream), so a callback still running
        // on the queue never sees a half-changed watcher.
        let filter = Filter(skimState: skimState, onChange: onChange)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(filter).toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<Filter>.fromOpaque(info).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let filter = Unmanaged<Filter>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            if (list as? [String] ?? []).prefix(count).contains(where: filter.matters) { filter.onChange() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagIgnoreSelf)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, folders as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else {
            if let info = context.info { Unmanaged<Filter>.fromOpaque(info).release() }
            DraftsFeature.log.error("could not watch the drafts folders")
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    /// Which changed paths count: a Markdown file outside node_modules and skim's own
    /// history, or skim's folder list.
    static func matters(_ path: String, skimState: String?) -> Bool {
        if let skimState {
            if path == skimState + "/roots.json" { return true }
            if path.hasPrefix(skimState + "/") { return false }
        }
        return path.lowercased().hasSuffix(".md") && !path.contains("/node_modules/")
    }

    private final class Filter: @unchecked Sendable {
        let skimState: String?
        let onChange: @Sendable () -> Void

        init(skimState: String?, onChange: @escaping @Sendable () -> Void) {
            self.skimState = skimState
            self.onChange = onChange
        }

        func matters(_ path: String) -> Bool { DraftsWatcher.matters(path, skimState: skimState) }
    }
}
