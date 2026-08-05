// swift-tools-version: 5.9

import PackageDescription

/// OddsCore — Domain + Data 層。
///
/// 刻意同時支援 macOS：本模組不依賴 UIKit，因此測試可用
/// `swift test --package-path Packages/OddsCore` 直接在命令列跑完，
/// 不需要啟動模擬器（見 CLAUDE.md「指令」）。
/// 這也是「Domain 層不得依賴 UI」這條規則的編譯期證明 —— 一旦有人
/// import UIKit，macOS 平台就會編譯失敗。
let package = Package(
    name: "OddsCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "OddsCore", targets: ["OddsCore"])
    ],
    targets: [
        .target(
            name: "OddsCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "OddsCoreTests",
            dependencies: ["OddsCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
