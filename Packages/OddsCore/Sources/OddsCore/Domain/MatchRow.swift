import Foundation

/// 畫面實際消費的合併模型：一場比賽 + 它當下的賠率 + 最近一次的變動方向。
public struct MatchRow: Hashable, Sendable, Identifiable {

    public var id: Int { match.id }

    public let match: Match

    /// 可能為 nil：`GET /odds` 尚未回來，或該場暫無盤口。
    /// 題目沒有描述這個狀態，但只要兩支 API 分開請求，就必然存在
    /// 「比賽已載入、賠率還沒到」的中間態，cell 必須能表現它。
    public let odds: Odds?

    public let change: OddsChange

    public init(match: Match, odds: Odds?, change: OddsChange = .unchanged) {
        self.match = match
        self.odds = odds
        self.change = change
    }
}

// MARK: - 排序

public enum MatchSorting {

    /// 依開賽時間升序（最早的在最上面）。
    ///
    /// 題目只寫了「依比賽時間升序」，但當多場比賽開賽時間相同時次序未定義，
    /// 不同次載入可能得到不同順序，畫面會無故跳動。
    /// 因此排序鍵採 `(startTime, matchID)` 複合鍵 —— matchID 全域唯一，
    /// 保證排序結果具**確定性**（見 `docs/spec.md` §4 FR-3.2）。
    public static func isOrderedBefore(_ lhs: Match, _ rhs: Match) -> Bool {
        if lhs.startTime != rhs.startTime {
            return lhs.startTime < rhs.startTime
        }
        return lhs.id < rhs.id
    }

    public static func sorted(_ matches: [Match]) -> [Match] {
        matches.sorted(by: isOrderedBefore)
    }
}
