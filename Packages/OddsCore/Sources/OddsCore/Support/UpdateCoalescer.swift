import Foundation

/// 把高頻的更新通知合併成低頻的批次，避免 UI 更新頻率被資料到達頻率牽著走。
///
/// **為什麼不用 `Combine.throttle`**：throttle 在時間視窗內**丟棄**事件，
/// 用在這裡會連帶丟掉其他場次的更新 —— 使用者會看到某些 cell 永遠不動。
/// 我們要的是**合併**：ID 取聯集、值取最新（值的部分由 `OddsStore` 的
/// 序號規則保證），一場比賽的更新都不會遺失，只是不會被畫超過一次。
///
/// **為什麼時間驅動留在外面**：`flush()` 由呼叫端決定何時觸發，UI 層可以用
/// `CADisplayLink` 對齊畫面刷新節奏。把節拍寫死在這裡，既測不乾淨，也失去
/// 「UI 更新頻率應由畫面刷新節奏決定」這個設計意圖。
///
/// **為什麼不是 actor**：它由 `@MainActor` 的 ViewModel 獨佔持有，沒有跨執行緒
/// 存取，因此不需要同步機制。做成 actor 只會在每一幀多付一次 actor hop 的成本。
public final class UpdateCoalescer {

    private var pending: Set<Int> = []

    /// 累計統計，供 Debug HUD 顯示「推播進來幾筆 vs 實際畫了幾次」。
    public private(set) var totalIngested: Int = 0
    public private(set) var totalFlushes: Int = 0

    public init() {}

    public var pendingCount: Int { pending.count }

    public var hasPendingUpdates: Bool { !pending.isEmpty }

    /// 累積待更新的 matchID。同一個 ID 在兩次 flush 之間重複進來只會計一次。
    public func ingest(_ matchIDs: some Sequence<Int>) {
        for matchID in matchIDs {
            pending.insert(matchID)
            totalIngested += 1
        }
    }

    /// 取出並清空待更新集合。
    /// - Returns: 需要重新設定的 matchID。無待更新時回傳空集合且不計入 flush 次數。
    public func flush() -> Set<Int> {
        guard !pending.isEmpty else { return [] }

        let drained = pending
        pending.removeAll(keepingCapacity: true)
        totalFlushes += 1
        return drained
    }

    public func reset() {
        pending.removeAll(keepingCapacity: true)
        totalIngested = 0
        totalFlushes = 0
    }
}
