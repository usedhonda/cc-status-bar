import Foundation

/// Represents an active Codex CLI session
struct CodexSession: Equatable {
    let pid: pid_t
    let cwd: String
    let projectName: String
    let startedAt: Date

    /// Session ID from Codex session file (if found)
    var sessionId: String?

    init(pid: pid_t, cwd: String, sessionId: String? = nil) {
        self.pid = pid
        self.cwd = cwd
        self.projectName = URL(fileURLWithPath: cwd).lastPathComponent
        self.startedAt = Date()
        self.sessionId = sessionId
    }
}

/// Information about Codex session for WebSocket output
struct CodexInfo: Codable {
    let pid: pid_t
    let isActive: Bool
    let startedAt: Date?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case pid
        case isActive = "is_active"
        case startedAt = "started_at"
        case sessionId = "session_id"
    }
}
