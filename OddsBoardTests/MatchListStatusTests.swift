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

    private func makeSubject() -> (MatchListViewController, MatchListViewModel, FakeSocket) {
        let dataset = MockDataset.make(
            configuration: MockDataset.Configuration(matchCount: 5),
            referenceDate: Date(timeIntervalSince1970: 1_720_099_200)
        )
        var apiConfiguration = MockAPIClient.Configuration()
        apiConfiguration.latencyRange = 1...1

        let socket = FakeSocket()
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
}

/// 可由測試注入事件的推播替身。
private actor FakeSocket: OddsStreaming {

    nonisolated let events: AsyncStream<OddsStreamEvent>
    private let continuation: AsyncStream<OddsStreamEvent>.Continuation

    init() {
        let pipe = AsyncStream<OddsStreamEvent>.makePipe()
        self.events = pipe.stream
        self.continuation = pipe.continuation
    }

    func connect() {}
    func disconnect() {}
    func setUpdatesPerSecond(_ rate: Int) {}
    func simulateDisconnection() {}

    nonisolated func emit(_ event: OddsStreamEvent) {
        continuation.yield(event)
    }
}
