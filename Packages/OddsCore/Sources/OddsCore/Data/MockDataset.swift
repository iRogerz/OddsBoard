import Foundation

/// 一整份模擬資料：比賽清單與其初始賠率。
///
/// 獨立成值型別的理由：`MockAPIClient` 與 `MockOddsSocket` 必須共用**同一份**
/// 初始賠率 —— 推播是在現值上做小幅漂移，若推播來源看到的起始值和 API 回傳的
/// 不同，畫面一收到第一筆推播就會整排跳動。
/// 由 Composition Root 建立一次、注入兩者，這個一致性就變成結構上的保證。
public struct MockDataset: Sendable {

    public let matches: [Match]
    public let odds: [Odds]

    public init(matches: [Match], odds: [Odds]) {
        self.matches = matches
        self.odds = odds
    }

    public struct Configuration: Sendable {

        public var seed: UInt64
        public var matchCount: Int
        /// 刻意讓這麼多場比賽共用同一個開賽時間，用來確保排序穩定性
        /// （`docs/spec.md` §4 FR-3.2）真的有被行使到。
        public var duplicateStartTimeCount: Int

        public init(
            seed: UInt64 = 20_250_704,
            matchCount: Int = 100,
            duplicateStartTimeCount: Int = 5
        ) {
            self.seed = seed
            self.matchCount = matchCount
            self.duplicateStartTimeCount = duplicateStartTimeCount
        }
    }

    /// 以固定種子產生資料集。同一個種子永遠得到同一份資料 —— 測試才寫得下
    /// 斷言，demo 影片也能重錄到滿意為止。
    public static func make(
        configuration: Configuration = Configuration(),
        referenceDate: Date = Date()
    ) -> MockDataset {

        var generator = SeededGenerator(seed: configuration.seed)
        var matches: [Match] = []
        var odds: [Odds] = []
        matches.reserveCapacity(configuration.matchCount)
        odds.reserveCapacity(configuration.matchCount)

        // 開賽時間以「App 啟動時間」為基準往後散佈，而非寫死日期。
        // 否則交件當天一打開，100 場比賽全部都是過去式。
        let sharedStartTime = referenceDate.addingTimeInterval(6 * 3600)

        for index in 0..<configuration.matchCount {
            let matchID = 1001 + index

            let startTime: Date
            if index < configuration.duplicateStartTimeCount {
                startTime = sharedStartTime
            } else {
                // 對齊到 5 分鐘，看起來像真的賽程表而不是隨機時間戳。
                let offset = Int.random(in: 0...(48 * 12), using: &generator) * 300
                startTime = referenceDate.addingTimeInterval(TimeInterval(offset))
            }

            let (teamA, teamB) = makeTeamPair(using: &generator)
            matches.append(Match(id: matchID, teamA: teamA, teamB: teamB, startTime: startTime))

            odds.append(
                Odds(
                    matchID: matchID,
                    teamAOdds: makeOddsValue(using: &generator),
                    teamBOdds: makeOddsValue(using: &generator)
                )
            )
        }

        return MockDataset(matches: matches, odds: odds)
    }

    // MARK: - Private

    private static func makeTeamPair(
        using generator: inout SeededGenerator
    ) -> (String, String) {
        let first = Int.random(in: 0..<teamNames.count, using: &generator)
        var second = Int.random(in: 0..<teamNames.count, using: &generator)
        if second == first {
            second = (first + 1) % teamNames.count
        }
        return (teamNames[first], teamNames[second])
    }

    private static func makeOddsValue(using generator: inout SeededGenerator) -> Double {
        // 賠率以 0.01 為單位，範圍取常見的 1.20 ~ 5.00。
        Double(Int.random(in: 120...500, using: &generator)) / 100
    }

    private static let teamNames = [
        "Eagles", "Tigers", "Lions", "Sharks", "Wolves", "Bears", "Falcons", "Panthers",
        "Dragons", "Ravens", "Cobras", "Hawks", "Bulls", "Stallions", "Rhinos", "Jaguars",
        "Vipers", "Titans", "Giants", "Warriors", "Knights", "Pirates", "Rangers", "Bandits",
        "Comets", "Rockets", "Thunder", "Lightning", "Blizzard", "Cyclones", "Meteors", "Phoenix"
    ]
}
