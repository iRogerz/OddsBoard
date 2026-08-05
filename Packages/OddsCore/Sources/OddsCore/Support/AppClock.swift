import Foundation

/// 時間的抽象。所有等待與「現在幾點」都必須經過它。
///
/// 存在的理由是測試：重連退避序列是 1s → 2s → 4s → 8s → 16s → 30s，
/// 若直接呼叫 `Task.sleep`，驗證這串序列的測試要真的等 61 秒。
/// 注入假時鐘後整套測試可以在毫秒內跑完（見 `docs/spec.md` §9）。
///
/// 這也是為什麼 `.swiftlint.yml` 把 `Thread.sleep` 設成 error。
public protocol AppClock: Sendable {

    var now: Date { get }

    /// 單調時鐘讀數（奈秒），用於量測延遲。不受系統時間調整影響。
    var monotonicNanos: UInt64 { get }

    func sleep(for duration: Duration) async throws
}

/// 正式環境使用的系統時鐘。
public struct SystemClock: AppClock {

    public init() {}

    public var now: Date { Date() }

    public var monotonicNanos: UInt64 { DispatchTime.now().uptimeNanoseconds }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
