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

    /// Focus with pre-resolved environment parameters
    /// - Parameters:
    ///   - session: The session to focus
    ///   - hasTmux: Whether tmux is involved (resolved by EnvironmentResolver)
    ///   - tabIndex: Bind-on-start tab index if available
    ///   - tmuxSessionName: tmux session name if available
    func focus(
        session: Session,
        hasTmux: Bool,
        tabIndex: Int?,
        tmuxSessionName: String?
    ) -> FocusResult {
        guard isRunning else {
            return .notRunning
        }

        // 1. Select tmux pane if needed (already known via resolver)
        if hasTmux, let tty = session.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            DebugLog.log("[GhosttyController] Selected tmux pane")
        }

        // 2. Try Bind-on-start tab index first
        if let tabIndex = tabIndex {
            if GhosttyHelper.focusTabByIndex(tabIndex) {
                DebugLog.log("[GhosttyController] Focused tab by index \(tabIndex)")
                return .success
            }
            DebugLog.log("[GhosttyController] Tab index \(tabIndex) invalid, trying title search")
        }

        let projectName = session.projectName

        // 3. Title-based search (tmux: session name, non-tmux: CC title)
        if hasTmux {
            // Try tmux session name first
            if let name = tmuxSessionName, GhosttyHelper.focusSession(name) {
                DebugLog.log("[GhosttyController] Focused tab for tmux session '\(name)'")
                return .success
            }
            // Try project name as fallback
            if GhosttyHelper.focusSession(projectName) {
                DebugLog.log("[GhosttyController] Focused tab for project '\(projectName)'")
                return .success
            }
        } else if let tty = session.tty {
            // Non-tmux: search by CC title format "[CC] project • ttysNNN"
            let ccTitle = TtyHelper.ccTitle(project: projectName, tty: tty)

            // First attempt
            if GhosttyHelper.focusSession(ccTitle) {
                DebugLog.log("[GhosttyController] Focused tab by CC title '\(ccTitle)'")
                return .success
            }

            // Heal: re-assert title and retry (in case Claude Code overwrote the title)
            DebugLog.log("[GhosttyController] CC title not found, re-asserting title...")
            TtyHelper.setTitle(ccTitle, tty: tty)
            usleep(100_000)  // 100ms wait for AX tree update

            if GhosttyHelper.focusSession(ccTitle) {
                DebugLog.log("[GhosttyController] Focused tab after re-assert '\(ccTitle)'")
                return .success
            }

            // Fallback: try project name only (handles partial matches)
            if GhosttyHelper.focusSession(projectName) {
                DebugLog.log("[GhosttyController] Focused tab for project '\(projectName)'")
                return .success
            }
        }

        // 4. Last resort: just activate Ghostty
        activate()

        // Return appropriate result
        if hasTmux {
            return .partialSuccess(reason: "tmux pane selected, but tab not found")
        }

        return .partialSuccess(reason: "Ghostty activated, tab '\(projectName)' not found")
    }

    @discardableResult
    func activate() -> Bool {
        GhosttyHelper.activate()
    }
}
