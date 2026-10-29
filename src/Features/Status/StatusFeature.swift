import AppKit
import Combine
import SwiftUI
import os

enum StatusLog {
    static let log = Logger(subsystem: "local.dynamicnotch", category: "status")
}

/// Short system notices in the notch: Caps Lock, camera and microphone in use, unlocking,
/// and downloads. No tab and no Home card; everything is a live activity. Each part runs
/// only while its setting is on.
@MainActor
final class StatusFeature: Feature {
    private let context: AppContext
    private var activities: ActivityCenter { context.activities }
    private var config = Config()

    private var caps: StatusCapsLockWatcher?
    private var camera: StatusCameraWatcher?
    private var mic: StatusMicWatcher?
    private var downloads: StatusDownloadWatcher?
    /// The devices the privacy activity shows as in use, and their pending "stopped"
    /// changes (see `privacyChanged`).
    private var privacyInUse: Set<PrivacyDevice> = []
    private var offWork: [PrivacyDevice: DispatchWorkItem] = [:]
    private var locked = false
    private var displaysAsleep = false
    private var sessionInactive = false     // another user is on screen (fast user switching)
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private lazy var lockListener = StatusLockListener { [weak self] isLocked in
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.lockChanged(isLocked) }
        }
    }
    private var bag = Set<AnyCancellable>()

    private static let capsID = "status.capslock"
    private static let unlockID = "status.unlock"
    private static let downloadPrefix = "status.download."

    init(context: AppContext) {
        self.context = context
    }

    func start() {
        locked = Self.screenIsLocked()
        lockListener.start()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysChanged(asleep: true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysChanged(asleep: false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionChanged(active: false) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionChanged(active: true) }

        apply(context.config)
        // $config sends the new value before the model stores it; use the value sent.
        context.model.$config
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] config in MainActor.assumeIsolated { self?.apply(config) } }
            .store(in: &bag)
    }

    func stop() {
        bag.removeAll()
        lockListener.stop()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        caps?.stop()
        caps = nil
        camera?.stop()
        camera = nil
        mic?.stop()
        mic = nil
        downloads?.stop()
        downloads = nil
        for work in offWork.values { work.cancel() }
        offWork.removeAll()
        privacyInUse.removeAll()
        activities.removeAll(prefix: "status.")
    }

    /// Starts and stops each part to match the settings. Turning one off also takes its
    /// activity down.
    private func apply(_ config: Config) {
        self.config = config
        updateCapsPolling()
        if !config.capsLockHUD { activities.remove(id: Self.capsID) }
        if !config.lockNotice { activities.remove(id: Self.unlockID) }
        setCamera(config.cameraGuard)
        setMic(config.micGuard)
        setDownloads(config.downloads)
    }

    // MARK: Caps Lock, lock and unlock

    /// Polls only while it could show: the setting is on, the screen is unlocked, the
    /// displays are awake and this user is on screen. Resuming starts from a fresh baseline,
    /// so Caps Lock pressed on the lock screen doesn't flash after unlocking.
    private func updateCapsPolling() {
        let wanted = config.capsLockHUD && !locked && !displaysAsleep && !sessionInactive
        if wanted, caps == nil {
            let watcher = StatusCapsLockWatcher { [weak self] on in self?.capsChanged(on) }
            caps = watcher
            watcher.start()
        } else if !wanted, let watcher = caps {
            watcher.stop()
            caps = nil
        }
    }

    private func capsChanged(_ on: Bool) {
        guard config.capsLockHUD else { return }
        activities.post(Activity(id: Self.capsID, priority: .transient, symbol: on ? "capslock.fill" : "capslock",
                                 accessory: .text(on ? "On" : "Off"), title: on ? "Caps Lock on" : "Caps Lock off",
                                 duration: 2))
    }

    /// Unlocking always shows, even if the lock notice was missed; showing twice just
    /// replaces the activity.
    private func lockChanged(_ isLocked: Bool) {
        locked = isLocked
        updateCapsPolling()
        if isLocked {
            activities.remove(id: Self.capsID)
        } else if config.lockNotice {
            activities.post(Activity(id: Self.unlockID, priority: .transient, symbol: "lock.open.fill",
                                     title: "Unlocked", duration: 1.5))
        }
    }

    private func displaysChanged(asleep: Bool) {
        displaysAsleep = asleep
        updateCapsPolling()
    }

    private func sessionChanged(active: Bool) {
        sessionInactive = !active
        updateCapsPolling()
    }

    /// At launch from the login item the screen is normally unlocked, but a restart of the
    /// app while locked must not show "Unlocked" until it really is.
    private static func screenIsLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return (info["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    // MARK: Camera and microphone

    private enum PrivacyDevice { case camera, mic }

    private func setCamera(_ on: Bool) {
        if on, camera == nil {
            let watcher = StatusCameraWatcher { [weak self] watcher, inUse in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.camera === watcher else { return }
                        self.privacyChanged(.camera, inUse: inUse)
                    }
                }
            }
            camera = watcher
            watcher.start()
        } else if !on, let watcher = camera {
            watcher.stop()
            camera = nil
            clearPrivacy(.camera)
        }
    }

    private func setMic(_ on: Bool) {
        if on, mic == nil {
            let watcher = StatusMicWatcher { [weak self] watcher, inUse in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.mic === watcher else { return }
                        self.privacyChanged(.mic, inUse: inUse)
                    }
                }
            }
            mic = watcher
            watcher.start()
        } else if !on, let watcher = mic {
            watcher.stop()
            mic = nil
            clearPrivacy(.mic)
        }
    }

    /// A device shows at once and counts as stopped a second after it stops, because an app
    /// switching cameras or restarting a call stops one just before the next starts.
    private func privacyChanged(_ device: PrivacyDevice, inUse: Bool) {
        offWork[device]?.cancel()
        offWork[device] = nil
        if inUse {
            privacyInUse.insert(device)
            refreshPrivacy()
        } else if privacyInUse.contains(device) {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.offWork[device] = nil
                    self.privacyInUse.remove(device)
                    self.refreshPrivacy()
                }
            }
            offWork[device] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
    }

    /// Its setting was turned off: drops that device only, so the other one keeps showing.
    private func clearPrivacy(_ device: PrivacyDevice) {
        offWork[device]?.cancel()
        offWork[device] = nil
        privacyInUse.remove(device)
        refreshPrivacy()
    }

    /// Camera and mic share one activity (see `StatusPrivacy`). A change while it shows is
    /// made in place, so it keeps its place among other privacy activities.
    private func refreshPrivacy() {
        let id = StatusPrivacy.id
        guard let next = StatusPrivacy.activity(camera: privacyInUse.contains(.camera),
                                                mic: privacyInUse.contains(.mic)) else {
            activities.remove(id: id)
            return
        }
        guard let shown = activities.activity(id: id) else {
            activities.post(next)
            return
        }
        guard shown.symbol != next.symbol || shown.tint != next.tint || shown.title != next.title
                || shown.accessory != next.accessory else { return }
        activities.update(id: id) {
            $0.symbol = next.symbol
            $0.tint = next.tint
            $0.title = next.title
            $0.accessory = next.accessory
        }
    }

    // MARK: Downloads

    private func setDownloads(_ on: Bool) {
        if on, downloads == nil {
            guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
            let watcher = StatusDownloadWatcher(folder: folder) { [weak self] watcher, events in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.downloads === watcher else { return }
                        for event in events { self.downloadEvent(event, folder: watcher.folder) }
                    }
                }
            }
            downloads = watcher
            watcher.start()
        } else if !on, let watcher = downloads {
            watcher.stop()
            downloads = nil
            activities.removeAll(prefix: Self.downloadPrefix)
        }
    }

    private func downloadEvent(_ event: StatusDownloadEvent, folder: URL) {
        switch event {
        case let .progress(name, bytes, total, rate):
            let id = Self.downloadPrefix + name
            let fraction = StatusDownloadEntry.fraction(bytes: bytes, total: total)
            let accessory: ActivityAccessory = fraction.map { .progress($0) } ?? .text(StatusDownloadText.bytes(bytes))
            let subtitle = StatusDownloadText.subtitle(bytes: bytes, total: total, bytesPerSecond: rate)
            if let shown = activities.activity(id: id), shown.duration == nil {
                activities.update(id: id) {
                    $0.accessory = accessory
                    $0.subtitle = subtitle
                }
            } else {
                activities.post(Activity(id: id, priority: .info, symbol: "arrow.down.circle.fill", tint: .blue,
                                         accessory: accessory, title: name, subtitle: subtitle))
            }
        case let .finished(name, bytes):
            postFinished(id: Self.downloadPrefix + name, name: name, bytes: bytes, folder: folder)
            StatusLog.log.info("download finished: \(name, privacy: .private)")
        case let .replaced(name, by, bytes):
            // Only while its done chip shows. Posted again, so the buttons and the drag act
            // on the new item and it gets its full time.
            let id = Self.downloadPrefix + name
            if activities.activity(id: id)?.duration != nil {
                postFinished(id: id, name: by, bytes: bytes, folder: folder)
            }
        case let .gone(name):
            let id = Self.downloadPrefix + name
            if activities.activity(id: id)?.duration != nil { activities.remove(id: id) }
        case let .ended(name):
            let id = Self.downloadPrefix + name
            if activities.activity(id: id)?.duration == nil { activities.remove(id: id) }
        }
    }

    /// The done chip. Open, Show and Shelf act on `name` in the folder, and the peek can be
    /// dragged out as that file (to the Shelf, Finder or Mail).
    private func postFinished(id: String, name: String, bytes: Int64, folder: URL) {
        let url = folder.appendingPathComponent(name)
        var actions = [ActivityAction(id: "open", title: "Open", style: .primary),
                       ActivityAction(id: "show", title: "Show")]
        if context.addToShelf != nil { actions.append(ActivityAction(id: "shelf", title: "Shelf")) }
        activities.post(Activity(id: id, priority: .info, symbol: "arrow.down.circle.fill", tint: .blue,
                                 accessory: .text("Done"), title: "Downloaded \(name)",
                                 subtitle: StatusDownloadText.bytes(bytes), fileURL: url, duration: 6,
                                 actions: actions)) {
            [weak self] action in self?.downloadAction(action, url: url, activityID: id)
        }
    }

    /// The file can be gone by the time a button is pressed (moved away, or an archive
    /// Safari opened and trashed): then the Downloads folder opens instead, and nothing
    /// goes to the Shelf.
    private func downloadAction(_ action: String, url: URL, activityID: String) {
        if FileManager.default.fileExists(atPath: url.path) {
            switch action {
            case "open": NSWorkspace.shared.open(url)
            case "show": NSWorkspace.shared.activateFileViewerSelecting([url])
            case "shelf": context.addToShelf?([url])
            default: break
            }
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
        activities.remove(id: activityID)
    }

    // MARK: Helpers

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping (StatusFeature) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }
}

/// Receives the screen lock and unlock notifications. Registered to deliver immediately:
/// AppKit holds distributed notifications back while an app is inactive, and this menu
/// bar app almost always is.
private final class StatusLockListener: NSObject {
    private static let locked = Notification.Name("com.apple.screenIsLocked")
    private static let unlocked = Notification.Name("com.apple.screenIsUnlocked")
    private let onChange: @Sendable (_ isLocked: Bool) -> Void

    init(onChange: @escaping @Sendable (_ isLocked: Bool) -> Void) {
        self.onChange = onChange
        super.init()
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        for name in [Self.locked, Self.unlocked] {
            center.addObserver(self, selector: #selector(received(_:)), name: name,
                               object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func received(_ note: Notification) {
        onChange(note.name == Self.locked)
    }
}

// MARK: Self-test and snapshots

extension StatusFeature {
    /// Pure-logic checks: download bookkeeping, Safari's plist, Caps Lock changes, file names.
    @MainActor static func selfTest(_ check: (Bool, String) -> Void) {
        // Caps Lock.
        var caps = StatusCapsLockDetector()
        check(caps.sample(true) == nil, "status: the first Caps Lock reading shows nothing (launch)")
        check(caps.sample(true) == nil && caps.sample(false) == false && caps.sample(true) == true,
              "status: Caps Lock shows each change, and only changes")
        caps.reset()
        check(caps.sample(false) == nil, "status: after a pause the first Caps Lock reading is a new baseline")

        // File names.
        let chrome = StatusDownloadFile.classify(name: "SwiftTerm.zip.crdownload", isDirectory: false)
        check(chrome?.kind == .chrome && chrome?.finalName == "SwiftTerm.zip", "status: .crdownload is a Chrome partial")
        let firefox = StatusDownloadFile.classify(name: "ubuntu.iso.part", isDirectory: false)
        check(firefox?.kind == .firefox && firefox?.finalName == "ubuntu.iso", "status: .part is a Firefox partial")
        let safari = StatusDownloadFile.classify(name: "paper.pdf.download", isDirectory: true)
        check(safari?.kind == .safari && safari?.finalName == "paper.pdf"
              && StatusDownloadFile.classify(name: "notes.download", isDirectory: false) == nil,
              "status: only a .download folder is a Safari partial")
        check(StatusDownloadFile.classify(name: "photo.jpg", isDirectory: false) == nil
              && StatusDownloadFile.classify(name: ".x.crdownload", isDirectory: false) == nil
              && StatusDownloadFile.classify(name: ".part", isDirectory: false) == nil
              && StatusDownloadFile.classify(name: "build.part", isDirectory: true) == nil,
              "status: finished, hidden and nameless files aren't partials")
        check(StatusDownloadFile.isUnconfirmed("Unconfirmed 482913", kind: .chrome)
              && !StatusDownloadFile.isUnconfirmed("Unconfirmed notes", kind: .chrome),
              "status: Chrome's Unconfirmed placeholder is recognized")

        // Safari's Info.plist.
        let plist: [String: Any] = [StatusSafariDownload.bytesKey: 2_500_000, StatusSafariDownload.totalKey: 10_000_000,
                                    "DownloadEntryURL": "https://example.com/paper.pdf"]
        check(StatusSafariDownload.progress(plist: plist) == StatusSafariDownload.Progress(bytes: 2_500_000, total: 10_000_000),
              "status: Safari progress is read from the plist")
        let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        check(data.flatMap(StatusSafariDownload.progress(data:))?.total == 10_000_000, "status: a binary Info.plist parses")
        check(StatusSafariDownload.progress(plist: [StatusSafariDownload.bytesKey: 5.0, StatusSafariDownload.totalKey: -1])
              == StatusSafariDownload.Progress(bytes: 5, total: nil)
              && StatusSafariDownload.progress(plist: ["DownloadEntryURL": "x"]) == nil
              && StatusSafariDownload.progress(data: Data("not a plist".utf8)) == nil,
              "status: an unknown total, missing keys and garbage are handled")

        // Download bookkeeping, partial path. `files` is the fake folder's finished files.
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        func partial(_ name: String, _ bytes: Int64, _ total: Int64? = nil) -> StatusDownloadEntry {
            let c = StatusDownloadFile.classify(name: name, isDirectory: name.hasSuffix(".download"))
            return StatusDownloadEntry(name: name, finalName: c?.finalName ?? name, kind: c?.kind ?? .chrome,
                                       bytes: bytes, total: total)
        }
        func file(_ size: Int64, markedAt: Date? = nil) -> StatusDownloadFileInfo {
            StatusDownloadFileInfo(size: size, quarantine: markedAt.map {
                "0083;\(String(Int($0.timeIntervalSince1970), radix: 16));Google Chrome;"
            })
        }
        var files: [String: StatusDownloadFileInfo] = ["old.zip": file(10)]
        var tracker = StatusDownloadTracker()
        func step(_ partials: [StatusDownloadEntry], _ s: TimeInterval) -> [StatusDownloadEvent] {
            tracker.update(partials, names: Set(files.keys).union(partials.map(\.name)), now: at(s), info: { files[$0] })
        }
        let stale = partial("stale.zip.crdownload", 10)
        check(step([stale], 0).isEmpty && tracker.pollInterval(now: at(0)) == nil,
              "status: partials present at launch are ignored")

        var events = step([stale, partial("a.zip.crdownload", 100)], 1)
        check(events == [.progress(name: "a.zip", bytes: 100, total: nil, bytesPerSecond: nil)]
              && tracker.pollInterval(now: at(1)) == 1, "status: a new partial starts a download, polled every second")
        events = step([stale, partial("a.zip.crdownload", 300)], 2)
        check(events == [.progress(name: "a.zip", bytes: 300, total: nil, bytesPerSecond: 200)], "status: progress carries the speed")
        files["a.zip"] = file(300, markedAt: at(1))
        events = step([stale], 3)
        check(events == [.finished(name: "a.zip", bytes: 300)], "status: a partial replaced by its file is finished, once")
        check(step([stale], 4).isEmpty && tracker.pollInterval(now: at(4)) == 1,
              "status: a finished download's file is watched a little longer")
        let watched = 3 + StatusDownloadTracker.watchFinished
        check(step([stale], watched).isEmpty && tracker.pollInterval(now: at(watched)) == nil,
              "status: polling stops when nothing is downloading or watched")

        _ = step([stale, partial("b.dmg.part", 50)], 15)
        check(step([stale], 16).isEmpty, "status: a vanished partial waits for its file")
        check(step([stale], 16 + StatusDownloadTracker.grace) == [.ended(name: "b.dmg")], "status: a partial gone without a file was cancelled")

        _ = step([stale, partial("paper.pdf.download", 400, 1000)], 25)
        _ = step([stale], 26)
        files["paper.pdf"] = file(1000, markedAt: at(24))
        check(step([stale], 27) == [.finished(name: "paper.pdf", bytes: 1000)],
              "status: a file that lands just after its partial goes still finishes the download")

        files["ubuntu.iso"] = file(0)                              // Firefox's empty placeholder
        _ = step([stale, partial("ubuntu.iso.part", 500)], 30)
        check(step([stale], 31).isEmpty, "status: Firefox's empty placeholder doesn't count as finished")
        files["ubuntu.iso"] = file(900, markedAt: at(30))
        check(step([stale], 32) == [.finished(name: "ubuntu.iso", bytes: 900)], "status: Firefox's download finishes when the data lands")

        _ = step([stale, partial("big.zip.crdownload", 10)], 40)
        events = step([stale, partial("big.zip.crdownload", 10)], 40 + StatusDownloadTracker.stallAfter)
        check(events == [.ended(name: "big.zip")] && tracker.pollInterval(now: at(101)) == 15,
              "status: a stalled download is taken down and checked less often")
        events = step([stale, partial("big.zip.crdownload", 20)], 110)
        check(events == [.progress(name: "big.zip", bytes: 20, total: nil, bytesPerSecond: nil)], "status: a resumed download shows again")

        check(step([partial("big.zip.crdownload", 20), partial("Unconfirmed 4821.crdownload", 5)], 111).isEmpty,
              "status: Chrome's Unconfirmed placeholder isn't shown")
        events = step([stale, partial("big.zip.crdownload", 20)], 112)
        check(events.first == .progress(name: "stale.zip", bytes: 10, total: nil, bytesPerSecond: nil),
              "status: a launch-time partial that goes and comes back counts as new")

        // Safari opens an archive and trashes it before the archive is ever seen finished.
        let big = partial("big.zip.crdownload", 20)
        _ = step([stale, big, partial("site.zip.download", 300, 1000)], 120)
        var site = file(160, markedAt: at(119))
        site.isDirectory = true
        files["site"] = site
        check(step([stale, big], 121) == [.ended(name: "site.zip"), .finished(name: "site", bytes: 1000)]
              && step([stale, big], 122).isEmpty,
              "status: a Safari archive trashed unseen finishes as the folder it unpacked into")

        // Download bookkeeping, downloads too quick to be seen as partial.
        var folder: [String: StatusDownloadFileInfo] = ["old.pdf": file(5, markedAt: at(-86_400))]
        var quick = StatusDownloadTracker()
        func look(_ s: TimeInterval) -> [StatusDownloadEvent] {
            quick.update([], names: Set(folder.keys), now: at(s), info: { folder[$0] })
        }
        _ = look(0)
        folder["report.pdf"] = file(2000, markedAt: at(0))
        folder["curl.out"] = file(10)
        folder["moved.zip"] = file(10, markedAt: at(-86_400))
        check(look(1).isEmpty && look(2) == [.finished(name: "report.pdf", bytes: 2000)],
              "status: a quick download shows once its size holds between two looks")
        check(look(5).isEmpty && look(12).isEmpty && quick.pollInterval(now: at(12)) == nil,
              "status: new files without a fresh quarantine mark (curl, moved in) are ignored")
        folder["airdrop.mov"] = file(100, markedAt: at(13))
        _ = look(13)
        folder["airdrop.mov"] = file(200, markedAt: at(13))
        check(look(14).isEmpty && look(15) == [.finished(name: "airdrop.mov", bytes: 200)],
              "status: a file still being written waits until its size settles")

        // Archives Safari opens right away, and files that go.
        folder["photos.zip"] = file(5000, markedAt: at(15))
        _ = look(16)
        _ = look(17)                                                // finished
        var unpacked = file(160, markedAt: at(15))
        unpacked.isDirectory = true
        folder["photos"] = unpacked
        check(look(18).isEmpty, "status: a folder unpacked from a fresh download isn't a second download")
        folder["photos.zip"] = nil                                  // trashed once unpacked
        check(look(19) == [.replaced(name: "photos.zip", by: "photos", bytes: 5000)],
              "status: when an opened archive goes, the folder it unpacked into takes its place")
        folder["paper.zip"] = file(800, markedAt: at(19))
        _ = look(20)
        _ = look(21)
        folder["paper.zip"] = nil
        folder["paper.pdf"] = file(1200, markedAt: at(19))
        check(look(22) == [.replaced(name: "paper.zip", by: "paper.pdf", bytes: 1200)] && look(23).isEmpty,
              "status: a single file unpacked from an archive takes its place instead of showing twice")
        folder["notes.txt"] = file(50, markedAt: at(23))
        _ = look(24)
        _ = look(25)
        folder["notes.txt"] = nil                                   // moved away
        let gone = 26 + StatusDownloadTracker.goneAfter
        check(look(26).isEmpty && look(gone) == [.gone(name: "notes.txt")] && quick.pollInterval(now: at(gone)) == nil,
              "status: a finished file that goes with nothing in its place takes its chip down")
        check(StatusQuarantine.date("0083;6543abcd;Safari;F1A2") == Date(timeIntervalSince1970: 0x6543abcd)
              && StatusQuarantine.date("garbage") == nil, "status: the quarantine mark's date is read")

        // Camera and microphone.
        let camera = StatusPrivacy.activity(camera: true, mic: false)
        let both = StatusPrivacy.activity(camera: true, mic: true)
        let micOnly = StatusPrivacy.activity(camera: false, mic: true)
        check(StatusPrivacy.activity(camera: false, mic: false) == nil
              && [camera, both, micOnly].allSatisfy { $0?.id == StatusPrivacy.id && $0?.priority == .privacy },
              "status: camera and mic share one privacy activity, gone when neither is on")
        check(camera?.tint == .green && camera?.symbol == "video.fill" && camera?.accessory == .text("On"),
              "status: the camera alone shows green")
        check(both?.tint == .green && both?.symbol == "video.fill" && both?.accessory == .symbol("mic.fill"),
              "status: camera and mic show green, with the mic in the right ear")
        check(micOnly?.tint == .orange && micOnly?.symbol == "mic.fill" && micOnly?.accessory == .text("On"),
              "status: the mic alone shows orange")
        check(StatusMicDecision.inUse(inputOnlyRunning: true, sharedRunning: false, processInput: nil)
              && !StatusMicDecision.inUse(inputOnlyRunning: false, sharedRunning: true, processInput: false)
              && StatusMicDecision.inUse(inputOnlyRunning: false, sharedRunning: true, processInput: nil)
              && !StatusMicDecision.inUse(inputOnlyRunning: false, sharedRunning: false, processInput: nil),
              "status: headphones playing music don't count as the mic being on")

        // Text.
        let text = StatusDownloadText.subtitle(bytes: 1_200_000, total: 4_000_000, bytesPerSecond: 500_000)
        check(text.contains(" of ") && text.hasSuffix("/s")
              && !StatusDownloadText.subtitle(bytes: 1, total: nil, bytesPerSecond: nil).contains(" of "),
              "status: download subtitles show size, total and speed")
    }

    /// No views of its own: everything shows as activities.
    @MainActor static func snapshotViews() -> [(name: String, view: AnyView)] { [] }
}
