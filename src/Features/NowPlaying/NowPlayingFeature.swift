import AppKit
import Combine
import SwiftUI
import os

/// Shows what's playing in the collapsed notch, with album art and previous / play-pause /
/// next buttons in the peek: Spotify, Music, or any other app or browser tab (YouTube, Suno),
/// which comes from macOS's own Now Playing through `NowPlayingSystemSource`, with its
/// cover and controls, and needs no permission.
///
/// Spotify and Music track info comes from the players' own distributed notifications,
/// which need no permission. Their controls and album art use AppleScript, which needs
/// Automation permission per app. So that the Automation prompt never appears unprompted (at launch or on a
/// track change), AppleScript runs only:
/// - when you press a control: the prompt, if any, follows your click; or
/// - when macOS reports, without asking, that permission was already granted
///   (`AEDeterminePermissionToAutomateTarget` with "ask" off).
/// Album art waits for one of those. Until you first use a control, or if you deny it,
/// the left ear shows a music note instead of the cover. With permission already granted,
/// a player that was playing before this app started shows at once; otherwise it shows
/// from its next track or play/pause change.
///
/// With "hide when paused" on, a paused track that is showing stays while the pointer is
/// on the notch, so Pause pressed in the peek leaves Play under the pointer; it hides once
/// the pointer leaves.
@MainActor
final class NowPlayingFeature: Feature {
    static let activityID = "nowplaying.track"
    private static let deniedID = "nowplaying.denied"
    private static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    /// Seconds before the one retry of a cover that failed in a way that may pass (offline, a busy player).
    private static let artRetryDelay: TimeInterval = 30

    private struct Settings: Equatable {
        var enabled: Bool
        var hideWhenPaused: Bool

        init(_ config: Config) {
            enabled = config.nowPlaying
            hideWhenPaused = config.nowPlayingHideWhenPaused
        }
    }

    /// A cached cover, or a known lack of one (so it isn't fetched again).
    private enum Art {
        case image(NSImage)
        case none
    }

    private let context: AppContext
    private let log = Logger(subsystem: "local.dynamicnotch", category: "nowplaying")
    private let runner = NowPlayingScriptRunner()
    private var listener: NowPlayingListener?
    private var system: NowPlayingSystemSource?
    private var quitObserver: NSObjectProtocol?
    private var configSubscription: AnyCancellable?
    private var hoverSubscription: AnyCancellable?
    private var hoveringNow = false                                // the pointer is on the notch
    private var settings: Settings
    private var state = NowPlayingState()
    private var shownKey: String? {                                // track key of the posted activity
        didSet {
            let key = shownKey
            if key != oldValue { queuedKey.withLock { $0 = key } }
        }
    }
    /// `shownKey` for the script queue, so an art script for a track that's gone is skipped.
    private let queuedKey = OSAllocatedUnfairLock<String?>(initialState: nil)
    private var art = NowPlayingCache<Art>(capacity: 40)           // by track key, and "url:" + cover URL
    private var artLoading: Set<String> = []
    private var artMismatched: Set<String> = []                    // shown tracks whose art reply named another track once
    private var artRetried: String?                                // track key whose one delayed art retry was scheduled
    private var scriptable: Set<NowPlayingPlayer> = []             // AppleScript known to work
    private var consentChecked: [NowPlayingPlayer: String] = [:]   // track key last checked without prompting

    init(context: AppContext) {
        self.context = context
        settings = Settings(context.config)
    }

    func start() {
        settings = Settings(context.config)
        // $config fires before the model's value changes, so the new value is passed along.
        configSubscription = context.model.$config
            .map(Settings.init)
            .removeDuplicates()
            .sink { [weak self] new in MainActor.assumeIsolated { self?.settingsChanged(new) } }
        // Like $config, $hovering fires before the value changes, so the sink uses the value it's given.
        hoveringNow = context.model.hovering
        hoverSubscription = context.model.$hovering
            .removeDuplicates()
            .sink { [weak self] hovering in MainActor.assumeIsolated { self?.hoverChanged(hovering) } }

        let listener = NowPlayingListener { [weak self] track in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(track) } }
        }
        listener.start()
        self.listener = listener
        let system = NowPlayingSystemSource { [weak self] track, art in self?.receiveSystem(track, art: art) }
        self.system = system
        if settings.enabled { system.start() }

        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let player = NowPlayingPlayer(bundleID: app?.bundleIdentifier) else { return }
            MainActor.assumeIsolated { self?.playerQuit(player) }
        }

        if settings.enabled { primeFromRunningPlayers() }
    }

    func stop() {
        listener?.stop()
        listener = nil
        system?.stop()
        system = nil
        if let quitObserver { NSWorkspace.shared.notificationCenter.removeObserver(quitObserver) }
        quitObserver = nil
        configSubscription = nil
        hoverSubscription = nil
        context.activities.removeAll(prefix: "nowplaying.")
        shownKey = nil
    }

    // MARK: Updates

    private func receive(_ track: NowPlayingTrack) {
        state.apply(track)
        render()
    }

    /// A line from macOS's Now Playing: its cover comes along, so it's cached before the
    /// track renders. Nil: nothing else is playing (or it's Spotify or Music, shown on their own).
    private func receiveSystem(_ track: NowPlayingTrack?, art: CGImage?) {
        guard let track else {
            if state.tracks[.system] != nil { playerQuit(.system) }
            return
        }
        if let art { artArrived(.image(art), for: track.key) }
        receive(track)
    }

    /// Only a paused track's visibility depends on the pointer: leaving hides one held for it.
    private func hoverChanged(_ hovering: Bool) {
        hoveringNow = hovering
        if state.current?.state == .paused { render() }
    }

    private func playerQuit(_ player: NowPlayingPlayer) {
        state.forget(player)
        render()
    }

    private func settingsChanged(_ new: Settings) {
        guard new != settings else { return }
        let wasEnabled = settings.enabled
        settings = new
        guard new.enabled else {
            system?.stop()
            context.activities.removeAll(prefix: "nowplaying.")
            shownKey = nil
            return
        }
        system?.start()
        render()
        if !wasEnabled && state.current == nil { primeFromRunningPlayers() }
    }

    /// Posts, updates or removes the activity to match the state and settings.
    private func render() {
        let showing = context.activities.activity(id: Self.activityID) != nil
        let hide = Self.hidesPaused(setting: settings.hideWhenPaused, hovering: hoveringNow, showing: showing)
        guard let track = state.visibleTrack(enabled: settings.enabled, hideWhenPaused: hide) else {
            context.activities.remove(id: Self.activityID)
            shownKey = nil
            return
        }
        let activity = Self.activity(for: track, image: cachedImage(for: track.key))
        if shownKey == track.key, let existing = context.activities.activity(id: Self.activityID) {
            // Same track: change it in place, so it keeps its place and its button handler.
            var changed = existing
            changed.title = activity.title
            changed.subtitle = activity.subtitle
            changed.accessory = activity.accessory
            changed.tint = activity.tint
            changed.image = activity.image
            changed.actions = activity.actions
            if changed != existing { context.activities.update(id: Self.activityID) { $0 = changed } }
        } else {
            context.activities.post(activity) { [weak self] actionID in self?.perform(actionID) }
            shownKey = track.key
        }
        loadArtIfNeeded(for: track)
    }

    /// Whether a paused track hides. One already showing stays while the pointer is on the
    /// notch (so Play is still there after Pause), but hovering never brings a hidden one back.
    static func hidesPaused(setting: Bool, hovering: Bool, showing: Bool) -> Bool {
        setting && !(hovering && showing)
    }

    /// The activity for a track. Pure, so the self-test can check it.
    static func activity(for track: NowPlayingTrack, image: NSImage?) -> Activity {
        let paused = track.state != .playing
        var subtitle = !track.artist.isEmpty ? track.artist : !track.album.isEmpty ? track.album
            : track.title.isEmpty ? "" : track.source
        if paused { subtitle = subtitle.isEmpty ? "Paused" : "\(subtitle) · Paused" }
        return Activity(
            id: activityID, priority: .nowPlaying, symbol: "music.note", image: image,
            tint: track.player.tint, accessory: paused ? .symbol("pause.fill") : .animatedSymbol("waveform"),
            title: track.displayTitle, subtitle: subtitle.isEmpty ? nil : subtitle,
            actions: NowPlayingCommand.allCases.map { ActivityAction(id: $0.rawValue, title: $0.title, symbol: $0.symbol) })
    }

    // MARK: Controls

    /// Sends a button's command to the app that sent the shown track, if it's still running.
    private func perform(_ actionID: String) {
        if actionID == "automation" {
            if let url = Self.automationSettings { NSWorkspace.shared.open(url) }
            context.activities.remove(id: Self.deniedID)
            return
        }
        guard let command = NowPlayingCommand(rawValue: actionID), let player = state.controlTarget else { return }
        if player == .system {
            system?.send(command)
            return
        }
        guard Self.isRunning(player) else {
            // Never launch it; it quit without telling us.
            playerQuit(player)
            return
        }
        runner.runCommand(NowPlayingScripts.command(command, for: player), parse: { $0.booleanValue }) { [weak self] outcome in
            self?.commandFinished(outcome, command: command, player: player)
        }
    }

    private func commandFinished(_ outcome: NowPlayingScriptOutcome<Bool>, command: NowPlayingCommand, player: NowPlayingPlayer) {
        switch outcome {
        case .success(let sent?) where sent:
            context.activities.remove(id: Self.deniedID)
            // Confirm without prompting before art relies on it, as everywhere else.
            runner.checkConsent(player) { [weak self] consent in
                guard consent == .granted else { return }
                self?.becameScriptable(player)
            }
        case .success:
            // Nothing was sent, so nothing was learned about permission: the player quit.
            playerQuit(player)
        case .failure(let code):
            log.error("\(player.appName, privacy: .public) \(command.verb, privacy: .public) failed: \(code)")
            if code == NowPlayingScripts.notPermitted {
                scriptable.remove(player)
                showDenied(player)
            }
        }
    }

    private func showDenied(_ player: NowPlayingPlayer) {
        let hint = Activity(
            id: Self.deniedID, priority: .info, symbol: "lock.fill", tint: .orange,
            accessory: .text("Denied"), title: "Can't control \(player.appName)",
            subtitle: "Allow it in Privacy & Security, Automation", duration: 6,
            actions: [ActivityAction(id: "automation", title: "Open Settings")])
        context.activities.post(hint) { [weak self] actionID in self?.perform(actionID) }
    }

    private static func isRunning(_ player: NowPlayingPlayer) -> Bool {
        guard let bundleID = player.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: AppleScript permission and startup

    /// AppleScript to `player` works, so art can be fetched for the shown track.
    private func becameScriptable(_ player: NowPlayingPlayer) {
        scriptable.insert(player)
        if let track = state.current, track.player == player, shownKey == track.key { loadArtIfNeeded(for: track) }
    }

    /// A player that was already playing when this app started sends nothing until its next
    /// change. If AppleScript to it was allowed earlier, ask it directly; never prompt.
    private func primeFromRunningPlayers() {
        for player in NowPlayingPlayer.apps where Self.isRunning(player) {
            runner.checkConsent(player) { [weak self] consent in
                guard consent == .granted else { return }
                self?.prime(player)
            }
        }
    }

    private func prime(_ player: NowPlayingPlayer) {
        runner.run(NowPlayingScripts.status(for: player),
                   parse: { NowPlayingScripts.statusTrack($0, player: player) }) { [weak self] outcome in
            guard let self, case .success(let track) = outcome else { return }
            self.scriptable.insert(player)
            // A notification that arrived meanwhile is newer; keep it.
            if let track, self.state.tracks[player] == nil {
                self.receive(track)
            } else {
                self.becameScriptable(player)
            }
        }
    }

    // MARK: Album art

    private func cachedImage(for key: String) -> NSImage? {
        if case .image(let image)? = art.value(for: key) { return image }
        return nil
    }

    /// Fetches the cover for the shown track once AppleScript to its app is known to work.
    /// Before that, checks (without prompting) at most once per track whether it already is.
    private func loadArtIfNeeded(for track: NowPlayingTrack) {
        let player = track.player
        // The system's covers come with its tracks (`receiveSystem`).
        guard settings.enabled, player != .system, art.value(for: track.key) == nil,
              !artLoading.contains(track.key) else { return }
        guard scriptable.contains(player) else {
            guard consentChecked[player] != track.key else { return }
            consentChecked[player] = track.key
            runner.checkConsent(player) { [weak self] consent in
                guard consent == .granted else { return }
                self?.becameScriptable(player)
            }
            return
        }
        guard Self.isRunning(player) else { return }
        let key = track.key
        artLoading.insert(key)
        runner.run(NowPlayingScripts.artwork(for: player),
                   unwanted: { [queuedKey] in queuedKey.withLock { $0 } != key },
                   parse: { NowPlayingScripts.artReply($0, player: player) }) { [weak self] outcome in
            self?.artReplied(outcome, for: track)
        }
    }

    /// Script failures aren't cached: a timeout, a track change mid-script (-1728) or a race
    /// with the app quitting (-600) may not happen again, so the track keeps a chance at art.
    private func artReplied(_ outcome: NowPlayingScriptOutcome<NowPlayingArtReply>, for track: NowPlayingTrack) {
        let key = track.key
        switch outcome {
        case .failure(let code):
            artLoading.remove(key)
            if code == NowPlayingScripts.notPermitted {
                scriptable.remove(track.player)
            } else if code != NowPlayingScripts.skipped {
                log.info("no art from \(track.player.appName, privacy: .public): \(code)")
                retryArtLater(key)
            }
        case .success(let reply):
            guard let reply, reply.belongs(to: track) else {
                // The app moved on to another track; that track's own update fetches its art.
                // Once is usually a race (Next pressed before its update arrived), so this
                // track keeps a chance at art; a shown track that mismatches twice is given
                // up on, so a reply that never matches can't refetch on every update.
                artLoading.remove(key)
                if reply == nil || (shownKey == key && !artMismatched.insert(key).inserted) {
                    artMismatched.remove(key)
                    art.set(.none, for: key)
                }
                return
            }
            artMismatched.remove(key)
            if let image = reply.image {
                artArrived(.image(image), for: key)
            } else if let url = reply.url, NowPlayingArtwork.isFetchable(url) {
                let urlKey = "url:" + url.absoluteString
                if case .image(let image)? = art.value(for: urlKey) {
                    artLoading.remove(key)
                    art.set(.image(image), for: key)
                    if shownKey == key { render() }
                    return
                }
                NowPlayingArtwork.download(url) { [weak self] result in
                    self?.artArrived(result, for: key, urlKey: urlKey)
                }
            } else {
                artLoading.remove(key)
                art.set(.none, for: key)
            }
        }
    }

    /// Caches the cover, or "no art" only for a definite answer; a transient failure stays
    /// uncached and is tried once more later.
    private func artArrived(_ result: NowPlayingArtwork.Download, for key: String, urlKey: String? = nil) {
        artLoading.remove(key)
        switch result {
        case .noArt:
            art.set(.none, for: key)
        case .transient:
            retryArtLater(key)
        case .image(let cgImage):
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
            art.set(.image(image), for: key)
            if let urlKey { art.set(.image(image), for: urlKey) }
            if shownKey == key { render() }
        }
    }

    /// Tries the shown track's art once more after a failure that may pass, such as being
    /// offline. Once per track, so a failure that doesn't pass can't loop; the track's own
    /// updates still try again.
    private func retryArtLater(_ key: String) {
        guard artRetried != key else { return }
        artRetried = key
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.artRetryDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shownKey == key, let track = self.state.current, track.key == key else { return }
                self.loadArtIfNeeded(for: track)
            }
        }
    }

    // MARK: Snapshots

    /// No tab and no Home card: everything shows through the activity.
    static func snapshotViews() -> [(name: String, view: AnyView)] { [] }
}

/// Receives the players' distributed notifications. Registered to deliver immediately:
/// AppKit holds distributed notifications back while an app is inactive, and this
/// menu bar app almost always is.
private final class NowPlayingListener: NSObject {
    private let onTrack: @Sendable (NowPlayingTrack) -> Void

    init(onTrack: @escaping @Sendable (NowPlayingTrack) -> Void) {
        self.onTrack = onTrack
        super.init()
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        for name in NowPlayingPlayer.apps.compactMap(\.notification) {
            center.addObserver(self, selector: #selector(received(_:)), name: name,
                               object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func received(_ note: Notification) {
        guard let player = NowPlayingPlayer(notification: note.name),
              let track = NowPlayingTrack.parse(player: player, userInfo: note.userInfo ?? [:]) else { return }
        onTrack(track)
    }
}
