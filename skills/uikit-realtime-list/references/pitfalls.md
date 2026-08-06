# 讀程式碼找不到的五個陷阱

這五個都實際發生過，共同點是：**程式碼邏輯看起來完全正確，編譯無警告，
單元測試全綠，但畫面上的行為是錯的。**

遇到「邏輯明明對，畫面就是不對」時，先掃一遍這份。

---

## 1. `UIView.animate` 播不出背景色動畫

### 症狀

想讓 cell 在數值變動時閃一下顏色。寫法看起來完全合理：

```swift
label.backgroundColor = flashColor
UIView.animate(withDuration: 0.6) {
    label.backgroundColor = .clear
}
```

**結果什麼都看不到。** 而且動畫「確實」被加到 layer 上，`animationKeys()` 有值，
沒有任何警告。

### 原因

設定 `backgroundColor` 只寫進 **model layer**，該 runloop 尚未 commit。
UIKit 建立動畫時去取起始值，取到的仍是上一幀的 `.clear` ——
於是動畫變成 `clear → clear`。

### 正解

明確指定 `fromValue` / `toValue`，不留任何推斷空間：

```swift
label.layer.removeAnimation(forKey: key)
label.backgroundColor = .clear          // model 值全程保持 clear，動畫結束不留殘色

let animation = CABasicAnimation(keyPath: "backgroundColor")
animation.fromValue = flashColor.cgColor
animation.toValue = UIColor.clear.cgColor
animation.duration = 0.6
label.layer.add(animation, forKey: key)
```

### 留下的規則

```swift
// 直接斷言動畫的起始色是不透明的
let animation = label.layer.animation(forKey: key) as? CABasicAnimation
let fromColor = animation?.fromValue as! CGColor
XCTAssertGreaterThan(fromColor.alpha, 0)
```

### 通則

**UIKit 的渲染行為不要靠讀程式碼推論。** 這個 bug 讀了三次程式碼都沒找到，
最後靠「只設背景色、不做動畫」的區隔測試，一次定位到問題在動畫本身
而不是佈局或呼叫路徑。

---

## 2. `CADisplayLink` 的保留循環

### 症狀

view controller 永遠不被釋放，`deinit` 不執行。

### 原因

`CADisplayLink(target:selector:)` **強引用** target。若 VC 走過 `viewWillAppear`
卻沒有配對的 `viewDidDisappear`，link 就永遠留在 runloop 上抓著 VC。

最惡毒的地方：寫在 `deinit` 裡的 `invalidate()` **恰好在最需要它時執行不到** ——
因為物件根本沒被釋放，deinit 也就不會被呼叫。

### 正解

透過弱引用代理中介：

```swift
final class DisplayLinkProxy {
    private weak var target: MatchListViewController?
    private let handler: (MatchListViewController) -> Void

    @objc func handleDisplayLink(_ link: CADisplayLink) {
        guard let target else { return }
        handler(target)
    }
}
```

**注意**：`[weak self]` 在這裡沒有用 —— `target:` 參數不接受 closure，
只能透過額外一層代理物件才能拿到弱引用的效果。

### 留下的規則

```swift
func test_啟動節拍後view_controller仍可被釋放() async {
    weak var weakVC: MatchListViewController?
    autoreleasepool {
        let vc = makeSubject()
        weakVC = vc
        vc.loadViewIfNeeded()
        vc.viewWillAppear(false)
    }
    for _ in 0..<200 { await Task.yield() }
    XCTAssertNil(weakVC)
}
```

**務必附一支對照組**（未啟動節拍的 VC 也要能釋放），否則這支測試紅掉時
無法分辨問題在 display link 還是別處。

---

## 3. `isMovingFromParent` 在 navigation root 上恆為 false

### 症狀

用它當「使用者離開這個畫面」的判斷條件，整段程式碼從來沒有被執行過。

```swift
override func viewDidDisappear(_ animated: Bool) {
    if isMovingFromParent || isBeingDismissed {
        pauseStreaming()     // ← 死程式碼
        saveSnapshot()       // ← 死程式碼
    }
}
```

### 原因

列表若是 navigation controller 的 **root**，它永遠不會被 pop、也不會被 dismiss，
兩個條件恆為 `false`。**在 tab 架構下同樣如此**（tab controller 一直持有子 VC）。

### 正解

用 App 生命週期通知，而不是容器語意：

```swift
NotificationCenter.default.addObserver(
    self, selector: #selector(handleDidEnterBackground),
    name: UIApplication.didEnterBackgroundNotification, object: nil)
```

同時注意 `viewDidDisappear` **在 push 下一頁時也會觸發** ——
在那裡中斷資料串流，會讓剛推進來的詳情頁在進入的瞬間凍結。
正確的分工是：`viewDidDisappear` 只停 UI 節拍，進背景才中斷連線。

### 通則

**用 UIKit 的容器語意去判斷業務意圖本身就脆弱。**
`isMovingFromParent` / `isBeingDismissed` 只反映「容器怎麼移動我」，
不反映「使用者的意圖是什麼」。

---

## 4. `AsyncStream` 的單一消費者限制

### 症狀

第二次呼叫 `start()` 時觸發執行期錯誤。

### 原因

`AsyncStream` 只支援**一個**消費者。同時存在兩個 `for await` 迭代器會直接 crash。

常見誤寫：`start()` 的守衛只擋 `.loading` 狀態，於是「已載入完成」時再呼叫一次，
就會對同一個 stream 建立第二個迭代器。

### 正解

事件消費者在整個生命週期內**只建立一次**，連線的開關交給
`connect()` / `disconnect()`：

```swift
private func startStreamingIfNeeded() {
    guard streamTask == nil else { return }
    let events = socket.events
    streamTask = Task { [weak self] in
        for await event in events {
            guard let self else { break }
            await self.handle(event)
        }
    }
}
```

### 附帶影響

如果之後要加「強制重新載入」的入口，它不能直接呼叫 `start()`
（會被守衛擋住），要另開一個不受狀態阻擋的 `reload()`。

---

## 5. flush 交錯造成的漏更新

### 症狀

負載越高，越多次變動「沒有閃」。低頻率下正常。

### 原因

每個節拍各開一個 `Task`，而 flush 內有多個 `await` 點。前後兩輪交錯時，
前一輪的「清除變動標記」會抹掉後一輪剛讀到的標記。

### 正解

互斥旗標：

```swift
guard !isFlushing else { return }
isFlushing = true
Task { @MainActor [weak self] in
    defer { self?.isFlushing = false }
    await self?.flushPendingUpdates()
}
```

### 通則

**「每個節拍開一個 Task」在低頻率下永遠正確，在高頻率下必然出錯。**
任何由計時器驅動、內含 `await` 的工作，都要問一次：
前一輪還沒做完時，下一輪會發生什麼？

---

## 這五個的共同教訓

| 陷阱 | 靠什麼發現 |
|---|---|
| 1. 動畫起始值 | **跑起來看** |
| 2. 保留循環 | code review + 洩漏測試 |
| 3. 死程式碼條件 | code review（獨立視角） |
| 4. 單一消費者 | 執行期 crash |
| 5. flush 交錯 | **加壓後盯著畫面** |

**兩個最難察覺的（1 和 5）都不是靠讀程式碼找到的，而且發生時單元測試全是綠的。**
原因見 `verification.md`。
