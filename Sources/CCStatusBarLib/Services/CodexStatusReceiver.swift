import Foundation

/// Status of a Codex session
enum CodexStatus: String, Codable {
    case running
    case waitingInput = "waiting_input"
}

/// Reason of Codex waiting_input for color distinction (red/yellow)
enum CodexWaitingReason: String, Codable {
    case permissionPrompt = "permission_prompt"  // red
    case stop = "stop"                           // yellow
    case unknown = "unknown"                     // yellow fallback
}

/// Tracks status received from Codex notify events
/// Provides cwd -> status mapping with timeout-based state machine
@MainActor
final class CodexStatusReceiver {
    static let shared = CodexStatusReceiver()

    // MARK: - Configuration

    /// Timeout after which waiting_input reverts to running (seconds)
    private let statusTimeout: TimeInterval = 30.0

    // MARK: - State

    /// cwd -> last event info
    private var statusByCwd: [String: CodexSessionStatus] = [:]

    private init() {}

    // MARK: - Event Handling

    /// Handle incoming Codex notify event
    /// - Parameter data: JSON data from POST body
    func handleEvent(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            DebugLog.log("[CodexStatusReceiver] Failed to parse event JSON")
            return
        }

        // Expected format: { "type": "agent-turn-complete", "cwd": "...", "thread-id": "..." }
        guard let eventType = json["type"] as? String else {
            DebugLog.log("[CodexStatusReceiver] Missing event type")
            return
        }

        let cwd = json["cwd"] as? String

        switch eventType {
        case "agent-turn-complete":
            handleAgentTurnComplete(cwd: cwd, json: json)
        default:
            DebugLog.log("[CodexStatusReceiver] Unknown event type: \(eventType)")
        }
    }

    private func handleAgentTurnComplete(cwd: String?, json: [String: Any]) {
        guard let cwd = cwd else {
            DebugLog.log("[CodexStatusReceiver] agent-turn-complete without cwd")
            return
        }

        let threadId = json["thread-id"] as? String
        let now = Date()
        let waitingReason = Self.inferWaitingReason(from: json)

        statusByCwd[cwd] = CodexSessionStatus(
            status: .waitingInput,
            waitingReason: waitingReason,
            lastEventAt: now,
            threadId: threadId
        )

        DebugLog.log("[CodexStatusReceiver] Codex waiting_input: \(cwd) reason=\(waitingReason.rawValue)")

        // Invalidate CodexObserver cache to trigger WebSocket update
        CodexObserver.invalidateCache()

        // Broadcast update to WebSocket clients (with pane capture for waiting_input)
        Task {
            if let codexSession = CodexObserver.getCodexSession(for: cwd) {
                var dict = WebSocketManager.shared.codexSessionToDict(codexSession)
                // Capture pane for waiting_input transition
                if let tmuxSession = codexSession.tmuxSession,
                   let tmuxWindow = codexSession.tmuxWindow,
                   let tmuxPane = codexSession.tmuxPane {
                    let target = "\(tmuxSession):\(tmuxWindow).\(tmuxPane)"
                    if let capture = TmuxHelper.capturePane(target: target, socketPath: codexSession.tmuxSocketPath) {
                        dict["pane_capture"] = capture
                    }
                }
                let event = WebSocketEvent(type: .sessionUpdated, session: dict)
                WebSocketManager.shared.broadcast(event: event)
            }
        }
    }

    // MARK: - Status Query

    /// Get effective status for a cwd (applies timeout logic)
    /// - Parameter cwd: Working directory
    /// - Returns: Current status or .running if unknown/timed out
    func getStatus(for cwd: String) -> CodexStatus {
        guard let sessionStatus = statusByCwd[cwd] else {
            return .running
        }

        // Check timeout
        let elapsed = Date().timeIntervalSince(sessionStatus.lastEventAt)
        if sessionStatus.status == .waitingInput && elapsed > statusTimeout {
            // Timed out, revert to running
            statusByCwd[cwd]?.status = .running
            statusByCwd[cwd]?.waitingReason = nil
            return .running
        }

        return sessionStatus.status
    }

    /// Get full status info for a cwd
    func getSessionStatus(for cwd: String) -> CodexSessionStatus? {
        guard let sessionStatus = statusByCwd[cwd] else {
            return nil
        }

        // Apply timeout
        let elapsed = Date().timeIntervalSince(sessionStatus.lastEventAt)
        if sessionStatus.status == .waitingInput && elapsed > statusTimeout {
            statusByCwd[cwd]?.status = .running
            statusByCwd[cwd]?.waitingReason = nil
        }

        return statusByCwd[cwd]
    }

    /// Get waiting reason for a cwd
    func getWaitingReason(for cwd: String) -> CodexWaitingReason? {
        guard let sessionStatus = getSessionStatus(for: cwd),
              sessionStatus.status == .waitingInput else {
            return nil
        }
        return sessionStatus.waitingReason ?? .unknown
    }

    /// Remove status tracking for a cwd (when session ends)
    func removeStatus(for cwd: String) {
        statusByCwd.removeValue(forKey: cwd)
    }

    /// Clear all status tracking
    func clearAll() {
        statusByCwd.removeAll()
    }

    // MARK: - Reason Inference

    /// Infer waiting reason from raw Codex notify payload.
    /// If no explicit permission/approval token is present, default to yellow (stop).
    static func inferWaitingReason(from json: [String: Any]) -> CodexWaitingReason {
        let permissionTokens = [
            "permission_prompt",
            "approval_required",
            "approval_request",
            "approval-request"
        ]

        if containsAnyToken(permissionTokens, in: json) {
            return .permissionPrompt
        }
        return .stop
    }

    private static func containsAnyToken(_ tokens: [String], in value: Any) -> Bool {
        switch value {
        case let string as String:
            let normalized = string.lowercased()
            return tokens.contains { normalized.contains($0) }
        case let dict as [String: Any]:
            for (key, nestedValue) in dict {
                if containsAnyToken(tokens, in: key) || containsAnyToken(tokens, in: nestedValue) {
                    return true
                }
            }
            return false
        case let array as [Any]:
            return array.contains { containsAnyToken(tokens, in: $0) }
        default:
            return false
        }
    }
}

/// Status tracking for a single Codex session
struct CodexSessionStatus {
    var status: CodexStatus
    var waitingReason: CodexWaitingReason?
    var lastEventAt: Date
    var threadId: String?
}
