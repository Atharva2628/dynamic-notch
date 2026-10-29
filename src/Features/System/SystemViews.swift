import AppKit
import SwiftUI

/// The System tab: eight tiles (CPU, GPU, memory, SSD, network, battery, heat, devices),
/// each with a sparkline, and the top processes beside them.
struct SystemTabView: View {
    @ObservedObject var store: SystemStore

    var body: some View {
        let s = store.snapshot
        HStack(spacing: 8) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    SystemCPUTile(cpu: s?.cpu, series: store.history.cpu.values)
                    SystemGPUTile(gpu: s?.gpu, series: store.history.gpu.values, top: store.top[.gpu]?.first)
                    SystemMemoryTile(memory: s?.memory, series: store.history.memory.values)
                    SystemDiskTile(disk: s?.disk, series: store.history.disk.values)
                }
                HStack(spacing: 6) {
                    SystemNetworkTile(network: s?.network, day: store.networkDay,
                                      down: store.history.down.values, up: store.history.up.values)
                    SystemBatteryTile(battery: s?.battery, history: store.batteryHistory, now: s?.date ?? Date())
                    SystemHeatTile(heat: s?.heat, series: store.history.temperature.values)
                    SystemDevicesTile(devices: store.devices)
                }
            }
            SystemProcessList(store: store)
                .frame(width: 246)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Home card: CPU, memory, SSD space and network, densely. A click opens the System tab.
/// (Battery is in the menu bar already; it has its own tile in the tab.)
struct SystemHomeCard: View {
    @ObservedObject var store: SystemStore
    var open: (() -> Void)? = nil

    var body: some View {
        let s = store.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "cpu").font(.system(size: 12, weight: .semibold))
                Text("System").font(NotchStyle.titleFont)
                Spacer(minLength: 0)
                if let heat = s?.heat, heat.thermal >= .fair {
                    Image(systemName: "thermometer.high")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SystemPalette.thermal(heat.thermal))
                        .help("Thermal state: \(heat.thermal.title)")
                }
            }
            .foregroundStyle(.white)

            row("CPU", s?.cpu.map { SystemFormat.percent($0.total) } ?? "–") {
                SystemSparkline(values: store.history.cpu.values, maxValue: 1, color: SystemPalette.cpu)
            }
            row("Memory", s?.memory.map { SystemFormat.bytes(Double($0.used), binary: true, precise: true) } ?? "–") {
                SystemBar(fraction: s?.memory?.fraction ?? 0, color: SystemPalette.pressure(s?.memory?.pressure ?? .normal))
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
            }
            row("SSD", s?.disk.free.map { SystemFormat.bytes(Double($0)) + " free" } ?? "–") {
                if let d = s?.disk, let free = d.free, let total = d.total, total > 0 {
                    SystemBar(fraction: 1 - Double(free) / Double(total), color: SystemPalette.space(free: free, total: total))
                        .frame(height: 4)
                        .frame(maxHeight: .infinity)
                        .help("\(SystemFormat.bytes(Double(free))) free of \(SystemFormat.bytes(Double(total)))")
                } else {
                    Color.clear
                }
            }
            row("Network", s.map { "↓" + SystemFormat.shortRate($0.network.downRate) + " ↑" + SystemFormat.shortRate($0.network.upRate) } ?? "–") {
                SystemSparkline(values: store.history.down.values, color: SystemPalette.down,
                                secondary: store.history.up.values, secondaryColor: SystemPalette.up)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { open?() }
    }

    private func row<Chart: View>(_ label: String, _ value: String, @ViewBuilder chart: () -> Chart) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchStyle.tertiary)
                Spacer(minLength: 0)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            chart().frame(height: 12)
        }
    }
}

// MARK: - Tiles

/// One metric: a label, a big value, up to two lines of detail and a chart along the
/// bottom.
private struct SystemTile<Accessory: View, Chart: View>: View {
    let symbol: String
    let title: String
    let value: String
    var lines: [String] = []
    var help: String? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var chart: Chart

    var body: some View {
        ZStack(alignment: .bottom) {
            chart
                .frame(height: 26)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                    Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.4)
                    Spacer(minLength: 2)
                    accessory
                }
                .foregroundStyle(NotchStyle.secondary)
                .frame(height: 12)
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i])
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(NotchStyle.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(help ?? "")
    }
}

private struct SystemCPUTile: View {
    let cpu: SystemCPU?
    let series: [Double]

    var body: some View {
        SystemTile(symbol: "cpu", title: "CPU", value: cpu.map { SystemFormat.percent($0.total) } ?? "–",
                   lines: cpu.map { ["User \(SystemFormat.percent($0.user)) · Sys \(SystemFormat.percent($0.system))"] } ?? [],
                   help: cpu.map { c in
                       "Per core: " + c.cores.map { SystemFormat.percent($0) }.joined(separator: " ")
                   }) {
            if let cores = cpu?.cores, !cores.isEmpty { SystemCoreBars(cores: cores) }
        } chart: {
            SystemSparkline(values: series, maxValue: 1, color: SystemPalette.cpu)
        }
    }
}

/// A tiny bar per core, in the CPU tile's corner.
private struct SystemCoreBars: View {
    let cores: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(cores.indices, id: \.self) { i in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.12))
                    RoundedRectangle(cornerRadius: 1).fill(SystemPalette.cpu)
                        .frame(height: max(1, 10 * min(1, max(0, cores[i]))))
                }
                .frame(width: 3, height: 10)
            }
        }
    }
}

private struct SystemGPUTile: View {
    let gpu: Double?
    let series: [Double]
    let top: SystemProcess?

    var body: some View {
        SystemTile(symbol: "rectangle.3.group", title: "GPU", value: gpu.map { SystemFormat.percent($0) } ?? "–",
                   lines: top.map { ["Top: \($0.name)"] } ?? ["Device utilization"]) {
            EmptyView()
        } chart: {
            SystemSparkline(values: series, maxValue: 1, color: SystemPalette.gpu)
        }
    }
}

private struct SystemMemoryTile: View {
    let memory: SystemMemory?
    let series: [Double]

    var body: some View {
        let m = memory
        func gb(_ v: UInt64) -> String { SystemFormat.bytes(Double(v), binary: true, precise: true) }
        func short(_ v: UInt64) -> String { String(format: "%.1f", Double(v) / Double(1 << 30)) }
        return SystemTile(
            symbol: "memorychip", title: "Memory", value: m.map { gb($0.used) } ?? "–",
            lines: m.map { ["App \(short($0.app)) · Wired \(short($0.wired))",
                            "Comp \(short($0.compressed)) · Swap \(short($0.swapUsed))"] } ?? [],
            help: m.map { "\(gb($0.used)) of \(gb($0.total)) used · pressure \($0.pressure.title)\nApp \(gb($0.app)), wired \(gb($0.wired)), compressed \(gb($0.compressed))\nSwap \(gb($0.swapUsed)) of \(gb($0.swapTotal))" }) {
            if let m {
                Circle().fill(SystemPalette.pressure(m.pressure)).frame(width: 6, height: 6)
                    .help("Memory pressure: \(m.pressure.title)")
            }
        } chart: {
            SystemSparkline(values: series, maxValue: 1, color: SystemPalette.pressure(m?.pressure ?? .normal))
        }
    }
}

private struct SystemDiskTile: View {
    let disk: SystemDisk?
    let series: [Double]

    var body: some View {
        let d = disk
        return SystemTile(
            symbol: "internaldrive", title: "SSD", value: d?.free.map { SystemFormat.bytes(Double($0)) } ?? "–",
            lines: [d?.total.map { "free of \(SystemFormat.bytes(Double($0)))" } ?? "free",
                    d.map { "R \(SystemFormat.shortRate($0.readRate))/s · W \(SystemFormat.shortRate($0.writeRate))/s" } ?? ""],
            help: d.map { "Read \(SystemFormat.rate($0.readRate)), write \(SystemFormat.rate($0.writeRate))" }) {
            EmptyView()
        } chart: {
            SystemSparkline(values: series, color: SystemPalette.disk)
        }
    }
}

private struct SystemNetworkTile: View {
    let network: SystemNetwork?
    let day: SystemNetworkDay
    let down: [Double]
    let up: [Double]

    var body: some View {
        SystemTile(
            symbol: "network", title: "Network", value: network.map { "↓ " + SystemFormat.rate($0.downRate) } ?? "–",
            lines: [network.map { "↑ " + SystemFormat.rate($0.upRate) } ?? "",
                    "Today \(SystemFormat.bytes(Double(day.down &+ day.up)))"],
            help: "Today: ↓ \(SystemFormat.bytes(Double(day.down))), ↑ \(SystemFormat.bytes(Double(day.up)))") {
            EmptyView()
        } chart: {
            SystemSparkline(values: down, color: SystemPalette.down, secondary: up, secondaryColor: SystemPalette.up)
        }
    }
}

private struct SystemBatteryTile: View {
    let battery: SystemBattery?
    let history: [SystemBatteryPoint]
    let now: Date

    var body: some View {
        guard let b = battery else {
            return AnyView(SystemTile(symbol: "battery.100percent", title: "Battery", value: "None",
                                      lines: ["No internal battery"]) { EmptyView() } chart: { EmptyView() })
        }
        var lines: [String] = []
        if b.charging {
            lines.append(b.minutesToFull.map { "\(SystemFormat.minutes($0)) to full" } ?? "Charging")
        } else if b.pluggedIn {
            lines.append(b.percent >= 100 ? "Charged" : "On power, not charging")
        } else {
            lines.append(b.minutesToEmpty.map { "\(SystemFormat.minutes($0)) left" } ?? "Calculating…")
        }
        var health: [String] = []
        if let h = b.health { health.append("Health \(SystemFormat.percent(h))") }
        if let c = b.cycles { health.append("\(c) cyc") }
        if !health.isEmpty { lines.append(health.joined(separator: " · ")) }
        var help = "24-hour history"
        if let t = b.temperature { help += " · battery \(SystemFormat.temperature(t))C" }
        if let c = b.cycles { help += " · \(c) cycles" }
        return AnyView(SystemTile(symbol: SystemPalette.batterySymbol(b), title: "Battery", value: "\(b.percent)%",
                                  lines: lines, help: help) {
            if let w = b.watts, abs(w) >= 0.1 {
                Text(String(format: "%.1f W", abs(w)))
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(w > 0 ? Color.green : NotchStyle.secondary)
                    .help(w > 0 ? "Charging at \(String(format: "%.1f", w)) W" : "Drawing \(String(format: "%.1f", -w)) W")
            }
        } chart: {
            SystemBatteryChart(points: history, now: now)
        })
    }
}

private struct SystemHeatTile: View {
    let heat: SystemHeat?
    let series: [Double]

    var body: some View {
        let h = heat ?? SystemHeat(thermal: .nominal)
        var lines = ["Thermal: \(h.thermal.title)"]
        if let b = h.battery { lines.append("Battery \(SystemFormat.temperature(b))") }
        return SystemTile(symbol: "thermometer.medium", title: "Heat",
                          value: h.cpu.map { "CPU " + SystemFormat.temperature($0) } ?? h.thermal.title,
                          lines: heat == nil ? [] : lines,
                          help: "CPU die and battery temperatures; macOS's thermal state") {
            Circle().fill(SystemPalette.thermal(h.thermal)).frame(width: 6, height: 6)
        } chart: {
            SystemSparkline(values: series, minValue: 20, maxValue: 100, color: SystemPalette.thermal(h.thermal))
        }
    }
}

private struct SystemDevicesTile: View {
    let devices: [SystemDeviceBattery]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "headphones").font(.system(size: 9, weight: .bold))
                Text("DEVICES").font(.system(size: 9, weight: .bold)).tracking(0.4)
                Spacer(minLength: 0)
            }
            .foregroundStyle(NotchStyle.secondary)
            .frame(height: 12)
            if devices.isEmpty {
                Text("No devices")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Bluetooth batteries show here")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchStyle.tertiary)
                    .lineLimit(2)
            } else {
                ForEach(devices.prefix(4)) { d in
                    HStack(spacing: 4) {
                        Image(systemName: d.symbol)
                            .font(.system(size: 10))
                            .frame(width: 14)
                        Text(d.name)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 2)
                        Text(d.main.map { "\($0)%" } ?? "–")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle((d.main ?? 100) <= 20 ? Color.red : Color.white)
                    }
                    .foregroundStyle(.white)
                    .help("\(d.name): \(d.detail)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Top processes

private struct SystemProcessList: View {
    @ObservedObject var store: SystemStore

    var body: some View {
        let key = store.sortKey
        let rows = store.top[key] ?? []
        let largest = rows.map { value($0, key) }.max() ?? 1
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Processes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                ForEach(SystemSortKey.allCases) { k in
                    Button { store.sortKey = k } label: {
                        Text(k.title)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .foregroundStyle(k == key ? Color.black : Color.white.opacity(0.7))
                            .background(k == key ? Color.white : Color.white.opacity(0.08), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 2)
            if rows.isEmpty {
                Text(store.processesMeasured || key == .memory ? "Nothing busy" : "Measuring…")
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(rows) { p in
                    row(p, key: key, share: largest > 0 ? value(p, key) / largest : 0)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func value(_ p: SystemProcess, _ key: SystemSortKey) -> Double {
        switch key {
        case .cpu: p.cpu
        case .memory: Double(p.memory)
        case .gpu: p.gpu
        }
    }

    private func row(_ p: SystemProcess, key: SystemSortKey, share: Double) -> some View {
        HStack(spacing: 6) {
            Group {
                if let icon = store.icon(for: p.appPath) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchStyle.tertiary)
                }
            }
            .frame(width: 16, height: 16)
            Text(p.name)
                .font(NotchStyle.bodyFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(text(p, key))
                .font(NotchStyle.monoFont)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: max(0, geo.size.width * min(1, share)))
            }
        }
        .help("\(p.name) (pid \(p.pid)) · CPU \(String(format: "%.1f", p.cpu))% · \(SystemFormat.bytes(Double(p.memory), binary: true, precise: true)) · GPU \(String(format: "%.1f", p.gpu))%")
    }

    private func text(_ p: SystemProcess, _ key: SystemSortKey) -> String {
        switch key {
        case .cpu: String(format: "%.1f%%", p.cpu)
        case .memory: SystemFormat.bytes(Double(p.memory), binary: true, precise: true)
        case .gpu: String(format: "%.1f%%", min(p.gpu, 999))
        }
    }
}

// MARK: - Charts

/// The last 60 values as a line with a soft fill, newest at the right edge. `secondary`
/// adds a thinner line (upload under download).
struct SystemSparkline: View {
    var values: [Double]
    var capacity = 60
    var minValue: Double = 0
    var maxValue: Double? = nil          // nil: scale to the largest value shown
    var color: Color
    var secondary: [Double]? = nil
    var secondaryColor: Color = .orange

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? 0, values.max() ?? 0, secondary?.max() ?? 0)
            let range = max(top - minValue, 1e-9)
            ZStack {
                if values.count > 1 {
                    area(values, size: geo.size, range: range)
                        .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom))
                    line(values, size: geo.size, range: range)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
                if let secondary, secondary.count > 1 {
                    line(secondary, size: geo.size, range: range)
                        .stroke(secondaryColor.opacity(0.85), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                }
            }
        }
    }

    private func points(_ list: [Double], size: CGSize, range: Double) -> [CGPoint] {
        let step = size.width / CGFloat(max(capacity - 1, 1))
        let start = size.width - CGFloat(list.count - 1) * step
        return list.enumerated().map { i, v in
            let f = CGFloat(min(max((v - minValue) / range, 0), 1))
            return CGPoint(x: start + CGFloat(i) * step, y: size.height - 1 - f * (size.height - 2))
        }
    }

    private func line(_ list: [Double], size: CGSize, range: Double) -> Path {
        Path { p in p.addLines(points(list, size: size, range: range)) }
    }

    private func area(_ list: [Double], size: CGSize, range: Double) -> Path {
        let pts = points(list, size: size, range: range)
        return Path { p in
            guard let first = pts.first, let last = pts.last else { return }
            p.move(to: CGPoint(x: first.x, y: size.height))
            p.addLines(pts)
            p.addLine(to: CGPoint(x: last.x, y: size.height))
            p.closeSubpath()
        }
    }
}

/// The last 24 hours of battery level, green where it was plugged in. A gap longer than
/// 20 minutes (the Mac slept) breaks the line.
private struct SystemBatteryChart: View {
    let points: [SystemBatteryPoint]
    let now: Date

    var body: some View {
        GeometryReader { geo in
            let segments = segments(size: geo.size)
            ZStack {
                ForEach(segments.indices, id: \.self) { i in
                    let seg = segments[i]
                    Path { p in
                        guard let first = seg.points.first, let last = seg.points.last else { return }
                        p.move(to: CGPoint(x: first.x, y: geo.size.height))
                        p.addLines(seg.points)
                        p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill((seg.charging ? Color.green : Color.white).opacity(0.14))
                    Path { p in p.addLines(seg.points) }
                        .stroke(seg.charging ? Color.green : Color.white.opacity(0.8), lineWidth: 1.2)
                }
            }
        }
    }

    private struct Segment {
        var charging: Bool
        var points: [CGPoint]
    }

    private func segments(size: CGSize) -> [Segment] {
        let window = SystemMath.batteryKeep
        var out: [Segment] = []
        var previous: SystemBatteryPoint?
        for point in points {
            let age = now.timeIntervalSince(point.date)
            guard age <= window else { continue }
            let xy = CGPoint(x: size.width * CGFloat(1 - age / window),
                             y: size.height - 1 - CGFloat(min(max(point.percent, 0), 100)) / 100 * (size.height - 2))
            let broken = previous.map { point.date.timeIntervalSince($0.date) > 20 * 60 } ?? true
            if broken || out.last?.charging != point.charging {
                // Start a new run; join it to the previous point so color changes don't leave gaps.
                var start: [CGPoint] = []
                if !broken, let last = out.last?.points.last { start.append(last) }
                out.append(Segment(charging: point.charging, points: start + [xy]))
            } else {
                out[out.count - 1].points.append(xy)
            }
            previous = point
        }
        return out.filter { $0.points.count > 1 }
    }
}

/// A thin horizontal meter.
private struct SystemBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color).frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
    }
}

/// Colors per metric, shared by the tab and the Home card.
enum SystemPalette {
    static let cpu = Color(red: 0.36, green: 0.68, blue: 1.0)
    static let gpu = Color(red: 0.72, green: 0.52, blue: 1.0)
    static let disk = Color(red: 0.35, green: 0.85, blue: 0.85)
    static let down = Color(red: 0.36, green: 0.68, blue: 1.0)
    static let up = Color(red: 1.0, green: 0.62, blue: 0.3)

    static func pressure(_ p: SystemPressure) -> Color {
        switch p {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    static func thermal(_ t: SystemThermal) -> Color {
        switch t {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        }
    }

    /// The used-space bar: orange under 10 % free, red under 5 %.
    static func space(free: Int64, total: Int64) -> Color {
        let left = Double(free) / Double(max(total, 1))
        return left < 0.05 ? .red : (left < 0.1 ? .orange : disk)
    }

    static func battery(_ b: SystemBattery) -> Color {
        if b.charging || b.pluggedIn { return .green }
        return b.percent <= 10 ? .red : (b.percent <= 20 ? .orange : .white)
    }

    static func batterySymbol(_ b: SystemBattery) -> String {
        if b.charging { return "battery.100percent.bolt" }
        switch b.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
