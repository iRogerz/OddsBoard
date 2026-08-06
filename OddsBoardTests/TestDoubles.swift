import Foundation
import OddsCore

/// 會記錄呼叫次數的推播替身。
///
/// 用它取代真實的 `MockOddsSocket`，是因為「有沒有中斷推播」這件事
/// 沒辦法從 UIKit 狀態間接推論 —— 必須直接數 `disconnect()` 被叫了幾次。
/// 先前那支恆真測試就是敗在用 `isMovingFromParent` 去間接斷言。
actor SpyOddsSocket: OddsStreaming {

    nonisolated let events: AsyncStream<OddsStreamEvent>
    private let continuation: AsyncStream<OddsStreamEvent>.Continuation

    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    init() {
        let pipe = AsyncStream<OddsStreamEvent>.makePipe()
        self.events = pipe.stream
        self.continuation = pipe.continuation
    }

    func connect() {
        connectCount += 1
    }

    func disconnect() {
        disconnectCount += 1
    }

    func setUpdatesPerSecond(_ rate: Int) {}

    func simulateDisconnection() {}

    nonisolated func emit(_ event: OddsStreamEvent) {
        continuation.yield(event)
    }
}

/// 可在測試中途改變行為的 API 替身。
///
/// 要測「首次載入成功、之後的對帳失敗」這種情境，必須有可變狀態；
/// 以值傳入的 struct 替身注入後就再也調不動了。
actor ControllableAPI: MatchAPI {

    private let matches: [Match]
    private let odds: [Odds]
    private var error: MatchAPIError?

    init(matches: [Match], odds: [Odds]) {
        self.matches = matches
        self.odds = odds
    }

    func setError(_ error: MatchAPIError?) {
        self.error = error
    }

    func fetchMatches() async throws -> [Match] {
        if let error { throw error }
        return matches
    }

    func fetchOdds() async throws -> [Odds] {
        if let error { throw error }
        return odds
    }
}
