# OddsBoard — 即時賽事賠率系統

100 場比賽的即時賠率看板。資料來自模擬的 REST API 與模擬的 WebSocket 推播。

這個專案要解的是兩件互相拉扯的事：**資料要即時**（推播每秒數十至數百筆，
畫面上的數字必須是現值），**畫面要順**（使用者正在滾動，任何多餘的重繪都會被看見）。

天真的做法是「收到一筆更新一次畫面」，在每秒 10 筆時看起來正常，
在每秒 1000 筆時會卡死。本專案的核心主張是：

> **UI 的更新頻率應該由畫面的刷新節奏決定，而不是由資料的到達節奏決定。**

因此賠率更新的路徑是「actor 仲裁 → 合併成批 → 只更新看得見的列 →
`CADisplayLink` 對齊幀邊界」，**全程不呼叫 `reloadData()`**
—— 而且這條規則是 SwiftLint 的 error 級規則，寫了就編譯不過。

| | |
|---|---|
| UI | UIKit（純程式碼，無 Storyboard）｜SnapKit |
| 架構 | MVVM + 四層本地 SPM 模組 |
| 非同步 | Swift Concurrency（actor / AsyncStream）+ Combine（UI 綁定） |
| 最低版本 | iOS 16.0 |
| 第三方相依 | 僅 SnapKit，且僅限 UI 層 |
| 測試 | 139 支，核心測試不需模擬器 |

## 文件

**建議面試官只需要讀 [`ARCHITECTURE.md`](ARCHITECTURE.md)**：回答作業點名的三題
（Concurrency/Combine 使用場景、thread-safe、UI 綁定），並列出已知限制與未完成部分。
以下是其餘文件，供想深入的人選讀：

| 檔案 | 內容 |
|---|---|
| [`docs/spec.md`](docs/spec.md) | 功能規格書。每條需求都標了來源：📄 文件要求／⭐ 加分題／🧩 我方主動補的設計。開發過程的規劃文件，比 `ARCHITECTURE.md` 詳細很多 |
| [`docs/verification.md`](docs/verification.md) | Instruments 檢查清單與錄影腳本。每項都寫死「看什麼、什麼算通過」 |
| [`CLAUDE.md`](CLAUDE.md) | 專案憲法：不可違反的規則、架構、非同步邊界 |
| [`docs/sdd-progress.md`](docs/sdd-progress.md) | 開發進度與逐條決策紀錄（開發過程用，非交件內容） |

## 操作影片

**▶ [OddsBoard 操作示範](https://www.youtube.com/watch?v=Hy7F4Z-h2Yo)**

依序展示：列表排序與 100 場資料 → 賠率跳動時只有變動的那一格閃爍 →
加壓至 1000 筆/秒後滾動仍順暢（HUD 顯示 `reloadData 0`）→ 模擬斷線後的
指數退避重連與全量對帳 → 載入失敗與恢復 → 詳情頁往返 → 冷啟動的磁碟快取。

效能實測數據與 Instruments 截圖見 [`ARCHITECTURE.md` §5](ARCHITECTURE.md)。

## 執行

```bash
open OddsBoard.xcodeproj
```

選 `OddsBoard` scheme，⌘R。首次開啟時 Xcode 會自動解析 SnapKit，需要網路。

### Debug 面板（建議一定要試）

點右上角的 **Debug** 按鈕開啟。可以：

| 功能 | 用途 |
|---|---|
| 推播 10 / 100 / 1000 筆每秒 | 作業要求「每秒最多 10 筆」，但那對 `UITableView` 不算壓力。加到 100 倍再滾動，才看得出架構撐不撐得住 |
| 模擬斷線 | 觸發指數退避重連，以及重連後的**全量對帳** |
| 模擬載入失敗 | 讓 API 進入失敗模式並重新載入。畫面會**完全靜止**（推播一併中斷）並顯示錯誤，再按一次可恢復 |
| 顯示 / 隱藏 HUD | 常駐顯示 `推播／套用／丟棄／UI 批次數／p95 延遲／reloadData 次數` |

HUD 上的 `reloadData 0` 與「UI 批次數遠低於推播數」兩個數字，
是本題核心驗收條件最直接的證據。

## 測試

```bash
swift test --package-path Packages/OddsCore
```

```bash
swift test --package-path Packages/OddsPresentation
```

139 支測試中有 111 支在這兩個模組。它們不依賴 UIKit，因此 SwiftPM 能為 macOS
建置並直接執行 —— 無需模擬器，秒級完成。這是開發時的主要迴圈。

需要真實 UIKit 環境的 UI 測試（27 支）在 App target 底下的 `OddsBoardTests`，
用 ⌘U 或 `xcodebuild test` 執行。

> **已知限制**：以 `XCLocalSwiftPackageReference` 掛在 `.xcodeproj` 下的 local
> package，Xcode 不會把它們的測試目標列進 scheme 的 test action（自動產生的
> package scheme 也只有 build action）。要在 Xcode 內以 ⌘U 跑，需改用
> `.xcworkspace` 架構。本專案選擇不轉換：核心測試用 SwiftPM 更快。
> 完整的限制清單見 [`ARCHITECTURE.md` §7](ARCHITECTURE.md#7-已知限制與未完成的部分)。

所有時間相關邏輯（網路延遲、重連退避、快取 TTL）都走注入的 `AppClock`，
**測試中不會真的等待**。所有隨機資料都用固定種子，同一個種子永遠得到同一份資料。

## 專案結構

```
OddsBoard.xcodeproj
├── OddsBoard/              App target — Composition Root + Scene 啟動
├── OddsBoardTests/         UI 層測試（需真實 UITableView）
└── Packages/
    ├── OddsCore/           Domain + Data。零第三方相依，不得 import UIKit
    ├── OddsPresentation/   ViewModel。可用 Combine，不得 import UIKit
    └── OddsUI/             View 層。UIKit / SnapKit
```

依賴方向永遠向下：`App → OddsUI → OddsPresentation → OddsCore`。
跨層一律走 protocol，具體型別只在 `AppDependencies` 出現。

`OddsCore` 與 `OddsPresentation` 同時宣告支援 macOS —— 這不是為了跑在 Mac 上，
而是讓「這兩層不得依賴 UI」成為**編譯期保證**：一旦有人 import UIKit，macOS
平台立刻編譯失敗。附帶好處是它們的測試不需要模擬器，包含最該被測的 ViewModel。

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
