import AppKit
import Foundation

/// Manages terminal focus operations
/// Uses EnvironmentResolver for single source of truth on environment detection
final class FocusManager {
    static let shared = FocusManager()

    private init() {}

    // MARK: - Public API

    /// Focus the terminal for a given session
    /// - Parameter session: The session to focus
    /// - Returns: FocusResult indicating success or failure
    @discardableResult
    func focus(session: Session) -> FocusResult {
        var env = EnvironmentResolver.shared.resolve(session: session)

        // Real-time detection for tmux sessions without actualTermProgram
        if session.actualTermProgram == nil, env.hasTmux, let tmuxName = env.tmuxSessionName {
            if let detected = TmuxHelper.getClientTerminalInfo(for: tmuxName)?.lowercased() {
                DebugLog.log("[FocusManager] Real-time detected terminal: \(detected)")
                switch detected {
                case "ghostty":
                    env = .ghostty(hasTmux: true, tabIndex: session.ghosttyTabIndex, tmuxSessionName: tmuxName)
                case "iterm.app":
                    env = .iterm2(hasTmux: true, tmuxSessionName: tmuxName)
                case "apple_terminal":
                    env = .terminal(hasTmux: true, tmuxSessionName: tmuxName)
                default:
                    break
                }
            }
        }

        DebugLog.log("[FocusManager] Focusing '\(session.projectName)' (env: \(env.displayName))")

        switch env {
        case .editor(let bundleID, let pid, let hasTmux, let tmuxSessionName):
            return activateEditor(
                bundleID: bundleID,
                pid: pid,
                hasTmux: hasTmux,
                tmuxSessionName: tmuxSessionName,
                session: session
            )

        case .ghostty(let hasTmux, let tabIndex, let tmuxSessionName):
            return GhosttyController.shared.focus(
                session: session,
                hasTmux: hasTmux,
                tabIndex: tabIndex,
                tmuxSessionName: tmuxSessionName
            )

        case .iterm2(let hasTmux, let tmuxSessionName):
            return ITerm2Controller.shared.focus(
                session: session,
                hasTmux: hasTmux,
                tmuxSessionName: tmuxSessionName
            )

        case .terminal(let hasTmux, let tmuxSessionName):
            return TerminalAppController.shared.focus(
                session: session,
                hasTmux: hasTmux,
                tmuxSessionName: tmuxSessionName
            )

        case .tmuxOnly(let sessionName):
            return focusTmuxOnly(session: session, sessionName: sessionName)

        case .unknown:
            return focusFallback(session: session)
        }
    }

    // MARK: - Private

    /// Activate editor application
    private func activateEditor(
        bundleID: String,
        pid: pid_t?,
        hasTmux: Bool,
        tmuxSessionName: String?,
        session: Session
    ) -> FocusResult {
        // Handle tmux pane selection if needed
        if hasTmux, let tty = session.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            DebugLog.log("[FocusManager] Selected tmux pane for editor session")
        }

        // Priority 1: Activate by PID if available (most reliable for multiple instances)
        if let pid = pid {
            if let app = NSRunningApplication(processIdentifier: pid),
               !app.isTerminated,
               app.activationPolicy == .regular {  // Skip helper processes (.accessory/.prohibited)
                let activated = app.activate(options: [.activateIgnoringOtherApps])
                if activated {
                    DebugLog.log("[FocusManager] Activated editor by PID \(pid)")
                    raiseMainWindow(pid: pid)
                    return .success
                }
            }
            DebugLog.log("[FocusManager] PID \(pid) not a regular app, falling back to bundle ID")
        }

        // Priority 2: Bundle ID + window title matching (fallback)
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else {
            let editorName = EditorDetector.shared.displayName(for: bundleID) ?? bundleID
            return .notFound(hint: "\(editorName) is not running")
        }

        // Try to find the app with matching project name in window title
        if let (matchingApp, matchingWindow) = findAppWithProjectWindow(apps: apps, projectName: session.projectName) {
            let activated = matchingApp.activate(options: [.activateIgnoringOtherApps])
            if activated {
                // Raise the specific window (important for multi-window editors)
                AXUIElementPerformAction(matchingWindow, kAXRaiseAction as CFString)
                DebugLog.log("[FocusManager] Activated editor with matching window title for '\(session.projectName)'")
                return .success
            }
        }

        // Fallback: activate first app
        let activated = apps[0].activate(options: [.activateIgnoringOtherApps])
        let editorName = EditorDetector.shared.displayName(for: bundleID) ?? bundleID
        if activated {
            DebugLog.log("[FocusManager] Fallback: activated first editor instance")
            return .success
        } else {
            return .notFound(hint: "Failed to activate \(editorName)")
        }
    }

    /// Raise main window using Accessibility API for reliability
    private func raiseMainWindow(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let mainWindow = windows.first else { return }

        AXUIElementPerformAction(mainWindow, kAXRaiseAction as CFString)
    }

    /// Find the app and window containing the project name
    private func findAppWithProjectWindow(apps: [NSRunningApplication], projectName: String) -> (NSRunningApplication, AXUIElement)? {
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
                    return (app, window)
                }
            }
        }
        return nil
    }

    /// Focus tmux-only sessions (no known terminal)
    private func focusTmuxOnly(session: Session, sessionName: String) -> FocusResult {
        // Select tmux pane
        if let tty = session.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            DebugLog.log("[FocusManager] Selected tmux pane '\(sessionName)'")
        }

        // Try to activate any running terminal
        if GhosttyHelper.isRunning {
            GhosttyController.shared.activate()
            return .partialSuccess(reason: "tmux pane selected, Ghostty activated")
        }
        if ITerm2Helper.isRunning {
            ITerm2Controller.shared.activate()
            return .partialSuccess(reason: "tmux pane selected, iTerm2 activated")
        }
        if TerminalAppController.shared.isRunning {
            TerminalAppController.shared.activate()
            return .partialSuccess(reason: "tmux pane selected, Terminal activated")
        }

        return .partialSuccess(reason: "tmux pane selected, no terminal to activate")
    }

    /// Fallback focus for unknown environment
    private func focusFallback(session: Session) -> FocusResult {
        // First, try to select tmux pane if applicable
        var tmuxSelected = false
        if let tty = session.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            tmuxSelected = true
            DebugLog.log("[FocusManager] Fallback: selected tmux pane '\(paneInfo.session)'")
        }

        // Activate any running terminal
        if GhosttyHelper.isRunning {
            GhosttyController.shared.activate()
            let reason = tmuxSelected ? "tmux pane selected, Ghostty activated" : "Ghostty activated as fallback"
            return .partialSuccess(reason: reason)
        }
        if ITerm2Helper.isRunning {
            ITerm2Controller.shared.activate()
            let reason = tmuxSelected ? "tmux pane selected, iTerm2 activated" : "iTerm2 activated as fallback"
            return .partialSuccess(reason: reason)
        }
        if TerminalAppController.shared.isRunning {
            TerminalAppController.shared.activate()
            let reason = tmuxSelected ? "tmux pane selected, Terminal activated" : "Terminal activated as fallback"
            return .partialSuccess(reason: reason)
        }

        return .notFound(hint: "No running terminal found")
    }
}
