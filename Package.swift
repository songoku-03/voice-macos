// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "soundssource",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "SoundsSource", targets: ["SoundsSource"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Core",
            dependencies: [],
            path: "Sources/Core"
        ),
        .target(
            name: "Engine",
            dependencies: ["Core"],
            path: "Sources/Engine"
        ),
        .target(
            name: "UI",
            dependencies: ["Core", "Engine"],
            path: "Sources/UI"
        ),
        .executableTarget(
            name: "SoundsSource",
            dependencies: ["Core", "Engine", "UI"],
            path: "Sources/SoundsSource",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        ),
        .testTarget(
            name: "EngineTests",
            dependencies: ["Engine", "Core"],
            path: "Tests/EngineTests"
        )
    ]
)
