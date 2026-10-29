import AppKit
import Combine
import SwiftUI
import os

/// System stats: the System tab, a Home card, alerts in the collapsed notch and, if
/// turned on (menu bar icon's menu, System), CPU and network speed in the ears.
///
/// Samples every second while the System tab or Home shows in the open notch, every
/// 10 s otherwise (2 s while the ears show stats on screen), on a background queue.
/// Nothing counts as shown while the displays sleep, the screen is locked or another
/// user is on screen. Processes are scanned and device batteries read only while the
/// System tab shows. A battery point is saved every 5 minutes for the 24-hour graph.
@MainActor
final class SystemFeature: Feature {
    static let earsID = "system.ears"
    private static let batteryID = "system.battery"
    private static let memoryID = "system.memory"
    private static let diskID = "system.disk"
    private static let heatID = "system.heat"

    let store = SystemStore()
    private let context: AppContext
    private let log = Logger(subsystem: "local.dynamicnotch", category: "system")
    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "local.dynamicnotch.system", qos: .utility)
    private let io = DispatchQueue(label: "local.dynamicnotch.system.io", qos: .utility)
    private let historyFile: JSONFile<[SystemBatteryPoint]>
    private let networkFile: JSONFile<SystemNetworkDay>

    private let menuTarget = SystemMenuTarget()
    private var earsItem: NSMenuItem?

    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 0
    private var running = false
    private var sampling = false
    private var restored = false
    private var shown = false                    // System tab or Home in the open notch
    private var systemShown = false              // the System tab itself
    private var earsShown = false                // the ears' stats on screen
    private var displaysAsleep = false
    private var sessionInactive = false          // another user is on screen (fast user switching)
    private var locked = false
    private var subscriptions = Set<AnyCancellable>()
    private var thermalObserver: NSObjectProtocol?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var workspaceObservers: [NSObjectProtocol] = []
    private lazy var lockListener = SystemLockListener { [weak self] isLocked in
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.locked = isLocked
                self.visibilityChanged()
            }
        }
    }

    private var batteryAlarm = SystemBatteryAlarm()
    private var memoryLatch = SystemLatch()
    private var diskLatch = SystemLatch()
    private var heatLatch = SystemLatch()

    private var registryDevices: [SystemDeviceBattery] = []
    private var bluetoothDevices: [SystemDeviceBattery] = []
    private var registryReadAt: TimeInterval?
    private var bluetoothReadAt: TimeInterval?
    private var bluetoothRunning = false
    private var networkSavedAt = Date.distantPast

    init(context: AppContext) {
        self.context = context
        historyFile = JSONFile(url: context.dataURL("battery-history.json"))
        networkFile = JSONFile(url: context.dataURL("network-today.json"))
    }

    func start() {
        running = true
        let store = store
        let model = context.model
        context.registerTab(.system) { SystemTabView(store: store) }
        // The model keeps this closure, so it holds the model weakly.
        context.registerHomeCard { [weak model] in SystemHomeCard(store: store, open: { model?.select(.system) }) }
        context.model.onTabShown[.system] = { [weak self] in self?.visibilityChanged() }
        addMenu()

        // Saved graph and today's total, read off the main thread.
        let historyFile = historyFile, networkFile = networkFile
        io.async { [weak self] in
            let history = historyFile.load() ?? []
            let day = networkFile.load()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.store.restore(history: history, networkDay: day, now: Date())
                    self.restored = true
                }
            }
        }

        // @Published fires before the change lands; look again once it has.
        Publishers.CombineLatest3(model.$isOpen, model.$tab, model.$config)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.visibilityChanged() } }
            .store(in: &subscriptions)
        // The ears can also be hidden: no notch screen (clamshell), a fullscreen app, or
        // another activity above them.
        Publishers.Merge3(model.$geometry.map { _ in () }, model.$inFullscreenSpace.map { _ in () },
                          context.activities.$activities.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.visibilityChanged() } }
            .store(in: &subscriptions)

        // Nobody sees the numbers while the displays sleep, the screen is locked or
        // another user is on screen; sample as if everything were closed.
        locked = Self.screenIsLocked()
        lockListener.start()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }

        // Heat and memory alerts shouldn't wait for the next 10-second sample.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.sample() } }
        pressure.resume()
        pressureSource = pressure

        visibilityChanged()
        sample()
    }

    func stop() {
        running = false
        timer?.cancel()
        timer = nil
        subscriptions.removeAll()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        pressureSource?.cancel()
        pressureSource = nil
        lockListener.stop()
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObservers.removeAll()
        context.model.onTabShown[.system] = nil
        context.activities.removeAll(prefix: "system.")
        // Quitting: write today's total now, while the process is still here.
        if restored { networkFile.save(store.networkDay) }
    }

    // MARK: Scheduling

    private func visibilityChanged() {
        guard running else { return }             // a late notification after stop()
        let model = context.model
        let tab = model.currentTab
        let awake = !displaysAsleep && !sessionInactive && !locked
        let nowShown = awake && model.isOpen && (tab == .system || tab == .home)
        let nowSystem = awake && model.isOpen && tab == .system
        let nowEars = Self.earsOnScreen(statsInEars: context.config.statsInEars, awake: awake,
                                        hasNotch: model.geometry != nil, isOpen: model.isOpen, shown: model.shownActivity)
        let wanted = SystemMath.interval(visible: nowShown, ears: nowEars)
        if wanted != interval {
            interval = wanted
            restartTimer()
        }
        let opened = (nowShown && !shown) || (nowSystem && !systemShown)
        let earsAppeared = nowEars && !earsShown
        shown = nowShown
        systemShown = nowSystem
        earsShown = nowEars
        if opened {
            sample()                              // fresh numbers the moment it opens
            refreshDevices()
        } else if earsAppeared {
            sample()                              // hidden, they were updated only every 10 s
        }
        earsItem?.state = context.config.statsInEars ? .on : .off
        if context.config.statsInEars, let s = store.snapshot {
            updateEars(s)                         // turned on: show them now, not at the next sample
        } else if !context.config.statsInEars {
            removeIfPresent(Self.earsID)
        }
    }

    private func restartTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.sample() } }
        t.resume()
        timer = t
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ change: @escaping (SystemFeature) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.visibilityChanged()
            }
        }
        workspaceObservers.append(token)
    }

    /// A restart of the app while the screen is locked starts out locked.
    private static func screenIsLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return (info["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// Takes one sample on the background queue. Skipped while one is still running.
    private func sample() {
        guard running, !sampling else { return }
        sampling = true
        let sampler = sampler
        let scan = systemShown, visible = shown
        queue.async { [weak self] in
            let snapshot = sampler.sample(scanProcesses: scan, visible: visible)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot) }
            }
        }
    }

    private func apply(_ s: SystemSnapshot) {
        sampling = false
        guard running else { return }             // a sample that finished after stop()
        store.apply(s)
        recordBattery(s)
        checkAlerts(s)
        updateEars(s)
        if systemShown { refreshDevices() }
    }

    // MARK: Battery history

    private func recordBattery(_ s: SystemSnapshot) {
        guard restored else { return }
        if let b = s.battery, SystemMath.shouldRecordBattery(last: store.batteryHistory.last?.date, now: s.date) {
            store.appendBattery(SystemBatteryPoint(date: s.date, percent: b.percent, charging: b.pluggedIn || b.charging))
            let points = store.batteryHistory, file = historyFile
            io.async { file.save(points) }
        }
        if s.date.timeIntervalSince(networkSavedAt) >= SystemMath.batteryStep {
            networkSavedAt = s.date
            let day = store.networkDay, file = networkFile
            io.async { file.save(day) }
        }
    }

    // MARK: Alerts

    private func checkAlerts(_ s: SystemSnapshot) {
        let config = context.config

        if let b = s.battery {
            if let threshold = batteryAlarm.check(percent: b.percent, discharging: b.discharging, thresholds: config.batteryAlerts) {
                log.info("battery alert at \(b.percent)% (threshold \(threshold)%)")
                post(Activity(id: Self.batteryID, priority: .alert, symbol: b.percent <= 10 ? "battery.0percent" : "battery.25percent",
                              tint: b.percent <= 10 ? .red : .orange, accessory: .text("\(b.percent)%"),
                              title: "Battery at \(b.percent)%",
                              subtitle: b.minutesToEmpty.map { "About \(SystemFormat.minutes($0)) left · plug in soon" } ?? "Plug in soon",
                              duration: 60, actions: [Self.dismiss], opensTab: .system))
            }
            if !b.discharging { removeIfPresent(Self.batteryID) }
        }

        if let m = s.memory {
            if memoryLatch.check(over: m.pressure == .critical, clear: m.pressure == .normal) {
                log.info("memory pressure critical")
                // Only this sample's own scan (the sampler scans when pressure turns
                // critical): the store's lists are from whenever the tab was last open.
                let hog = s.top?[.memory]?.first.map { "\($0.name) uses \(SystemFormat.bytes(Double($0.memory), binary: true, precise: true))" }
                post(Activity(id: Self.memoryID, priority: .alert, symbol: "memorychip", tint: .red, accessory: .text("Full"),
                              title: "Memory pressure is critical",
                              subtitle: hog ?? "Quit apps you don't need",
                              actions: [Self.dismiss], opensTab: .system))
            }
            if m.pressure != .critical { removeIfPresent(Self.memoryID) }
        }

        if let free = s.disk.free, config.diskAlertGB > 0 {
            let gb = Double(free) / 1e9
            if diskLatch.check(over: gb < config.diskAlertGB, clear: gb >= config.diskAlertGB + 1) {
                log.info("disk alert: \(Int(gb)) GB free")
                post(Activity(id: Self.diskID, priority: .alert, symbol: "internaldrive", tint: .orange,
                              accessory: .text(SystemFormat.bytes(Double(free))), title: "Disk almost full",
                              subtitle: "\(SystemFormat.bytes(Double(free))) free" + (s.disk.total.map { " of \(SystemFormat.bytes(Double($0)))" } ?? ""),
                              duration: 60, actions: [Self.dismiss], opensTab: .system))
            }
            if gb >= config.diskAlertGB { removeIfPresent(Self.diskID) }
        }

        let thermal = s.heat.thermal
        let heatText = "Thermal state \(thermal.title.lowercased())" + (s.heat.cpu.map { " · CPU \(SystemFormat.temperature($0))C" } ?? "")
        if Self.heatAlert(&heatLatch, thermal) {
            log.info("thermal state \(thermal.title, privacy: .public)")
            post(Activity(id: Self.heatID, priority: .alert, symbol: "thermometer.high", tint: thermal == .critical ? .red : .orange,
                          accessory: .text(thermal.title), title: "Your Mac is running hot", subtitle: heatText,
                          actions: [Self.dismiss], opensTab: .system))
        } else if thermal >= .serious, context.activities.activity(id: Self.heatID) != nil {
            context.activities.update(id: Self.heatID) {
                $0.tint = thermal == .critical ? .red : .orange
                $0.accessory = .text(thermal.title)
                $0.subtitle = heatText
            }
        }
        if thermal < .serious { removeIfPresent(Self.heatID) }
    }

    /// Fires at serious or critical, and re-arms only back at nominal: the states are
    /// coarse, and fair is right at the edge, so re-arming there alerted on every swing.
    static func heatAlert(_ latch: inout SystemLatch, _ thermal: SystemThermal) -> Bool {
        latch.check(over: thermal >= .serious, clear: thermal == .nominal)
    }

    private static let dismiss = ActivityAction(id: "dismiss", title: "Dismiss")

    private func post(_ activity: Activity) {
        let id = activity.id
        context.activities.post(activity) { [weak activities = context.activities] action in
            if action == "dismiss" { activities?.remove(id: id) }
        }
    }

    /// `remove` republishes the list even when nothing goes, so check first.
    private func removeIfPresent(_ id: String) {
        if context.activities.activity(id: id) != nil { context.activities.remove(id: id) }
    }

    // MARK: Ears

    private func updateEars(_ s: SystemSnapshot) {
        guard context.config.statsInEars, let ears = Self.earsActivity(s) else {
            if !context.config.statsInEars { removeIfPresent(Self.earsID) }
            return
        }
        if let current = context.activities.activity(id: Self.earsID) {
            guard current.accessory != ears.accessory || current.symbol != ears.symbol || current.tint != ears.tint
                    || current.title != ears.title || current.subtitle != ears.subtitle else { return }
            context.activities.update(id: Self.earsID) {
                $0.symbol = ears.symbol
                $0.tint = ears.tint
                $0.accessory = ears.accessory
                $0.title = ears.title
                $0.subtitle = ears.subtitle
            }
        } else {
            context.activities.post(ears)         // below everything: shows once nothing else does
        }
    }

    /// Whether the ears' stats can be seen: turned on, displays awake, a notch screen
    /// attached (none in clamshell mode), the notch collapsed, and the ears what it shows
    /// (nothing above them, and not hidden by a fullscreen app).
    static func earsOnScreen(statsInEars: Bool, awake: Bool, hasNotch: Bool, isOpen: Bool, shown: Activity?) -> Bool {
        statsInEars && awake && hasNotch && !isOpen && shown?.id == earsID
    }

    /// A CPU gauge in the left ear; CPU % and the busier network direction's speed in
    /// the right one ("42% 1.2M": the right ear has about 62 pt, so no arrow there; the
    /// peek has both directions). "100% 640K" is about 71 pt, so the ear's text has to
    /// shrink to fit. Ambient, the lowest priority: anything else shows instead. No tab:
    /// a click reopens the last one, as with nothing showing.
    static func earsActivity(_ s: SystemSnapshot) -> Activity? {
        guard let cpu = s.cpu else { return nil }
        let load = cpu.total
        let step = load.isFinite ? min(4, max(0, Int((load * 4).rounded()))) : 0
        let gauge = ["0", "33", "50", "67", "100"][step]
        let rate = SystemFormat.shortRate(max(s.network.downRate, s.network.upRate))
        var subtitle = "↓ \(SystemFormat.rate(s.network.downRate))  ↑ \(SystemFormat.rate(s.network.upRate))"
        if let m = s.memory { subtitle += "  ·  Memory \(SystemFormat.bytes(Double(m.used), binary: true, precise: true))" }
        return Activity(id: earsID, priority: .ambient, symbol: "gauge.with.dots.needle.\(gauge)percent",
                        tint: load >= 0.9 ? .red : (load >= 0.7 ? .orange : .white),
                        accessory: .text("\(SystemFormat.percent(load)) \(rate)"),
                        title: "CPU \(SystemFormat.percent(load))", subtitle: subtitle)
    }

    // MARK: Device batteries

    /// Registry batteries at most once a minute; AirPods through system_profiler at most
    /// every 10 minutes. Only while the System tab shows.
    private func refreshDevices() {
        guard systemShown else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if registryReadAt.map({ now - $0 >= 60 }) ?? true {
            registryReadAt = now
            queue.async { [weak self] in
                let list = SystemDevices.registryBatteries()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.registryDevices = list
                        self.store.setDevices(SystemMath.mergeDevices(list, self.bluetoothDevices))
                    }
                }
            }
        }
        if !bluetoothRunning, bluetoothReadAt.map({ now - $0 >= 600 }) ?? true {
            bluetoothReadAt = now
            bluetoothRunning = true
            SystemDevices.bluetoothBatteries { [weak self] list in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.bluetoothRunning = false
                        self.bluetoothDevices = list
                        self.store.setDevices(SystemMath.mergeDevices(self.registryDevices, list))
                    }
                }
            }
        }
    }

    // MARK: Menu

    /// "System" in the menu bar icon's menu: open the tab, and turn the stats in the ears
    /// on or off (the only switch for it besides config.json).
    private func addMenu() {
        let submenu = NSMenu()
        submenu.addItem(menuTarget.item("Open System Stats") { [weak self] in self?.context.model.open(tab: .system) })
        let ears = menuTarget.item("Stats in Notch Ears") { [weak self] in
            self?.context.model.updateConfig { $0.statsInEars.toggle() }
        }
        ears.state = context.config.statsInEars ? .on : .off
        earsItem = ears
        submenu.addItem(ears)
        let root = NSMenuItem(title: "System", action: nil, keyEquivalent: "")
        root.submenu = submenu
        context.statusItem.extraItems.append(root)
    }

    // MARK: Self-test and snapshots

    static func selfTest(_ check: (Bool, String) -> Void) {
        // CPU: two cores, 50 % and 25 % busy, one with a wrapped user counter.
        let t0 = [SystemCPUTicks(user: 100, system: 50, idle: 800, nice: 0),
                  SystemCPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)]
        let t1 = [SystemCPUTicks(user: 140, system: 60, idle: 1000, nice: 0),
                  SystemCPUTicks(user: 15, system: 0, idle: 75, nice: 0)]
        let load = SystemMath.cpuLoad(from: t0, to: t1)
        check(load.map { abs($0.cores[0] - 50.0 / 250) < 1e-9 } == true, "system: per-core load from tick deltas")
        check(load.map { abs($0.cores[1] - 25.0 / 100) < 1e-9 } == true, "system: a wrapped 32-bit tick counter still gives the right delta")
        check(load.map { abs($0.total - 75.0 / 350) < 1e-9 && abs($0.user + $0.system - $0.total) < 1e-9 } == true,
              "system: total CPU weighs every core's ticks")
        check(SystemMath.cpuLoad(from: [], to: t1) == nil && SystemMath.cpuLoad(from: t0, to: [t1[0]]) == nil,
              "system: no CPU load from a first reading or a changed core count")

        // Network: deltas per interface, a reset counter, a new interface.
        let n0 = ["en0": SystemCounters(a: 1_000, b: 500), "en1": SystemCounters(a: 9_000_000, b: 10)]
        let n1 = ["en0": SystemCounters(a: 4_000, b: 700), "en1": SystemCounters(a: 300, b: 20),
                  "en5": SystemCounters(a: 77_000_000, b: 1)]
        let moved = SystemMath.delta(from: n0, to: n1)
        check(moved == SystemCounters(a: 3_000 + 300, b: 200 + 10),
              "system: network delta handles a counter reset and ignores a new interface's history")
        check(SystemMath.isPhysicalInterface("en0", type: 6) && !SystemMath.isPhysicalInterface("utun3", type: 6)
              && !SystemMath.isPhysicalInterface("lo0", type: 24) && !SystemMath.isPhysicalInterface("awdl0", type: 6),
              "system: only Wi-Fi and Ethernet interfaces count")

        var day = SystemNetworkDay(day: "2026-10-26", down: 10, up: 5)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        day.add(down: 1, up: 1, at: Date(timeIntervalSince1970: 1_793_000_000), calendar: calendar)   // 2026-10-26 07:33 UTC
        let sameDay = day
        day.add(down: 7, up: 3, at: Date(timeIntervalSince1970: 1_793_000_000 + 86_400), calendar: calendar)
        check(sameDay.down == 11 && day == SystemNetworkDay(day: "2026-10-27", down: 7, up: 3),
              "system: today's network total adds up and restarts at midnight")

        // Alerts fire once per crossing.
        var alarm = SystemBatteryAlarm()
        let fired = [25, 20, 19, 12, 10, 9].map { alarm.check(percent: $0, discharging: true, thresholds: [20, 10]) }
        check(fired == [nil, 20, nil, nil, 10, nil], "system: battery alerts at 20 % and 10 %, once each")
        check(alarm.check(percent: 15, discharging: false, thresholds: [20, 10]) == nil
              && alarm.check(percent: 21, discharging: true, thresholds: [20, 10]) == nil
              && alarm.check(percent: 20, discharging: true, thresholds: [20, 10]) == nil,
              "system: no battery alert while charging or before the level clears the threshold by 2")
        _ = alarm.check(percent: 22, discharging: false, thresholds: [20, 10])
        check(alarm.check(percent: 20, discharging: true, thresholds: [20, 10]) == 20,
              "system: a battery alert re-arms after charging above it")
        var jump = SystemBatteryAlarm()
        check(jump.check(percent: 9, discharging: true, thresholds: [20, 10]) == 10
              && jump.check(percent: 8, discharging: true, thresholds: [20, 10]) == nil,
              "system: crossing two thresholds at once alerts once, for the lowest")
        var latch = SystemLatch()
        let latched = [(true, false), (true, false), (false, false), (true, false), (false, true), (true, false)]
            .map { latch.check(over: $0.0, clear: $0.1) }
        check(latched == [true, false, false, false, false, true], "system: an alert latch re-arms only once clear")
        var heat = SystemLatch()
        let heated = [SystemThermal.serious, .fair, .serious, .nominal, .serious].map { heatAlert(&heat, $0) }
        check(heated == [true, false, false, false, true], "system: the heat alert re-arms only once back to nominal")

        // Formatting.
        check(SystemFormat.bytes(0) == "0 B" && SystemFormat.bytes(999) == "999 B" && SystemFormat.bytes(1_500) == "1.5 KB"
              && SystemFormat.bytes(12_345_678) == "12 MB" && SystemFormat.bytes(999_700) == "1 MB",
              "system: byte sizes")
        check(SystemFormat.bytes(Double(16 << 30), binary: true, precise: true) == "16 GB"
              && SystemFormat.bytes(11.2 * Double(1 << 30), binary: true, precise: true) == "11.2 GB",
              "system: memory sizes in binary units")
        check(SystemFormat.rate(1_240_000) == "1.2 MB/s" && SystemFormat.shortRate(640_000) == "640K"
              && SystemFormat.shortRate(12) == "12B" && SystemFormat.minutes(245) == "4:05"
              && SystemFormat.percent(0.234) == "23%",
              "system: rates, durations and percents")

        // Battery history.
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let points = [-90_000.0, -86_000, -300, 0, 3_600].map {
            SystemBatteryPoint(date: now.addingTimeInterval($0), percent: 50, charging: false)
        }
        let trimmed = SystemMath.trimHistory(points.reversed(), now: now)
        check(trimmed.map(\.date) == [points[1].date, points[2].date, points[3].date],
              "system: battery history keeps 24 hours, oldest first, nothing from the future")
        check(SystemMath.shouldRecordBattery(last: nil, now: now)
              && !SystemMath.shouldRecordBattery(last: now.addingTimeInterval(-200), now: now)
              && SystemMath.shouldRecordBattery(last: now.addingTimeInterval(-297), now: now),
              "system: a battery point every 5 minutes")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("system-selftest-\(UUID().uuidString)")
        let file = JSONFile<[SystemBatteryPoint]>(url: dir.appendingPathComponent("battery-history.json"))
        file.save(trimmed)
        check(file.load() == trimmed, "system: battery history survives a save and load")
        try? FileManager.default.removeItem(at: dir)

        // Processes.
        let procs = [SystemProcess(pid: 3, name: "a", cpu: 5, memory: 900, gpu: 0),
                     SystemProcess(pid: 1, name: "b", cpu: 50, memory: 100, gpu: 2),
                     SystemProcess(pid: 2, name: "c", cpu: 0.01, memory: 5_000, gpu: 0)]
        check(SystemMath.top(procs, by: .cpu).map(\.pid) == [1, 3] && SystemMath.top(procs, by: .memory).map(\.pid) == [2, 3, 1]
              && SystemMath.top(procs, by: .gpu).map(\.pid) == [1],
              "system: top processes sort by CPU, memory or GPU, idle ones left out")
        let ps = SystemMath.parsePS("  413  39.8  71920\n    1   0.0  12000\ngarbage line\n  562   5,5  26928\n")
        check(ps.count == 3 && ps[413]?.cpu == 39.8 && ps[413]?.rss == 71_920 * 1024 && ps[562]?.cpu == 5.5,
              "system: ps output gives other users' CPU and memory")
        check(SystemMath.outermostApp("/Applications/Google Chrome.app/Contents/Frameworks/G.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
              == "/Applications/Google Chrome.app" && SystemMath.outermostApp("/usr/sbin/bluetoothd") == nil,
              "system: a helper's icon comes from its outermost app")
        check(SystemMath.isCPUDieSensor("PMU2 tdie3") && !SystemMath.isCPUDieSensor("PMU tdev1")
              && SystemMath.isBatterySensor("gas gauge battery"), "system: temperature sensors are picked by name")

        // Device batteries from system_profiler, merged with the registry's.
        let profiler = #"""
        {"SPBluetoothDataType": [{"controller_properties": {"controller_state": "attrib_on"},
          "device_connected": [
            {"Sam's AirPods Pro": {"device_address": "AA:BB:CC:00:11:22", "device_batteryLevelLeft": "100%",
              "device_batteryLevelRight": "92%", "device_batteryLevelCase": "45%", "device_minorType": "Headphones"}},
            {"MX Anywhere 3S": {"device_address": "11:22:33:44:55:66", "device_batteryLevelMain": "80%", "device_minorType": "Mouse"}},
            {"Speaker": {"device_address": "99:99:99:99:99:99", "device_minorType": "Speaker"}}],
          "device_not_connected": [{"Old AirPods": {"device_batteryLevelLeft": "10%"}}]}]}
        """#
        let parsed = SystemMath.parseBluetooth(Data(profiler.utf8))
        check(parsed.map(\.name) == ["MX Anywhere 3S", "Sam's AirPods Pro"],
              "system: system_profiler devices with a battery, connected only")
        check(parsed.last?.levels == [.init(label: "L", percent: 100), .init(label: "R", percent: 92), .init(label: "Case", percent: 45)]
              && parsed.last?.main == 92 && parsed.last?.symbol == "airpodspro" && parsed.first?.main == 80,
              "system: AirPods left, right and case levels")
        let registry = [SystemDeviceBattery(name: "MX Anywhere 3S", symbol: "computermouse",
                                            levels: [.init(label: "", percent: 79)],
                                            address: SystemMath.normalizeAddress("11-22-33-44-55-66"))]
        let merged = SystemMath.mergeDevices(registry, parsed)
        check(merged.count == 2 && merged.first?.main == 79, "system: one entry per device, the registry's reading first")
        check(SystemMath.parseBluetooth(Data("not json".utf8)).isEmpty, "system: bad system_profiler output means no devices")

        // Scheduling and ears.
        check(SystemMath.interval(visible: true, ears: true) == 1 && SystemMath.interval(visible: false, ears: true) == 2
              && SystemMath.interval(visible: false, ears: false) == 10, "system: sample interval follows what's visible")
        var series = SystemSeries()
        for i in 0..<75 { series.append(Double(i)) }
        check(series.values.count == 60 && series.values.first == 15 && series.values.last == 74, "system: sparklines keep 60 samples")
        var snap = SystemSnapshot(date: now)
        snap.cpu = SystemCPU(total: 0.42, user: 0.3, system: 0.12, cores: [])
        snap.network = SystemNetwork(downRate: 1_240_000, upRate: 3_000)
        let ears = earsActivity(snap)
        check(ears?.accessory == .text("42% 1.2M") && ears?.priority == .ambient && ears?.id == earsID
              && ears?.symbol == "gauge.with.dots.needle.50percent",
              "system: the ears show CPU and the busier network direction's speed")
        check(ears != nil && ears?.opensTab == nil, "system: clicking the ears reopens the last tab, not System")
        let center = ActivityCenter()
        center.post(Activity(id: "nowplaying.track", priority: .nowPlaying, symbol: "music.note", title: "Song"))
        if let ears { center.post(ears) }
        check(center.top?.id == "nowplaying.track", "system: the ears never cover a track, even posted after it")
        check(!earsOnScreen(statsInEars: true, awake: true, hasNotch: true, isOpen: false, shown: center.top),
              "system: covered ears count as hidden")
        center.remove(id: "nowplaying.track")
        check(center.top?.id == earsID, "system: the ears show as soon as the track goes")
        check(earsOnScreen(statsInEars: true, awake: true, hasNotch: true, isOpen: false, shown: center.top)
              && !earsOnScreen(statsInEars: true, awake: true, hasNotch: true, isOpen: false, shown: center.topUrgent)
              && !earsOnScreen(statsInEars: true, awake: true, hasNotch: false, isOpen: false, shown: center.top)
              && !earsOnScreen(statsInEars: true, awake: false, hasNotch: true, isOpen: false, shown: center.top)
              && !earsOnScreen(statsInEars: true, awake: true, hasNotch: true, isOpen: true, shown: center.top),
              "system: the ears count as hidden in a fullscreen app, in clamshell mode, asleep or locked, and while open")
        // The right ear is NotchMetrics.ear less NotchView's 14 pt trailing padding, and its
        // text may shrink to 80 %. The widest accessories still have to fit.
        let earFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let widest = [999_000.0, 640_000, 1_240_000, 12_000_000, 999].map { rate -> CGFloat in
            var busy = snap
            busy.cpu = SystemCPU(total: 1, user: 0.8, system: 0.2, cores: [])
            busy.network = SystemNetwork(downRate: rate, upRate: 0)
            guard case .text(let text)? = earsActivity(busy)?.accessory else { return .infinity }
            return (text as NSString).size(withAttributes: [.font: earFont]).width
        }.max() ?? .infinity
        check(widest <= (NotchMetrics.ear - 14) / 0.8, "system: the ears' text fits the right ear at 100 % CPU")
    }

    static func snapshotViews() -> [(name: String, view: AnyView)] {
        let store = SystemStore.sample()
        return [
            ("system-tab", AnyView(SystemTabView(store: store)
                .frame(width: 758, height: 186)
                .background(Color.black)
                .environment(\.colorScheme, .dark))),
            ("system-home-card", AnyView(SystemHomeCard(store: store)
                .frame(width: 145, height: 186)
                .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: NotchStyle.cornerRadius, style: .continuous))
                .background(Color.black)
                .environment(\.colorScheme, .dark))),
        ]
    }
}

/// Runs a closure per menu item (NSMenuItem needs an Objective-C target).
@MainActor
private final class SystemMenuTarget: NSObject {
    private var actions: [() -> Void] = []

    func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions.append(action)
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        if actions.indices.contains(sender.tag) { actions[sender.tag]() }
    }
}

/// Receives the screen lock and unlock notifications, delivered immediately: AppKit holds
/// distributed notifications back while an app is inactive, and this one almost always is.
/// (The same as StatusFeature's listener.)
private final class SystemLockListener: NSObject {
    private static let locked = Notification.Name("com.apple.screenIsLocked")
    private static let unlocked = Notification.Name("com.apple.screenIsUnlocked")
    private let onChange: @Sendable (_ isLocked: Bool) -> Void

    init(onChange: @escaping @Sendable (_ isLocked: Bool) -> Void) {
        self.onChange = onChange
        super.init()
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        for name in [Self.locked, Self.unlocked] {
            center.addObserver(self, selector: #selector(received(_:)), name: name,
                               object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func received(_ note: Notification) {
        onChange(note.name == Self.locked)
    }
}

extension SystemFeature {
    func debugState() -> [String: Any] {
        ["sampled": store.snapshot != nil, "devices": store.devices.count, "batteryPoints": store.batteryHistory.count]
    }
}
