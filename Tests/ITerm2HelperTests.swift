import XCTest
@testable import CCStatusBarLib

final class ITerm2HelperTests: XCTestCase {
    func testTTYTabIndexesReadsEverySessionAndSkipsJunk() {
        let output = "/dev/ttys027:0\n/dev/ttys032:1\n/dev/ttys032:2\nnot a row\n/dev/ttys040:x\n"
        XCTAssertEqual(
            ITerm2Helper.ttyTabIndexes(fromScriptOutput: output),
            ["/dev/ttys027": 0, "/dev/ttys032": 1]
        )
        XCTAssertEqual(ITerm2Helper.ttyTabIndexes(fromScriptOutput: ""), [:])
    }

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
