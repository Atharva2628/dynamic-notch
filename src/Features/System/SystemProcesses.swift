import Darwin
import Foundation
import IOKit

/// Measures every process between two scans and returns the top five by CPU, memory and
/// GPU. Used only on the sampler's queue. Technique from Agent Away's Procs.swift.
///
/// - Your own processes: CPU time from proc_pid_rusage (deltas between scans, like
///   Activity Monitor) and memory as the physical footprint.
/// - Other users' processes (WindowServer, root daemons): the kernel only gives their
///   rusage to root, so CPU and memory come from `ps`, which is setuid root. Its CPU is
///   a decaying average and its memory the resident size.
/// - GPU for all: the GPU driver's per-client accounting in the IORegistry.
final class SystemProcessScanner {
    /// A specific process, not just a pid (pids get reused).
    private struct Key: Hashable {
        let pid: pid_t
        let start: UInt64
    }

    private var lastCPU: [Key: UInt64] = [:]
    private var lastGPU: [pid_t: UInt64] = [:]
    private var lastUptime: TimeInterval?
    /// ps's last answer. Its CPU is already a moving average, so running it every few
    /// seconds instead of every second loses nothing and saves a process launch a second.
    private var ps: (table: [pid_t: (cpu: Double, rss: UInt64)], uptime: TimeInterval)?

    /// rusage times are mach ticks on Apple Silicon.
    private static let nanosPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(max(tb.denom, 1))
    }()

    /// The top five by each measure. CPU and GPU are measured since the previous scan, so
    /// after the first scan (or a long gap) their lists are empty and `measured` is false.
    func scan() -> (top: [SystemSortKey: [SystemProcess]], measured: Bool) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let dt = lastUptime.map { uptime - $0 } ?? 0
        let measured = dt > 0.2 && dt < 60
        lastUptime = uptime

        let gpuNow = Self.gpuNanosByPid()
        func gpu(_ pid: pid_t) -> Double {
            guard measured, let now = gpuNow[pid], let before = lastGPU[pid], now >= before else { return 0 }
            return Double(now - before) / 1e9 / dt * 100
        }
        var cpuNow: [Key: UInt64] = [:]
        var list: [SystemProcess] = []
        var denied: [pid_t] = []
        for pid in Self.allPids() where pid >= 0 {
            var usage = rusage_info_v2()
            let rc = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard rc == 0 else {
                if errno == EPERM { denied.append(pid) }
                continue
            }
            let key = Key(pid: pid, start: usage.ri_proc_start_abstime)
            let cpu = UInt64(Double(usage.ri_user_time &+ usage.ri_system_time) * Self.nanosPerTick)
            cpuNow[key] = cpu
            var p = SystemProcess(pid: pid, name: "", memory: usage.ri_phys_footprint, gpu: gpu(pid))
            if measured, let before = lastCPU[key], cpu >= before { p.cpu = Double(cpu - before) / 1e9 / dt * 100 }
            list.append(p)
        }
        if !denied.isEmpty {
            if ps.map({ uptime - $0.uptime }) ?? .infinity >= 3 { ps = (Self.psTable(), uptime) }
            let table = ps?.table ?? [:]
            for pid in denied {
                guard let row = table[pid] else { continue }
                list.append(SystemProcess(pid: pid, name: "", cpu: measured ? row.cpu : 0, memory: row.rss, gpu: gpu(pid)))
            }
        }
        lastCPU = cpuNow
        lastGPU = gpuNow

        // Names and icons only for the few that are shown.
        var top: [SystemSortKey: [SystemProcess]] = [:]
        var labels: [pid_t: (name: String, app: String?)] = [:]
        for key in SystemSortKey.allCases {
            top[key] = SystemMath.top(list, by: key).map { p in
                var p = p
                let label = labels[p.pid] ?? Self.label(p.pid)
                labels[p.pid] = label
                p.name = label.name
                p.appPath = label.app
                return p
            }
        }
        return (top, measured)
    }

    private static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return got > 0 ? Array(pids.prefix(Int(got))) : []
    }

    /// The executable's full name (kinfo_proc's is cut at 16 characters) and its app.
    /// The path is readable for every process, whoever owns it.
    private static func label(_ pid: pid_t) -> (name: String, app: String?) {
        if pid == 0 { return ("kernel_task", nil) }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let text = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let name = (text as NSString).lastPathComponent
            return (name.isEmpty ? "pid \(pid)" : name, SystemMath.outermostApp(text))
        }
        var short = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        proc_name(pid, &short, UInt32(short.count))
        let name = short.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return (name.isEmpty ? "pid \(pid)" : name, nil)
    }

    /// `ps -A -o pid=,pcpu=,rss=`: CPU % and resident bytes for every process. Gives up
    /// after 5 s.
    private static func psTable() -> [pid_t: (cpu: Double, rss: UInt64)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,pcpu=,rss="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return [:] }
        return SystemMath.parsePS(String(decoding: data, as: UTF8.self))
    }

    /// GPU time per process in nanoseconds, from the Apple GPU driver's per-client
    /// accounting in the IORegistry (readable without root; what Activity Monitor shows).
    private static func gpuNanosByPid() -> [pid_t: UInt64] {
        var out: [pid_t: UInt64] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXDeviceUserClient"), &iterator) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            // "pid 412, WindowServer"
            guard let creator = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let pid = pid_t(creator.dropFirst(4).prefix(while: { $0 != "," })),
                  let usage = IORegistryEntryCreateCFProperty(entry, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]] else { continue }
            for u in usage { out[pid, default: 0] &+= (u["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0 }
        }
        return out
    }
}
