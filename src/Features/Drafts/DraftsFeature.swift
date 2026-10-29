import AppKit
import Combine
import os

/// The Drafts card on Home: how many `[!ASK]` boxes are open in your Markdown drafts, the
/// top 3 files, and a Quick Capture button.
///
/// Folders come from the `skimFolders` setting; when that's empty, from the folders you've
/// opened in skim lately (read from ~/.skim, never written). Scans run off the main thread
/// every 2 minutes and a couple of seconds after a Markdown file changes, re-reading only
/// changed files.
@MainActor
final class DraftsFeature: Feature {
    nonisolated static let log = Logger(subsystem: "local.dynamicnotch", category: "drafts")
    static let rescanInterval: TimeInterval = 120

    let model = DraftsModel()
    private let context: AppContext
    private let scanner = DraftsScanner()
    private var watcher: DraftsWatcher?
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var scanning = false
    private var rescanAfter = false
    private var folders: [String] = []
    private var bag = Set<AnyCancellable>()

    init(context: AppContext) {
        self.context = context
    }

    func start() {
        let model = self.model
        let actions = DraftsActions(
            open: { [weak self] file in self?.open(file) },
            capture: { CaptureFeature.present() },
            canCapture: { CaptureFeature.isAvailable })
        context.registerHomeCard { DraftsHomeCard(model: model, actions: actions) }

        watcher = DraftsWatcher { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.requestScan(after: 1) } }
        }
        // Fires now with the current folders, then whenever they change.
        context.model.$config
            .map(\.skimFolders)
            .removeDuplicates()
            .sink { [weak self] folders in
                MainActor.assumeIsolated {
                    self?.folders = folders
                    self?.requestScan(after: 0)
                }
            }
            .store(in: &bag)
        let timer = Timer(timeInterval: Self.rescanInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestScan(after: 0) }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        bag.removeAll()
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        watcher?.stop()
        watcher = nil
    }

    /// Coalesces requests; a request during a scan runs one more scan after it.
    private func requestScan(after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scan() {
        pending = nil
        guard !scanning else {
            rescanAfter = true
            return
        }
        scanning = true
        let configured = folders
        let scanner = self.scanner
        scanner.queue.async { [weak self] in
            let summary = scanner.scan(configured: configured)
            let skimState = summary.fromSkim ? DraftsDiscovery.stateDirectory.path : nil
            let watch = DraftsWatcher.folders(for: summary.roots, skimState: skimState)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finished(summary, watch: watch, skimState: skimState) }
            }
        }
    }

    /// Shows the result and moves the file watch when the folders changed.
    private func finished(_ summary: DraftsSummary, watch: [String], skimState: String?) {
        scanning = false
        if model.summary != summary { model.summary = summary }
        if let watcher, watcher.paths != watch {
            watcher.watch(watch, skimState: skimState)
            Self.log.info("watching \(summary.roots.count) drafts folder(s)\(summary.fromSkim ? " from skim" : "", privacy: .public)")
        }
        if rescanAfter {
            rescanAfter = false
            requestScan(after: 0)
        }
    }

    /// Opens the draft in its default app (skim is a per-folder server, not an app to hand
    /// a file to).
    private func open(_ file: DraftsFile) {
        guard FileManager.default.fileExists(atPath: file.path) else {
            NSSound.beep()
            requestScan(after: 0)
            return
        }
        NSWorkspace.shared.open(file.url)
        if !context.model.pinned { context.model.close() }
    }
}

/// The latest scan, for the card.
@MainActor
final class DraftsModel: ObservableObject {
    @Published var summary = DraftsSummary()
}

/// What the card's buttons do.
struct DraftsActions {
    var open: (DraftsFile) -> Void = { _ in }
    var capture: () -> Void = {}
    var canCapture: () -> Bool = { false }
}
