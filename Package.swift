// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UsageBarCore", targets: ["UsageBarCore"]),
        .executable(name: "UsageBar", targets: ["UsageBar"]),
        .executable(name: "usagebar-probe", targets: ["UsageBarProbe"]),
        .executable(name: "usagebar-selftest", targets: ["UsageBarSelfTest"]),
    ],
    targets: [
        .target(name: "UsageBarCore"),
        .executableTarget(
            name: "UsageBar",
            dependencies: ["UsageBarCore"]),
        .executableTarget(
            name: "UsageBarProbe",
            dependencies: ["UsageBarCore"]),
        .executableTarget(
            name: "UsageBarSelfTest",
            dependencies: ["UsageBarCore"],
            resources: [.copy("Fixtures")]),
    ])
