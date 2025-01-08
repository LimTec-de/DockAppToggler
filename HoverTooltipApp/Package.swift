// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "HoverTooltipApp",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "HoverTooltipApp", targets: ["HoverTooltipApp"])
    ],
    targets: [
        .executableTarget(
            name: "HoverTooltipApp",
            dependencies: []
        )
    ]
)

