# 即時賽事賠率系統 — 功能規格書 (Feature Spec)

> **來源文件**：`OpenNet_IOS_Home_Test.pdf`（iOS Take-Home Assignment）
> **本文件是唯一真實來源 (Source of Truth)**。實作與本規格衝突時，改實作，不改規格；規格要改，先改本文件再改碼。

---

## 0. 標記說明

每一條需求都標了來源，用意是讓「題目要求的」與「主動補上的設計」在文件裡可以被逐條區分：

| 標記 | 意義 |
|---|---|
| 📄 | 原文件明確要求 |
| ⭐ | 原文件列為加分題 |
| 🧩 | **原文件沒寫、主動補上的設計考量**（每條都附「為什麼」） |

---

## 1. 目標與範圍

實作一個 iOS App，展示約 100 場比賽的即時賠率。資料來自模擬的 REST API 與模擬的 WebSocket 推播；重點不在畫面多漂亮，而在**架構分層、thread-safe、以及高頻更新下的 UI 效能**。

### 明確不在範圍內
- 真實網路層 / 真實 WebSocket 伺服器（文件指定用 Mock）
- 使用者登入、下注、金流
- 多語系、深色模式適配（可做但不列為驗收項）

---

## 2. 技術限制（不可協商）

| 項目 | 限制 | 來源 |
|---|---|---|
| UI Framework | **UIKit，不可使用 SwiftUI** | 📄 |
| 列表元件 | **UITableView** | 📄 |
| 架構模式 | **MVVM** | 📄 |
| 非同步 | **Swift Concurrency 或 Combine**（本專案兩者並用，邊界見 §6） | 📄 |
| 第三方套件 | 🧩 **禁止 RxSwift 等響應式框架**；版面配置類（SnapKit）允許，但**僅限 `OddsUI` 模組** | 🧩 |

> 🧩 **第三方套件的判準**：文件的限制表格並未禁止第三方套件，所以判準不是「有沒有相依」，而是**「這個套件是否取代了文件指定的技術」**。
> - **RxSwift ❌** — 它會取代 Swift Concurrency / Combine，而那兩者是文件明文指定的。用它等於繞過限制。
> - **SnapKit ✅** — 純 Auto Layout 語法糖，不觸碰任何被指定的技術，也不影響架構分層。
>
> **約束**：SnapKit 只能出現在 `OddsUI`。`OddsCore`（Domain + Data）維持**零第三方相依**，由 SPM 模組邊界在編譯期強制（§5）。

### 🧩 執行環境（原文件未指定）
- **Deployment Target: iOS 16.0** — `UITableViewDiffableDataSource.reconfigureItems` 需 iOS 15+，這是 §5.3「不整頁 reload」的核心 API；訂 16.0 留餘裕且涵蓋絕大多數裝置。
- **Swift 5 language mode + `-strict-concurrency=complete`（警告等級）** — 讓編譯器幫忙抓資料競爭，但不會像 Swift 6 語言模式那樣為了滿足編譯器而扭曲架構。
- **無 Storyboard，純程式碼 UI + Auto Layout** — Storyboard 的 diff 不可讀，且會讓「依賴注入」變得彆扭。

---

## 3. 資料模型

### 3.1 領域模型

```swift
struct Match: Identifiable, Hashable, Codable, Sendable {
    let id: Int          // matchID
    let teamA: String
    let teamB: String
    let startTime: Date
}

struct Odds: Hashable, Codable, Sendable {
    let matchID: Int
    let teamAOdds: Double
    let teamBOdds: Double
}

/// 畫面實際消費的合併後模型
struct MatchRow: Hashable, Sendable, Identifiable {
    var id: Int { match.id }
    let match: Match
    let odds: Odds?          // 🧩 可為 nil：odds 尚未載入或該場無盤口
    let change: OddsChange   // 🧩 給漲跌視覺提示用
}

/// 🧩 兩隊分開記錄，不是單一方向。
/// 同一次推播中 teamA 上漲、teamB 下跌是常態，
/// 用單一方向表示必然會漏掉其中一邊的閃爍。
struct OddsChange: Hashable, Sendable {
    enum Direction: Sendable { case up, down, unchanged }
    let teamA: Direction
    let teamB: Direction
}
```

### 3.2 傳輸模型（Mock API 回傳格式，依文件範例）

```jsonc
// GET /matches
[ { "matchID": 1001, "teamA": "Eagles", "teamB": "Tigers",
    "startTime": "2025-07-04T13:00:00Z" } ]

// GET /odds
[ { "matchID": 1001, "teamAOdds": 1.95, "teamBOdds": 2.10 } ]

// WebSocket push
{ "matchID": 1001, "teamAOdds": 1.92, "teamBOdds": 2.08 }
```

### 🧩 3.3 我對推播 payload 的補強

文件的推播 payload **沒有時間戳也沒有序號**。這在單一模擬來源下看似無害，但只要有並行處理或重連補資料，就會出現**後到的舊資料覆蓋新資料**。

```swift
struct OddsUpdate: Sendable {
    let matchID: Int
    let teamAOdds: Double
    let teamBOdds: Double
    let sequence: UInt64      // 🧩 單調遞增，本地產生
    let sentAt: DispatchTime  // 🧩 量測端到端延遲用
}
```

**規則**：`OddsStore` 只接受 `sequence` 大於該 matchID 目前值的更新，否則丟棄。這條規則要有對應單元測試（§9）。

> 原文件的 payload 沒有版序。一旦有斷線重連或多來源合併，亂序覆蓋是必然會發生的 bug，
> 而且它不會 crash、只會讓畫面顯示錯的賠率 —— 屬於最難被發現的那一類。

---

## 4. 功能需求

### FR-1 資料來源（📄）

| ID | 需求 | 驗收條件 |
|---|---|---|
| FR-1.1 | `GET /matches` 回傳約 100 筆比賽 | Mock client 回傳 100 筆，含 matchID / 隊名 / startTime |
| FR-1.2 | `GET /odds` 回傳每場初始賠率 | 回傳筆數 == matches 筆數 |
| FR-1.3 | 🧩 模擬網路延遲 200–600ms 隨機 | 首屏有真實的 loading 狀態，而非瞬間出現 |
| FR-1.4 | 🧩 可注入失敗（`.never` / `.always` / `.firstCalls(n)`），且**失敗模式可在執行期切換** | 錯誤路徑可被單元測試與手動 demo 觸發：Debug 面板的「模擬載入失敗」會切換模式並重新載入 |

> 🧩 **為什麼要能模擬失敗**：文件完全沒提錯誤處理，但沒有 loading / empty / error 三態的列表在 code review 中是明顯扣分項。
> 🧩 **為什麼失敗模式必須能在執行期切換**：只在建構子注入是不夠的 —— App 跑起來時永遠是 `.never`，`.failed` 那條 UI 分支變成只有單元測試碰得到的死碼，錄影也拍不到。加上執行期的 setter 與 Debug 面板入口，「錯誤 UI 不是死碼」才真的成立。
> 🧩 **為什麼是確定性模式而非失敗率**：機率式失敗會讓測試偶爾紅燈，而偶爾紅燈的測試最後一定會被當成雜訊忽略。確定性的 `.firstCalls(n)` 反而能精準驗證「重試後恢復」這條路徑。

**🧩 Mock 資料生成規則**（原文件未定義）：
- `startTime` 以 **App 啟動時間為基準**往後散佈 0–48 小時，避免交件當天全部變成「已開賽」。
- 使用**固定亂數種子**，讓每次啟動資料一致 → 測試可重現、demo 影片可重錄。
- 隊名從 32 隊池組合，保證同一場的 teamA ≠ teamB。
- 🧩 **刻意讓約 5 場 `startTime` 完全相同** → 逼出排序穩定性問題（見 FR-3.2）。

---

### FR-2 WebSocket 模擬（📄）

| ID | 需求 | 驗收條件 |
|---|---|---|
| FR-2.1 | 每秒最多推播 10 筆賠率更新 | 量測 60 秒，總推播數 ≤ 600 |
| FR-2.2 | 每筆對應一個 matchID 的新賠率 | payload 符合 §3.2 |
| FR-2.3 | 🧩 連線狀態機外露給 UI | 狀態列可見 `connecting / connected / reconnecting / failed` |
| FR-2.4 | ⭐ 斷線自動重連 | 見 §4.FR-6 |

**🧩 推播內容規則**（文件未定義）：
- 每次隨機挑 1 場比賽，賠率在 `1.01 ... 15.00` 內做 ±0.01–0.15 的隨機漂移，**而非整數亂跳** → 漲跌視覺提示才有意義。
- 提供 **debug 控制面板**（導覽列右上角按鈕開啟）可即時把頻率調成 10 / 100 / 1000 筆每秒。
  > 為什麼：題目說「每秒最多 10 筆」，但 10 筆/秒對 UITableView 根本不算壓力。要證明架構撐得住，得能當場加壓到 100x。這是我覺得最容易讓這份作業從「有做完」變成「有想過」的一個小功能。

---

### FR-3 畫面行為（📄 — 本題核心）

| ID | 需求 | 驗收條件 |
|---|---|---|
| FR-3.1 | UITableView 呈現比賽資訊 | 每列顯示：隊伍對戰、開賽時間、teamA/teamB 賠率 |
| FR-3.2 | 依 `startTime` **升序**排序 | 最早開賽在最上面 |
| FR-3.3 | **賠率更新只更新對應 cell，不可整頁 reload** | `reloadData()` 全程呼叫次數 == 0（見 §8 機械保證） |
| FR-3.4 | 畫面保持順暢 | 滾動時 FPS ≥ 58（見 §7 效能預算）|

#### 🧩 FR-3.2 補充：排序穩定性
文件只說「依比賽時間升序」。當多場 `startTime` 相同時，未定義次序 → 不同次載入順序可能不同，畫面會莫名跳動。
**規則**：排序鍵為 `(startTime, matchID)` 複合鍵，全域唯一 → 排序結果**確定性**。

#### 🧩 FR-3.2 補充：排序不隨時間重排
比賽開始後**不重新排序、不移除**，僅在該列標記「進行中」。
> 為什麼：若隨時鐘把已開賽的移走，使用者滾到一半列表會自己跳，體驗比排序不準更糟。這是刻意的取捨，不是漏做 — 要寫進架構文件。

#### 🎯 FR-3.3 的實作策略（這題真正在考的東西）

關鍵洞察：**賠率變動不改變 cell 的身分，也不改變排序**。所以這根本不是一次 diff 更新，而是一次「同一個 cell 的內容重設」。

```
資料識別 (Section, Int=matchID)  →  身分穩定
排序鍵 (startTime, matchID)      →  賠率變動不影響
∴ snapshot 的順序完全不變 → 不需要 apply 帶動畫的 diff
```

三層防護：

1. **`UITableViewDiffableDataSource<Section, Int>`**，identifier 用 `matchID`（不是整個 struct）。
   > 🧩 為什麼不是 `MatchRow`：若 identifier 含賠率，賠率一變 hash 就變，diffable 會判定為「刪一列 + 插一列」，畫面會閃 — 這正是題目要你避開的陷阱。

2. **只對「可見範圍內」的列做 `reconfigureItems`**。
   ```
   收到更新 → 寫入 actor store（永遠執行）
            → 該 matchID 在 indexPathsForVisibleRows 內？
                 是 → 加入待更新集合
                 否 → 不碰 UI（使用者滾到時 cellForRowAt 自然拿到新值）
   ```
   > 🧩 100 場比賽、螢幕只看得到約 10 列 → **約 90% 的推播根本不該碰 UI**。這條規則本身就是效能設計。

3. **更新合併（Coalescing）** — 🧩 文件沒提，但這是「畫面保持順暢」的真正解法。
   ```
   推播進來 → 累積進 pendingIDs: Set<Int>
   CADisplayLink / 100ms tick 觸發一次 flush
     → reconfigureItems(Array(pendingIDs)) 一次做完
     → pendingIDs.removeAll()
   ```
   效果：100 筆/秒的推播 → UI 每秒最多 10 次批次更新；且**同一場比賽在一個視窗內連續更新 3 次，只會渲染最後一次**。
   > 原則：UI 更新頻率應該由畫面的刷新節奏決定，不該由資料的到達節奏決定。

4. 🧩 **賠率漲跌視覺提示**：上漲綠底、下跌紅底，0.3 秒淡出。
   > 為什麼要做：這不只是美觀 — 它讓 reviewer **肉眼就能確認「只有那一格在動，整頁沒有重繪」**，等於把 FR-3.3 變成可視化的證據。

5. 🧩 **Cell 自繪最佳化**：賠率用 monospaced digit 字型、標籤寬度固定。
   > 為什麼：比例字型下 `1.95 → 1.92` 會造成寬度變動 → 觸發 Auto Layout 重算。等寬數字直接消除這個成本。

---

### FR-4 Thread-safe（📄）

| ID | 需求 | 驗收條件 |
|---|---|---|
| FR-4.1 | 多執行緒下資料一致、無 race condition | Thread Sanitizer 全綠；並發壓力測試通過（§9）|
| FR-4.2 | 🧩 所有 UI 存取限定主執行緒 | ViewModel 與 ViewController 標記 `@MainActor` |
| FR-4.3 | 🧩 亂序更新必須被丟棄 | 見 §3.3；有對應單元測試 |

**設計**：
```
      推播 Task ─┐
                 ├──→  actor OddsStore  ──→ AsyncStream<[Int]> ──→ @MainActor ViewModel
    重連補資料 ─┘      (唯一可變狀態)          (變動的 matchID)         (@Published)
```

- **`actor OddsStore` 是全 App 唯一持有可變賠率狀態的地方。** 沒有第二份副本、沒有 `NSLock`、沒有 concurrent queue + barrier。
  > 🧩 為什麼用 actor 而不是 `DispatchQueue` + barrier：barrier 的正確性靠**每個呼叫端自律**，漏一個地方就是資料競爭，而且編譯器不會告訴你。actor 把它變成**編譯期**保證。這正是文件問「如何確保 thread-safe」時想聽到的答案層次。
- ViewModel 是 `@MainActor` → 從 store 拿資料必然是 `await`，跨界點在型別系統上一目了然。
- 🧩 **不使用 `Task { @MainActor in }` 散落各處**：綁定集中在 ViewModel 一處，避免執行緒切換點失控。

---

### FR-5 ⭐ 快取機制（加分題）

文件原文：「切換畫面後能快速恢復顯示」。🧩 這句話涵蓋兩種情境，兩種都做：

| 情境 | 機制 | 驗收條件 |
|---|---|---|
| 同一次啟動內的畫面切換（push detail → pop 回列表）| ViewModel 由 Coordinator 持有，**不隨 ViewController 銷毀** | pop 回來時列表位置、賠率、滾動位置完全保留，**無 loading** |
| App 冷啟動 | 磁碟快照 (JSON, atomic write) | 冷啟 → **先顯示上次快照**（毫秒級）→ 背景打 API → 靜默替換 |
| App 進背景再回前景 | 記憶體保留 + 回前景時全量對帳 | 回前景 1 秒內賠率與伺服器一致 |

🧩 **快取設計細節**：
- 兩層：`MemoryCache`（NSCache，即時）+ `DiskCache`（JSON，App 進背景時寫入，atomic replace 避免半寫檔）。
- 快照含 `savedAt`；超過 **10 分鐘視為過期**，仍顯示但列表頂端出現「資料可能已過時，更新中…」橫幅。
  > 🧩 為什麼要標示過期：直接拿舊賠率當現值顯示，在博弈情境是最危險的一種 bug。標示成本極低，但表現出你想過這個領域的風險。
- 磁碟寫入在**背景 Task**，絕不阻塞主執行緒。

---

### FR-6 ⭐ WebSocket 斷線自動重連（加分題）

| ID | 需求 |
|---|---|
| FR-6.1 | 偵測斷線 → 自動重連 |
| FR-6.2 | 🧩 指數退避 + 抖動：`1s, 2s, 4s, 8s, 16s`，上限 30s，每次 ±20% jitter |
| FR-6.3 | 🧩 重連上限 8 次後停止，UI 顯示「重新連線」按鈕 |
| FR-6.4 | 🧩 **重連成功後全量對帳**：重抓 `GET /odds` 覆寫本地 |
| FR-6.5 | 🧩 Debug 面板可手動觸發斷線，讓重連行為能被 demo |

> 🧩 **FR-6.4 是最關鍵的一條，原文件完全沒提**：斷線期間的推播是**永久遺失**的，只重連不對帳，畫面會停在斷線前的舊賠率且**永遠不會自己修正**（除非那場剛好又被推播到）。這個 bug 不會 crash、測不出來、只會讓資料默默錯下去。
> 🧩 **為什麼要 jitter**：真實世界所有客戶端同時斷線時，固定退避會讓它們在同一毫秒一起重連，把剛恢復的伺服器再打掛（thundering herd）。這在 mock 環境沒有實際效果，但它證明你知道這段程式碼上線後會發生什麼。

---

### 🧩 FR-7 比賽詳情頁（文件未要求，建議新增）

一個極簡的第二層畫面：該場比賽的隊伍、開賽時間、當前賠率、**近 60 秒賠率變化 sparkline**。

> **為什麼建議做**：加分題說「切換畫面後能快速恢復顯示」— 但文件只描述了一個畫面，**沒有第二個畫面就無從展示這個加分項**。這一頁存在的唯一目的就是讓 FR-5 可被驗證，所以刻意做到最小。
> 附帶好處：sparkline 需要賠率歷史，正好展示 store 的資料建模不只存「當前值」。

---

## 5. 架構

```
┌─ Presentation ────────────────────────────────────┐
│  MatchListViewController  (UIKit, @MainActor)     │
│  MatchListViewModel       (@MainActor, @Published)│
│  MatchCell / OddsFlashView                        │
└──────────────────┬────────────────────────────────┘
                   │ protocol (依賴反轉)
┌─ Domain ─────────▼────────────────────────────────┐
│  Match / Odds / MatchRow / OddsChange             │
│  ObserveMatchListUseCase                          │
│  MatchRepositoryProtocol   OddsStreamProtocol     │
└──────────────────┬────────────────────────────────┘
                   │
┌─ Data ───────────▼────────────────────────────────┐
│  actor OddsStore          ← 唯一可變狀態           │
│  MatchRepository                                  │
│  MockAPIClient            (延遲/失敗注入)          │
│  MockOddsSocket           (AsyncStream + 重連)     │
│  MemoryCache + DiskCache                          │
└───────────────────────────────────────────────────┘
```

**規則**：
- 依賴方向**永遠向下**。Domain 不 import UIKit，不 import Combine。
- 所有跨層依賴走 protocol，實體在 Composition Root (`AppDependencies`) 組裝。

### 5.1 模組切分（已定案：採用本地 SPM package）

```
OddsBoard.xcodeproj
├── App target            ← 只做 Composition Root + AppDelegate/SceneDelegate
└── Packages/
    ├── OddsCore          ← Domain + Data。零第三方相依，禁 UIKit
    │   └── Tests         ← `swift test` 在命令列跑，無需模擬器
    ├── OddsPresentation  ← ViewModel。可用 Combine，禁 UIKit
    │   └── Tests         ← 同上，無需模擬器
    └── OddsUI            ← View 層。可 import UIKit / SnapKit
        └── Tests         ← 需 xcodebuild + simulator
```

🧩 **為什麼 ViewModel 要與 View 分成兩個模組**：ViewModel 不依賴 UIKit，只用
Combine 對外綁定。把它留在 iOS-only 的 `OddsUI` 裡，它的測試就得靠模擬器跑 ——
而 ViewModel 正是 MVVM 最該被測的一層。獨立出來後它的測試回到「命令列兩秒跑完」
的快迴圈，同時「ViewModel 不得碰 UIKit」也變成編譯期保證。

🧩 **為什麼值得多這一層**：
- 「Domain 不依賴 UI」從資料夾慣例升級成**編譯期保證** — `OddsCore` 沒有 UIKit 可 import，寫錯直接編不過。這正是 §8「機械保證」的精神。
- `OddsCore` 不碰 UIKit ⇒ 其測試可用 **`swift test`** 直接跑，**約 2 秒完成、不需開模擬器**。CI 因此可分兩段：核心測試每次 commit 跑，UI 測試才走 `xcodebuild`。
- 模組邊界逼你把 protocol 定義在正確的一側，MVVM 的分層在 code review 中一眼可驗證。

---

## 6. Swift Concurrency ╱ Combine 邊界規則

這是文件在「架構說明文件」裡點名要回答的題目，所以規則要**簡單到能一句話講完**：

> **跨執行緒存取狀態 → Swift Concurrency。狀態變動通知 UI → Combine。**

| 場景 | 用什麼 | 為什麼不是另一個 |
|---|---|---|
| 共享賠率狀態的保護 | `actor OddsStore` | Combine 無法提供資料隔離保證 |
| 模擬 WebSocket 事件流 | `AsyncStream<OddsUpdate>` | 取消語意跟著 `Task` 走，`deinit` 不會漏 |
| API 請求 | `async throws` | 錯誤即 `throw`，不必處理 `Publisher` 的完成/失敗雙通道 |
| ViewModel → ViewController 綁定 | Combine `@Published` + `sink` | UIKit 無自動重繪；Combine 是綁定最短路徑 |
| UI 更新節流 | 🧩 自製 coalescer，**不用 `.throttle`** | `.throttle` 會丟事件；我們要的是**合併**（保留最後值、聯集所有 ID），語意不同 |

🧩 最後一列很重要：`Combine.throttle` 在區間內丟棄事件，用在這裡會**丟掉其他 matchID 的更新**。自製 coalescer 是把 ID 收進 `Set`、值取最新 — 沒有任何一場比賽的更新會遺失。

---

## 7. 非功能需求與效能預算

| 指標 | 目標 | 量測方式 |
|---|---|---|
| 滾動 FPS | ≥ 58 fps（120Hz 裝置 ≥ 110）| 🧩 Debug overlay 即時顯示（文件建議的驗證方式之一）|
| `reloadData()` 呼叫次數 | **全程 0 次** | 🧩 Lint 規則 + runtime counter，見 §8 |
| 單次 UI flush 耗時 | < 5ms | `os_signpost` + Instruments |
| 端到端更新延遲（推播→畫面）| p50 < 120ms, p95 < 250ms | 🧩 `sentAt` 時間戳 + signpost |
| 記憶體 | 穩定，60 秒推播後無成長 | Instruments Allocations |
| Retain cycle | 0 | Instruments Leaks + `deinit` log |
| 主執行緒阻塞 | 無 > 16ms 的同步工作 | Time Profiler |

🧩 **Debug HUD**：右上角常駐顯示 `FPS │ 推播/秒 │ UI flush/秒 │ p95 延遲 │ reloadData 次數`。
> 為什麼：文件建議「使用 FPS 指標或列印 log」。做成 HUD 而非 log 的原因是 — **錄操作影片時證據直接在畫面上**，reviewer 不用去翻 console。一個畫面同時證明了 FR-3.3 和 FR-3.4。

---

## 8. 品質閘門（機械保證）

原則：**每一條規則都要有機器來執行，而不是靠記得**。

| 規則 | 執行者 |
|---|---|
| 禁止呼叫 `tableView.reloadData()` | 🧩 SwiftLint custom rule，違反 = **編譯錯誤** |
| 禁止 `import SwiftUI` | 🧩 SwiftLint custom rule（守住文件硬性限制）|
| 禁止 `import RxSwift` / `RxCocoa` | 🧩 SwiftLint custom rule（它會取代文件指定的非同步技術）|
| `OddsCore` 禁止 `import UIKit` / 第三方 | 🧩 **SPM 模組邊界，編譯期強制**（§5.1）|
| 資料競爭 | `-strict-concurrency=complete` + CI 跑 Thread Sanitizer |
| 測試通過 | CI: `xcodebuild test` |

> 🧩 第一條是我最推薦的一條。「不可整頁 reload」是本題最核心的驗收條件 — 與其相信自己不會手滑，不如讓專案**在物理上無法**通過編譯。修 bug 時同理：每修一個 bug，就留下一條讓它不可能再發生的規則，而不是留一行註解。

---

## 9. 測試策略（⭐ 文件：有寫單元測試更佳）

| 測試 | 驗證什麼 | 為什麼重要 |
|---|---|---|
| `OddsStore` 並發壓力 | 10 個 Task 各寫 1000 筆 → 結果確定、無 crash | 直接證明 FR-4.1 |
| 亂序丟棄 | seq 5 之後送 seq 3 → 值不變 | 🧩 §3.3 的核心規則 |
| 排序穩定性 | 相同 startTime 的比賽順序固定 | 🧩 FR-3.2 |
| Coalescer | 100ms 內同 ID 更新 5 次 → 只 flush 1 次、值為最後一次 | FR-3.3 效能核心 |
| 重連退避 | 產生序列 = 1,2,4,8,16,30,30…（jitter 範圍內）| FR-6.2 |
| 重連對帳 | 斷線期間漏 3 筆 → 重連後三筆全部正確 | 🧩 FR-6.4 |
| 快取往返 | 寫入 → 讀出 → 完全相等；半寫檔可被偵測 | FR-5 |
| ViewModel | 給定更新流 → 產出正確的待更新 ID 集合 | MVVM 可測性的證明 |

🧩 **`Clock` 抽象化**：所有計時（節流視窗、退避、快取 TTL）都經過注入的 `ClockProtocol`。
> 為什麼：否則測退避序列要真的 `sleep` 31 秒。有了 fake clock，整個測試套件應在 **2 秒內跑完** — 這也讓 CI 有意義。

---

## 10. 交付物檢查表（📄）

- [ ] 原始碼（GitHub Repo）
- [ ] 架構說明文件 `ARCHITECTURE.md`，必須回答文件點名的三題：
  - [ ] Swift Concurrency / Combine 使用場景 → §6 的表格
  - [ ] 如何確保資料存取 thread-safe → §4 的 actor 設計
  - [ ] UI 與 ViewModel 資料綁定方式 → §6 + §5
- [ ] ⭐ 操作影片（含 debug HUD、加壓到 100x、手動斷線重連、切畫面回來秒顯）
- [ ] ⭐ 單元測試（§9）
- [ ] 🧩 `README.md`：一段話說明如何跑、如何開 debug 面板
- [ ] 🧩 **「設計考量與未完成項目」章節** — 文件最後一段明說會「根據設計思維與整體架構一併評估」，這章是唯一能主動陳述取捨的地方，別省略

---

## 11. 建議時程（文件建議 3–5 天）

| 天 | 產出 | 完成定義 |
|---|---|---|
| D1 | 專案骨架、Domain 模型、`MockAPIClient`、`actor OddsStore` | store 單元測試綠燈 |
| D2 | `MockOddsSocket` + AsyncStream、ViewModel、綁定 | 資料能流到 console，測試綠燈 |
| D3 | UITableView + diffable + coalescer + 漲跌閃爍 | **FR-3 全數達標，reloadData 計數 = 0** |
| D4 | ⭐ 快取、⭐ 重連 + 對帳、詳情頁、Debug HUD | 加分題全數可 demo |
| D5 | 測試補完、Instruments 驗證、架構文件、錄影 | 交付物檢查表全綠 |

> 🧩 D3 結束時已滿足文件**所有必要需求**。加分題排在 D4 是刻意的 — 若時間被壓縮，砍掉的是加分項而不是及格線。

---

## 12. 開放項目的定案紀錄

規劃階段留下的未定項，以及最後的決定：

| # | 問題 | 定案 |
|---|---|---|
| 1 | 模組化方案 | **本地 SPM package**（§5.1）|
| 2 | SnapKit 可否使用 | **可用，僅限 `OddsUI`**（§2）|
| 3 | 最低支援版本 | **iOS 16.0**（`reconfigureItems` 需 iOS 15+）|
| 4 | 詳情頁（FR-7）要做嗎 | **要做** —— 否則加分題「切換畫面後快速恢復」無從展示 |
| 5 | Debug HUD / 加壓面板要做嗎 | **要做** —— 它是 FR-3.3 最有力的證據 |
| 6 | 專案名稱 | `OddsBoard` |
| 7 | Repo 公開性 | **public** —— 交件只需貼連結，不必等待邀請 |

### 專案建立參數

Xcode 專案以 GUI 建立而非手寫 `project.pbxproj`（後者脆弱且難以驗證）。
設定為：Template `iOS → App`｜Interface **Storyboard**（建立後刪除 storyboard，
改為程式碼啟動 `UIWindow`；選 SwiftUI 會生成 SwiftUI entry point，牴觸 §2 的限制）｜
Language Swift｜Testing System **None**（測試在 SPM package 內）｜Storage None｜
Minimum Deployments **iOS 16.0**。

開發環境：Xcode 26.1.1 / Swift 6.2.1 / iPhone 16 Pro 模擬器。

---

## 13. 驗收（Definition of Done）

本專案完成的定義是**以下全部成立**：

1. §4 所有 FR 的驗收條件通過
2. `reloadData()` 全程呼叫次數 = 0，且有 HUD 佐證
3. Thread Sanitizer 全綠
4. §9 測試全數通過且 < 5 秒跑完
5. §8 所有品質閘門在 CI 上是綠的
6. §10 交付物檢查表全數勾選

不滿足以上任何一條，不算完成 — 不因為「看起來會動」而放行。
