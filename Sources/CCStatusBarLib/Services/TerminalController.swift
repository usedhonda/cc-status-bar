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

/// Protocol for terminal-specific implementations
/// Each terminal (Ghostty, iTerm2, Terminal.app) implements this protocol
///
/// Note: The focus() method is NOT part of the protocol because each controller
/// has different parameters. FocusManager uses EnvironmentResolver to determine
/// the environment and calls the appropriate controller method directly.
protocol TerminalController {
    /// Display name for logging
    var name: String { get }

    /// macOS bundle identifier
    var bundleIdentifier: String { get }

    /// Check if terminal application is currently running
    var isRunning: Bool { get }

    /// Simply activate the terminal application (bring to front)
    /// - Returns: true if successfully activated
    @discardableResult
    func activate() -> Bool
}
