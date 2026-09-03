// swift-tools-version: 6.2
import PackageDescription

// Library + thin executable so tests can @testable import the app code.
// Run tests with ./test.sh, never bare `swift test` — see that script.
let package = Package(
    name: "Shotput",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "Shotput",
            path: "Sources/Shotput",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ShotputApp",
            dependencies: ["Shotput"],
            path: "Sources/ShotputApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ShotputTests",
            dependencies: ["Shotput"],
            path: "Tests/ShotputTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
