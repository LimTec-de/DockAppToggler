// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DockAppToggler",
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
            swiftSettings: [
                .unsafeFlags(["-enable-bare-slash-regex"])
            ]
        )
    ]
)
