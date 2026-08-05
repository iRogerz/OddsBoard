import Foundation

/// 模擬的 REST API。取代題目的 `GET /matches` 與 `GET /odds`。
///
/// 設計成 actor 的理由：失敗注入需要一個呼叫次數計數器，那是可變狀態；
/// 與其用鎖保護，不如讓型別本身就是隔離的（與 `OddsStore` 同一套原則）。
public actor MockAPIClient: MatchAPI {

    /// 失敗注入模式。
    ///
    /// 題目寫的是「失敗率」，這裡改成確定性的模式：機率式失敗在測試裡
    /// 會產生偶發性的紅燈，而偶發紅燈最後一定會被人忽略。
    /// 確定性的行為讓錯誤路徑真的被測到，也讓 demo 可以穩定重現。
    public enum FailureMode: Sendable, Equatable {
        case never
        case always
        /// 前 n 次呼叫失敗，之後成功 —— 用來 demo「重試後恢復」。
        case firstCalls(Int)
    }

    public struct Configuration: Sendable {

        public var seed: UInt64
        public var matchCount: Int
        /// 刻意讓這麼多場比賽共用同一個開賽時間，用來確保排序穩定性
        /// （`docs/spec.md` §4 FR-3.2）真的有被行使到。
        public var duplicateStartTimeCount: Int
        public var latencyRange: ClosedRange<Int>
        public var failureMode: FailureMode

        public init(
            seed: UInt64 = 20_250_704,
            matchCount: Int = 100,
            duplicateStartTimeCount: Int = 5,
            latencyRange: ClosedRange<Int> = 200...600,
            failureMode: FailureMode = .never
        ) {
            self.seed = seed
            self.matchCount = matchCount
            self.duplicateStartTimeCount = duplicateStartTimeCount
            self.latencyRange = latencyRange
            self.failureMode = failureMode
        }
    }

    private let configuration: Configuration
    private let clock: AppClock
    private let matches: [Match]
    private let initialOdds: [Odds]
    private var callCount = 0

    public init(
        configuration: Configuration = Configuration(),
        clock: AppClock = SystemClock(),
        referenceDate: Date = Date()
    ) {
        self.configuration = configuration
        self.clock = clock

        var generator = SeededGenerator(seed: configuration.seed)
        let dataset = Self.makeDataset(
            configuration: configuration,
            referenceDate: referenceDate,
            generator: &generator
        )
        self.matches = dataset.matches
        self.initialOdds = dataset.odds
    }

    // MARK: - MatchAPI

    public func fetchMatches() async throws -> [Match] {
        try await simulateRequest()
        return matches
    }

    public func fetchOdds() async throws -> [Odds] {
        try await simulateRequest()
        return initialOdds
    }

    // MARK: - Private

    private func simulateRequest() async throws {
        callCount += 1

        var generator = SeededGenerator(seed: configuration.seed &+ UInt64(callCount))
        let milliseconds = Int.random(in: configuration.latencyRange, using: &generator)
        try await clock.sleep(for: .milliseconds(milliseconds))

        switch configuration.failureMode {
        case .never:
            return
        case .always:
            throw MatchAPIError.simulatedNetworkFailure
        case .firstCalls(let count):
            if callCount <= count {
                throw MatchAPIError.simulatedNetworkFailure
            }
        }
    }

    private static func makeDataset(
        configuration: Configuration,
        referenceDate: Date,
        generator: inout SeededGenerator
    ) -> (matches: [Match], odds: [Odds]) {

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

            let (teamA, teamB) = Self.makeTeamPair(using: &generator)
            matches.append(
                Match(id: matchID, teamA: teamA, teamB: teamB, startTime: startTime)
            )

            odds.append(
                Odds(
                    matchID: matchID,
                    teamAOdds: Self.makeOddsValue(using: &generator),
                    teamBOdds: Self.makeOddsValue(using: &generator)
                )
            )
        }

        return (matches, odds)
    }

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
