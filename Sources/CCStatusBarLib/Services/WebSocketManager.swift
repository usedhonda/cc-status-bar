import Foundation
import Combine
@preconcurrency import Swifter

/// WebSocket event types for iOS app communication
enum WebSocketEventType: String {
    case connected
    case sessionAdded = "session.added"
    case sessionUpdated = "session.updated"
    case sessionRemoved = "session.removed"
}

/// WebSocket event payload
struct WebSocketEvent {
    let type: WebSocketEventType
    let sessions: [[String: Any]]?
    let session: [String: Any]?
    let timestamp: String

    init(type: WebSocketEventType, sessions: [[String: Any]]? = nil, session: [String: Any]? = nil) {
        self.type = type
        self.sessions = sessions
        self.session = session
        self.timestamp = ISO8601DateFormatter().string(from: Date())
    }

    func toJSON() -> String {
        var dict: [String: Any] = [
            "type": type.rawValue,
            "timestamp": timestamp
        ]
        if let sessions = sessions {
            dict["sessions"] = sessions
        }
        if let session = session {
            dict["session"] = session
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

/// Manages WebSocket connections for real-time session updates
/// Thread-safe using DispatchQueue for client management
@MainActor
final class WebSocketManager {
    static let shared = WebSocketManager()

    private var connectedClients = Set<WebSocketSession>()
    private let clientQueue = DispatchQueue(label: "com.ccstatusbar.websocket.clients")

    private var previousSessions: [String: Session] = [:]
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Client Management

    /// Subscribe a new WebSocket client
    func subscribe(_ session: WebSocketSession) {
        _ = clientQueue.sync {
            connectedClients.insert(session)
        }
        DebugLog.log("[WebSocketManager] Client connected (total: \(connectedClients.count))")

        // Send initial session list
        let sessions = SessionStore.shared.getSessions()
        let sessionsData = sessions.map { sessionToDict($0) }
        let event = WebSocketEvent(type: .connected, sessions: sessionsData)
        sendToClient(session, event: event)
    }

    /// Unsubscribe a WebSocket client
    func unsubscribe(_ session: WebSocketSession) {
        _ = clientQueue.sync {
            connectedClients.remove(session)
        }
        DebugLog.log("[WebSocketManager] Client disconnected (total: \(connectedClients.count))")
    }

    // MARK: - Session Observation

    /// Start observing session changes
    func observeSessions(_ publisher: Published<[Session]>.Publisher) {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.handleSessionsChanged(sessions)
            }
            .store(in: &cancellables)

        DebugLog.log("[WebSocketManager] Started observing sessions")
    }

    // MARK: - Broadcast

    /// Broadcast an event to all connected clients
    func broadcast(event: WebSocketEvent) {
        let clients: Set<WebSocketSession> = clientQueue.sync { connectedClients }

        guard !clients.isEmpty else { return }

        let json = event.toJSON()
        for client in clients {
            sendText(client, text: json)
        }

        DebugLog.log("[WebSocketManager] Broadcast \(event.type.rawValue) to \(clients.count) client(s)")
    }

    // MARK: - Private

    private func handleSessionsChanged(_ sessions: [Session]) {
        let currentSessionsById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        // Detect added sessions
        for session in sessions {
            if previousSessions[session.id] == nil {
                let event = WebSocketEvent(type: .sessionAdded, session: sessionToDict(session))
                broadcast(event: event)
            }
        }

        // Detect removed sessions
        for (id, session) in previousSessions {
            if currentSessionsById[id] == nil {
                let event = WebSocketEvent(type: .sessionRemoved, session: ["session_id": session.sessionId])
                broadcast(event: event)
            }
        }

        // Detect updated sessions
        for session in sessions {
            if let previous = previousSessions[session.id], session != previous {
                let event = WebSocketEvent(type: .sessionUpdated, session: sessionToDict(session))
                broadcast(event: event)
            }
        }

        previousSessions = currentSessionsById
    }

    private func sessionToDict(_ session: Session) -> [String: Any] {
        var dict: [String: Any] = [
            "session_id": session.sessionId,
            "project": session.projectName,
            "path": session.cwd,
            "status": session.status.rawValue,
            "updated_at": ISO8601DateFormatter().string(from: session.updatedAt),
            "is_acknowledged": session.isAcknowledged ?? false,
            "attention_level": attentionLevel(for: session)
        ]

        if let tty = session.tty {
            dict["tty"] = tty
        }

        if session.status == .waitingInput {
            dict["waiting_reason"] = session.waitingReason?.rawValue ?? "unknown"
        }

        if let isToolRunning = session.isToolRunning {
            dict["is_tool_running"] = isToolRunning
        }

        // Add tmux info if available
        if let tty = session.tty, let remoteInfo = TmuxHelper.getRemoteAccessInfo(for: tty) {
            dict["tmux"] = [
                "session": remoteInfo.sessionName,
                "window": remoteInfo.windowIndex,
                "pane": remoteInfo.paneIndex,
                "attach_command": remoteInfo.attachCommand,
                "is_attached": TmuxHelper.isSessionAttached(remoteInfo.sessionName)
            ]
        }

        return dict
    }

    /// Compute attention level: 0=green, 1=yellow, 2=red
    private func attentionLevel(for session: Session) -> Int {
        if session.status == .running || session.isAcknowledged == true {
            return 0  // green
        }
        if session.status == .waitingInput {
            return session.waitingReason == .permissionPrompt ? 2 : 1  // red or yellow
        }
        return 0  // stopped/unknown
    }

    private func sendToClient(_ client: WebSocketSession, event: WebSocketEvent) {
        let json = event.toJSON()
        sendText(client, text: json)
    }

    private func sendText(_ client: WebSocketSession, text: String) {
        // WebSocketSession.writeText is not thread-safe, dispatch to avoid crashes
        DispatchQueue.global(qos: .userInitiated).async {
            client.writeText(text)
        }
    }
}
