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

    /// 目前畫面上的資料來自快取，尚未被 API 結果取代。
    @Published public private(set) var isShowingCachedData = false

    /// 快取已超過新鮮度門檻。畫面必須明確標示，不能讓使用者誤以為是現值。
    @Published public private(set) var isShowingStaleData = false

    /// 重連後的全量對帳失敗。與 `connectionState` 分開表達 ——
    /// 對帳走的是 REST，推播連線可能完全正常。
    @Published public private(set) var resyncFailed = false

    // MARK: - 相依

    private let api: MatchAPI
    private let store: OddsStore
    private let socket: OddsStreaming
    private let clock: AppClock
    private let cache: SnapshotCaching?
    private let coalescer = UpdateCoalescer()

    // MARK: - 內部狀態

    private var matchesByID: [Int: Match] = [:]
    private var rowsByID: [Int: MatchRow] = [:]
    /// 每個待更新場次「最早」那筆推播的產生時刻，用來量測推播→畫面的延遲。
    private var pendingSentAt: [Int: UInt64] = [:]
    private var streamTask: Task<Void, Never>?
    /// 記錄前一個連線狀態，用來辨識「重連成功」這個轉換 ——
    /// 只看到 `.connected` 無法分辨是首次連線還是斷線後接回來。
    private var previousConnectionState: OddsConnectionState = .idle

    public init(
        api: MatchAPI,
        store: OddsStore,
        socket: OddsStreaming,
        clock: AppClock = SystemClock(),
        cache: SnapshotCaching? = nil
    ) {
        self.api = api
        self.store = store
        self.socket = socket
        self.clock = clock
        self.cache = cache
    }

    // MARK: - 生命週期

    /// 載入資料並開始接收推播。
    ///
    /// 已在載入中或已載入完成時直接返回。這個守衛必須擋掉「已完成」的情況 ——
    /// 只擋 `.loading` 的話，第二次呼叫會再建立一個 `socket.events` 的迭代器，
    /// 而 `AsyncStream` 只支援單一消費者，重疊期間會直接觸發執行期錯誤。
    /// 載入失敗後仍允許重試。
    public func start() async {
        switch loadState {
        case .loading, .loaded:
            return
        case .idle, .failed:
            break
        }
        loadState = .loading

        // 冷啟動先把上次的快照畫出來（毫秒級），再去打 API。
        // 沒有這一步，使用者要盯著轉圈等 200~600ms 才看得到任何東西。
        await applyCachedSnapshotIfAvailable()

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
            // 兩個旗標都要清。只清 `isShowingCachedData` 的話，過期橫幅會在
            // 即時資料抵達後仍掛在畫面上 —— 這條警示本來是要防止使用者把舊
            // 賠率當現值，留著反而讓人把即時賠率當成過期資料，適得其反。
            isShowingCachedData = false
            isShowingStaleData = false
            loadState = .loaded

            await saveSnapshot()
            startStreamingIfNeeded()
            await socket.connect()
        } catch {
            // **載入失敗必須一併中斷推播。**
            //
            // 不變式：`loadState == .failed` ⟺ 畫面上沒有任何即時資料在流動。
            //
            // 少了這一行，重新載入失敗時會出現「狀態列寫著載入失敗、賠率卻仍在
            // 跳動」的畫面 —— 使用者無從判斷哪個才是真的。首次冷啟動失敗時之所以
            // 不會有這個問題，只是因為 `socket.connect()` 排在 `try` 之後、根本
            // 還沒被呼叫；一旦有重新載入的入口，這個巧合就不成立了。
            //
            // 註：REST 與 WebSocket 在真實系統中確實是獨立的失敗域，「推播還活著
            // 但 REST 掛了」是可能的。那種情況該用獨立的旗標表達（如同 D4 的
            // `resyncFailed`），而不是讓 `.failed` 一詞同時代表兩種互相矛盾的畫面。
            await socket.disconnect()
            loadState = .failed(String(describing: error))
        }
    }

    /// 強制重新載入，不受目前狀態阻擋。
    ///
    /// 與 `start()` 的差別只在那道守衛：`start()` 會擋掉已載入完成的情況，
    /// 因此無法用來重跑載入流程。Debug 面板切換 API 失敗模式後需要這個入口，
    /// 否則錯誤畫面在 App 裡永遠走不到（`docs/spec.md` §FR-1.4）。
    public func reload() async {
        loadState = .idle
        await start()
    }

    /// 畫面離開時呼叫：中斷推播來源，但保留事件消費者。
    ///
    /// 不做這件事的話，使用者離開列表後推播仍以每秒 10 筆持續流入 ——
    /// 換成真實 WebSocket 就是背景維持連線與耗電，統計數字也會把離開期間
    /// 的推播一併算進去，讓 Debug HUD 顯示的更新率失真。
    public func pauseStreaming() async {
        await socket.disconnect()
        await saveSnapshot()
    }

    /// 畫面回到前景時呼叫：重新連上推播來源。
    ///
    /// 刻意**不**重新建立事件消費者 —— 消費者在整個 ViewModel 生命週期內
    /// 只建立一次，避免對同一個 `AsyncStream` 產生第二個迭代器。
    ///
    /// - Note: 離開期間的推播是真的遺失了。D4 的重連對帳（spec §FR-6.4）
    ///   會在這裡補上「重抓 `GET /odds` 做一次全量校正」。
    public func resumeStreaming() async {
        guard loadState == .loaded else { return }
        await socket.connect()
    }

    /// 完整拆除。ViewModel 不再被使用時呼叫。
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

    public func simulateDisconnection() async {
        await socket.simulateDisconnection()
    }

    // MARK: - Private

    /// 重連成功後的全量對帳（`docs/spec.md` §FR-6.4）。
    ///
    /// **這是重連功能真正的重點，也是最容易被漏掉的一半。**
    /// 斷線期間的推播是永久遺失的：只重連而不重抓 `GET /odds`，那些場次會
    /// 永遠停在斷線前的舊賠率，直到它剛好又被推播到為止。這個 bug 不會 crash、
    /// 沒有 log、測不出來，只會讓畫面默默顯示錯誤的數字。
    private func resynchronize() async {
        guard loadState == .loaded else { return }

        do {
            let odds = try await api.fetchOdds()
            await store.replaceAll(with: odds)

            // **校正後必須把所有場次送進合併器。**
            // 只更新 store 與內部字典的話，可見的 cell 從頭到尾不會被
            // reconfigure，使用者仍看著斷線前的舊值 —— 對帳等於沒有抵達畫面。
            // 走一般的 flush 路徑，畫面更新只有這一條路，不需要第二套機制。
            coalescer.ingest(orderedMatchIDs)

            resyncFailed = false
        } catch {
            // 對帳失敗只代表「校正沒成功」，不代表推播斷了 ——
            // 此時連線其實是好的，賠率仍在跳。把它寫成 `.failed` 會讓畫面
            // 顯示「無法連線」卻同時看到數字在動，自相矛盾。
            resyncFailed = true
        }
    }

    // MARK: - 快取

    private func applyCachedSnapshotIfAvailable() async {
        guard
            orderedMatchIDs.isEmpty,
            let cache,
            let cached = await cache.load()
        else {
            return
        }

        let sorted = MatchSorting.sorted(cached.matches)
        matchesByID = Dictionary(
            sorted.map { ($0.id, $0) },
            uniquingKeysWith: { _, new in new }
        )
        let oddsByID = Dictionary(
            cached.odds.map { ($0.matchID, $0) },
            uniquingKeysWith: { _, new in new }
        )
        rowsByID = Dictionary(
            sorted.map { ($0.id, MatchRow(match: $0, odds: oddsByID[$0.id], change: .unchanged)) },
            uniquingKeysWith: { _, new in new }
        )
        orderedMatchIDs = sorted.map(\.id)

        // 過期的快取仍然顯示，但必須讓使用者知道。直接拿舊賠率當現值呈現，
        // 在博弈情境是最危險的一類錯誤。
        isShowingCachedData = true
        isShowingStaleData = cached.isStale(now: clock.now)
    }

    private func saveSnapshot() async {
        guard let cache, !orderedMatchIDs.isEmpty else { return }

        let matches = orderedMatchIDs.compactMap { matchesByID[$0] }
        let odds = orderedMatchIDs.compactMap { rowsByID[$0]?.odds }
        await cache.save(
            CachedSnapshot(matches: matches, odds: odds, savedAt: clock.now)
        )
    }

    /// 建立事件消費者，並確保整個 ViewModel 生命週期內**只建立一次**。
    ///
    /// `AsyncStream` 只支援單一消費者：同時存在兩個迭代器會直接觸發執行期
    /// 錯誤。因此連線的開關由 `socket.connect()` / `disconnect()` 負責，
    /// 消費者本身從頭到尾都在。
    private func startStreamingIfNeeded() {
        guard streamTask == nil else { return }

        let events = socket.events
        streamTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: OddsStreamEvent) async {
        switch event {
        case .connectionState(let state):
            let wasReconnecting: Bool
            if case .reconnecting = previousConnectionState {
                wasReconnecting = true
            } else {
                wasReconnecting = false
            }
            previousConnectionState = state
            connectionState = state

            if wasReconnecting, state == .connected {
                // 獨立 Task：對帳含一次 REST 往返（200~600ms），若在此 await，
                // 事件消費迴圈整段停擺，高頻推播下 AsyncStream 的緩衝區會溢位
                // 而丟掉事件 —— 包含可能夾在其中的連線狀態事件。
                Task { [weak self] in await self?.resynchronize() }
            }

        case .updates(let updates):
            guard !updates.isEmpty else { return }

            let result = await store.apply(updates)
            stats.recordBatch(received: updates.count, applied: result.acceptedCount)

            // 只記錄每場「最早」那筆的送出時刻：一場比賽在同一個視窗內被更新
            // 多次時，使用者感受到的延遲是從第一筆算起，不是最後一筆。
            for update in updates where result.changedMatchIDs.contains(update.matchID) {
                let existing = pendingSentAt[update.matchID]
                pendingSentAt[update.matchID] = min(existing ?? .max, update.sentAtNanos)
            }

            coalescer.ingest(result.changedMatchIDs)
        }
    }
}
