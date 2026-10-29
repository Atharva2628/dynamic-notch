// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DynamicNotch",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "DynamicNotch",
            dependencies: ["SwiftTerm"],
            path: "src",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pinned copy of github.com/migueldeicaza/SwiftTerm (MIT); see vendor/SwiftTerm/VENDORED.md.
        .target(
            name: "SwiftTerm",
            path: "vendor/SwiftTerm/Sources/SwiftTerm"
        ),
    ]
)
