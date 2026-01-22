// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CCStatusBar",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "CCStatusBarLib",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CCStatusBarLib"
        ),
        .executableTarget(
            name: "CCStatusBar",
            dependencies: ["CCStatusBarLib"],
            path: "Sources/CCStatusBar"
        ),
        .testTarget(
            name: "CCStatusBarTests",
            dependencies: ["CCStatusBarLib"],
            path: "Tests"
        ),
    ]
)
