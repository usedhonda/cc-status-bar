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
        let isTmux = tty.flatMap { TmuxHelper.getPaneInfo(for: $0) } != nil

        // Detect terminal app
        let terminal: String
        if ghosttyTabIndex != nil || GhosttyHelper.isRunning {
            terminal = "Ghostty"
        } else if ITerm2Helper.isRunning {
            terminal = "iTerm2"
        } else {
            terminal = "Terminal"
        }

        return isTmux ? "\(terminal)/tmux" : terminal
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
