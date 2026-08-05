# OddsBoard — 即時賽事賠率系統

以 UIKit + MVVM 實作的即時賽事賠率看板。模擬 REST API 與 WebSocket 推播，
在每秒數十至數百筆賠率更新下維持列表順暢，且**不做整頁 reload**。

| | |
|---|---|
| UI | UIKit（純程式碼，無 Storyboard）｜SnapKit |
| 架構 | MVVM + 本地 SPM 模組切分 |
| 非同步 | Swift Concurrency（actor / AsyncStream）+ Combine（UI 綁定） |
| 最低版本 | iOS 16.0 |
| 第三方相依 | 僅 SnapKit，且僅限 UI 層 |

## 文件

| 檔案 | 內容 |
|---|---|
| [`docs/spec.md`](docs/spec.md) | 功能規格書。**唯一真實來源**，含每條需求的來源標記與設計理由 |
| [`CLAUDE.md`](CLAUDE.md) | 專案憲法：不可違反的規則、架構、非同步邊界 |
| [`docs/sdd-progress.md`](docs/sdd-progress.md) | 開發進度與關鍵決策紀錄 |
| `ARCHITECTURE.md` | 架構說明文件（D5 產出） |

## 專案結構

```
OddsBoard.xcodeproj
├── OddsBoard/              App target — Composition Root + Scene 啟動
└── Packages/
    ├── OddsCore/           Domain + Data。零第三方相依，不得 import UIKit
    └── OddsUI/             Presentation。UIKit / SnapKit / Combine
```

依賴方向永遠向下：`App → OddsUI → OddsCore`。

`OddsCore` 同時宣告支援 macOS —— 這不是為了跑在 Mac 上，而是讓
「Domain 層不得依賴 UI」成為**編譯期保證**：一旦有人 import UIKit，macOS
平台立刻編譯失敗。附帶好處是它的測試不需要模擬器。

## 執行

```bash
open OddsBoard.xcodeproj
```

首次開啟時 Xcode 會自動解析 SnapKit，需要網路。

## 測試

```bash
swift test --package-path Packages/OddsCore
```

Domain / Data 層的測試不依賴 UIKit，可直接在命令列跑完，無需模擬器。
所有時間相關邏輯（網路延遲、重連退避、快取 TTL）都走注入的 `AppClock`，
測試中不會真的等待。

## 品質閘門

專案的硬性規則不靠自律，而是由 SwiftLint 在**每次 build 時**強制執行，
違反即 build 失敗：

| 規則 | 理由 |
|---|---|
| 禁止 `reloadData()` | 本題核心驗收條件是「賠率更新不整頁 reload」 |
| 禁止 `import SwiftUI` | 考題硬性限制 |
| 禁止 RxSwift | 考題指定 Swift Concurrency 或 Combine |
| 禁止 `NSLock` / `DispatchSemaphore` | 共享可變狀態一律由 actor 保護 |
| 禁止 `Thread.sleep` | 時間邏輯走注入的時鐘，測試不得真的等待 |

```bash
brew install swiftlint   # 未安裝時 build 不會失敗，但會發出警告
swiftlint --strict
```
