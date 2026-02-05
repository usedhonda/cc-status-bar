import Foundation

/// Status of a Codex session
enum CodexStatus: String, Codable {
    case running
    case waitingInput = "waiting_input"
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

        statusByCwd[cwd] = CodexSessionStatus(
            status: .waitingInput,
            lastEventAt: now,
            threadId: threadId
        )

        DebugLog.log("[CodexStatusReceiver] Codex waiting_input: \(cwd)")

        // Invalidate CodexObserver cache to trigger WebSocket update
        CodexObserver.invalidateCache()

        // Broadcast update to WebSocket clients
        Task {
            if let codexSession = CodexObserver.getCodexSession(for: cwd) {
                let event = WebSocketEvent(
                    type: .sessionUpdated,
                    session: WebSocketManager.shared.codexSessionToDict(codexSession)
                )
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
        }

        return statusByCwd[cwd]
    }

    /// Remove status tracking for a cwd (when session ends)
    func removeStatus(for cwd: String) {
        statusByCwd.removeValue(forKey: cwd)
    }

    /// Clear all status tracking
    func clearAll() {
        statusByCwd.removeAll()
    }
}

/// Status tracking for a single Codex session
struct CodexSessionStatus {
    var status: CodexStatus
    var lastEventAt: Date
    var threadId: String?
}
