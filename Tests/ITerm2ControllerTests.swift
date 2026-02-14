import XCTest
@testable import CCStatusBarLib

final class ITerm2ControllerTests: XCTestCase {
    func testSearchTermsWithTmuxAndProject() {
        let terms = ITerm2Controller.searchTerms(tmuxSessionName: "workspace", projectName: "api")
        XCTAssertEqual(terms, ["workspace", "api"])
    }

    func testSearchTermsDeduplicatesProjectFallback() {
        let terms = ITerm2Controller.searchTerms(tmuxSessionName: "api", projectName: "api")
        XCTAssertEqual(terms, ["api"])
    }

    func testSearchTermsWithoutTmuxFallsBackToProject() {
        let terms = ITerm2Controller.searchTerms(tmuxSessionName: nil, projectName: "api")
        XCTAssertEqual(terms, ["api"])
    }

    func testRetryConfiguration() {
        XCTAssertEqual(ITerm2Controller.focusRetryAttempts, 4)
        XCTAssertEqual(ITerm2Controller.focusRetryDelaySeconds, 0.2, accuracy: 0.0001)
    }
}
