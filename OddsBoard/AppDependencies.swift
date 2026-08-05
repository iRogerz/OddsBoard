//
//  AppDependencies.swift
//  OddsBoard
//

import UIKit

/// Composition Root — 全 App 唯一組裝具體實作的地方。
///
/// 各層之間只透過 protocol 相依（見 `docs/spec.md` §5），
/// 具體型別（MockAPIClient、OddsStore、Cache…）僅在此處被 new 出來並注入。
/// 這讓測試可以替換任一層，也讓「依賴方向永遠向下」這件事有單一稽核點。
@MainActor
final class AppDependencies {

    static let shared = AppDependencies()

    private init() {}

    // MARK: - Presentation

    /// 建立 App 的 root view controller。
    ///
    /// - Note: 目前回傳開機驗證用的佔位畫面。
    ///   依 `docs/spec.md` §11 的時程，D3 會替換為 `MatchListViewController`
    ///   （由 `OddsUI` 模組提供，並注入 `OddsCore` 組裝出的 ViewModel）。
    func makeRootViewController() -> UIViewController {
        UINavigationController(rootViewController: BootstrapViewController())
    }
}
