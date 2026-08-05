import XCTest
@testable import OddsCore

final class MockOddsSocketTests: XCTestCase {

    private func makeInitialOdds(count: Int = 10) -> [Odds] {
        (0..<count).map {
            Odds(matchID: 1001 + $0, teamAOdds: 2.00, teamBOdds: 2.00)
        }
    }

    private func makeSocket(
        updatesPerSecond: Int = 10,
        tickInterval: Duration = .milliseconds(100)
    ) -> (MockOddsSocket, ImmediateClock) {
        let clock = ImmediateClock()
        var configuration = MockOddsSocket.Configuration()
        configuration.updatesPerSecond = updatesPerSecond
        configuration.tickInterval = tickInterval
        let socket = MockOddsSocket(
            initialOdds: makeInitialOdds(),
            configuration: configuration,
            clock: clock
        )
        return (socket, clock)
    }

    // MARK: - 推播頻率（spec §4 FR-2.1）

    func test_預設每秒十筆_每個節拍送出一筆() async {
        let (socket, _) = makeSocket(updatesPerSecond: 10, tickInterval: .milliseconds(100))

        let batch = await socket.emitNextBatch()

        XCTAssertEqual(batch.count, 1, "10 筆/秒 ÷ 每秒 10 個節拍 = 每拍 1 筆")
    }

    func test_加壓後每個節拍送出更多筆() async {
        let (socket, _) = makeSocket(updatesPerSecond: 1000, tickInterval: .milliseconds(100))

        let batch = await socket.emitNextBatch()

        XCTAssertEqual(batch.count, 100, "加壓 100 倍時每拍 100 筆，節拍次數不變")
    }

    func test_可即時調整推播頻率() async {
        let (socket, _) = makeSocket(updatesPerSecond: 10)

        await socket.setUpdatesPerSecond(500)
        let batch = await socket.emitNextBatch()

        XCTAssertEqual(batch.count, 50)
    }

    func test_頻率下限至少每拍一筆() async {
        let (socket, _) = makeSocket(updatesPerSecond: 1, tickInterval: .milliseconds(100))

        let batch = await socket.emitNextBatch()

        XCTAssertEqual(batch.count, 1, "整數除法不該讓推播完全停擺")
    }

    // MARK: - 序號（spec §3.3）

    func test_序號全域單調遞增() async {
        let (socket, _) = makeSocket(updatesPerSecond: 100)

        let first = await socket.emitNextBatch()
        let second = await socket.emitNextBatch()
        let sequences = (first + second).map(\.sequence)

        XCTAssertEqual(sequences, Array(1...UInt64(sequences.count)))
    }

    // MARK: - 賠率漂移（spec §4 FR-2 補充）

    func test_賠率為小幅漂移而非整數亂跳() async {
        let (socket, _) = makeSocket(updatesPerSecond: 10)

        for _ in 0..<50 {
            let batch = await socket.emitNextBatch()
            for update in batch {
                XCTAssertTrue(
                    (1.01...15.00).contains(update.teamAOdds),
                    "teamA 賠率 \(update.teamAOdds) 超出合理區間"
                )
                XCTAssertTrue((1.01...15.00).contains(update.teamBOdds))
            }
        }
    }

    func test_賠率維持在小數點後兩位() async {
        let (socket, _) = makeSocket(updatesPerSecond: 100)

        for _ in 0..<20 {
            let batch = await socket.emitNextBatch()
            for update in batch {
                let scaled = update.teamAOdds * 100
                XCTAssertEqual(
                    scaled,
                    scaled.rounded(),
                    accuracy: 0.0001,
                    "浮點累積誤差會讓賠率變成 1.9500000000000002 這種值"
                )
            }
        }
    }

    func test_單筆漂移幅度不超過零點一五() async {
        let socket = MockOddsSocket(
            initialOdds: [Odds(matchID: 1001, teamAOdds: 5.00, teamBOdds: 5.00)],
            configuration: MockOddsSocket.Configuration(updatesPerSecond: 10),
            clock: ImmediateClock()
        )

        var previous = 5.00
        for _ in 0..<30 {
            let batch = await socket.emitNextBatch()
            guard let update = batch.first else {
                XCTFail("應該至少有一筆推播")
                return
            }
            XCTAssertLessThanOrEqual(
                abs(update.teamAOdds - previous),
                0.15 + 0.0001,
                "漂移過大時漲跌提示會失去意義"
            )
            previous = update.teamAOdds
        }
    }

    func test_賠率確實會變動() async {
        let (socket, _) = makeSocket(updatesPerSecond: 10)

        let first = await socket.emitNextBatch()
        guard let initial = first.first else {
            XCTFail("應該至少有一筆推播")
            return
        }

        var changed = false
        for _ in 0..<20 {
            let batch = await socket.emitNextBatch()
            if batch.contains(where: { $0.matchID == initial.matchID
                && $0.teamAOdds != initial.teamAOdds }) {
                changed = true
                break
            }
        }

        XCTAssertTrue(changed, "推播必須真的造成賠率變動，否則整個 demo 沒有意義")
    }

    // MARK: - 可重現性

    func test_相同種子產生完全相同的推播序列() async {
        let (first, _) = makeSocket()
        let (second, _) = makeSocket()

        let firstBatch = await first.emitNextBatch()
        let secondBatch = await second.emitNextBatch()

        // 只比對由種子決定的內容。`sentAtNanos` 是時間戳，不屬於「相同種子
        // 產生相同結果」的保證範圍，把它納入比較是在測錯東西。
        func content(_ updates: [OddsUpdate]) -> [[Double]] {
            updates.map { [Double($0.matchID), $0.teamAOdds, $0.teamBOdds, Double($0.sequence)] }
        }

        XCTAssertEqual(content(firstBatch), content(secondBatch))
    }

    // MARK: - 連線生命週期

    func test_連線後送出連線中與已連線狀態() async {
        let (socket, _) = makeSocket()

        var iterator = socket.events.makeAsyncIterator()
        await socket.connect()

        guard case .connectionState(let first) = await iterator.next() else {
            XCTFail("第一個事件應為連線狀態")
            return
        }
        XCTAssertEqual(first, .connecting)

        guard case .connectionState(let second) = await iterator.next() else {
            XCTFail("第二個事件應為連線狀態")
            return
        }
        XCTAssertEqual(second, .connected)

        await socket.disconnect()
    }

    func test_重複connect不會啟動第二個迴圈() async {
        let (socket, clock) = makeSocket()

        await socket.connect()
        await socket.connect()
        await Task.yield()
        await socket.disconnect()

        let sleeps = await clock.recorder.durations
        let events = sleeps.count
        XCTAssertGreaterThanOrEqual(events, 0, "重複 connect 不應造成推播速率加倍")
    }

    func test_斷線後送出idle狀態() async {
        let (socket, _) = makeSocket()

        var iterator = socket.events.makeAsyncIterator()
        await socket.connect()
        _ = await iterator.next()   // connecting
        await socket.disconnect()

        var sawIdle = false
        for _ in 0..<10 {
            guard let event = await iterator.next() else { break }
            if case .connectionState(.idle) = event {
                sawIdle = true
                break
            }
        }

        XCTAssertTrue(sawIdle, "斷線必須讓 UI 有機會反映狀態")
    }

    func test_斷線後推播迴圈停止() async {
        let (socket, clock) = makeSocket()

        await socket.connect()
        await Task.yield()
        await socket.disconnect()

        let countAfterDisconnect = await clock.recorder.durations.count
        for _ in 0..<20 {
            await Task.yield()
        }
        let countLater = await clock.recorder.durations.count

        XCTAssertEqual(
            countAfterDisconnect,
            countLater,
            "斷線後迴圈仍在跑代表 Task 沒被取消，會造成背景耗電與記憶體滯留"
        )
    }
}
