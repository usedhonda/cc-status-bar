import ArgumentParser
import Foundation

struct HookCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Handle a hook event from Claude Code"
    )

    @Argument(help: "The hook event name (PreToolUse, PostToolUse, Notification, Stop, UserPromptSubmit, SessionStart, SessionEnd)")
    var eventName: String

    func run() throws {
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()

        guard !stdinData.isEmpty else {
            throw ValidationError("No input received from stdin")
        }

        let decoder = JSONDecoder()
        var event = try decoder.decode(HookEvent.self, from: stdinData)

        if event.tty == nil {
            event.tty = TtyDetector.getTty()
        }

        // Capture TERM_PROGRAM environment variable for editor detection (legacy fallback)
        if event.termProgram == nil {
            event.termProgram = ProcessInfo.processInfo.environment["TERM_PROGRAM"]
        }

        // Detect editor via PPID chain (most accurate for VS Code forks)
        if event.editorBundleID == nil {
            if let editor = EditorDetector.shared.detectFromCurrentProcess() {
                event.editorBundleID = editor.bundleID
            }
        }

        _ = SessionStore.shared.updateSession(event: event)
    }
}
