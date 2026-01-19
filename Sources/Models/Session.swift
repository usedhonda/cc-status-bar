import Foundation

struct Session: Codable, Identifiable {
    let sessionId: String
    let cwd: String
    let tty: String?
    var status: SessionStatus
    let createdAt: Date
    var updatedAt: Date
    var ghosttyTabIndex: Int?  // Bind-on-start: tab index at session start
    var termProgram: String?   // TERM_PROGRAM environment variable (legacy, kept for compatibility)
    var editorBundleID: String?  // Detected editor bundle ID via PPID chain (e.g., "com.todesktop.230313mzl4w4u92" for Cursor)

    var id: String {
        tty.map { "\(sessionId):\($0)" } ?? sessionId
    }

    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var displayPath: String {
        cwd.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    /// Environment label showing terminal and tmux status
    /// e.g., "Ghostty/tmux", "iTerm2", "Ghostty", "VS Code", "Cursor", "Zed"
    var environmentLabel: String {
        let tmuxPane = tty.flatMap { TmuxHelper.getPaneInfo(for: $0) }
        let hasTmux = tmuxPane != nil

        // Priority 1: Use detected editor bundle ID (most accurate)
        if let bundleID = editorBundleID,
           let editorName = EditorDetector.shared.displayName(for: bundleID) {
            return hasTmux ? "\(editorName)/tmux" : editorName
        }

        // Priority 2: Fallback to TERM_PROGRAM for backward compatibility
        if let prog = termProgram?.lowercased() {
            switch prog {
            case "zed":
                return hasTmux ? "Zed/tmux" : "Zed"
            default:
                break
            }
        }

        // Terminal detection (Ghostty, iTerm2, etc.)
        if let pane = tmuxPane {
            // tmux session - check if Ghostty has a tab with this session name
            if GhosttyHelper.isRunning && GhosttyHelper.hasTabWithTitle(pane.session) {
                return "Ghostty/tmux"
            }
            // Check if iTerm2 is running for tmux
            if ITerm2Helper.isRunning {
                return "iTerm2/tmux"
            }
            return "tmux"
        }

        // Non-tmux: check specific evidence
        if ghosttyTabIndex != nil {
            return "Ghostty"
        }

        // Check if iTerm2 is running and this TTY belongs to it
        if ITerm2Helper.isRunning {
            return "iTerm2"
        }

        // No specific evidence - don't guess
        return "Terminal"
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case tty
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case ghosttyTabIndex = "ghostty_tab_index"
        case termProgram = "term_program"
        case editorBundleID = "editor_bundle_id"
    }
}
