import Foundation
import os

// Read with: log stream --predicate 'subsystem == "local.dynamicnotch"'
enum Log {
    static let app = Logger(subsystem: "local.dynamicnotch", category: "app")
    static let notch = Logger(subsystem: "local.dynamicnotch", category: "notch")
}

extension Bundle {
    var version: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}
