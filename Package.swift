// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shotput",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Shotput",
            path: "Sources/Shotput",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
