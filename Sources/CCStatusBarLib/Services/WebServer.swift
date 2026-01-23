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
                "updated_at": ISO8601DateFormatter().string(from: session.updatedAt)
            ]

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

            return dict
        }

        return ["sessions": sessionData]
    }

    // MARK: - HTML UI

    private func renderHTML() -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
            <title>CC Sessions (tmux)</title>
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
                .connect-btn {
                    display: inline-block;
                    background: #007aff;
                    color: #fff;
                    padding: 10px 20px;
                    border-radius: 8px;
                    text-decoration: none;
                    font-size: 14px;
                    font-weight: 500;
                    margin-top: 12px;
                    transition: background 0.2s;
                }
                .connect-btn:active {
                    background: #0056b3;
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
                .settings-bar {
                    background: #2a2a2a;
                    padding: 12px 16px;
                    margin-bottom: 16px;
                    border-radius: 12px;
                    display: flex;
                    gap: 12px;
                    align-items: center;
                    flex-wrap: wrap;
                }
                .settings-bar label {
                    font-size: 13px;
                    color: #aaa;
                }
                .settings-bar input {
                    background: #1a1a1a;
                    border: 1px solid #444;
                    border-radius: 6px;
                    padding: 8px 12px;
                    color: #fff;
                    font-size: 14px;
                    width: 120px;
                }
                .settings-bar input:focus {
                    outline: none;
                    border-color: #007aff;
                }
                .settings-bar .save-btn {
                    background: #30d158;
                    color: #fff;
                    border: none;
                    padding: 8px 16px;
                    border-radius: 6px;
                    font-size: 13px;
                    cursor: pointer;
                }
                .settings-bar .save-btn:active {
                    background: #28b84d;
                }
                .settings-bar .status-msg {
                    font-size: 12px;
                    color: #30d158;
                }
                .no-key-warning {
                    background: #3a2a00;
                    color: #ffcc00;
                    padding: 12px 16px;
                    border-radius: 8px;
                    margin-bottom: 16px;
                    font-size: 13px;
                }
            </style>
        </head>
        <body>
            <h1>Claude Code Sessions (tmux)</h1>
            <div class="settings-bar">
                <label>Blink URL Key:</label>
                <input type="text" id="urlKeyInput" placeholder="e.g. ABC123" maxlength="20">
                <button class="save-btn" onclick="saveUrlKey()">Save</button>
                <span id="saveStatus" class="status-msg"></span>
            </div>
            <div id="keyWarning" class="no-key-warning" style="display:none;">
                Set your Blink URL Key above to enable Connect buttons.<br>
                Find it in Blink: config → X-Callback-URL
            </div>
            <div id="sessions"><div class="loading">Loading...</div></div>
            <button class="refresh-btn" onclick="loadSessions()">↻</button>

            <script>
                // URL Key management
                function getUrlKey() {
                    return localStorage.getItem('blinkUrlKey') || '';
                }

                function saveUrlKey() {
                    const key = document.getElementById('urlKeyInput').value.trim();
                    if (key) {
                        localStorage.setItem('blinkUrlKey', key);
                        document.getElementById('saveStatus').textContent = 'Saved!';
                        setTimeout(() => document.getElementById('saveStatus').textContent = '', 2000);
                        loadSessions(); // Refresh to show Connect buttons
                    }
                }

                function initUrlKey() {
                    const saved = getUrlKey();
                    document.getElementById('urlKeyInput').value = saved;
                    document.getElementById('keyWarning').style.display = saved ? 'none' : 'block';
                }

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
                    const urlKey = getUrlKey();
                    document.getElementById('keyWarning').style.display = urlKey ? 'none' : 'block';

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
                                let connectHtml = '';

                                if (s.tmux) {
                                    tmuxHtml = '<div class="tmux-info">tmux: ' + s.tmux.session + '</div>';
                                    // Generate Blink Shell deep link (only if URL key is set)
                                    if (urlKey) {
                                        const sess = s.tmux.session;
                                        const sshCmd = 'ssh -t mac /Users/usedhonda/bin/tmux-attach.sh ' + sess;
                                        const blinkUrl = 'blinkshell://run?key=' + urlKey + '&cmd=' + encodeURIComponent(sshCmd);
                                        connectHtml = '<a class="connect-btn" href="' + blinkUrl + '">Connect via Blink</a>';
                                    }
                                }

                                div.innerHTML =
                                    '<div class="project-name">' + escapeHtml(s.project) + '</div>' +
                                    '<div class="path">' + escapeHtml(s.path.replace(/^\\/Users\\/[^\\/]+/, '~')) + '</div>' +
                                    '<span class="status ' + s.status + '">' + getStatusLabel(s.status, s.waiting_reason) + '</span>' +
                                    '<span class="time">' + formatTime(s.updated_at) + '</span>' +
                                    tmuxHtml +
                                    connectHtml;

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
                initUrlKey();
                loadSessions();

                // Auto-refresh every 5 seconds
                setInterval(loadSessions, 5000);
            </script>
        </body>
        </html>
        """
    }
}
