import AppKit
import Foundation

/// Terminal controller for iTerm2
/// Uses AppleScript for session/tab switching
final class ITerm2Controller: TerminalController {
    static let shared = ITerm2Controller()
    static let focusRetryAttempts = 4
    static let focusRetryDelaySeconds = 0.2

    let name = "iTerm2"
    let bundleIdentifier = "com.googlecode.iterm2"

    var isRunning: Bool {
        ITerm2Helper.isRunning
    }

    private init() {}

    // MARK: - TerminalController

    /// Focus with pre-resolved environment parameters
    /// - Parameters:
    ///   - session: The session to focus
    ///   - hasTmux: Whether tmux is involved (resolved by EnvironmentResolver)
    ///   - tmuxSessionName: tmux session name if available
    func focus(
        session: Session,
        hasTmux: Bool,
        tmuxSessionName: String?
    ) -> FocusResult {
        guard isRunning else {
            return .notRunning
        }

        let projectName = session.projectName
        var paneSelected = false

        // 1. Select tmux pane if needed (already known via resolver)
        if hasTmux, let tty = session.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            paneSelected = TmuxHelper.selectPane(paneInfo)
            if paneSelected {
                DebugLog.log("[ITerm2Controller] Selected tmux pane")
            }
        }

        // 2. Try focus with short retries to absorb slow iTerm2 tab updates.
        for attempt in 0..<Self.focusRetryAttempts {
            if tryFocusSession(session: session, tmuxSessionName: tmuxSessionName, projectName: projectName) {
                return .success
            }
            if attempt < Self.focusRetryAttempts - 1 {
                Thread.sleep(forTimeInterval: Self.focusRetryDelaySeconds)
            }
        }

        // 3. Fallback: just activate iTerm2
        activate()

        // If tmux pane selection succeeded, keep it as partial success.
        if paneSelected {
            let preferredSearch = tmuxSessionName ?? projectName
            return .partialSuccess(reason: "tmux pane selected, but tab '\(preferredSearch)' not found after retry")
        }

        let preferredSearch = tmuxSessionName ?? projectName
        let hint = session.tty != nil
            ? "No session with TTY '\(session.tty!)' or name '\(preferredSearch)' found"
            : "No session matching '\(preferredSearch)' found"

        return .notFound(hint: hint)
    }

    @discardableResult
    func activate() -> Bool {
        ITerm2Helper.activate()
    }

    static func searchTerms(tmuxSessionName: String?, projectName: String) -> [String] {
        var terms: [String] = []
        if let tmuxSessionName, !tmuxSessionName.isEmpty {
            terms.append(tmuxSessionName)
        }
        if !projectName.isEmpty, !terms.contains(projectName) {
            terms.append(projectName)
        }
        return terms
    }

    private func tryFocusSession(session: Session, tmuxSessionName: String?, projectName: String) -> Bool {
        // TTY match first (works best for non-tmux, sometimes for tmux clients)
        if let tty = session.tty, ITerm2Helper.focusSessionByTTY(tty) {
            DebugLog.log("[ITerm2Controller] Focused session by TTY '\(tty)'")
            return true
        }

        // Then robust name matching (tmux session, then project fallback)
        for term in Self.searchTerms(tmuxSessionName: tmuxSessionName, projectName: projectName) {
            if ITerm2Helper.focusSessionByName(term) {
                DebugLog.log("[ITerm2Controller] Focused session by name '\(term)'")
                return true
            }
        }

        return false
    }
}
