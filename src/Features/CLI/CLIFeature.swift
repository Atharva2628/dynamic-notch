import AppKit
import os

/// The app's side of the `notch` command (bin/notch): checks each "cli" message from the
/// socket, posts, updates or removes "cli.<id>" activities, opens tabs, and always answers
/// {"ok":true} or {"ok":false,"error":...}.
///
/// A post with a time limit peeks for that long, up to 8 s, then stays collapsed for the
/// rest (it's a notification you asked to see); `--for 0` and progress rings stay collapsed
/// until removed, with a Dismiss button in the peek. `done` turns any of them into a 6 s
/// check mark.
@MainActor
final class CLIFeature: Feature {
    static let log = Logger(subsystem: "local.dynamicnotch", category: "cli")
    static let prefix = "cli."
    static let maxActivities = 16
    static let defaultSeconds: Double = 8
    static let peekSeconds: Double = 8         // longest a post peeks before collapsing
    static let doneSeconds: Double = 6
    static let postSymbol = "bell.fill"
    static let progressSymbol = "terminal.fill"

    private let context: AppContext

    init(context: AppContext) {
        self.context = context
    }

    func start() {
        context.bridge.on("cli") { [weak self] message, connection in
            guard let self else {
                connection.reply(["ok": false, "error": "Dynamic Notch is quitting"])
                return
            }
            connection.reply(self.handle(message))
        }
    }

    func stop() {
        // The bridge has no way to unregister; answer instead of leaving clients hanging.
        context.bridge.on("cli") { _, connection in
            connection.reply(["ok": false, "error": "Dynamic Notch is quitting"])
        }
        context.activities.removeAll(prefix: Self.prefix)
    }

    /// The reply for one message.
    func handle(_ message: [String: Any]) -> [String: Any] {
        let parsed = CLICommand.parse(message) { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
        switch parsed {
        case .failure(let failure):
            Self.log.info("rejected a command: \(failure.message, privacy: .private)")
            return ["ok": false, "error": failure.message]
        case .success(let command):
            if let error = Self.apply(command, activities: context.activities, model: context.model) {
                Self.log.info("could not run \(command.name, privacy: .public): \(error, privacy: .private)")
                return ["ok": false, "error": error]
            }
            return ["ok": true]
        }
    }

    /// Carries out a checked command. Returns an error message, or nil when it worked.
    static func apply(_ command: CLICommand, activities: ActivityCenter, model: NotchModel) -> String? {
        switch command {
        case let .post(id, text, title, icon, tint, seconds):
            let key = prefix + id
            if let full = roomError(for: key, in: activities) { return full }
            let duration = seconds == 0 ? nil : (seconds ?? defaultSeconds)
            var a = Activity(id: key, priority: .info, symbol: icon ?? postSymbol, tint: tint ?? .white,
                             title: title ?? text, subtitle: title == nil ? nil : text, duration: duration)
            a.expands = duration != nil
            if duration == nil { a.actions = [dismissAction] }
            post(a, to: activities)
            if let duration, duration > peekSeconds { collapse(key, after: peekSeconds, in: activities) }

        case let .progress(id, fraction, title):
            let key = prefix + id
            let percent = "\(Int((fraction * 100).rounded()))%"
            let existing = activities.activity(id: key)
            if let existing, existing.expiresAt == nil {
                // Same ring, new value: no reordering, no sound.
                activities.update(id: key) { a in
                    a.accessory = .progress(fraction)
                    a.subtitle = percent
                    a.expands = false
                    if let title { a.title = title }
                    if a.actions.isEmpty { a.actions = [dismissAction] }
                }
            } else {
                if let full = roomError(for: key, in: activities) { return full }
                var a = Activity(id: key, priority: .info, symbol: progressSymbol, accessory: .progress(fraction),
                                 title: title ?? existing?.title ?? id, subtitle: percent)
                a.actions = [dismissAction]
                post(a, to: activities)
            }

        case let .done(id, text):
            let key = prefix + id
            let existing = activities.activity(id: key)
            if let full = roomError(for: key, in: activities) { return full }
            var a = Activity(id: key, priority: .info, symbol: "checkmark.circle.fill", tint: .green,
                             accessory: .text("Done"), title: text ?? existing?.title ?? "Done",
                             duration: doneSeconds)
            a.expands = true
            post(a, to: activities)

        case .remove(let id):
            activities.remove(id: prefix + id)

        case .open(let tab):
            guard model.geometry != nil else { return "the notch isn't showing (the built-in display is off)" }
            if let tab, !model.visibleTabs.contains(tab) { return "the \(tab.rawValue) tab is hidden in settings" }
            model.open(tab: tab)
        }
        return nil
    }

    private static let dismissAction = ActivityAction(id: "dismiss", title: "Dismiss")

    private static func post(_ activity: Activity, to activities: ActivityCenter) {
        let id = activity.id
        activities.post(activity) { [weak activities] action in
            if action == "dismiss" { activities?.remove(id: id) }
        }
    }

    /// A long `--for` peeks only for the first few seconds, then stays collapsed (with a
    /// Dismiss button) for the rest, so it doesn't hold the menu bar for minutes.
    private static func collapse(_ key: String, after seconds: Double, in activities: ActivityCenter) {
        guard let sequence = activities.activity(id: key)?.sequence else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak activities] in
            MainActor.assumeIsolated { collapseNow(key, sequence: sequence, in: activities) }
        }
    }

    /// Collapses the post if it's still the one `collapse` saw (not replaced since).
    static func collapseNow(_ key: String, sequence: Int, in activities: ActivityCenter?) {
        guard let activities, activities.activity(id: key)?.sequence == sequence else { return }
        activities.update(id: key) { a in
            a.expands = false
            if a.actions.isEmpty { a.actions = [dismissAction] }
        }
    }

    /// A new id needs room: scripts that never remove their messages can't fill the notch.
    private static func roomError(for key: String, in activities: ActivityCenter) -> String? {
        guard activities.activity(id: key) == nil else { return nil }
        let count = activities.activities.filter { $0.id.hasPrefix(prefix) }.count
        return count >= maxActivities ? "too many notch messages (\(maxActivities)); remove some with: notch remove ID" : nil
    }
}

extension CLICommand {
    /// The command word, for the log.
    var name: String {
        switch self {
        case .post: "post"
        case .progress: "progress"
        case .done: "done"
        case .remove: "remove"
        case .open: "open"
        }
    }
}
