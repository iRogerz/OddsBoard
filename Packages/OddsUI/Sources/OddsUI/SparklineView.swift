import UIKit

/// 極簡的折線走勢圖。
///
/// 自己畫而不引入圖表套件：需求只有「一條線」，為此背上一個第三方相依
/// 並不划算，而且題目限制的判準是「不取代被指定的技術」——
/// 能自己畫的東西就沒有理由外包。
final class SparklineView: UIView {

    var values: [Double] = [] {
        didSet {
            guard values != oldValue else { return }
            setNeedsDisplay()
        }
    }

    var lineColor: UIColor = .systemBlue {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("本專案不使用 Storyboard/XIB")
    }

    override func draw(_ rect: CGRect) {
        guard values.count > 1 else { return }

        guard let minimum = values.min(), let maximum = values.max() else { return }
        // 所有值相同時 range 為 0，直接畫在中線，避免除以零。
        let range = maximum - minimum
        let insetRect = rect.insetBy(dx: 2, dy: 6)

        let path = UIBezierPath()
        for (index, value) in values.enumerated() {
            let ratio = range > 0 ? (value - minimum) / range : 0.5
            let point = CGPoint(
                x: insetRect.minX + insetRect.width * CGFloat(index) / CGFloat(values.count - 1),
                // y 軸翻轉：賠率高的畫在上面。
                y: insetRect.maxY - insetRect.height * CGFloat(ratio)
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        lineColor.setStroke()
        path.stroke()
    }
}
