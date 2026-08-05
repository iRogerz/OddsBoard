import XCTest
@testable import OddsCore

final class ReconnectPolicyTests: XCTestCase {

    func test_退避序列為指數成長並夾在上限() {
        let policy = ReconnectPolicy(baseDelay: .seconds(1), maxDelay: .seconds(30))

        let sequence = (1...8).map { policy.unjitteredDelay(forAttempt: $0) }

        XCTAssertEqual(
            sequence,
            [
                .seconds(1), .seconds(2), .seconds(4), .seconds(8),
                .seconds(16), .seconds(30), .seconds(30), .seconds(30)
            ],
            "退避必須指數成長，且不能無限拉長到使用者以為 App 壞了"
        )
    }

    func test_長時間離線不會造成溢位() {
        let policy = ReconnectPolicy(baseDelay: .seconds(1), maxDelay: .seconds(30))

        XCTAssertEqual(policy.unjitteredDelay(forAttempt: 1000), .seconds(30))
    }

    func test_抖動落在設定的比例範圍內() {
        let policy = ReconnectPolicy(jitterFactor: 0.2)
        var generator = SeededGenerator(seed: 42)

        for attempt in 1...6 {
            let base = policy.unjitteredDelay(forAttempt: attempt).seconds
            for _ in 0..<50 {
                let actual = policy.delay(forAttempt: attempt, using: &generator).seconds
                XCTAssertGreaterThanOrEqual(actual, base * 0.8 - 0.001)
                XCTAssertLessThanOrEqual(actual, base * 1.2 + 0.001)
            }
        }
    }

    /// 沒有抖動的話，所有客戶端會在同一毫秒一起重連，
    /// 把剛恢復的伺服器再打掛一次（thundering herd）。
    func test_抖動確實產生不同的延遲() {
        let policy = ReconnectPolicy(jitterFactor: 0.2)
        var generator = SeededGenerator(seed: 7)

        let delays = (0..<20).map { _ in
            policy.delay(forAttempt: 3, using: &generator)
        }

        XCTAssertGreaterThan(Set(delays).count, 1, "所有重連都落在同一時刻會造成驚群效應")
    }

    func test_關閉抖動時回傳理論值() {
        let policy = ReconnectPolicy(jitterFactor: 0)
        var generator = SeededGenerator(seed: 1)

        XCTAssertEqual(policy.delay(forAttempt: 3, using: &generator), .seconds(4))
    }

    func test_超過上限後停止重試() {
        let policy = ReconnectPolicy(maxAttempts: 8)

        XCTAssertTrue(policy.shouldRetry(attempt: 8))
        XCTAssertFalse(
            policy.shouldRetry(attempt: 9),
            "無限重連只會在真的連不上時默默耗電，該把控制權交還使用者"
        )
    }
}
