import XCTest
@testable import OddsCore

final class StreamStatsTests: XCTestCase {

    func test_記錄批次時同時累計被丟棄的筆數() {
        var stats = StreamStats()

        stats.recordBatch(received: 10, applied: 7)

        XCTAssertEqual(stats.received, 10)
        XCTAssertEqual(stats.applied, 7)
        XCTAssertEqual(stats.dropped, 3)
    }

    func test_延遲取p95而非平均() {
        var stats = StreamStats()

        // 99 筆很快，1 筆很慢。平均會把那筆慢的稀釋掉，
        // 但使用者感受到的卡頓正是來自它。
        for _ in 0..<99 {
            stats.recordLatency(milliseconds: 10)
        }
        stats.recordLatency(milliseconds: 500)

        XCTAssertEqual(stats.latencyMedian, 10)
        XCTAssertNotNil(stats.latencyP95)
    }

    func test_延遲樣本數有上限() {
        var stats = StreamStats()

        for index in 0..<1000 {
            stats.recordLatency(milliseconds: Double(index))
        }

        // 只保留最近 200 筆，因此中位數必然落在尾段。
        XCTAssertNotNil(stats.latencyMedian)
        XCTAssertGreaterThan(
            stats.latencyMedian ?? 0,
            800,
            "樣本無上限的話長時間執行會無界成長"
        )
    }

    func test_無樣本時延遲為nil() {
        let stats = StreamStats()

        XCTAssertNil(stats.latencyP95)
        XCTAssertNil(stats.latencyMedian)
    }

    func test_reset回到初始狀態() {
        var stats = StreamStats()

        stats.recordBatch(received: 10, applied: 5)
        stats.recordFlush()
        stats.recordLatency(milliseconds: 50)
        stats.reset()

        XCTAssertEqual(stats, StreamStats())
    }
}
