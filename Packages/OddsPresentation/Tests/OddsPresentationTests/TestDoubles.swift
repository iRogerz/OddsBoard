import Foundation
import OddsCore
@testable import OddsPresentation

struct FakeMatchAPI: MatchAPI {

    var matches: [Match] = []
    var odds: [Odds] = []
    var error: MatchAPIError?

    func fetchMatches() async throws -> [Match] {
        if let error { throw error }
        return matches
    }

    func fetchOdds() async throws -> [Odds] {
        if let error { throw error }
        return odds
    }
}

/// 可由測試逐一注入事件的推播來源。
///
/// 與 `MockOddsSocket` 的差別：後者是產品用的模擬器（會自己產生資料），
/// 這個只是測試替身，讓測試完全掌控「什麼時候送出什麼」。
actor FakeOddsSocket: OddsStreaming {

    nonisolated let events: AsyncStream<OddsStreamEvent>

    private let continuation: AsyncStream<OddsStreamEvent>.Continuation

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var requestedRate: Int?

    init() {
        let pipe = AsyncStream<OddsStreamEvent>.makePipe()
        self.events = pipe.stream
        self.continuation = pipe.continuation
    }

    func connect() {
        connectCallCount += 1
    }

    func disconnect() {
        disconnectCallCount += 1
    }

    func setUpdatesPerSecond(_ rate: Int) {
        requestedRate = rate
    }

    nonisolated func emit(_ event: OddsStreamEvent) {
        continuation.yield(event)
    }
}

enum Fixture {

    static let base = Date(timeIntervalSince1970: 1_720_099_200)

    static func matches(_ count: Int) -> [Match] {
        (0..<count).map { index in
            Match(
                id: 1001 + index,
                teamA: "Team A\(index)",
                teamB: "Team B\(index)",
                // 刻意逆序建立，確保 ViewModel 真的有排序而不是照收。
                startTime: base.addingTimeInterval(TimeInterval((count - index) * 60))
            )
        }
    }

    static func odds(_ count: Int) -> [Odds] {
        (0..<count).map { index in
            Odds(matchID: 1001 + index, teamAOdds: 2.00, teamBOdds: 2.00)
        }
    }

    static func update(
        matchID: Int,
        teamA: Double,
        teamB: Double,
        sequence: UInt64
    ) -> OddsUpdate {
        OddsUpdate(
            matchID: matchID,
            teamAOdds: teamA,
            teamBOdds: teamB,
            sequence: sequence,
            sentAtNanos: 1
        )
    }
}
