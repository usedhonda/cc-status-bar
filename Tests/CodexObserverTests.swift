import XCTest
@testable import CCStatusBarLib

final class CodexObserverTests: XCTestCase {
    /// These replaced `ps`, so they must agree with it, including for a process with no terminal.
    func testProcessFactsMatchPS() throws {
        func ps(_ pid: pid_t, _ field: String) throws -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-p", "\(pid)", "-o", "\(field)="]
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for pid in [getpid(), getppid(), 1] {
            XCTAssertEqual(CodexObserver.processParentPID(for: pid), pid_t(try ps(pid, "ppid")))
            XCTAssertEqual(CodexObserver.getTTY(for: pid), CodexObserver.controllingTerminal(fromPSField: try ps(pid, "tty")))
        }
        XCTAssertEqual(CodexObserver.processStartToken(for: getpid()), CodexObserver.processStartToken(for: getpid()))
        XCTAssertNotEqual(CodexObserver.processStartToken(for: getpid()), CodexObserver.processStartToken(for: 1))

        let gonePID: pid_t = 99_999
        XCTAssertNil(CodexObserver.processParentPID(for: gonePID))
        XCTAssertNil(CodexObserver.processStartToken(for: gonePID))
        XCTAssertNil(CodexObserver.getTTY(for: gonePID))

        let lineage = CodexObserver.processLineage(of: getpid())
        XCTAssertTrue(lineage.isSuperset(of: [getpid(), getppid()]))
        XCTAssertFalse(lineage.contains(1))
    }

    func testShouldTrackCodexCommandLineForInteractiveCodex() {
        XCTAssertTrue(CodexObserver.shouldTrackCodexCommandLine("codex"))
        XCTAssertTrue(CodexObserver.shouldTrackCodexCommandLine("codex --model gpt-5"))
        XCTAssertTrue(CodexObserver.shouldTrackCodexCommandLine("/opt/homebrew/bin/codex --ask"))
        XCTAssertTrue(CodexObserver.shouldTrackCodexCommandLine("codex resume --last -s danger-full-access"))
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

    func testShouldNotTrackCodexExecCommandLine() {
        XCTAssertFalse(CodexObserver.shouldTrackCodexCommandLine("codex exec --json 'task'"))
        XCTAssertEqual(CodexObserver.codexCommandExclusionReason("codex exec --json 'task'"), "exec")
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

final class CodexControllingTerminalTests: XCTestCase {
    /// Headless Codex processes (app servers, agent-runtime workers) report no
    /// terminal; only processes with one may become Cdx session rows.
    func testOnlyAProcessWithATerminalCountsAsASession() {
        XCTAssertEqual(CodexObserver.controllingTerminal(fromPSField: "ttys005\n"), "/dev/ttys005")
        XCTAssertNil(CodexObserver.controllingTerminal(fromPSField: "??"))
        XCTAssertNil(CodexObserver.controllingTerminal(fromPSField: "  \n"))
    }
}
