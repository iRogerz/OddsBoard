import Foundation

/// 固定種子的亂數產生器（SplitMix64）。
///
/// 用它而不是 `SystemRandomNumberGenerator` 的理由有三個：
/// 1. 測試可重現 —— 同一個 seed 永遠產出同一組資料，斷言才寫得下去。
/// 2. Demo 可重錄 —— 每次啟動的 100 場比賽完全一致，影片可以重錄到滿意為止。
/// 3. 回報 bug 時只要附上 seed，就能完整重現當時的資料集。
public struct SeededGenerator: RandomNumberGenerator {

    private var state: UInt64

    public init(seed: UInt64) {
        // seed 為 0 時 SplitMix64 仍能正常運作，但加上常數可避免
        // 呼叫端不小心傳 0 而產出可預測性過高的開頭序列。
        self.state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
