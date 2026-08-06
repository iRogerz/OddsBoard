import XCTest
import OddsCore
import OddsPresentation
@testable import OddsUI

/// `MatchListViewController` 的整合測試。
///
/// 用真實的 `MockAPIClient` / `MockOddsSocket` 而非測試替身：這一層要驗的是
/// 「整條路徑接起來會不會動」，替身反而會把真正的接線問題藏起來。
@MainActor
final class MatchListViewControllerTests: XCTestCase {

    private func makeSpySubject(
        matchCount: Int = 20
    ) -> (MatchListViewController, MatchListViewModel, SpyOddsSocket) {
        let dataset = MockDataset.make(
            configuration: MockDataset.Configuration(matchCount: matchCount),
            referenceDate: Date(timeIntervalSince1970: 1_720_099_200)
        )
        var apiConfiguration = MockAPIClient.Configuration()
        apiConfiguration.latencyRange = 1...1

        let socket = SpyOddsSocket()
        let viewModel = MatchListViewModel(
            api: MockAPIClient(dataset: dataset, configuration: apiConfiguration),
            store: OddsStore(),
            socket: socket
        )
        return (MatchListViewController(viewModel: viewModel), viewModel, socket)
    }

    private func makeSubject(matchCount: Int = 20) -> (MatchListViewController, MatchListViewModel) {
        let dataset = MockDataset.make(
            configuration: MockDataset.Configuration(matchCount: matchCount),
            referenceDate: Date(timeIntervalSince1970: 1_720_099_200)
        )
        // 延遲設到最小，讓測試不必等真實的網路模擬。
        var apiConfiguration = MockAPIClient.Configuration()
        apiConfiguration.latencyRange = 1...1

        let viewModel = MatchListViewModel(
            api: MockAPIClient(dataset: dataset, configuration: apiConfiguration),
            store: OddsStore(),
            socket: MockOddsSocket(initialOdds: dataset.odds)
        )
        return (MatchListViewController(viewModel: viewModel), viewModel)
    }

    /// 讓 view controller 完成載入。用輪詢讓出執行權而非 sleep ——
    /// 專案憲法禁止測試真的等待。
    private func waitUntilLoaded(
        _ viewModel: MatchListViewModel,
        iterations: Int = 2000
    ) async -> Bool {
        for _ in 0..<iterations {
            if case .loaded = viewModel.loadState { return true }
            await Task.yield()
        }
        return false
    }

    func test_載入後列表顯示全部比賽() async {
        let (viewController, viewModel) = makeSubject(matchCount: 20)
        viewController.loadViewIfNeeded()
        viewController.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        let loaded = await waitUntilLoaded(viewModel)
        XCTAssertTrue(loaded, "載入未完成")

        XCTAssertEqual(viewModel.orderedMatchIDs.count, 20)
    }

    func test_列表依開賽時間升序() async {
        let (viewController, viewModel) = makeSubject(matchCount: 20)
        viewController.loadViewIfNeeded()

        _ = await waitUntilLoaded(viewModel)

        let startTimes = viewModel.rows.map(\.match.startTime)
        XCTAssertEqual(
            startTimes,
            startTimes.sorted(),
            "最早開賽的必須在最上面（spec §4 FR-3.2）"
        )
    }

    /// 本題最核心的效能性質：賠率更新不改變列表順序，
    /// 因此 snapshot 永遠不需要重新 apply，只走 reconfigureItems。
    func test_賠率更新後列表順序不變() async {
        let (viewController, viewModel) = makeSubject(matchCount: 20)
        viewController.loadViewIfNeeded()
        _ = await waitUntilLoaded(viewModel)

        let orderBefore = viewModel.orderedMatchIDs

        for _ in 0..<50 {
            await Task.yield()
        }
        _ = await viewModel.drainPendingUpdates()

        XCTAssertEqual(
            viewModel.orderedMatchIDs,
            orderBefore,
            "順序一旦變動就會觸發整份 snapshot apply，這正是題目要避開的"
        )
    }

    /// 這支測試曾經是恆真的：view 未加入 window 時 display link 根本不會觸發，
    /// 無論 stopDisplayLink 是否被呼叫，uiFlushes 都不會增加 ——
    /// 把整行刪掉測試照樣過。改為直接斷言節拍與推播來源的狀態。
    func test_離開畫面後停止節拍並中斷推播() async {
        let (viewController, viewModel) = makeSubject(matchCount: 20)
        viewController.loadViewIfNeeded()
        _ = await waitUntilLoaded(viewModel)

        viewController.viewWillAppear(false)
        XCTAssertTrue(viewController.isDisplayLinkRunningForTesting, "出現時應啟動節拍")

        viewController.viewDidDisappear(false)

        XCTAssertFalse(
            viewController.isDisplayLinkRunningForTesting,
            "離開畫面仍保留 display link，等於持續為看不見的畫面做更新"
        )
    }

    /// 對照組：沒有啟動節拍的 view controller 必須能被釋放。
    /// 若這支也紅，代表問題不在 CADisplayLink 而在別處。
    func test_未啟動節拍的view_controller可被釋放() async {
        weak var weakViewController: MatchListViewController?

        autoreleasepool {
            let (subject, _) = makeSubject(matchCount: 5)
            weakViewController = subject
            subject.loadViewIfNeeded()
        }
        for _ in 0..<200 { await Task.yield() }

        XCTAssertNil(weakViewController)
    }

    /// CADisplayLink 會強引用 target。若直接把 VC 當 target，只要 link 還在
    /// 排程中 VC 就永遠不會釋放，寫在 deinit 的 invalidate 也就執行不到。
    func test_啟動節拍後view_controller仍可被釋放() async {
        weak var weakViewController: MatchListViewController?

        autoreleasepool {
            let (subject, _) = makeSubject(matchCount: 5)
            weakViewController = subject
            subject.loadViewIfNeeded()
            subject.viewWillAppear(false)
        }
        for _ in 0..<200 { await Task.yield() }

        XCTAssertNil(
            weakViewController,
            "CADisplayLink 強引用 target 會造成 VC 永久洩漏，必須透過弱引用代理"
        )
    }

    /// 這支測試原本是恆真的：它斷言 `isMovingFromParent == false`，
    /// 而那是測試自己剛擺好的 UIKit 事實，與被修的那行 guard 無關 ——
    /// 把 guard 整行刪掉照樣過。改為直接數 `disconnect()` 的呼叫次數。
    func test_被詳情頁覆蓋時不中斷推播() async {
        let (viewController, viewModel, socket) = makeSpySubject()
        let navigationController = UINavigationController(rootViewController: viewController)
        viewController.loadViewIfNeeded()
        _ = await waitUntilLoaded(viewModel)

        viewController.viewWillAppear(false)
        navigationController.pushViewController(UIViewController(), animated: false)
        viewController.viewDidDisappear(false)
        for _ in 0..<200 { await Task.yield() }

        let disconnects = await socket.disconnectCount
        XCTAssertEqual(
            disconnects,
            0,
            "推播若在此中斷，詳情頁的賠率與走勢圖會在進入的瞬間凍結"
        )
        XCTAssertFalse(
            viewController.isDisplayLinkRunningForTesting,
            "看不見的畫面不該繼續做 UI 工作"
        )
    }

    /// 列表是 navigation controller 的 root，永遠不會被 pop 或 dismiss。
    /// 因此任何以「離開列表」為條件的暫停都是死程式碼 ——
    /// 真正該中斷連線與寫入快照的時機是 App 進背景。
    func test_進入背景時中斷推播() async {
        let (viewController, viewModel, socket) = makeSpySubject()
        viewController.loadViewIfNeeded()
        _ = await waitUntilLoaded(viewModel)
        viewController.viewWillAppear(false)

        viewController.handleDidEnterBackground()
        for _ in 0..<200 { await Task.yield() }

        let disconnects = await socket.disconnectCount
        XCTAssertEqual(disconnects, 1, "背景中維持連線等於白白耗電")
        XCTAssertFalse(
            viewController.isDisplayLinkRunningForTesting,
            "背景中不該有任何 UI 工作"
        )
    }

    func test_回到前景時恢復推播與節拍() async {
        let (viewController, viewModel, socket) = makeSpySubject()
        viewController.loadViewIfNeeded()
        _ = await waitUntilLoaded(viewModel)
        viewController.viewWillAppear(false)
        viewController.handleDidEnterBackground()
        for _ in 0..<200 { await Task.yield() }
        let connectsAfterBackground = await socket.connectCount

        viewController.handleWillEnterForeground()
        for _ in 0..<200 { await Task.yield() }

        let connectsAfterForeground = await socket.connectCount
        XCTAssertGreaterThan(connectsAfterForeground, connectsAfterBackground)
        XCTAssertTrue(viewController.isDisplayLinkRunningForTesting)
    }

    /// 若使用者離開 App 前停留在詳情頁，回到前景時列表不該在背後重新開始更新。
    func test_停留在詳情頁時回到前景不重啟列表節拍() async {
        let (viewController, viewModel, _) = makeSpySubject()
        let navigationController = UINavigationController(rootViewController: viewController)
        viewController.loadViewIfNeeded()
        _ = await waitUntilLoaded(viewModel)
        viewController.viewWillAppear(false)

        navigationController.pushViewController(UIViewController(), animated: false)
        viewController.viewDidDisappear(false)
        viewController.handleDidEnterBackground()
        viewController.handleWillEnterForeground()
        for _ in 0..<200 { await Task.yield() }

        XCTAssertFalse(
            viewController.isDisplayLinkRunningForTesting,
            "列表不在畫面上，不該為它做 UI 工作"
        )
    }
}
