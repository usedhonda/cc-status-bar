import XCTest
@testable import CCStatusBarLib

final class SessionStatusTests: XCTestCase {
    // MARK: - Symbol Tests

    func testRunningSymbol() {
        XCTAssertEqual(SessionStatus.running.symbol, "●")
    }

    func testWaitingInputSymbol() {
        XCTAssertEqual(SessionStatus.waitingInput.symbol, "◐")
    }

    func testStoppedSymbol() {
        XCTAssertEqual(SessionStatus.stopped.symbol, "✓")
    }

    // MARK: - Label Tests

    func testRunningLabel() {
        XCTAssertEqual(SessionStatus.running.label, "Running")
    }

    func testWaitingInputLabel() {
        XCTAssertEqual(SessionStatus.waitingInput.label, "Waiting")
    }

    func testStoppedLabel() {
        XCTAssertEqual(SessionStatus.stopped.label, "Done")
    }

    // MARK: - Raw Value Tests

    func testRawValues() {
        XCTAssertEqual(SessionStatus.running.rawValue, "running")
        XCTAssertEqual(SessionStatus.waitingInput.rawValue, "waiting_input")
        XCTAssertEqual(SessionStatus.stopped.rawValue, "stopped")
    }

    func testInitFromRawValue() {
        XCTAssertEqual(SessionStatus(rawValue: "running"), .running)
        XCTAssertEqual(SessionStatus(rawValue: "waiting_input"), .waitingInput)
        XCTAssertEqual(SessionStatus(rawValue: "stopped"), .stopped)
        XCTAssertNil(SessionStatus(rawValue: "invalid"))
    }
}
