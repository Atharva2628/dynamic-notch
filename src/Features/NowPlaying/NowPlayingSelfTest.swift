import AppKit

extension NowPlayingFeature {
    /// Pure checks: parsing both apps' notifications and AppleScript replies, the system
    /// helper's lines, which player is shown and controlled, the activity, the art cache.
    /// No apps, scripts, helper or network.
    @MainActor
    static func selfTest(_ check: (Bool, String) -> Void) {
        // Notifications. Spotify: Duration in ms, Playback Position in s, Track ID.
        // Music: Total Time in ms, PersistentID as a signed 64-bit number.
        let spotifyInfo: [AnyHashable: Any] = [
            "Name": "Bohemian Rhapsody", "Artist": "Queen", "Album": "A Night at the Opera",
            "Player State": "Playing", "Track ID": "spotify:track:7tFiyTwD0nx5a1eklYtX2J",
            "Duration": NSNumber(value: 354_320), "Playback Position": NSNumber(value: 12.5),
        ]
        let musicInfo: [AnyHashable: Any] = [
            "Name": "Teardrop", "Artist": "Massive Attack", "Album": "Mezzanine", "Player State": "Paused",
            "Total Time": NSNumber(value: 330_000), "PersistentID": NSNumber(value: Int64(-2)),
        ]
        guard let spotify = NowPlayingTrack.parse(player: .spotify, userInfo: spotifyInfo),
              let music = NowPlayingTrack.parse(player: .music, userInfo: musicInfo) else {
            check(false, "now playing: both apps' notifications parse")
            return
        }
        check(spotify.title == "Bohemian Rhapsody" && spotify.artist == "Queen" && spotify.album == "A Night at the Opera"
              && spotify.state == .playing && spotify.id == "spotify:track:7tFiyTwD0nx5a1eklYtX2J"
              && spotify.duration == 354.32 && spotify.position == 12.5,
              "now playing: Spotify's notification gives the track, its URI, duration and position")
        check(music.title == "Teardrop" && music.artist == "Massive Attack" && music.state == .paused
              && music.duration == 330 && music.id == "FFFFFFFFFFFFFFFE",
              "now playing: Music's notification gives the track, paused state, and AppleScript's hex ID")
        let stopped = NowPlayingTrack.parse(player: .music, userInfo: ["Player State": "Stopped"])
        check(stopped?.state == .stopped && stopped?.title == ""
              && NowPlayingTrack.parse(player: .music, userInfo: ["Name": "x", "Player State": "Fast Forwarding"])?.state == .playing,
              "now playing: a bare Stopped update parses, and fast forwarding counts as playing")
        check(NowPlayingTrack.parse(player: .spotify, userInfo: ["Name": "Song"]) == nil
              && NowPlayingTrack.parse(player: .spotify, userInfo: ["Name": "Song", "Player State": "Buffering"]) == nil,
              "now playing: a missing or unknown state is ignored")
        let ad = NowPlayingTrack.parse(player: .spotify, userInfo: ["Player State": "Playing"])
        check(ad?.id == "||" && ad?.displayTitle == "Spotify", "now playing: a nameless track gets an ID and shows the app's name")
        check(NowPlayingPlayer(notification: Notification.Name("com.spotify.client.PlaybackStateChanged")) == .spotify
              && NowPlayingPlayer(bundleID: "com.apple.Music") == .music && NowPlayingPlayer(bundleID: "com.apple.Safari") == nil,
              "now playing: players are recognized by notification and bundle ID")

        // Which player shows, and which one the controls talk to.
        var state = NowPlayingState()
        state.apply(spotify)
        check(state.controlTarget == .spotify, "now playing: controls go to the app that sent the track")
        state.apply(music)
        check(state.current == spotify, "now playing: a paused update from Music doesn't hide playing Spotify")
        var musicPlaying = music
        musicPlaying.state = .playing
        state.apply(musicPlaying)
        check(state.controlTarget == .music, "now playing: the app that starts playing takes over the controls")
        if let stopped { state.apply(stopped) }
        let afterStop = state.current
        state.forget(.spotify)
        check(afterStop == spotify && state.current == nil && state.controlTarget == nil,
              "now playing: when Music stops Spotify shows again; when Spotify quits, nothing is controlled")
        var both = NowPlayingState()
        both.apply(spotify)
        both.apply(musicPlaying)
        both.apply(music)
        check(both.current == spotify && both.controlTarget == .spotify
              && both.visibleTrack(enabled: true, hideWhenPaused: true) == spotify,
              "now playing: pausing the shown Music while Spotify plays shows Spotify")

        // Everything else (a browser tab, VLC), from macOS's Now Playing through the helper.
        func line(_ json: String) -> NowPlayingSystemLine? { NowPlayingSystemLine.parse(Data(json.utf8)) }
        func systemTrack(_ json: String) -> NowPlayingTrack? {
            line(json).flatMap { NowPlayingSystemSource.track(from: $0) { $0 == "com.apple.Safari" ? "Safari" : "" } }
        }
        let tab = systemTrack(#"{"Album":"","Artist":"Sample Artist","Bundle":"com.apple.Safari","Duration":212.36,"Name":"Sample Song","Player State":"Playing"}"#)
        check(tab?.player == .system && tab?.title == "Sample Song" && tab?.artist == "Sample Artist" && tab?.state == .playing
              && tab?.duration == 212.36 && tab?.source == "Safari" && tab?.key == "system:com.apple.Safari|Sample Song|Sample Artist|",
              "now playing: a browser tab's track comes from macOS's Now Playing, with the app it plays in")
        check(systemTrack(#"{"Bundle":"com.spotify.client","Name":"Song","Player State":"Playing"}"#) == nil
              && systemTrack(#"{"Bundle":"com.apple.Music","Name":"Song","Player State":"Paused"}"#) == nil,
              "now playing: Spotify and Music from macOS's Now Playing are left to their own notifications")
        check(systemTrack(#"{"Player State":"Stopped"}"#)?.state == .stopped
              && line(#"{"Name":"Song"}"#) == nil && line("[1]") == nil && line("not json") == nil,
              "now playing: nothing playing reads as stopped; a line without a player state is ignored")
        let cover = line(#"{"Player State":"Playing","Name":"x","Art":""# + samplePNG(width: 600).base64EncodedString() + #""}"#)
        check(cover?.art.map { max($0.width, $0.height) <= NowPlayingArtwork.maxPixels } ?? false
              && line(#"{"Player State":"Playing","Art":"%%%"}"#)?.art == nil,
              "now playing: a cover from the helper is shrunk to notch size; a broken one is skipped")
        if let tab {
            var mixed = NowPlayingState()
            mixed.apply(spotify)
            mixed.apply(tab)
            check(mixed.controlTarget == .system, "now playing: a tab that starts playing takes over from Spotify")
            var pausedTab = tab
            pausedTab.state = .paused
            mixed.apply(pausedTab)
            check(mixed.current == spotify, "now playing: pausing the tab while Spotify plays shows Spotify")
            mixed.forget(.spotify)
            check(mixed.current == pausedTab, "now playing: when Spotify quits the paused tab is what's left")
            var bare = tab
            bare.artist = ""
            var untitled = bare
            untitled.title = ""
            check(activity(for: bare, image: nil).subtitle == "Safari" && activity(for: untitled, image: nil).title == "Safari"
                  && activity(for: untitled, image: nil).subtitle == nil && activity(for: tab, image: nil).tint == .white,
                  "now playing: a tab without an artist names its app; one without a title shows the app's name")
        }

        // Settings: hide when paused, off.
        var paused = NowPlayingState()
        paused.apply(music)
        check(paused.visibleTrack(enabled: true, hideWhenPaused: true) == nil
              && paused.visibleTrack(enabled: true, hideWhenPaused: false) == music
              && paused.visibleTrack(enabled: false, hideWhenPaused: false) == nil,
              "now playing: a paused track hides only when set to, and turned off shows nothing")
        check(paused.visibleTrack(enabled: true, hideWhenPaused: hidesPaused(setting: true, hovering: true, showing: true)) == music
              && paused.visibleTrack(enabled: true, hideWhenPaused: hidesPaused(setting: true, hovering: false, showing: true)) == nil
              && paused.visibleTrack(enabled: true, hideWhenPaused: hidesPaused(setting: true, hovering: true, showing: false)) == nil,
              "now playing: a paused track stays while the pointer is on it, hides when it leaves, and hovering doesn't bring it back")

        // The activity.
        let playing = activity(for: spotify, image: nil)
        check(playing.id.hasPrefix("nowplaying.") && playing.priority == .nowPlaying && playing.symbol == "music.note"
              && playing.accessory == .animatedSymbol("waveform") && playing.title == "Bohemian Rhapsody" && playing.subtitle == "Queen"
              && playing.actions.compactMap(\.symbol) == ["backward.fill", "playpause.fill", "forward.fill"]
              && playing.actions.allSatisfy { NowPlayingCommand(rawValue: $0.id) != nil },
              "now playing: the activity shows the track and three working control buttons")
        let pausedActivity = activity(for: music, image: nil)
        check(pausedActivity.accessory == .symbol("pause.fill") && pausedActivity.subtitle == "Massive Attack · Paused",
              "now playing: the paused state shows as paused")

        // Scripts never launch the app, and use each app's verbs.
        let next = NowPlayingScripts.command(.next, for: .spotify)
        check(next.hasPrefix("if application \"Spotify\" is running then") && next.contains("to next track")
              && NowPlayingScripts.command(.playPause, for: .music).contains("tell application \"Music\" to playpause")
              && NowPlayingPlayer.apps.allSatisfy { NowPlayingScripts.artwork(for: $0).hasPrefix("if application") },
              "now playing: scripts check the app is running and use its verbs")
        check(next.contains("return true") && next.hasSuffix("return false") && !next.contains("with timeout"),
              "now playing: a control says whether it sent anything, and waits on the Automation prompt")
        check(NowPlayingPlayer.apps.allSatisfy {
                  NowPlayingScripts.status(for: $0).contains("with timeout of \(NowPlayingScripts.replyTimeout) seconds")
                  && NowPlayingScripts.artwork(for: $0).contains("with timeout of \(NowPlayingScripts.replyTimeout) seconds")
              } && Double(NowPlayingScripts.replyTimeout) < NowPlayingScriptRunner.staleAfter,
              "now playing: status and art give up on a busy player before a waiting press goes stale")

        // AppleScript replies.
        let status = NSAppleEventDescriptor.list()
        for (i, item) in ["paused", "Teardrop", "Massive Attack", "Mezzanine", "fffffffffffffffe"].enumerated() {
            status.insert(NSAppleEventDescriptor(string: item), at: i + 1)
        }
        status.insert(NSAppleEventDescriptor(double: 330_000), at: 6)
        status.insert(NSAppleEventDescriptor(double: 4), at: 7)
        check(NowPlayingScripts.statusTrack(status, player: .music) == music
              && NowPlayingScripts.statusTrack(NSAppleEventDescriptor.list(), player: .spotify) == nil,
              "now playing: a status reply matches the notification; an empty one (not running) gives nothing")

        let spotifyArt = NSAppleEventDescriptor.list()
        spotifyArt.insert(NSAppleEventDescriptor(string: spotify.id), at: 1)
        spotifyArt.insert(NSAppleEventDescriptor(string: "http://i.scdn.co/image/ab67616d0000b273"), at: 2)
        let spotifyReply = NowPlayingScripts.artReply(spotifyArt, player: .spotify)
        check(spotifyReply?.belongs(to: spotify) == true && spotifyReply?.belongs(to: musicPlaying) == false
              && spotifyReply?.url?.absoluteString == "https://i.scdn.co/image/ab67616d0000b273",
              "now playing: Spotify's art reply names its track, and its cover URL is upgraded to HTTPS")
        check(NowPlayingArtwork.coverURL("file:///etc/hosts") == nil && NowPlayingArtwork.coverURL("") == nil
              && !NowPlayingArtwork.isFetchable(URL(string: "http://i.scdn.co/x")!),
              "now playing: only HTTPS cover URLs are downloaded")

        let png = samplePNG(width: 600)
        check(NowPlayingArtwork.thumbnail(png) != nil && NowPlayingArtwork.thumbnail(png, maxBytes: png.count - 1) == nil
              && NowPlayingArtwork.thumbnail(Data("not an image".utf8)) == nil
              && NowPlayingArtwork.maxRawBytes > NowPlayingArtwork.maxDownloadBytes,
              "now playing: covers over the size limit or not images are rejected; Music's own art may be bigger than a download")
        func isTransient(_ d: NowPlayingArtwork.Download) -> Bool { if case .transient = d { true } else { false } }
        func isNoArt(_ d: NowPlayingArtwork.Download) -> Bool { if case .noArt = d { true } else { false } }
        let gotImage = if case .image = NowPlayingArtwork.downloadResult(failed: false, status: 200, data: png) { true } else { false }
        check(gotImage
              && isTransient(NowPlayingArtwork.downloadResult(failed: true, status: 0, data: nil))
              && [408, 429, 500, 503].allSatisfy { isTransient(NowPlayingArtwork.downloadResult(failed: false, status: $0, data: nil)) }
              && [404, 403].allSatisfy { isNoArt(NowPlayingArtwork.downloadResult(failed: false, status: $0, data: png)) }
              && isNoArt(NowPlayingArtwork.downloadResult(failed: false, status: 200, data: Data("not an image".utf8))),
              "now playing: offline, timeouts and server errors are retried later; a missing cover or non-image is final")

        let musicArt = NSAppleEventDescriptor.list()
        musicArt.insert(NSAppleEventDescriptor(string: "Teardrop"), at: 1)
        if let raw = NSAppleEventDescriptor(descriptorType: DescType(0x7464_7461), data: png) {  // 'tdta'
            musicArt.insert(raw, at: 2)
        }
        let noArt = NSAppleEventDescriptor.list()
        noArt.insert(NSAppleEventDescriptor(string: "Teardrop"), at: 1)
        noArt.insert(NSAppleEventDescriptor(string: ""), at: 2)
        let musicReply = NowPlayingScripts.artReply(musicArt, player: .music)
        check(musicReply?.belongs(to: music) == true
              && (musicReply?.image.map { max($0.width, $0.height) <= NowPlayingArtwork.maxPixels } ?? false)
              && NowPlayingScripts.artReply(noArt, player: .music)?.image == nil,
              "now playing: Music's raw artwork is shrunk to notch size; a track without art gives none")

        check(NowPlayingConsent(status: OSStatus(noErr)) == .granted
              && NowPlayingConsent(status: OSStatus(errAEEventWouldRequireUserConsent)) == .undetermined
              && NowPlayingConsent(status: OSStatus(errAEEventNotPermitted)) == .denied,
              "now playing: macOS's permission answers are read correctly")

        // Art cache.
        var cache = NowPlayingCache<Int>(capacity: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        _ = cache.value(for: "a")
        cache.set(3, for: "c")
        check(cache.count == 2 && cache.value(for: "a") == 1 && cache.value(for: "b") == nil,
              "now playing: the art cache drops the least recently used cover")
    }

    /// A plain PNG, made in memory, for the artwork check.
    private static func samplePNG(width: Int) -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: width,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
