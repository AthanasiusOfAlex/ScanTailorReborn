// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ScanTailorReborn",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ScanTailorContracts",
            targets: ["ScanTailorContracts"]
        ),
        .library(
            name: "ScanTailorCore",
            targets: ["ScanTailorCore"]
        ),
        .library(
            name: "ScanTailorPortableBackend",
            targets: ["ScanTailorPortableBackend"]
        ),
        .library(
            name: "ScanTailorAppleBackend",
            targets: ["ScanTailorAppleBackend"]
        ),
        .library(
            name: "ScanTailorPipeline",
            targets: ["ScanTailorPipeline"]
        ),
        .executable(
            name: "scantailor-cli",
            targets: ["ScanTailorCLI"]
        ),
    ],
    targets: [
        .target(
            name: "ScanTailorContracts",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "ScanTailorCore",
            dependencies: ["ScanTailorContracts"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "ScanTailorPipeline",
            dependencies: [
                "ScanTailorContracts",
                "ScanTailorCore"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "ScanTailorPortableBackend",
            dependencies: [
                "ScanTailorContracts",
                "ScanTailorCore"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "ScanTailorAppleBackend",
            dependencies: [
                "ScanTailorContracts",
                "ScanTailorCore",
                "ScanTailorPortableBackend",
                "ScanTailorPipeline"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "ScanTailorCLI",
            dependencies: [
                "ScanTailorContracts",
                "ScanTailorCore",
                "ScanTailorPortableBackend",
                "ScanTailorAppleBackend",
                "ScanTailorPipeline"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ScanTailorContractsTests",
            dependencies: ["ScanTailorContracts"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ScanTailorCoreTests",
            dependencies: [
                "ScanTailorContracts",
                "ScanTailorCore",
                "ScanTailorPipeline",
                "ScanTailorPortableBackend"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ComputeAcceleratorTests",
            dependencies: [
                "ScanTailorContracts",
                "ScanTailorCore",
                "ScanTailorPortableBackend",
                "ScanTailorAppleBackend"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ScanTailorAppleBackendTests",
            dependencies: [
                "ScanTailorContracts",
                "ScanTailorCore",
                "ScanTailorPortableBackend",
                "ScanTailorAppleBackend",
                "ScanTailorPipeline"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
    ]
)
