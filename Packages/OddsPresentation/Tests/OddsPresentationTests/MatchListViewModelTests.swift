import XCTest
import OddsCore
@testable import OddsPresentation

@MainActor
final class MatchListViewModelTests: XCTestCase {

    private func makeViewModel(
        matchCount: Int = 5,
        error: MatchAPIError? = nil
    ) -> (MatchListViewModel, FakeOddsSocket) {
        var api = FakeMatchAPI()
        api.matches = Fixture.matches(matchCount)
        api.odds = Fixture.odds(matchCount)
        api.error = error

        let socket = FakeOddsSocket()
        let viewModel = MatchListViewModel(
            api: api,
            store: OddsStore(),
            socket: socket,
            clock: SystemClock()
        )
        return (viewModel, socket)
    }

    /// 推播處理是由背景 Task 消費事件流，測試必須等它跑到。
    /// 用讓出執行權而非 sleep —— 專案憲法禁止測試真的等待。
    private func waitUntil(
        _ condition: () async -> Bool,
        iterations: Int = 500
    ) async -> Bool {
        for _ in 0..<iterations {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    // MARK: - 載入

    func test_載入成功後狀態為loaded() async {
        let (viewModel, _) = makeViewModel()

        await viewModel.start()

        XCTAssertEqual(viewModel.loadState, .loaded)
    }

    func test_載入後依開賽時間升序排列() async {
        let (viewModel, _) = makeViewModel(matchCount: 5)

        await viewModel.start()

        // Fixture 刻意逆序建立，正確排序後 matchID 應為遞減。
        XCTAssertEqual(viewModel.orderedMatchIDs, [1005, 1004, 1003, 1002, 1001])
    }

    func test_載入後每列都帶有賠率() async {
        let (viewModel, _) = makeViewModel()

        await viewModel.start()

        for row in viewModel.rows {
            XCTAssertNotNil(row.odds, "matchID \(row.id) 載入後應該要有賠率")
        }
    }

    func test_載入後不標記漲跌() async {
        let (viewModel, _) = makeViewModel()

        await viewModel.start()

        for row in viewModel.rows {
            XCTAssertFalse(row.change.hasChange, "首次載入若標記漲跌，進畫面時整頁都會閃")
        }
    }

    func test_載入失敗時狀態為failed() async {
        let (viewModel, _) = makeViewModel(error: .simulatedNetworkFailure)

        await viewModel.start()

        guard case .failed = viewModel.loadState else {
            XCTFail("應為 failed，實際為 \(viewModel.loadState)")
            return
        }
        XCTAssertTrue(viewModel.orderedMatchIDs.isEmpty)
    }

    func test_載入後自動連線() async {
        let (viewModel, socket) = makeViewModel()

        await viewModel.start()
        let connected = await waitUntil {
            await socket.connectCallCount == 1
        }

        XCTAssertTrue(connected)
    }

    // MARK: - 推播

    func test_收到推播後更新對應的列() async {
        let (viewModel, socket) = makeViewModel()
        await viewModel.start()

        socket.emit(.updates([
            Fixture.update(matchID: 1001, teamA: 2.50, teamB: 1.60, sequence: 1)
        ]))
        _ = await waitUntil { viewModel.hasPendingUpdates }

        let changed = await viewModel.drainPendingUpdates()

        XCTAssertEqual(changed, [1001])
        XCTAssertEqual(viewModel.row(for: 1001)?.odds?.teamAOdds, 2.50)
        XCTAssertEqual(viewModel.row(for: 1001)?.change.teamA, .up)
        XCTAssertEqual(viewModel.row(for: 1001)?.change.teamB, .down)
    }

    /// 本題最核心的效能性質：賠率更新**不會**改變列表順序，
    /// 因此 diffable snapshot 不需要重新 apply，永遠只走 reconfigureItems。
    func test_賠率更新不改變列表順序() async {
        let (viewModel, socket) = makeViewModel()
        await viewModel.start()
        let before = viewModel.orderedMatchIDs

        socket.emit(.updates([
            Fixture.update(matchID: 1001, teamA: 9.99, teamB: 1.01, sequence: 1),
            Fixture.update(matchID: 1005, teamA: 1.10, teamB: 8.00, sequence: 2)
        ]))
        _ = await waitUntil { viewModel.hasPendingUpdates }
        _ = await viewModel.drainPendingUpdates()

        XCTAssertEqual(
            viewModel.orderedMatchIDs,
            before,
            "順序一旦變動就會觸發整份 snapshot apply，這正是題目要避開的"
        )
    }

    func test_同一場比賽在一拍內多次更新只造成一次UI工作() async {
        let (viewModel, socket) = makeViewModel()
        await viewModel.start()

        for sequence in 1...5 {
            socket.emit(.updates([
                Fixture.update(
                    matchID: 1001,
                    teamA: 2.00 + Double(sequence) / 100,
                    teamB: 2.00,
                    sequence: UInt64(sequence)
                )
            ]))
        }
        _ = await waitUntil { viewModel.stats.received >= 5 }

        let changed = await viewModel.drainPendingUpdates()

        XCTAssertEqual(changed, [1001], "5 次推播只該產生 1 個待更新的 cell")
        XCTAssertEqual(
            viewModel.row(for: 1001)?.odds?.teamAOdds,
            2.05,
            "合併後保留的必須是最新值"
        )
    }

    func test_序號過舊的推播被丟棄且不計入已套用() async {
        let (viewModel, socket) = makeViewModel()
        await viewModel.start()

        socket.emit(.updates([
            Fixture.update(matchID: 1001, teamA: 3.00, teamB: 1.50, sequence: 10)
        ]))
        _ = await waitUntil { viewModel.stats.received >= 1 }
        _ = await viewModel.drainPendingUpdates()

        socket.emit(.updates([
            Fixture.update(matchID: 1001, teamA: 9.99, teamB: 9.99, sequence: 3)
        ]))
        _ = await waitUntil { viewModel.stats.received >= 2 }

        XCTAssertEqual(viewModel.stats.dropped, 1)
        XCTAssertEqual(
            viewModel.row(for: 1001)?.odds?.teamAOdds,
            3.00,
            "被丟棄的推播不該影響畫面"
        )
    }

    func test_無待更新時drain不產生UI工作() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.start()

        let changed = await viewModel.drainPendingUpdates()

        XCTAssertTrue(changed.isEmpty)
        XCTAssertEqual(viewModel.stats.uiFlushes, 0)
    }

    func test_統計反映合併帶來的節省() async {
        let (viewModel, socket) = makeViewModel(matchCount: 5)
        await viewModel.start()

        // 50 筆推播集中在 5 場比賽上。
        var sequence: UInt64 = 0
        for round in 0..<10 {
            var batch: [OddsUpdate] = []
            for index in 0..<5 {
                sequence += 1
                batch.append(
                    Fixture.update(
                        matchID: 1001 + index,
                        teamA: 2.00 + Double(round) / 100,
                        teamB: 2.00,
                        sequence: sequence
                    )
                )
            }
            socket.emit(.updates(batch))
        }
        _ = await waitUntil { viewModel.stats.received >= 50 }

        let changed = await viewModel.drainPendingUpdates()

        XCTAssertEqual(viewModel.stats.received, 50)
        XCTAssertEqual(changed.count, 5, "50 筆推播應該只造成 5 個 cell 的更新")
        XCTAssertEqual(viewModel.stats.uiFlushes, 1)
    }

    // MARK: - 連線狀態

    func test_連線狀態變化反映到發布的屬性() async {
        let (viewModel, socket) = makeViewModel()
        await viewModel.start()

        socket.emit(.connectionState(.reconnecting(attempt: 3)))
        let updated = await waitUntil {
            viewModel.connectionState == .reconnecting(attempt: 3)
        }

        XCTAssertTrue(updated)
    }

    // MARK: - 漲跌標記

    func test_清除漲跌標記() async {
        let (viewModel, socket) = makeViewModel()
        await viewModel.start()

        socket.emit(.updates([
            Fixture.update(matchID: 1001, teamA: 2.50, teamB: 1.60, sequence: 1)
        ]))
        _ = await waitUntil { viewModel.hasPendingUpdates }
        _ = await viewModel.drainPendingUpdates()
        XCTAssertTrue(viewModel.row(for: 1001)?.change.hasChange == true)

        await viewModel.clearChanges(for: [1001])

        XCTAssertFalse(
            viewModel.row(for: 1001)?.change.hasChange == true,
            "不清除的話 cell 被重用時會再閃一次早就過期的變動"
        )
    }

    // MARK: - Debug

    func test_可調整推播頻率() async {
        let (viewModel, socket) = makeViewModel()
        await viewModel.start()

        await viewModel.setUpdatesPerSecond(1000)

        let rate = await socket.requestedRate
        XCTAssertEqual(rate, 1000)
    }
}
