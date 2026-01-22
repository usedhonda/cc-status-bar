import Foundation

/// Resolved focus environment for a session
/// Single source of truth for environment detection
enum FocusEnvironment {
    case editor(bundleID: String, pid: pid_t?, hasTmux: Bool, tmuxSessionName: String?)
    case ghostty(hasTmux: Bool, tabIndex: Int?, tmuxSessionName: String?)
    case iterm2(hasTmux: Bool, tabIndex: Int?, tmuxSessionName: String?)
    case terminal(hasTmux: Bool, tmuxSessionName: String?)
    case tmuxOnly(sessionName: String)
    case unknown

    var displayName: String {
        switch self {
        case .editor(let bundleID, _, let hasTmux, _):
            let name = EditorDetector.shared.displayName(for: bundleID) ?? bundleID
            return hasTmux ? "\(name)/tmux" : name
        case .ghostty(let hasTmux, _, _):
            return hasTmux ? "Ghostty/tmux" : "Ghostty"
        case .iterm2(let hasTmux, _, _):
            return hasTmux ? "iTerm2/tmux" : "iTerm2"
        case .terminal(let hasTmux, _):
            return hasTmux ? "Terminal/tmux" : "Terminal"
        case .tmuxOnly:
            return "tmux"
        case .unknown:
            return "Terminal"
        }
    }

    var hasTmux: Bool {
        switch self {
        case .editor(_, _, let hasTmux, _): return hasTmux
        case .ghostty(let hasTmux, _, _): return hasTmux
        case .iterm2(let hasTmux, _, _): return hasTmux
        case .terminal(let hasTmux, _): return hasTmux
        case .tmuxOnly: return true
        case .unknown: return false
        }
    }

    var tmuxSessionName: String? {
        switch self {
        case .editor(_, _, _, let name): return name
        case .ghostty(_, _, let name): return name
        case .iterm2(_, _, let name): return name
        case .terminal(_, let name): return name
        case .tmuxOnly(let name): return name
        case .unknown: return nil
        }
    }
}

/// Single source of truth for environment detection
/// Resolves session properties into a concrete FocusEnvironment
final class EnvironmentResolver {
    static let shared = EnvironmentResolver()
    private init() {}

    /// Resolve the focus environment for a session
    /// - Parameter session: The session to analyze
    /// - Returns: Resolved FocusEnvironment with all necessary information
    func resolve(session: Session) -> FocusEnvironment {
        // Get tmux info once
        let tmuxPane = session.tty.flatMap { TmuxHelper.getPaneInfo(for: $0) }
        let hasTmux = tmuxPane != nil
        let tmuxSessionName = tmuxPane?.session

        // Priority 1: Editor (detected via PPID chain)
        if let bundleID = session.editorBundleID {
            return .editor(
                bundleID: bundleID,
                pid: session.editorPID,
                hasTmux: hasTmux,
                tmuxSessionName: tmuxSessionName
            )
        }

        // Priority 2: actualTermProgram (detected from tmux client's parent process)
        // Note: Real-time detection moved to FocusManager for performance
        if let actualProg = session.actualTermProgram?.lowercased() {
            switch actualProg {
            case "ghostty":
                // Use stored tabIndex, or dynamically find by tmux session name
                let tabIndex = session.ghosttyTabIndex ?? tmuxSessionName.flatMap { GhosttyHelper.getTabIndexByTitle($0) }
                return .ghostty(
                    hasTmux: hasTmux,
                    tabIndex: tabIndex,
                    tmuxSessionName: tmuxSessionName
                )
            case "iterm.app":
                // tmux: search by session name, non-tmux: search by TTY
                let tabIndex = tmuxSessionName.flatMap { ITerm2Helper.getTabIndexByName($0) }
                    ?? session.tty.flatMap { ITerm2Helper.getTabIndexByTTY($0) }
                return .iterm2(
                    hasTmux: hasTmux,
                    tabIndex: tabIndex,
                    tmuxSessionName: tmuxSessionName
                )
            case "apple_terminal":
                return .terminal(
                    hasTmux: hasTmux,
                    tmuxSessionName: tmuxSessionName
                )
            default:
                break
            }
        }

        // Priority 3: TERM_PROGRAM detection (for non-tmux sessions)
        if let prog = session.termProgram?.lowercased() {
            switch prog {
            case "ghostty":
                // Use stored tabIndex, or dynamically find by tmux session name
                let tabIndex = session.ghosttyTabIndex ?? tmuxSessionName.flatMap { GhosttyHelper.getTabIndexByTitle($0) }
                return .ghostty(
                    hasTmux: hasTmux,
                    tabIndex: tabIndex,
                    tmuxSessionName: tmuxSessionName
                )
            case "iterm.app":
                // tmux: search by session name, non-tmux: search by TTY
                let tabIndex = tmuxSessionName.flatMap { ITerm2Helper.getTabIndexByName($0) }
                    ?? session.tty.flatMap { ITerm2Helper.getTabIndexByTTY($0) }
                return .iterm2(
                    hasTmux: hasTmux,
                    tabIndex: tabIndex,
                    tmuxSessionName: tmuxSessionName
                )
            case "apple_terminal":
                return .terminal(
                    hasTmux: hasTmux,
                    tmuxSessionName: tmuxSessionName
                )
            case "zed":
                if let bundleID = EditorDetector.shared.bundleID(for: "Zed") {
                    return .editor(
                        bundleID: bundleID,
                        pid: nil,
                        hasTmux: hasTmux,
                        tmuxSessionName: tmuxSessionName
                    )
                }
            default:
                break
            }
        }

        // Priority 4: Detect terminal by running state (with tmux)
        if hasTmux {
            // Check if Ghostty has a tab with this tmux session name
            if GhosttyHelper.isRunning,
               let name = tmuxSessionName,
               let tabIndex = GhosttyHelper.getTabIndexByTitle(name) {
                return .ghostty(hasTmux: true, tabIndex: tabIndex, tmuxSessionName: name)
            }
            // Check if iTerm2 is running
            if ITerm2Helper.isRunning, let name = tmuxSessionName {
                let tabIndex = ITerm2Helper.getTabIndexByName(name)
                return .iterm2(hasTmux: true, tabIndex: tabIndex, tmuxSessionName: name)
            }
            // tmux only (no known terminal)
            return .tmuxOnly(sessionName: tmuxSessionName ?? "unknown")
        }

        // Priority 5: Non-tmux detection - identify terminal by TTY lookup
        // Try iTerm2 TTY lookup first (most reliable for non-tmux)
        if ITerm2Helper.isRunning,
           let tty = session.tty,
           let tabIndex = ITerm2Helper.getTabIndexByTTY(tty) {
            return .iterm2(hasTmux: false, tabIndex: tabIndex, tmuxSessionName: nil)
        }
        // Then check Ghostty
        if session.ghosttyTabIndex != nil || GhosttyHelper.isRunning {
            return .ghostty(
                hasTmux: false,
                tabIndex: session.ghosttyTabIndex,
                tmuxSessionName: nil
            )
        }

        // Fallback: Terminal.app or unknown
        return .terminal(hasTmux: false, tmuxSessionName: nil)
    }
}
