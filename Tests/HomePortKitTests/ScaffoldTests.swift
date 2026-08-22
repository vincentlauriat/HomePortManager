import XCTest
@testable import HomePortKit

final class ScaffoldTests: XCTestCase {
    func testErrorDescription() {
        XCTAssertEqual(HPMError("boom").description, "boom")
    }

    func testExpandPath() {
        XCTAssertFalse(expandPath("~/x").hasPrefix("~"))
        XCTAssertEqual(expandPath("/abs/path"), "/abs/path")
    }
}
