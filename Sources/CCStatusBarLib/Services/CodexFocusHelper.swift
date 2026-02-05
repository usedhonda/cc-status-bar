import AppKit
import Foundation

/// Helps focus Codex sessions by bridging CodexSession to existing focus infrastructure
enum CodexFocusHelper {
    /// Focus a Codex session's terminal
    /// - Parameter codexSession: The Codex session to focus
    /// - Returns: FocusResult indicating success or failure
    @discardableResult
    static func focus(session codexSession: CodexSession) -> FocusResult {
        // Resolve environment from Codex session
        let env = resolveEnvironment(for: codexSession)

        DebugLog.log("[CodexFocusHelper] Focusing '\(codexSession.projectName)' (env: \(env.displayName))")

        switch env {
        case .ghostty(let hasTmux, let tabIndex, let tmuxSessionName):
            // Create minimal Session-like data for Ghostty controller
            return focusGhostty(
                codexSession: codexSession,
                hasTmux: hasTmux,
                tabIndex: tabIndex,
                tmuxSessionName: tmuxSessionName
            )

        case .iterm2(let hasTmux, let tabIndex, let tmuxSessionName):
            return focusITerm2(
                codexSession: codexSession,
                hasTmux: hasTmux,
                tabIndex: tabIndex,
                tmuxSessionName: tmuxSessionName
            )

        case .terminal(let hasTmux, let tmuxSessionName):
            return focusTerminal(
                codexSession: codexSession,
                hasTmux: hasTmux,
                tmuxSessionName: tmuxSessionName
            )

        case .tmuxOnly(let sessionName):
            return focusTmuxOnly(codexSession: codexSession, sessionName: sessionName)

        case .editor, .unknown:
            return focusFallback(codexSession: codexSession)
        }
    }

    // MARK: - Environment Resolution

    /// Public method for icon display (used by AppDelegate)
    static func resolveEnvironmentForIcon(session codexSession: CodexSession) -> FocusEnvironment {
        return resolveEnvironment(for: codexSession)
    }

    /// Resolve FocusEnvironment from CodexSession
    private static func resolveEnvironment(for codexSession: CodexSession) -> FocusEnvironment {
        // Get tmux info
        let hasTmux = codexSession.tmuxSession != nil
        let tmuxSessionName = codexSession.tmuxSession

        // Priority 1: terminalApp from CodexObserver
        if let terminalApp = codexSession.terminalApp?.lowercased() {
            switch terminalApp {
            case "ghostty":
                let tabIndex = tmuxSessionName.flatMap { GhosttyHelper.getTabIndexByTitle($0) }
                return .ghostty(hasTmux: hasTmux, tabIndex: tabIndex, tmuxSessionName: tmuxSessionName)
            case "iterm.app":
                let tabIndex = tmuxSessionName.flatMap { ITerm2Helper.getTabIndexByName($0) }
                    ?? codexSession.tty.flatMap { ITerm2Helper.getTabIndexByTTY($0) }
                return .iterm2(hasTmux: hasTmux, tabIndex: tabIndex, tmuxSessionName: tmuxSessionName)
            case "apple_terminal":
                return .terminal(hasTmux: hasTmux, tmuxSessionName: tmuxSessionName)
            default:
                break
            }
        }

        // Priority 2: tmux detection with running terminal check
        if hasTmux {
            // Try real-time detection from tmux client
            if let sessionName = tmuxSessionName,
               let detected = TmuxHelper.getClientTerminalInfo(for: sessionName)?.lowercased() {
                switch detected {
                case "ghostty":
                    let tabIndex = GhosttyHelper.getTabIndexByTitle(sessionName)
                    return .ghostty(hasTmux: true, tabIndex: tabIndex, tmuxSessionName: sessionName)
                case "iterm.app":
                    let tabIndex = ITerm2Helper.getTabIndexByName(sessionName)
                    return .iterm2(hasTmux: true, tabIndex: tabIndex, tmuxSessionName: sessionName)
                case "apple_terminal":
                    return .terminal(hasTmux: true, tmuxSessionName: sessionName)
                default:
                    break
                }
            }

            // Check running terminals
            if GhosttyHelper.isRunning,
               let name = tmuxSessionName,
               let tabIndex = GhosttyHelper.getTabIndexByTitle(name) {
                return .ghostty(hasTmux: true, tabIndex: tabIndex, tmuxSessionName: name)
            }
            if ITerm2Helper.isRunning, let name = tmuxSessionName {
                let tabIndex = ITerm2Helper.getTabIndexByName(name)
                return .iterm2(hasTmux: true, tabIndex: tabIndex, tmuxSessionName: name)
            }

            return .tmuxOnly(sessionName: tmuxSessionName ?? "unknown")
        }

        // Priority 3: Non-tmux - try TTY lookup
        if let tty = codexSession.tty {
            if ITerm2Helper.isRunning,
               let tabIndex = ITerm2Helper.getTabIndexByTTY(tty) {
                return .iterm2(hasTmux: false, tabIndex: tabIndex, tmuxSessionName: nil)
            }
        }

        // Check running terminals as fallback
        if GhosttyHelper.isRunning {
            return .ghostty(hasTmux: false, tabIndex: nil, tmuxSessionName: nil)
        }
        if ITerm2Helper.isRunning {
            return .iterm2(hasTmux: false, tabIndex: nil, tmuxSessionName: nil)
        }

        return .terminal(hasTmux: false, tmuxSessionName: nil)
    }

    // MARK: - Focus Methods

    private static func focusGhostty(
        codexSession: CodexSession,
        hasTmux: Bool,
        tabIndex: Int?,
        tmuxSessionName: String?
    ) -> FocusResult {
        guard GhosttyHelper.isRunning else {
            return .notRunning
        }

        // Select tmux pane if needed
        if hasTmux, let tty = codexSession.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            DebugLog.log("[CodexFocusHelper] Selected tmux pane for Codex")
        }

        // Activate Ghostty
        GhosttyHelper.activate()

        // Try to focus specific tab by index
        if let tabIndex = tabIndex {
            if GhosttyHelper.focusTabByIndex(tabIndex) {
                DebugLog.log("[CodexFocusHelper] Focused Ghostty tab \(tabIndex)")
                return .success
            }
        }

        // Try by tmux session name
        if let name = tmuxSessionName {
            if GhosttyHelper.focusSession(name) {
                DebugLog.log("[CodexFocusHelper] Focused Ghostty tab by tmux name '\(name)'")
                return .success
            }
        }

        // Try by project name
        if GhosttyHelper.focusSession(codexSession.projectName) {
            DebugLog.log("[CodexFocusHelper] Focused Ghostty tab by project '\(codexSession.projectName)'")
            return .success
        }

        return hasTmux ? .partialSuccess(reason: "tmux pane selected, Ghostty activated") : .success
    }

    private static func focusITerm2(
        codexSession: CodexSession,
        hasTmux: Bool,
        tabIndex: Int?,
        tmuxSessionName: String?
    ) -> FocusResult {
        guard ITerm2Helper.isRunning else {
            return .notRunning
        }

        // Select tmux pane if needed
        if hasTmux, let tty = codexSession.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            DebugLog.log("[CodexFocusHelper] Selected tmux pane for Codex")
        }

        // Activate iTerm2
        ITerm2Helper.activate()

        // Try by TTY first (most reliable)
        if let tty = codexSession.tty {
            if ITerm2Helper.focusSessionByTTY(tty) {
                DebugLog.log("[CodexFocusHelper] Focused iTerm2 by TTY '\(tty)'")
                return .success
            }
        }

        // Try by tmux session name
        if let name = tmuxSessionName {
            if ITerm2Helper.focusSessionByName(name) {
                DebugLog.log("[CodexFocusHelper] Focused iTerm2 by tmux name '\(name)'")
                return .success
            }
        }

        // Try by project name
        if ITerm2Helper.focusSessionByName(codexSession.projectName) {
            DebugLog.log("[CodexFocusHelper] Focused iTerm2 by project '\(codexSession.projectName)'")
            return .success
        }

        return hasTmux ? .partialSuccess(reason: "tmux pane selected, iTerm2 activated") : .success
    }

    private static func focusTerminal(
        codexSession: CodexSession,
        hasTmux: Bool,
        tmuxSessionName: String?
    ) -> FocusResult {
        // Select tmux pane if needed
        if hasTmux, let tty = codexSession.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            DebugLog.log("[CodexFocusHelper] Selected tmux pane for Codex")
        }

        // Activate Terminal.app
        TerminalAppController.shared.activate()

        return hasTmux ? .partialSuccess(reason: "tmux pane selected, Terminal activated") : .success
    }

    private static func focusTmuxOnly(codexSession: CodexSession, sessionName: String) -> FocusResult {
        // Select tmux pane
        if let tty = codexSession.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            DebugLog.log("[CodexFocusHelper] Selected tmux pane '\(sessionName)'")
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

    private static func focusFallback(codexSession: CodexSession) -> FocusResult {
        // Try tmux pane selection first
        var tmuxSelected = false
        if let tty = codexSession.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            tmuxSelected = true
        }

        // Activate any running terminal
        if GhosttyHelper.isRunning {
            GhosttyController.shared.activate()
            return .partialSuccess(reason: tmuxSelected ? "tmux pane selected, Ghostty activated" : "Ghostty activated as fallback")
        }
        if ITerm2Helper.isRunning {
            ITerm2Controller.shared.activate()
            return .partialSuccess(reason: tmuxSelected ? "tmux pane selected, iTerm2 activated" : "iTerm2 activated as fallback")
        }
        if TerminalAppController.shared.isRunning {
            TerminalAppController.shared.activate()
            return .partialSuccess(reason: tmuxSelected ? "tmux pane selected, Terminal activated" : "Terminal activated as fallback")
        }

        return .notFound(hint: "No running terminal found")
    }
}
