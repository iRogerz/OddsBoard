// swift-tools-version: 5.9

import PackageDescription

/// OddsUI — Presentation 層（ViewController / ViewModel / Cell）。
///
/// 只有這個模組能 import UIKit 與 SnapKit。`OddsCore` 不行 ——
/// 那條規則由「OddsCore 同時支援 macOS」在編譯期強制（見 OddsCore/Package.swift）。
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
        .package(url: "https://github.com/SnapKit/SnapKit.git", .upToNextMajor(from: "5.7.0"))
    ],
    targets: [
        .target(
            name: "OddsUI",
            dependencies: [
                "OddsCore",
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
