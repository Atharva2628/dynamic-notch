import Foundation

/// Where a track comes from. Spotify and Music announce their tracks themselves and take
/// AppleScript; `system` is everything else (a browser tab, VLC, Podcasts…), read from
/// macOS's own Now Playing by `NowPlayingSystemSource`.
enum NowPlayingPlayer: String, CaseIterable, Sendable {
    case spotify, music, system

    /// The apps with their own notifications, AppleScript controls and covers.
    static let apps: [NowPlayingPlayer] = [.spotify, .music]

    /// Nil for `system`, which stands for whichever app macOS says is playing.
    var bundleID: String? {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        case .system: nil
        }
    }

    /// The app's name, for AppleScript `tell` blocks and for display.
    var appName: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Music"
        case .system: "Now Playing"
        }
    }

    /// The distributed notification the app posts on every track or play state change.
    var notification: Notification.Name? {
        switch self {
        case .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged")
        case .music: Notification.Name("com.apple.Music.playerInfo")
        case .system: nil
        }
    }

    var tint: ActivityTint {
        switch self {
        case .spotify: .green
        case .music: .red
        case .system: .white
        }
    }

    init?(bundleID: String?) {
        guard let bundleID, let match = Self.apps.first(where: { $0.bundleID == bundleID }) else { return nil }
        self = match
    }

    init?(notification: Notification.Name) {
        guard let match = Self.apps.first(where: { $0.notification == notification }) else { return nil }
        self = match
    }
}

/// One update from a player: the track and whether it's playing. Parsed from the
/// notification's userInfo (or the same keys built from an AppleScript reply).
struct NowPlayingTrack: Equatable, Sendable {
    enum State: String, Sendable { case playing, paused, stopped }

    var player: NowPlayingPlayer
    var id: String                       // Spotify's track URI, Music's persistent ID, or name|artist|album
    var title: String
    var artist: String
    var album: String
    var state: State
    var duration: TimeInterval?          // seconds
    var position: TimeInterval?          // seconds; Spotify only
    var source = ""                      // the app it plays in ("Safari"); `system` only

    /// Identifies the track across updates (art cache, "is this a new track?").
    var key: String { "\(player.rawValue):\(id)" }

    /// Title to show; a nameless track (an ad, a stream between songs) shows the app's name.
    var displayTitle: String { title.isEmpty ? (source.isEmpty ? player.appName : source) : title }

    /// Spotify: Name, Artist, Album, Player State, Track ID, Duration (ms), Playback Position (s).
    /// Music: Name, Artist, Album, Player State, Total Time (ms), PersistentID.
    /// System: Name, Artist, Album, Player State, Duration (s), Bundle, App (its name).
    /// Returns nil when the player state is missing or unknown; a "Stopped" update usually
    /// carries nothing else, so the other fields may come back empty.
    static func parse(player: NowPlayingPlayer, userInfo: [AnyHashable: Any]) -> NowPlayingTrack? {
        guard let state = parseState(userInfo["Player State"]) else { return nil }
        let title = text(userInfo["Name"])
        let artist = text(userInfo["Artist"])
        let album = text(userInfo["Album"])
        let fallbackID = [title, artist, album].joined(separator: "|")
        switch player {
        case .spotify:
            let trackID = text(userInfo["Track ID"])
            return NowPlayingTrack(
                player: player, id: trackID.isEmpty ? fallbackID : trackID,
                title: title, artist: artist, album: album, state: state,
                duration: number(userInfo["Duration"]).map { $0 / 1000 },
                position: number(userInfo["Playback Position"]))
        case .music:
            return NowPlayingTrack(
                player: player, id: persistentID(userInfo["PersistentID"]) ?? fallbackID,
                title: title, artist: artist.isEmpty ? text(userInfo["Stream Title"]) : artist,
                album: album, state: state,
                duration: number(userInfo["Total Time"]).map { $0 / 1000 },
                position: nil)
        case .system:
            // Titles repeat across apps (two tabs, one song), so the app is part of the ID.
            return NowPlayingTrack(
                player: player, id: text(userInfo["Bundle"]) + "|" + fallbackID,
                title: title, artist: artist, album: album, state: state,
                duration: number(userInfo["Duration"]), position: nil, source: text(userInfo["App"]))
        }
    }

    /// "Playing", "Paused", "Stopped" from notifications; lowercase from AppleScript.
    /// Music's "Fast Forwarding" and "Rewinding" count as playing.
    private static func parseState(_ value: Any?) -> State? {
        switch (value as? String)?.lowercased() {
        case "playing", "fast forwarding", "rewinding": .playing
        case "paused": .paused
        case "stopped": .stopped
        default: nil
        }
    }

    private static func text(_ value: Any?) -> String {
        ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func number(_ value: Any?) -> Double? {
        let n: Double? = switch value {
        case let v as NSNumber: v.doubleValue
        case let v as String: Double(v)
        default: nil
        }
        guard let n, n.isFinite, n >= 0 else { return nil }
        return n
    }

    /// The notification sends a signed 64-bit number, AppleScript a 16-digit hex string;
    /// both become the hex string.
    private static func persistentID(_ value: Any?) -> String? {
        switch value {
        case let v as NSNumber: String(format: "%016llX", UInt64(bitPattern: v.int64Value))
        case let v as String where !v.isEmpty: v.uppercased()
        default: nil
        }
    }
}

/// What each player last said, and which one the notch shows. The shown player is also
/// the one the controls talk to.
struct NowPlayingState: Equatable {
    private(set) var tracks: [NowPlayingPlayer: NowPlayingTrack] = [:]
    private(set) var active: NowPlayingPlayer?

    var current: NowPlayingTrack? { active.flatMap { tracks[$0] } }

    /// The app that sent the shown track; controls go there and nowhere else.
    var controlTarget: NowPlayingPlayer? { current?.player }

    /// A player that starts playing takes over. A paused update never hides a player that is
    /// still playing: pausing Music in the background doesn't hide Spotify, and pausing the
    /// shown Music while Spotify plays shows Spotify.
    mutating func apply(_ track: NowPlayingTrack) {
        let player = track.player
        switch track.state {
        case .stopped:
            forget(player)
        case .playing:
            tracks[player] = track
            active = player
        case .paused:
            tracks[player] = track
            // A playing player always wins over a paused one, including when the shown player is the one pausing.
            active = NowPlayingPlayer.allCases.first { $0 != player && tracks[$0]?.state == .playing } ?? player
        }
    }

    /// The player stopped or quit. The other player's track, if any, shows instead.
    mutating func forget(_ player: NowPlayingPlayer) {
        tracks[player] = nil
        guard active == player else { return }
        let others = NowPlayingPlayer.allCases.compactMap { tracks[$0] }
        active = (others.first { $0.state == .playing } ?? others.first)?.player
    }

    /// The track the notch should show with these settings, or nil to show nothing.
    func visibleTrack(enabled: Bool, hideWhenPaused: Bool) -> NowPlayingTrack? {
        guard enabled, let track = current else { return nil }
        switch track.state {
        case .playing: return track
        case .paused: return hideWhenPaused ? nil : track
        case .stopped: return nil
        }
    }
}

/// The three buttons in the peek. Raw values are the activity action ids.
enum NowPlayingCommand: String, CaseIterable, Sendable {
    case previous, playPause = "playpause", next

    /// The verb both Spotify and Music understand. The raw value is what
    /// `NowPlayingSystemSource` sends its helper.
    var verb: String {
        switch self {
        case .previous: "previous track"
        case .playPause: "playpause"
        case .next: "next track"
        }
    }

    var symbol: String {
        switch self {
        case .previous: "backward.fill"
        case .playPause: "playpause.fill"
        case .next: "forward.fill"
        }
    }

    var title: String {
        switch self {
        case .previous: "Previous"
        case .playPause: "Play or Pause"
        case .next: "Next"
        }
    }
}

/// A small least-recently-used cache, for album art.
struct NowPlayingCache<Value> {
    let capacity: Int
    private var values: [String: Value] = [:]
    private var order: [String] = []     // least recently used first

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { values.count }

    mutating func value(for key: String) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func set(_ value: Value, for key: String) {
        values[key] = value
        touch(key)
        while order.count > capacity { values[order.removeFirst()] = nil }
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
