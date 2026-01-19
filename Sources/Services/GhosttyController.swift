import AppKit

/// Terminal controller for Ghostty
/// Uses Accessibility API for tab switching
final class GhosttyController: TerminalController {
    static let shared = GhosttyController()

    let name = "Ghostty"
    let bundleIdentifier = "com.mitchellh.ghostty"

    var isRunning: Bool {
        GhosttyHelper.isRunning
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

        // 2. Try Bind-on-start tab index (for non-tmux sessions)
        if let tabIndex = session.ghosttyTabIndex {
            if GhosttyHelper.focusTabByIndex(tabIndex) {
                DebugLog.log("[GhosttyController] Focused tab by index \(tabIndex)")
                return .success
            }
        }

        // 3. Try title-based search (tmux session name or project name)
        let searchTerm = tmuxSessionName ?? projectName
        if GhosttyHelper.focusSession(searchTerm) {
            DebugLog.log("[GhosttyController] Focused tab for '\(searchTerm)'")
            return .success
        }

        // 4. If tmux session name didn't work, try project name as fallback
        if tmuxSessionName != nil && GhosttyHelper.focusSession(projectName) {
            DebugLog.log("[GhosttyController] Focused tab for project '\(projectName)'")
            return .success
        }

        // 5. Fallback: just activate Ghostty
        activate()

        // If we at least selected tmux pane, it's partial success
        if tmuxSessionName != nil {
            return .partialSuccess(reason: "tmux pane selected, but tab '\(searchTerm)' not found")
        }

        return .notFound(hint: "No tab matching '\(searchTerm)' found in Ghostty")
    }

    @discardableResult
    func activate() -> Bool {
        GhosttyHelper.activate()
    }
}
