import AppKit
import Combine

/// What the System tab and Home card show: the latest sample, the sparklines, the
/// 24-hour battery graph, today's network total and device batteries.
@MainActor
final class SystemStore: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var history = SystemHistory()
    @Published private(set) var top: [SystemSortKey: [SystemProcess]] = [:]
    @Published private(set) var processesMeasured = false
    @Published private(set) var batteryHistory: [SystemBatteryPoint] = []
    @Published private(set) var networkDay = SystemNetworkDay(day: SystemNetworkDay.key(Date()))
    @Published private(set) var devices: [SystemDeviceBattery] = []
    @Published var sortKey: SystemSortKey = .cpu

    private var icons: [String: NSImage] = [:]

    /// Folds one sample in: sparklines, today's total, and the top lists when scanned.
    func apply(_ s: SystemSnapshot) {
        var h = history
        if let cpu = s.cpu { h.cpu.append(cpu.total) }
        if let gpu = s.gpu { h.gpu.append(gpu) }
        if let memory = s.memory { h.memory.append(memory.fraction) }
        h.disk.append(s.disk.readRate + s.disk.writeRate)
        h.down.append(s.network.downRate)
        h.up.append(s.network.upRate)
        if let t = s.heat.cpu { h.temperature.append(t) }
        history = h

        var day = networkDay
        day.add(down: s.network.downBytes, up: s.network.upBytes, at: s.date)
        if day != networkDay { networkDay = day }

        if let lists = s.top {
            top = lists
            processesMeasured = s.processesMeasured
        }
        snapshot = s
    }

    func appendBattery(_ point: SystemBatteryPoint) {
        batteryHistory = SystemMath.trimHistory(batteryHistory + [point], now: point.date)
    }

    /// Merges the saved graph with any points taken before the file was read.
    func restore(history saved: [SystemBatteryPoint], networkDay savedDay: SystemNetworkDay?, now: Date) {
        batteryHistory = SystemMath.trimHistory(saved + batteryHistory, now: now)
        if let savedDay, savedDay.day == networkDay.day {
            networkDay = SystemNetworkDay(day: savedDay.day, down: savedDay.down &+ networkDay.down,
                                          up: savedDay.up &+ networkDay.up)
        }
    }

    func setDevices(_ list: [SystemDeviceBattery]) {
        if list != devices { devices = list }
    }

    /// The Finder icon of a process's app, cached by path.
    func icon(for appPath: String?) -> NSImage? {
        guard let appPath else { return nil }
        if let cached = icons[appPath] { return cached }
        if icons.count > 200 { icons.removeAll() }
        let image = NSWorkspace.shared.icon(forFile: appPath)
        image.size = NSSize(width: 32, height: 32)
        icons[appPath] = image
        return image
    }

    // MARK: Sample data for snapshots

    /// A store filled with made-up but plausible numbers, for the snapshots.
    static func sample() -> SystemStore {
        let store = SystemStore()
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        func wave(_ i: Int, _ base: Double, _ swing: Double, _ speed: Double) -> Double {
            base + swing * sin(Double(i) * speed) + swing * 0.4 * sin(Double(i) * speed * 2.7)
        }
        var h = SystemHistory()
        for i in 0..<60 {
            h.cpu.append(max(0.03, wave(i, 0.24, 0.12, 0.31)))
            h.gpu.append(max(0.01, wave(i, 0.18, 0.1, 0.22)))
            h.memory.append(wave(i, 0.66, 0.02, 0.05))
            h.disk.append(max(0, wave(i, 2_400_000, 2_000_000, 0.4)))
            h.down.append(max(0, wave(i, 1_300_000, 900_000, 0.27)))
            h.up.append(max(0, wave(i, 120_000, 80_000, 0.35)))
            h.temperature.append(wave(i, 48, 4, 0.12))
        }
        store.history = h

        var s = SystemSnapshot(date: now)
        s.cpu = SystemCPU(total: 0.23, user: 0.15, system: 0.08,
                          cores: [0.42, 0.31, 0.12, 0.08, 0.55, 0.21, 0.06, 0.04, 0.03, 0.02])
        s.gpu = 0.18
        s.memory = SystemMemory(total: 16 << 30, app: 6_550_000_000, wired: 2_150_000_000, compressed: 3_300_000_000,
                                swapUsed: 536_000_000, swapTotal: 2 << 30, pressure: .normal)
        s.disk = SystemDisk(free: 182_400_000_000, total: 494_380_000_000, readRate: 1_240_000, writeRate: 340_000)
        s.network = SystemNetwork(downRate: 1_240_000, upRate: 41_000)
        s.battery = SystemBattery(percent: 48, charging: false, pluggedIn: false, minutesToEmpty: 245, cycles: 166,
                                  health: 0.914, watts: -11.4, temperature: 31.2)
        s.heat = SystemHeat(thermal: .nominal, cpu: 47.6, battery: 31.2)
        store.snapshot = s

        func p(_ pid: pid_t, _ name: String, _ cpu: Double, _ memory: UInt64, _ gpu: Double) -> SystemProcess {
            SystemProcess(pid: pid, name: name, appPath: nil, cpu: cpu, memory: memory, gpu: gpu)
        }
        let all = [
            p(812, "Google Chrome Helper (Renderer)", 38.4, 912_000_000, 4.1),
            p(402, "WindowServer", 21.7, 310_000_000, 12.8),
            p(1290, "claude", 14.2, 640_000_000, 0),
            p(977, "Spotify", 6.3, 420_000_000, 0.8),
            p(615, "kernel_task", 5.1, 3_400_000_000, 0),
            p(1544, "Code Helper (Plugin)", 3.9, 1_210_000_000, 0),
            p(733, "DynamicNotch", 1.2, 88_000_000, 0.4),
        ]
        store.top = Dictionary(uniqueKeysWithValues: SystemSortKey.allCases.map { ($0, SystemMath.top(all, by: $0)) })
        store.processesMeasured = true

        store.batteryHistory = (0..<288).map { i in
            let date = now.addingTimeInterval(-Double(287 - i) * 300)
            // Charged overnight to 100, then a working day down to 48.
            let percent = i < 60 ? 30 + i : (i < 96 ? 100 : max(48, 100 - (i - 96) * 52 / 191))
            return SystemBatteryPoint(date: date, percent: percent, charging: i < 96)
        }
        store.networkDay = SystemNetworkDay(day: SystemNetworkDay.key(now), down: 2_140_000_000, up: 186_000_000)
        store.devices = [
            SystemDeviceBattery(name: "AirPods Pro", symbol: "airpodspro",
                                levels: [.init(label: "L", percent: 92), .init(label: "R", percent: 88), .init(label: "Case", percent: 45)]),
            SystemDeviceBattery(name: "Magic Keyboard", symbol: "keyboard", levels: [.init(label: "", percent: 71)]),
            SystemDeviceBattery(name: "MX Anywhere 3S", symbol: "computermouse", levels: [.init(label: "", percent: 18)]),
        ]
        return store
    }
}
