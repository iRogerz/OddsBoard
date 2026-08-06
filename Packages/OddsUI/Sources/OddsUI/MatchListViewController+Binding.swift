import Combine
import OddsCore
import OddsPresentation
import UIKit

/// ViewModel → View 的綁定，以及各種狀態的渲染。
///
/// UIKit 沒有 SwiftUI 的自動重繪，因此每一個要上畫面的狀態都必須在這裡
/// 明確接上一條線。**漏接一條的代價是「單元測試全綠、畫面卻不動」**——
/// 這個專案已經因此踩過三次（漲跌閃爍、對帳結果、對帳失敗提示）。
/// 新增 `@Published` 屬性時，請一併確認它在這裡有對應的訂閱。
extension MatchListViewController {

    // MARK: - 綁定

    func bind() {
        // 列表順序只在載入時變動，因此 snapshot 也只在這時 apply 一次。
        viewModel.$orderedMatchIDs
            .removeDuplicates()
            .sink { [weak self] matchIDs in
                self?.applySnapshot(matchIDs: matchIDs)
            }
            .store(in: &cancellables)

        viewModel.$loadState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.render(state)
            }
            .store(in: &cancellables)

        // 連線狀態與對帳結果一起決定狀態列文字。
        // 兩者分開訂閱的話，後到的那個會把另一個的訊息蓋掉。
        Publishers.CombineLatest(viewModel.$connectionState, viewModel.$resyncFailed)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] state, resyncFailed in
                self?.renderConnection(state, resyncFailed: resyncFailed)
            }
            .store(in: &cancellables)

        viewModel.$isShowingStaleData
            .removeDuplicates()
            .sink { [weak self] isStale in
                self?.staleBanner.isHidden = !isStale
            }
            .store(in: &cancellables)
    }

    func applySnapshot(matchIDs: [Int]) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Int>()
        snapshot.appendSections([.main])
        snapshot.appendItems(matchIDs, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func render(_ state: MatchListViewModel.LoadState) {
        switch state {
        case .idle, .loading:
            loadingIndicator.startAnimating()
            statusLabel.text = "載入中…"
        case .loaded:
            loadingIndicator.stopAnimating()
        case .failed(let message):
            loadingIndicator.stopAnimating()
            statusLabel.text = "載入失敗：\(message)"
        }
    }

    func renderConnection(_ state: OddsConnectionState, resyncFailed: Bool) {
        guard case .loaded = viewModel.loadState else { return }

        let connectionText: String
        switch state {
        case .idle:
            connectionText = "已中斷"
        case .connecting:
            connectionText = "連線中…"
        case .connected:
            connectionText = "● 即時更新中"
        case .reconnecting(let attempt):
            connectionText = "連線中斷，重試中（第 \(attempt) 次）"
        case .failed:
            connectionText = "無法連線"
        }

        // 對帳失敗必須可見。
        //
        // 它代表「重連成功了，但斷線期間遺失的推播沒補回來」——
        // 部分場次會停在舊值且不會自我修正，而畫面其他地方看起來一切正常。
        // 這個狀態若不顯示，使用者沒有任何線索可以察覺（spec §FR-6.4）。
        statusLabel.text = resyncFailed
            ? connectionText + "・資料校正失敗"
            : connectionText
        statusLabel.textColor = resyncFailed ? .systemOrange : .secondaryLabel
    }
}
