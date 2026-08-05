import XCTest
@testable import OddsCore

final class OddsStoreTests: XCTestCase {

    // MARK: - 亂序防護（spec §3.3）

    func test_套用較新的序號_會更新賠率() async {
        let store = OddsStore()

        await store.apply(.stub(matchID: 1001, teamA: 1.95, teamB: 2.10, sequence: 1))
        let accepted = await store.apply(.stub(matchID: 1001, teamA: 1.92, teamB: 2.08, sequence: 2))

        XCTAssertTrue(accepted)
        let odds = await store.odds(for: 1001)
        XCTAssertEqual(odds?.teamAOdds, 1.92)
    }

    func test_套用較舊的序號_會被丟棄且不影響現值() async {
        let store = OddsStore()

        await store.apply(.stub(matchID: 1001, teamA: 1.92, teamB: 2.08, sequence: 5))
        let accepted = await store.apply(.stub(matchID: 1001, teamA: 9.99, teamB: 9.99, sequence: 3))

        XCTAssertFalse(accepted, "序號較舊的推播必須被丟棄，否則舊資料會覆蓋新資料")
        let odds = await store.odds(for: 1001)
        XCTAssertEqual(odds?.teamAOdds, 1.92)
        XCTAssertEqual(odds?.teamBOdds, 2.08)
    }

    func test_重複序號_會被丟棄() async {
        let store = OddsStore()

        await store.apply(.stub(matchID: 1001, teamA: 1.92, teamB: 2.08, sequence: 5))
        let accepted = await store.apply(.stub(matchID: 1001, teamA: 3.00, teamB: 3.00, sequence: 5))

        XCTAssertFalse(accepted)
        let odds = await store.odds(for: 1001)
        XCTAssertEqual(odds?.teamAOdds, 1.92)
    }

    // MARK: - 並發一致性（spec §4 FR-4.1）

    /// 這支測試是 thread-safe 的直接證明：
    /// 10 個並行 Task 對同一批比賽亂序寫入 1000 筆更新，
    /// 最終每一場的值都必須等於「序號最大的那一筆」。
    ///
    /// 若 store 換成無保護的字典，這支測試會 crash 或得到錯誤結果。
    func test_十個並行任務寫入一千筆_最終狀態確定且正確() async {
        let store = OddsStore()
        let matchIDs = Array(1001...1010)
        let updatesPerTask = 100
        let taskCount = 10

        // 預先產生全域唯一且遞增的序號，並打亂送出順序。
        var allUpdates: [OddsUpdate] = []
        var sequence: UInt64 = 0
        for _ in 0..<(taskCount * updatesPerTask) {
            sequence += 1
            let matchID = matchIDs[Int(sequence) % matchIDs.count]
            allUpdates.append(
                .stub(
                    matchID: matchID,
                    teamA: Double(sequence) / 100,
                    teamB: Double(sequence) / 50,
                    sequence: sequence
                )
            )
        }

        // 每場比賽序號最大的那一筆，就是期望的最終值。
        var expected: [Int: OddsUpdate] = [:]
        for update in allUpdates {
            if let existing = expected[update.matchID], existing.sequence > update.sequence {
                continue
            }
            expected[update.matchID] = update
        }

        var generator = SeededGenerator(seed: 42)
        allUpdates.shuffle(using: &generator)

        let chunks = stride(from: 0, to: allUpdates.count, by: updatesPerTask).map {
            Array(allUpdates[$0..<min($0 + updatesPerTask, allUpdates.count)])
        }

        await withTaskGroup(of: Void.self) { group in
            for chunk in chunks {
                group.addTask {
                    for update in chunk {
                        await store.apply(update)
                    }
                }
            }
        }

        for (matchID, expectedUpdate) in expected {
            let actual = await store.odds(for: matchID)
            XCTAssertEqual(
                actual?.teamAOdds,
                expectedUpdate.teamAOdds,
                "matchID \(matchID) 的最終值必須是序號最大的那一筆"
            )
        }
    }

    // MARK: - 重連對帳（spec §FR-6.4）

    func test_對帳後_斷線期間飛行中的舊推播不會覆蓋校正值() async {
        let store = OddsStore()

        // 斷線前收到 seq 10。
        await store.apply(.stub(matchID: 1001, teamA: 1.50, teamB: 2.50, sequence: 10))

        // 重連後全量對帳，拿到伺服器的正確值。
        await store.replaceAll(with: [Odds(matchID: 1001, teamAOdds: 3.00, teamBOdds: 1.40)])

        // 斷線期間仍在飛行中的舊推播現在才抵達 —— 必須被擋掉。
        let accepted = await store.apply(
            .stub(matchID: 1001, teamA: 1.55, teamB: 2.45, sequence: 9)
        )

        XCTAssertFalse(accepted, "對帳後的舊推播若被接受，對帳等於白做")
        let odds = await store.odds(for: 1001)
        XCTAssertEqual(odds?.teamAOdds, 3.00)
    }

    func test_對帳後_新推播仍可正常套用() async {
        let store = OddsStore()

        await store.apply(.stub(matchID: 1001, teamA: 1.50, teamB: 2.50, sequence: 10))
        await store.replaceAll(with: [Odds(matchID: 1001, teamAOdds: 3.00, teamBOdds: 1.40)])

        let accepted = await store.apply(
            .stub(matchID: 1001, teamA: 3.10, teamB: 1.38, sequence: 11)
        )

        XCTAssertTrue(accepted)
        let odds = await store.odds(for: 1001)
        XCTAssertEqual(odds?.teamAOdds, 3.10)
    }

    func test_對帳不觸發漲跌閃爍() async {
        let store = OddsStore()

        await store.apply(.stub(matchID: 1001, teamA: 1.50, teamB: 2.50, sequence: 1))
        await store.apply(.stub(matchID: 1001, teamA: 1.80, teamB: 2.20, sequence: 2))
        let changeBefore = await store.change(for: 1001)
        XCTAssertTrue(changeBefore.hasChange)

        await store.replaceAll(with: [Odds(matchID: 1001, teamAOdds: 5.00, teamBOdds: 1.10)])

        let changeAfter = await store.change(for: 1001)
        XCTAssertFalse(
            changeAfter.hasChange,
            "對帳是校正而非賠率跳動，不該讓整頁 cell 一起閃爍"
        )
    }

    // MARK: - 漲跌方向

    func test_兩隊漲跌方向分開判定() async {
        let store = OddsStore()

        await store.apply(.stub(matchID: 1001, teamA: 1.95, teamB: 2.10, sequence: 1))
        await store.apply(.stub(matchID: 1001, teamA: 2.05, teamB: 2.00, sequence: 2))

        let change = await store.change(for: 1001)
        XCTAssertEqual(change.teamA, .up)
        XCTAssertEqual(change.teamB, .down)
    }

    func test_首次載入不標記漲跌() async {
        let store = OddsStore()

        await store.apply(.stub(matchID: 1001, teamA: 1.95, teamB: 2.10, sequence: 1))

        let change = await store.change(for: 1001)
        XCTAssertFalse(change.hasChange, "首次載入若標記漲跌，進畫面時整頁都會閃")
    }

    func test_清除漲跌標記() async {
        let store = OddsStore()

        await store.apply(.stub(matchID: 1001, teamA: 1.95, teamB: 2.10, sequence: 1))
        await store.apply(.stub(matchID: 1001, teamA: 2.05, teamB: 2.00, sequence: 2))
        await store.clearChanges(for: [1001])

        let change = await store.change(for: 1001)
        XCTAssertFalse(change.hasChange)
    }

    // MARK: - 歷史

    func test_歷史筆數不超過上限() async {
        let store = OddsStore(historyLimit: 5)

        for sequence in 1...20 {
            await store.apply(
                .stub(
                    matchID: 1001,
                    teamA: Double(sequence),
                    teamB: 1.0,
                    sequence: UInt64(sequence)
                )
            )
        }

        let history = await store.history(for: 1001)
        XCTAssertEqual(history.count, 5, "歷史必須有界，否則長時間執行會無限成長")
        XCTAssertEqual(history.last?.teamAOdds, 20, "保留的必須是最新的幾筆")
        XCTAssertEqual(history.first?.teamAOdds, 16)
    }

    // MARK: - 批次

    func test_批次套用只回報實際變動的比賽() async {
        let store = OddsStore()

        await store.apply(.stub(matchID: 1001, teamA: 1.95, teamB: 2.10, sequence: 10))

        let accepted = await store.apply([
            .stub(matchID: 1001, teamA: 1.90, teamB: 2.15, sequence: 5),   // 舊的，丟棄
            .stub(matchID: 1002, teamA: 3.00, teamB: 1.40, sequence: 11),  // 新的
            .stub(matchID: 1003, teamA: 2.20, teamB: 1.80, sequence: 12)   // 新的
        ])

        XCTAssertEqual(
            accepted,
            [1002, 1003],
            "被丟棄的更新不該造成任何 UI 工作"
        )
    }

    // MARK: - 快照

    func test_快照與比賽清單合併後依開賽時間排序() async {
        let store = OddsStore()
        let base = Date(timeIntervalSince1970: 1_720_099_200)

        await store.apply(.stub(matchID: 1001, teamA: 1.95, teamB: 2.10, sequence: 1))

        let matches = [
            Match(id: 1003, teamA: "C", teamB: "D", startTime: base.addingTimeInterval(300)),
            Match(id: 1001, teamA: "A", teamB: "B", startTime: base.addingTimeInterval(100)),
            Match(id: 1002, teamA: "E", teamB: "F", startTime: base.addingTimeInterval(200))
        ]

        let rows = await store.snapshot().rows(for: matches)

        XCTAssertEqual(rows.map(\.id), [1001, 1002, 1003])
        XCTAssertEqual(rows[0].odds?.teamAOdds, 1.95)
        XCTAssertNil(rows[1].odds, "賠率尚未載入的比賽必須能以 nil 表現，而不是假資料")
    }
}
