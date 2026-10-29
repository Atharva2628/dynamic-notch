import Darwin
import Foundation
import os

/// CPU die and battery temperatures from the HID event system: a private IOKit API, the
/// one other stats apps use, since Apple has no public one. Loaded with dlopen/dlsym, so
/// a missing symbol only means no temperatures (nil), never a crash at launch. Needs no
/// permission. Used only on the sampler's queue.
final class SystemTemperatureSensors {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias ClientSetMatching = @convention(c) (OpaquePointer, CFDictionary) -> Int32
    private typealias ClientCopyServices = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    private typealias ServiceCopyProperty = @convention(c) (OpaquePointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias ServiceCopyEvent = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    private typealias EventGetFloat = @convention(c) (OpaquePointer, Int32) -> Double

    private struct API {
        let copyServices: ClientCopyServices
        let copyProperty: ServiceCopyProperty
        let copyEvent: ServiceCopyEvent
        let floatValue: EventGetFloat
    }

    private static let temperatureType: Int64 = 15                 // kIOHIDEventTypeTemperature
    private static let temperatureField = Int32(15 << 16)          // IOHIDEventFieldBase(kIOHIDEventTypeTemperature)

    private let log = Logger(subsystem: "local.dynamicnotch", category: "system")
    private var api: API?
    private var client: OpaquePointer?             // kept for the app's lifetime
    private var services: CFArray?                 // keeps the service refs below alive
    private var cpuDies: [OpaquePointer] = []
    private var batteries: [OpaquePointer] = []
    private var loaded = false
    private var lastLookup: TimeInterval?

    /// Average of the CPU die sensors and of the battery sensors, in °C; nil for either
    /// when the API or its sensors aren't there.
    func read() -> (cpu: Double?, battery: Double?) {
        if !loaded { load() }
        guard let api, let client else { return (nil, nil) }
        let uptime = ProcessInfo.processInfo.systemUptime
        // Sensors don't come and go; look again only if none were found, every 10 minutes.
        if lastLookup == nil || (cpuDies.isEmpty && batteries.isEmpty && uptime - lastLookup! > 600) {
            lookup(api, client, uptime: uptime)
        }
        return (SystemMath.average(cpuDies.compactMap { value(api, $0) }),
                SystemMath.average(batteries.compactMap { value(api, $0) }))
    }

    private func load() {
        loaded = true
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: ClientCreate.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: ClientSetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: ClientCopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: ServiceCopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: ServiceCopyEvent.self),
              let floatValue = symbol("IOHIDEventGetFloatValue", as: EventGetFloat.self),
              let client = create(kCFAllocatorDefault) else {
            log.info("temperature sensors unavailable")
            return
        }
        // Apple vendor page, temperature sensor usage.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(client, matching)
        self.client = client
        api = API(copyServices: copyServices, copyProperty: copyProperty, copyEvent: copyEvent, floatValue: floatValue)
    }

    private func lookup(_ api: API, _ client: OpaquePointer, uptime: TimeInterval) {
        lastLookup = uptime
        cpuDies = []
        batteries = []
        guard let list = api.copyServices(client)?.takeRetainedValue() else { services = nil; return }
        services = list
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let service = OpaquePointer(raw)
            guard let name = api.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else { continue }
            if SystemMath.isCPUDieSensor(name) {
                cpuDies.append(service)
            } else if SystemMath.isBatterySensor(name) {
                batteries.append(service)
            }
        }
        log.info("temperature sensors: \(self.cpuDies.count) CPU, \(self.batteries.count) battery")
    }

    private func value(_ api: API, _ service: OpaquePointer) -> Double? {
        guard let event = api.copyEvent(service, Self.temperatureType, 0, 0) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release() }
        let celsius = api.floatValue(event, Self.temperatureField)
        return celsius.isFinite && celsius > 1 && celsius < 150 ? celsius : nil
    }
}
