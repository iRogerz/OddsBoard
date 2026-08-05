import XCTest
@testable import OddsCore

final class OddsCacheTests: XCTestCase {

    private var fileURL: URL!
    private var cache: FileSnapshotCache!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("odds-cache-test-\(UUID().uuidString).json")
        cache = FileSnapshotCache(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func makeSnapshot(savedAt: Date = Date(timeIntervalSince1970: 1_720_099_200)) -> CachedSnapshot {
        CachedSnapshot(
            matches: [
                Match(id: 1001, teamA: "Eagles", teamB: "Tigers", startTime: savedAt)
            ],
            odds: [Odds(matchID: 1001, teamAOdds: 1.95, teamBOdds: 2.10)],
            savedAt: savedAt
        )
    }

    func test_寫入後可完整讀回() async {
        let snapshot = makeSnapshot()

        await cache.save(snapshot)
        let loaded = await cache.load()

        XCTAssertEqual(loaded, snapshot)
    }

    func test_沒有快取時回傳nil() async {
        let loaded = await cache.load()

        XCTAssertNil(loaded)
    }

    func test_清除後讀不到() async {
        await cache.save(makeSnapshot())
        await cache.clear()

        let loaded = await cache.load()

        XCTAssertNil(loaded)
    }

    /// 半寫入的檔案必須被視為「沒有快取」，而不是讓解析錯誤往上冒。
    func test_損毀的檔案被視為沒有快取() async {
        try? "{ 這不是合法的 JSON".data(using: .utf8)?.write(to: fileURL)

        let loaded = await cache.load()

        XCTAssertNil(loaded, "快取只是最佳化，損毀時應安靜失敗而不是拖垮啟動")
    }

    func test_重複寫入以最新一份為準() async {
        let older = makeSnapshot(savedAt: Date(timeIntervalSince1970: 1_720_000_000))
        let newer = makeSnapshot(savedAt: Date(timeIntervalSince1970: 1_720_099_200))

        await cache.save(older)
        await cache.save(newer)
        let loaded = await cache.load()

        XCTAssertEqual(loaded?.savedAt, newer.savedAt)
    }

    // MARK: - 新鮮度

    func test_剛存的快照不算過期() {
        let now = Date(timeIntervalSince1970: 1_720_099_200)
        let snapshot = makeSnapshot(savedAt: now)

        XCTAssertFalse(snapshot.isStale(now: now.addingTimeInterval(60)))
    }

    func test_超過門檻的快照算過期() {
        let now = Date(timeIntervalSince1970: 1_720_099_200)
        let snapshot = makeSnapshot(savedAt: now)

        XCTAssertTrue(
            snapshot.isStale(now: now.addingTimeInterval(CachedSnapshot.staleThreshold + 1)),
            "過期的賠率若不標示，使用者會依據錯誤的數字做判斷"
        )
    }
}
