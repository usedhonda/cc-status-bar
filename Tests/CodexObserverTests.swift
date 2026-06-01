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

    func testShouldNotTrackCodexAppServerCommandLine() {
        // `codex app-server` is the GUI Codex.app / Computer Use protocol server,
        // not an interactive terminal CLI session.
        XCTAssertFalse(CodexObserver.shouldTrackCodexCommandLine("codex app-server --listen stdio://"))
        XCTAssertFalse(CodexObserver.shouldTrackCodexCommandLine("/Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled"))
    }

    func testShouldTrackCodexWithAppServerInPath() {
        // "app-server" appears in a path argument, not as a standalone subcommand
        XCTAssertTrue(CodexObserver.shouldTrackCodexCommandLine("codex --cwd /projects/app-server-demo"))
    }

    func testShouldTrackCodexEmptyAndWhitespace() {
        XCTAssertFalse(CodexObserver.shouldTrackCodexCommandLine(""))
        XCTAssertFalse(CodexObserver.shouldTrackCodexCommandLine("   "))
    }
}
