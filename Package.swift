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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"),
    ],
    targets: [
        .target(name: "ReserveCore"),
        .executableTarget(
            name: "Reserve",
            dependencies: [
                "ReserveCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.copy("Resources/ProviderLogos"), .copy("Resources/ClaudeLoginBrowser.sh")],
            swiftSettings: [
                .define("RESERVE_DEV_AUTOMATION", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
                ])
            ]),
        .executableTarget(
            name: "ReserveProbe",
            dependencies: ["ReserveCore"]),
        .executableTarget(
            name: "ReserveSelfTest",
            dependencies: ["ReserveCore"],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "ReserveCoreTests", dependencies: ["ReserveCore"]),
    ])
