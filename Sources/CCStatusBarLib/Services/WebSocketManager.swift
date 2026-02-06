import Foundation
import Combine
@preconcurrency import Swifter

/// WebSocket event types for iOS app communication
enum WebSocketEventType: String {
    case sessionsList = "sessions.list"
    case sessionAdded = "session.added"
    case sessionUpdated = "session.updated"
    case sessionRemoved = "session.removed"
    case hostInfo = "host_info"
}

/// WebSocket event payload
struct WebSocketEvent {
    let type: WebSocketEventType
    let sessions: [[String: Any]]?
    let session: [String: Any]?
    let sessionId: String?  // For session.removed
    let icons: [String: String]?  // For sessions.list
    let icon: String?  // For session.added (new terminal type only)
    let addresses: [HostAddress]?  // For host_info

    init(
        type: WebSocketEventType,
        sessions: [[String: Any]]? = nil,
        session: [String: Any]? = nil,
        sessionId: String? = nil,
        icons: [String: String]? = nil,
        icon: String? = nil,
        addresses: [HostAddress]? = nil
    ) {
        self.type = type
        self.sessions = sessions
        self.session = session
        self.sessionId = sessionId
        self.icons = icons
        self.icon = icon
        self.addresses = addresses
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
        if let addresses = addresses {
            dict["addresses"] = addresses.map { ["interface": $0.interface, "ip": $0.ip] }
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
    private var previousCodexIDs = Set<String>()  // Track Codex sessions by unique id
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

        // Send host_info with all available IP addresses (for smart IP selection)
        let addresses = NetworkHelper.shared.getAllAddressesWithInterface()
        let hostInfoEvent = WebSocketEvent(type: .hostInfo, addresses: addresses)
        sendToClient(session, event: hostInfoEvent)
        DebugLog.log("[WebSocketManager] Sent host_info with \(addresses.count) addresses")

        // Send initial session list with icons (both Claude Code and Codex)
        let claudeSessions = SessionStore.shared.getSessions()
        let codexSessions = CodexObserver.getActiveSessions()
        let codexSessionList = Array(codexSessions.values).sorted { $0.pid < $1.pid }

        var sessionsData = claudeSessions.map { claudeSessionToDict($0) }
        sessionsData += codexSessionList.map { codexSessionToDict($0) }

        let icons = generateIcons(claudeSessions: claudeSessions, codexSessions: codexSessionList)
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

        // --- Claude Code sessions ---

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

                let event = WebSocketEvent(type: .sessionAdded, session: claudeSessionToDict(session), icon: icon)
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
                let event = WebSocketEvent(type: .sessionUpdated, session: claudeSessionToDict(session))
                broadcast(event: event)
            }
        }

        previousSessions = currentSessionsById

        // --- Codex sessions ---
        let currentCodexSessions = CodexObserver.getActiveSessions()
        let currentCodexIDs = Set(currentCodexSessions.keys)

        // Detect added Codex sessions
        for (id, codexSession) in currentCodexSessions {
            if !previousCodexIDs.contains(id) {
                // Check if this is a new terminal type
                let terminalName = codexSession.terminalApp ?? "Codex"
                let isNewTerminalType = !knownTerminalTypes.contains(terminalName)
                var icon: String? = nil

                if isNewTerminalType {
                    knownTerminalTypes.insert(terminalName)
                    // Get icon for the detected terminal
                    if let terminalApp = codexSession.terminalApp {
                        icon = IconManager.shared.terminalIconBase64(for: terminalApp, size: 64)
                    }
                }

                let event = WebSocketEvent(type: .sessionAdded, session: codexSessionToDict(codexSession), icon: icon)
                broadcast(event: event)
            }
        }

        // Detect removed Codex sessions
        for id in previousCodexIDs {
            if !currentCodexIDs.contains(id) {
                let event = WebSocketEvent(type: .sessionRemoved, sessionId: id)
                broadcast(event: event)
            }
        }

        previousCodexIDs = currentCodexIDs
    }

    /// Convert Claude Code session to dictionary for WebSocket output
    private func claudeSessionToDict(_ session: Session) -> [String: Any] {
        var dict: [String: Any] = [
            "type": "claude_code",
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

    /// Convert Codex session to dictionary for WebSocket output
    /// This method is called from CodexStatusReceiver, so it must be accessible
    func codexSessionToDict(_ session: CodexSession) -> [String: Any] {
        // Get status from CodexStatusReceiver
        let status = CodexStatusReceiver.shared.getStatus(for: session.cwd)
        let attentionLevel = status == .waitingInput ? 1 : 0  // yellow or green

        // Use detected terminal app, or fallback to "Codex"
        let terminalName = session.terminalApp ?? "Codex"

        var dict: [String: Any] = [
            "type": "codex",
            "id": "codex:\(session.pid)",
            "pid": session.pid,
            "project": session.projectName,
            "cwd": session.cwd,
            "status": status.rawValue,
            "started_at": ISO8601DateFormatter().string(from: session.startedAt),
            "attention_level": attentionLevel,
            "terminal": terminalName
        ]

        if let sessionId = session.sessionId {
            dict["session_id"] = sessionId
        }

        // Add TTY if available
        if let tty = session.tty {
            dict["tty"] = tty
        }

        // Add tmux info if available
        if let tmuxSession = session.tmuxSession,
           let tmuxWindow = session.tmuxWindow,
           let tmuxPane = session.tmuxPane {
            dict["tmux"] = [
                "session": tmuxSession,
                "window": tmuxWindow,
                "pane": tmuxPane,
                "attach_command": "tmux attach -t \(tmuxSession):\(tmuxWindow).\(tmuxPane)",
                "is_attached": TmuxHelper.isSessionAttached(tmuxSession)
            ]
        }

        return dict
    }

    /// Generate icons dictionary for all terminal types in sessions
    private func generateIcons(claudeSessions: [Session], codexSessions: [CodexSession]) -> [String: String] {
        var icons: [String: String] = [:]

        // Claude Code session icons
        for session in claudeSessions {
            let terminalName = session.environmentLabel
            if icons[terminalName] == nil {
                let env = EnvironmentResolver.shared.resolve(session: session)
                if let base64 = IconManager.shared.iconBase64(for: env, size: 64) {
                    icons[terminalName] = base64
                }
                knownTerminalTypes.insert(terminalName)
            }
        }

        // Codex session icons (same as Claude Code - use detected terminal app)
        for session in codexSessions {
            if let terminalApp = session.terminalApp, icons[terminalApp] == nil {
                // Use detected terminal icon
                if let base64 = IconManager.shared.terminalIconBase64(for: terminalApp, size: 64) {
                    icons[terminalApp] = base64
                }
                knownTerminalTypes.insert(terminalApp)
            }
        }

        // Fallback Codex marker (if any session has no detected terminal)
        if codexSessions.contains(where: { $0.terminalApp == nil }) {
            knownTerminalTypes.insert("Codex")
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
