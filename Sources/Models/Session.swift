import Foundation

enum WaitingReason: String, Codable {
    case permissionPrompt = "permission_prompt"  // Red - permission/choice waiting
    case stop = "stop"                           // Yellow - command completion waiting
    case unknown = "unknown"                     // Yellow - legacy/unknown reason
}

struct Session: Codable, Identifiable {
    let sessionId: String
    let cwd: String
    let tty: String?
    var status: SessionStatus
    let createdAt: Date
    var updatedAt: Date
    var ghosttyTabIndex: Int?  // Bind-on-start: tab index at session start
    var termProgram: String?   // TERM_PROGRAM environment variable (legacy, kept for compatibility)
    var actualTermProgram: String?  // Actual terminal when inside tmux (detected from client parent)
    var editorBundleID: String?  // Detected editor bundle ID via PPID chain (e.g., "com.todesktop.230313mzl4w4u92" for Cursor)
    var editorPID: pid_t?  // Editor process ID for direct activation (reliable for multiple instances)
    var waitingReason: WaitingReason?  // Reason for waitingInput status (permissionPrompt=red, stop/unknown=yellow)
    var isToolRunning: Bool?  // true during PreToolUse..PostToolUse (show spinner)
    var isAcknowledged: Bool?  // true if user has seen this waiting session (show as green)

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
    /// Delegates to EnvironmentResolver for single source of truth
    var environmentLabel: String {
        EnvironmentResolver.shared.resolve(session: self).displayName
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
        case actualTermProgram = "actual_term_program"
        case editorBundleID = "editor_bundle_id"
        case editorPID = "editor_pid"
        case waitingReason = "waiting_reason"
        case isToolRunning = "is_tool_running"
        case isAcknowledged = "is_acknowledged"
    }
}
