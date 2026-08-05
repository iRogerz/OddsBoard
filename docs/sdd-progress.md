# SDD 進度狀態

> ⚠️ 請勿刪除。這是跨對話的記憶檔。每次開新 session 先讀這份。

**專案**：OpenNet iOS Take-Home — 即時賽事賠率系統
**最後更新**：2026-08-06

---

## 目前階段

**Phase 4 完成。D1–D4 全部實作、驗證、並通過兩輪 code review 修正。下一步是 D5（交件文件與驗證）。**

---

## 進度

| 階段 | 狀態 |
|---|---|
| Phase 1 Brain Dump（來源 `OpenNet_IOS_Home_Test.pdf`）| ✅ |
| Phase 2 Spec Interview | ✅ |
| Phase 3a Feature Spec `docs/spec.md` | ✅ |
| Phase 3b 專案憲法 `CLAUDE.md` | ✅ |
| 品質閘門（5 條 SwiftLint custom rule，已實測會擋）| ✅ |
| SPM 模組 `OddsCore` / `OddsPresentation` / `OddsUI` | ✅ |
| D1 Domain + `actor OddsStore` + `MockAPIClient` | ✅ 已驗證 |
| D2 `MockOddsSocket` + `UpdateCoalescer` + `MatchListViewModel` | ✅ 已驗證 |
| D3 `UITableView` + diffable + 漲跌閃爍 | ✅ 已驗證 |
| Code review 修正輪（6 項）| ✅ 已驗證 |
| D4 快取 + 重連對帳 + 詳情頁 + Debug HUD | ✅ 已驗證 |
| D4 code review 修正（7 項）| ✅ 已驗證 |
| D5 `ARCHITECTURE.md` + Instruments + 錄影 | ⬜ |
| Phase 6 Skill 萃取 | ⬜ |

**測試數**：`OddsCore` 73 + `OddsPresentation` 32 + `OddsBoardTests` 19 = **124**

**Repo**：https://github.com/iRogerz/OddsBoard （**public**，交件直接貼連結即可）

---

## 待辦（D5：交件前最後一段）

- [ ] **`ARCHITECTURE.md`** — 考題點名要回答的三題：
      Swift Concurrency / Combine 使用場景、如何確保 thread-safe、
      UI 與 ViewModel 綁定方式。**外加「已知限制與未完成部分」**
      （考題最後明說會據此評估，見下方「刻意保留項」）
- [ ] **README 交件版** — 目前偏開發者視角，需補上「這個專案在解什麼問題」的開場
- [ ] **Instruments 驗證** — memory retain、滾動流暢度（需人工操作，可先寫檢查清單）
- [ ] **操作錄影** — 依腳本走一遍。錄影本身也是驗證：凍結、不閃這類 bug 會自己跳出來
- [ ] 建議交件前由使用者跑一次 `/code-review ultra`（多 agent 深度審查，僅使用者可觸發）
- [ ] **Phase 6** — 萃取可重用的 SKILL.md

### 錄影腳本要帶到的考點

1. 列表依開賽時間升序、100 場比賽
2. 賠率跳動時**只有變動的那一格閃綠/閃紅**，整頁不重繪
3. 長按開 Debug 面板 → 加壓到 1000 筆/秒，滾動仍順暢
4. HUD 顯示 reloadData 次數為 0
5. 模擬斷線 → 狀態列顯示重試次數 → 重連後全量對帳
6. 點進詳情頁（賠率與走勢圖持續更新）→ 返回列表**無載入過程**

### 刻意保留、不修的項目（D5 寫進 ARCHITECTURE.md 的「已知限制」）

- `MockOddsSocket` 的連線狀態事件與賠率資料共用會丟棄的 `bufferingNewest(256)`
  緩衝，極高負載下狀態事件可能被丟掉。正解是控制事件走獨立不丟棄的通道。
- `OddsStore.replaceAll` 未清掉不在新資料中的比賽的 `acceptedSequence` 與
  `histories`。本專案比賽集合固定，不會觸發。

---

## 兩輪 code review 的總結（值得寫進 ARCHITECTURE.md）

兩輪各找出 6 項與 7 項問題。**最值得記的是「哪一類 bug 靠什麼方式才抓得到」**：

| bug | 靠什麼發現 |
|---|---|
| 漲跌閃爍完全不生效 | **跑模擬器**。讀程式碼三次都沒抓到，因為動畫確實被加到 layer 上、`animationKeys()` 有值、無任何警告 |
| Debug HUD 的丟棄數灌水 | **盯著畫面上的數字**。型別完全合法 |
| 對帳結果不會抵達畫面 | code review |
| 詳情頁進入即凍結 | code review |
| `CADisplayLink` 保留循環 | code review |

前兩個是最嚴重也最難察覺的，而它們**都不是靠讀程式碼找到的**，而且當時單元測試全是綠的 ——
因為測試驗的是 ViewModel 內部狀態，bug 在「狀態到畫面」那一段。

**教訓**：這個專案的弱點不是「審得不夠多」，是「驗得不夠真」。
後續補上的 `MatchCellTests`（斷言動畫 `fromValue` 的 alpha）與 `MatchListStatusTests`
（斷言狀態列文字）就是針對這一類。

## D4 的關鍵設計

- **重連的一半是對帳**：斷線期間的推播永久遺失，只重連不重抓 `GET /odds`，
  那些場次會永遠停在舊賠率且不會自我修正。`MatchListViewModel.resynchronize()`
  在偵測到 `.reconnecting → .connected` 的轉換時觸發。
- **退避加抖動**：1/2/4/8/16/30 秒上限，每次 ±20%。抖動是為了避免所有客戶端
  同時重連把剛恢復的伺服器再打掛（thundering herd）。
- **快取分兩種情境**：冷啟動讀磁碟快照先畫出來，離開畫面時寫入；同一次啟動內的
  push/pop 則靠 ViewModel 由導覽控制器持有而不重建。過期快照仍顯示但加警示橫幅 ——
  直接拿舊賠率當現值是博弈情境最危險的一類錯誤。
- **快取放 Caches 目錄**：可重建的衍生資料，系統該有權在空間不足時回收，
  也不該被備份到 iCloud。寫入採原子替換，避免半截 JSON。

---

## 關鍵決策紀錄

| 日期 | 決策 | 理由 |
|---|---|---|
| 2026-08-05 | **UI 用純 UIKit，不用 SwiftUI** | 使用者原本想用 SwiftUI，經指出考題技術限制表格明文「限定使用 UIKit（不可使用 SwiftUI）」後決定照文件走，較保險 |
| 2026-08-05 | **禁 RxSwift，但允許 SnapKit（僅限 `OddsUI`）** | 判準是「是否取代文件指定的技術」而非「有無第三方相依」。RxSwift 會取代 Concurrency/Combine ⇒ 禁；SnapKit 只是 Auto Layout 語法糖 ⇒ 可。原先「零第三方相依」是我方自訂規則、非文件要求，已修正 |
| 2026-08-05 | **採用本地 SPM package：`OddsCore` + `OddsUI`** | 使用者選擇更低耦合。附帶效益：`OddsCore` 無 UIKit ⇒ 測試可用 `swift test` 命令列跑、免模擬器、約 2 秒 |
| 2026-08-05 | **Xcode 專案由使用者手動建立** | 手刻 pbxproj 脆弱；已給出建立參數（App template / Storyboard interface / Testing None / iOS 16.0）|
| 2026-08-05 | **Repo 根目錄設在 `OddsBoard/`，題目 PDF 留在 repo 外層** | 保留 Xcode 既有 git 歷史（不必刪 `.git`），且公司內部題目 PDF 在物理上不可能被誤 push |
| 2026-08-05 | **GitHub repo 最終設為 public**（使用者確認）| 初期設 private，考量 take-home 解答公開後會被永久索引；後續改為 public 讓交件只需貼連結、面試官不必接受邀請。轉換前已確認 repo 內無題目 PDF、無任何金鑰 |
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
