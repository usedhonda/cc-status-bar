import Foundation

// MARK: - Focus Result

/// Result of a terminal focus operation
/// Provides feedback for logging and potential UI display
enum FocusResult: CustomStringConvertible {
    /// Successfully focused the terminal and session
    case success

    /// Partially successful (e.g., tmux pane selected but tab not found)
    case partialSuccess(reason: String)

    /// Session not found in this terminal
    case notFound(hint: String)

    /// Terminal application is not running
    case notRunning

    var description: String {
        switch self {
        case .success:
            return "success"
        case .partialSuccess(let reason):
            return "partial: \(reason)"
        case .notFound(let hint):
            return "not found: \(hint)"
        case .notRunning:
            return "terminal not running"
        }
    }

    var isSuccess: Bool {
        switch self {
        case .success, .partialSuccess:
            return true
        case .notFound, .notRunning:
            return false
        }
    }
}

// MARK: - Terminal Controller Protocol

/// Protocol for terminal-specific focus implementations
/// Each terminal (Ghostty, iTerm2, Terminal.app) implements this protocol
/// The controller handles both terminal tab switching AND tmux pane selection internally
protocol TerminalController {
    /// Display name for logging
    var name: String { get }

    /// macOS bundle identifier
    var bundleIdentifier: String { get }

    /// Check if terminal application is currently running
    var isRunning: Bool { get }

    /// Focus the terminal for a given session
    /// This method should:
    /// 1. Select tmux pane if session is in tmux
    /// 2. Focus the correct terminal tab/window
    /// 3. Activate the terminal application
    /// - Parameter session: The session to focus
    /// - Returns: FocusResult indicating success or failure with details
    func focus(session: Session) -> FocusResult

    /// Simply activate the terminal application (bring to front)
    /// - Returns: true if successfully activated
    @discardableResult
    func activate() -> Bool
}

// MARK: - Default Implementation

extension TerminalController {
    /// Helper to select tmux pane for a session
    /// - Parameter session: The session to check for tmux
    /// - Returns: tmux session name if tmux pane was selected, nil otherwise
    func selectTmuxPaneIfNeeded(for session: Session) -> String? {
        guard let tty = session.tty,
              let paneInfo = TmuxHelper.getPaneInfo(for: tty) else {
            return nil
        }

        _ = TmuxHelper.selectPane(paneInfo)
        DebugLog.log("[\(name)] Selected tmux pane: \(paneInfo.session):\(paneInfo.window).\(paneInfo.pane)")
        return paneInfo.session
    }
}
