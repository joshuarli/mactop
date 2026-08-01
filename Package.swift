// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mactop",
    platforms: [.macOS("15.7")],
    products: [
        .library(name: "mactopCore", targets: ["mactopCore"]),
        .executable(name: "mactop", targets: ["mactop"]),
        .executable(name: "mactopBench", targets: ["mactopBench"]),
    ],
    targets: [
        .target(
            name: "mactopCore",
            path: "Sources/mactop/Core",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "mactop",
            dependencies: ["mactopCore"],
            path: "Sources/mactop/UI",
            swiftSettings: [.swiftLanguageMode(.v5)],
        ),
        .executableTarget(
            name: "mactopBench",
            dependencies: ["mactopCore"],
            path: "Sources/mactopBench",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(
            name: "mactopTests",
            dependencies: ["mactopCore"]
        ),
    ]
)
