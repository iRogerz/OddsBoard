import Foundation

/// 連線狀態。題目沒有要求把它呈現給使用者，但一個「即時」看板若無法讓人
/// 判斷資料是否還在流動，畫面停住時就無從分辨是「賠率沒變」還是「連線斷了」。
public enum OddsConnectionState: Hashable, Sendable {
    case idle
    case connecting
    case connected
    /// 第 n 次重連嘗試中（`docs/spec.md` §FR-6）。
    case reconnecting(attempt: Int)
    /// 超過重連次數上限，等待使用者手動重試。
    case failed
}

/// 推播來源送出的事件。
public enum OddsStreamEvent: Sendable {
    case connectionState(OddsConnectionState)
    case updates([OddsUpdate])
}

/// 賠率推播來源。對應題目的 WebSocket。
///
/// Presentation 層只認識這個 protocol；`MockOddsSocket` 之後要換成真的
/// `URLSessionWebSocketTask`，只需在 Composition Root 換一行。
public protocol OddsStreaming: Sendable {

    /// 事件流。以 `AsyncStream` 而非 Combine `Publisher` 呈現的理由：
    /// 取消語意跟著 `Task` 走 —— ViewController 消失時 Task 被取消，
    /// 推播迴圈自然結束，不需要額外管理 `AnyCancellable` 的生命週期。
    nonisolated var events: AsyncStream<OddsStreamEvent> { get }

    func connect() async
    func disconnect() async

    /// 調整推播頻率。用於 Debug 面板加壓測試（`docs/spec.md` §FR-2）：
    /// 每秒 10 筆對 UITableView 稱不上壓力，要證明架構撐得住得能當場加到 100 倍。
    func setUpdatesPerSecond(_ rate: Int) async
}
