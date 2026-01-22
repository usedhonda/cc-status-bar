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

        // 2. Try Bind-on-start tab index (only for tmux sessions)
        // Non-tmux sessions use CCSB token search which is more reliable
        // because Bind-on-start can capture wrong tab index if user switches tabs quickly
        if hasTmux, let tabIndex = tabIndex {
            if GhosttyHelper.focusTabByIndex(tabIndex) {
                DebugLog.log("[GhosttyController] Focused tab by index \(tabIndex)")
                return .success
            }
            DebugLog.log("[GhosttyController] Tab index \(tabIndex) invalid, trying title search")
        }

        let projectName = session.projectName

        // 3. Title-based search (tmux: session name, non-tmux: CCSB token)
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
            // Non-tmux: Use CCSB token for reliable tab identification
            // Token format: "[CCSB:ttysNNN]" - unique per TTY

            // Step 1: Always set the CCSB token title before searching
            // This ensures the tab is identifiable even if Claude Code overwrote the title
            let ccsbToken = TtyHelper.ccsbToken(tty: tty)
            let ccTitle = TtyHelper.ccTitle(project: projectName, tty: tty)
            let fullTitle = "\(ccTitle) \(ccsbToken)"

            DebugLog.log("[GhosttyController] Setting title with CCSB token: '\(fullTitle)'")
            TtyHelper.setTitle(fullTitle, tty: tty)
            usleep(150_000)  // 150ms wait for title update and AX tree refresh

            // Step 2: Search by CCSB token (most reliable)
            if GhosttyHelper.focusByTtyToken(tty) {
                DebugLog.log("[GhosttyController] Focused tab by CCSB token")
                return .success
            }

            // Step 3: Fallback to CC title search (legacy support)
            if GhosttyHelper.focusSession(ccTitle) {
                DebugLog.log("[GhosttyController] Focused tab by CC title '\(ccTitle)'")
                return .success
            }

            // Step 4: Last resort - try project name only
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
