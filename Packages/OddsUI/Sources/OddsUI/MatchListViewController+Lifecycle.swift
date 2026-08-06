import OddsPresentation
import UIKit

/// App 前景/背景切換的處理。
///
/// **為什麼推播的暫停要掛在這裡，而不是 `viewDidDisappear`：**
/// 列表是 navigation controller 的 root，永遠不會被 pop 或 dismiss，
/// 因此任何以「離開列表」為條件的暫停都不會被觸發。而 `viewDidDisappear`
/// 本身又會在 push 詳情頁時被呼叫 —— 在那裡暫停會讓詳情頁凍結。
///
/// App 進背景才是真正該中斷連線與寫入快照的時機，這也正是
/// `docs/spec.md` §FR-5 所描述的行為。
extension MatchListViewController {

    func observeApplicationLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc
    func handleDidEnterBackground() {
        // 背景中不該有任何 UI 工作，也不該維持連線 ——
        // 換成真實 WebSocket 就是白白耗電。同時把當下狀態寫入快照，
        // 讓下次冷啟動能立刻畫出東西。
        stopDisplayLink()
        Task { [viewModel] in await viewModel.pauseStreaming() }
    }

    @objc
    func handleWillEnterForeground() {
        // 只有列表真的在畫面上時才恢復節拍。若使用者離開前停在詳情頁，
        // 列表不該在背後重新開始更新。
        if isVisible {
            startDisplayLink()
        }
        // 推播則一律恢復 —— 詳情頁也需要它。
        Task { [viewModel] in await viewModel.resumeStreaming() }
    }
}
