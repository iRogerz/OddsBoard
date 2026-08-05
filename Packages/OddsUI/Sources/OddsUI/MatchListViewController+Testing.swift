import UIKit

/// 供測試斷言使用的觀察窗。
///
/// 拆成獨立檔案是 SwiftLint 檔案長度規則的要求，但也讓「哪些成員只為
/// 測試存在」一目了然 —— 這些不是產品邏輯，改動它們不影響 App 行為。
extension MatchListViewController {

    /// 測試用：讓斷言能直接檢查節拍是否在運轉，而不是間接觀察 uiFlushes ——
    /// view 未加入 window 時 display link 本來就不會觸發，間接觀察會恆真。
    var isDisplayLinkRunningForTesting: Bool {
        displayLink != nil
    }

    /// 測試用：狀態列的當前文字。
    ///
    /// 重連期間的狀態是短暫的（退避總長約 7 秒），靠截圖去捕捉並不可靠。
    /// 用斷言直接驗證每一種連線狀態對應的文字，才是穩定的驗證方式。
    var statusTextForTesting: String? {
        statusLabel.text
    }
}
