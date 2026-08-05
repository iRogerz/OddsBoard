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
        public var latencyRange: ClosedRange<Int>
        public var failureMode: FailureMode

        public init(
            seed: UInt64 = 20_250_704,
            latencyRange: ClosedRange<Int> = 200...600,
            failureMode: FailureMode = .never
        ) {
            self.seed = seed
            self.latencyRange = latencyRange
            self.failureMode = failureMode
        }
    }

    private let configuration: Configuration
    private let clock: AppClock
    private let dataset: MockDataset
    private var callCount = 0

    /// 注入既有資料集。Composition Root 應走這個入口，讓 API 與推播來源
    /// 共用同一份初始賠率（見 `MockDataset`）。
    public init(
        dataset: MockDataset,
        configuration: Configuration = Configuration(),
        clock: AppClock = SystemClock()
    ) {
        self.dataset = dataset
        self.configuration = configuration
        self.clock = clock
    }

    /// 自行產生資料集的便利建構子，供測試使用。
    public init(
        configuration: Configuration = Configuration(),
        datasetConfiguration: MockDataset.Configuration = MockDataset.Configuration(),
        clock: AppClock = SystemClock(),
        referenceDate: Date = Date()
    ) {
        var datasetConfiguration = datasetConfiguration
        datasetConfiguration.seed = configuration.seed
        self.init(
            dataset: MockDataset.make(
                configuration: datasetConfiguration,
                referenceDate: referenceDate
            ),
            configuration: configuration,
            clock: clock
        )
    }

    // MARK: - MatchAPI

    public func fetchMatches() async throws -> [Match] {
        try await simulateRequest()
        return dataset.matches
    }

    public func fetchOdds() async throws -> [Odds] {
        try await simulateRequest()
        return dataset.odds
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
}
