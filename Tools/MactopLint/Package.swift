// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MactopLint",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "mactopLint",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
    ]
)
