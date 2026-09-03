// swift-tools-version: 6.2
import PackageDescription

// Three targets because this machine has Command Line Tools only: XCTest is
// absent and Testing.framework is missing lib_TestingInterop.dylib, so
// `swift test` cannot run. Tests are a plain executable that exits non-zero.
let package = Package(
    name: "Shotput",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "Shotput",
            path: "Sources/Shotput",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-enable-testing"])]
        ),
        .executableTarget(
            name: "ShotputApp",
            dependencies: ["Shotput"],
            path: "Sources/ShotputApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ShotputTests",
            dependencies: ["Shotput"],
            path: "Tests/ShotputTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
