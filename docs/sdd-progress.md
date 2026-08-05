# SDD 進度狀態

> ⚠️ 請勿刪除。這是跨對話的記憶檔。每次開新 session 先讀這份。

**專案**：OpenNet iOS Take-Home — 即時賽事賠率系統
**最後更新**：2026-08-05

---

## 目前階段

**Phase 4 — PEV 迴圈實作中。D1 完成，待人工驗證後進 D2**

> ⚠️ **D1 的程式碼尚未經過編譯或測試執行。** 使用者要求由他自行驗證
> （見下方決策紀錄 2026-08-05「驗證分工」）。下次 session 若要接手，
> 請先確認 `swift test --package-path Packages/OddsCore` 是綠的。

---

## 已完成

- [x] **Phase 1 Brain Dump** — 來源為 `OpenNet_IOS_Home_Test.pdf`，已完整抽出文字（2 頁）
- [x] **Phase 2 Spec Interview** — 已問 2 題並取得決議（見下方決策紀錄）
- [x] **Phase 3a Feature Spec** — `docs/spec.md` v0.1 草案完成

- [x] **開工前置作業** — Xcode 專案 `OddsBoard` 建立完成、Storyboard 移除、手動 UIWindow 啟動可運行
- [x] **Repo 建立並推送** — `git@github.com:iRogerz/OddsBoard.git`（private）

- [x] **Phase 3b** — `CLAUDE.md` 專案憲法完成
- [x] **品質閘門** — `.swiftlint.yml` 五條 custom rule，已掛進 build phase；
      以探針檔實測四條規則皆正確觸發 error
- [x] **SPM 模組** — `Packages/OddsCore`、`Packages/OddsUI` 建立並接進 xcodeproj
- [x] **D1** — Domain 模型、`AppClock`、`SeededGenerator`、`MockAPIClient`、
      `actor OddsStore` 與 3 個測試檔（共 30 個測試案例）

- [x] **D1 已由使用者驗證** — `swift test` 全數通過、Xcode build 成功
- [x] **D2** — `OddsStreaming` protocol、`MockOddsSocket`、`UpdateCoalescer`、
      `StreamStats`、`MatchListViewModel`，新增 `Packages/OddsPresentation` 模組

## 待辦

- [x] **D2 已驗證** — 69 passed / 0 failures
- [x] **D3** — `MatchCell`、`MatchListViewController`（diffable + CADisplayLink 節拍 +
      可見範圍交集 + 漲跌閃爍）、`MockDataset` 抽離、`OddsBoardTests` 目標與 11 個 UI 測試

- [x] **D3 已驗證** — 模擬器實測閃爍正常；swift test 69 + OddsBoardTests 14 全過
- [x] **Code review 修正輪** — 6 項發現已修（見下方決策紀錄）

## 待辦

- [ ] **人工驗證修正輪**：Xcode build + ⌘U
- [ ] **D4** — 快取、重連 + 對帳、詳情頁、Debug HUD
- [ ] **D5** — `ARCHITECTURE.md`、Instruments 驗證、錄影

### Code review 未處理項（刻意保留，D5 寫進 ARCHITECTURE.md 的「已知限制」）

- `MockOddsSocket` 的連線狀態事件與賠率資料共用會丟棄的 `bufferingNewest(256)`
  緩衝，極高負載下狀態事件可能被丟掉。正解是控制事件走獨立不丟棄的通道。
- `OddsStore.replaceAll` 未清掉不在新資料中的比賽的 `acceptedSequence` 與
  `histories`。本專案比賽集合固定，不會觸發。
- [ ] **D3** — `MatchListViewController` + diffable data source + 更新合併器 + 漲跌閃爍
- [ ] **D4** — 快取、重連 + 對帳、詳情頁、Debug HUD
- [ ] **D5** — `ARCHITECTURE.md`、Instruments 驗證、錄影
- [ ] **Phase 4** — Context Reset (`/clear`) 後進入 PEV 迴圈實作，實作 agent 只讀 `CLAUDE.md` + `docs/spec.md`
- [ ] **Phase 5** — Anti-Drift + Hashimoto（每個 bug 留下一條 lint/test）
- [ ] **Phase 6** — Skill 萃取

---

## 關鍵決策紀錄

| 日期 | 決策 | 理由 |
|---|---|---|
| 2026-08-05 | **UI 用純 UIKit，不用 SwiftUI** | 使用者原本想用 SwiftUI，經指出考題技術限制表格明文「限定使用 UIKit（不可使用 SwiftUI）」後決定照文件走，較保險 |
| 2026-08-05 | **禁 RxSwift，但允許 SnapKit（僅限 `OddsUI`）** | 判準是「是否取代文件指定的技術」而非「有無第三方相依」。RxSwift 會取代 Concurrency/Combine ⇒ 禁；SnapKit 只是 Auto Layout 語法糖 ⇒ 可。原先「零第三方相依」是我方自訂規則、非文件要求，已修正 |
| 2026-08-05 | **採用本地 SPM package：`OddsCore` + `OddsUI`** | 使用者選擇更低耦合。附帶效益：`OddsCore` 無 UIKit ⇒ 測試可用 `swift test` 命令列跑、免模擬器、約 2 秒 |
| 2026-08-05 | **Xcode 專案由使用者手動建立** | 手刻 pbxproj 脆弱；已給出建立參數（App template / Storyboard interface / Testing None / iOS 16.0）|
| 2026-08-05 | **Repo 根目錄設在 `OddsBoard/`，題目 PDF 留在 repo 外層** | 保留 Xcode 既有 git 歷史（不必刪 `.git`），且公司內部題目 PDF 在物理上不可能被誤 push |
| 2026-08-05 | **GitHub repo 設為 private** | take-home 解答若公開會被永久索引；交件時邀請面試官為 collaborator 或屆時再轉 public |
| 2026-08-05 | **驗證分工**：agent 不跑 build 與模擬器，由使用者自行驗證 | 使用者指示。agent 仍會跑不需編譯的檢查（SwiftLint、pbxproj 解析）|
| 2026-08-05 | **`OddsCore` 宣告支援 macOS** | 不是為了跑在 Mac 上，而是讓「Domain 不得 import UIKit」成為編譯期保證，並讓測試免模擬器 |
| 2026-08-05 | **失敗注入改為確定性模式而非機率** | 題目寫「失敗率」，但機率式失敗會造成偶發紅燈，而偶發紅燈最後一定會被忽略。改用 `.never` / `.always` / `.firstCalls(n)` |
| 2026-08-05 | **`OddsChange` 改為兩隊分開記錄方向** | 原 spec §3.1 設計為單一方向；實際上同一次推播中 teamA 漲、teamB 跌是常態，單一方向會漏掉一邊。spec 已同步更新 |
| 2026-08-05 | **關閉 `ENABLE_USER_SCRIPT_SANDBOXING`** | Xcode 15 起 script phase 在 sandbox 內執行，SwiftLint 讀不到 .swiftlint.yml 與原始碼。整棵原始碼樹無法逐一宣告成 input，故關閉。理由記於 CLAUDE.md |
| 2026-08-05 | **新增第三個模組 `OddsPresentation`** | ViewModel 不依賴 UIKit，留在 iOS-only 的 `OddsUI` 會讓它的測試需要模擬器 —— 而 ViewModel 正是 MVVM 最該被測的一層。獨立後測試回到命令列快迴圈 |
| 2026-08-05 | **`UpdateCoalescer` 不做成 actor，時間驅動也留在外面** | 它由 `@MainActor` ViewModel 獨佔持有，做成 actor 只會每幀多付一次 hop；節拍交給 View 層的 `CADisplayLink`，才符合「UI 更新頻率由畫面刷新節奏決定」 |
| 2026-08-05 | **`orderedMatchIDs` 與 row 資料分開發布** | 賠率更新不改變順序，所以 snapshot 不需重 apply；若把 `[MatchRow]` 整包發布，每次更新都要重建 100 筆陣列 |
| 2026-08-05 | **不轉 `.xcworkspace`，local package 測試一律走 `swift test`**（使用者確認）| 以 `XCLocalSwiftPackageReference` 掛在 .xcodeproj 下的 package，Xcode 不會把測試目標列進任何 scheme 的 test action。轉 workspace 需再動一次 pbxproj，換來的只是 ⌘U 的便利性；而核心測試用 SwiftPM 本來就更快 |
| 2026-08-05 | **維持 3 個模組**（使用者確認）| 曾評估併回 2 個。關鍵釐清：測試速度與「禁 import UIKit」的編譯期保證，兩個方案都保留，**唯一差別是依賴方向是編譯期強制或資料夾慣例**。選 3 個以維持「規則由機器強制」這條貫穿全專案的論述 |
| 2026-08-05 | **UI 層測試改用原生 iOS Unit Testing Bundle target** | 已由使用者新增 `OddsBoardTests`。UI 測試要驗的是 `reconfigureItems` 與「未整頁 reload」，需要真實 UITableView；原生 target 也讓 ⌘U 對 UI 測試有意義 |
| 2026-08-05 | **漲跌閃爍改用明確指定 fromValue/toValue 的 `CABasicAnimation`** | **實際發生的 bug，且靠讀程式碼找不到、必須實際跑模擬器才抓到。** 原寫法是 `label.backgroundColor = color` 後用 `UIView.animate` 淡回 `.clear`：設定背景色只寫進 model layer、該 runloop 尚未 commit，UIKit 建立動畫時取到的起始值仍是上一幀的 `.clear`，動畫變成 clear → clear，完全看不見。惡劣之處在於動畫確實被加到 layer 上、`animationKeys()` 有值、無任何警告。Hashimoto 產物：`MatchCellTests.test_閃爍動畫的起始顏色必須是不透明的` 直接斷言 `fromValue` 的 alpha > 0 |
| 2026-08-05 | 動畫改在 `dataSource.apply` 之後觸發，不寫在 cellProvider 內 | 職責分離：cellProvider 只負責內容；且它也會因滾動被呼叫，在那裡播動畫會讓滾過去的格子全在閃。（註：先前一度誤判這是不閃的根因，實際根因見上一列）|
| 2026-08-05 | 除錯方法論：連兩次盲猜失敗後改為實測 | 用「只設背景色、不做動畫」的區隔測試，一次就定位到問題在動畫而非佈局或呼叫路徑。教訓：UIKit 的渲染行為不要靠讀程式碼推論 |
| 2026-08-05 | **`CADisplayLink` 改用弱引用代理 `DisplayLinkProxy`** | `CADisplayLink(target:)` 強引用 target。VC 若走過 `viewWillAppear` 卻沒有配對的 `viewDidDisappear`，就永久洩漏，而 `deinit` 裡的 `invalidate()` 正好在最需要它時執行不到 |
| 2026-08-05 | **flush 加上 `isFlushing` 互斥旗標** | 每個節拍各開 Task 且 flush 內有多個 await 點，前後兩輪交錯時前一輪的 `clearChanges` 會抹掉後一輪剛讀到的漲跌標記，造成漏閃。負載越高越明顯 |
| 2026-08-05 | **事件消費者改為整個生命週期只建立一次；連線改由 `pauseStreaming`/`resumeStreaming` 控制** | 原本 `start()` 只擋 `.loading`，第二次呼叫會對同一個 `AsyncStream` 建立第二個迭代器 —— 單一消費者限制會直接觸發執行期錯誤。同時解決「離開畫面後推播仍持續」的問題 |
| 2026-08-05 | **`MockAPIClient` 不再以延遲種子覆寫資料集種子** | 呼叫端明確指定的 `datasetConfiguration.seed` 被靜默丟棄，資料看起來正常但與預期不同，除錯時極難察覺 |
| 2026-08-05 | **fire-and-forget `Task` 一律明確捕捉相依物件而非 self** | `Task { await viewModel.start() }` 會因存取 self 的屬性而隱式強引用整個 VC，載入完成前無法釋放。改為 `Task { [viewModel] in ... }` |
| 2026-08-05 | **修正一支恆真的測試** | `test_離開畫面後停止產生UI工作` 在 view 未加入 window 時 display link 本就不觸發，把 `stopDisplayLink()` 刪掉照樣過。改為直接斷言節拍狀態，並補上 VC 釋放的洩漏測試（含對照組）|
| 2026-08-05 | **Concurrency 與 Combine 並用，邊界明確** | 跨執行緒狀態存取 → actor/AsyncStream；ViewModel→View 綁定 → Combine。文件的架構說明文件正好要求說明兩者使用場景 |
| 2026-08-05 | Deployment target iOS 16.0 | `reconfigureItems` 需 iOS 15+，是「不整頁 reload」的核心 API |

---

## 尚未解決的問題

見 `docs/spec.md` §12（5 項），全部有預設值，不阻擋開工。

---

## 給下一個 session 的提醒

- 唯一真實來源是 `docs/spec.md`。實作與規格衝突時改實作。
- 本題最核心的驗收條件是「賠率更新不可整頁 reload」→ 對應 spec §4 FR-3.3 的三層策略。
- 規格書用 📄/⭐/🧩/❓ 標記需求來源，🧩 是文件沒寫、我方主動補的設計，交件的架構文件要能逐條解釋。
