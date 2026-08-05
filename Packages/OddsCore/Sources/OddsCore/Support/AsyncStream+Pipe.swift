import Foundation

extension AsyncStream {

    /// 一次取得 stream 與它的 continuation。
    ///
    /// 標準庫的 `AsyncStream.makeStream(of:)` 要 iOS 17 才有，本專案最低支援
    /// iOS 16，因此自備一個等價的工廠方法 —— 而不是在每個呼叫端寫
    /// `var continuation: Continuation!` 這種隱式解包。
    public static func makePipe(
        bufferingPolicy: Continuation.BufferingPolicy = .unbounded
    ) -> (stream: AsyncStream<Element>, continuation: Continuation) {
        var captured: Continuation?
        let stream = AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            captured = continuation
        }
        guard let continuation = captured else {
            // AsyncStream 的建構 closure 保證同步執行，走到這裡代表標準庫行為變了。
            preconditionFailure("AsyncStream 未同步提供 continuation")
        }
        return (stream, continuation)
    }
}
