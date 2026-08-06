import OddsPresentation
import UIKit

/// Debug HUD 與加壓面板。
///
/// 拆成獨立檔案的直接原因是 SwiftLint 的檔案長度規則擋下了合併版本 ——
/// 而這也確實是個乾淨的切法：這些功能只服務驗證與 demo，
/// 與列表本身的職責無關。
extension MatchListViewController {
    func renderDebugHUD() {
        guard !debugHUD.isHidden else { return }

        let stats = viewModel.stats
        let latency = stats.latencyP95.map { String(format: "%.0fms", $0) } ?? "—"
        let firstLine = "推播 \(stats.received)   套用 \(stats.applied)   丟棄 \(stats.dropped)"
        let secondLine = "UI 批次 \(stats.uiFlushes)   p95 \(latency)   reloadData 0"
        debugHUD.text = firstLine + "\n" + secondLine
    }

    // MARK: - Debug 面板

    /// 掛在導覽列按鈕上的選單。
    ///
    /// 用 `UIMenu` 而不是 `UIAlertController(preferredStyle: .actionSheet)`，
    /// 有兩個實際理由：
    /// 1. **首次開啟明顯較快。** action sheet 第一次呈現要初始化一整套 alert
    ///    的資源，會有肉眼可見的延遲；選單走的是輕量的 context menu 系統。
    /// 2. **不需要 popover 錨點。** action sheet 在 iPad 上沒有錨點會直接 crash，
    ///    而錨點又必須跟著入口（view / barButtonItem）一起維護。選單沒有這個問題。
    ///
    /// 「顯示/隱藏 HUD」與「模擬/恢復載入失敗」的文字取決於當下狀態，因此選單
    /// 必須能反映最新狀態。作法是**在改變狀態的動作執行後重建整份選單**
    /// （`refreshDebugMenu()`），而不是用 `UIDeferredMenuElement.uncached` ——
    /// 後者會在選單不可見時被求值，UIKit 因而印出
    /// 「Called -[UIContextMenuInteraction updateVisibleMenuWithBlock:] while no
    /// context menu is visible」的雜訊。這些文字只會被選單自己的動作改變，
    /// 所以事後重建就足夠，不需要每次開啟都延遲求值。
    func makeDebugMenu() -> UIMenu {
        UIMenu(
            title: "推播加壓、斷線與載入失敗模擬",
            children: makeDebugMenuElements()
        )
    }

    /// 狀態改變後重建選單，讓下次開啟時文字是最新的。
    private func refreshDebugMenu() {
        navigationItem.rightBarButtonItem?.menu = makeDebugMenu()
    }

    private func makeDebugMenuElements() -> [UIMenuElement] {
        [
            makeUpdateRateMenu(),
            makeDisconnectAction(),
            makeFailureSimulationAction(),
            makeHUDToggleAction()
        ]
    }

    /// 加壓功能的用意：每秒 10 筆對 UITableView 根本稱不上壓力，
    /// 要證明架構撐得住，得能當場把頻率調到 100 倍。
    private func makeUpdateRateMenu() -> UIMenu {
        let actions = [10, 100, 1000].map { rate in
            UIAction(title: "推播 \(rate) 筆/秒") { [viewModel] _ in
                Task { await viewModel.setUpdatesPerSecond(rate) }
            }
        }
        return UIMenu(title: "", options: .displayInline, children: actions)
    }

    private func makeDisconnectAction() -> UIAction {
        UIAction(
            title: "模擬斷線（觸發重連與對帳）",
            attributes: .destructive
        ) { [viewModel] _ in
            Task { await viewModel.simulateDisconnection() }
        }
    }

    /// 切換 API 失敗模擬，並立刻重新載入讓結果可見。
    ///
    /// 少了「重新載入」這一步，切換失敗模式不會有任何畫面變化 ——
    /// 載入流程早就跑完了，錯誤分支要重跑一次載入才走得到。
    private func makeFailureSimulationAction() -> UIAction {
        let isSimulating = isSimulatingAPIFailure
        return UIAction(
            title: isSimulating ? "恢復正常載入並重試" : "模擬載入失敗",
            attributes: isSimulating ? [] : .destructive
        ) { [weak self] _ in
            guard let self else { return }
            let shouldFail = !self.isSimulatingAPIFailure
            self.isSimulatingAPIFailure = shouldFail
            // 標題會跟著切換成「恢復正常載入並重試」，重建選單讓下次開啟時是對的。
            self.refreshDebugMenu()

            Task { [weak self] in
                guard let self else { return }
                await self.onSimulateAPIFailure?(shouldFail)
                await self.viewModel.reload()
            }
        }
    }

    private func makeHUDToggleAction() -> UIAction {
        UIAction(title: debugHUD.isHidden ? "顯示 HUD" : "隱藏 HUD") { [weak self] _ in
            self?.debugHUD.isHidden.toggle()
            self?.renderDebugHUD()
            self?.refreshDebugMenu()
        }
    }
}
