import AppKit
import Combine

/// Holds the live activities and picks the one the collapsed notch shows.
@MainActor
final class ActivityCenter: ObservableObject {
    @Published private(set) var activities: [Activity] = []
    private var handlers: [String: (String) -> Void] = [:]
    private var expiry: DispatchWorkItem?
    private var nextSequence = 0
    private var paused: Set<String> = []

    /// Most important first; among equals, the newest.
    var top: Activity? { Self.pick(activities) }

    /// What a fullscreen Space may show: permission requests, meeting alerts.
    var topUrgent: Activity? { Self.pick(activities.filter(\.urgent)) }
    var hasUrgent: Bool { activities.contains(where: \.urgent) }

    nonisolated static func pick(_ list: [Activity]) -> Activity? {
        list.min { a, b in a.priority != b.priority ? a.priority < b.priority : a.sequence > b.sequence }
    }

    func activity(id: String) -> Activity? { activities.first { $0.id == id } }

    /// Posts or replaces an activity. `onAction` gets the id of the button pressed.
    func post(_ activity: Activity, now: ContinuousClock.Instant = .now, onAction: ((String) -> Void)? = nil) {
        var a = activity
        nextSequence += 1
        a.sequence = nextSequence
        a.postedAt = Date()
        a.expiresAt = a.duration.map { now.advanced(by: .seconds($0)) }
        var list = activities.filter { $0.id != a.id }
        list.append(a)
        activities = list
        handlers[a.id] = onAction
        if let sound = a.sound, !sound.isEmpty { NSSound(named: NSSound.Name(sound))?.play() }
        pruneExpired(now: now)
    }

    /// Changes an activity in place (progress, text) without moving it to the front or
    /// replaying its sound. Does nothing if it's gone.
    func update(id: String, _ change: (inout Activity) -> Void) {
        guard let i = activities.firstIndex(where: { $0.id == id }) else { return }
        var a = activities[i]
        change(&a)
        a.id = id
        activities[i] = a
    }

    /// Runs the handler for a button in an activity's peek.
    func perform(activityID: String, actionID: String) {
        handlers[activityID]?(actionID)
    }

    func remove(id: String) {
        handlers[id] = nil
        guard activities.contains(where: { $0.id == id }) else { return }
        activities.removeAll { $0.id == id }
        scheduleExpiry(now: .now)
    }

    /// Removes every activity whose id starts with `prefix` (one feature's activities).
    func removeAll(prefix: String) {
        guard activities.contains(where: { $0.id.hasPrefix(prefix) }) else { return }
        for a in activities where a.id.hasPrefix(prefix) { handlers[a.id] = nil }
        activities.removeAll { $0.id.hasPrefix(prefix) }
        scheduleExpiry(now: .now)
    }

    func removeAll() {
        activities.removeAll()
        handlers.removeAll()
        scheduleExpiry(now: .now)
    }

    /// Keeps a timed activity on screen while you're looking at it (hovering the peek), so
    /// it can't vanish under the pointer. `resumeExpiry` gives it at least 3 s more.
    func pauseExpiry(id: String) {
        guard activities.contains(where: { $0.id == id && $0.expiresAt != nil }) else { return }
        paused.insert(id)
    }

    func resumeExpiry(now: ContinuousClock.Instant = .now) {
        guard !paused.isEmpty else { return }
        for id in paused {
            guard let i = activities.firstIndex(where: { $0.id == id }), let end = activities[i].expiresAt else { continue }
            activities[i].expiresAt = max(end, now.advanced(by: .seconds(3)))
        }
        paused.removeAll()
        pruneExpired(now: now)
    }

    /// Drops activities whose time is up and arms a timer for the next one. Also called on
    /// wake, because the timer's clock stops while the Mac sleeps.
    func pruneExpired(now: ContinuousClock.Instant = .now) {
        let kept = activities.filter { a in paused.contains(a.id) || (a.expiresAt.map { $0 > now } ?? true) }
        if kept.count != activities.count {
            let keptIDs = Set(kept.map(\.id))
            for a in activities where !keptIDs.contains(a.id) { handlers[a.id] = nil }
            activities = kept
        }
        scheduleExpiry(now: now)
    }

    private func scheduleExpiry(now: ContinuousClock.Instant) {
        expiry?.cancel()
        expiry = nil
        guard let next = activities.filter({ !paused.contains($0.id) }).compactMap(\.expiresAt).min() else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.pruneExpired() }
        }
        expiry = work
        let wait = now.duration(to: next).components
        let seconds = Double(wait.seconds) + Double(wait.attoseconds) / 1e18
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, seconds), execute: work)
    }
}
