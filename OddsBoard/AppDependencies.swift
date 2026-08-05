//
//  AppDependencies.swift
//  OddsBoard
//

import OddsCore
import OddsPresentation
import OddsUI
import UIKit

/// Composition Root — 全 App 唯一組裝具體實作的地方。
///
/// 各層之間只透過 protocol 相依（見 `docs/spec.md` §5），
/// 具體型別（MockAPIClient、MockOddsSocket、OddsStore…）僅在此處被建立並注入。
/// 這讓測試可以替換任一層，也讓「依賴方向永遠向下」有單一稽核點。
@MainActor
final class AppDependencies {

    static let shared = AppDependencies()

    /// 一次啟動內共用的物件。
    ///
    /// 特別注意 `store` 必須共用：列表與詳情頁看的是同一份賠率狀態，
    /// 各自持有一份就會出現「列表顯示 1.95、詳情頁顯示 1.92」這種
    /// 使用者一眼就會發現的不一致。
    private struct Session {
        let dataset: MockDataset
        let api: MockAPIClient
        let socket: MockOddsSocket
        let store: OddsStore
        let cache: FileSnapshotCache
    }

    private lazy var session: Session = {
        // 資料集建立一次，同時注入 API 與推播來源。
        // 兩者若各自產生資料，推播的起始賠率會與 API 回傳的不一致，
        // 畫面收到第一筆推播就會整排跳動。
        let dataset = MockDataset.make()
        return Session(
            dataset: dataset,
            api: MockAPIClient(dataset: dataset),
            socket: MockOddsSocket(initialOdds: dataset.odds),
            store: OddsStore(),
            cache: FileSnapshotCache.makeDefault()
        )
    }()

    private init() {}

    // MARK: - Presentation

    func makeRootViewController() -> UIViewController {
        let navigationController = UINavigationController()
        navigationController.navigationBar.prefersLargeTitles = false
        navigationController.setViewControllers(
            [makeMatchListViewController(navigationController: navigationController)],
            animated: false
        )
        return navigationController
    }

    // MARK: - Private

    private func makeMatchListViewController(
        navigationController: UINavigationController
    ) -> UIViewController {
        let viewModel = MatchListViewModel(
            api: session.api,
            store: session.store,
            socket: session.socket,
            cache: session.cache
        )

        let viewController = MatchListViewController(viewModel: viewModel)

        // 導覽由 Composition Root 負責，view controller 只回報「使用者選了誰」。
        // 這讓列表不需要知道詳情頁的存在，也不必持有 navigation controller。
        viewController.onSelectMatch = { [weak navigationController, weak self] matchID in
            guard
                let self,
                let detail = self.makeMatchDetailViewController(matchID: matchID)
            else {
                return
            }
            navigationController?.pushViewController(detail, animated: true)
        }

        return viewController
    }

    private func makeMatchDetailViewController(matchID: Int) -> UIViewController? {
        guard let match = session.dataset.matches.first(where: { $0.id == matchID }) else {
            return nil
        }

        let viewModel = MatchDetailViewModel(match: match, store: session.store)
        return MatchDetailViewController(viewModel: viewModel)
    }
}
