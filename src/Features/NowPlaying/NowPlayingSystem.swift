import AppKit
import os

/// Everything that isn't Spotify or Music (a YouTube or Suno tab, VLC, Podcasts…), read
/// from macOS's own Now Playing, which every app and browser reports to.
///
/// MediaRemote, the private framework behind it, answers only Apple's own processes since
/// macOS 15.4. So the reading happens in `NowPlayingHelper.dylib` (helpers/NowPlayingHelper.m,
/// built into the app's Frameworks folder), run by Apple's `/usr/bin/perl`: it sends a JSON
/// line per change, and takes play/pause, next and previous on its input. It exits when this
/// app closes its input, so it never outlives the app. No permission is involved.
///
/// Spotify and Music show through their own notifications, so their lines count as nothing
/// here. A helper that stops is started again after a pause that doubles each time; after
/// five failures in a row without a minute of running, it stays off until the next start.
@MainActor
final class NowPlayingSystemSource {
    private static let maxFailures = 5
    /// Loads the dylib named by the first argument and calls its run loop, which never returns.
    private static let perlScript = """
        use DynaLoader;
        my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $s = DynaLoader::dl_find_symbol($h, "dn_nowplaying_run") or die DynaLoader::dl_error();
        DynaLoader::dl_install_xsub("main::run", $s);
        run();
        """

    private let log = Logger(subsystem: "local.dynamicnotch", category: "nowplaying")
    /// A track for `system`, or nil when nothing (or only Spotify or Music) is playing, with its cover.
    private let onUpdate: (NowPlayingTrack?, CGImage?) -> Void
    private var process: Process?
    private var input: FileHandle?
    private var startedAt = Date.distantPast
    private var failures = 0
    private var restart: DispatchWorkItem?
    private var wanted = false
    private var appNames: [String: String] = [:]

    init(onUpdate: @escaping (NowPlayingTrack?, CGImage?) -> Void) {
        self.onUpdate = onUpdate
    }

    static var helperURL: URL? {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("NowPlayingHelper.dylib"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var isRunning: Bool { process != nil }

    func start() {
        wanted = true
        failures = 0
        if process == nil && restart == nil { launch() }
    }

    func stop() {
        wanted = false
        restart?.cancel()
        restart = nil
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        onUpdate(nil, nil)
    }

    /// Sends a control to whichever app macOS says is playing.
    func send(_ command: NowPlayingCommand) {
        guard let input else { return }
        do {
            try input.write(contentsOf: Data((command.rawValue + "\n").utf8))
        } catch {
            log.error("now playing helper didn't take \(command.rawValue, privacy: .public)")
        }
    }

    private func launch() {
        restart = nil
        guard wanted else { return }
        guard let helper = Self.helperURL else {
            log.error("NowPlayingHelper.dylib is missing; only Spotify and Music will show")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.perlScript, helper.path]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        // A write after the helper died fails instead of killing this app with SIGPIPE.
        _ = fcntl(inp.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let reader = NowPlayingLineReader { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(line) } }
        }
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.append(data) }
        }
        p.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(ended, status: status) } }
        }
        do {
            try p.run()
        } catch {
            log.error("now playing helper didn't start: \(error.localizedDescription, privacy: .public)")
            return
        }
        try? inp.fileHandleForReading.close()
        process = p
        input = inp.fileHandleForWriting
        startedAt = Date()
    }

    private func exited(_ ended: Process, status: Int32) {
        guard ended === process else { return }      // one stopped on purpose
        process = nil
        try? input?.close()
        input = nil
        onUpdate(nil, nil)
        guard wanted else { return }
        if Date().timeIntervalSince(startedAt) > 60 { failures = 0 }
        failures += 1
        guard failures < Self.maxFailures else {
            log.error("now playing helper keeps stopping (status \(status)); only Spotify and Music will show")
            return
        }
        let delay = Double(1 << failures)
        log.info("now playing helper stopped (status \(status)); restarting in \(Int(delay)) s")
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.launch() } }
        restart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func received(_ line: NowPlayingSystemLine) {
        guard process != nil else { return }
        let track = Self.track(from: line) { [self] bundle in appName(for: bundle) }
        onUpdate(track, track == nil ? nil : line.art)
    }

    /// The running app's name ("Google Chrome"), or the installed one's; cached.
    private func appName(for bundleID: String) -> String {
        if let cached = appNames[bundleID] { return cached }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent
            ?? ""
        appNames[bundleID] = name
        return name
    }

    /// The track a helper line describes, or nil when it's Spotify or Music (shown through
    /// their own notifications) or unreadable. Pure, for the self-test.
    nonisolated static func track(from line: NowPlayingSystemLine, appName: (String) -> String) -> NowPlayingTrack? {
        let bundle = line.info["Bundle"] ?? ""
        guard NowPlayingPlayer(bundleID: bundle) == nil else { return nil }
        var info: [AnyHashable: Any] = line.info
        info["App"] = bundle.isEmpty ? "" : appName(bundle)
        if let duration = line.duration { info["Duration"] = NSNumber(value: duration) }
        return NowPlayingTrack.parse(player: .system, userInfo: info)
    }
}

/// One line from the helper: its text fields, the duration, and the cover shrunk to notch size.
struct NowPlayingSystemLine: Sendable {
    var info: [String: String]           // Player State, Name, Artist, Album, Bundle
    var duration: Double?
    var art: CGImage?

    /// Nil for anything that isn't a JSON object with a player state.
    static func parse(_ data: Data) -> NowPlayingSystemLine? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["Player State"] is String else { return nil }
        var info: [String: String] = [:]
        for key in ["Player State", "Name", "Artist", "Album", "Bundle"] {
            if let value = object[key] as? String { info[key] = value }
        }
        let art = (object["Art"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { NowPlayingArtwork.thumbnail($0) }
        return NowPlayingSystemLine(info: info, duration: (object["Duration"] as? NSNumber)?.doubleValue, art: art)
    }
}

/// Splits the helper's output into lines and parses each off the main thread (a line with
/// a cover can be a few hundred KB). The pipe hands it one chunk at a time, never two at once.
private final class NowPlayingLineReader: @unchecked Sendable {
    /// More than this without a line break is not the helper talking; it's dropped.
    private static let maxLine = 60_000_000
    private var buffer = Data()
    private let onLine: @Sendable (NowPlayingSystemLine) -> Void

    init(onLine: @escaping @Sendable (NowPlayingSystemLine) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let parsed = NowPlayingSystemLine.parse(line) { onLine(parsed) }
        }
        if buffer.count > Self.maxLine { buffer.removeAll() }
    }
}
