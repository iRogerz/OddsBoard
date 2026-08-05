import OddsCore
import SnapKit
import UIKit

/// 單一場比賽的列。
///
/// 效能相關的兩個刻意設計：
/// 1. 賠率使用**等寬數字**字型。比例字型下 `1.95 → 1.92` 會造成標籤寬度改變，
///    進而觸發 Auto Layout 重算；等寬數字直接消除這個成本。
/// 2. 漲跌閃爍改變的是背景色而非佈局，不會造成任何 re-layout。
final class MatchCell: UITableViewCell {

    static let reuseIdentifier = "MatchCell"

    /// 漲跌閃爍的 layer 動畫 key。取出它即可在測試中斷言動畫的起訖顏色。
    static let flashAnimationKey = "oddsFlash"

    /// 閃爍時間與濃度。
    ///
    /// 這個提示的目的是讓「只有變動的那一格在動、整頁沒有重繪」肉眼可驗證，
    /// 所以刻意調到看得清楚 —— 太含蓄就失去意義。但仍短到不會在高頻更新下
    /// 讓整個畫面看起來在閃。
    private static let flashDuration: CFTimeInterval = 0.6
    private static let flashAlpha: CGFloat = 0.45

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    private let teamsLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        return label
    }()

    private let teamAOddsLabel = MatchCell.makeOddsLabel()
    private let teamBOddsLabel = MatchCell.makeOddsLabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setUpLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("本專案不使用 Storyboard/XIB")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // cell 被重用時必須清掉閃爍殘留，否則滾動時會看到不屬於這場比賽的顏色。
        for label in [teamAOddsLabel, teamBOddsLabel] {
            label.layer.removeAnimation(forKey: Self.flashAnimationKey)
            label.backgroundColor = .clear
        }
    }

    // MARK: - 設定內容

    func configure(with row: MatchRow) {
        teamsLabel.text = "\(row.match.teamA)  vs  \(row.match.teamB)"
        timeLabel.text = Self.timeFormatter.string(from: row.match.startTime)

        teamAOddsLabel.text = Self.format(row.odds?.teamAOdds)
        teamBOddsLabel.text = Self.format(row.odds?.teamBOdds)

        // 賠率尚未載入時以佔位符表現，而不是顯示 0.00 這種會被誤讀為真實賠率的值。
        let hasOdds = row.odds != nil
        teamAOddsLabel.textColor = hasOdds ? .label : .tertiaryLabel
        teamBOddsLabel.textColor = hasOdds ? .label : .tertiaryLabel
    }

    /// 播放漲跌提示。
    ///
    /// 這個效果不只是美觀 —— 它讓「只有變動的那一格在動、整頁沒有重繪」
    /// 這件事**肉眼可驗證**，錄影時證據直接在畫面上（`docs/spec.md` §4 FR-3.3）。
    func playChangeAnimation(_ change: OddsChange) {
        flash(teamAOddsLabel, direction: change.teamA)
        flash(teamBOddsLabel, direction: change.teamB)
    }

    /// 測試用：讓斷言能取出 layer 上的閃爍動畫，檢查它的起訖顏色。
    var oddsLabelsForTesting: [UILabel] {
        [teamAOddsLabel, teamBOddsLabel]
    }

    // MARK: - Private

    private func flash(_ label: UILabel, direction: OddsChange.Direction) {
        let color: UIColor
        switch direction {
        case .up:
            color = UIColor.systemGreen.withAlphaComponent(Self.flashAlpha)
        case .down:
            color = UIColor.systemRed.withAlphaComponent(Self.flashAlpha)
        case .unchanged:
            return
        }

        // 用明確指定 fromValue / toValue 的 CABasicAnimation，而不是
        // `label.backgroundColor = color` 後再用 `UIView.animate` 淡回 clear。
        //
        // 後者實測完全看不見：設定背景色只寫進 model layer，該 runloop 尚未
        // commit，UIKit 建立動畫時取到的起始值仍是上一幀的 `.clear`，
        // 於是動畫變成 clear → clear。最難察覺的是動畫「確實」被加到 layer 上、
        // `animationKeys()` 有值、沒有任何警告，只是視覺上什麼都沒發生。
        //
        // 明確給定兩端就沒有任何推斷空間。model 值全程保持 `.clear`，
        // 動畫結束後也不會留下殘色。
        label.layer.removeAnimation(forKey: Self.flashAnimationKey)
        label.backgroundColor = .clear

        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = color.cgColor
        animation.toValue = UIColor.clear.cgColor
        animation.duration = Self.flashDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        label.layer.add(animation, forKey: Self.flashAnimationKey)
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }

    private static func makeOddsLabel() -> UILabel {
        let label = UILabel()
        // 等寬數字：賠率變動時字寬不變，不觸發 Auto Layout 重算。
        label.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .right
        label.layer.cornerRadius = 4
        label.layer.masksToBounds = true
        return label
    }

    private func setUpLayout() {
        selectionStyle = .none

        let textStack = UIStackView(arrangedSubviews: [teamsLabel, timeLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let oddsStack = UIStackView(arrangedSubviews: [teamAOddsLabel, teamBOddsLabel])
        oddsStack.axis = .horizontal
        oddsStack.spacing = 12
        oddsStack.distribution = .fillEqually

        contentView.addSubview(textStack)
        contentView.addSubview(oddsStack)

        textStack.snp.makeConstraints { make in
            make.leading.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalTo(contentView.layoutMarginsGuide)
        }

        oddsStack.snp.makeConstraints { make in
            make.leading.greaterThanOrEqualTo(textStack.snp.trailing).offset(12)
            make.trailing.equalTo(contentView.layoutMarginsGuide)
            make.centerY.equalTo(contentView)
            make.width.equalTo(132)
        }

        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        oddsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
}
