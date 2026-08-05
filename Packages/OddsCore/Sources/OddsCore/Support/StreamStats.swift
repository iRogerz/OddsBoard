import Foundation

/// 推播與更新的即時統計，供 Debug HUD 顯示（`docs/spec.md` §7）。
///
/// 題目建議「使用 FPS 指標或列印 log」來證明畫面更新正常。做成畫面上的 HUD
/// 而非 console log 的理由是：錄操作影片時，證據直接在畫面上，reviewer 不必
/// 去翻 console。同一段影片可以同時佐證「更新有到」與「沒有整頁重繪」。
public struct StreamStats: Sendable, Equatable {

    /// 收到的推播總筆數。
    public private(set) var received: Int = 0
    /// 實際被 store 接受的筆數。
    public private(set) var applied: Int = 0
    /// 因序號過舊而被丟棄的筆數。
    public private(set) var dropped: Int = 0
    /// UI 實際批次更新的次數。與 `received` 的比值就是合併帶來的節省。
    public private(set) var uiFlushes: Int = 0

    /// 端到端延遲樣本（毫秒），從推播產生到被套用。
    /// 只保留最近的樣本，避免長時間執行後無界成長。
    private var latencySamples: [Double] = []
    private let sampleLimit = 200

    public init() {}

    public mutating func recordBatch(received: Int, applied: Int) {
        self.received += received
        self.applied += applied
        self.dropped += max(0, received - applied)
    }

    public mutating func recordFlush() {
        uiFlushes += 1
    }

    public mutating func recordLatency(milliseconds: Double) {
        latencySamples.append(milliseconds)
        if latencySamples.count > sampleLimit {
            latencySamples.removeFirst(latencySamples.count - sampleLimit)
        }
    }

    /// 取 p95 而非平均：平均會被大量的快速更新稀釋掉，
    /// 而使用者感受到的卡頓來自尾端那幾次慢的。
    public var latencyP95: Double? {
        guard !latencySamples.isEmpty else { return nil }
        let sorted = latencySamples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))
        return sorted[index]
    }

    public var latencyMedian: Double? {
        guard !latencySamples.isEmpty else { return nil }
        let sorted = latencySamples.sorted()
        return sorted[sorted.count / 2]
    }

    public mutating func reset() {
        self = StreamStats()
    }
}
