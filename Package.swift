// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MorningContext",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MorningContext",
            path: "Sources/MorningContext",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "MorningContextTests",
            dependencies: ["MorningContext"],
            path: "Tests/MorningContextTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
