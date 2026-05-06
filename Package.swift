// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mactop",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/realm/SwiftLint.git", from: "0.57.0"),
    ],
    targets: [
        .executableTarget(
            name: "mactop",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ],
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint"),
            ]
        )
    ]
)
