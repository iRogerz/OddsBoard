# 驗證分層：哪一類 bug 靠什麼方式才抓得到

這份的核心主張只有一句：

> **專案的弱點通常不是「審得不夠多」，是「驗得不夠真」。**

以下來自一個 UIKit 即時列表專案的實際經驗：兩輪 code review 各找出 6 項與 7 項
問題，但**最嚴重的兩個 bug 都不是靠讀程式碼找到的，而且發生時單元測試全是綠的**。

---

## 一、bug 與偵測方式的對應

| bug | 靠什麼發現 | 為什麼其他方式抓不到 |
|---|---|---|
| 漲跌閃爍完全不生效 | **跑模擬器** | 動畫確實被加到 layer、`animationKeys()` 有值、無警告。程式碼層面看不出錯 |
| 統計數字灌水 | **盯著畫面上的數字** | 型別完全合法，計算式看起來合理 |
| 高頻下漏更新 | **加壓後盯畫面** | 低頻率下永遠正確 |
| 對帳結果不會抵達畫面 | code review | 邏輯正確，只是少接一條線到 UI |
| 詳情頁進入即凍結 | code review | 生命週期方法的副作用 |
| `CADisplayLink` 保留循環 | code review + 洩漏測試 | 沒有任何執行期徵兆 |
| 暫停/存檔整段是死程式碼 | code review | 條件恆為 false，但語法完全正確 |

**規律**：`code review` 擅長抓「結構性錯誤」（漏接線、錯誤的條件、生命週期）；
**只有實際執行才抓得到「渲染與時序」類的錯誤**。兩者不能互相取代。

---

## 二、為什麼「測試全綠但畫面不動」

這是 UIKit + MVVM 專案的結構性弱點，值得單獨理解。

```
ViewModel 內部狀態  ←── 單元測試驗這裡（快、穩、好寫）
        │
        │  ← bug 最常發生在這一段
        ▼
    畫面上的像素   ←── 幾乎沒有測試驗這裡
```

**UIKit 沒有 SwiftUI 的自動重繪**，每個要上畫面的狀態都必須明確接一條線
（`sink` 到某個 UI 屬性）。漏接一條的症狀就是：

- ViewModel 的 `@Published` 值正確 ✓
- 針對它的單元測試全綠 ✓
- 畫面完全不動 ✗

某專案為此踩過三次（動畫、對帳結果、失敗提示）。

### 對策一：在綁定處留下提醒

```swift
/// ViewModel → View 的綁定。
/// **漏接一條的代價是「單元測試全綠、畫面卻不動」** —— 本專案已因此踩過三次。
/// 新增 @Published 屬性時，請一併確認它在這裡有對應的訂閱。
extension MatchListViewController {
    func bind() { ... }
}
```

### 對策二：寫「驗最終輸出」而非「驗中間狀態」的測試

不要只斷言 ViewModel 的屬性，要斷言**真正抵達畫面的東西**：

```swift
// 弱：驗 ViewModel 內部狀態
XCTAssertEqual(viewModel.connectionState, .reconnecting(attempt: 3))

// 強：驗畫面上實際顯示的文字
XCTAssertEqual(viewController.statusTextForTesting, "連線中斷，重試中（第 3 次）")

// 強：驗動畫的實際起始顏色
XCTAssertGreaterThan(fromColor.alpha, 0)
```

需要為此開一點測試觀察窗。**保持 view 本身 private，只開唯讀的 computed
property** —— 測試該驗的是「畫面顯示什麼」，不是「內部有哪些 view」。

---

## 三、識別「恆真測試」

**一支永遠會過的測試比沒有測試更糟**：它會讓人以為那條路徑有人守著。

### 怎麼發現

> **把被測的那行程式碼刪掉，測試還會過嗎？**

如果會過，這支測試是假的。

### 實際案例

**案例一：斷言了測試自己擺好的事實**

```swift
func test_被詳情頁覆蓋時不中斷推播() {
    // ...
    XCTAssertFalse(viewController.isMovingFromParent)   // ← 這是 UIKit 的預設值
}
```

斷言的是測試自己剛擺好的 UIKit 狀態，與被測的那行 guard 毫無關係。
把 guard 整行刪掉照樣過。

**改法**：用 spy 直接數呼叫次數。

```swift
let disconnectCount = await spySocket.disconnectCount
XCTAssertEqual(disconnectCount, 0)
```

**案例二：前置條件讓被測行為不可能觸發**

```swift
func test_離開畫面後停止產生UI工作() {
    // view 沒有被加入 window，display link 本來就不會觸發
    XCTAssertEqual(viewModel.stats.uiFlushes, 0)
}
```

把 `stopDisplayLink()` 整個刪掉照樣過。

**改法**：直接斷言節拍的狀態，而不是它的間接後果。

```swift
XCTAssertFalse(viewController.isDisplayLinkRunningForTesting)
```

### 預防

**每寫一支測試，先讓它紅一次。** 沒看過它紅的測試，不知道它在守什麼。

---

## 四、驗證工具本身會壞

不要把驗收的唯一防線押在一個會壞的工具上。

### 實例：Instruments Leaks

```
Failed to generate memory graph for pid NNN: failed to create a
VMUTaskMemoryScanner, probably because the target's libmalloc
hasn't been initialized
```

Leaks 在 iOS 模擬器上經常這樣掛掉。若「有沒有 retain cycle」只能靠它驗，
那天它壞了就等於沒有防線。

### 對策：能搬進測試的就搬進測試

```swift
func test_詳情頁在完整生命週期後可被釋放() async {
    weak var weakVC: MatchDetailViewController?
    autoreleasepool {
        let vc = makeSubject()
        weakVC = vc
        vc.loadViewIfNeeded()
        vc.viewWillAppear(false)
        vc.viewDidDisappear(false)
    }
    for _ in 0..<200 { await Task.yield() }
    XCTAssertNil(weakVC)
}
```

搬進測試後，它每次跑測試都會驗，不依賴任何 GUI 工具。

### 各工具的替代方案

| 原本 | 壞掉時的替代 |
|---|---|
| Instruments Leaks | `weak var` + `autoreleasepool` 測試；Xcode Memory Graph Debugger |
| Thread Sanitizer（不支援真機） | 模擬器上跑；並發壓力測試 |
| 手動看 FPS | Animation Hitches 的 Hitch Time Ratio |

---

## 五、平台限制的備忘

這些不記下來每次都要重新踩：

| 限制 | 內容 |
|---|---|
| Thread Sanitizer | **不支援 iOS 真機**，只能模擬器或 macOS |
| Instruments Leaks | 模擬器上常失敗，改用 Memory Graph Debugger |
| ProMotion | iOS 15 起 App 預設仍以 **60fps** 渲染，除非在 Info.plist 加 `CADisableMinimumFrameDurationOnPhone`。一幀是 16.67ms 不是 8.33ms |
| Animation Hitches | 給的是 **Hitch Time Ratio**（良好 < 5 ms/s），不是 fps |
| 效能數字 | **必須用真機**。模擬器跑在 Mac 的 CPU/GPU 上，只有「有沒有明顯錯誤」有參考價值 |

---

## 六、把驗證寫成可執行的清單

驗證最容易退化成「跑一跑覺得還行」。對策是**事先寫死「看什麼欄位、什麼算通過」**：

```markdown
### Animation Hitches
**操作**：三種頻率各滾動 20 秒 —— 10 / 100 / 1000 筆每秒

| 看什麼 | 通過標準 |
|---|---|
| Hitch Time Ratio | < 5 ms/s |
| 單次 hitch 的 duration | 落在幀邊界整數倍＝瞬時事件；不規則大數字才是效能問題 |
| **三種頻率的差異** | 體感應幾乎沒有差別。有差別代表合併沒有真的解耦 |
```

最後一列是重點：**判準不是絕對數字，而是「加壓 100 倍後有沒有變差」**。
絕對數字受機型影響，相對差異才反映架構。

---

## 總結：驗證的四個層次

| 層次 | 抓什麼 | 成本 |
|---|---|---|
| 編譯期（型別、模組邊界、linter） | 結構性違規 | 零，且不可能被繞過 |
| 單元測試 | 邏輯與狀態轉換 | 低，每次 commit 跑 |
| 整合測試（真實 UI 元件） | 狀態到畫面那一段 | 中，需要模擬器 |
| 人工 + Instruments | 渲染、時序、記憶體、效能 | 高，但**無可取代** |

**最上面兩層最便宜，也最容易讓人產生虛假的安全感。**
高頻更新、動畫、生命週期這三類問題，只有最下面兩層抓得到。
