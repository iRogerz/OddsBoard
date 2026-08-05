import Foundation

/// 賽事資料來源。對應題目的 `GET /matches` 與 `GET /odds`。
///
/// Presentation 層只認識這個 protocol，不認識 `MockAPIClient`。
/// 之後要換成真實網路層，只需在 Composition Root 換一行。
public protocol MatchAPI: Sendable {
    func fetchMatches() async throws -> [Match]
    func fetchOdds() async throws -> [Odds]
}

public enum MatchAPIError: Error, Equatable, Sendable {
    /// 模擬的網路失敗，用來驗證錯誤路徑不是死碼。
    case simulatedNetworkFailure
}
