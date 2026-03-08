import XCTest
@testable import CCStatusBarLib

final class SoundPlayerTests: XCTestCase {
    private func makeContext() -> AlertCommandContext {
        AlertCommandContext(
            source: "claude_code",
            sessionID: "sess-123",
            project: "demo",
            displayName: "demo",
            cwd: "/tmp/demo",
            tty: "/dev/ttys001",
            waitingReason: "stop",
            terminal: "iTerm2",
            tmuxSession: "work",
            tmuxWindowIndex: "2",
            tmuxWindowName: "editor",
            tmuxPaneIndex: "1",
            tmuxPaneTarget: "work:2.1"
        )
    }

    func testResolveSoundPathUsesDefaultForBeepSetting() {
        let resolved = SoundPlayer.resolveSoundPath(
            setting: "beep",
            defaultSoundPath: "/System/Library/Sounds/Ping.aiff",
            fileExists: { path in path == "/System/Library/Sounds/Ping.aiff" }
        )

        XCTAssertEqual(resolved, "/System/Library/Sounds/Ping.aiff")
    }

    func testResolveSoundPathReturnsNilWhenNoDefaultExists() {
        let resolved = SoundPlayer.resolveSoundPath(
            setting: "beep",
            defaultSoundPath: "/System/Library/Sounds/Ping.aiff",
            fileExists: { _ in false }
        )

        XCTAssertNil(resolved)
    }

    func testResolveSoundPathKeepsCustomWhenPresent() {
        let resolved = SoundPlayer.resolveSoundPath(
            setting: "/tmp/custom.aiff",
            defaultSoundPath: "/System/Library/Sounds/Ping.aiff",
            fileExists: { path in path == "/tmp/custom.aiff" }
        )

        XCTAssertEqual(resolved, "/tmp/custom.aiff")
    }

    func testResolveSoundPathFallsBackToDefaultWhenCustomMissing() {
        let resolved = SoundPlayer.resolveSoundPath(
            setting: "/tmp/missing.aiff",
            defaultSoundPath: "/System/Library/Sounds/Ping.aiff",
            fileExists: { path in path == "/System/Library/Sounds/Ping.aiff" }
        )

        XCTAssertEqual(resolved, "/System/Library/Sounds/Ping.aiff")
    }

    func testResolveSoundPathTreatsEmptyAsDefault() {
        let resolved = SoundPlayer.resolveSoundPath(
            setting: "",
            defaultSoundPath: "/System/Library/Sounds/Ping.aiff",
            fileExists: { path in path == "/System/Library/Sounds/Ping.aiff" }
        )

        XCTAssertEqual(resolved, "/System/Library/Sounds/Ping.aiff")
    }

    func testBuildAlertCommandLaunchReturnsNilWhenDisabled() {
        let launch = SoundPlayer.buildAlertCommandLaunch(
            command: "echo hello",
            enabled: false,
            context: makeContext(),
            baseEnvironment: [:]
        )

        XCTAssertNil(launch)
    }

    func testBuildAlertCommandLaunchReturnsNilWhenCommandMissing() {
        let launch = SoundPlayer.buildAlertCommandLaunch(
            command: "   ",
            enabled: true,
            context: makeContext(),
            baseEnvironment: [:]
        )

        XCTAssertNil(launch)
    }

    func testBuildAlertCommandLaunchUsesZshAndExportsContext() {
        let launch = SoundPlayer.buildAlertCommandLaunch(
            command: "echo \"$CCSB_PROJECT:$CCSB_TMUX_PANE_TARGET\"",
            enabled: true,
            context: makeContext(),
            baseEnvironment: ["PATH": "/usr/bin"]
        )

        XCTAssertEqual(launch?.executableURL.path, "/bin/zsh")
        XCTAssertEqual(launch?.arguments, ["-lc", "echo \"$CCSB_PROJECT:$CCSB_TMUX_PANE_TARGET\""])
        XCTAssertEqual(launch?.environment["PATH"], "/usr/bin")
        XCTAssertEqual(launch?.environment["CCSB_PROJECT"], "demo")
        XCTAssertEqual(launch?.environment["CCSB_TTY"], "/dev/ttys001")
        XCTAssertEqual(launch?.environment["CCSB_TMUX_SESSION"], "work")
        XCTAssertEqual(launch?.environment["CCSB_TMUX_WINDOW_INDEX"], "2")
        XCTAssertEqual(launch?.environment["CCSB_TMUX_WINDOW_NAME"], "editor")
        XCTAssertEqual(launch?.environment["CCSB_TMUX_PANE_INDEX"], "1")
        XCTAssertEqual(launch?.environment["CCSB_TMUX_PANE_TARGET"], "work:2.1")
        XCTAssertEqual(launch?.currentDirectoryURL?.path, "/tmp/demo")
    }

    func testAlertCommandContextFromSessionUsesEmptyStringsForMissingPaneInfo() {
        let session = Session(
            sessionId: "sess-123",
            cwd: "/tmp/demo",
            tty: nil,
            status: .waitingInput,
            createdAt: .now,
            updatedAt: .now,
            waitingReason: .permissionPrompt
        )

        let context = AlertCommandContext.from(session: session, paneInfoProvider: { _ in nil })

        XCTAssertEqual(context.source, "claude_code")
        XCTAssertEqual(context.sessionID, "sess-123")
        XCTAssertEqual(context.project, "demo")
        XCTAssertEqual(context.waitingReason, "permission_prompt")
        XCTAssertEqual(context.tty, "")
        XCTAssertEqual(context.tmuxSession, "")
        XCTAssertEqual(context.tmuxPaneTarget, "")
    }

    func testAlertCommandContextFromCodexSessionFallsBackToSessionFields() {
        var session = CodexSession(pid: 42, cwd: "/tmp/demo")
        session.sessionId = "codex-1"
        session.tty = "/dev/ttys009"
        session.tmuxSession = "pair"
        session.tmuxWindow = "5"
        session.tmuxPane = "3"
        session.terminalApp = "ghostty"

        let context = AlertCommandContext.from(
            codexSession: session,
            waitingReason: .stop,
            paneInfoProvider: { _ in nil }
        )

        XCTAssertEqual(context.source, "codex")
        XCTAssertEqual(context.sessionID, "codex-1")
        XCTAssertEqual(context.terminal, "ghostty")
        XCTAssertEqual(context.tmuxSession, "pair")
        XCTAssertEqual(context.tmuxWindowIndex, "5")
        XCTAssertEqual(context.tmuxPaneIndex, "3")
        XCTAssertEqual(context.tmuxPaneTarget, "pair:5.3")
    }
}
