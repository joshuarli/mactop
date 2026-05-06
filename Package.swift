// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mactop",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "mactop",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        )
    ]
)
