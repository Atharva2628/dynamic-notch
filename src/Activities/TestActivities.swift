import Foundation

/// Sample activities, one per priority, for the menu bar's Test Activities menu and the
/// snapshots. Real sources replace them milestone by milestone.
enum TestActivities {
    struct Sample {
        let menuTitle: String
        let activity: Activity
    }

    static let all: [Sample] = [
        Sample(menuTitle: "Claude Permission Request", activity: Activity(
            id: "test.permission", priority: .permission, symbol: "hand.raised.fill", tint: .orange,
            accessory: .text("Allow?"), title: "Bash wants to run: rm -rf build",
            subtitle: "tools-and-optimizations", urgent: true)),
        Sample(menuTitle: "Camera On", activity: Activity(
            id: "test.camera", priority: .privacy, symbol: "video.fill", tint: .green,
            accessory: .text("On"), title: "Camera is on")),
        Sample(menuTitle: "Meeting in 5 Minutes", activity: Activity(
            id: "test.meeting", priority: .alert, symbol: "calendar", tint: .red,
            accessory: .text("5 min"), title: "Design review", subtitle: "Starts in 5 min · Zoom",
            urgent: true)),
        Sample(menuTitle: "Claude Finished (6 s)", activity: Activity(
            id: "test.agent", priority: .agent, symbol: "sparkles", tint: .purple,
            accessory: .text("Done"), title: "Claude finished", subtitle: "dynamic-notch",
            duration: 6)),
        Sample(menuTitle: "Download Done (6 s)", activity: Activity(
            id: "test.download", priority: .info, symbol: "arrow.down.circle.fill", tint: .blue,
            accessory: .text("Done"), title: "SwiftTerm.zip", subtitle: "Downloads", duration: 6)),
        Sample(menuTitle: "Caps Lock (2 s)", activity: Activity(
            id: "test.capslock", priority: .transient, symbol: "capslock.fill",
            accessory: .text("On"), title: "Caps Lock on", duration: 2)),
        Sample(menuTitle: "Now Playing", activity: Activity(
            id: "test.music", priority: .nowPlaying, symbol: "music.note", tint: .green,
            accessory: .symbol("waveform"), title: "Song title", subtitle: "Artist")),
    ]

    static func sample(_ id: String) -> Activity? {
        all.first { $0.activity.id == id }?.activity
    }
}
