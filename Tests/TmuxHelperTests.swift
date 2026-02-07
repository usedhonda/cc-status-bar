import XCTest
@testable import CCStatusBarLib

final class TmuxHelperTests: XCTestCase {

    // MARK: - RemoteAccessInfo.attachCommand

    func testAttachCommandWithoutSocket() {
        let info = TmuxHelper.RemoteAccessInfo(
            sessionName: "main",
            windowIndex: "0",
            paneIndex: "0",
            socketPath: nil
        )
        XCTAssertEqual(info.attachCommand, "tmux attach -t main")
    }

    func testAttachCommandWithSocket() {
        let info = TmuxHelper.RemoteAccessInfo(
            sessionName: "main",
            windowIndex: "0",
            paneIndex: "0",
            socketPath: "/tmp/tmux-501/custom"
        )
        XCTAssertEqual(info.attachCommand, "tmux -S /tmp/tmux-501/custom attach -t main")
    }

    func testTargetSpecifier() {
        let info = TmuxHelper.RemoteAccessInfo(
            sessionName: "dev",
            windowIndex: "2",
            paneIndex: "1",
            socketPath: nil
        )
        XCTAssertEqual(info.targetSpecifier, "dev:2.1")
    }

    // MARK: - TmuxAttachCommand.build

    func testBuildAttachCommandWithoutSocket() {
        let cmd = TmuxAttachCommand.build(sessionName: "main", socketPath: nil)
        XCTAssertEqual(cmd, "tmux attach -t main")
    }

    func testBuildAttachCommandWithSocket() {
        let cmd = TmuxAttachCommand.build(sessionName: "main", socketPath: "/tmp/tmux-501/custom")
        XCTAssertEqual(cmd, "tmux -S /tmp/tmux-501/custom attach -t main")
    }

    func testBuildFullAttachCommandWithoutSocket() {
        let cmd = TmuxAttachCommand.buildFull(sessionName: "dev", window: "0", pane: "1", socketPath: nil)
        XCTAssertEqual(cmd, "tmux attach -t dev:0.1")
    }

    func testBuildFullAttachCommandWithSocket() {
        let cmd = TmuxAttachCommand.buildFull(
            sessionName: "dev", window: "0", pane: "1", socketPath: "/tmp/tmux-501/custom"
        )
        XCTAssertEqual(cmd, "tmux -S /tmp/tmux-501/custom attach -t dev:0.1")
    }

    // MARK: - TmuxHelper.deduplicatePaths

    func testDeduplicatePathsRemovesDuplicates() {
        // Use paths that actually exist on the system
        let paths = ["/tmp", "/tmp", "/tmp"]
        let result = TmuxHelper.deduplicatePaths(paths)
        XCTAssertEqual(result.count, 1)
    }

    func testDeduplicatePathsFiltersNonExistent() {
        let paths = ["/tmp", "/nonexistent/path/abc123"]
        let result = TmuxHelper.deduplicatePaths(paths)
        // /tmp exists, /nonexistent does not -> only /tmp remains
        XCTAssertEqual(result, ["/tmp"])
    }

    func testDeduplicatePathsNormalizesSymlinks() {
        // On macOS, /private/tmp normalizes to /tmp via standardizingPath
        let paths = ["/tmp", "/private/tmp"]
        let result = TmuxHelper.deduplicatePaths(paths)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first, "/tmp")
    }

    // MARK: - normalizeTTY

    func testNormalizeTTYWithDevPrefix() {
        XCTAssertEqual(TmuxHelper.normalizeTTY("/dev/ttys001"), "/dev/ttys001")
    }

    func testNormalizeTTYWithoutPrefix() {
        XCTAssertEqual(TmuxHelper.normalizeTTY("ttys001"), "/dev/ttys001")
    }

    func testNormalizeTTYWithPartialPrefix() {
        XCTAssertEqual(TmuxHelper.normalizeTTY("dev/ttys001"), "/dev/ttys001")
    }

    func testNormalizeTTYEmpty() {
        XCTAssertEqual(TmuxHelper.normalizeTTY(""), "")
    }

    func testNormalizeTTYWhitespace() {
        XCTAssertEqual(TmuxHelper.normalizeTTY("  "), "")
    }

    func testNormalizeTTYWithTrailingWhitespace() {
        XCTAssertEqual(TmuxHelper.normalizeTTY("/dev/ttys001  "), "/dev/ttys001")
    }

    // MARK: - splitPaneColumns

    func testSplitPaneColumnsTabSeparated() {
        let line: Substring = "/dev/ttys001\tdefault\t0\t0\tzsh"
        let parts = TmuxHelper.splitPaneColumns(line)
        XCTAssertEqual(parts.count, 5)
        XCTAssertEqual(parts[0], "/dev/ttys001")
        XCTAssertEqual(parts[1], "default")
        XCTAssertEqual(parts[2], "0")
        XCTAssertEqual(parts[3], "0")
        XCTAssertEqual(parts[4], "zsh")
    }

    func testSplitPaneColumnsPipeSeparated() {
        let line: Substring = "/dev/ttys002|mysession|1|0|vim"
        let parts = TmuxHelper.splitPaneColumns(line)
        XCTAssertEqual(parts.count, 5)
        XCTAssertEqual(parts[0], "/dev/ttys002")
        XCTAssertEqual(parts[1], "mysession")
        XCTAssertEqual(parts[2], "1")
        XCTAssertEqual(parts[3], "0")
        XCTAssertEqual(parts[4], "vim")
    }

    func testSplitPaneColumnsInsufficientFields() {
        let line: Substring = "only|two"
        let parts = TmuxHelper.splitPaneColumns(line)
        XCTAssertEqual(parts, [])
    }

    func testSplitPaneColumnsWindowNameWithDelimiter() {
        // Window name contains the delimiter character
        let line: Substring = "/dev/ttys001\tdefault\t0\t0\tmy\twindow"
        let parts = TmuxHelper.splitPaneColumns(line)
        XCTAssertEqual(parts.count, 5)
        XCTAssertEqual(parts[4], "my\twindow")
    }

    // MARK: - parsePaneInfo

    func testParsePaneInfoMatching() {
        let output = "/dev/ttys001\tdefault\t0\t0\tzsh\n/dev/ttys002\twork\t1\t0\tvim"
        let info = TmuxHelper.parsePaneInfo(from: output, matchingTTY: "/dev/ttys002", socketPath: nil)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.session, "work")
        XCTAssertEqual(info?.window, "1")
        XCTAssertEqual(info?.pane, "0")
        XCTAssertEqual(info?.windowName, "vim")
        XCTAssertNil(info?.socketPath)
    }

    func testParsePaneInfoNoMatch() {
        let output = "/dev/ttys001\tdefault\t0\t0\tzsh"
        let info = TmuxHelper.parsePaneInfo(from: output, matchingTTY: "/dev/ttys999", socketPath: nil)
        XCTAssertNil(info)
    }

    func testParsePaneInfoWithSocketPath() {
        let output = "/dev/ttys003\tdev\t2\t1\tnode"
        let info = TmuxHelper.parsePaneInfo(from: output, matchingTTY: "/dev/ttys003", socketPath: "/tmp/tmux-501/custom")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.session, "dev")
        XCTAssertEqual(info?.socketPath, "/tmp/tmux-501/custom")
    }

    func testParsePaneInfoEmptyOutput() {
        let info = TmuxHelper.parsePaneInfo(from: "", matchingTTY: "/dev/ttys001", socketPath: nil)
        XCTAssertNil(info)
    }

    func testParsePaneInfoNormalizesInputTTY() {
        // The output has /dev/ prefix but matching TTY does not
        let output = "/dev/ttys005\tproject\t0\t0\tbash"
        let info = TmuxHelper.parsePaneInfo(from: output, matchingTTY: "/dev/ttys005", socketPath: nil)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.session, "project")
    }

    // MARK: - parseAttachStates

    func testParseAttachStates() {
        let output = "session_name|0\nattached_session|1"
        let states = TmuxHelper.parseAttachStates(from: output)
        XCTAssertEqual(states["session_name"], false)
        XCTAssertEqual(states["attached_session"], true)
    }

    func testParseAttachStatesEmpty() {
        let states = TmuxHelper.parseAttachStates(from: "")
        XCTAssertTrue(states.isEmpty)
    }

    func testParseAttachStatesMalformedLine() {
        let output = "no_separator\nvalid|1"
        let states = TmuxHelper.parseAttachStates(from: output)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states["valid"], true)
    }

    func testParseAttachStatesMultipleSessions() {
        let output = "a|0\nb|1\nc|0\nd|1"
        let states = TmuxHelper.parseAttachStates(from: output)
        XCTAssertEqual(states.count, 4)
        XCTAssertEqual(states["a"], false)
        XCTAssertEqual(states["b"], true)
        XCTAssertEqual(states["c"], false)
        XCTAssertEqual(states["d"], true)
    }
}
