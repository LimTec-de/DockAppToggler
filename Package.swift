// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DockAppToggler",
    version: "1.0.0",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "DockAppToggler",
            targets: ["DockAppToggler"]
        )
    ],
    targets: [
        .executableTarget(
            name: "DockAppToggler",
            resources: [
                .copy("Resources/icon.png")
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-bare-slash-regex"])
            ]
        )
    ]
)
