// swift-tools-version: 5.9

import PackageDescription

/// OddsPresentation — ViewModel 層。
///
/// 為什麼要與 `OddsUI` 分開：ViewModel 不依賴 UIKit，只用 Combine 對外綁定。
/// 把它留在 iOS-only 的 `OddsUI` 裡，它的測試就得靠模擬器跑 —— 而 ViewModel
/// 正是 MVVM 最該被測的一層。獨立成支援 macOS 的模組後，
/// `swift test` 就能在命令列驗證它。
///
/// 同時這也讓「ViewModel 不得碰 UIKit」成為編譯期保證，而不是口頭約定：
/// 一旦有人在 ViewModel 裡 import UIKit，macOS 平台立刻編譯失敗。
let package = Package(
    name: "OddsPresentation",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "OddsPresentation", targets: ["OddsPresentation"])
    ],
    dependencies: [
        .package(path: "../OddsCore")
    ],
    targets: [
        .target(
            name: "OddsPresentation",
            dependencies: ["OddsCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "OddsPresentationTests",
            dependencies: ["OddsPresentation"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
