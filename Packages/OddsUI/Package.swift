// swift-tools-version: 5.9

import PackageDescription

/// OddsUI — View 層（ViewController / Cell / Debug HUD）。
///
/// 只有這個模組能 import UIKit 與 SnapKit。`OddsCore` 與 `OddsPresentation`
/// 都不行 —— 那條規則由「兩者同時支援 macOS」在編譯期強制。
let package = Package(
    name: "OddsUI",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "OddsUI", targets: ["OddsUI"])
    ],
    dependencies: [
        .package(path: "../OddsCore"),
        .package(path: "../OddsPresentation"),
        .package(url: "https://github.com/SnapKit/SnapKit.git", .upToNextMajor(from: "5.7.0"))
    ],
    targets: [
        .target(
            name: "OddsUI",
            dependencies: [
                "OddsCore",
                "OddsPresentation",
                "SnapKit"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "OddsUITests",
            dependencies: ["OddsUI"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
