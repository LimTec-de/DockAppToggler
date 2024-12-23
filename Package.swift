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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.5.1")
    ],
    targets: [
        .executableTarget(
            name: "DockAppToggler",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-bare-slash-regex"])
            ],
            linkerSettings: [
                .linkedFramework("Sparkle")
            ]
        )
    ]
)
