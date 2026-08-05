import Foundation

/// 某一場比賽當下的賠率。對應 `GET /odds` 的單筆資料。
public struct Odds: Hashable, Sendable, Codable {

    public let matchID: Int
    public let teamAOdds: Double
    public let teamBOdds: Double

    public init(matchID: Int, teamAOdds: Double, teamBOdds: Double) {
        self.matchID = matchID
        self.teamAOdds = teamAOdds
        self.teamBOdds = teamBOdds
    }
}

/// 賠率相對於前一次的變動方向，供 cell 做漲跌閃爍提示。
///
/// 兩隊分開記錄：同一次推播裡 teamA 上漲、teamB 下跌是常態，
/// 用單一方向表示會漏掉其中一邊。
public struct OddsChange: Hashable, Sendable {

    public enum Direction: Hashable, Sendable {
        case up
        case down
        case unchanged
    }

    public static let unchanged = OddsChange(teamA: .unchanged, teamB: .unchanged)

    public let teamA: Direction
    public let teamB: Direction

    public init(teamA: Direction, teamB: Direction) {
        self.teamA = teamA
        self.teamB = teamB
    }

    /// 由前後兩筆賠率推導變動方向。`previous` 為 nil（首次載入）時視為無變動，
    /// 避免初次進畫面時整頁閃爍。
    public init(previous: Odds?, current: Odds) {
        guard let previous else {
            self = .unchanged
            return
        }
        self.teamA = Direction(from: previous.teamAOdds, to: current.teamAOdds)
        self.teamB = Direction(from: previous.teamBOdds, to: current.teamBOdds)
    }

    public var hasChange: Bool {
        teamA != .unchanged || teamB != .unchanged
    }
}

extension OddsChange.Direction {

    fileprivate init(from oldValue: Double, to newValue: Double) {
        // 賠率以 0.01 為最小跳動單位，用 0.001 當門檻可避開浮點誤差
        // 造成的假變動（例如 1.95 - 1.95 != 0 的情形）。
        let delta = newValue - oldValue
        if delta > 0.001 {
            self = .up
        } else if delta < -0.001 {
            self = .down
        } else {
            self = .unchanged
        }
    }
}
