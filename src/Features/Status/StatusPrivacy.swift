import CoreAudio
import CoreMediaIO
import Foundation

/// Decides whether a microphone is recording. A device that only records (the built-in
/// microphone) is in use whenever it runs. A device that also plays sound (AirPods, Zoom's
/// virtual device) runs for playback too, so for those the HAL's per-process "running
/// input" decides, when it can be read.
enum StatusMicDecision {
    static func inUse(inputOnlyRunning: Bool, sharedRunning: Bool, processInput: Bool?) -> Bool {
        inputOnlyRunning || (sharedRunning && (processInput ?? true))
    }
}

/// The one activity for both devices, so the camera never hides behind the mic: green while
/// the camera is on (with the mic in the right ear when it's on too), orange for the mic
/// alone, nil when neither is.
enum StatusPrivacy {
    static let id = "status.privacy"

    static func activity(camera: Bool, mic: Bool) -> Activity? {
        switch (camera, mic) {
        case (true, false):
            Activity(id: id, priority: .privacy, symbol: "video.fill", tint: .green, accessory: .text("On"),
                     title: "Camera is on")
        case (true, true):
            Activity(id: id, priority: .privacy, symbol: "video.fill", tint: .green, accessory: .symbol("mic.fill"),
                     title: "Camera and microphone are on")
        case (false, true):
            Activity(id: id, priority: .privacy, symbol: "mic.fill", tint: .orange, accessory: .text("On"),
                     title: "Microphone is on")
        case (false, false):
            nil
        }
    }
}

/// Watches whether any app uses a camera, through CoreMediaIO's "running somewhere"
/// property on every video device. Never opens a device, so it needs no permission.
/// Everything happens on a private queue; `onChange` is called there, once at start and
/// then on every change.
final class StatusCameraWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.dynamicnotch.status.camera", qos: .utility)
    private let onChange: @Sendable (StatusCameraWatcher, Bool) -> Void

    // Touched only on `queue`, and in deinit.
    private var relay: StatusListenerRelay?          // set while running
    private var listensToList = false
    private var cameras: Set<CMIOObjectID> = []
    private var listened: Set<CMIOObjectID> = []     // cameras whose listener was accepted
    private var last: Bool?

    init(onChange: @escaping @Sendable (StatusCameraWatcher, Bool) -> Void) {
        self.onChange = onChange
    }

    deinit { removeListeners() }

    func start() {
        queue.async { [self] in
            guard relay == nil else { return }
            let relay = StatusListenerRelay(queue: queue) { [weak self] object, _ in
                guard let self, self.relay != nil else { return }
                if object == StatusCMIO.system { self.refreshDevices() } else { self.evaluate() }
            }
            self.relay = relay
            listensToList = StatusCMIO.listen(StatusCMIO.system, StatusCMIO.devicesSelector, relay)
            refreshDevices()
        }
    }

    func stop() {
        queue.async { [self] in
            removeListeners()
            last = nil
        }
    }

    private func removeListeners() {
        guard let relay else { return }
        if listensToList { StatusCMIO.unlisten(StatusCMIO.system, StatusCMIO.devicesSelector, relay) }
        listensToList = false
        for id in listened { StatusCMIO.unlisten(id, StatusCMIO.runningSelector, relay) }
        listened = []
        cameras = []
        self.relay = nil
        relay.retire()
    }

    /// Cameras come and go (Continuity Camera, virtual cameras); listen to each one.
    private func refreshDevices() {
        guard let relay else { return }
        cameras = Set(StatusCMIO.devices())
        for id in listened.subtracting(cameras) {
            StatusCMIO.unlisten(id, StatusCMIO.runningSelector, relay)
            listened.remove(id)
        }
        for id in cameras.subtracting(listened) where StatusCMIO.listen(id, StatusCMIO.runningSelector, relay) {
            listened.insert(id)
        }
        evaluate()
    }

    private func evaluate() {
        guard relay != nil else { return }
        let on = cameras.contains { StatusCMIO.flag($0, StatusCMIO.runningSelector) == true }
        guard on != last else { return }
        last = on
        onChange(self, on)
    }
}

/// Watches whether any app records from a microphone, with CoreAudio's "running
/// somewhere" on every input device, and per-process "running input" only while a device
/// that also plays sound is running (see `StatusMicDecision`). Never opens a device.
/// Everything happens on a private queue; `onChange` is called there, once at start and
/// then on every change.
final class StatusMicWatcher: @unchecked Sendable {
    private struct Device {
        var hasOutput: Bool
        var listening: Bool
    }

    private let queue = DispatchQueue(label: "local.dynamicnotch.status.mic", qos: .utility)
    private let onChange: @Sendable (StatusMicWatcher, Bool) -> Void

    // Touched only on `queue`, and in deinit.
    private var relay: StatusListenerRelay?          // set while running
    private var listensToDevices = false
    private var devices: [AudioObjectID: Device] = [:]
    private var watchingProcesses = false
    private var listensToProcessList = false
    private var processes: [AudioObjectID: Bool] = [:]   // process object: listener accepted
    private var processesKnown = false
    private var last: Bool?

    init(onChange: @escaping @Sendable (StatusMicWatcher, Bool) -> Void) {
        self.onChange = onChange
    }

    deinit { removeListeners() }

    func start() {
        queue.async { [self] in
            guard relay == nil else { return }
            let relay = StatusListenerRelay(queue: queue) { [weak self] object, selectors in
                guard let self, self.relay != nil else { return }
                guard object == StatusHAL.system else { return self.evaluate() }
                if selectors.contains(kAudioHardwarePropertyDevices) { self.refreshDevices() }
                if selectors.contains(kAudioHardwarePropertyProcessObjectList) { self.processesChanged() }
            }
            self.relay = relay
            listensToDevices = StatusHAL.listen(StatusHAL.system, kAudioHardwarePropertyDevices, relay)
            refreshDevices()
        }
    }

    func stop() {
        queue.async { [self] in
            removeListeners()
            last = nil
        }
    }

    private func removeListeners() {
        guard let relay else { return }
        watchProcesses(false)
        if listensToDevices { StatusHAL.unlisten(StatusHAL.system, kAudioHardwarePropertyDevices, relay) }
        listensToDevices = false
        for (id, device) in devices where device.listening {
            StatusHAL.unlisten(id, kAudioDevicePropertyDeviceIsRunningSomewhere, relay)
        }
        devices = [:]
        self.relay = nil
        relay.retire()
    }

    private func refreshDevices() {
        guard let relay else { return }
        let ids = StatusHAL.objects(StatusHAL.system, kAudioHardwarePropertyDevices) ?? []
        let inputs = Set(ids.filter { StatusHAL.hasStreams($0, scope: kAudioObjectPropertyScopeInput) })
        for (id, device) in devices where !inputs.contains(id) {
            if device.listening { StatusHAL.unlisten(id, kAudioDevicePropertyDeviceIsRunningSomewhere, relay) }
            devices[id] = nil
        }
        for id in inputs where devices[id] == nil {
            devices[id] = Device(hasOutput: StatusHAL.hasStreams(id, scope: kAudioObjectPropertyScopeOutput),
                                 listening: StatusHAL.listen(id, kAudioDevicePropertyDeviceIsRunningSomewhere, relay))
        }
        evaluate()
    }

    private func evaluate() {
        guard relay != nil else { return }
        var inputOnly = false
        var shared = false
        for (id, device) in devices where StatusHAL.flag(id, kAudioDevicePropertyDeviceIsRunningSomewhere) == true {
            if device.hasOutput { shared = true } else { inputOnly = true }
        }
        // Per-process answers matter only when a shared device runs and nothing else
        // already settles it; the listeners stay off the rest of the time. Without the
        // process list listener, new processes would be missed, so the answer isn't used.
        watchProcesses(shared && !inputOnly)
        var processInput: Bool?
        if watchingProcesses && listensToProcessList && processesKnown {
            processInput = processes.keys.contains { StatusHAL.flag($0, kAudioProcessPropertyIsRunningInput) == true }
        }
        let on = StatusMicDecision.inUse(inputOnlyRunning: inputOnly, sharedRunning: shared, processInput: processInput)
        guard on != last else { return }
        last = on
        onChange(self, on)
    }

    private func watchProcesses(_ on: Bool) {
        guard let relay, on != watchingProcesses else { return }
        watchingProcesses = on
        if on {
            listensToProcessList = StatusHAL.listen(StatusHAL.system, kAudioHardwarePropertyProcessObjectList, relay)
            syncProcesses()
        } else {
            if listensToProcessList {
                StatusHAL.unlisten(StatusHAL.system, kAudioHardwarePropertyProcessObjectList, relay)
            }
            listensToProcessList = false
            for (id, listening) in processes where listening {
                StatusHAL.unlisten(id, kAudioProcessPropertyIsRunningInput, relay)
            }
            processes = [:]
            processesKnown = false
        }
    }

    private func processesChanged() {
        guard watchingProcesses else { return }
        syncProcesses()
        evaluate()
    }

    private func syncProcesses() {
        guard let relay, let ids = StatusHAL.objects(StatusHAL.system, kAudioHardwarePropertyProcessObjectList) else {
            processesKnown = false
            return
        }
        processesKnown = true
        let current = Set(ids)
        for (id, listening) in processes where !current.contains(id) {
            if listening { StatusHAL.unlisten(id, kAudioProcessPropertyIsRunningInput, relay) }
            processes[id] = nil
        }
        for id in current where processes[id] == nil {
            processes[id] = StatusHAL.listen(id, kAudioProcessPropertyIsRunningInput, relay)
        }
    }
}

/// Hands CoreAudio and CoreMediaIO property notifications to a watcher's queue. The
/// watchers use the function-pointer listener APIs with a relay as client data, because a
/// listener block can't be removed from Swift: Swift wraps a closure in a new block on
/// every call, so the remove call never matches the block that was added, and the system
/// keeps (and calls) the old one for good.
private final class StatusListenerRelay: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handler: @Sendable (_ object: UInt32, _ selectors: [UInt32]) -> Void

    init(queue: DispatchQueue, handler: @escaping @Sendable (_ object: UInt32, _ selectors: [UInt32]) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    /// Identifies this relay's listeners; the watcher keeps the relay alive while they exist.
    var clientData: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Called by the listener functions, on whatever thread the system picks.
    static func deliver(_ clientData: UnsafeMutableRawPointer?, object: UInt32, selectors: [UInt32]) {
        guard let clientData else { return }
        let relay = Unmanaged<StatusListenerRelay>.fromOpaque(clientData).takeUnretainedValue()
        relay.queue.async { relay.handler(object, selectors) }
    }

    /// Call after removing every listener. Keeps the relay a few seconds longer, for a
    /// notification that was already on its way.
    func retire() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { withExtendedLifetime(self) {} }
    }
}

/// Small CoreAudio HAL helpers.
private enum StatusHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    /// The one listener function; the relay passed as client data routes each call.
    static let proc: AudioObjectPropertyListenerProc = { object, count, addresses, clientData in
        StatusListenerRelay.deliver(clientData, object: object,
                                    selectors: (0..<Int(count)).map { addresses[$0].mSelector })
        return noErr
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID]? {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return nil }
        let stride = MemoryLayout<AudioObjectID>.stride
        guard size >= stride else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / stride))
    }

    static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    static func hasStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// False if the object refused the listener.
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ relay: StatusListenerRelay) -> Bool {
        var addr = address(selector)
        return AudioObjectAddPropertyListener(object, &addr, proc, relay.clientData) == noErr
    }

    static func unlisten(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ relay: StatusListenerRelay) {
        var addr = address(selector)
        _ = AudioObjectRemovePropertyListener(object, &addr, proc, relay.clientData)
    }
}

/// Small CoreMediaIO helpers, the camera twin of `StatusHAL`.
private enum StatusCMIO {
    static let system = CMIOObjectID(kCMIOObjectSystemObject)
    static let devicesSelector = CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)
    static let runningSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)

    /// The one listener function; the relay passed as client data routes each call.
    static let proc: CMIOObjectPropertyListenerProc = { object, count, addresses, clientData in
        let selectors = addresses.map { list in (0..<Int(count)).map { list[$0].mSelector } } ?? []
        StatusListenerRelay.deliver(clientData, object: object, selectors: selectors)
        return noErr
    }

    static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func devices() -> [CMIOObjectID] {
        var addr = address(devicesSelector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        let stride = MemoryLayout<CMIOObjectID>.stride
        guard size >= stride else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / stride)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / stride))
    }

    static func flag(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> Bool? {
        var addr = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr
        else { return nil }
        return value != 0
    }

    /// False if the object refused the listener.
    static func listen(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector,
                       _ relay: StatusListenerRelay) -> Bool {
        var addr = address(selector)
        return CMIOObjectAddPropertyListener(object, &addr, proc, relay.clientData) == noErr
    }

    static func unlisten(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector, _ relay: StatusListenerRelay) {
        var addr = address(selector)
        _ = CMIOObjectRemovePropertyListener(object, &addr, proc, relay.clientData)
    }
}
