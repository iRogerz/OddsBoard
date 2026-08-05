import XCTest
@testable import OddsUI

final class OddsUITests: XCTestCase {

    /// 骨架佔位。ViewModel 的測試會在 D2 隨 `MatchListViewModel` 一起加入。
    func test_模組可載入() {
        XCTAssertEqual(OddsUI.moduleName, "OddsUI")
    }
}
