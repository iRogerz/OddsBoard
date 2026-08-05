import Foundation

/// 全 App **唯一**持有可變賠率狀態的地方。
///
/// 沒有第二份副本、沒有 `NSLock`、沒有 concurrent queue + barrier。
///
/// 為什麼是 actor 而不是 queue + barrier：barrier 的正確性靠**每一個呼叫端
/// 自律**，漏掉一處就是資料競爭，而且編譯器不會告訴你。actor 把「同一時間
/// 只有一個執行緒能碰這份狀態」變成**編譯期**保證 —— 這正是題目問
/// 「如何確保資料存取 thread-safe」時該給的答案層次（`docs/spec.md` §4）。
public actor OddsStore {

    // MARK: - 狀態

    private var current: [Int: Odds] = [:]
    private var changes: [Int: OddsChange] = [:]
    private var histories: [Int: [Odds]] = [:]

    /// 每場比賽已接受過的最高序號，用來擋掉亂序的舊推播。
    private var acceptedSequence: [Int: UInt64] = [:]

    /// 全域看過的最高序號。重新對帳時用它當新的基準線，見 `replaceAll(with:)`。
    private var highestSequenceSeen: UInt64 = 0

    private let historyLimit: Int

    /// - Parameter historyLimit: 每場比賽保留的賠率歷史筆數，供詳情頁的
    ///   走勢圖使用（`docs/spec.md` §FR-7）。100 場 × 60 筆的記憶體成本
    ///   可忽略，但上限必須存在 —— 否則跑一整天就是無界成長。
    public init(historyLimit: Int = 60) {
        self.historyLimit = historyLimit
    }

    // MARK: - 寫入

    /// 套用單筆推播更新。
    /// - Returns: 是否被接受。序號不新於已接受的值時回傳 `false`（已丟棄）。
    @discardableResult
    public func apply(_ update: OddsUpdate) -> Bool {
        highestSequenceSeen = max(highestSequenceSeen, update.sequence)

        if let accepted = acceptedSequence[update.matchID], update.sequence <= accepted {
            return false
        }

        acceptedSequence[update.matchID] = update.sequence

        let newOdds = update.odds
        changes[update.matchID] = OddsChange(previous: current[update.matchID], current: newOdds)
        current[update.matchID] = newOdds
        appendHistory(newOdds)

        return true
    }

    /// 批次套用。
    /// - Returns: 實際發生變動的 matchID 集合 —— 呼叫端只需要對這些 id
    ///   做 UI 更新，被丟棄的更新不該造成任何畫面工作。
    @discardableResult
    public func apply(_ updates: [OddsUpdate]) -> Set<Int> {
        var accepted: Set<Int> = []
        for update in updates where apply(update) {
            accepted.insert(update.matchID)
        }
        return accepted
    }

    /// 整批覆寫所有賠率。用於初次載入，以及**斷線重連後的全量對帳**。
    ///
    /// 對帳是 `docs/spec.md` §FR-6.4 的核心：斷線期間的推播是永久遺失的，
    /// 只重連而不重抓 `GET /odds`，那些場次會永遠停在斷線前的舊賠率。
    ///
    /// 序號的處理是這裡最微妙的一點：覆寫後把所有場次的序號基準推到
    /// `highestSequenceSeen`。否則斷線前仍在飛行中的舊推播，會在對帳完成後
    /// 才抵達並覆蓋掉剛剛校正過的正確值 —— 等於對帳白做。
    public func replaceAll(with odds: [Odds]) {
        let baseline = highestSequenceSeen

        var newCurrent: [Int: Odds] = [:]
        newCurrent.reserveCapacity(odds.count)

        for entry in odds {
            newCurrent[entry.matchID] = entry
            acceptedSequence[entry.matchID] = baseline
            appendHistory(entry)
        }

        current = newCurrent
        // 對帳是校正而非「賠率跳動」，不應觸發漲跌閃爍。
        changes = [:]
    }

    // MARK: - 讀取

    public func odds(for matchID: Int) -> Odds? {
        current[matchID]
    }

    public func change(for matchID: Int) -> OddsChange {
        changes[matchID] ?? .unchanged
    }

    public func history(for matchID: Int) -> [Odds] {
        histories[matchID] ?? []
    }

    /// 取得當下全量快照。回傳的是值型別，離開 actor 後不再共享可變狀態。
    public func snapshot() -> OddsSnapshot {
        OddsSnapshot(odds: current, changes: changes)
    }

    /// 只取指定幾場的賠率與變動方向。
    ///
    /// 高頻更新時不該用 `snapshot()`：每次 flush 都複製 100 筆，
    /// 但實際變動的通常只有個位數。這個方法讓複製量正比於「真正變動的數量」，
    /// 而不是資料集大小。
    public func entries(for matchIDs: some Sequence<Int>) -> [Int: OddsEntry] {
        var result: [Int: OddsEntry] = [:]
        for matchID in matchIDs {
            guard let odds = current[matchID] else { continue }
            result[matchID] = OddsEntry(
                odds: odds,
                change: changes[matchID] ?? .unchanged
            )
        }
        return result
    }

    /// 清掉漲跌標記。cell 的閃爍動畫播完後呼叫，
    /// 避免使用者滾動時重用 cell 又閃一次早就過期的變動。
    public func clearChanges(for matchIDs: some Sequence<Int>) {
        for matchID in matchIDs {
            changes.removeValue(forKey: matchID)
        }
    }

    // MARK: - Private

    private func appendHistory(_ odds: Odds) {
        var entries = histories[odds.matchID] ?? []
        entries.append(odds)
        if entries.count > historyLimit {
            entries.removeFirst(entries.count - historyLimit)
        }
        histories[odds.matchID] = entries
    }
}

/// 單一場比賽的賠率與其變動方向。
public struct OddsEntry: Hashable, Sendable {

    public let odds: Odds
    public let change: OddsChange

    public init(odds: Odds, change: OddsChange) {
        self.odds = odds
        self.change = change
    }
}

/// 某一瞬間的賠率全量快照。
public struct OddsSnapshot: Sendable {

    public let odds: [Int: Odds]
    public let changes: [Int: OddsChange]

    public init(odds: [Int: Odds], changes: [Int: OddsChange]) {
        self.odds = odds
        self.changes = changes
    }

    /// 與比賽清單合併成畫面模型。排序在此一併完成，
    /// 確保 UI 拿到的順序永遠符合 `docs/spec.md` §4 FR-3.2。
    public func rows(for matches: [Match]) -> [MatchRow] {
        MatchSorting.sorted(matches).map { match in
            MatchRow(
                match: match,
                odds: odds[match.id],
                change: changes[match.id] ?? .unchanged
            )
        }
    }
}
