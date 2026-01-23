import Foundation
import Swifter

/// Web server for remote session monitoring and access
/// Designed for access via Tailscale from mobile devices
final class WebServer {
    static let shared = WebServer()

    private var server: HttpServer?
    private(set) var actualPort: UInt16 = 0
    private let basePort: UInt16 = 8080
    private let maxPortAttempts = 10

    private init() {}

    // MARK: - Public API

    /// Start the web server, automatically finding an available port
    func start() throws {
        guard server == nil else {
            DebugLog.log("[WebServer] Already running on port \(actualPort)")
            return
        }

        let httpServer = HttpServer()

        // GET / - Web UI
        httpServer["/"] = { [weak self] _ in
            guard let self = self else { return .internalServerError }
            return .ok(.html(self.renderHTML()))
        }

        // GET /api/sessions - JSON API
        httpServer["/api/sessions"] = { [weak self] _ in
            guard let self = self else { return .internalServerError }
            return .ok(.json(self.sessionsToJSON()))
        }

        // WebSocket /ws/sessions - Real-time session updates
        httpServer["/ws/sessions"] = websocket(
            connected: { wsSession in
                Task { @MainActor in
                    WebSocketManager.shared.subscribe(wsSession)
                }
            },
            disconnected: { wsSession in
                Task { @MainActor in
                    WebSocketManager.shared.unsubscribe(wsSession)
                }
            }
        )

        // POST /api/sessions/:id/focus - Focus and acknowledge a session
        httpServer.POST["/api/sessions/:id/focus"] = { request in
            guard let sessionId = request.params[":id"] else {
                return .badRequest(.text("Missing session ID"))
            }

            Task { @MainActor in
                // Find session by ID (includes TTY in compound ID)
                guard let session = SessionStore.shared.getSessions().first(where: { $0.id == sessionId || $0.sessionId == sessionId }) else {
                    DebugLog.log("[WebServer] Focus: Session not found: \(sessionId)")
                    return
                }

                // Focus the terminal
                _ = FocusManager.shared.focus(session: session)

                // Acknowledge the session
                SessionStore.shared.acknowledgeSession(sessionId: session.sessionId, tty: session.tty)

                DebugLog.log("[WebServer] Focus: Focused and acknowledged session: \(session.projectName)")
            }

            return .ok(.json(["success": true, "session_id": sessionId]))
        }

        // GET /api/icons - Terminal icons as base64 PNG
        httpServer["/api/icons"] = { [weak self] _ in
            guard self != nil else { return .internalServerError }
            return .ok(.json(Self.iconsToJSON()))
        }

        // POST /api/sessions/:id/acknowledge - Acknowledge a session without focus
        httpServer.POST["/api/sessions/:id/acknowledge"] = { request in
            guard let sessionId = request.params[":id"] else {
                return .badRequest(.text("Missing session ID"))
            }

            Task { @MainActor in
                guard let session = SessionStore.shared.getSessions().first(where: { $0.id == sessionId || $0.sessionId == sessionId }) else {
                    DebugLog.log("[WebServer] Acknowledge: Session not found: \(sessionId)")
                    return
                }

                SessionStore.shared.acknowledgeSession(sessionId: session.sessionId, tty: session.tty)
                DebugLog.log("[WebServer] Acknowledge: Acknowledged session: \(session.projectName)")
            }

            return .ok(.json(["success": true, "session_id": sessionId]))
        }

        // Try ports starting from basePort
        var lastError: Error?
        for offset in 0..<maxPortAttempts {
            let port = basePort + UInt16(offset)
            do {
                try httpServer.start(port, forceIPv4: false, priority: .default)
                server = httpServer
                actualPort = port
                DebugLog.log("[WebServer] Started on port \(port)")
                return
            } catch {
                lastError = error
                DebugLog.log("[WebServer] Port \(port) unavailable, trying next...")
            }
        }

        // All ports failed
        throw lastError ?? WebServerError.noAvailablePort
    }

    /// Stop the web server
    func stop() {
        server?.stop()
        server = nil
        let port = actualPort
        actualPort = 0
        DebugLog.log("[WebServer] Stopped (was on port \(port))")
    }

    /// Check if server is running
    var isRunning: Bool {
        server != nil
    }

    enum WebServerError: Error, LocalizedError {
        case noAvailablePort

        var errorDescription: String? {
            switch self {
            case .noAvailablePort:
                return "No available port found (tried \(WebServer.shared.basePort)-\(WebServer.shared.basePort + UInt16(WebServer.shared.maxPortAttempts) - 1))"
            }
        }
    }

    // MARK: - JSON API

    private func sessionsToJSON() -> Any {
        let sessions = SessionStore.shared.getSessions()

        let sessionData: [[String: Any]] = sessions.map { session in
            var dict: [String: Any] = [
                "session_id": session.sessionId,
                "project": session.projectName,
                "path": session.cwd,
                "status": session.status.rawValue,
                "updated_at": ISO8601DateFormatter().string(from: session.updatedAt),
                "is_acknowledged": session.isAcknowledged ?? false,
                "attention_level": attentionLevel(for: session),
                "terminal": session.environmentLabel
            ]

            // Add TTY if available
            if let tty = session.tty {
                dict["tty"] = tty
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

            // Add waiting reason for UI indication
            if session.status == .waitingInput {
                dict["waiting_reason"] = session.waitingReason?.rawValue ?? "unknown"
            }

            // Add tool running status
            if let isToolRunning = session.isToolRunning {
                dict["is_tool_running"] = isToolRunning
            }

            return dict
        }

        return ["sessions": sessionData]
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

    /// Generate icons JSON for all known terminals/editors
    /// Returns: {"terminal_name": "base64_png_data", ...}
    private static func iconsToJSON() -> [String: String] {
        var icons: [String: String] = [:]

        // Get unique terminal names from current sessions
        let sessions = SessionStore.shared.getSessions()
        var environments: [String: FocusEnvironment] = [:]

        for session in sessions {
            let env = EnvironmentResolver.shared.resolve(session: session)
            let name = env.displayName
            if environments[name] == nil {
                environments[name] = env
            }
        }

        // Generate base64 icons for each environment
        for (name, env) in environments {
            if let base64 = IconManager.shared.iconBase64(for: env, size: 64) {
                icons[name] = base64
            }
        }

        // Also add common terminals that might not have active sessions
        let commonTerminals: [(String, FocusEnvironment)] = [
            ("Ghostty", .ghostty(hasTmux: false, tabIndex: nil, tmuxSessionName: nil)),
            ("Ghostty/tmux", .ghostty(hasTmux: true, tabIndex: nil, tmuxSessionName: nil)),
            ("iTerm2", .iterm2(hasTmux: false, tabIndex: nil, tmuxSessionName: nil)),
            ("iTerm2/tmux", .iterm2(hasTmux: true, tabIndex: nil, tmuxSessionName: nil)),
            ("Terminal", .terminal(hasTmux: false, tmuxSessionName: nil)),
            ("Terminal/tmux", .terminal(hasTmux: true, tmuxSessionName: nil))
        ]

        for (name, env) in commonTerminals {
            if icons[name] == nil, let base64 = IconManager.shared.iconBase64(for: env, size: 64) {
                icons[name] = base64
            }
        }

        return icons
    }

    // MARK: - HTML UI

    private func renderHTML() -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
            <title>CC Status Bar</title>
            <style>
                * {
                    box-sizing: border-box;
                    margin: 0;
                    padding: 0;
                }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    background: #1a1a1a;
                    color: #fff;
                    min-height: 100vh;
                    padding: 16px;
                    padding-bottom: env(safe-area-inset-bottom, 16px);
                }
                h1 {
                    font-size: 20px;
                    font-weight: 600;
                    margin-bottom: 16px;
                    color: #fff;
                }
                .loading {
                    color: #888;
                    text-align: center;
                    padding: 40px;
                }
                .empty {
                    color: #666;
                    text-align: center;
                    padding: 40px;
                }
                .session {
                    background: #2a2a2a;
                    border-radius: 12px;
                    padding: 16px;
                    margin-bottom: 12px;
                    border-left: 4px solid #888;
                }
                .session.waiting_input {
                    border-left-color: #ffcc00;
                }
                .session.waiting_input.permission_prompt {
                    border-left-color: #ff3b30;
                }
                .session.running {
                    border-left-color: #34c759;
                }
                .session.stopped {
                    border-left-color: #8e8e93;
                }
                .project-name {
                    font-size: 18px;
                    font-weight: 600;
                    margin-bottom: 4px;
                }
                .path {
                    font-size: 13px;
                    color: #888;
                    margin-bottom: 8px;
                    word-break: break-all;
                }
                .status {
                    display: inline-block;
                    font-size: 12px;
                    padding: 2px 8px;
                    border-radius: 4px;
                    background: #3a3a3a;
                    margin-right: 8px;
                }
                .status.running { background: #1a4d1a; color: #34c759; }
                .status.waiting_input { background: #4d3d00; color: #ffcc00; }
                .status.stopped { background: #3a3a3a; color: #8e8e93; }
                .time {
                    font-size: 12px;
                    color: #666;
                }
                .tmux-info {
                    font-size: 12px;
                    color: #888;
                    margin-top: 8px;
                }
                .refresh-btn {
                    position: fixed;
                    bottom: 24px;
                    right: 24px;
                    width: 56px;
                    height: 56px;
                    border-radius: 50%;
                    background: #007aff;
                    color: #fff;
                    border: none;
                    font-size: 24px;
                    cursor: pointer;
                    box-shadow: 0 4px 12px rgba(0,0,0,0.3);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    padding-bottom: env(safe-area-inset-bottom, 0);
                }
                .refresh-btn:active {
                    background: #0056b3;
                }
            </style>
        </head>
        <body>
            <h1>CC Status Bar</h1>
            <div id="sessions"><div class="loading">Loading...</div></div>
            <button class="refresh-btn" onclick="loadSessions()">↻</button>

            <script>
                function formatTime(isoString) {
                    const date = new Date(isoString);
                    return date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
                }

                function getStatusLabel(status, waitingReason) {
                    if (status === 'waiting_input') {
                        return waitingReason === 'permission_prompt' ? 'Needs Input' : 'Waiting';
                    }
                    if (status === 'running') return 'Running';
                    if (status === 'stopped') return 'Stopped';
                    return status;
                }

                function loadSessions() {
                    fetch('/api/sessions')
                        .then(r => r.json())
                        .then(data => {
                            const el = document.getElementById('sessions');

                            if (!data.sessions || data.sessions.length === 0) {
                                el.innerHTML = '<div class="empty">No active sessions</div>';
                                return;
                            }

                            el.innerHTML = '';
                            data.sessions.forEach(s => {
                                const div = document.createElement('div');
                                const waitingClass = s.waiting_reason === 'permission_prompt' ? ' permission_prompt' : '';
                                div.className = 'session ' + s.status + waitingClass;

                                let tmuxHtml = '';
                                if (s.tmux) {
                                    tmuxHtml = '<div class="tmux-info">tmux: ' + s.tmux.session + '</div>';
                                }

                                div.innerHTML =
                                    '<div class="project-name">' + escapeHtml(s.project) + '</div>' +
                                    '<div class="path">' + escapeHtml(s.path.replace(/^\\/Users\\/[^\\/]+/, '~')) + '</div>' +
                                    '<span class="status ' + s.status + '">' + getStatusLabel(s.status, s.waiting_reason) + '</span>' +
                                    '<span class="time">' + formatTime(s.updated_at) + '</span>' +
                                    tmuxHtml;

                                el.appendChild(div);
                            });
                        })
                        .catch(err => {
                            console.error('Failed to load sessions:', err);
                            document.getElementById('sessions').innerHTML =
                                '<div class="empty">Failed to load sessions</div>';
                        });
                }

                function escapeHtml(str) {
                    return str.replace(/&/g, '&amp;')
                              .replace(/</g, '&lt;')
                              .replace(/>/g, '&gt;')
                              .replace(/"/g, '&quot;');
                }

                // Initialize
                loadSessions();

                // Auto-refresh every 5 seconds
                setInterval(loadSessions, 5000);
            </script>
        </body>
        </html>
        """
    }
}
