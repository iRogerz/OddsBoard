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

    private init() {}

    // MARK: - Presentation

    func makeRootViewController() -> UIViewController {
        let navigationController = UINavigationController(
            rootViewController: makeMatchListViewController()
        )
        navigationController.navigationBar.prefersLargeTitles = false
        return navigationController
    }

    // MARK: - Private

    private func makeMatchListViewController() -> UIViewController {
        // 資料集在此建立一次，同時注入 API 與推播來源。
        // 兩者若各自產生資料，推播的起始賠率會與 API 回傳的不一致，
        // 畫面收到第一筆推播就會整排跳動。
        let dataset = MockDataset.make()

        let api = MockAPIClient(dataset: dataset)
        let socket = MockOddsSocket(initialOdds: dataset.odds)
        let store = OddsStore()

        let viewModel = MatchListViewModel(
            api: api,
            store: store,
            socket: socket
        )

        return MatchListViewController(viewModel: viewModel)
    }
}
