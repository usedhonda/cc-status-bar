import ArgumentParser
import Foundation

public struct HookCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Handle a hook event from Claude Code"
    )

    @Argument(help: "The hook event name (PreToolUse, PostToolUse, Notification, Stop, UserPromptSubmit, SessionStart, SessionEnd)")
    var eventName: String

    public init() {}

    public func run() throws {
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()

        guard !stdinData.isEmpty else {
            throw ValidationError("No input received from stdin")
        }

        let decoder = JSONDecoder()
        var event = try decoder.decode(HookEvent.self, from: stdinData)

        DebugLog.log("[HookCommand] Received event: \(eventName) for session \(event.sessionId)")

        if event.tty == nil {
            event.tty = TtyDetector.getTty()
        }

        // Capture TERM_PROGRAM environment variable for editor detection (legacy fallback)
        if event.termProgram == nil {
            event.termProgram = ProcessInfo.processInfo.environment["TERM_PROGRAM"]
        }

        // If inside tmux, detect the actual terminal from tmux client's parent process
        if event.termProgram?.lowercased() == "tmux",
           let tty = event.tty,
           let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            event.actualTermProgram = TmuxHelper.getClientTerminalInfo(for: paneInfo.session)
        }

        // Detect editor via PPID chain (most accurate for VS Code forks)
        if event.editorBundleID == nil {
            if let editor = EditorDetector.shared.detectFromCurrentProcess() {
                event.editorBundleID = editor.bundleID
                event.editorPID = editor.pid
            }
        }

        let session = SessionStore.shared.updateSession(event: event)

        // Set terminal title for Ghostty non-tmux sessions
        // This enables title-based tab focusing with CC-specific format
        if let session = session,
           let tty = session.tty,
           session.editorBundleID == nil,  // Not an editor session (VS Code, Cursor, etc.)
           TmuxHelper.getPaneInfo(for: tty) == nil {  // Not a tmux session
            let title = TtyHelper.ccTitle(project: session.projectName, tty: tty)
            TtyHelper.setTitle(title, tty: tty)
        }
    }
}
