import Foundation

/// 斷線重連的退避策略（`docs/spec.md` §FR-6）。
///
/// 指數退避加上抖動：`1s, 2s, 4s, 8s, 16s, 30s(上限)`，每次乘上 ±20% 的隨機因子。
///
/// **為什麼要抖動**：真實情況下所有客戶端往往同時斷線（伺服器重啟、機房網路
/// 中斷）。固定退避會讓它們在同一毫秒一起重連，把剛恢復的伺服器再打掛一次
/// —— 也就是 thundering herd。抖動把重連時間散開。
/// 在 mock 環境裡這沒有實際效果，但它表明這段程式碼上線後會發生什麼事。
public struct ReconnectPolicy: Sendable {

    public let baseDelay: Duration
    public let maxDelay: Duration
    public let maxAttempts: Int
    /// 抖動比例。0.2 代表實際延遲落在計算值的 80%~120% 之間。
    public let jitterFactor: Double

    public init(
        baseDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(30),
        maxAttempts: Int = 8,
        jitterFactor: Double = 0.2
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
        self.jitterFactor = jitterFactor
    }

    /// 是否還要繼續嘗試。超過上限後應停止並讓使用者手動重試 ——
    /// 無限重連只會在真的連不上時默默耗電，不如把控制權交還給使用者。
    public func shouldRetry(attempt: Int) -> Bool {
        attempt <= maxAttempts
    }

    /// 第 n 次嘗試（從 1 起算）之前該等待多久。
    public func delay(
        forAttempt attempt: Int,
        using generator: inout some RandomNumberGenerator
    ) -> Duration {
        let base = unjitteredDelay(forAttempt: attempt)
        guard jitterFactor > 0 else { return base }

        let factor = Double.random(
            in: (1 - jitterFactor)...(1 + jitterFactor),
            using: &generator
        )
        // 以總奈秒數運算，而非只取 `components.seconds`：
        // 後者會讓任何小於一秒的設定值被無聲丟棄。
        let nanos = Double(base.totalNanoseconds) * factor
        return .nanoseconds(Int64(nanos))
    }

    /// 未加抖動的理論值，供測試斷言退避序列的形狀。
    public func unjitteredDelay(forAttempt attempt: Int) -> Duration {
        guard attempt > 0 else { return baseDelay }

        let maxNanos = maxDelay.totalNanoseconds
        var nanos = baseNanos

        // 逐次倍增並在每一步檢查上限，長時間離線也不會溢位。
        for _ in 0..<(attempt - 1) {
            if nanos >= maxNanos { return maxDelay }
            let (doubled, overflow) = nanos.multipliedReportingOverflow(by: 2)
            if overflow { return maxDelay }
            nanos = doubled
        }
        return nanos >= maxNanos ? maxDelay : .nanoseconds(nanos)
    }

    private var baseNanos: Int64 {
        max(1, baseDelay.totalNanoseconds)
    }
}

extension Duration {

    /// 總奈秒數。`components.seconds` 會丟掉小數部分，
    /// 任何以毫秒為單位設定的 `Duration` 都會因此被當成 0。
    var totalNanoseconds: Int64 {
        let fromSeconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !fromSeconds.overflow else { return .max }
        let fromAttoseconds = components.attoseconds / 1_000_000_000
        let total = fromSeconds.partialValue.addingReportingOverflow(fromAttoseconds)
        return total.overflow ? .max : total.partialValue
    }
}
