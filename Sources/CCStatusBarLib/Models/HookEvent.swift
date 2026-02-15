import Foundation

struct HookQuestionOption: Codable {
    let label: String
    let description: String?
}

struct HookQuestionPayload: Codable {
    let text: String
    let options: [HookQuestionOption]
    let selectedIndex: Int?

    enum CodingKeys: String, CodingKey {
        case text
        case options
        case selectedIndex = "selected_index"
    }
}

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
    let toolName: String?  // Tool name for Notification payload (e.g. AskUserQuestion)
    let question: HookQuestionPayload?  // Structured AskUserQuestion payload
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

    var isAskUserQuestion: Bool {
        toolName == "AskUserQuestion"
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case tty
        case hookEventName = "hook_event_name"
        case notificationType = "notification_type"
        case message
        case toolName = "tool_name"
        case question
        case termProgram = "term_program"
        case actualTermProgram = "actual_term_program"
        case editorBundleID = "editor_bundle_id"
        case editorPID = "editor_pid"
    }
}
