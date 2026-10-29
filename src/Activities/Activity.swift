import SwiftUI

/// How important a live activity is; lower comes first. The order is the spec's.
enum ActivityPriority: Int, Comparable, CaseIterable {
    case permission = 1   // Claude permission request
    case privacy          // camera or microphone on
    case alert            // meeting soon; battery, memory, disk or heat
    case agent            // Claude needs input, or finished
    case info             // download finished, prompter running, `notch` messages
    case transient        // Caps Lock, lock and unlock
    case nowPlaying
    case ambient          // stats in the ears: shows only when nothing else does

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

enum ActivityTint: String {
    case white, green, orange, red, blue, purple, yellow

    var color: Color {
        switch self {
        case .white: .white
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .blue: .blue
        case .purple: .purple
        case .yellow: .yellow
        }
    }
}

/// What the right ear shows.
enum ActivityAccessory: Equatable {
    case none
    case text(String)
    case symbol(String)
    case animatedSymbol(String)           // pulses while shown (music playing)
    case progress(Double)                 // 0...1, drawn as a small ring
}

/// A button shown under the activity while the notch is peeking. The handler is passed to
/// `ActivityCenter.post(_:onAction:)`; this only describes the button.
struct ActivityAction: Identifiable, Equatable {
    enum Style: Equatable { case normal, primary, destructive }
    var id: String
    var title: String
    var style: Style = .normal
    var symbol: String? = nil            // shows an SF Symbol instead of the title (media controls)
    var armDelay: TimeInterval = 0       // seconds after the activity appears before it can be pressed
}

/// One thing the notch can show while collapsed: an icon in the left ear, an accessory
/// in the right ear, and a title, subtitle and buttons when you hover.
struct Activity: Identifiable, Equatable {
    var id: String                       // posting the same id again replaces it
    var priority: ActivityPriority
    var symbol: String
    var image: NSImage? = nil            // replaces the symbol in the left ear (album art)
    var tint: ActivityTint = .white
    var accessory: ActivityAccessory = .none
    var title: String
    var subtitle: String? = nil
    var detail: String? = nil            // up to 3 monospaced lines in the peek (a full command)
    var fileURL: URL? = nil              // the peek can be dragged out as this file (a download)
    var duration: TimeInterval? = nil    // nil: stays until removed
    var urgent = false                   // also shows over fullscreen apps
    var actions: [ActivityAction] = []   // buttons in the peek
    var expands = false                  // peeks without waiting for hover (permission requests)
    var opensTab: NotchTab? = nil        // clicking the notch opens this tab
    var sound: String? = nil             // system sound name played once when posted

    // Set by ActivityCenter when posted.
    var postedAt = Date()                          // for display only
    var sequence = 0                               // breaks priority ties: higher is newer
    var expiresAt: ContinuousClock.Instant? = nil  // counts sleep, ignores clock changes
}
