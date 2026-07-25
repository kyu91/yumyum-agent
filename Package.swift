// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "YumYum",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "YumYumCore", targets: ["YumYumCore"]),
        .executable(name: "yumyum-probe", targets: ["YumYumProbe"]),
        .executable(
            name: "yumyum-process-fixture",
            targets: ["YumYumProcessFixture"]
        ),
    ],
    targets: [
        .target(name: "YumYumCore"),
        .executableTarget(
            name: "YumYumProbe",
            dependencies: ["YumYumCore"]
        ),
        .executableTarget(name: "YumYumProcessFixture"),
        .testTarget(
            name: "YumYumCoreTests",
            dependencies: [
                "YumYumCore",
                "YumYumProbe",
                "YumYumProcessFixture",
            ]
        ),
    ]
)
