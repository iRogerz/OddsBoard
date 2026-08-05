import Foundation
@testable import OddsCore

/// 記錄被要求等待了多久。做成 actor 是為了避免在測試輔助程式裡引入手動鎖 ——
/// 專案憲法禁止 `NSLock`，測試碼沒有豁免權。
actor SleepRecorder {

    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

/// 立即返回的假時鐘：`sleep` 不真的等待，只記錄下來。
///
/// 這讓「模擬 200–600ms 網路延遲」「重連退避 1s→2s→4s→…」這類邏輯
/// 可以被斷言，而整套測試仍在毫秒內跑完（`docs/spec.md` §9）。
final class ImmediateClock: AppClock {

    let recorder = SleepRecorder()

    /// 固定時間，讓依賴「現在」的資料生成具可重現性。
    var now: Date { Date(timeIntervalSince1970: 1_720_099_200) }

    /// 固定值。假時鐘若在這裡漏出真實時間，任何「相同輸入 → 相同輸出」的
    /// 斷言都會偶發失敗 —— 而偶發失敗的測試最後一定會被當成雜訊忽略。
    /// 需要真實延遲量測的測試請改注入 `SystemClock`。
    var monotonicNanos: UInt64 { 1_000_000 }

    func sleep(for duration: Duration) async throws {
        await recorder.record(duration)
        // 刻意不等待實際時間，但仍讓出執行權：
        // 否則以此時鐘驅動的迴圈（例如推播的節拍）會變成忙迴圈，
        // 取消訊號永遠沒有機會被處理。
        try Task.checkCancellation()
        await Task.yield()
    }
}

extension OddsUpdate {

    /// 測試用的簡便建構子。
    static func stub(
        matchID: Int,
        teamA: Double,
        teamB: Double,
        sequence: UInt64
    ) -> OddsUpdate {
        OddsUpdate(
            matchID: matchID,
            teamAOdds: teamA,
            teamBOdds: teamB,
            sequence: sequence,
            sentAtNanos: sequence
        )
    }
}
