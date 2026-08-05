//
//  BootstrapViewController.swift
//  OddsBoard
//

import UIKit

/// 開機驗證用的暫時畫面，唯一目的是證明「無 Storyboard 的手動啟動路徑」是通的。
///
/// 依 `docs/spec.md` §11，D3 會被 `MatchListViewController` 取代。
final class BootstrapViewController: UIViewController {

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "OddsBoard"
        label.font = .systemFont(ofSize: 34, weight: .bold)
        label.textAlignment = .center
        return label
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "手動 UIWindow 啟動成功\n無 Storyboard、無 SwiftUI"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        title = "Bootstrap"

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor)
        ])
    }
}
