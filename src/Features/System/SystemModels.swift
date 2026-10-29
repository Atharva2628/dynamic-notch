import Foundation

/// CPU load as fractions (0...1) of all cores together, and of each core.
struct SystemCPU: Equatable, Sendable {
    var total: Double
    var user: Double
    var system: Double
    var cores: [Double]
}

/// One core's tick counters from host_processor_info. They are 32-bit and wrap.
struct SystemCPUTicks: Equatable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// A pair of byte counters: received and sent (network), or read and written (disk).
struct SystemCounters: Equatable, Sendable {
    var a: UInt64
    var b: UInt64
}

/// kern.memorystatus_vm_pressure_level.
enum SystemPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

/// Memory as Activity Monitor counts it: used = app + wired + compressed.
struct SystemMemory: Equatable, Sendable {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressure: SystemPressure

    var used: UInt64 { app + wired + compressed }
    var fraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

struct SystemDisk: Equatable, Sendable {
    var free: Int64?                 // what macOS can free up for important use, like Finder shows
    var total: Int64?
    var readRate: Double = 0         // bytes per second
    var writeRate: Double = 0
}

struct SystemNetwork: Equatable, Sendable {
    var downRate: Double = 0         // bytes per second
    var upRate: Double = 0
    var downBytes: UInt64 = 0        // since the previous sample, for today's total
    var upBytes: UInt64 = 0
}

struct SystemBattery: Equatable, Sendable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    var minutesToEmpty: Int? = nil
    var minutesToFull: Int? = nil
    var cycles: Int? = nil
    var health: Double? = nil        // full-charge capacity over design capacity
    var watts: Double? = nil         // into the battery: positive while charging, negative while discharging
    var temperature: Double? = nil   // °C

    var discharging: Bool { !pluggedIn && !charging }
}

/// ProcessInfo's thermal state, as a plain comparable value.
enum SystemThermal: Int, Comparable, Sendable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    var title: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct SystemHeat: Equatable, Sendable {
    var thermal: SystemThermal
    var cpu: Double? = nil           // °C, average of the CPU die sensors
    var battery: Double? = nil       // °C
}

enum SystemSortKey: String, CaseIterable, Identifiable, Sendable {
    case cpu, memory, gpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        }
    }
}

/// One process in the top list.
struct SystemProcess: Identifiable, Equatable, Sendable {
    var pid: pid_t
    var name: String
    var appPath: String?             // the outermost .app it lives in, for the icon
    var cpu: Double = 0              // % of one core, like Activity Monitor
    var memory: UInt64 = 0           // physical footprint in bytes
    var gpu: Double = 0              // % of the GPU's time

    var id: pid_t { pid }
}

/// Everything one sample read. Processes are only scanned while the System tab shows.
struct SystemSnapshot: Sendable {
    var date: Date
    var cpu: SystemCPU?
    var gpu: Double?                 // 0...1
    var memory: SystemMemory?
    var disk = SystemDisk()
    var network = SystemNetwork()
    var battery: SystemBattery?
    var heat = SystemHeat(thermal: .nominal)
    var top: [SystemSortKey: [SystemProcess]]?
    var processesMeasured = false    // CPU and GPU per process need two scans
}

/// One point of the 24-hour battery graph.
struct SystemBatteryPoint: Codable, Equatable, Sendable {
    var date: Date
    var percent: Int
    var charging: Bool               // plugged in
}

/// A Bluetooth device's battery: one level (mouse), or left, right and case (AirPods).
struct SystemDeviceBattery: Identifiable, Equatable, Sendable {
    struct Level: Equatable, Sendable {
        var label: String            // "", "L", "R", "Case"
        var percent: Int
    }

    var name: String
    var symbol: String
    var levels: [Level]
    var address: String? = nil       // aa:bb:cc:dd:ee:ff, to match the same device from two sources

    var id: String { address ?? name }

    /// The number to show when there's room for one: the lowest bud or the device itself.
    var main: Int? {
        let devices = levels.filter { $0.label != "Case" }
        return (devices.isEmpty ? levels : devices).map(\.percent).min()
    }

    var detail: String {
        levels.map { $0.label.isEmpty ? "\($0.percent)%" : "\($0.label) \($0.percent)%" }.joined(separator: " · ")
    }
}

/// Bytes moved today, reset at local midnight. Saved so a restart doesn't lose it.
struct SystemNetworkDay: Codable, Equatable, Sendable {
    var day: String
    var down: UInt64 = 0
    var up: UInt64 = 0

    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    mutating func add(down: UInt64, up: UInt64, at date: Date, calendar: Calendar = .current) {
        let today = Self.key(date, calendar: calendar)
        if today != day { self = SystemNetworkDay(day: today) }
        self.down &+= down
        self.up &+= up
    }
}

/// The last `capacity` values of one metric, oldest first, for a sparkline.
struct SystemSeries: Equatable {
    var capacity = 60
    private(set) var values: [Double] = []

    mutating func append(_ value: Double) {
        values.append(value.isFinite ? value : 0)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

/// The sparklines of the System tab.
struct SystemHistory: Equatable {
    var cpu = SystemSeries()
    var gpu = SystemSeries()
    var memory = SystemSeries()
    var disk = SystemSeries()        // read + write bytes per second
    var down = SystemSeries()
    var up = SystemSeries()
    var temperature = SystemSeries()
}
