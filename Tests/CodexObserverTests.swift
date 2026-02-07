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

    func testShouldTrackCodexWithMCPServerInPath() {
        // "mcp-server" appears in a path argument, not as a standalone subcommand
        XCTAssertTrue(CodexObserver.shouldTrackCodexCommandLine("codex --cwd /projects/mcp-server-demo"))
        XCTAssertTrue(CodexObserver.shouldTrackCodexCommandLine("codex --cwd /home/user/mcp-server"))
    }

    func testShouldNotTrackCodexMCPServerSubcommand() {
        // "mcp-server" as a standalone token (subcommand)
        XCTAssertFalse(CodexObserver.shouldTrackCodexCommandLine("codex mcp-server --stdio"))
    }

    func testShouldTrackCodexEmptyAndWhitespace() {
        XCTAssertFalse(CodexObserver.shouldTrackCodexCommandLine(""))
        XCTAssertFalse(CodexObserver.shouldTrackCodexCommandLine("   "))
    }
}
