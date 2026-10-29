import AppKit
import CoreServices
import ImageIO

/// AppleScript sources for Spotify and Music, and parsers for their replies. Every script
/// first checks `application "X" is running`, which asks without launching the app, so a
/// control can never start a player that was quit in the meantime. `system` is never
/// scripted (its helper takes the controls), so its scripts return nothing.
enum NowPlayingScripts {
    /// AppleScript's "not authorized to send Apple events" (Automation denied).
    static let notPermitted = -1743
    /// errAETimeout: a script's `with timeout` ran out, or a press waited too long for its turn.
    static let timedOut = -1712
    /// userCanceledErr: a queued script that was no longer wanted, so it never ran.
    static let skipped = -128
    /// Seconds a status or artwork script waits on a busy player. They run only once
    /// permission is known to be granted, so the timeout never cuts short the Automation prompt.
    static let replyTimeout = 2

    /// Returns true if the app was running and got the command, false if it wasn't running
    /// (nothing sent, so nothing learned about permission). No timeout: the first press may
    /// wait on you answering the Automation prompt.
    static func command(_ command: NowPlayingCommand, for player: NowPlayingPlayer) -> String {
        """
        if application "\(player.appName)" is running then
            tell application "\(player.appName)" to \(command.verb)
            return true
        end if
        return false
        """
    }

    /// Returns {} (not running), {state} (stopped), or
    /// {state, name, artist, album, id, duration in ms, position in s}.
    /// Spotify gives duration in ms and `id` as its track URI; Music gives seconds and a hex
    /// persistent ID, and streams in Music have no duration, hence the try.
    static func status(for player: NowPlayingPlayer) -> String {
        switch player {
        case .spotify:
            """
            if application "Spotify" is running then
                with timeout of \(replyTimeout) seconds
                    tell application "Spotify"
                        set s to player state as string
                        if s is "stopped" then return {s}
                        set t to current track
                        return {s, name of t, artist of t, album of t, id of t, duration of t, player position}
                    end tell
                end timeout
            end if
            return {}
            """
        case .music:
            """
            if application "Music" is running then
                with timeout of \(replyTimeout) seconds
                    tell application "Music"
                        set s to player state as string
                        if s is "stopped" then return {s}
                        set t to current track
                        set d to 0
                        try
                            set d to (duration of t) * 1000
                        end try
                        return {s, name of t, artist of t, album of t, persistent ID of t, d, player position}
                    end tell
                end timeout
            end if
            return {}
            """
        case .system:
            "return {}"
        }
    }

    /// Returns {} or {track id, artwork url} (Spotify), {} or {name, raw artwork data or ""} (Music).
    /// The first item says which track the art belongs to, since the app may have moved on.
    static func artwork(for player: NowPlayingPlayer) -> String {
        switch player {
        case .spotify:
            """
            if application "Spotify" is running then
                with timeout of \(replyTimeout) seconds
                    tell application "Spotify"
                        if player state is stopped then return {}
                        return {id of current track, artwork url of current track}
                    end tell
                end timeout
            end if
            return {}
            """
        case .music:
            """
            if application "Music" is running then
                with timeout of \(replyTimeout) seconds
                    tell application "Music"
                        if player state is stopped then return {}
                        set t to current track
                        if (count of artworks of t) is 0 then return {name of t, ""}
                        return {name of t, raw data of artwork 1 of t}
                    end tell
                end timeout
            end if
            return {}
            """
        case .system:
            "return {}"
        }
    }

    /// Turns a `status` reply into a track, through the same keys the notifications use.
    static func statusTrack(_ reply: NSAppleEventDescriptor, player: NowPlayingPlayer) -> NowPlayingTrack? {
        let items = listItems(reply)
        guard let state = items.first?.stringValue else { return nil }
        var info: [String: Any] = ["Player State": state]
        if items.count >= 7 {
            info["Name"] = items[1].stringValue
            info["Artist"] = items[2].stringValue
            info["Album"] = items[3].stringValue
            switch player {
            case .spotify:
                info["Track ID"] = items[4].stringValue
                info["Duration"] = NSNumber(value: items[5].doubleValue)
                info["Playback Position"] = NSNumber(value: items[6].doubleValue)
            case .music:
                info["PersistentID"] = items[4].stringValue
                info["Total Time"] = NSNumber(value: items[5].doubleValue)
            case .system:
                return nil
            }
        }
        return NowPlayingTrack.parse(player: player, userInfo: info)
    }

    /// Turns an `artwork` reply into which track it is for, plus a URL (Spotify) or a small
    /// image made from the raw data (Music). Runs on the script queue, so decoding the art
    /// stays off the main thread.
    static func artReply(_ reply: NSAppleEventDescriptor, player: NowPlayingPlayer) -> NowPlayingArtReply? {
        let items = listItems(reply)
        guard items.count == 2, let match = items[0].stringValue, !match.isEmpty else { return nil }
        switch player {
        case .spotify:
            let url = items[1].stringValue.flatMap(NowPlayingArtwork.coverURL)
            return NowPlayingArtReply(match: match, url: url, image: nil)
        case .music:
            let art = items[1]
            let isText = [typeUnicodeText, typeUTF8Text, typeChar].contains(art.descriptorType)
            let image = isText ? nil : NowPlayingArtwork.thumbnail(art.data)
            return NowPlayingArtReply(match: match, url: nil, image: image)
        case .system:
            return nil
        }
    }

    /// The items of an AppleScript list (1-based in Apple events), or none for anything else.
    private static func listItems(_ reply: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard reply.descriptorType == typeAEList, reply.numberOfItems > 0 else { return [] }
        return (1...reply.numberOfItems).compactMap { reply.atIndex($0) }
    }
}

/// What an artwork script returned. `match` is the Spotify track URI, or the Music track name.
struct NowPlayingArtReply: Sendable {
    var match: String
    var url: URL?
    var image: CGImage?

    func belongs(to track: NowPlayingTrack) -> Bool {
        switch track.player {
        case .spotify: match == track.id
        case .music: match.trimmingCharacters(in: .whitespacesAndNewlines) == track.title
        case .system: false
        }
    }
}

enum NowPlayingScriptOutcome<T: Sendable>: Sendable {
    case success(T?)
    case failure(code: Int)              // AppleScript error number; -1743 means not permitted
}

/// Whether this app may send Apple events to a player, as macOS answers without asking.
enum NowPlayingConsent: Equatable, Sendable {
    case granted, denied, undetermined, notRunning, unknown

    init(status: OSStatus) {
        switch Int(status) {
        case Int(noErr): self = .granted
        case Int(errAEEventNotPermitted): self = .denied
        case Int(errAEEventWouldRequireUserConsent): self = .undetermined
        case Int(procNotFound): self = .notRunning
        default: self = .unknown
        }
    }
}

/// Runs AppleScript on one serial queue, never the main thread: a script can wait on a
/// busy app, or on the user answering the Automation prompt. NSAppleScript isn't
/// thread-safe, so every call goes through this queue.
///
/// Control presses go ahead of any status, artwork or permission job still waiting, so
/// they wait at most for the one script already running (bounded by `replyTimeout`).
final class NowPlayingScriptRunner: @unchecked Sendable {
    /// A press still waiting this long when its turn comes is dropped unsent, so presses made
    /// while a player was stuck don't all replay once it recovers.
    static let staleAfter: TimeInterval = 2.5

    private typealias Job = () -> Void

    private let queue = DispatchQueue(label: "local.dynamicnotch.nowplaying", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:]   // touched only on `queue`
    private let lock = NSLock()
    private var commands: [Job] = []                      // under `lock`; run before `others`
    private var others: [Job] = []                        // under `lock`

    /// Runs `source`, parses the reply on the queue, and hands the result to `done` on the main thread.
    /// If `unwanted` says so when its turn comes, the script doesn't run and fails with `skipped`.
    func run<T: Sendable>(_ source: String,
                          unwanted: (@Sendable () -> Bool)? = nil,
                          parse: @escaping @Sendable (NSAppleEventDescriptor) -> T?,
                          done: @escaping @MainActor @Sendable (NowPlayingScriptOutcome<T>) -> Void) {
        enqueue(command: false) { [self] in
            let outcome: NowPlayingScriptOutcome<T> = unwanted?() == true
                ? .failure(code: NowPlayingScripts.skipped) : execute(source, parse: parse)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(outcome) } }
        }
    }

    /// Runs a control's script ahead of every waiting job. A press older than `staleAfter`
    /// by then fails with `timedOut` without being sent.
    func runCommand<T: Sendable>(_ source: String,
                                 parse: @escaping @Sendable (NSAppleEventDescriptor) -> T?,
                                 done: @escaping @MainActor @Sendable (NowPlayingScriptOutcome<T>) -> Void) {
        let pressed = DispatchTime.now()
        enqueue(command: true) { [self] in
            let outcome: NowPlayingScriptOutcome<T> = DispatchTime.now() > pressed + Self.staleAfter
                ? .failure(code: NowPlayingScripts.timedOut) : execute(source, parse: parse)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(outcome) } }
        }
    }

    /// Asks macOS whether Apple events to `player` are allowed. Never shows a prompt.
    func checkConsent(_ player: NowPlayingPlayer, done: @escaping @MainActor @Sendable (NowPlayingConsent) -> Void) {
        guard let bundleID = player.bundleID else {
            DispatchQueue.main.async { MainActor.assumeIsolated { done(.unknown) } }
            return
        }
        enqueue(command: false) {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            // `aeDesc` points into `target`, so it must outlive the call.
            let status = withExtendedLifetime(target) {
                AEDeterminePermissionToAutomateTarget(
                    target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
            }
            let consent = NowPlayingConsent(status: status)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(consent) } }
        }
    }

    /// Each job adds one block to the queue, and each block runs whichever job is next,
    /// commands first; so a command jumps every job that hasn't started.
    private func enqueue(command: Bool, _ job: @escaping Job) {
        lock.withLock { if command { commands.append(job) } else { others.append(job) } }
        queue.async { [self] in
            let next = lock.withLock { commands.isEmpty ? others.removeFirst() : commands.removeFirst() }
            next()
        }
    }

    private func execute<T: Sendable>(_ source: String,
                                      parse: (NSAppleEventDescriptor) -> T?) -> NowPlayingScriptOutcome<T> {
        var error: NSDictionary?
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { return .failure(code: -1) }
            guard fresh.compileAndReturnError(&error) else { return .failure(code: Self.code(error)) }
            compiled[source] = fresh
            script = fresh
        }
        let reply = script.executeAndReturnError(&error)
        if error != nil { return .failure(code: Self.code(error)) }
        return .success(parse(reply))
    }

    private static func code(_ error: NSDictionary?) -> Int {
        (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
    }
}

/// Album art: downloading Spotify's cover URL and shrinking covers to notch size.
enum NowPlayingArtwork {
    /// The peek shows art at 34 pt; 128 px stays sharp on a Retina screen.
    static let maxPixels = 128
    /// Largest cover download accepted; Spotify's are about 100 KB.
    static let maxDownloadBytes = 5_000_000
    /// Largest embedded Music artwork decoded. It's already in memory, and ImageIO shrinks
    /// it without decoding the full image, so big user-added PNGs are fine.
    static let maxRawBytes = 40_000_000

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Only HTTPS URLs with a host are fetched. The URL comes from Spotify itself.
    static func isFetchable(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    /// Spotify's `artwork url`, upgraded to HTTPS (some versions report http://, which App
    /// Transport Security blocks; its image CDN serves both). Nil for anything else.
    static func coverURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") { trimmed = "https://" + trimmed.dropFirst(7) }
        guard let url = URL(string: trimmed), isFetchable(url) else { return nil }
        return url
    }

    /// Decodes and shrinks image data; nil if it isn't an image or is over `maxBytes`.
    static func thumbnail(_ data: Data, maxPixels: Int = maxPixels, maxBytes: Int = maxRawBytes) -> CGImage? {
        guard !data.isEmpty, data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// What a cover download gave.
    enum Download: Sendable {
        case image(CGImage)
        case noArt          // a definite answer: this cover doesn't exist or isn't an image
        case transient      // offline, a timeout, the server busy; worth trying again later
    }

    /// Classifies a finished download. `failed` is a URLSession error; `status` 0 means no
    /// HTTP response.
    static func downloadResult(failed: Bool, status: Int, data: Data?) -> Download {
        if failed || status == 0 || status == 408 || status == 429 || status >= 500 { return .transient }
        guard (200..<300).contains(status), let image = data.flatMap({ thumbnail($0, maxBytes: maxDownloadBytes) }) else {
            return .noArt
        }
        return .image(image)
    }

    /// Downloads and shrinks the image at `url` off the main thread; `done` runs on the
    /// main thread.
    @MainActor
    static func download(_ url: URL, done: @escaping @MainActor @Sendable (Download) -> Void) {
        guard isFetchable(url) else {
            done(.noArt)
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result = downloadResult(failed: error != nil, status: status, data: data)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }.resume()
    }
}
