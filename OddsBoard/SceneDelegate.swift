//
//  SceneDelegate.swift
//  OddsBoard
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    /// 手動建立 UIWindow 與 root view controller。
    ///
    /// 本專案不使用 Storyboard：畫面階層完全由程式碼組裝，
    /// 依賴由 `AppDependencies`（Composition Root）注入，
    /// 讓 ViewController 的相依關係在型別上是明確且可替換的。
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = AppDependencies.shared.makeRootViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
