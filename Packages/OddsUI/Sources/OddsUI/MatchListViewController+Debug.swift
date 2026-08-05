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

    /// 長按畫面開啟。
    ///
    /// 加壓功能的用意：每秒 10 筆對 UITableView 根本稱不上壓力，
    /// 要證明架構撐得住，得能當場把頻率調到 100 倍。
    func showDebugMenu() {
        let sheet = UIAlertController(
            title: "Debug",
            message: "推播加壓與斷線模擬",
            preferredStyle: .actionSheet
        )
        for rate in [10, 100, 1000] {
            let action = UIAlertAction(title: "推播 \(rate) 筆/秒", style: .default) { [viewModel] _ in
                Task { await viewModel.setUpdatesPerSecond(rate) }
            }
            sheet.addAction(action)
        }
        sheet.addAction(
            UIAlertAction(title: "模擬斷線（觸發重連與對帳）", style: .destructive) { [viewModel] _ in
                Task { await viewModel.simulateDisconnection() }
            }
        )
        sheet.addAction(
            UIAlertAction(
                title: debugHUD.isHidden ? "顯示 HUD" : "隱藏 HUD",
                style: .default
            ) { [weak self] _ in
                self?.debugHUD.isHidden.toggle()
                self?.renderDebugHUD()
            }
        )
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }
}
