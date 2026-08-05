import XCTest
@testable import OddsCore

final class UpdateCoalescerTests: XCTestCase {

    /// 這是合併器存在的理由：同一場比賽在一個視窗內更新多次，
    /// 只該造成一次 UI 工作。
    func test_同一ID在視窗內更新五次_只flush一次() {
        let coalescer = UpdateCoalescer()

        for _ in 0..<5 {
            coalescer.ingest([1001])
        }

        XCTAssertEqual(coalescer.pendingCount, 1)
        XCTAssertEqual(coalescer.flush(), [1001])
        XCTAssertEqual(coalescer.totalFlushes, 1)
    }

    /// 與 `Combine.throttle` 的關鍵差異：不同 ID 必須全部保留。
    /// throttle 會在視窗內丟棄事件，導致某些 cell 永遠不更新。
    func test_不同ID全部保留_不丟棄任何一場() {
        let coalescer = UpdateCoalescer()

        coalescer.ingest([1001, 1002])
        coalescer.ingest([1002, 1003])
        coalescer.ingest([1004])

        XCTAssertEqual(coalescer.flush(), [1001, 1002, 1003, 1004])
    }

    func test_flush後清空() {
        let coalescer = UpdateCoalescer()

        coalescer.ingest([1001, 1002])
        _ = coalescer.flush()

        XCTAssertFalse(coalescer.hasPendingUpdates)
        XCTAssertEqual(coalescer.flush(), [])
    }

    func test_無待更新時flush不計次() {
        let coalescer = UpdateCoalescer()

        _ = coalescer.flush()
        _ = coalescer.flush()

        XCTAssertEqual(
            coalescer.totalFlushes,
            0,
            "沒有待更新時不該產生 UI 工作，也不該被記成一次更新"
        )
    }

    func test_統計反映合併帶來的節省() {
        let coalescer = UpdateCoalescer()

        // 模擬 100 筆推播集中在 10 場比賽上。
        for index in 0..<100 {
            coalescer.ingest([1001 + index % 10])
        }
        let drained = coalescer.flush()

        XCTAssertEqual(coalescer.totalIngested, 100)
        XCTAssertEqual(drained.count, 10, "100 筆推播應該只造成 10 個 cell 的更新")
        XCTAssertEqual(coalescer.totalFlushes, 1)
    }

    func test_reset清空所有狀態() {
        let coalescer = UpdateCoalescer()

        coalescer.ingest([1001])
        _ = coalescer.flush()
        coalescer.ingest([1002])
        coalescer.reset()

        XCTAssertEqual(coalescer.pendingCount, 0)
        XCTAssertEqual(coalescer.totalIngested, 0)
        XCTAssertEqual(coalescer.totalFlushes, 0)
    }
}
