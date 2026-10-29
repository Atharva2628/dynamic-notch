import Darwin
import Foundation
import IOKit
import IOKit.ps
import os

/// Reads every number the System tab shows. Lives on one serial queue (it isn't
/// thread-safe) and keeps the previous counters there to turn them into rates. Every
/// reader needs no permission: kernel counters, the IORegistry and power sources.
final class SystemSampler: @unchecked Sendable {
    private let log = Logger(subsystem: "local.dynamicnotch", category: "system")
    private let host = mach_host_self()
    private let processes = SystemProcessScanner()
    private let sensors = SystemTemperatureSensors()

    private var lastClock: TimeInterval?
    private var lastTicks: [SystemCPUTicks] = []
    private var lastNetwork: [String: SystemCounters] = [:]
    private var lastDisk: [String: SystemCounters] = [:]
    private var space: (free: Int64?, total: Int64?, uptime: TimeInterval)?
    private var batteryDetails: (cycles: Int?, health: Double?, uptime: TimeInterval)?
    private var lastPressure: SystemPressure?

    /// One full reading. `scanProcesses` adds the top lists (only while the tab shows:
    /// it's the costliest part), and so does memory pressure turning critical, for the
    /// alert's biggest process. `visible`: the numbers are on screen, so free space is
    /// read every 10 s instead of every minute.
    func sample(scanProcesses: Bool, visible: Bool = true) -> SystemSnapshot {
        let uptime = ProcessInfo.processInfo.systemUptime
        // Rates use a clock that counts sleep (systemUptime doesn't), so bytes moved by a
        // dark wake or the sleep image aren't divided by a few seconds after waking.
        let clock = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
        let dt = lastClock.map { clock - $0 } ?? 0
        let valid = dt > 0.2
        lastClock = clock

        var s = SystemSnapshot(date: Date())

        let ticks = readTicks()
        s.cpu = SystemMath.cpuLoad(from: lastTicks, to: ticks)
        lastTicks = ticks

        s.gpu = Self.gpuUtilization()
        s.memory = readMemory()

        let network = Self.interfaceCounters()
        let moved = SystemMath.delta(from: lastNetwork, to: network)
        lastNetwork = network
        s.network.downBytes = moved.a
        s.network.upBytes = moved.b
        if valid {
            s.network.downRate = Double(moved.a) / dt
            s.network.upRate = Double(moved.b) / dt
        }

        let disk = Self.diskCounters()
        let io = SystemMath.delta(from: lastDisk, to: disk)
        lastDisk = disk
        if valid {
            s.disk.readRate = Double(io.a) / dt
            s.disk.writeRate = Double(io.b) / dt
        }
        // Free space takes a moment to compute (purgeable files), and changes slowly.
        if space.map({ uptime - $0.uptime }) ?? .infinity >= (visible ? 10 : 60) {
            let values = try? URL(fileURLWithPath: "/").resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            space = (values?.volumeAvailableCapacityForImportantUsage, values?.volumeTotalCapacity.map(Int64.init), uptime)
        }
        s.disk.free = space?.free
        s.disk.total = space?.total

        let temperatures = sensors.read()
        s.heat = SystemHeat(thermal: SystemThermal(ProcessInfo.processInfo.thermalState),
                            cpu: temperatures.cpu, battery: temperatures.battery)
        s.battery = readBattery(uptime: uptime)
        if s.battery?.temperature == nil { s.battery?.temperature = temperatures.battery }
        if s.heat.battery == nil { s.heat.battery = s.battery?.temperature }

        // Memory is a one-shot reading, so even a first scan names the biggest process.
        let turnedCritical = s.memory?.pressure == .critical && lastPressure != .critical
        lastPressure = s.memory?.pressure
        if scanProcesses || turnedCritical {
            let scan = processes.scan()
            s.top = scan.top
            s.processesMeasured = scan.measured
        }
        return s
    }

    // MARK: CPU

    private func readTicks() -> [SystemCPUTicks] {
        var cpus: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cpus)).map { cpu in
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[cpu * states + Int(state)]) }
            return SystemCPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                                  idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    // MARK: Memory

    private func readMemory() -> SystemMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) != 0 { swap = xsw_usage() }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) != 0 { level = 1 }

        return SystemMemory(total: ProcessInfo.processInfo.physicalMemory,
                            app: (anonymous > purgeable ? anonymous - purgeable : 0) * page,
                            wired: UInt64(stats.wire_count) * page,
                            compressed: UInt64(stats.compressor_page_count) * page,
                            swapUsed: swap.xsu_used, swapTotal: swap.xsu_total,
                            pressure: SystemPressure(rawValue: Int(level)) ?? .normal)
    }

    // MARK: GPU

    /// "Device Utilization %" from the GPU driver's statistics: what Activity Monitor's
    /// GPU history shows. No admin rights needed.
    private static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var busiest: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let busy = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            busiest = max(busiest ?? 0, busy)
        }
        return busiest.map { min(max($0, 0), 100) / 100 }
    }

    // MARK: Disk and network counters

    /// Bytes read and written per storage driver, keyed by registry entry, so attaching
    /// or ejecting a disk doesn't show up as a burst.
    private static func diskCounters() -> [String: SystemCounters] {
        var out: [String: SystemCounters] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &id)
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            out[String(id)] = SystemCounters(a: (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0,
                                             b: (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0)
        }
        return out
    }

    /// 64-bit received and sent byte counters of the physical interfaces, from one
    /// NET_RT_IFLIST2 sysctl (the 32-bit counters in getifaddrs wrap at 4 GB).
    private static func interfaceCounters() -> [String: SystemCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var buffer: [UInt8] = []
        var length = 0
        for attempt in 0..<3 {      // the list can grow between the size query and the read
            guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
            length += 512 << attempt
            buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 { break }
            if errno != ENOMEM || attempt == 2 { return [:] }
        }
        var out: [String: SystemCounters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let size = Int(header.ifm_msglen)
                guard size > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil {
                        let text = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                        if SystemMath.isPhysicalInterface(text, type: info.ifm_data.ifi_type) {
                            out[text] = SystemCounters(a: info.ifm_data.ifi_ibytes, b: info.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += size
            }
        }
        return out
    }

    // MARK: Battery

    /// Percent, charging and time left from the power sources (what the menu bar shows);
    /// cycles, health, watts and temperature from the battery controller.
    private func readBattery(uptime: TimeInterval) -> SystemBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let capacity = d[kIOPSMaxCapacityKey] as? Int ?? 100
            var b = SystemBattery(percent: capacity > 0 ? min(100, max(0, current * 100 / capacity)) : current,
                                  charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                  pluggedIn: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
            if let m = d[kIOPSTimeToEmptyKey] as? Int, m > 0, !b.pluggedIn { b.minutesToEmpty = m }
            if let m = d[kIOPSTimeToFullChargeKey] as? Int, m > 0, b.charging { b.minutesToFull = m }
            readSmartBattery(into: &b, uptime: uptime)
            return b
        }
        return nil
    }

    private func readSmartBattery(into b: inout SystemBattery, uptime: TimeInterval) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        func value(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        func number(_ key: String) -> NSNumber? { value(key) as? NSNumber }

        // Amperage is signed (negative while discharging); ioreg prints it unsigned.
        if let mV = number("Voltage")?.doubleValue ?? number("AppleRawBatteryVoltage")?.doubleValue,
           let mA = number("Amperage")?.int64Value ?? number("InstantAmperage")?.int64Value {
            let watts = mV * Double(mA) / 1_000_000
            if abs(watts) < 300 { b.watts = watts }
        }
        // Hundredths of a degree on Macs that publish it; recent macOS doesn't, and the
        // HID sensor fills in.
        if let t = number("Temperature")?.doubleValue ?? number("VirtualTemperature")?.doubleValue, t > 0 {
            b.temperature = t / 100
        }

        // Cycles and health change slowly; read them every 5 minutes.
        if batteryDetails.map({ uptime - $0.uptime }) ?? .infinity >= 300 {
            let data = value("BatteryData") as? [String: Any] ?? [:]
            func capacity(_ key: String) -> Double? {
                (number(key) ?? data[key] as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 ? $0 : nil }
            }
            // System Settings' "Maximum Capacity" is the nominal charge capacity over the
            // design capacity; the raw maximum is the fallback.
            let full = capacity("NominalChargeCapacity") ?? capacity("AppleRawMaxCapacity")
            let health = capacity("DesignCapacity").flatMap { design in full.map { min(1.2, $0 / design) } }
            batteryDetails = (number("CycleCount")?.intValue, health, uptime)
        }
        b.cycles = batteryDetails?.cycles
        b.health = batteryDetails?.health
    }
}
