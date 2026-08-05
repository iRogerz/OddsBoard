import XCTest
@testable import OddsCore

final class MatchSortingTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_720_099_200)

    func test_依開賽時間升序_最早的在最上面() {
        let matches = [
            Match(id: 1, teamA: "A", teamB: "B", startTime: base.addingTimeInterval(300)),
            Match(id: 2, teamA: "C", teamB: "D", startTime: base.addingTimeInterval(100)),
            Match(id: 3, teamA: "E", teamB: "F", startTime: base.addingTimeInterval(200))
        ]

        XCTAssertEqual(MatchSorting.sorted(matches).map(\.id), [2, 3, 1])
    }

    /// 題目只寫「依比賽時間升序」，未定義同時間的次序。
    /// 不補這條規則，同一份資料在不同次載入可能得到不同順序，畫面會無故跳動。
    func test_開賽時間相同時_以matchID決定次序() {
        let sameTime = base.addingTimeInterval(600)
        let matches = [
            Match(id: 1005, teamA: "A", teamB: "B", startTime: sameTime),
            Match(id: 1001, teamA: "C", teamB: "D", startTime: sameTime),
            Match(id: 1003, teamA: "E", teamB: "F", startTime: sameTime)
        ]

        XCTAssertEqual(MatchSorting.sorted(matches).map(\.id), [1001, 1003, 1005])
    }

    func test_任意輸入順序都得到相同結果() {
        let sameTime = base.addingTimeInterval(600)
        let matches = [
            Match(id: 1005, teamA: "A", teamB: "B", startTime: sameTime),
            Match(id: 1001, teamA: "C", teamB: "D", startTime: sameTime),
            Match(id: 1003, teamA: "E", teamB: "F", startTime: base),
            Match(id: 1002, teamA: "G", teamB: "H", startTime: sameTime)
        ]

        var generator = SeededGenerator(seed: 7)
        let expected = MatchSorting.sorted(matches).map(\.id)

        for _ in 0..<20 {
            var shuffled = matches
            shuffled.shuffle(using: &generator)
            XCTAssertEqual(
                MatchSorting.sorted(shuffled).map(\.id),
                expected,
                "排序必須具確定性，不受輸入順序影響"
            )
        }
    }
}
