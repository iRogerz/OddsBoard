import XCTest
import OddsCore
@testable import OddsPresentation

/// 重新載入與載入失敗的行為（`docs/spec.md` §FR-1.4）。
///
/// 這一組測試守的是兩件事：
/// 1. `reload()` 必須真的能重跑載入流程 —— 否則 `.failed` 那條 UI 分支
///    在 App 裡是永遠走不到的死碼，只有測試碰得到。
/// 2. **不變式：`loadState == .failed` ⟺ 畫面上沒有即時資料在流動。**
@MainActor
final class MatchListViewModelReloadTests: XCTestCase {

    /// 具名而非 tuple：這一組測試需要同時操作 API（注入錯誤）與
    /// socket（數連線次數），三個成員的 tuple 在呼叫端只剩位置可辨識。
    private struct Context {
        let viewModel: MatchListViewModel
        let api: ControllableMatchAPI
        let socket: FakeOddsSocket
    }

    private func makeContext(error: MatchAPIError? = nil) -> Context {
        let api = ControllableMatchAPI(
            matches: Fixture.matches(3),
            odds: Fixture.odds(3),
            error: error
        )
        let socket = FakeOddsSocket()
        return Context(
            viewModel: MatchListViewModel(
                api: api,
                store: OddsStore(),
                socket: socket,
                clock: FixedClock(now: Fixture.base)
            ),
            api: api,
            socket: socket
        )
    }

    // MARK: - reload 必須真的能重跑

    /// `start()` 會擋掉已載入完成的情況，因此無法用來重跑載入流程。
    /// 少了 `reload()`，Debug 面板切換失敗模式後畫面不會有任何變化。
    func test_重新載入不受已載入狀態阻擋而且能走到失敗() async {
        let context = makeContext()

        await context.viewModel.start()
        XCTAssertEqual(context.viewModel.loadState, .loaded)

        await context.api.setError(.simulatedNetworkFailure)
        await context.viewModel.reload()

        guard case .failed = context.viewModel.loadState else {
            return XCTFail("重新載入必須真的重跑載入流程，才走得到錯誤分支")
        }
    }

    /// 對照組：同樣的情境改呼叫 `start()`，狀態不該有任何變化 ——
    /// 這正是需要獨立 `reload()` 入口的原因。
    func test_已載入完成後呼叫start不會重跑載入() async {
        let context = makeContext()

        await context.viewModel.start()
        await context.api.setError(.simulatedNetworkFailure)
        await context.viewModel.start()

        XCTAssertEqual(
            context.viewModel.loadState,
            .loaded,
            "start() 的守衛必須擋住已載入完成的情況，否則會重複建立事件消費者"
        )
    }

    // MARK: - 失敗時不得留下還在流動的資料

    /// **不變式：`loadState == .failed` ⟺ 畫面上沒有即時資料在流動。**
    ///
    /// 少了這條，重新載入失敗後推播仍在跑，畫面會顯示「載入失敗」卻同時
    /// 看到賠率跳動。首次冷啟動失敗不會暴露這個問題（`connect()` 排在 `try`
    /// 之後、根本還沒被呼叫），所以這支測試必須從「已載入成功」的狀態測起。
    func test_重新載入失敗時必須中斷推播() async {
        let context = makeContext()

        await context.viewModel.start()
        let disconnectsBefore = await context.socket.disconnectCallCount

        await context.api.setError(.simulatedNetworkFailure)
        await context.viewModel.reload()

        let disconnectsAfter = await context.socket.disconnectCallCount
        XCTAssertEqual(
            disconnectsAfter,
            disconnectsBefore + 1,
            "載入失敗卻放任推播繼續，畫面會一邊寫著失敗一邊跳賠率"
        )
    }

    /// 失敗後恢復正常再重載，必須回到 `.loaded` 且推播跟著回來 ——
    /// Debug 面板的「恢復正常載入並重試」走的就是這條路。
    func test_失敗後恢復正常可重新載入成功() async {
        let context = makeContext(error: .simulatedNetworkFailure)

        await context.viewModel.start()
        guard case .failed = context.viewModel.loadState else {
            return XCTFail("前置條件：首次載入應該失敗")
        }

        await context.api.setError(nil)
        await context.viewModel.reload()

        XCTAssertEqual(context.viewModel.loadState, .loaded)
        XCTAssertEqual(context.viewModel.orderedMatchIDs.count, 3)

        // 推播必須跟著回來。只把資料載回來卻不重連，畫面會是一份
        // 永遠不再更新的靜態快照 —— 而使用者看到的是「已恢復」。
        let connectCount = await context.socket.connectCallCount
        XCTAssertGreaterThan(connectCount, 0, "恢復載入後必須重新連上推播")
    }
}
