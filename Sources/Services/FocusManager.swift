import AppKit
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

        // Check for editor environments first (VS Code, Cursor, Zed, etc.)
        // Priority: session's detected bundle ID > environment label lookup
        if let bundleId = session.editorBundleID ?? editorBundleId(for: env) {
            let result = activateEditor(bundleId: bundleId, env: env, session: session)
            DebugLog.log("[FocusManager] Editor activation returned: \(result)")
            return result
        }

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

    /// Get editor bundle ID for environment label (fallback for sessions without detected bundle ID)
    private func editorBundleId(for environmentLabel: String) -> String? {
        // Extract editor name without "/tmux" suffix
        let editorName = environmentLabel.components(separatedBy: "/").first ?? environmentLabel

        // Look up bundle ID from display name using EditorDetector
        return EditorDetector.shared.bundleID(for: editorName)
    }

    /// Activate editor application
    private func activateEditor(bundleId: String, env: String, session: Session) -> FocusResult {
        // Handle tmux pane selection if needed
        if env.contains("tmux"), let tty = session.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            DebugLog.log("[FocusManager] Selected tmux pane for editor session")
        }

        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard !apps.isEmpty else {
            let editorName = env.components(separatedBy: "/").first ?? env
            return .notFound(hint: "\(editorName) is not running")
        }

        // Try to find the app with matching project name in window title
        if let matchingApp = findAppWithProjectWindow(apps: apps, projectName: session.projectName) {
            let activated = matchingApp.activate(options: [.activateIgnoringOtherApps])
            if activated {
                DebugLog.log("[FocusManager] Activated editor with matching window title for '\(session.projectName)'")
                return .success
            }
        }

        // Fallback: activate first app
        let activated = apps[0].activate(options: [.activateIgnoringOtherApps])
        if activated {
            DebugLog.log("[FocusManager] Fallback: activated first editor instance")
            return .success
        } else {
            return .notFound(hint: "Failed to activate \(env)")
        }
    }

    /// Find the app that has a window containing the project name
    private func findAppWithProjectWindow(apps: [NSRunningApplication], projectName: String) -> NSRunningApplication? {
        for app in apps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)

            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else {
                continue
            }

            for window in windows {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String,
                   title.lowercased().contains(projectName.lowercased()) {
                    DebugLog.log("[FocusManager] Found matching window '\(title)' for project '\(projectName)'")
                    return app
                }
            }
        }
        return nil
    }

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
