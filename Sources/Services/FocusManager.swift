import Foundation

/// Manages terminal focus operations
/// Selects the appropriate TerminalController based on session's environment
final class FocusManager {
    static let shared = FocusManager()

    /// All registered terminal controllers in priority order
    private let controllers: [TerminalController] = [
        GhosttyController.shared,
        ITerm2Controller.shared,
        TerminalAppController.shared
    ]

    private init() {}

    // MARK: - Public API

    /// Focus the terminal for a given session
    /// - Parameter session: The session to focus
    /// - Returns: FocusResult indicating success or failure
    @discardableResult
    func focus(session: Session) -> FocusResult {
        let env = session.environmentLabel

        DebugLog.log("[FocusManager] Focusing session '\(session.projectName)' (env: \(env))")

        // Find the appropriate controller based on environment label
        if let controller = controller(for: env) {
            let result = controller.focus(session: session)
            DebugLog.log("[FocusManager] \(controller.name) returned: \(result)")
            return result
        }

        // Fallback: try to find any running terminal
        DebugLog.log("[FocusManager] No controller matched env '\(env)', trying fallback")
        return focusFallback(session: session)
    }

    // MARK: - Private

    /// Find controller matching the environment label
    private func controller(for environmentLabel: String) -> TerminalController? {
        if environmentLabel.contains("Ghostty") {
            return GhosttyController.shared
        }
        if environmentLabel.contains("iTerm2") {
            return ITerm2Controller.shared
        }
        if environmentLabel.contains("Terminal") {
            return TerminalAppController.shared
        }
        // "tmux" only (no terminal prefix) - try to detect running terminal
        if environmentLabel == "tmux" {
            return findRunningController()
        }
        return nil
    }

    /// Find the first running terminal controller
    private func findRunningController() -> TerminalController? {
        controllers.first { $0.isRunning }
    }

    /// Fallback focus: try each running terminal
    private func focusFallback(session: Session) -> FocusResult {
        // First, try to select tmux pane if applicable
        var tmuxSelected = false
        if let tty = session.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            tmuxSelected = true
            DebugLog.log("[FocusManager] Fallback: selected tmux pane '\(paneInfo.session)'")
        }

        // Activate any running terminal
        if let controller = findRunningController() {
            controller.activate()
            DebugLog.log("[FocusManager] Fallback: activated \(controller.name)")

            if tmuxSelected {
                return .partialSuccess(reason: "tmux pane selected, \(controller.name) activated")
            }
            return .partialSuccess(reason: "\(controller.name) activated as fallback")
        }

        return .notFound(hint: "No running terminal found")
    }
}
