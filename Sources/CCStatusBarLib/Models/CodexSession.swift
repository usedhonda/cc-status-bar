import Foundation

/// Cumulative token usage for a Codex session
struct CodexTokenUsage: Equatable, Codable {
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int

    /// Human-readable total (e.g., "521K tokens", "1.5M tokens")
    var formattedTotal: String {
        Self.format(totalTokens)
    }

    static func format(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000.0
            return String(format: "%.1fM tokens", millions)
        } else if count >= 1_000 {
            let thousands = Double(count) / 1_000.0
            if thousands == Double(Int(thousands)) {
                return "\(Int(thousands))K tokens"
            }
            return String(format: "%.1fK tokens", thousands)
        }
        return "\(count) tokens"
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }
}

/// Represents an active Codex CLI session
struct CodexSession: Equatable {
    let pid: pid_t
    let cwd: String
    let projectName: String
    let startedAt: Date

    /// Session ID from Codex session file (if found)
    var sessionId: String?

    /// TTY device path (e.g., "/dev/ttys001")
    var tty: String?

    /// tmux session name
    var tmuxSession: String?

    /// tmux window index
    var tmuxWindow: String?

    /// tmux pane index
    var tmuxPane: String?

    /// tmux socket path (for non-default servers)
    var tmuxSocketPath: String?

    /// Terminal app name (e.g., "ghostty", "iTerm.app")
    var terminalApp: String?

    /// Token usage from JSONL session file
    var tokenUsage: CodexTokenUsage?

    /// CLI version from session_meta (e.g., "1.0.7")
    var cliVersion: String?

    /// Model provider from session_meta (e.g., "openai")
    var modelProvider: String?

    /// Originator from session_meta (e.g., "codex-cli")
    var originator: String?

    /// Session status (running or waiting_input)
    var status: CodexStatus {
        // Delegate to CodexStatusReceiver for real-time status
        // Note: This is computed property, actual status comes from receiver
        return .running  // Default, will be overridden by caller using CodexStatusReceiver
    }

    init(pid: pid_t, cwd: String, sessionId: String? = nil) {
        self.pid = pid
        self.cwd = cwd
        self.projectName = URL(fileURLWithPath: cwd).lastPathComponent
        self.startedAt = Date()
        self.sessionId = sessionId
    }
}

extension CodexSession: Identifiable {
    var id: String {
        if pid > 0 {
            return "codex:\(pid)"
        }
        return "codex:synthetic:\(cwd)"
    }

    /// Display text based on session display mode setting
    func displayText(for mode: SessionDisplayMode) -> String {
        let paneInfo = tty.flatMap { TmuxHelper.getPaneInfo(for: $0) }
        switch mode {
        case .projectName:
            return projectName
        case .tmuxWindow:
            return paneInfo?.windowName ?? projectName
        case .tmuxSession:
            return paneInfo?.session ?? projectName
        case .tmuxSessionWindow:
            guard let info = paneInfo else { return projectName }
            return "\(info.session):\(info.windowName)"
        }
    }
}

/// Information about Codex session for WebSocket output
struct CodexInfo: Codable {
    let pid: pid_t
    let isActive: Bool
    let startedAt: Date?
    let sessionId: String?
    let tokenUsage: CodexTokenUsage?
    let cliVersion: String?
    let modelProvider: String?

    enum CodingKeys: String, CodingKey {
        case pid
        case isActive = "is_active"
        case startedAt = "started_at"
        case sessionId = "session_id"
        case tokenUsage = "token_usage"
        case cliVersion = "cli_version"
        case modelProvider = "model_provider"
    }
}
