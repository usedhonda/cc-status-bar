import Foundation
import Combine
@preconcurrency import Swifter

/// WebSocket event types for iOS app communication
enum WebSocketEventType: String {
    case sessionsList = "sessions.list"
    case sessionAdded = "session.added"
    case sessionUpdated = "session.updated"
    case sessionRemoved = "session.removed"
}

/// WebSocket event payload
struct WebSocketEvent {
    let type: WebSocketEventType
    let sessions: [[String: Any]]?
    let session: [String: Any]?
    let sessionId: String?  // For session.removed
    let icons: [String: String]?  // For sessions.list
    let icon: String?  // For session.added (new terminal type only)

    init(
        type: WebSocketEventType,
        sessions: [[String: Any]]? = nil,
        session: [String: Any]? = nil,
        sessionId: String? = nil,
        icons: [String: String]? = nil,
        icon: String? = nil
    ) {
        self.type = type
        self.sessions = sessions
        self.session = session
        self.sessionId = sessionId
        self.icons = icons
        self.icon = icon
    }

    func toJSON() -> String {
        var dict: [String: Any] = [
            "type": type.rawValue
        ]
        if let sessions = sessions {
            dict["sessions"] = sessions
        }
        if let session = session {
            dict["session"] = session
        }
        if let sessionId = sessionId {
            dict["session_id"] = sessionId
        }
        if let icons = icons {
            dict["icons"] = icons
        }
        if let icon = icon {
            dict["icon"] = icon
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
    private var knownTerminalTypes = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Client Management

    /// Subscribe a new WebSocket client
    func subscribe(_ session: WebSocketSession) {
        _ = clientQueue.sync {
            connectedClients.insert(session)
        }
        DebugLog.log("[WebSocketManager] Client connected (total: \(connectedClients.count))")

        // Send initial session list with icons
        let sessions = SessionStore.shared.getSessions()
        let sessionsData = sessions.map { sessionToDict($0) }
        let icons = generateIcons(for: sessions)
        let event = WebSocketEvent(type: .sessionsList, sessions: sessionsData, icons: icons)
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
                // Check if this is a new terminal type
                let terminalName = session.environmentLabel
                let isNewTerminalType = !knownTerminalTypes.contains(terminalName)
                var icon: String? = nil

                if isNewTerminalType {
                    knownTerminalTypes.insert(terminalName)
                    let env = EnvironmentResolver.shared.resolve(session: session)
                    icon = IconManager.shared.iconBase64(for: env, size: 64)
                }

                let event = WebSocketEvent(type: .sessionAdded, session: sessionToDict(session), icon: icon)
                broadcast(event: event)
            }
        }

        // Detect removed sessions
        for (id, _) in previousSessions {
            if currentSessionsById[id] == nil {
                let event = WebSocketEvent(type: .sessionRemoved, sessionId: id)
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
            "id": session.id,
            "session_id": session.sessionId,
            "project": session.projectName,
            "cwd": session.cwd,
            "status": session.status.rawValue,
            "updated_at": ISO8601DateFormatter().string(from: session.updatedAt),
            "is_acknowledged": session.isAcknowledged ?? false,
            "attention_level": attentionLevel(for: session),
            "terminal": session.environmentLabel
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

    /// Generate icons dictionary for all terminal types in sessions
    private func generateIcons(for sessions: [Session]) -> [String: String] {
        var icons: [String: String] = [:]

        for session in sessions {
            let terminalName = session.environmentLabel
            if icons[terminalName] == nil {
                let env = EnvironmentResolver.shared.resolve(session: session)
                if let base64 = IconManager.shared.iconBase64(for: env, size: 64) {
                    icons[terminalName] = base64
                }
                knownTerminalTypes.insert(terminalName)
            }
        }

        return icons
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
