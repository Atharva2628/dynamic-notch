import Foundation

/// The pure parts of the System feature, apart from the readers so the self-test can
/// check them with made-up numbers.
enum SystemMath {
    /// CPU load between two readings of the per-core tick counters. The counters are
    /// 32-bit and wrap, so differences use wrapping subtraction. Nil when the readings
    /// don't line up (the first reading, or a core count change).
    static func cpuLoad(from old: [SystemCPUTicks], to new: [SystemCPUTicks]) -> SystemCPU? {
        guard !old.isEmpty, old.count == new.count else { return nil }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0
        var cores: [Double] = []
        for (a, b) in zip(old, new) {
            let u = UInt64(b.user &- a.user) + UInt64(b.nice &- a.nice)
            let s = UInt64(b.system &- a.system)
            let i = UInt64(b.idle &- a.idle)
            let all = u + s + i
            cores.append(all == 0 ? 0 : Double(u + s) / Double(all))
            user += u
            system += s
            idle += i
        }
        let all = Double(user + system + idle)
        guard all > 0 else { return SystemCPU(total: 0, user: 0, system: 0, cores: cores) }
        return SystemCPU(total: Double(user + system) / all, user: Double(user) / all,
                         system: Double(system) / all, cores: cores)
    }

    /// How far a counter moved. One that went backwards was reset (its interface came
    /// back), so everything it holds now is new.
    static func counterDelta(_ old: UInt64, _ new: UInt64) -> UInt64 {
        new >= old ? new - old : new
    }

    /// Bytes moved since the previous reading, summed over the counters present both
    /// times. A counter seen for the first time adds nothing: its total is history.
    static func delta(from old: [String: SystemCounters], to new: [String: SystemCounters]) -> SystemCounters {
        var sum = SystemCounters(a: 0, b: 0)
        for (key, now) in new {
            guard let before = old[key] else { continue }
            sum.a &+= counterDelta(before.a, now.a)
            sum.b &+= counterDelta(before.b, now.b)
        }
        return sum
    }

    /// Wi-Fi and Ethernet (including USB and Thunderbolt adapters) are "en" interfaces of
    /// Ethernet type (IFT_ETHER). Loopback, VPN tunnels (utun), AWDL and bridges are
    /// skipped, so traffic isn't counted twice.
    static func isPhysicalInterface(_ name: String, type: UInt8) -> Bool {
        name.hasPrefix("en") && type == 0x06
    }

    /// Seconds between samples: every second while you look at the numbers, every 2 s
    /// while the ears show them, every 10 s otherwise (alerts and history).
    static func interval(visible: Bool, ears: Bool) -> TimeInterval {
        visible ? 1 : (ears ? 2 : 10)
    }

    static let batteryStep: TimeInterval = 5 * 60
    static let batteryKeep: TimeInterval = 24 * 60 * 60

    /// A battery point every 5 minutes. A few seconds early counts, so samples taken
    /// every 10 s don't drift to 5:10.
    static func shouldRecordBattery(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        let gap = now.timeIntervalSince(last)
        return gap >= batteryStep - 5 || gap < -60          // the clock went back: start fresh
    }

    /// Keeps the last 24 hours, oldest first, and drops points from the future (a clock
    /// that was set back).
    static func trimHistory(_ points: [SystemBatteryPoint], now: Date) -> [SystemBatteryPoint] {
        points
            .filter { $0.date > now.addingTimeInterval(-batteryKeep) && $0.date <= now.addingTimeInterval(60) }
            .sorted { $0.date < $1.date }
    }

    /// The outermost app bundle a binary lives in ("/Applications/Google Chrome.app" for
    /// its helpers), for the icon.
    static func outermostApp(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// The top `limit` processes by `key`. CPU and GPU lists leave out idle processes.
    static func top(_ list: [SystemProcess], by key: SystemSortKey, limit: Int = 5) -> [SystemProcess] {
        let value: (SystemProcess) -> Double = {
            switch key {
            case .cpu: $0.cpu
            case .memory: Double($0.memory)
            case .gpu: $0.gpu
            }
        }
        let floor = key == .memory ? 0 : 0.05
        return list.filter { value($0) > floor }
            .sorted { value($0) != value($1) ? value($0) > value($1) : $0.pid < $1.pid }
            .prefix(limit).map { $0 }
    }

    /// Lines of `ps -A -o pid=,pcpu=,rss=` ("  413  39.8  71920"): CPU % and resident
    /// bytes (ps gives kilobytes) by pid. Lines that don't parse are skipped.
    static func parsePS(_ text: String) -> [pid_t: (cpu: Double, rss: UInt64)] {
        var out: [pid_t: (cpu: Double, rss: UInt64)] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 3, let pid = pid_t(f[0]), let cpu = Double(f[1].replacingOccurrences(of: ",", with: ".")),
                  let kb = UInt64(f[2]) else { continue }
            out[pid] = (cpu, kb &* 1024)
        }
        return out
    }

    /// "PMU tdie3", "PMU2 tdie1": the SoC's CPU die sensors.
    static func isCPUDieSensor(_ name: String) -> Bool { name.lowercased().contains("tdie") }

    /// "gas gauge battery": the battery pack.
    static func isBatterySensor(_ name: String) -> Bool { name.lowercased().contains("battery") }

    static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    // MARK: Device batteries

    /// Reads `system_profiler SPBluetoothDataType -json`: connected devices that report
    /// a battery level (AirPods left, right and case; mice and keyboards one level).
    static func parseBluetooth(_ data: Data) -> [SystemDeviceBattery] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        let keys: [(key: String, label: String)] = [
            ("device_batteryLevelMain", ""), ("device_batteryLevel", ""),
            ("device_batteryLevelLeft", "L"), ("device_batteryLevelRight", "R"),
            ("device_batteryLevelCase", "Case"),
        ]
        var out: [SystemDeviceBattery] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let props = value as? [String: Any] else { continue }
                    let levels = keys.compactMap { k in
                        (props[k.key] as? String).flatMap(percent).map { SystemDeviceBattery.Level(label: k.label, percent: $0) }
                    }
                    guard !levels.isEmpty else { continue }
                    out.append(SystemDeviceBattery(
                        name: name, symbol: deviceSymbol(name: name, type: props["device_minorType"] as? String),
                        levels: levels, address: (props["device_address"] as? String).map(normalizeAddress)))
                }
            }
        }
        return sortDevices(out)
    }

    /// "85%" → 85.
    static func percent(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
            .map { min(max($0, 0), 100) }
    }

    /// "A4-83-E7-12-34-56" and "A4:83:E7:12:34:56" both become "a4:83:e7:12:34:56".
    static func normalizeAddress(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    /// One entry per device. The same device from both sources (matched by address, or
    /// by name) keeps the reading with more levels, and the registry's when equal.
    static func mergeDevices(_ registry: [SystemDeviceBattery], _ bluetooth: [SystemDeviceBattery]) -> [SystemDeviceBattery] {
        var out: [SystemDeviceBattery] = []
        func same(_ a: SystemDeviceBattery, _ b: SystemDeviceBattery) -> Bool {
            if let x = a.address, let y = b.address { return x == y }
            return a.name.caseInsensitiveCompare(b.name) == .orderedSame
        }
        for device in registry + bluetooth {
            if let i = out.firstIndex(where: { same($0, device) }) {
                if device.levels.count > out[i].levels.count { out[i] = device }
            } else {
                out.append(device)
            }
        }
        return sortDevices(out)
    }

    static func deviceSymbol(name: String, type: String?) -> String {
        let text = (name + " " + (type ?? "")).lowercased()
        if text.contains("airpods max") { return "airpodsmax" }
        if text.contains("airpods pro") { return "airpodspro" }
        if text.contains("airpods") { return "airpods" }
        if text.contains("beats") || text.contains("headphone") || text.contains("headset") { return "headphones" }
        if text.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if text.contains("keyboard") { return "keyboard" }
        if text.contains("mouse") || text.contains("mx ") { return "computermouse" }
        if text.contains("controller") || text.contains("gamepad") { return "gamecontroller" }
        if text.contains("speaker") { return "hifispeaker" }
        return "dot.radiowaves.left.and.right"
    }

    private static func sortDevices(_ list: [SystemDeviceBattery]) -> [SystemDeviceBattery] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Fires once when a value enters its alert zone, then stays quiet until the value has
/// clearly left it (`clear`), so a value hovering at the edge doesn't alert again.
struct SystemLatch: Equatable {
    private(set) var armed = true

    mutating func check(over: Bool, clear: Bool) -> Bool {
        if over && armed {
            armed = false
            return true
        }
        if clear { armed = true }
        return false
    }
}

/// The battery thresholds (20 % and 10 % by default). Each fires once on the way down
/// while discharging, and re-arms once the battery is 2 points above it again. Crossing
/// several at once reports only the lowest.
struct SystemBatteryAlarm: Equatable {
    private(set) var fired: Set<Int> = []

    mutating func check(percent: Int, discharging: Bool, thresholds: [Int]) -> Int? {
        fired = fired.filter { percent < $0 + 2 && thresholds.contains($0) }
        guard discharging else { return nil }
        let crossed = thresholds.filter { percent <= $0 && !fired.contains($0) }
        guard let lowest = crossed.min() else { return nil }
        fired.formUnion(crossed)
        return lowest
    }
}

/// Text for sizes, speeds and times, the same everywhere in the feature.
enum SystemFormat {
    /// "0 B", "999 B", "1.5 KB", "12 MB", "182 GB". Decimal units like Finder; `binary`
    /// for memory, where 16 GB means 16 × 2³⁰ bytes. `precise` keeps one decimal up to 100.
    static func bytes(_ value: Double, binary: Bool = false, precise: Bool = false) -> String {
        let unit: Double = binary ? 1024 : 1000
        let names = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = value.isFinite ? max(0, value) : 0
        var i = 0
        while v >= unit - 0.5 && i < names.count - 1 {
            v /= unit
            i += 1
        }
        if i == 0 { return "\(Int(v.rounded())) B" }
        return "\(number(v, decimals: v < (precise ? 99.95 : 9.95) ? 1 : 0)) \(names[i])"
    }

    /// "1.2 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String { bytes(bytesPerSecond) + "/s" }

    /// "1.2M", "640K", "12B": for the ears, where room is short.
    static func shortRate(_ bytesPerSecond: Double) -> String {
        let full = bytes(bytesPerSecond)
        let parts = full.split(separator: " ")
        guard parts.count == 2 else { return full }
        return parts[0] + String(parts[1].prefix(1))
    }

    /// 0.234 → "23%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, fraction.isFinite ? fraction : 0) * 100).rounded()))%"
    }

    /// 245 → "4:05".
    static func minutes(_ total: Int) -> String {
        let m = max(0, total)
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// 52.4 → "52°".
    static func temperature(_ celsius: Double) -> String { "\(Int(celsius.rounded()))°" }

    /// One decimal, without a trailing ".0".
    private static func number(_ v: Double, decimals: Int) -> String {
        let text = String(format: "%.\(decimals)f", v)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
