import AppKit

// Entry point. Flags for checks that need no running app:
//   --selftest        run the built-in checks and exit (0 = all passed)
//   --geometry        print each screen's notch geometry and exit
//   --snapshot DIR    render every notch state to PNG files in DIR and exit
//   --cost            add up Claude Code's transcripts at API prices (nothing saved) and exit

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    exit(MainActor.assumeIsolated { SelfTest.run() } ? 0 : 1)
}

let app = NSApplication.shared

if arguments.contains("--geometry") {
    MainActor.assumeIsolated { GeometryReport.print() }
    exit(0)
}

if let i = arguments.firstIndex(of: "--snapshot") {
    guard i + 1 < arguments.count else {
        FileHandle.standardError.write(Data("usage: DynamicNotch --snapshot DIR\n".utf8))
        exit(2)
    }
    let dir = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
    exit(MainActor.assumeIsolated { Snapshots.render(to: dir) } ? 0 : 1)
}

if arguments.contains("--cost") {
    let started = Date()
    let r = AgentsCostScanner(root: AgentsCostScanner.defaultRoot, store: nil).scan(save: false)
    print(String(format: "scanned in %.1f s", Date().timeIntervalSince(started)))
    print("today \(AgentsCostFormat.dollars(r.today)) · 7 days \(AgentsCostFormat.dollars(r.week)) · 30 days \(AgentsCostFormat.dollars(r.month))")
    for m in r.models { print("  \(AgentsCostFormat.modelName(m.id)): \(AgentsCostFormat.dollars(m.cost)), \(AgentsCostFormat.tokens(m.tokens)) tokens") }
    print("last 14 days:", r.days.map { "\($0.id.suffix(5)) \(AgentsCostFormat.dollars($0.cost))" }.joined(separator: ", "))
    if r.unpriced > 0 { print("unpriced responses: \(r.unpriced)") }
    exit(0)
}

// One copy at a time: a second launch (login item plus a manual open) quits quietly.
let bundleID = Bundle.main.bundleIdentifier ?? "local.dynamicnotch"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .contains(where: { $0 != NSRunningApplication.current }) {
    exit(0)
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
