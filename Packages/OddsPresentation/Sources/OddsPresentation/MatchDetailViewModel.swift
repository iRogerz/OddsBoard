import Combine
import Foundation
import OddsCore

/// 單場比賽的詳情。
///
/// 這個畫面在題目中並未要求。它存在的理由是：加分題「切換畫面後能快速恢復
/// 顯示」需要有第二個畫面才能被驗證，而題目只描述了一個列表。
/// 因此刻意做到最小 —— 只顯示這場比賽的現況與近期賠率走勢。
///
/// 附帶好處是它證明了 `OddsStore` 的資料建模不只存「當前值」。
@MainActor
public final class MatchDetailViewModel: ObservableObject {

    public let match: Match

    @Published public private(set) var currentOdds: Odds?
    @Published public private(set) var history: [Odds] = []

    private let store: OddsStore
    private let clock: AppClock
    private var refreshTask: Task<Void, Never>?

    /// 詳情頁的更新間隔可以比列表寬鬆：走勢圖不需要每 100ms 重畫一次。
    private let refreshInterval: Duration = .milliseconds(500)

    public init(match: Match, store: OddsStore, clock: AppClock = SystemClock()) {
        self.match = match
        self.store = store
        self.clock = clock
    }

    public func startObserving() {
        guard refreshTask == nil else { return }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.refreshInterval else { return }
                do {
                    try await self?.clock.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    public func stopObserving() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func refresh() async {
        currentOdds = await store.odds(for: match.id)
        history = await store.history(for: match.id)
    }
}
