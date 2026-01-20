import Foundation

enum HookEventName: String, Codable {
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case notification = "Notification"
    case stop = "Stop"
    case userPromptSubmit = "UserPromptSubmit"
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
}

struct HookEvent: Codable {
    let sessionId: String
    let cwd: String
    var tty: String?
    let hookEventName: HookEventName
    let notificationType: String?
    let message: String?  // Notification message (used as fallback for permission detection)
    var termProgram: String?  // Captured from TERM_PROGRAM environment variable (legacy)
    var actualTermProgram: String?  // Actual terminal when inside tmux (detected from client parent)
    var editorBundleID: String?  // Detected editor bundle ID via PPID chain
    var editorPID: Int32?  // Editor process ID for direct activation

    /// Check if this is a permission prompt notification
    /// Uses notification_type first, falls back to message content check (workaround for Claude Code bug)
    var isPermissionPrompt: Bool {
        if notificationType == "permission_prompt" {
            return true
        }
        // Fallback: check message content (workaround for missing notification_type)
        if let message = message?.lowercased() {
            return message.contains("permission")
        }
        return false
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case tty
        case hookEventName = "hook_event_name"
        case notificationType = "notification_type"
        case message
        case termProgram = "term_program"
        case actualTermProgram = "actual_term_program"
        case editorBundleID = "editor_bundle_id"
        case editorPID = "editor_pid"
    }
}
