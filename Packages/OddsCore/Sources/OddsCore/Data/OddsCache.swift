import Foundation

/// 快取的比賽快照（`docs/spec.md` §FR-5）。
public struct CachedSnapshot: Sendable, Codable, Equatable {

    public let matches: [Match]
    public let odds: [Odds]
    public let savedAt: Date

    public init(matches: [Match], odds: [Odds], savedAt: Date) {
        self.matches = matches
        self.odds = odds
        self.savedAt = savedAt
    }

    /// 超過此時間即視為過期。仍會顯示，但畫面上必須標示。
    ///
    /// **為什麼過期一定要標示而不是直接丟棄**：直接拿舊賠率當現值顯示，在博弈
    /// 情境是最危險的一類錯誤 —— 使用者會依據錯誤的數字做決定。但完全不顯示
    /// 又會讓冷啟動變成一片空白，失去快取的意義。折衷是「顯示 + 明確標示」。
    public static let staleThreshold: TimeInterval = 10 * 60

    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(savedAt) > Self.staleThreshold
    }
}

/// 快照的持久化介面。
public protocol SnapshotCaching: Sendable {
    func load() async -> CachedSnapshot?
    func save(_ snapshot: CachedSnapshot) async
    func clear() async
}

/// 以單一 JSON 檔持久化的快取。
///
/// 寫入採「先寫暫存檔再原子替換」：直接覆寫原檔時若在寫入中途被系統終止，
/// 留下的是一個半截的 JSON —— 下次冷啟動不只讀不到快取，還得先解析失敗一次。
/// 原子替換讓檔案永遠處於「舊的完整版」或「新的完整版」兩種狀態之一。
public actor FileSnapshotCache: SnapshotCaching {

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// 預設落在 Caches 目錄而非 Documents：這是可重建的衍生資料，
    /// 系統在空間不足時本來就該有權回收它，也不該被備份到 iCloud。
    public static func makeDefault(
        fileManager: FileManager = .default
    ) -> FileSnapshotCache {
        let directory = fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return FileSnapshotCache(
            fileURL: directory.appendingPathComponent("odds-snapshot.json")
        )
    }

    public func load() async -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(CachedSnapshot.self, from: data)
    }

    public func save(_ snapshot: CachedSnapshot) async {
        guard let data = try? encoder.encode(snapshot) else { return }

        let temporaryURL = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } catch {
            // 快取寫入失敗不該影響 App 運作 —— 它只是加速冷啟動的最佳化。
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }

    public func clear() async {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
