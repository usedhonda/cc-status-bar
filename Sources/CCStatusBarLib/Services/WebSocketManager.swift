import Foundation
import Combine
@preconcurrency import Swifter

/// WebSocket event types for iOS app communication
enum WebSocketEventType: String {
    case sessionsList = "sessions.list"
    case sessionAdded = "session.added"
    case sessionUpdated = "session.updated"
    case sessionRemoved = "session.removed"
    case sessionProgress = "session.progress"
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

    // Progress broadcasting
    private var progressTimer: DispatchSourceTimer?
    private var lastProgressHashes: [String: Int] = [:]

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
        let ttyMigrations = Self.detectTTYMigrations(previous: previousSessions, current: sessions)
        let migratedPreviousIDs = Set(ttyMigrations.values)

        // --- Claude Code sessions ---

        // Detect added sessions
        for session in sessions {
            if previousSessions[session.id] == nil {
                // Session ID changed on same TTY: treat as update continuity.
                if let previousID = ttyMigrations[session.id],
                   let previous = previousSessions[previousID] {
                    if session != previous {
                        let event = WebSocketEvent(
                            type: .sessionUpdated,
                            session: buildUpdatedSessionDict(current: session, previous: previous)
                        )
                        broadcast(event: event)
                    }
                    continue
                }

                // Check if this is a new terminal type
                let terminalName = session.environmentLabel
                let isNewTerminalType = !knownTerminalTypes.contains(terminalName)
                var icon: String? = nil

                if isNewTerminalType {
                    knownTerminalTypes.insert(terminalName)
                    let env = EnvironmentResolver.shared.resolve(session: session)
                    icon = IconManager.shared.iconBase64(for: env, size: 64)
                }

                let event = WebSocketEvent(
                    type: .sessionAdded,
                    session: buildAddedSessionDict(session),
                    icon: icon
                )
                broadcast(event: event)
            }
        }

        // Detect removed sessions
        for (id, _) in previousSessions {
            if currentSessionsById[id] == nil && !migratedPreviousIDs.contains(id) {
                let event = WebSocketEvent(type: .sessionRemoved, sessionId: id)
                broadcast(event: event)
            }
        }

        // Detect updated sessions
        for session in sessions {
            if let previous = previousSessions[session.id], session != previous {
                let event = WebSocketEvent(
                    type: .sessionUpdated,
                    session: buildUpdatedSessionDict(current: session, previous: previous)
                )
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

    private func buildUpdatedSessionDict(current: Session, previous: Session) -> [String: Any] {
        var dict = claudeSessionToDict(current)
        // Attach pane capture on waiting_input transition
        if previous.status == .running && current.status == .waitingInput {
            if let tty = current.tty, let paneInfo = TmuxHelper.getRemoteAccessInfo(for: tty) {
                let target = paneInfo.targetSpecifier
                if let capture = TmuxHelper.capturePane(target: target, socketPath: paneInfo.socketPath) {
                    dict["pane_capture"] = capture
                }
            }
        }
        return dict
    }

    private func buildAddedSessionDict(_ session: Session) -> [String: Any] {
        var dict = claudeSessionToDict(session)
        // Also include pane capture on initial waiting_input add.
        if session.status == .waitingInput,
           let tty = session.tty,
           let paneInfo = TmuxHelper.getRemoteAccessInfo(for: tty) {
            let target = paneInfo.targetSpecifier
            if let capture = TmuxHelper.capturePane(target: target, socketPath: paneInfo.socketPath) {
                dict["pane_capture"] = capture
            }
        }
        return dict
    }

    /// Detect session ID migration on the same TTY.
    /// Returns mapping: new session id -> previous session id.
    nonisolated static func detectTTYMigrations(previous: [String: Session], current: [Session]) -> [String: String] {
        let currentIDs = Set(current.map(\.id))
        var previousByTTY: [String: String] = [:]
        var migrations: [String: String] = [:]

        for (id, session) in previous {
            guard let tty = session.tty, !tty.isEmpty else { continue }
            previousByTTY[tty] = id
        }

        for session in current {
            guard let tty = session.tty, !tty.isEmpty else { continue }
            guard let oldID = previousByTTY[tty] else { continue }
            guard oldID != session.id else { continue }
            // Migration means old id disappeared from current snapshot.
            guard !currentIDs.contains(oldID) else { continue }
            migrations[session.id] = oldID
        }

        return migrations
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
            if session.waitingReason == .askUserQuestion {
                if let text = session.questionText {
                    dict["question_text"] = text
                }
                if let options = session.questionOptions {
                    dict["question_options"] = options
                }
                if let selected = session.questionSelected {
                    dict["question_selected"] = selected
                }
            }
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
                "is_attached": TmuxHelper.isSessionAttached(remoteInfo.sessionName, socketPath: remoteInfo.socketPath)
            ]
        }

        return dict
    }

    /// Convert Codex session to dictionary for WebSocket output
    /// This method is called from CodexStatusReceiver, so it must be accessible
    func codexSessionToDict(_ session: CodexSession) -> [String: Any] {
        // Get status from CodexStatusReceiver
        let status = CodexStatusReceiver.shared.getStatus(for: session.cwd)
        let waitingReason = CodexStatusReceiver.shared.getWaitingReason(for: session.cwd)
        let attentionLevel: Int
        if status == .waitingInput {
            attentionLevel = (waitingReason == .permissionPrompt) ? 2 : 1  // red or yellow
        } else {
            attentionLevel = 0
        }

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

        if status == .waitingInput {
            dict["waiting_reason"] = (waitingReason ?? .unknown).rawValue
        }

        // Add TTY if available
        if let tty = session.tty {
            dict["tty"] = tty
        }

        // Add tmux info if available
        if let tmuxSession = session.tmuxSession,
           let tmuxWindow = session.tmuxWindow,
           let tmuxPane = session.tmuxPane {
            let attachCmd = TmuxAttachCommand.buildFull(
                sessionName: tmuxSession, window: tmuxWindow, pane: tmuxPane, socketPath: session.tmuxSocketPath
            )
            dict["tmux"] = [
                "session": tmuxSession,
                "window": tmuxWindow,
                "pane": tmuxPane,
                "attach_command": attachCmd,
                "is_attached": TmuxHelper.isSessionAttached(tmuxSession, socketPath: session.tmuxSocketPath)
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

    // MARK: - Progress Broadcasting

    /// Start periodic progress broadcasting for running sessions
    func startProgressBroadcasting() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.broadcastProgress() }
        }
        timer.resume()
        progressTimer = timer
    }

    private func broadcastProgress() {
        let allSessions = SessionStore.shared.getSessions().filter { $0.status == .running }
        let codexSessions = Array(CodexObserver.getActiveSessions().values).filter {
            CodexStatusReceiver.shared.getStatus(for: $0.cwd) == .running
        }

        // CC sessions
        for session in allSessions {
            guard let tty = session.tty,
                  let paneInfo = TmuxHelper.getRemoteAccessInfo(for: tty) else { continue }
            let target = paneInfo.targetSpecifier
            guard let capture = TmuxHelper.capturePane(target: target, socketPath: paneInfo.socketPath) else { continue }
            let hash = capture.hashValue
            if lastProgressHashes[session.id] == hash { continue }
            lastProgressHashes[session.id] = hash

            var dict = claudeSessionToDict(session)
            dict["pane_capture"] = capture
            broadcast(event: WebSocketEvent(type: .sessionProgress, session: dict))
        }

        // Codex sessions
        for session in codexSessions {
            guard let tmuxSession = session.tmuxSession,
                  let tmuxWindow = session.tmuxWindow,
                  let tmuxPane = session.tmuxPane else { continue }
            let target = "\(tmuxSession):\(tmuxWindow).\(tmuxPane)"
            guard let capture = TmuxHelper.capturePane(target: target, socketPath: session.tmuxSocketPath) else { continue }
            let hash = capture.hashValue
            let key = "codex:\(session.pid)"
            if lastProgressHashes[key] == hash { continue }
            lastProgressHashes[key] = hash

            var dict = codexSessionToDict(session)
            dict["pane_capture"] = capture
            broadcast(event: WebSocketEvent(type: .sessionProgress, session: dict))
        }
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
