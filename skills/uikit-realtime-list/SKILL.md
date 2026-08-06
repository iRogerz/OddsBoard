---
name: uikit-realtime-list
description: >
  設計在高頻資料更新下仍然順暢的 UIKit 列表畫面（WebSocket 推播、即時報價/賠率、
  感測器串流）。適用於：建立或除錯每秒更新數十至數百列的 UITableView/UICollectionView、
  加壓時滾動卡頓、cell 更新時整頁閃爍或跳動、決定某個畫面該用 Swift Concurrency
  還是 Combine、規劃斷線重連後的資料一致性。
  也在這些詞出現時觸發：reloadData 效能、diffable data source、reconfigureItems、
  更新合併 coalescing、CADisplayLink 節流、actor 保護共享狀態、重連對帳、
  高頻更新、即時報價、只更新變動的 cell、整頁重繪。
  不適用於：SwiftUI 的列表效能、一般的網路層或 Core Data 設定、
  資料只在使用者操作時才變動的靜態表格。
---

# UIKit 即時資料列表

## 這個 skill 解什麼問題

即時看板要同時滿足兩件互相拉扯的事：

- **資料要即時** —— 推播每秒數十至數百筆，畫面上的數字必須是現值
- **畫面要順** —— 使用者正在滾動，任何多餘的重繪都會被看見

天真的做法是「收到一筆就更新一次畫面」，或更糟的「收到一筆就 `reloadData()`」。
兩者在每秒 10 筆時都看起來正常，在每秒 1000 筆時會直接卡死 —— 而正式環境的高峰
往往就是每秒數百筆。

**核心主張，一句話：**

> UI 的更新頻率應該由**畫面的刷新節奏**決定，而不是由**資料的到達節奏**決定。

推播進來多快是外界決定的，畫面畫多快是我們決定的。以下三層策略就是把兩者解耦。

---

## 三層策略

關鍵洞察先講，因為它決定了整個架構：

> **資料值的變動不改變 cell 的身分，也不改變排序。**
> 所以這根本不是一次 diff 更新，而是一次「同一個 cell 的內容重設」。

```
資料識別 (Section, ID)      →  身分穩定
排序鍵 (時間, ID)            →  值變動不影響
∴ snapshot 的順序完全不變 → 不需要 apply 一次帶動畫的 diff
```

### 第一層：identifier 只放 ID，不放整個 model

```swift
UITableViewDiffableDataSource<Section, Int>   // Int = matchID，不是整個 struct
```

**為什麼**：若 identifier 含會變動的值（賠率、價格），值一變 hash 就變，diffable
會把它判定為「刪一列 + 插一列」，畫面會閃 —— 這正是高頻更新最典型的陷阱。

### 第二層：只更新目前可見的列

```
收到更新 → 寫入共享狀態（永遠執行）
         → 該 ID 在 indexPathsForVisibleRows 內？
              是 → 加入待更新集合
              否 → 不碰 UI（使用者滾到時 cellProvider 自然取到新值）
```

**為什麼**：100 筆資料、螢幕一次只看得到約 10 列 ⇒ **約九成的推播根本不該碰 UI**。
這條規則本身就是效能設計，不是最佳化的細節。

### 第三層：合併更新，並由 `CADisplayLink` 對齊幀邊界

```
推播進來 → 累積進 pendingIDs: Set<ID>
CADisplayLink 每 N 毫秒觸發一次 flush
  → reconfigureItems(變動 ∩ 可見) 一次做完
  → pendingIDs.removeAll()
```

**為什麼用 `CADisplayLink` 而非 `Timer`**：前者與畫面刷新同步，更新永遠發生在幀
邊界上；後者可能在一幀的中間觸發，讓那一幀的工作量突增。

**為什麼不能用 `Combine.throttle`**（這是最容易選錯的一步）：

```
throttle  ：視窗內 [A, B, C] → 只留一筆，A 和 B 真的消失
coalescer ：視窗內 [A, B, C] → ID 取聯集，值各自取最新
```

`throttle` 在時間視窗內**丟棄**事件，用在這裡會連帶丟掉**其他 ID** 的更新 ——
使用者會看到某些 cell 永遠不動。我們要的是**合併**：沒有任何一筆更新會遺失，
只是同一個 ID 在一個視窗內變動多次時，畫面只畫最後一次。

### 關鍵 API：`reconfigureItems` 而非 `reloadItems`

`reconfigureItems`（iOS 15+）保留既有的 cell 實體，只重跑 cellProvider ——
這是「不整頁 reload」與「不刪列再插列」之間的那條路。
用 `reloadItems` 會重新 dequeue，失去 cell 上的狀態（例如進行中的動畫）。

---

## 非同步邊界

規則要簡單到能一句話講完：

> **跨執行緒存取狀態 → Swift Concurrency。狀態變動通知 UI → Combine。**

| 場景 | 用什麼 | 為什麼不是另一個 |
|---|---|---|
| 共享可變狀態的保護 | `actor` | Combine 不提供資料隔離保證，它是事件傳遞而非同步機制 |
| 事件流（WebSocket） | `AsyncStream` | 取消語意跟著 `Task` 走，不需額外管理訂閱生命週期 |
| API 請求 | `async throws` | 錯誤即 `throw`，不必處理 Publisher 的完成/失敗雙通道 |
| ViewModel → View 綁定 | `@Published` + `sink` | UIKit 無自動重繪，Combine 是綁定最短路徑 |
| 高頻更新的節流 | 自製 coalescer | 見上方，`throttle` 語意不對 |

### 為什麼用 actor 而不是 queue + barrier

兩者都能達成互斥，差別在**誰負責保證正確性**：

| | 正確性靠什麼 | 漏掉一處會怎樣 |
|---|---|---|
| `DispatchQueue` + barrier | **每個呼叫端自律**記得包進 queue | 資料競爭，編譯器不會警告，測試多半也測不到 |
| `actor` | **編譯器**。跨界必須 `await` | 編不過 |

actor 把「同一時間只有一個執行緒能碰這份狀態」從**慣例**升級成**編譯期保證**。

### coalescer 不需要是 actor

它由 `@MainActor` 的 ViewModel 獨佔持有，不存在跨執行緒存取。做成 actor 只會在
每一幀多付一次 actor hop 的成本，換到零安全性收益。

**判準**：actor 是拿來保護「真的會被多個執行緒碰到」的狀態，不是拿來當「看起來
比較安全」的預設值。

---

## 資料正確性的兩個補強

即時資料系統有兩類 bug 不會 crash、測試測不到，只會讓畫面默默顯示錯的數字。
它們是這個領域最該主動處理的部分。

### 1. 亂序更新必須被丟棄

推播 payload 通常沒有版序。單一模擬來源下看似無害，但只要有並行處理或重連補資料，
**後到的舊資料覆蓋新資料**就是必然發生的 bug。

作法：在資料層補上單調遞增的 `sequence`，由狀態持有者仲裁。

```swift
if let accepted = acceptedSequence[id], update.sequence <= accepted {
    return false   // 舊資料，丟棄
}
```

**容易漏的一步**：全量覆寫（初次載入、重連對帳）之後，要把所有項目的序號基準推到
「當下已知的最高序號」。否則斷線前仍在飛行中的舊推播，會在對帳完成後才抵達並
蓋掉剛校正好的值 —— 對帳等於白做。

### 2. 重連的一半是對帳

**斷線期間的推播是永久遺失的。** 只重連而不重抓一次全量資料，那些項目會永遠停在
斷線前的舊值，直到它剛好又被推播到為止。

這個 bug 不會 crash、沒有 log、單元測試測不到。在金融或博弈情境下，它是最壞的
一類錯誤。

實作上有兩個容易漏的點：

- **對帳結果必須走一般的更新路徑抵達畫面。** 只更新內部狀態的話，可見的 cell
  從頭到尾不會被 reconfigure，使用者仍看著舊值。作法是把所有 ID 送進 coalescer，
  讓畫面更新永遠只有一條路。
- **對帳失敗要與連線失敗分開表達。** 對帳失敗時推播其實是好的、數字仍在跳，
  只是校正沒成功。混為一談會讓畫面顯示「無法連線」卻同時看到數字在動。

---

## 常見錯誤

| 錯誤 | 症狀 | 正解 |
|---|---|---|
| identifier 放整個 model | 每次更新畫面都閃一下 | identifier 只放穩定的 ID |
| 用 `Combine.throttle` 節流 | 某些 cell 永遠不動 | 自製 coalescer，ID 取聯集 |
| 更新所有變動的列 | 加壓時卡頓 | 先與 `indexPathsForVisibleRows` 取交集 |
| 用 `Timer` 驅動 flush | 偶發掉幀 | `CADisplayLink`，對齊幀邊界 |
| `reloadItems` | cell 上的動畫被中斷 | `reconfigureItems` |
| 每筆推播各觸發一次 UI 更新 | 高頻下主執行緒被淹沒 | 批次 + 合併 |
| 比例字型顯示數字 | 值變動時觸發 Auto Layout 重算 | `monospacedDigitSystemFont` |
| 用估算列高 | 滾動時反覆詢問與修正 | 固定列高，`estimatedRowHeight = 0` |
| 只重連不對帳 | 部分項目永遠停在舊值 | 重連後重抓全量並走一般更新路徑 |
| 在 cellProvider 內播動畫 | 滾過去的 cell 全在閃 | 動畫在 `apply` 之後對可見 cell 觸發 |

---

## 深入閱讀

需要時才載入，不要一次全讀：

- **`references/pitfalls.md`** —— 五個實際踩過、且**讀程式碼找不到**的陷阱：
  `CABasicAnimation` 的起始值、`CADisplayLink` 的保留循環、
  `isMovingFromParent` 恆為 false、`AsyncStream` 的單一消費者限制、
  flush 交錯造成的漏更新。遇到「邏輯看起來對但畫面不對」時讀這份。

- **`references/verification.md`** —— 驗證分層：哪一類 bug 靠什麼方式才抓得到、
  如何識別「恆真測試」、UIKit 專案「測試全綠但畫面不動」的結構性原因。
  寫測試或準備驗收時讀這份。

---

## 參考實作

本模式的完整實作在 [OddsBoard](https://github.com/iRogerz/OddsBoard)：

| 關注點 | 檔案 |
|---|---|
| 三層策略、flush 迴圈 | `Packages/OddsUI/Sources/OddsUI/MatchListViewController.swift` |
| 合併器 | `Packages/OddsCore/Sources/OddsCore/Support/UpdateCoalescer.swift` |
| actor 狀態、序號仲裁 | `Packages/OddsCore/Sources/OddsCore/Data/OddsStore.swift` |
| 綁定與狀態渲染 | `Packages/OddsUI/Sources/OddsUI/MatchListViewController+Binding.swift` |
| 重連退避 + 抖動 | `Packages/OddsCore/Sources/OddsCore/Support/ReconnectPolicy.swift` |
| 對帳 | `MatchListViewModel.resynchronize()` |

實測（iPhone ProMotion 機種，加壓 1000 筆/秒並持續滾動 40 秒）：
Hitch Time Ratio 0.82 ms/s（Apple 良好門檻為 5）、Hangs 0、主執行緒 CPU 22%、
零記憶體洩漏、Thread Sanitizer 零 data race。

---

## 驗收標準

套用本模式的畫面，應該滿足：

- [ ] 全程零次 `reloadData()`（建議做成 linter error，而非靠自律）
- [ ] 資料值更新時，snapshot 的順序不變（只走 `reconfigureItems`）
- [ ] 加壓到目標頻率的 100 倍時，滾動體感與低頻率時**幾乎沒有差別**
- [ ] Hitch Time Ratio < 5 ms/s
- [ ] Thread Sanitizer 零 data race
- [ ] 斷線重連後，畫面上的所有值與伺服器一致（對帳有效）
- [ ] 亂序抵達的舊資料不會覆蓋新值（有對應測試）
