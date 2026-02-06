import XCTest
@testable import CCStatusBarLib

final class CodexObserverTests: XCTestCase {
    func testShouldTrackCodexCommandLineForInteractiveCodex() {
        XCTAssertTrue(CodexObserver.shouldTrackCodexCommandLine("codex"))
        XCTAssertTrue(CodexObserver.shouldTrackCodexCommandLine("codex --model gpt-5"))
        XCTAssertTrue(CodexObserver.shouldTrackCodexCommandLine("/opt/homebrew/bin/codex --ask"))
    }

    func testShouldNotTrackCodexMCPServerCommandLine() {
        XCTAssertFalse(CodexObserver.shouldTrackCodexCommandLine("codex mcp-server"))
        XCTAssertFalse(CodexObserver.shouldTrackCodexCommandLine("codex mcp-server --stdio"))
        XCTAssertFalse(CodexObserver.shouldTrackCodexCommandLine("/opt/homebrew/bin/codex mcp-server --stdio"))
    }
}
