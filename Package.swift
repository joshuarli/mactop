// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mactop",
    platforms: [.macOS("15.7")],
    targets: [
        .executableTarget(
            name: "mactop",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(
            name: "mactopTests",
            dependencies: ["mactop"]
        ),
    ]
)
