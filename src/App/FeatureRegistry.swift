import Foundation
import SwiftUI

/// Every feature, in start order. Each one registers its tab, Home card, hotkeys and
/// socket handlers in `start()`. Home cards appear in this order: Agents, System,
/// Calendar, Clipboard, Drafts. Shelf starts before Status, which hands it downloads.
@MainActor
enum FeatureRegistry {
    static func make(_ context: AppContext) -> [Feature] {
        [
            TerminalFeature(context: context),
            AgentsFeature(context: context),
            SystemFeature(context: context),
            CalendarFeature(context: context),
            ClipboardFeature(context: context),
            ShelfFeature(context: context),
            StatusFeature(context: context),
            NowPlayingFeature(context: context),
            PrompterFeature(context: context),
            CLIFeature(context: context),
            CaptureFeature(context: context),
            DraftsFeature(context: context),
        ]
    }

    /// Each feature's own checks, for `--selftest`.
    static func selfTests(_ check: (Bool, String) -> Void) {
        TerminalFeature.selfTest(check)
        AgentsFeature.selfTest(check)
        SystemFeature.selfTest(check)
        CalendarFeature.selfTest(check)
        ClipboardFeature.selfTest(check)
        ShelfFeature.selfTest(check)
        StatusFeature.selfTest(check)
        NowPlayingFeature.selfTest(check)
        PrompterFeature.selfTest(check)
        CLIFeature.selfTest(check)
        CaptureFeature.selfTest(check)
        DraftsFeature.selfTest(check)
    }

    /// Each feature's views with sample data, for `--snapshot`.
    static func snapshotViews() -> [(name: String, view: AnyView)] {
        TerminalFeature.snapshotViews() + AgentsFeature.snapshotViews() + SystemFeature.snapshotViews()
            + CalendarFeature.snapshotViews() + ClipboardFeature.snapshotViews() + ShelfFeature.snapshotViews()
            + StatusFeature.snapshotViews() + NowPlayingFeature.snapshotViews() + PrompterFeature.snapshotViews()
            + CLIFeature.snapshotViews() + CaptureFeature.snapshotViews() + DraftsFeature.snapshotViews()
    }
}
