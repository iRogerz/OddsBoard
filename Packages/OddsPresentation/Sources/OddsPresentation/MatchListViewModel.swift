import Combine
import Foundation
import OddsCore

/// 比賽列表的 ViewModel。
///
/// 職責刻意壓到最薄 —— 它只做「串接」：載入資料、訂閱推播、把接受的更新
/// 交給合併器、在 flush 時把變動反映到可發布的狀態上。
/// 所有值得測試的邏輯（序號仲裁、合併語意、排序、統計）都住在 `OddsCore`，
/// 那裡的測試不需要模擬器，`swift test` 兩秒跑完。
///
/// 非同步邊界（見 CLAUDE.md）：
/// - 對外的資料存取一律 `await` 進 actor（`OddsStore` / `MockOddsSocket`）
/// - 對內的 UI 綁定用 Combine `@Published`，因為 UIKit 沒有自動重繪
@MainActor
public final class MatchListViewModel: ObservableObject {

    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    // MARK: - 對 View 發布的狀態

    /// 列表的顯示順序。**只在載入時變動** —— 賠率更新不會改變它。
    ///
    /// 這是效能設計的關鍵：diffable data source 的 snapshot 綁在這個陣列上，
    /// 它不變就代表不需要 apply，賠率更新因此永遠只走 `reconfigureItems`
    /// 這條路（`docs/spec.md` §4 FR-3.3）。
    @Published public private(set) var orderedMatchIDs: [Int] = []

    @Published public private(set) var loadState: LoadState = .idle
    @Published public private(set) var connectionState: OddsConnectionState = .idle
    @Published public private(set) var stats = StreamStats()

    // MARK: - 相依

    private let api: MatchAPI
    private let store: OddsStore
    private let socket: OddsStreaming
    private let clock: AppClock
    private let coalescer = UpdateCoalescer()

    // MARK: - 內部狀態

    private var matchesByID: [Int: Match] = [:]
    private var rowsByID: [Int: MatchRow] = [:]
    /// 每個待更新場次「最早」那筆推播的產生時刻，用來量測推播→畫面的延遲。
    private var pendingSentAt: [Int: UInt64] = [:]
    private var streamTask: Task<Void, Never>?

    public init(
        api: MatchAPI,
        store: OddsStore,
        socket: OddsStreaming,
        clock: AppClock = SystemClock()
    ) {
        self.api = api
        self.store = store
        self.socket = socket
        self.clock = clock
    }

    // MARK: - 生命週期

    public func start() async {
        guard loadState != .loading else { return }
        loadState = .loading

        do {
            // 兩支 API 沒有先後相依，並行送出。
            async let matchesResult = api.fetchMatches()
            async let oddsResult = api.fetchOdds()
            let (fetchedMatches, fetchedOdds) = try await (matchesResult, oddsResult)

            let sorted = MatchSorting.sorted(fetchedMatches)
            matchesByID = Dictionary(
                sorted.map { ($0.id, $0) },
                uniquingKeysWith: { _, new in new }
            )

            await store.replaceAll(with: fetchedOdds)
            let snapshot = await store.snapshot()

            rowsByID = Dictionary(
                sorted.map { match in
                    (
                        match.id,
                        MatchRow(
                            match: match,
                            odds: snapshot.odds[match.id],
                            change: .unchanged
                        )
                    )
                },
                uniquingKeysWith: { _, new in new }
            )

            orderedMatchIDs = sorted.map(\.id)
            loadState = .loaded

            startStreaming()
        } catch {
            loadState = .failed(String(describing: error))
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil

        let socket = self.socket
        Task { await socket.disconnect() }
    }

    // MARK: - 供 View 讀取

    public func row(for matchID: Int) -> MatchRow? {
        rowsByID[matchID]
    }

    public var rows: [MatchRow] {
        orderedMatchIDs.compactMap { rowsByID[$0] }
    }

    public var hasPendingUpdates: Bool {
        coalescer.hasPendingUpdates
    }

    // MARK: - 更新節拍

    /// 取出這一拍要重新設定的 matchID，並把它們的最新值套進畫面模型。
    ///
    /// 由 View 層以 `CADisplayLink` 驅動 —— UI 的更新頻率應該由畫面的刷新
    /// 節奏決定，而不是由資料的到達節奏決定。
    ///
    /// - Returns: 需要 `reconfigureItems` 的 matchID。呼叫端應再與「目前可見的
    ///   列」取交集：100 場比賽、螢幕只看得到約 10 列，約九成的更新根本不該碰 UI。
    @discardableResult
    public func drainPendingUpdates() async -> Set<Int> {
        let matchIDs = coalescer.flush()
        guard !matchIDs.isEmpty else { return [] }

        let entries = await store.entries(for: matchIDs)
        let now = clock.monotonicNanos

        for matchID in matchIDs {
            guard let match = matchesByID[matchID] else { continue }
            let entry = entries[matchID]
            rowsByID[matchID] = MatchRow(
                match: match,
                odds: entry?.odds ?? rowsByID[matchID]?.odds,
                change: entry?.change ?? .unchanged
            )

            if let sentAt = pendingSentAt.removeValue(forKey: matchID), now > sentAt {
                stats.recordLatency(milliseconds: Double(now - sentAt) / 1_000_000)
            }
        }

        stats.recordFlush()
        return matchIDs
    }

    /// 閃爍動畫播完後呼叫，清掉漲跌標記。
    /// 否則使用者滾動時 cell 被重用，會再閃一次早就過期的變動。
    public func clearChanges(for matchIDs: Set<Int>) async {
        await store.clearChanges(for: matchIDs)
        for matchID in matchIDs {
            guard let row = rowsByID[matchID] else { continue }
            rowsByID[matchID] = MatchRow(
                match: row.match,
                odds: row.odds,
                change: .unchanged
            )
        }
    }

    // MARK: - Debug

    public func setUpdatesPerSecond(_ rate: Int) async {
        await socket.setUpdatesPerSecond(rate)
    }

    // MARK: - Private

    private func startStreaming() {
        streamTask?.cancel()

        let events = socket.events
        streamTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                await self.handle(event)
            }
        }

        let socket = self.socket
        Task { await socket.connect() }
    }

    private func handle(_ event: OddsStreamEvent) async {
        switch event {
        case .connectionState(let state):
            connectionState = state

        case .updates(let updates):
            guard !updates.isEmpty else { return }

            let accepted = await store.apply(updates)
            stats.recordBatch(received: updates.count, applied: accepted.count)

            // 只記錄每場「最早」那筆的送出時刻：一場比賽在同一個視窗內被更新
            // 多次時，使用者感受到的延遲是從第一筆算起，不是最後一筆。
            for update in updates where accepted.contains(update.matchID) {
                let existing = pendingSentAt[update.matchID]
                pendingSentAt[update.matchID] = min(existing ?? .max, update.sentAtNanos)
            }

            coalescer.ingest(accepted)
        }
    }
}
