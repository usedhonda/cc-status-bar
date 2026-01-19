import AppKit

/// Terminal controller for iTerm2
/// Uses AppleScript for session/tab switching
final class ITerm2Controller: TerminalController {
    static let shared = ITerm2Controller()

    let name = "iTerm2"
    let bundleIdentifier = "com.googlecode.iterm2"

    var isRunning: Bool {
        ITerm2Helper.isRunning
    }

    private init() {}

    // MARK: - TerminalController

    func focus(session: Session) -> FocusResult {
        guard isRunning else {
            return .notRunning
        }

        let projectName = session.projectName

        // 1. Select tmux pane if needed
        let tmuxSessionName = selectTmuxPaneIfNeeded(for: session)

        // 2. Try TTY-based search (works for non-tmux sessions)
        if let tty = session.tty {
            if ITerm2Helper.focusSessionByTTY(tty) {
                DebugLog.log("[ITerm2Controller] Focused session by TTY '\(tty)'")
                return .success
            }
        }

        // 3. Try name-based search (tmux session name or project name)
        let searchTerm = tmuxSessionName ?? projectName
        if ITerm2Helper.focusSessionByName(searchTerm) {
            DebugLog.log("[ITerm2Controller] Focused session by name '\(searchTerm)'")
            return .success
        }

        // 4. If tmux session name didn't work, try project name as fallback
        if tmuxSessionName != nil && ITerm2Helper.focusSessionByName(projectName) {
            DebugLog.log("[ITerm2Controller] Focused session by project name '\(projectName)'")
            return .success
        }

        // 5. Fallback: just activate iTerm2
        activate()

        // If we at least selected tmux pane, it's partial success
        if tmuxSessionName != nil {
            return .partialSuccess(reason: "tmux pane selected, but tab '\(searchTerm)' not found")
        }

        let hint = session.tty != nil
            ? "No session with TTY '\(session.tty!)' or name '\(searchTerm)' found"
            : "No session matching '\(searchTerm)' found"

        return .notFound(hint: hint)
    }

    @discardableResult
    func activate() -> Bool {
        ITerm2Helper.activate()
    }
}
