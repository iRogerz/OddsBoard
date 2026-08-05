import XCTest
import OddsCore
@testable import OddsUI

/// `MatchCell` 的行為測試。
///
/// 這些測試住在 App 的原生 test target 而非 SPM package，因為它們需要
/// 真實的 UIKit 執行環境（layer 動畫、cell 重用），而 `OddsUI` 是 iOS-only。
@MainActor
final class MatchCellTests: XCTestCase {

    private func makeCell() -> MatchCell {
        let cell = MatchCell(style: .default, reuseIdentifier: MatchCell.reuseIdentifier)
        cell.frame = CGRect(x: 0, y: 0, width: 390, height: 64)
        cell.layoutIfNeeded()
        return cell
    }

    private func makeRow(
        teamAOdds: Double? = 1.95,
        change: OddsChange = .unchanged
    ) -> MatchRow {
        let match = Match(
            id: 1001,
            teamA: "Eagles",
            teamB: "Tigers",
            startTime: Date(timeIntervalSince1970: 1_720_099_200)
        )
        let odds = teamAOdds.map {
            Odds(matchID: 1001, teamAOdds: $0, teamBOdds: 2.10)
        }
        return MatchRow(match: match, odds: odds, change: change)
    }

    private func flashAnimation(on label: UILabel) -> CABasicAnimation? {
        label.layer.animation(forKey: MatchCell.flashAnimationKey) as? CABasicAnimation
    }

    private func alpha(of value: Any?) -> CGFloat? {
        guard let color = value, CFGetTypeID(color as CFTypeRef) == CGColor.typeID else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return (color as! CGColor).alpha
    }

    // MARK: - 漲跌動畫（D3 回歸測試）

    /// **這支測試守的是一個真實發生過、而且極難察覺的 bug。**
    ///
    /// 原本的寫法是 `label.backgroundColor = color` 之後用 `UIView.animate`
    /// 淡回 `.clear`。但設定背景色只寫進 model layer、該 runloop 尚未 commit，
    /// UIKit 建立動畫時取到的起始值仍是上一幀的 `.clear` —— 動畫變成
    /// clear → clear，畫面完全不閃。
    ///
    /// 最惡劣的是它「看起來是對的」：動畫確實被加到 layer 上、`animationKeys()`
    /// 有值、沒有任何警告。唯一能抓到它的斷言就是**檢查起始顏色不是透明的**。
    func test_閃爍動畫的起始顏色必須是不透明的() {
        let cell = makeCell()

        cell.playChangeAnimation(OddsChange(teamA: .up, teamB: .down))

        for label in cell.oddsLabelsForTesting {
            guard let animation = flashAnimation(on: label) else {
                XCTFail("layer 上必須有閃爍動畫")
                return
            }
            guard let fromAlpha = alpha(of: animation.fromValue) else {
                XCTFail("fromValue 必須是 CGColor")
                return
            }
            XCTAssertGreaterThan(
                fromAlpha,
                0,
                "起始顏色若是透明的，動畫就是 clear → clear，使用者一幀都看不到"
            )
        }
    }

    func test_閃爍動畫的結束顏色是透明的() {
        let cell = makeCell()

        cell.playChangeAnimation(OddsChange(teamA: .up, teamB: .down))

        for label in cell.oddsLabelsForTesting {
            guard
                let animation = flashAnimation(on: label),
                let toAlpha = alpha(of: animation.toValue)
            else {
                XCTFail("動畫必須有 CGColor 型別的 toValue")
                return
            }
            XCTAssertEqual(toAlpha, 0, accuracy: 0.001, "閃爍必須淡出，不能留下殘色")
        }
    }

    func test_動畫結束後不留下殘色() {
        let cell = makeCell()

        cell.playChangeAnimation(OddsChange(teamA: .up, teamB: .down))

        for label in cell.oddsLabelsForTesting {
            XCTAssertEqual(
                label.backgroundColor,
                .clear,
                "model 值必須全程保持透明，否則動畫播完會卡住一格有色的 cell"
            )
        }
    }

    func test_上漲與下跌使用不同顏色() {
        let upCell = makeCell()
        let downCell = makeCell()

        upCell.playChangeAnimation(OddsChange(teamA: .up, teamB: .unchanged))
        downCell.playChangeAnimation(OddsChange(teamA: .down, teamB: .unchanged))

        let upFrom = flashAnimation(on: upCell.oddsLabelsForTesting[0])?.fromValue
        let downFrom = flashAnimation(on: downCell.oddsLabelsForTesting[0])?.fromValue

        XCTAssertNotNil(upFrom)
        XCTAssertNotNil(downFrom)
        XCTAssertFalse(
            String(describing: upFrom) == String(describing: downFrom),
            "漲跌若同色，這個提示就失去意義"
        )
    }

    func test_無變動時不播放動畫() {
        let cell = makeCell()

        cell.playChangeAnimation(.unchanged)

        for label in cell.oddsLabelsForTesting {
            XCTAssertNil(
                flashAnimation(on: label),
                "沒有變動卻閃爍，會讓使用者無法分辨哪一格真的動了"
            )
        }
    }

    func test_只有變動的那一邊會閃爍() {
        let cell = makeCell()

        cell.playChangeAnimation(OddsChange(teamA: .up, teamB: .unchanged))

        XCTAssertNotNil(flashAnimation(on: cell.oddsLabelsForTesting[0]), "teamA 上漲應該閃")
        XCTAssertNil(flashAnimation(on: cell.oddsLabelsForTesting[1]), "teamB 未變動不該閃")
    }

    // MARK: - 重用

    func test_重用時清掉閃爍殘留() {
        let cell = makeCell()
        cell.playChangeAnimation(OddsChange(teamA: .up, teamB: .down))

        cell.prepareForReuse()

        for label in cell.oddsLabelsForTesting {
            XCTAssertNil(
                flashAnimation(on: label),
                "殘留的動畫會讓滾動時出現不屬於這場比賽的顏色"
            )
            XCTAssertEqual(label.backgroundColor, .clear)
        }
    }

    // MARK: - 內容

    func test_賠率顯示至小數點後兩位() {
        let cell = makeCell()

        cell.configure(with: makeRow(teamAOdds: 1.9))

        XCTAssertEqual(cell.oddsLabelsForTesting[0].text, "1.90")
    }

    func test_賠率尚未載入時顯示佔位符() {
        let cell = makeCell()

        cell.configure(with: makeRow(teamAOdds: nil))

        XCTAssertEqual(
            cell.oddsLabelsForTesting[0].text,
            "—",
            "顯示 0.00 會被誤讀為真實賠率"
        )
    }

    func test_賠率使用等寬數字字型() {
        let cell = makeCell()

        cell.configure(with: makeRow(teamAOdds: 1.95))
        let widthOfNarrowDigits = cell.oddsLabelsForTesting[0].intrinsicContentSize.width

        cell.configure(with: makeRow(teamAOdds: 8.88))
        let widthOfWideDigits = cell.oddsLabelsForTesting[0].intrinsicContentSize.width

        XCTAssertEqual(
            widthOfNarrowDigits,
            widthOfWideDigits,
            accuracy: 0.5,
            "非等寬字型下賠率變動會改變字寬，進而觸發 Auto Layout 重算"
        )
    }
}
