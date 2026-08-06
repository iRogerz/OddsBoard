import XCTest
@testable import OddsCore

final class MockAPIClientTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_720_099_200)

    private func makeClient(
        failureMode: MockAPIClient.FailureMode = .never,
        seed: UInt64 = 20_250_704
    ) -> (MockAPIClient, ImmediateClock) {
        let clock = ImmediateClock()
        var configuration = MockAPIClient.Configuration()
        configuration.failureMode = failureMode
        let client = MockAPIClient(
            configuration: configuration,
            datasetConfiguration: MockDataset.Configuration(seed: seed),
            clock: clock,
            referenceDate: referenceDate
        )
        return (client, clock)
    }

    // MARK: - 資料來源（spec §4 FR-1）

    func test_回傳一百筆比賽() async throws {
        let (client, _) = makeClient()

        let matches = try await client.fetchMatches()

        XCTAssertEqual(matches.count, 100)
    }

    func test_賠率筆數與比賽筆數一致() async throws {
        let (client, _) = makeClient()

        let matches = try await client.fetchMatches()
        let odds = try await client.fetchOdds()

        XCTAssertEqual(odds.count, matches.count)
        XCTAssertEqual(Set(odds.map(\.matchID)), Set(matches.map(\.id)))
    }

    func test_matchID唯一() async throws {
        let (client, _) = makeClient()

        let matches = try await client.fetchMatches()

        XCTAssertEqual(Set(matches.map(\.id)).count, matches.count)
    }

    func test_同一場比賽的兩隊不相同() async throws {
        let (client, _) = makeClient()

        let matches = try await client.fetchMatches()

        for match in matches {
            XCTAssertNotEqual(match.teamA, match.teamB, "matchID \(match.id) 出現同隊對戰")
        }
    }

    func test_開賽時間皆不早於基準時間() async throws {
        let (client, _) = makeClient()

        let matches = try await client.fetchMatches()

        for match in matches {
            XCTAssertGreaterThanOrEqual(
                match.startTime,
                referenceDate,
                "開賽時間以 App 啟動時間為基準，不該產生已經過去的比賽"
            )
        }
    }

    /// 資料集刻意包含開賽時間相同的比賽，確保排序穩定性真的有被行使到。
    func test_資料集包含開賽時間相同的比賽() async throws {
        let (client, _) = makeClient()

        let matches = try await client.fetchMatches()
        let grouped = Dictionary(grouping: matches, by: \.startTime)

        XCTAssertTrue(
            grouped.values.contains { $0.count > 1 },
            "資料集若沒有時間重複的比賽，排序穩定性的規則等於沒被測到"
        )
    }

    func test_賠率落在合理範圍() async throws {
        let (client, _) = makeClient()

        let odds = try await client.fetchOdds()

        for entry in odds {
            XCTAssertTrue((1.20...5.00).contains(entry.teamAOdds))
            XCTAssertTrue((1.20...5.00).contains(entry.teamBOdds))
        }
    }

    // MARK: - 可重現性

    func test_相同種子產生完全相同的資料() async throws {
        let (first, _) = makeClient(seed: 12345)
        let (second, _) = makeClient(seed: 12345)

        let firstMatches = try await first.fetchMatches()
        let secondMatches = try await second.fetchMatches()

        XCTAssertEqual(firstMatches, secondMatches, "固定種子是測試可重現與 demo 可重錄的前提")
    }

    func test_不同種子產生不同的資料() async throws {
        let (first, _) = makeClient(seed: 1)
        let (second, _) = makeClient(seed: 2)

        let firstMatches = try await first.fetchMatches()
        let secondMatches = try await second.fetchMatches()

        XCTAssertNotEqual(firstMatches, secondMatches)
    }

    /// 曾經的 bug：便利建構子以 `configuration.seed` 覆寫 `datasetConfiguration.seed`，
    /// 呼叫端明確指定的資料集種子被靜默丟棄。
    func test_資料集種子不會被延遲種子覆寫() async throws {
        let clock = ImmediateClock()
        let client = MockAPIClient(
            configuration: MockAPIClient.Configuration(seed: 111),
            datasetConfiguration: MockDataset.Configuration(seed: 999),
            clock: clock,
            referenceDate: referenceDate
        )
        let expected = MockDataset.make(
            configuration: MockDataset.Configuration(seed: 999),
            referenceDate: referenceDate
        )

        let matches = try await client.fetchMatches()

        XCTAssertEqual(matches, expected.matches, "呼叫端指定的資料集種子必須被採用")
    }

    // MARK: - 網路延遲模擬（spec §4 FR-1.3）

    func test_請求會模擬網路延遲() async throws {
        let (client, clock) = makeClient()

        _ = try await client.fetchMatches()

        let sleeps = await clock.recorder.durations
        XCTAssertEqual(sleeps.count, 1)

        let milliseconds = sleeps[0].components.attoseconds / 1_000_000_000_000_000
            + sleeps[0].components.seconds * 1000
        XCTAssertTrue(
            (200...600).contains(milliseconds),
            "延遲 \(milliseconds)ms 超出設定範圍"
        )
    }

    // MARK: - 失敗注入（spec §4 FR-1.4）

    func test_失敗模式always_必定拋出錯誤() async {
        let (client, _) = makeClient(failureMode: .always)

        do {
            _ = try await client.fetchMatches()
            XCTFail("應該拋出錯誤")
        } catch {
            XCTAssertEqual(error as? MatchAPIError, .simulatedNetworkFailure)
        }
    }

    func test_失敗模式firstCalls_前n次失敗後恢復() async throws {
        let (client, _) = makeClient(failureMode: .firstCalls(2))

        for attempt in 1...2 {
            do {
                _ = try await client.fetchMatches()
                XCTFail("第 \(attempt) 次呼叫應該失敗")
            } catch {
                XCTAssertEqual(error as? MatchAPIError, .simulatedNetworkFailure)
            }
        }

        let matches = try await client.fetchMatches()
        XCTAssertEqual(matches.count, 100, "第 3 次呼叫應該成功，用來 demo 重試後恢復")
    }

    func test_預設不失敗() async throws {
        let (client, _) = makeClient()

        let matches = try await client.fetchMatches()

        XCTAssertEqual(matches.count, 100)
    }

    // MARK: - 現值來源（重連對帳用）

    /// 真實伺服器回傳的是此刻的盤口。若 mock 永遠回傳開機時的初始值，
    /// 重連對帳就變成「重置到開機值」—— demo 時看起來是無來由的大跳動。
    func test_有現值來源時fetchOdds回傳現值而非初始資料() async throws {
        let live = [
            Odds(matchID: 1001, teamAOdds: 7.77, teamBOdds: 8.88)
        ]
        let client = MockAPIClient(
            dataset: MockDataset.make(referenceDate: referenceDate),
            configuration: MockAPIClient.Configuration(),
            clock: ImmediateClock(),
            liveOdds: { live }
        )

        let odds = try await client.fetchOdds()

        XCTAssertEqual(odds, live)
    }

    func test_現值來源為空時退回初始資料() async throws {
        let dataset = MockDataset.make(referenceDate: referenceDate)
        let client = MockAPIClient(
            dataset: dataset,
            configuration: MockAPIClient.Configuration(),
            clock: ImmediateClock(),
            liveOdds: { [] }
        )

        let odds = try await client.fetchOdds()

        XCTAssertEqual(odds, dataset.odds)
    }

    // MARK: - 執行期切換失敗模式

    /// 失敗模式必須能在建構之後切換，否則 `.failed` 那條 UI 分支
    /// 在 App 裡是永遠走不到的死碼 —— 只有測試碰得到它（spec §FR-1.4）。
    func test_可在執行期切換成失敗() async {
        let client = MockAPIClient(
            dataset: MockDataset.make(referenceDate: referenceDate),
            configuration: MockAPIClient.Configuration(),
            clock: ImmediateClock()
        )

        await client.setFailureMode(.always)

        do {
            _ = try await client.fetchMatches()
            XCTFail("切換成 .always 之後必須失敗")
        } catch {
            XCTAssertEqual(error as? MatchAPIError, .simulatedNetworkFailure)
        }
    }

    func test_可從失敗切換回正常() async throws {
        let client = MockAPIClient(
            dataset: MockDataset.make(referenceDate: referenceDate),
            configuration: MockAPIClient.Configuration(failureMode: .always),
            clock: ImmediateClock()
        )

        await client.setFailureMode(.never)
        let matches = try await client.fetchMatches()

        XCTAssertEqual(matches.count, 100)
    }
}
