import AppKit

/// Terminal controller for macOS Terminal.app
/// Limited capabilities: activate-only + tmux pane selection
final class TerminalAppController: TerminalController {
    static let shared = TerminalAppController()

    let name = "Terminal"
    let bundleIdentifier = "com.apple.Terminal"

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
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

        // 1. Select tmux pane if needed (this is the main value we can provide)
        if hasTmux, let tty = session.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            DebugLog.log("[TerminalAppController] Selected tmux pane")
        }

        // 2. Activate Terminal.app
        activate()

        // Terminal.app doesn't support tab-level control via scripting
        // But if tmux is involved, we've at least selected the right pane
        if hasTmux {
            DebugLog.log("[TerminalAppController] Activated with tmux pane '\(tmuxSessionName ?? "unknown")'")
            return .partialSuccess(reason: "tmux pane selected, manual tab switch may be needed")
        }

        DebugLog.log("[TerminalAppController] Activated (no tab control available)")
        return .partialSuccess(reason: "Terminal.app activated, manual tab switch may be needed")
    }

    @discardableResult
    func activate() -> Bool {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else {
            DebugLog.log("[TerminalAppController] Terminal.app not running")
            return false
        }

        app.activate(options: [.activateIgnoringOtherApps])
        DebugLog.log("[TerminalAppController] Activated Terminal.app")
        return true
    }
}
