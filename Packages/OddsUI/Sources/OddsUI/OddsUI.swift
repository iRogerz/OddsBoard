import Foundation

/// OddsUI 模組的命名空間。
///
/// 目前僅有骨架。依 `docs/spec.md` §11 的時程：
/// - D2：`MatchListViewModel`（`@MainActor`，以 Combine `@Published` 對外綁定）
/// - D3：`MatchListViewController` + `MatchCell` + diffable data source + 更新合併器
/// - D4：`MatchDetailViewController`、Debug HUD
public enum OddsUI {
    public static let moduleName = "OddsUI"
}
