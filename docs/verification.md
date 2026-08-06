# 驗證清單與錄影腳本

> 這份文件的目的是讓「驗過了」有明確定義。
> 每一項都寫死了**要看什麼**與**看到什麼算通過**，避免驗證退化成「跑一跑覺得還行」。
>
> 自動化的部分（測試、lint）見 §1；改完程式碼的功能回歸見 §2；
> 效能與記憶體見 §3；錄影見 §4。

---

## 1. 自動化：每次改動都該綠的

```bash
swift test --package-path Packages/OddsCore
```

```bash
swift test --package-path Packages/OddsPresentation
```

```bash
swiftlint --strict
```

UI 層測試（需模擬器）：

```bash
xcodebuild test -project OddsBoard.xcodeproj -scheme OddsBoard -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

| 項目 | 通過標準 |
|---|---|
| `OddsCore` 測試 | 75 支全綠 |
| `OddsPresentation` 測試 | 36 支全綠 |
| `OddsBoardTests` | 27 支全綠 |
| SwiftLint | `--strict` 下零違規 |
| 建置警告 | 零（`-strict-concurrency=complete` 的 Sendable 警告也算） |

---

## 2. 功能回歸驗證（改完程式碼必做，約 10 分鐘）

**這一段要排在 Instruments 之前。** 功能壞掉的版本量效能沒有意義，
而錄影錄到一半發現按鈕沒反應要整段重錄。

跑一次模擬器，依序做以下九項。**全程開著 Xcode 的 Console**。

| # | 操作 | 通過標準 |
|---|---|---|
| 1 | 啟動 App | 轉圈（200–600ms 的模擬延遲）→ 列表出現 100 場，開賽時間由上而下遞增 |
| 2 | **看 Console** | **無 `updateVisibleMenuWithBlock` 相關訊息**。另有一則 `NavigationButtonBar.ItemWrapperView` 的約束衝突警告屬於 UIKit 內部、已知且接受（見 `ARCHITECTURE.md` §7），出現是正常的 |
| 3 | 點右上角 **Debug** | 選單立刻展開（**不該有首次延遲**——這是改用 `UIMenu` 的主因）。可看到：三個推播頻率、模擬斷線、模擬載入失敗、顯示 HUD |
| 4 | 選「顯示 HUD」→ 再開一次選單 | HUD 出現在底部；**選單文字變成「隱藏 HUD」**。文字沒變代表 `UIDeferredMenuElement` 沒生效，選單被快取住了 |
| 5 | 選「推播 1000 筆/秒」，同時滾動 | HUD 推播數飛快上升，**UI 批次數穩定在每秒約 10**，`reloadData 0`。滾動順暢 |
| 6 | 選「模擬斷線」 | 狀態列 →「連線中斷，重試中（第 N 次）」，**重試間隔明顯愈拉愈長**。約 7 秒後回到「● 即時更新中」，且**整頁賠率被校正一次**（對帳） |
| 7 | 選「模擬載入失敗」 | 轉圈 →「載入失敗：…」，**且賠率完全靜止**。這是新加的不變式：`loadState == .failed` ⟺ 畫面上沒有即時資料在流動 |
| 8 | 再開選單 → 「恢復正常載入並重試」 | 選單文字已變成「恢復正常載入並重試」；按下後資料**與跳動一起**回來 |
| 9 | 點進詳情頁 → 返回 → 殺掉 App 重開 | 詳情頁賠率與走勢圖**持續更新**；返回列表**無載入過程**；殺掉重開後列表**瞬間出現**再被即時資料取代 |

> 第 7、8 項是這次新增的功能，第 2、3、4 項是這次改動的回歸點。
> 其餘是既有功能的 smoke test。

---

## 3. Instruments 檢查清單

每一項都標了**要看哪個欄位**。Instruments 的畫面資訊量大，沒有預先寫死看哪裡，
很容易看到一堆數字然後說服自己沒問題。

> ### ✅ 實測結果（2026-08-06，iPhone ProMotion 機種實機）
>
> | 項目 | 實測 | 判準 |
> |---|---|---|
> | Animation Hitches | **2 次 / 40 秒，共 33.34ms → 0.82 ms/s** | < 5 ms/s ✅ |
> | Hangs | **0** | 0 ✅ |
> | 主執行緒 CPU | **8.80s / 40s ≈ 22%** | 無長時間阻塞 ✅ |
> | Persistent Bytes | **17.92 MiB，前 10 秒後走平** | 不持續成長 ✅ |
> | 物件回收率 | **1,661,378 次配置，僅 59,117 存活（96.4% 短命）** | — ✅ |
> | UILabel (CALayer) | **131 persistent，穩定** | 不隨滾動累積 ✅ |
> | Leaks | **三次檢查全綠** | 零洩漏 ✅ |
> | Thermal State | **全程 Nominal** | 未因過熱降頻 ✅ |
>
> 測試條件：推播加壓至 1000 筆/秒並持續滾動。
>
> **Thread Sanitizer 另在模擬器完成（不支援真機，見 §3.1）：零筆 data race ✅**
> —— 五項全數通過。
>
> **兩次 hitch 的 Min/Avg/Max 完全相同（皆 16.67ms）**，且集中在同一時刻 ——
> 這是「瞬時事件錯過一個 vsync」的特徵（切換推播頻率或起始滾動的那一下），
> 不是架構撐不住的表現。撐不住的話 duration 會是不規則的大數字，
> 且散佈在整段滾動期間。

### 3.1 Thread Sanitizer — 資料競爭

> **⚠️ TSan 不支援 iOS 真機，只能在模擬器（或 macOS）上跑。**
> 其餘四項建議用實機（效能數字才有意義），唯獨這一項必須切回模擬器。

**怎麼開**：Product → Scheme → Edit Scheme → **Run** → Diagnostics → 勾 Thread Sanitizer。
（不能與 Address Sanitizer 同時開啟。）

**操作順序有講究** —— TSan 是動態偵測，沒執行到的路徑它看不見：

1. 加壓到 **1000 筆/秒**（推播 Task 高頻寫入 store）
2. **同時用力滾動 30 秒**（主執行緒並行讀取畫面模型）
3. **模擬斷線 → 等重連與對帳完成** ← **最關鍵**
4. 進詳情頁停留數秒（第三個存取者讀同一個 store）→ 返回
5. 再加壓一次，拉長時間窗口

> **第 3 步是全 App 唯一的雙寫者場景**：對帳的 `resynchronize()` 是獨立 Task，
> 會與推播 Task 並行寫入同一個 `OddsStore`。跳過這步等於沒測到重點。
>
> 加壓也是必要條件 —— 低頻率下 race 的窗口太窄，跑十次可能一次都碰不到。

**怎麼判讀**：TSan 不給圖表或數字，**沉默就是通過**。

| 看什麼 | 通過標準 |
|---|---|
| Issue navigator（⌘5）→ Runtime Issues | **零筆**（有問題會出現紫色項目，點擊直接跳到該行） |
| Console | 無 `WARNING: ThreadSanitizer: data race` |

**兩個預期中的現象，別誤判**：

- **App 會非常慢**（執行速度降 2–20 倍、記憶體漲 5–10 倍）。這時的卡頓是 TSan
  造成的，與 §3.5 量到的效能無關。
- **預期就是綠的**：共享狀態全在 `actor OddsStore` 內，加上
  `-strict-concurrency=complete` 在編譯期已擋掉大部分問題。這一關驗的是
  「actor 的保證在執行期真的成立」。真的報出東西反而是重大發現，務必記錄下來。

### 3.2 Allocations — 記憶體是否穩定成長

**怎麼開**：Product → Profile（⌘I）→ Allocations。

**操作**：啟動後不做任何事，讓推播以預設 10 筆/秒跑 60 秒；接著加壓到 1000 筆/秒
再跑 60 秒。

| 看什麼 | 通過標準 |
|---|---|
| **Persistent Bytes** 曲線 | 前 10 秒爬升後**走平**。持續線性成長 = 洩漏 |
| `OddsUpdate` / `Odds` 的 Persistent 數量 | 不隨時間單調成長 |
| `[Odds]` 歷史陣列 | 每場最多 60 筆（`OddsStore.historyLimit`），總量有上限 |
| `StreamStats` 的延遲樣本 | 最多 200 筆（`sampleLimit`） |

> 這兩處上限是刻意存在的。沒有上限的「保留歷史」跑一整天就是無界成長，
> 而它在 5 分鐘的 demo 裡完全看不出來。

### 3.3 Leaks — retain cycle

> **先確認這關要不要做**：兩個 view controller 的釋放**都已有自動化測試覆蓋**，
> 各自帶對照組，每次跑測試都會驗：
> - `MatchListViewControllerTests.test_啟動節拍後view_controller仍可被釋放`
> - `MatchDetailViewControllerTests`（三支：未啟動觀察／啟動觀察後／完整生命週期）
>
> 所以這一節已降級為**補充確認**，不是交件的阻塞項。

**⚠️ Leaks 在 iOS 模擬器上經常失敗**，錯誤長這樣：

```
Failed to generate memory graph for pid NNN: failed to create a
VMUTaskMemoryScanner, probably because the target's libmalloc
hasn't been initialized
```

這是 Instruments 與模擬器的時序問題，不是 App 的毛病。三個處理方式：

| 方式 | 怎麼做 | 適用 |
|---|---|---|
| **Memory Graph Debugger**（推薦） | ⌘R 跑起來 → 操作 → Debug navigator 底部點「Debug Memory Graph」→ 左側搜尋類別名 | 最直接。要驗的就是「還有幾個實例」，它直接給答案，還會畫出 retain path |
| Malloc Stack Logging | Edit Scheme → **Profile**（不是 Run）→ Diagnostics → 勾 Malloc Stack Logging（Live Allocations Only） | 想繼續用 Leaks 時。設在 Run 底下不會生效，這是最常見的誤設 |
| 用真機 | 同 §3.5 的建議一起在真機做 | Leaks 在真機上可靠得多 |

**操作**：啟動 → 進詳情頁 → 返回（重複 5 次）→ App 進背景 → 回前景 → 再重複一輪。

| 看什麼 | 通過標準 |
|---|---|
| `MatchDetailViewController` 的實體數 | 返回列表後回到 **0** |
| `MatchListViewController` | 全程恆為 **1**（它是 nav root，不該被重建也不該有第二份） |
| Leaks 儀器的紅色 X（若跑得起來） | 零筆 |

**特別要盯的三處**（都是已修的 bug，這裡是回歸驗證）：

- `CADisplayLink` — 它會**強引用** target。本專案透過 `DisplayLinkProxy` 弱引用，
  若改壞會讓 VC 永遠不釋放。
- fire-and-forget `Task` — `Task { await viewModel.start() }` 會因存取 self 的屬性
  而隱式強引用整個 VC。本專案寫成 `Task { [viewModel] in ... }`。
- `MockOddsSocket` 的推播迴圈 — actor 持有 Task、Task 持有 actor 就是保留循環，
  ViewModel 釋放後迴圈仍會永遠跑下去。本專案用 `[weak self]`。

### 3.4 Time Profiler — 主執行緒是否被阻塞

**操作**：加壓到 1000 筆/秒，持續滾動 30 秒。

| 看什麼 | 通過標準 |
|---|---|
| Main Thread 的 heaviest stack trace | 最重的應是 UIKit 的繪製與佈局，**不是** `flushPendingUpdates` 或 JSON 編解碼 |
| 單次 flush 的耗時 | < 5ms |
| 任何同步工作 | 無 > 16ms 的區塊（超過一幀就會掉幀） |
| `FileSnapshotCache` 的寫入 | **不該出現在 main thread 上**（它是 actor，寫入在背景） |

### 3.5 Animation Hitches / Core Animation FPS — 滾動是否順

**怎麼開**：Instruments 的 **Animation Hitches** 模板（Xcode 13 起取代舊的 Core Animation FPS）。

**操作**：三種頻率各滾動 20 秒 —— 10 筆/秒、100 筆/秒、1000 筆/秒。

| 看什麼 | 通過標準 |
|---|---|
| Hitch Time Ratio | < 5 ms/s（Apple 的「良好」門檻）。**Instruments 給的是這個，不是 fps** |
| 單次 hitch 的 duration | 落在幀邊界的整數倍（16.67ms）＝ 錯過 vsync 的瞬時事件；**不規則的大數字才是效能問題** |
| **三種頻率下的差異** | 這是重點：1000 筆/秒與 10 筆/秒的滾動體感應**幾乎沒有差別**。有差別就代表更新合併沒有真的把資料頻率與畫面頻率解耦 |

> **關於 ProMotion 裝置的判讀**：iOS 15 起，App 在 120Hz 裝置上**預設仍以 60fps
> 渲染**，除非在 Info.plist 加入 `CADisableMinimumFrameDurationOnPhone`。
> 本專案**刻意不加** —— UI 更新由 `CADisplayLink` 節流到 100ms（10Hz），
> 120Hz 渲染對賠率看板沒有任何意義，只會多耗電。
> 因此在 ProMotion 機種上，一幀仍是 **16.67ms**，不是 8.33ms。
> 別把「沒跑到 110fps」誤判為效能問題 —— 那是預設行為，不是掉幀。

> **請用真機測，不要只信模擬器。** 模擬器跑在 Mac 的 CPU/GPU 上，
> 效能數字沒有參考價值，只有「有沒有明顯錯誤」有參考價值。

---

## 4. 錄影腳本

一鏡到底，約 2–3 分鐘。**錄影本身也是一種驗證** ——
凍結、不閃、數字不動這類 bug 會在錄的過程中自己跳出來。

錄之前：**先把 App 完全殺掉**（第 8 幕需要一次真正的冷啟動）。

| # | 操作 | 鏡頭要帶到什麼 | 對應需求 |
|---|---|---|---|
| 1 | 啟動 App | loading → 列表出現。**開賽時間由上而下遞增**，滑到底確認共 100 場 | FR-1、FR-3.1、FR-3.2 |
| 2 | 靜置 10 秒 | 賠率跳動時**只有變動的那一格閃綠或閃紅**，其他格子完全不動。整頁沒有任何重繪跡象 | **FR-3.3（核心）** |
| 3 | 點右上角 Debug → 開 HUD → 選「推播 1000 筆/秒」 | HUD 的推播數飛快上升；**同時滾動列表，滾動仍然順暢** | FR-2、FR-3.4 |
| 4 | 停下來讓 HUD 停留 3 秒 | `reloadData 0`、UI 批次數遠低於推播數（合併的效果）、p95 延遲 | §7 效能預算 |
| 5 | Debug →「模擬斷線」 | 狀態列變成「連線中斷，重試中（第 N 次）」，**重試間隔明顯愈拉愈長**（退避）。重連成功後狀態列回到「● 即時更新中」，同時**整頁賠率被校正一次** | FR-6、FR-6.4 |
| 6 | Debug →「模擬載入失敗」，停 3 秒後再 Debug →「恢復正常載入並重試」 | 轉圈 →「載入失敗：…」，且**賠率完全靜止**（推播一併中斷）→ 恢復後資料與跳動一起回來。證明 loading／loaded／error 三態都是活的 | FR-1.4 |
| 7 | 點進任一場比賽 | 詳情頁的賠率與走勢圖**持續更新**（不是靜態快照）。返回列表 —— **沒有任何載入過程，滾動位置也保留** | FR-7、FR-5（同一次啟動內） |
| 8 | **把 App 從多工列殺掉，重新開啟** | 列表**瞬間出現**（磁碟快照），隨即被即時資料無聲取代 | FR-5（跨啟動） |

### 兩個講解時務必說清楚的點

**第 7 幕與第 8 幕不是同一件事。**
第 7 幕展示的是 **ViewModel 的所有權**（view controller 全程活著，資料本來就在），
第 8 幕才是**磁碟快取**唯一能被看見的時刻。
把兩者都說成「我做了快取」會漏掉一半，而且是比較有內容的那一半。

**第 4 幕的 `reloadData 0` 不只是一個數字。**
它旁邊值得補一句：這條規則是 SwiftLint 的 error 級 custom rule，
專案在物理上無法通過編譯，所以它不是「我記得沒呼叫」，是「不可能呼叫」。

### 選配：想再多一個鏡頭的話

在 `MatchListViewController.flushPendingUpdates()` 打斷點，
展示 `changedIDs`（幾十個）與 `idsToReconfigure`（個位數）的差距 ——
這是「約九成的推播根本不碰 UI」最直接的證據。

---

## 5. 交件前最後檢查

- [ ] §1 自動化測試與 lint 全綠
- [ ] §2 功能回歸驗證九項全過
- [ ] §3.1 Thread Sanitizer 零筆
- [ ] §3.3（選配）Memory Graph 確認 `MatchDetailViewController` 返回後歸零 —— 兩個 VC 的釋放已有測試覆蓋，這關非阻塞
- [ ] §3.5 三種推播頻率下滾動體感一致
- [ ] §4 錄影完成，八幕齊全
- [ ] `README.md` 的執行與測試指令能被完全不了解本專案的人照著跑起來
- [ ] `ARCHITECTURE.md` §7「已知限制」與程式碼現況一致
- [ ] repo 內無題目 PDF、無任何金鑰（`.gitignore` 已排除 `*_Home_Test.pdf`）
- [ ] 建議：交件前跑一次 `/code-review ultra` 做多 agent 深度審查
