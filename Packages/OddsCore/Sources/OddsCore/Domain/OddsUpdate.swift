import Foundation

/// WebSocket 推播的單筆賠率更新。
///
/// 題目給的 payload 只有 `matchID` / `teamAOdds` / `teamBOdds`，
/// 沒有任何版本資訊。我們額外補了 `sequence`（見 `docs/spec.md` §3.3）：
///
/// 沒有版序時，只要出現並行處理或斷線重連補資料，就會發生
/// **後到的舊資料覆蓋新資料**。這種 bug 不會 crash、不會有 log，
/// 只會讓畫面顯示錯誤的賠率 —— 在博弈情境裡是最不能接受的一類錯誤。
public struct OddsUpdate: Hashable, Sendable {

    public let matchID: Int
    public let teamAOdds: Double
    public let teamBOdds: Double

    /// 全域單調遞增的序號，由推播來源產生。
    /// `OddsStore` 只接受序號大於該場比賽目前值的更新。
    public let sequence: UInt64

    /// 推播產生當下的單調時鐘讀數（奈秒）。
    /// 用來量測「推播 → 畫面」的端到端延遲（`docs/spec.md` §7），
    /// 刻意不用 `Date`，因為系統時間可能被調整而導致負延遲。
    public let sentAtNanos: UInt64

    public init(
        matchID: Int,
        teamAOdds: Double,
        teamBOdds: Double,
        sequence: UInt64,
        sentAtNanos: UInt64
    ) {
        self.matchID = matchID
        self.teamAOdds = teamAOdds
        self.teamBOdds = teamBOdds
        self.sequence = sequence
        self.sentAtNanos = sentAtNanos
    }

    /// 轉成領域模型。
    public var odds: Odds {
        Odds(matchID: matchID, teamAOdds: teamAOdds, teamBOdds: teamBOdds)
    }
}
