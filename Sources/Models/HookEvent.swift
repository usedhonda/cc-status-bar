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

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case tty
        case hookEventName = "hook_event_name"
        case notificationType = "notification_type"
    }
}
