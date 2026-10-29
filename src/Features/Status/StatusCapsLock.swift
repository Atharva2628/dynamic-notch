import CoreGraphics
import Foundation

/// Turns Caps Lock readings into changes. The first reading only sets the baseline, so
/// nothing shows at launch or when polling resumes after a pause.
struct StatusCapsLockDetector {
    private(set) var last: Bool?

    /// The new state when it differs from the previous reading, otherwise nil.
    mutating func sample(_ on: Bool) -> Bool? {
        defer { last = on }
        guard let last, last != on else { return nil }
        return on
    }

    mutating func reset() { last = nil }
}

/// Reads the Caps Lock state 4 times a second. The modifier flags need no permission,
/// unlike a key event monitor (Input Monitoring).
@MainActor
final class StatusCapsLockWatcher {
    private var detector = StatusCapsLockDetector()
    private var timer: Timer?
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard timer == nil else { return }
        detector.reset()
        poll()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)       // also while a menu is open
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let on = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        if let changed = detector.sample(on) { onChange(changed) }
    }
}
