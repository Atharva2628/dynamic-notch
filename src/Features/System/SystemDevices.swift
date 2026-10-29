import Foundation
import IOKit

/// Batteries of paired devices. Two sources: the IORegistry, where Apple's HID drivers
/// publish BatteryPercent (Magic Mouse, Keyboard, Trackpad, some other mice), and
/// system_profiler, the only public place AirPods' left, right and case levels show up.
enum SystemDevices {
    /// A registry read: cheap, needs no permission. Call off the main thread.
    static func registryBatteries() -> [SystemDeviceBattery] {
        var out: [SystemDeviceBattery] = []
        for type in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(type), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                func value(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                guard let percent = (value("BatteryPercent") as? NSNumber)?.intValue,
                      let name = value("Product") as? String, !name.isEmpty else { continue }
                out.append(SystemDeviceBattery(
                    name: name, symbol: SystemMath.deviceSymbol(name: name, type: nil),
                    levels: [.init(label: "", percent: min(max(percent, 0), 100))],
                    address: (value("DeviceAddress") as? String).map(SystemMath.normalizeAddress)))
            }
        }
        return SystemMath.mergeDevices(out, [])
    }

    /// Runs `system_profiler SPBluetoothDataType -json` on a background queue (it takes a
    /// second or two) and hands back the connected devices that report a battery. Gives
    /// up after 20 s. `done` runs on that background queue.
    static func bluetoothBatteries(_ done: @escaping @Sendable ([SystemDeviceBattery]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { done([]); return }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            done(process.terminationStatus == 0 ? SystemMath.parseBluetooth(data) : [])
        }
    }
}
