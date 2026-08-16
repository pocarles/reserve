// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reserve",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReserveCore", targets: ["ReserveCore"]),
        .executable(name: "Reserve", targets: ["Reserve"]),
        .executable(name: "reserve-probe", targets: ["ReserveProbe"]),
        .executable(name: "reserve-selftest", targets: ["ReserveSelfTest"]),
    ],
    targets: [
        .target(name: "ReserveCore"),
        .executableTarget(
            name: "Reserve",
            dependencies: ["ReserveCore"],
            resources: [.copy("Resources/ProviderLogos")]),
        .executableTarget(
            name: "ReserveProbe",
            dependencies: ["ReserveCore"]),
        .executableTarget(
            name: "ReserveSelfTest",
            dependencies: ["ReserveCore"],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "ReserveCoreTests", dependencies: ["ReserveCore"]),
    ])
