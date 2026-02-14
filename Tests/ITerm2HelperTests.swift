import XCTest
@testable import CCStatusBarLib

final class ITerm2HelperTests: XCTestCase {
    func testNormalizeNameForMatchingRemovesDecorations() {
        let normalized = ITerm2Helper.normalizeNameForMatching("🔔  MyProject : dev")
        XCTAssertEqual(normalized, "myproject : dev")
    }

    func testTabNameMatchesWithDelimiterBoundaries() {
        XCTAssertTrue(ITerm2Helper.tabNameMatches("work:api", searchTerm: "work"))
        XCTAssertTrue(ITerm2Helper.tabNameMatches("build-work_01", searchTerm: "work"))
    }

    func testTabNameMatchesWithWhitespaceAndCase() {
        XCTAssertTrue(ITerm2Helper.tabNameMatches("  PROJECT Alpha  ", searchTerm: "project alpha"))
    }

    func testTabNameMatchesRejectsUnrelatedTerm() {
        XCTAssertFalse(ITerm2Helper.tabNameMatches("backend-service", searchTerm: "frontend"))
    }

    func testTabNameMatchesRejectsEmptySearchTerm() {
        XCTAssertFalse(ITerm2Helper.tabNameMatches("backend-service", searchTerm: ""))
        XCTAssertFalse(ITerm2Helper.tabNameMatches("backend-service", searchTerm: "   "))
    }
}
