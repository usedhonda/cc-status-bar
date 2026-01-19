import Foundation

struct Session: Codable, Identifiable {
    let sessionId: String
    let cwd: String
    let tty: String?
    var status: SessionStatus
    let createdAt: Date
    var updatedAt: Date
    var ghosttyTabIndex: Int?  // Bind-on-start: tab index at session start

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
    /// e.g., "Ghostty/tmux", "iTerm2", "Ghostty"
    var environmentLabel: String {
        let tmuxPane = tty.flatMap { TmuxHelper.getPaneInfo(for: $0) }

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
    }
}
