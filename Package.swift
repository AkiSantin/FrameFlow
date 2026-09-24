// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "FrameFlow",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrameFlowCore", targets: ["FrameFlowCore"]),
        .library(name: "FrameFlowUI", targets: ["FrameFlowUI"]),
        .executable(name: "FrameFlowApp", targets: ["FrameFlowApp"]),
        .executable(name: "FrameFlowHarness", targets: ["FrameFlowHarness"]),
    ],
    targets: [
        .target(name: "FrameFlowCore"),
        .target(
            name: "FrameFlowUI",
            dependencies: ["FrameFlowCore"],
            exclude: ["Resources"]
        ),
        .executableTarget(name: "FrameFlowApp", dependencies: ["FrameFlowUI"]),
        .executableTarget(
            name: "FrameFlowHarness",
            dependencies: ["FrameFlowCore", "FrameFlowUI"]
        ),
        .testTarget(name: "FrameFlowCoreTests", dependencies: ["FrameFlowCore"]),
        .testTarget(name: "FrameFlowUITests", dependencies: ["FrameFlowUI"]),
    ]
)



