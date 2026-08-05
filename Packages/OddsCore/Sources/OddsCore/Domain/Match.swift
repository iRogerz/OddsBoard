import Foundation

/// 一場比賽。對應 `GET /matches` 的單筆資料。
///
/// - Note: `id` 即題目的 `matchID`，是全 App 唯一的實體識別。
///   diffable data source 的 item identifier 只會用它 —— **絕不可**把賠率
///   包進識別，否則賠率一變就會被判定成「刪一列 + 插一列」，畫面會閃
///   （見 `docs/spec.md` §4 FR-3.3）。
public struct Match: Identifiable, Hashable, Sendable, Codable {

    public let id: Int
    public let teamA: String
    public let teamB: String
    public let startTime: Date

    public init(id: Int, teamA: String, teamB: String, startTime: Date) {
        self.id = id
        self.teamA = teamA
        self.teamB = teamB
        self.startTime = startTime
    }

    private enum CodingKeys: String, CodingKey {
        case id = "matchID"
        case teamA
        case teamB
        case startTime
    }
}
