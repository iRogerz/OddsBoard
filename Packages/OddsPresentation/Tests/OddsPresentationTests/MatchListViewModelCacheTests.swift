import XCTest
import OddsCore
@testable import OddsPresentation

/// 快取與重連對帳（`docs/spec.md` §FR-5、§FR-6.4）。
@MainActor
final class MatchListViewModelCacheTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_720_099_200)

    private func makeCachedSnapshot(savedAt: Date) -> CachedSnapshot {
        CachedSnapshot(
            matches: Fixture.matches(3),
            odds: [
                Odds(matchID: 1001, teamAOdds: 9.11, teamBOdds: 9.12),
                Odds(matchID: 1002, teamAOdds: 9.21, teamBOdds: 9.22),
                Odds(matchID: 1003, teamAOdds: 9.31, teamBOdds: 9.32)
            ],
            savedAt: savedAt
        )
    }

    private func makeViewModel(
        cache: InMemorySnapshotCache?,
        matchCount: Int = 3
    ) -> (MatchListViewModel, FakeOddsSocket) {
        var api = FakeMatchAPI()
        api.matches = Fixture.matches(matchCount)
        api.odds = Fixture.odds(matchCount)

        let socket = FakeOddsSocket()
        let viewModel = MatchListViewModel(
            api: api,
            store: OddsStore(),
            socket: socket,
            clock: FixedClock(now: now),
            cache: cache
        )
        return (viewModel, socket)
    }

    private func waitUntil(_ condition: () async -> Bool, iterations: Int = 500) async -> Bool {
        for _ in 0..<iterations {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    // MARK: - 快取

    func test_冷啟動先顯示快取再被API取代() async {
        let cache = InMemorySnapshotCache(initial: makeCachedSnapshot(savedAt: now))
        let (viewModel, _) = makeViewModel(cache: cache)

        await viewModel.start()

        XCTAssertFalse(viewModel.isShowingCachedData, "API 回來後應改標示為即時資料")
        XCTAssertEqual(viewModel.orderedMatchIDs.count, 3)
        XCTAssertEqual(
            viewModel.row(for: 1001)?.odds?.teamAOdds,
            2.00,
            "API 的值必須覆蓋快取的值"
        )
    }

    func test_沒有快取時不影響正常載入() async {
        let (viewModel, _) = makeViewModel(cache: InMemorySnapshotCache())

        await viewModel.start()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertFalse(viewModel.isShowingCachedData)
    }

    func test_新鮮的快取不標示為過期() async {
        let cache = InMemorySnapshotCache(
            initial: makeCachedSnapshot(savedAt: now.addingTimeInterval(-60))
        )
        let (viewModel, _) = makeViewModel(cache: cache)

        await viewModel.start()

        XCTAssertFalse(viewModel.isShowingStaleData)
    }

    /// 直接拿舊賠率當現值顯示，在博弈情境是最危險的一類錯誤。
    func test_過期的快取會被標示() async {
        var api = FakeMatchAPI()
        api.error = .simulatedNetworkFailure   // 讓畫面停在快取狀態
        let cache = InMemorySnapshotCache(
            initial: makeCachedSnapshot(
                savedAt: now.addingTimeInterval(-CachedSnapshot.staleThreshold - 1)
            )
        )
        let viewModel = MatchListViewModel(
            api: api,
            store: OddsStore(),
            socket: FakeOddsSocket(),
            clock: FixedClock(now: now),
            cache: cache
        )

        await viewModel.start()

        XCTAssertTrue(viewModel.isShowingCachedData)
        XCTAssertTrue(viewModel.isShowingStaleData, "過期卻不標示，使用者會誤以為是現值")
    }

    func test_載入成功後寫入快取() async {
        let cache = InMemorySnapshotCache()
        let (viewModel, _) = makeViewModel(cache: cache)

        await viewModel.start()

        let saved = await cache.saveCount
        XCTAssertGreaterThanOrEqual(saved, 1)
        let snapshot = await cache.load()
        XCTAssertEqual(snapshot?.matches.count, 3)
    }

    func test_暫停時寫入快取() async {
        let cache = InMemorySnapshotCache()
        let (viewModel, _) = makeViewModel(cache: cache)
        await viewModel.start()
        let afterStart = await cache.saveCount

        await viewModel.pauseStreaming()

        let afterPause = await cache.saveCount
        XCTAssertGreaterThan(afterPause, afterStart, "離開畫面時應保存當下狀態供下次冷啟動")
    }

    // MARK: - 重連對帳（§FR-6.4）

    /// 斷線期間的推播是永久遺失的。只重連而不重抓 GET /odds，
    /// 那些場次會永遠停在斷線前的舊賠率。
    func test_重連成功後會全量對帳() async {
        let (viewModel, socket) = makeViewModel(cache: nil)
        await viewModel.start()

        // 斷線前收到一筆推播，畫面上是 5.55。
        socket.emit(.updates([
            Fixture.update(matchID: 1001, teamA: 5.55, teamB: 1.11, sequence: 1)
        ]))
        _ = await waitUntil { viewModel.hasPendingUpdates }
        _ = await viewModel.drainPendingUpdates()
        XCTAssertEqual(viewModel.row(for: 1001)?.odds?.teamAOdds, 5.55)

        // 斷線 → 重連成功。
        socket.emit(.connectionState(.reconnecting(attempt: 1)))
        _ = await waitUntil { viewModel.connectionState == .reconnecting(attempt: 1) }
        socket.emit(.connectionState(.connected))

        // 對帳走一般的 flush 路徑：先進合併器，再由畫面節拍 drain 出來。
        // 這正是「校正會抵達畫面」的保證 —— 直接寫內部字典的話，
        // 可見的 cell 永遠不會被 reconfigure。
        let queued = await waitUntil { viewModel.hasPendingUpdates }
        XCTAssertTrue(queued, "對帳必須把場次送進待更新集合")
        _ = await viewModel.drainPendingUpdates()

        XCTAssertEqual(
            viewModel.row(for: 1001)?.odds?.teamAOdds,
            2.00,
            "重連後必須重抓 /odds 校正，否則畫面永遠停在斷線前的值"
        )
    }

    func test_首次連線不觸發對帳() async {
        let (viewModel, socket) = makeViewModel(cache: nil)
        await viewModel.start()

        socket.emit(.updates([
            Fixture.update(matchID: 1001, teamA: 5.55, teamB: 1.11, sequence: 1)
        ]))
        _ = await waitUntil { viewModel.hasPendingUpdates }
        _ = await viewModel.drainPendingUpdates()

        // 沒有經過 reconnecting，單純又送一次 connected。
        socket.emit(.connectionState(.connected))
        for _ in 0..<200 { await Task.yield() }

        XCTAssertEqual(
            viewModel.row(for: 1001)?.odds?.teamAOdds,
            5.55,
            "非重連情境下對帳只是多打一次 API，還會把剛收到的推播蓋掉"
        )
    }

    func test_對帳不觸發整頁漲跌閃爍() async {
        let (viewModel, socket) = makeViewModel(cache: nil)
        await viewModel.start()

        socket.emit(.connectionState(.reconnecting(attempt: 1)))
        _ = await waitUntil { viewModel.connectionState == .reconnecting(attempt: 1) }
        socket.emit(.connectionState(.connected))
        _ = await waitUntil { viewModel.connectionState == .connected }
        for _ in 0..<100 { await Task.yield() }

        for row in viewModel.rows {
            XCTAssertFalse(
                row.change.hasChange,
                "對帳是校正而非賠率跳動，整頁一起閃會讓提示失去意義"
            )
        }
    }

    // MARK: - Code review 回歸測試

    /// **曾經的 bug：對帳的結果永遠不會出現在畫面上。**
    /// `resynchronize()` 更新了內部字典，卻沒把任何 matchID 送進合併器，
    /// 可見的 cell 因此從頭到尾不會被 reconfigure。
    func test_對帳後會把所有場次送進待更新集合() async {
        let (viewModel, socket) = makeViewModel(cache: nil)
        await viewModel.start()
        _ = await viewModel.drainPendingUpdates()
        XCTAssertFalse(viewModel.hasPendingUpdates)

        socket.emit(.connectionState(.reconnecting(attempt: 1)))
        _ = await waitUntil { viewModel.connectionState == .reconnecting(attempt: 1) }
        socket.emit(.connectionState(.connected))

        let queued = await waitUntil { viewModel.hasPendingUpdates }

        XCTAssertTrue(
            queued,
            "對帳若不進合併器，畫面上的 cell 永遠不會被 reconfigure，校正等於沒發生"
        )
        let changed = await viewModel.drainPendingUpdates()
        XCTAssertEqual(changed.count, viewModel.orderedMatchIDs.count)
    }

    /// 曾經的 bug：成功路徑只清 `isShowingCachedData`，忘了 `isShowingStaleData`，
    /// 過期橫幅在即時資料抵達後仍永遠掛在畫面上。
    func test_即時資料抵達後過期標示會被清除() async {
        let cache = InMemorySnapshotCache(
            initial: makeCachedSnapshot(
                savedAt: now.addingTimeInterval(-CachedSnapshot.staleThreshold - 1)
            )
        )
        let (viewModel, _) = makeViewModel(cache: cache)

        await viewModel.start()

        XCTAssertFalse(
            viewModel.isShowingStaleData,
            "橫幅不消失會讓使用者把即時賠率誤認為過期資料，與警示的本意相反"
        )
        XCTAssertFalse(viewModel.isShowingCachedData)
    }

    /// 對帳失敗走的是 REST，推播連線可能完全正常。
    /// 把它寫成 `.failed` 會讓畫面顯示「無法連線」卻同時看到數字在動。
    func test_對帳失敗不會把連線狀態誤標為失敗() async {
        let api = ControllableMatchAPI(
            matches: Fixture.matches(3),
            odds: Fixture.odds(3)
        )
        let socket = FakeOddsSocket()
        let viewModel = MatchListViewModel(
            api: api,
            store: OddsStore(),
            socket: socket,
            clock: FixedClock(now: now),
            cache: nil
        )
        await viewModel.start()

        // 首次載入成功之後才讓 fetchOdds 開始失敗，
        // 這樣失敗的就只有對帳那一次請求。
        await api.setError(.simulatedNetworkFailure)

        socket.emit(.connectionState(.reconnecting(attempt: 1)))
        _ = await waitUntil { viewModel.connectionState == .reconnecting(attempt: 1) }
        socket.emit(.connectionState(.connected))

        let failed = await waitUntil { viewModel.resyncFailed }

        XCTAssertTrue(failed, "對帳失敗必須被明確表達")
        XCTAssertEqual(
            viewModel.connectionState,
            .connected,
            "推播連線是好的，不該被對帳失敗連坐"
        )
    }
}
