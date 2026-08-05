import Combine
import OddsCore
import OddsPresentation
import SnapKit
import UIKit

/// 單場比賽的詳情頁。
///
/// 存在的理由見 `MatchDetailViewModel` —— 它是加分題「切換畫面後能快速恢復
/// 顯示」的驗證載體。從列表 push 進來、再 pop 回去時，列表的 ViewModel
/// 由導覽控制器持有而不會被重建，因此返回時沒有任何載入過程。
public final class MatchDetailViewController: UIViewController {

    private let viewModel: MatchDetailViewModel
    private var cancellables: Set<AnyCancellable> = []

    private let teamsLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .title2)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }()

    private let startTimeLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        return label
    }()

    private let teamAOddsLabel = MatchDetailViewController.makeOddsLabel()
    private let teamBOddsLabel = MatchDetailViewController.makeOddsLabel()

    private let sparkline = SparklineView()

    private let sparklineCaption: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.text = "近期賠率走勢（teamA）"
        return label
    }()

    public init(viewModel: MatchDetailViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("本專案不使用 Storyboard/XIB")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        title = "比賽詳情"
        view.backgroundColor = .systemBackground

        setUpLayout()
        bind()

        teamsLabel.text = "\(viewModel.match.teamA)  vs  \(viewModel.match.teamB)"
        startTimeLabel.text = Self.timeFormatter.string(from: viewModel.match.startTime)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.startObserving()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        viewModel.stopObserving()
    }

    // MARK: - 綁定

    private func bind() {
        viewModel.$currentOdds
            .sink { [weak self] odds in
                self?.teamAOddsLabel.text = Self.format(odds?.teamAOdds)
                self?.teamBOddsLabel.text = Self.format(odds?.teamBOdds)
            }
            .store(in: &cancellables)

        viewModel.$history
            .sink { [weak self] history in
                self?.sparkline.values = history.map(\.teamAOdds)
            }
            .store(in: &cancellables)
    }

    // MARK: - 版面

    private func setUpLayout() {
        let oddsStack = UIStackView(arrangedSubviews: [
            makeOddsColumn(title: viewModel.match.teamA, valueLabel: teamAOddsLabel),
            makeOddsColumn(title: viewModel.match.teamB, valueLabel: teamBOddsLabel)
        ])
        oddsStack.axis = .horizontal
        oddsStack.distribution = .fillEqually
        oddsStack.spacing = 16

        let stack = UIStackView(arrangedSubviews: [
            teamsLabel,
            startTimeLabel,
            oddsStack,
            sparklineCaption,
            sparkline
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(24, after: startTimeLabel)
        stack.setCustomSpacing(24, after: oddsStack)

        view.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(24)
            make.leading.trailing.equalTo(view.layoutMarginsGuide)
        }
        sparkline.snp.makeConstraints { make in
            make.height.equalTo(120)
        }
    }

    private func makeOddsColumn(title: String, valueLabel: UILabel) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }

    private static func makeOddsLabel() -> UILabel {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 34, weight: .bold)
        label.textAlignment = .center
        label.text = "—"
        return label
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()
}
