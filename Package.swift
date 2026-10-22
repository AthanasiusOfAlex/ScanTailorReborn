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
    ],
    targets: [
        .target(
            name: "ScanTailorContracts",
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
    ]
)
