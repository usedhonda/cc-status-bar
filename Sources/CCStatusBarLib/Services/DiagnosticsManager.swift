import Foundation
import AppKit

/// Severity level for diagnostic issues
enum DiagnosticSeverity {
    case warning
    case error
}

/// Diagnostic issue types detected by the diagnostics system
enum DiagnosticIssue: Identifiable {
    /// tmux session uses a numeric-only name (prevents title-based tab search)
    case tmuxDefaultName(sessionName: String, projectName: String)

    /// Failed to focus a session's terminal tab
    case focusFailed(projectName: String, reason: String, timestamp: Date)

    /// Accessibility permission not granted
    case accessibilityPermission

    /// Claude Code hooks not configured
    case hooksNotConfigured

    /// Sessions file not found or corrupted
    case sessionsFileIssue(reason: String)

    var id: String {
        switch self {
        case .tmuxDefaultName(let sessionName, _):
            return "tmux_default_name_\(sessionName)"
        case .focusFailed(let projectName, _, _):
            return "focus_failed_\(projectName)"
        case .accessibilityPermission:
            return "accessibility_permission"
        case .hooksNotConfigured:
            return "hooks_not_configured"
        case .sessionsFileIssue:
            return "sessions_file_issue"
        }
    }

    var title: String {
        switch self {
        case .tmuxDefaultName:
            return "tmux session uses numeric name"
        case .focusFailed:
            return "Focus failed for session"
        case .accessibilityPermission:
            return "Accessibility permission required"
        case .hooksNotConfigured:
            return "Claude Code hooks not configured"
        case .sessionsFileIssue:
            return "Sessions file issue"
        }
    }

    var description: String {
        switch self {
        case .tmuxDefaultName(let sessionName, let projectName):
            return """
            Session: "\(sessionName)"
            Project: \(projectName)
            Tab title: "\(sessionName):zsh" (no project name)
            """
        case .focusFailed(let projectName, let reason, let timestamp):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            formatter.locale = Locale(identifier: "en_US")
            let timeAgo = formatter.localizedString(for: timestamp, relativeTo: Date())
            return """
            Project: \(projectName)
            Reason: \(reason)
            Last attempt: \(timeAgo)
            """
        case .accessibilityPermission:
            return """
            CC Status Bar needs Accessibility permission to:
            - Read terminal tab titles
            - Focus specific terminal tabs
            - Switch between windows
            """
        case .hooksNotConfigured:
            return """
            CC Status Bar hooks are not found in settings.json.
            Session tracking won't work without hooks.
            """
        case .sessionsFileIssue(let reason):
            return """
            Expected: ~/Library/Application Support/CCStatusBar/sessions.json
            Status: \(reason)
            """
        }
    }

    var solution: String {
        switch self {
        case .tmuxDefaultName(let sessionName, let projectName):
            return """
            Option 1: Rename your session (immediate fix)
            tmux rename-session -t \(sessionName) \(projectName)

            Option 2: Create new sessions with names
            tmux new-session -s \(projectName)

            Option 3: Auto-configure in ~/.tmux.conf
            set -g automatic-rename on
            set -g automatic-rename-format "#{b:pane_current_path}"
            """
        case .focusFailed:
            return """
            For Ghostty:
            Tab titles are composed of tmux session name + window name.
            Give your tmux session a meaningful name.

            For iTerm2:
            Go to Preferences → Profiles → General → Title
            and include "Session Name" in the title format.
            """
        case .accessibilityPermission:
            return """
            1. Click "Open Settings" button below
            2. Go to System Settings → Privacy & Security → Accessibility
            3. Add or enable CC Status Bar
            4. Restart the app
            """
        case .hooksNotConfigured:
            return """
            Option 1: Run setup wizard
            Click Settings → Reconfigure Hooks...

            Option 2: Manual configuration
            Add hooks to ~/.claude/settings.json
            See README.md for complete configuration.
            """
        case .sessionsFileIssue:
            return """
            1. Restart the app (file will be created automatically)
            2. If that doesn't work:
               mkdir -p ~/Library/Application\\ Support/CCStatusBar
               echo '{"sessions":{}}' > ~/Library/Application\\ Support/CCStatusBar/sessions.json
            """
        }
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .tmuxDefaultName, .focusFailed, .hooksNotConfigured:
            return .warning
        case .accessibilityPermission, .sessionsFileIssue:
            return .error
        }
    }
}

/// Manages diagnostic checks and issue tracking
@MainActor
final class DiagnosticsManager: ObservableObject {
    static let shared = DiagnosticsManager()

    @Published private(set) var issues: [DiagnosticIssue] = []

    /// Focus failure records (kept separately to avoid duplicates)
    private var focusFailures: [String: (reason: String, timestamp: Date)] = [:]

    /// Maximum number of focus failures to track
    private let maxFocusFailures = 10

    /// Cached sessions for diagnostics (updated by checkTmuxSessionNames)
    private var cachedSessions: [Session] = []

    private init() {}

    // MARK: - Public API

    var hasIssues: Bool {
        !issues.isEmpty
    }

    var hasErrors: Bool {
        issues.contains { $0.severity == .error }
    }

    var hasWarnings: Bool {
        issues.contains { $0.severity == .warning }
    }

    /// Run all diagnostic checks
    func runDiagnostics() {
        DebugLog.log("[DiagnosticsManager] Running diagnostics")
        var newIssues: [DiagnosticIssue] = []

        // Check accessibility permission
        if !PermissionManager.checkAccessibilityPermission() {
            newIssues.append(.accessibilityPermission)
        }

        // Check sessions file
        checkSessionsFile(&newIssues)

        // Check hooks configuration
        checkHooksConfiguration(&newIssues)

        // Check tmux session names for numeric-only names
        addTmuxSessionNameIssues(sessions: cachedSessions, to: &newIssues)

        // Add any recorded focus failures
        for (projectName, failure) in focusFailures {
            newIssues.append(.focusFailed(
                projectName: projectName,
                reason: failure.reason,
                timestamp: failure.timestamp
            ))
        }

        issues = newIssues
        DebugLog.log("[DiagnosticsManager] Found \(issues.count) issue(s)")
    }

    /// Record a focus failure for a session
    func recordFocusFailure(projectName: String, reason: String) {
        DebugLog.log("[DiagnosticsManager] Recording focus failure for '\(projectName)': \(reason)")

        // Update or add the failure record
        focusFailures[projectName] = (reason: reason, timestamp: Date())

        // Limit the number of tracked failures
        if focusFailures.count > maxFocusFailures {
            // Remove oldest entry
            if let oldest = focusFailures.min(by: { $0.value.timestamp < $1.value.timestamp }) {
                focusFailures.removeValue(forKey: oldest.key)
            }
        }
    }

    /// Clear a focus failure record (e.g., when focus succeeds)
    func clearFocusFailure(projectName: String) {
        focusFailures.removeValue(forKey: projectName)
    }

    /// Check tmux session names for numeric-only names (called from SessionObserver polling)
    func checkTmuxSessionNames(sessions: [Session]) {
        // Cache sessions for use in runDiagnostics()
        cachedSessions = sessions

        // Remove existing tmux name issues
        issues.removeAll { issue in
            if case .tmuxDefaultName = issue { return true }
            return false
        }

        // Add tmux issues
        addTmuxSessionNameIssues(sessions: sessions, to: &issues)
    }

    /// Add tmux session name issues to the given array
    private func addTmuxSessionNameIssues(sessions: [Session], to issues: inout [DiagnosticIssue]) {
        for session in sessions {
            guard let tty = session.tty,
                  let paneInfo = TmuxHelper.getPaneInfo(for: tty) else {
                continue
            }

            let sessionName = paneInfo.session

            // Check if session name is numeric-only (default tmux behavior)
            if sessionName.allSatisfy({ $0.isNumber }) {
                issues.append(.tmuxDefaultName(
                    sessionName: sessionName,
                    projectName: session.projectName
                ))
            }
        }
    }

    // MARK: - Private Checks

    private func checkSessionsFile(_ issues: inout [DiagnosticIssue]) {
        let sessionsFile = SetupManager.sessionsFile

        if !FileManager.default.fileExists(atPath: sessionsFile.path) {
            issues.append(.sessionsFileIssue(reason: "File not found"))
            return
        }

        // Try to read and parse the file
        do {
            let data = try Data(contentsOf: sessionsFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode(StoreData.self, from: data)
            // File is valid
        } catch {
            issues.append(.sessionsFileIssue(reason: "Parse error: \(error.localizedDescription)"))
        }
    }

    private func checkHooksConfiguration(_ issues: inout [DiagnosticIssue]) {
        let settingsPath = NSString("~/.claude/settings.json").expandingTildeInPath

        guard FileManager.default.fileExists(atPath: settingsPath) else {
            issues.append(.hooksNotConfigured)
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = json["hooks"] as? [String: Any] else {
                issues.append(.hooksNotConfigured)
                return
            }

            // Check for required hook events
            let requiredEvents = ["PreToolUse", "PostToolUse", "Notification", "Stop"]
            var hasAnyHook = false

            for event in requiredEvents {
                if let eventHooks = hooks[event] as? [[String: Any]], !eventHooks.isEmpty {
                    // Check if any hook contains CCStatusBar
                    for hook in eventHooks {
                        if let hookList = hook["hooks"] as? [[String: Any]] {
                            for h in hookList {
                                if let command = h["command"] as? String,
                                   command.contains("CCStatusBar") {
                                    hasAnyHook = true
                                    break
                                }
                            }
                        }
                    }
                }
            }

            if !hasAnyHook {
                issues.append(.hooksNotConfigured)
            }
        } catch {
            issues.append(.hooksNotConfigured)
        }
    }

    // MARK: - Diagnostics Report

    /// Generate a full diagnostics report for copying
    func generateReport() -> String {
        var lines: [String] = []

        lines.append("=== CC Status Bar Diagnostics ===")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        // System info
        lines.append("-- System --")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            lines.append("App Version: \(appVersion)")
        }
        lines.append("")

        // Permission status
        lines.append(PermissionManager.diagnosticsReport())
        lines.append("")

        // Issues
        if issues.isEmpty {
            lines.append("-- Issues --")
            lines.append("No issues detected")
        } else {
            lines.append("-- Issues (\(issues.count)) --")
            for issue in issues {
                let severityIcon = issue.severity == .error ? "❌" : "⚠️"
                lines.append("\(severityIcon) \(issue.title)")
                lines.append(issue.description.split(separator: "\n").map { "   \($0)" }.joined(separator: "\n"))
                lines.append("")
            }
        }

        // Running terminals
        lines.append("-- Running Terminals --")
        if GhosttyHelper.isRunning { lines.append("✓ Ghostty") }
        if ITerm2Helper.isRunning { lines.append("✓ iTerm2") }
        if TerminalAppController.shared.isRunning { lines.append("✓ Terminal.app") }
        if !GhosttyHelper.isRunning && !ITerm2Helper.isRunning && !TerminalAppController.shared.isRunning {
            lines.append("(none detected)")
        }
        lines.append("")

        // tmux status
        lines.append("-- tmux --")
        if let sessions = TmuxHelper.listSessions(), !sessions.isEmpty {
            for session in sessions {
                lines.append("Session: \(session)")
            }
        } else {
            lines.append("(no tmux sessions)")
        }

        return lines.joined(separator: "\n")
    }
}
