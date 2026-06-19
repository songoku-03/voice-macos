// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "soundssource",
    platforms: [
        .macOS(.v14)
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
        .target(
            name: "HALPlugin",
            dependencies: [],
            path: "Sources/HALPlugin"
        ),
        .executableTarget(
            name: "SoundsSource",
            dependencies: ["Core", "Engine", "UI"],
            path: "Sources/SoundsSource",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        )
    ]
)
