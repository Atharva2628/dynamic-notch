import Foundation
import os

/// Which browser left a partial download in the folder.
enum StatusDownloadKind: Equatable {
    case chrome     // name.crdownload: Chrome, Edge, Brave, Arc
    case firefox    // name.part, beside an empty placeholder with the final name
    case safari     // name.download: a bundle holding Info.plist and the data so far
}

/// Recognizes partial downloads by name.
enum StatusDownloadFile {
    /// The browser and final name of a partial download, or nil for anything else: finished
    /// files, hidden files, a folder ending in .part or a plain file ending in .download.
    static func classify(name: String, isDirectory: Bool) -> (kind: StatusDownloadKind, finalName: String)? {
        guard !name.hasPrefix(".") else { return nil }
        let lower = name.lowercased()
        let suffixes: [(String, StatusDownloadKind)] = [(".crdownload", .chrome), (".part", .firefox), (".download", .safari)]
        for (suffix, kind) in suffixes where lower.hasSuffix(suffix) {
            guard isDirectory == (kind == .safari) else { return nil }
            let finalName = String(name.dropLast(suffix.count))
            return finalName.isEmpty ? nil : (kind, finalName)
        }
        return nil
    }

    /// Chrome's name before it settles on the real one ("Unconfirmed 123456.crdownload").
    /// Not shown: it's renamed within a second or two.
    static func isUnconfirmed(_ finalName: String, kind: StatusDownloadKind) -> Bool {
        kind == .chrome && finalName.hasPrefix("Unconfirmed ") && Int(finalName.dropFirst("Unconfirmed ".count)) != nil
    }
}

/// Reads progress from the Info.plist inside a Safari .download bundle.
enum StatusSafariDownload {
    struct Progress: Equatable {
        var bytes: Int64
        var total: Int64?           // nil while the size is unknown
    }

    static let bytesKey = "DownloadEntryProgressBytesSoFar"
    static let totalKey = "DownloadEntryProgressTotalToLoad"

    /// Nil when the plist has no byte count. A total of 0 or less means unknown.
    static func progress(plist: [String: Any]) -> Progress? {
        guard let bytes = number(plist[bytesKey]), bytes >= 0 else { return nil }
        return Progress(bytes: bytes, total: number(plist[totalKey]).flatMap { $0 > 0 ? $0 : nil })
    }

    static func progress(data: Data) -> Progress? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        return progress(plist: plist)
    }

    private static func number(_ value: Any?) -> Int64? {
        switch value {
        case let n as NSNumber: n.int64Value
        case let s as String: Int64(s)
        default: nil
        }
    }
}

/// One partial download as found in the folder.
struct StatusDownloadEntry: Equatable {
    var name: String            // the partial's own name ("a.zip.crdownload")
    var finalName: String       // the name it gets when done ("a.zip")
    var kind: StatusDownloadKind
    var bytes: Int64
    var total: Int64? = nil

    var fraction: Double? { Self.fraction(bytes: bytes, total: total) }

    static func fraction(bytes: Int64, total: Int64?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(total)))
    }
}

enum StatusDownloadEvent: Equatable {
    /// Started, or more bytes arrived. Names are final names.
    case progress(name: String, bytes: Int64, total: Int64?, bytesPerSecond: Double?)
    case finished(name: String, bytes: Int64)
    /// A finished download's file went away and an item with a fresh mark took its place
    /// (Safari opened an archive and trashed it): its chip now shows `by`.
    case replaced(name: String, by: String, bytes: Int64)
    /// A finished download's file went away with nothing in its place: take its chip down.
    case gone(name: String)
    /// Cancelled, or no new bytes for a minute: take the activity down.
    case ended(name: String)
}

/// What the tracker needs to know about a finished-looking file.
struct StatusDownloadFileInfo: Equatable {
    var size: Int64
    var quarantine: String?     // the com.apple.quarantine attribute, if any
    var isDirectory = false
}

/// Reads the quarantine mark browsers, AirDrop and Mail put on what they save:
/// "0083;6543abcd;Google Chrome;UUID" is flags, hex seconds since 1970, agent, event id.
enum StatusQuarantine {
    static func date(_ value: String) -> Date? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 2, let seconds = UInt64(parts[1], radix: 16) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Downloaded just now: marked, and the mark is at most 10 min older than when the file
    /// showed up. An old download moved into the folder keeps its old mark. A mark without
    /// a readable date counts as recent.
    static func isRecentDownload(_ value: String?, firstSeen: Date) -> Bool {
        guard let value else { return false }
        guard let date = date(value) else { return true }
        return date >= firstSeen.addingTimeInterval(-600)
    }
}

/// Turns listings of the Downloads folder into download events. Pure: the watcher feeds it
/// the folder's names, the partial downloads among them and a way to look at a file, so the
/// self-test can drive it with made-up listings and times.
///
/// Two paths lead to "finished": a partial that is replaced by its final file, and, for
/// downloads too quick to be seen as partial, a new file with a fresh quarantine mark whose
/// size holds still between two looks. New folders never count as downloads of their own.
///
/// A finished file is watched a little longer, because Safari opens "safe" files right
/// away: it unpacks an archive beside it, passing its mark on, and trashes the archive.
/// What it unpacked into then takes the download's place (see `successor`), and a file
/// that goes with nothing in its place takes its chip down.
struct StatusDownloadTracker {
    /// A finished file may land a moment after its partial goes (Safari moves the data out
    /// of its bundle, Firefox renames over its placeholder), so a partial that vanished
    /// gets this long before it counts as cancelled.
    static let grace: TimeInterval = 5
    static let stallAfter: TimeInterval = 60
    /// Stalled downloads are checked every 15 s for this long, then only on folder changes.
    static let giveUpAfter: TimeInterval = 15 * 60
    /// How long a new file without a fresh quarantine mark is looked at again (Chrome marks
    /// a file just after renaming it).
    static let freshWait: TimeInterval = 3
    /// How long a finished file is watched: a little longer than its chip shows (6 s).
    static let watchFinished: TimeInterval = 10
    /// How long a watched file may be missing, with nothing in its place yet, before it
    /// counts as gone.
    static let goneAfter: TimeInterval = 2

    private enum Phase: Equatable {
        case active
        case stalled
        case vanished(since: Date)
    }

    private struct Tracked {
        var entry: StatusDownloadEntry
        var phase: Phase = .active
        var changedAt: Date
        var bytesPerSecond: Double?

        var shown: Bool { !StatusDownloadFile.isUnconfirmed(entry.finalName, kind: entry.kind) }

        var vanishedSince: Date? {
            if case .vanished(let since) = phase { return since }
            return nil
        }
    }

    /// A new file that isn't a partial, waiting for a second look.
    private struct Fresh {
        var size: Int64
        var firstSeen: Date
        var changedAt: Date
    }

    /// A finished download whose file is still watched (see `watchFinished`).
    private struct Done {
        var since: Date                 // items new from then on may take its place
        var until: Date
        var bytes: Int64                // shown for a folder that takes its place
        var missingSince: Date? = nil
    }

    /// Partials found by the first listing (stale leftovers, usually); never reported. A
    /// name that later disappears is forgotten, so it counts as new if it comes back.
    private var baseline: Set<String>?
    private var known: Set<String> = []            // every name in the previous listing
    private var tracked: [String: Tracked] = [:]   // by partial name
    private var fresh: [String: Fresh] = [:]
    private var done: [String: Done] = [:]         // by file name
    /// New names and when they showed up, kept while a download that goes away may still
    /// turn out to have become one of them.
    private var arrivals: [String: Date] = [:]

    /// `names` is everything in the folder; `info` looks at one file by name and returns nil
    /// if there's no such file.
    mutating func update(_ partials: [StatusDownloadEntry], names: Set<String>, now: Date,
                         info: (String) -> StatusDownloadFileInfo?) -> [StatusDownloadEvent] {
        let partialNames = Set(partials.map(\.name))
        guard let previous = baseline else {
            baseline = partialNames
            known = names
            return []
        }
        let ignored = previous.intersection(partialNames)
        baseline = ignored
        var events: [StatusDownloadEvent] = []

        for entry in partials.sorted(by: { $0.name < $1.name }) where !ignored.contains(entry.name) {
            guard var t = tracked[entry.name] else {
                let t = Tracked(entry: entry, changedAt: now)
                tracked[entry.name] = t
                done[entry.finalName] = nil             // downloading again: the old file isn't watched
                if t.shown { events.append(Self.progress(t)) }
                continue
            }
            if entry.bytes != t.entry.bytes || entry.total != t.entry.total {
                let seconds = now.timeIntervalSince(t.changedAt)
                let delta = entry.bytes - t.entry.bytes
                if seconds >= 0.2, delta > 0, t.phase == .active {
                    let rate = Double(delta) / seconds
                    t.bytesPerSecond = t.bytesPerSecond.map { 0.5 * $0 + 0.5 * rate } ?? rate
                } else if t.phase != .active {
                    t.bytesPerSecond = nil
                }
                t.entry = entry
                t.changedAt = now
                t.phase = .active
                if t.shown { events.append(Self.progress(t)) }
            } else if case .vanished = t.phase {
                t.phase = .active                       // back again, unchanged
            } else if t.phase == .active, now.timeIntervalSince(t.changedAt) >= Self.stallAfter {
                t.phase = .stalled
                t.bytesPerSecond = nil
                if t.shown { events.append(.ended(name: t.entry.finalName)) }
            }
            tracked[entry.name] = t
        }

        // Final names of every partial seen, including ones finishing now: those files
        // belong to the partial path (and Firefox's empty placeholder is one of them).
        let finals = Set(tracked.values.map(\.entry.finalName))
        let taken = partialNames.union(finals)

        // New names: files that may be quick downloads (looked at again below), and anything
        // a download that goes away may have become.
        for name in names.subtracting(known).sorted() where !name.hasPrefix(".") && !partialNames.contains(name) {
            arrivals[name] = now
            if !finals.contains(name), let file = info(name), !file.isDirectory {
                fresh[name] = Fresh(size: file.size, firstSeen: now, changedAt: now)
            }
        }

        for name in tracked.keys.sorted() where !partialNames.contains(name) {
            guard var t = tracked[name] else { continue }
            let finalName = t.entry.finalName
            // Firefox's placeholder is empty until the data is renamed over it.
            if let size = info(finalName)?.size, size > 0 || t.entry.bytes == 0 {
                tracked[name] = nil
                if t.shown {
                    let bytes = max(size, t.entry.total ?? t.entry.bytes)
                    events.append(.finished(name: finalName, bytes: bytes))
                    watch(finalName, since: now, bytes: bytes, now: now)
                }
                continue
            }
            let since = t.vanishedSince ?? now
            let waited = now.timeIntervalSince(since) >= Self.grace
            // Safari can open an archive and trash it before its file is ever seen here.
            if t.entry.kind == .safari, t.shown,
               let (by, file) = successor(of: finalName, since: since, anyName: waited, names: names,
                                          taken: taken, info: info) {
                tracked[name] = nil
                let bytes = file.isDirectory ? (t.entry.total ?? t.entry.bytes) : file.size
                events += [.ended(name: finalName), .finished(name: by, bytes: bytes)]
                claim(by)
                watch(by, since: now, bytes: bytes, now: now)
            } else if waited {
                tracked[name] = nil
                if t.shown { events.append(.ended(name: finalName)) }
            } else if t.vanishedSince == nil {
                t.phase = .vanished(since: now)
                tracked[name] = t
            }
        }

        for name in done.keys.sorted() {
            guard var d = done[name] else { continue }
            if names.contains(name) {
                if now >= d.until {
                    done[name] = nil
                } else if d.missingSince != nil {
                    d.missingSince = nil
                    done[name] = d
                }
            } else if let (by, file) = successor(of: name, since: d.since, anyName: true, names: names,
                                                 taken: taken, info: info) {
                done[name] = nil
                events.append(.replaced(name: name, by: by, bytes: file.isDirectory ? d.bytes : file.size))
                claim(by)
            } else if let missing = d.missingSince {
                if now.timeIntervalSince(missing) >= Self.goneAfter {
                    done[name] = nil
                    events.append(.gone(name: name))
                }
            } else {
                d.missingSince = now
                done[name] = d
            }
        }

        for name in fresh.keys.sorted() {
            guard var f = fresh[name], f.changedAt != now else { continue }      // looked at it just now
            guard names.contains(name), !finals.contains(name), let file = info(name) else {
                fresh[name] = nil
                continue
            }
            if file.size != f.size {
                f.size = file.size                      // still being written
                f.changedAt = now
                fresh[name] = f
            } else if file.size > 0, StatusQuarantine.isRecentDownload(file.quarantine, firstSeen: f.firstSeen) {
                fresh[name] = nil
                events.append(.finished(name: name, bytes: file.size))
                watch(name, since: f.firstSeen, bytes: file.size, now: now)
            } else if now.timeIntervalSince(f.changedAt) >= Self.freshWait {
                fresh[name] = nil                       // not a download (curl, a copy, an old file moved in)
            }
        }

        // New names are kept only while something may still turn out to have become one.
        let horizon = (done.values.map(\.since) + fresh.values.map(\.firstSeen)
                       + tracked.values.compactMap(\.vanishedSince)).min()
        arrivals = horizon.map { h in arrivals.filter { $0.value >= h } } ?? [:]
        known = names
        return events
    }

    /// How often the folder should be read again, or nil to wait for a folder change.
    func pollInterval(now: Date) -> TimeInterval? {
        if !fresh.isEmpty || !done.isEmpty || tracked.values.contains(where: { $0.phase != .stalled }) { return 1 }
        if tracked.values.contains(where: { now.timeIntervalSince($0.changedAt) < Self.giveUpAfter }) { return 15 }
        return nil
    }

    private mutating func watch(_ name: String, since: Date, bytes: Int64, now: Date) {
        done[name] = Done(since: since, until: now.addingTimeInterval(Self.watchFinished), bytes: bytes)
    }

    /// `name` is what a download became, not a download of its own.
    private mutating func claim(_ name: String) {
        fresh[name] = nil
        arrivals[name] = nil
    }

    /// What a download that went away became: an item new since `since`, not itself a
    /// download, with a fresh quarantine mark. One named like it wins ("x.zip" unpacks into
    /// "x", "x 2" or "x.pdf"). With `anyName`, so does a lone folder named otherwise; a file
    /// named otherwise may be a download of its own, and the quick-download path shows it.
    private func successor(of name: String, since: Date, anyName: Bool, names: Set<String>, taken: Set<String>,
                           info: (String) -> StatusDownloadFileInfo?) -> (name: String, file: StatusDownloadFileInfo)? {
        var found: [(name: String, file: StatusDownloadFileInfo)] = []
        for (candidate, seen) in arrivals.sorted(by: { $0.key < $1.key })
        where seen >= since && names.contains(candidate) && !taken.contains(candidate) && done[candidate] == nil {
            guard let file = info(candidate), file.isDirectory || file.size > 0,
                  StatusQuarantine.isRecentDownload(file.quarantine, firstSeen: seen) else { continue }
            found.append((candidate, file))
        }
        let stem = Self.stem(name)
        if let match = found.first(where: { Self.stem($0.name).hasPrefix(stem) }) { return match }
        return anyName && found.count == 1 && found[0].file.isDirectory ? found[0] : nil
    }

    /// The name up to its first dot, lowercased: "x" for "x.tar.gz", "x 2" for "x 2.pdf".
    private static func stem(_ name: String) -> String {
        String(name.prefix { $0 != "." }).lowercased()
    }

    private static func progress(_ t: Tracked) -> StatusDownloadEvent {
        .progress(name: t.entry.finalName, bytes: t.entry.bytes, total: t.entry.total, bytesPerSecond: t.bytesPerSecond)
    }
}

/// Byte counts for the notch: "12.3 MB", "12.3 MB of 40 MB · 2.1 MB/s".
enum StatusDownloadText {
    static func bytes(_ count: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: max(0, count))
    }

    static func subtitle(bytes count: Int64, total: Int64?, bytesPerSecond: Double?) -> String {
        var text = total.map { "\(bytes(count)) of \(bytes($0))" } ?? bytes(count)
        if let rate = bytesPerSecond, rate >= 1 { text += " · \(bytes(Int64(rate)))/s" }
        return text
    }
}

/// Watches the Downloads folder. A file-system event source on the folder catches files
/// appearing, being renamed and going away; a timer re-reads partial files' sizes and looks
/// again at new and just-finished files, and runs only while there are some. Everything
/// happens on a private queue, and `onEvents` is called there.
final class StatusDownloadWatcher: @unchecked Sendable {
    let folder: URL
    private let queue = DispatchQueue(label: "local.dynamicnotch.status.downloads", qos: .utility)
    private let onEvents: @Sendable (StatusDownloadWatcher, [StatusDownloadEvent]) -> Void

    // Touched only on `queue`.
    private var running = false
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var timerInterval: TimeInterval?
    private var scanPending = false
    private var loggedOpenFailure = false
    private var tracker = StatusDownloadTracker()

    init(folder: URL, onEvents: @escaping @Sendable (StatusDownloadWatcher, [StatusDownloadEvent]) -> Void) {
        self.folder = folder
        self.onEvents = onEvents
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            openFolder()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            source?.cancel()
            source = nil
            setPolling(nil)
        }
    }

    /// Opening the folder is what asks for Downloads access the first time. Without it
    /// (denied, or the folder is missing), try again now and then.
    private func openFolder() {
        guard running, source == nil else { return }
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            let code = errno
            if !loggedOpenFailure {
                StatusLog.log.error("can't watch Downloads (errno \(code, privacy: .public)); retrying every 30 s")
                loggedOpenFailure = true
            }
            queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.openFolder() }
            return
        }
        loggedOpenFailure = false
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke],
                                                            queue: queue)
        src.setEventHandler { [weak self] in self?.folderChanged() }
        src.setCancelHandler { Darwin.close(fd) }
        source = src
        src.resume()
        scan()
    }

    private func folderChanged() {
        guard let src = source else { return }
        if !src.data.isDisjoint(with: [.delete, .rename, .revoke]) {
            // The folder itself moved or went away: watch whatever is at the path next.
            src.cancel()
            source = nil
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.openFolder() }
            return
        }
        // A browser renames and writes several entries at once; read the folder once after.
        guard !scanPending else { return }
        scanPending = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            scanPending = false
            scan()
        }
    }

    private func scan() {
        guard running, let listing = Self.listing(of: folder) else { return }
        let now = Date()
        let folder = folder
        let events = tracker.update(listing.partials, names: listing.names, now: now) { name in
            let url = folder.appendingPathComponent(name)
            // Folders too: one unpacked from a fresh archive carries the archive's mark.
            return Self.fileInfo(url).map {
                StatusDownloadFileInfo(size: $0.size, quarantine: Self.quarantine(url), isDirectory: $0.isDirectory)
            }
        }
        if !events.isEmpty { onEvents(self, events) }
        setPolling(tracker.pollInterval(now: now))
    }

    private func setPolling(_ interval: TimeInterval?) {
        guard interval != timerInterval else { return }
        timer?.cancel()
        timer = nil
        timerInterval = interval
        guard let interval else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 200)))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    /// Every name in `folder` and the partial downloads among them, or nil if it can't be
    /// read. Lists names only and looks closer at the few that look like partials.
    private static func listing(of folder: URL) -> (names: Set<String>, partials: [StatusDownloadEntry])? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        var entries: [StatusDownloadEntry] = []
        for name in names {
            guard StatusDownloadFile.classify(name: name, isDirectory: true) != nil
                    || StatusDownloadFile.classify(name: name, isDirectory: false) != nil else { continue }
            let url = folder.appendingPathComponent(name)
            guard let info = fileInfo(url),
                  let (kind, finalName) = StatusDownloadFile.classify(name: name, isDirectory: info.isDirectory) else { continue }
            var entry = StatusDownloadEntry(name: name, finalName: finalName, kind: kind, bytes: info.size)
            if kind == .safari {
                let plist = (try? Data(contentsOf: url.appendingPathComponent("Info.plist")))
                    .flatMap(StatusSafariDownload.progress(data:))
                let data = fileInfo(url.appendingPathComponent(finalName))?.size ?? 0
                entry.bytes = max(plist?.bytes ?? 0, data)
                entry.total = plist?.total
            }
            entries.append(entry)
        }
        return (Set(names), entries)
    }

    private static func fileInfo(_ url: URL) -> (size: Int64, isDirectory: Bool)? {
        var st = Darwin.stat()
        guard Darwin.lstat(url.path, &st) == 0 else { return nil }
        return (Int64(st.st_size), (st.st_mode & S_IFMT) == S_IFDIR)
    }

    private static func quarantine(_ url: URL) -> String? {
        let attribute = "com.apple.quarantine"
        let length = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(url.path, attribute, &buffer, length, 0, XATTR_NOFOLLOW)
        guard read > 0 else { return nil }
        return String(decoding: buffer.prefix(read), as: UTF8.self)
    }
}
