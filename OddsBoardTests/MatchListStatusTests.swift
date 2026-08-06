import XCTest
import OddsCore
import OddsPresentation
@testable import OddsUI

/// 狀態列文字。
///
/// 重連期間的狀態只存在幾秒，靠截圖捕捉不可靠 ——
/// 用斷言逐一驗證每種連線狀態對應的文字才是穩定的做法。
@MainActor
final class MatchListStatusTests: XCTestCase {

    private func makeSubject() -> (MatchListViewController, MatchListViewModel, SpyOddsSocket) {
        let dataset = MockDataset.make(
            configuration: MockDataset.Configuration(matchCount: 5),
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

    private func waitUntil(_ condition: () -> Bool, iterations: Int = 2000) async -> Bool {
        for _ in 0..<iterations {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    func test_重連中的狀態列顯示嘗試次數() async {
        let (viewController, viewModel, socket) = makeSubject()
        viewController.loadViewIfNeeded()
        _ = await waitUntil { viewModel.loadState == .loaded }

        socket.emit(.connectionState(.reconnecting(attempt: 3)))
        let shown = await waitUntil {
            viewController.statusTextForTesting?.contains("第 3 次") == true
        }

        XCTAssertTrue(
            shown,
            "重連時若不顯示狀態，使用者無法分辨是『賠率沒變』還是『連線斷了』"
        )
    }

    func test_各連線狀態都有對應文字() async {
        let (viewController, viewModel, socket) = makeSubject()
        viewController.loadViewIfNeeded()
        _ = await waitUntil { viewModel.loadState == .loaded }

        let cases: [(OddsConnectionState, String)] = [
            (.connected, "即時更新中"),
            (.connecting, "連線中"),
            (.idle, "已中斷"),
            (.failed, "無法連線")
        ]

        for (state, expected) in cases {
            socket.emit(.connectionState(state))
            let shown = await waitUntil {
                viewController.statusTextForTesting?.contains(expected) == true
            }
            XCTAssertTrue(shown, "狀態 \(state) 應顯示包含「\(expected)」的文字")
        }
    }

    /// **對帳失敗必須可見。**
    ///
    /// 它代表「重連成功了，但斷線期間遺失的推播沒補回來」——
    /// 部分場次會停在舊值且不會自我修正，而畫面其他地方看起來一切正常。
    /// 曾經有一版把這個訊號從 `connectionState = .failed` 改成獨立旗標，
    /// 卻沒接到任何 UI，等於把可見的失敗變成完全靜默。
    func test_對帳失敗時狀態列要看得出來() async {
        let dataset = MockDataset.make(
            configuration: MockDataset.Configuration(matchCount: 5),
            referenceDate: Date(timeIntervalSince1970: 1_720_099_200)
        )
        let api = ControllableAPI(matches: dataset.matches, odds: dataset.odds)
        let socket = SpyOddsSocket()
        let viewModel = MatchListViewModel(
            api: api,
            store: OddsStore(),
            socket: socket
        )
        let viewController = MatchListViewController(viewModel: viewModel)
        viewController.loadViewIfNeeded()
        _ = await waitUntil { viewModel.loadState == .loaded }

        // 首次載入成功之後才讓 fetchOdds 失敗，這樣壞掉的只有對帳那一次。
        await api.setError(.simulatedNetworkFailure)

        socket.emit(.connectionState(.reconnecting(attempt: 1)))
        _ = await waitUntil { viewModel.connectionState == .reconnecting(attempt: 1) }
        socket.emit(.connectionState(.connected))

        let failed = await waitUntil { viewModel.resyncFailed }
        XCTAssertTrue(failed, "前置條件：對帳應該失敗")

        let visible = await waitUntil {
            viewController.statusTextForTesting?.contains("校正失敗") == true
        }

        XCTAssertTrue(
            visible,
            "對帳失敗若不顯示，使用者沒有任何線索可以察覺部分場次停在舊值。"
                + "實際文字：\(viewController.statusTextForTesting ?? "nil")"
        )
    }
}
