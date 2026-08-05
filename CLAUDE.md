# OddsBoard — 專案憲法

即時賽事賠率系統。完整需求見 `docs/spec.md`（**唯一真實來源**），進度見 `docs/sdd-progress.md`。

## 不可違反的規則

1. **UIKit only。禁止 `import SwiftUI`。** 這是考題硬性限制，由 SwiftLint 強制。
2. **禁止 `tableView.reloadData()`。** 本題核心驗收條件是「賠率更新不整頁 reload」。由 SwiftLint 強制為 error。
3. **禁止 RxSwift / RxCocoa。** 它們會取代考題指定的 Swift Concurrency / Combine。
4. **`OddsCore` 不得 import UIKit、不得引入第三方套件。** 由 SPM 模組邊界在編譯期強制。
5. **實作與 `docs/spec.md` 衝突時，改實作。** 要改規格，先改 spec 再改碼。
6. **每修一個 bug，留下一條讓它不可能再發生的規則**（測試或 lint rule），而不是只改程式碼。

## 架構

```
App target (OddsBoard/)     ← Composition Root、AppDelegate/SceneDelegate。只做組裝
Packages/OddsCore           ← Domain + Data。零第三方相依，禁 UIKit
Packages/OddsUI             ← Presentation。可用 UIKit / SnapKit / Combine
```

依賴方向永遠向下：`App → OddsUI → OddsCore`。跨層一律走 protocol，具體型別只在 `AppDependencies` 組裝。

## 非同步邊界（一句話）

> **跨執行緒存取狀態 → Swift Concurrency。狀態變動通知 UI → Combine。**

- 共享可變狀態一律放 `actor OddsStore`。不使用 `NSLock` / `DispatchQueue` + barrier。
- 事件流用 `AsyncStream`。
- ViewModel / ViewController 標記 `@MainActor`。
- UI 更新節流用自製 coalescer，**不用 `Combine.throttle`**（它會丟事件，我們要的是合併）。

## 技術棧

| 項目 | 值 |
|---|---|
| Deployment target | iOS 16.0 |
| Swift | 5 language mode + `-strict-concurrency=complete` |
| UI | 純程式碼，無 Storyboard（`LaunchScreen.storyboard` 除外） |
| 版面配置 | SnapKit（**僅限 `OddsUI`**） |
| 測試 | XCTest。`OddsCore` 用 `swift test` 跑，不需模擬器 |

## 指令

```bash
# OddsCore 測試（快，約 2 秒，無需模擬器）— 開發時的主要迴圈
swift test --package-path Packages/OddsCore

# 完整 build（需模擬器）
xcodebuild -project OddsBoard.xcodeproj -scheme OddsBoard \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Lint
swiftlint --strict
```

## 給 agent 的行為指令

- 動工前先讀 `docs/sdd-progress.md`，完成任何一個階段後更新它。
- 實作範圍不得超出 `docs/spec.md` 所定義的內容。
- 時間相關邏輯（節流視窗、重連退避、快取 TTL）一律走注入的 `AppClock`，**測試中絕不真的 sleep**。
- 隨機資料一律用固定 seed，確保測試可重現。
- 本專案的驗證由使用者自行執行，除非被要求，否則不主動跑 build 或模擬器。
