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

    func focus(session: Session) -> FocusResult {
        guard isRunning else {
            return .notRunning
        }

        // 1. Select tmux pane if needed (this is the main value we can provide)
        let tmuxSessionName = selectTmuxPaneIfNeeded(for: session)

        // 2. Activate Terminal.app
        activate()

        // Terminal.app doesn't support tab-level control via scripting
        // But if tmux is involved, we've at least selected the right pane
        if tmuxSessionName != nil {
            DebugLog.log("[TerminalAppController] Activated with tmux pane '\(tmuxSessionName!)'")
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
