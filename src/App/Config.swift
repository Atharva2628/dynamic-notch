import Foundation

/// User settings, stored as JSON next to the app. Missing keys fall back to defaults,
/// out-of-range values are clamped, and a broken file never stops the app.
struct Config: Codable, Equatable {
    // Notch
    var collapseDelay: Double = 0.1      // seconds after the pointer leaves before the notch closes
    var hoverDelay: Double = 0.15        // seconds the pointer rests on the notch before it grows
    var hoverToPeek = true
    var panelWidth: Double = 806
    var panelHeight: Double = 250
    var tabs: [NotchTab] = NotchTab.allCases
    var hiddenTabs: [NotchTab] = []

    // Terminal
    var terminalHotkey = "ctrl+`"        // shows and hides the menu bar terminal
    var terminalFontSize: Double = 13
    var terminalScrollback = 10_000
    var terminalWidth: Double = 720      // menu bar dropdown size; remembered when you resize it
    var terminalHeight: Double = 420

    // Agents (Claude Code)
    var agentApprovals = true            // Allow/Deny permission requests from the notch
    var agentSound = "Sosumi"            // done ping; "" for silent
    var usageSource = "keychain"         // "keychain" (Claude Code's sign-in) or "off"
    var apiCostEstimate = true           // what your Claude Code tokens would cost at API prices
    var usageAlerts: [Int] = [95, 80]    // percent of the 5-hour or weekly limit (high to low)

    // Clipboard and shelf
    var clipboardHotkey = "ctrl+alt+v"
    var clipboardLimit = 40
    var clipboardAutoPaste = false       // also press ⌘V in the front app (needs Accessibility)
    var shelfKeepHours: Double = 24      // hours a file stays on the Shelf; 0 keeps it until removed

    // System
    var batteryAlerts: [Int] = [20, 10]  // percent left (high to low)
    var diskAlertGB: Double = 10
    var statsInEars = false              // CPU and network speed beside an idle notch

    // Calendar
    var calendarEnabled = true
    var calendarDays = 7
    var meetingAlertMinutes = 5
    var hiddenCalendars: [String] = []   // EventKit calendar identifiers, picked in the Calendar tab

    // Status
    var capsLockHUD = true
    var cameraGuard = true
    var micGuard = true
    var lockNotice = true
    var downloads = true
    var nowPlaying = true
    var nowPlayingHideWhenPaused = true

    // Prompter
    var prompterFolder = ""              // empty: Application Support/DynamicNotch/Prompter
    var prompterFontSize: Double = 20
    var prompterSpeed: Double = 40       // points per second
    var prompterWidth: Double = 420
    var prompterWordsPerMinute: Double = 150
    var prompterVoiceFollow = false

    // Extras
    var quickCaptureFile = "~/Documents/Quick Capture.md"
    var quickCaptureHotkey = "ctrl+alt+n"   // "" turns it off
    var skimFolders: [String] = []       // folders whose open [!ASK] boxes are counted
    var agentAwayStatus = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        func number(_ key: CodingKeys, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            let v = value(key, fallback)
            return v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : fallback
        }
        func integer(_ key: CodingKeys, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            min(max(value(key, fallback), range.lowerBound), range.upperBound)
        }
        func percents(_ key: CodingKeys, _ fallback: [Int]) -> [Int] {
            Array(Set(value(key, fallback).filter { (1...100).contains($0) })).sorted(by: >)
        }
        let d = Config()

        collapseDelay = number(.collapseDelay, d.collapseDelay, 0...5)
        hoverDelay = number(.hoverDelay, d.hoverDelay, 0...1)
        hoverToPeek = value(.hoverToPeek, d.hoverToPeek)
        panelWidth = number(.panelWidth, d.panelWidth, 480...1400)
        panelHeight = number(.panelHeight, d.panelHeight, 230...700)
        // Unknown names are dropped and tabs added in later versions are appended,
        // so an old file never hides a new tab.
        var order: [NotchTab] = []
        for name in value(.tabs, [String]()) {
            if let tab = NotchTab(rawValue: name), !order.contains(tab) { order.append(tab) }
        }
        tabs = order + NotchTab.allCases.filter { !order.contains($0) }
        hiddenTabs = value(.hiddenTabs, [String]()).compactMap(NotchTab.init(rawValue:))

        terminalHotkey = value(.terminalHotkey, d.terminalHotkey)
        terminalFontSize = number(.terminalFontSize, d.terminalFontSize, 8...32)
        terminalScrollback = integer(.terminalScrollback, d.terminalScrollback, 500...200_000)
        terminalWidth = number(.terminalWidth, d.terminalWidth, 360...2400)
        terminalHeight = number(.terminalHeight, d.terminalHeight, 200...1600)

        agentApprovals = value(.agentApprovals, d.agentApprovals)
        agentSound = value(.agentSound, d.agentSound)
        usageSource = ["keychain", "off"].contains(value(.usageSource, d.usageSource)) ? value(.usageSource, d.usageSource) : d.usageSource
        usageAlerts = percents(.usageAlerts, d.usageAlerts)
        apiCostEstimate = value(.apiCostEstimate, d.apiCostEstimate)

        clipboardHotkey = value(.clipboardHotkey, d.clipboardHotkey)
        clipboardLimit = integer(.clipboardLimit, d.clipboardLimit, 5...500)
        clipboardAutoPaste = value(.clipboardAutoPaste, d.clipboardAutoPaste)
        shelfKeepHours = number(.shelfKeepHours, d.shelfKeepHours, 0...8760)

        batteryAlerts = percents(.batteryAlerts, d.batteryAlerts)
        diskAlertGB = number(.diskAlertGB, d.diskAlertGB, 0...1000)
        statsInEars = value(.statsInEars, d.statsInEars)

        calendarEnabled = value(.calendarEnabled, d.calendarEnabled)
        calendarDays = integer(.calendarDays, d.calendarDays, 1...31)
        meetingAlertMinutes = integer(.meetingAlertMinutes, d.meetingAlertMinutes, 0...60)
        hiddenCalendars = value(.hiddenCalendars, d.hiddenCalendars)

        capsLockHUD = value(.capsLockHUD, d.capsLockHUD)
        cameraGuard = value(.cameraGuard, d.cameraGuard)
        micGuard = value(.micGuard, d.micGuard)
        lockNotice = value(.lockNotice, d.lockNotice)
        downloads = value(.downloads, d.downloads)
        nowPlaying = value(.nowPlaying, d.nowPlaying)
        nowPlayingHideWhenPaused = value(.nowPlayingHideWhenPaused, d.nowPlayingHideWhenPaused)

        prompterFolder = value(.prompterFolder, d.prompterFolder)
        prompterFontSize = number(.prompterFontSize, d.prompterFontSize, 10...60)
        prompterSpeed = number(.prompterSpeed, d.prompterSpeed, 5...300)
        prompterWidth = number(.prompterWidth, d.prompterWidth, 240...1000)
        prompterWordsPerMinute = number(.prompterWordsPerMinute, d.prompterWordsPerMinute, 60...400)
        prompterVoiceFollow = value(.prompterVoiceFollow, d.prompterVoiceFollow)

        quickCaptureFile = value(.quickCaptureFile, d.quickCaptureFile)
        quickCaptureHotkey = value(.quickCaptureHotkey, d.quickCaptureHotkey)
        skimFolders = value(.skimFolders, d.skimFolders)
        agentAwayStatus = value(.agentAwayStatus, d.agentAwayStatus)
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DynamicNotch", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Expands a leading `~` in a path from the settings file.
    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// What the settings file holds right now.
    enum Stored: Equatable {
        case missing
        case ok(Config)
        case unreadable          // a syntax error, or not a JSON object
    }

    /// Reads the file without writing anything.
    static func read(from url: URL = fileURL) -> Stored {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return parse(data)
    }

    static func parse(_ data: Data) -> Stored {
        guard let config = try? JSONDecoder().decode(Config.self, from: data) else { return .unreadable }
        return .ok(config)
    }

    /// At launch: creates a missing file, and never writes over one that doesn't parse.
    static func load() -> Config {
        switch read() {
        case .missing:
            let fresh = Config()
            fresh.save()
            return fresh
        case .unreadable:
            // Never overwrite a file the user may be in the middle of editing.
            Log.app.error("config.json is unreadable; using defaults")
            return Config()
        case .ok(let config):
            config.writeInNewKeys()
            return config
        }
    }

    /// Settings added in a newer version get written in, with their defaults, so they
    /// show up in the file. Only when keys are missing; the user's values are kept.
    private func writeInNewKeys() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let full = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any],
              !Set(full.keys).isSubset(of: Set(raw.keys)) else { return }
        save()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
        } catch {
            Log.app.error("could not save config.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
