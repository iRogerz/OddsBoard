import XCTest
import OddsCore
import OddsPresentation
@testable import OddsUI

/// `MatchDetailViewController` 的釋放與生命週期。
///
/// **為什麼這組測試值得存在**：詳情頁是全 App 唯一會被反覆建立與銷毀的
/// view controller，因此也是唯一真正有 retain cycle 風險的地方
/// （列表是 navigation root，全程只有一個）。
///
/// 而它原本只能靠 Instruments 的 Leaks 人工驗證 —— 那個工具在模擬器上
/// 經常以 `failed to create a VMUTaskMemoryScanner` 失敗（見
/// `docs/verification.md` §3.3）。把驗證搬進測試，就不必依賴一個會壞的工具。
@MainActor
final class MatchDetailViewControllerTests: XCTestCase {

    private func makeSubject() -> (MatchDetailViewController, OddsStore) {
        let match = Match(
            id: 1001,
            teamA: "Eagles",
            teamB: "Tigers",
            startTime: Date(timeIntervalSince1970: 1_720_099_200)
        )
        let store = OddsStore()
        let viewModel = MatchDetailViewModel(match: match, store: store)
        return (MatchDetailViewController(viewModel: viewModel), store)
    }

    /// 對照組：沒有啟動觀察的詳情頁必須能被釋放。
    /// 若這支也紅，代表問題不在觀察用的 Task 而在別處（例如綁定或版面）。
    func test_未啟動觀察的詳情頁可被釋放() async {
        weak var weakViewController: MatchDetailViewController?

        autoreleasepool {
            let (subject, _) = makeSubject()
            weakViewController = subject
            subject.loadViewIfNeeded()
        }
        for _ in 0..<200 { await Task.yield() }

        XCTAssertNil(weakViewController)
    }

    /// 啟動觀察後仍必須能被釋放。
    ///
    /// `MatchDetailViewModel.startObserving()` 會開一個持續輪詢的 Task。
    /// 它若以強引用捕捉 self，這個 Task 會讓 ViewModel 永遠活著，
    /// 而 ViewModel 被 view controller 強持有 —— 使用者每進一次詳情頁
    /// 就洩漏一頁，且完全沒有任何徵兆。
    func test_啟動觀察後詳情頁仍可被釋放() async {
        weak var weakViewController: MatchDetailViewController?

        autoreleasepool {
            let (subject, _) = makeSubject()
            weakViewController = subject
            subject.loadViewIfNeeded()
            subject.viewWillAppear(false)
        }
        for _ in 0..<200 { await Task.yield() }

        XCTAssertNil(
            weakViewController,
            "輪詢 Task 若強引用 self，每進一次詳情頁就洩漏一頁"
        )
    }

    /// 走完整的 appear → disappear 生命週期後也必須能釋放。
    /// 這條路徑對應使用者真正的操作：push 進來、看一下、pop 回去。
    func test_完整生命週期後詳情頁可被釋放() async {
        weak var weakViewController: MatchDetailViewController?

        autoreleasepool {
            let (subject, _) = makeSubject()
            weakViewController = subject
            subject.loadViewIfNeeded()
            subject.viewWillAppear(false)
            subject.viewDidDisappear(false)
        }
        for _ in 0..<200 { await Task.yield() }

        XCTAssertNil(weakViewController)
    }

    /// 詳情頁顯示的是共用 `OddsStore` 的現值，不是自己抓一份。
    ///
    /// 各自持有一份狀態會出現「列表顯示 1.95、詳情頁顯示 1.92」這種
    /// 使用者一眼就會發現的不一致（見 `AppDependencies` 的 `Session`）。
    func test_詳情頁顯示共用store的現值() async {
        let (subject, store) = makeSubject()
        await store.apply(
            OddsUpdate(
                matchID: 1001,
                teamAOdds: 3.33,
                teamBOdds: 4.44,
                sequence: 1,
                sentAtNanos: 1
            )
        )

        subject.loadViewIfNeeded()
        subject.viewWillAppear(false)

        let updated = await waitUntil {
            subject.teamAOddsTextForTesting == "3.33"
        }
        subject.viewDidDisappear(false)

        XCTAssertTrue(updated, "詳情頁必須反映 store 的現值，而不是啟動時的快照")
    }

    // MARK: - Helper

    /// 觀察是由背景 Task 驅動的，測試必須等它跑到。
    /// 用讓出執行權而非 sleep —— 專案憲法禁止測試真的等待。
    private func waitUntil(
        _ condition: () -> Bool,
        iterations: Int = 500
    ) async -> Bool {
        for _ in 0..<iterations {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
