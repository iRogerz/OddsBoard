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

    func test_離開畫面後停止產生UI工作() async {
        let (viewController, viewModel) = makeSubject(matchCount: 20)
        viewController.loadViewIfNeeded()
        _ = await waitUntilLoaded(viewModel)

        viewController.viewWillAppear(false)
        viewController.viewDidDisappear(false)

        let flushesAfterLeaving = viewModel.stats.uiFlushes
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(
            viewModel.stats.uiFlushes,
            flushesAfterLeaving,
            "畫面離開後仍在更新 UI 代表 CADisplayLink 沒被停掉，會白白耗電"
        )
    }
}
