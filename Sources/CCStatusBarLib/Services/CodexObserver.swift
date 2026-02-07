import Foundation
import Combine

/// Observes active Codex CLI sessions by monitoring running processes
/// Matches Codex sessions with Claude Code sessions by cwd
enum CodexObserver {
    // MARK: - Cache

    /// Cache for active Codex sessions (3-state: fresh / stale / empty)
    private static var sessionsCache: (sessions: [String: CodexSession], timestamp: Date)?
    private static let freshTTL: TimeInterval = 5.0    // Fresh: return immediately
    private static let staleTTL: TimeInterval = 30.0   // Stale: return cached, refresh in background
    private static var isRefreshing = false             // Prevent concurrent background refreshes

    /// Mark cache as stale (don't clear — stale data is still returned immediately)
    static func invalidateCache() {
        if let cached = sessionsCache {
            sessionsCache = (cached.sessions, cached.timestamp.addingTimeInterval(-freshTTL))
            DebugLog.log("[CodexObserver] Cache marked stale")
        }
    }

    // MARK: - Public API

    /// Get all active Codex sessions indexed by internal id
    /// Uses stale-while-revalidate: returns cached data immediately and refreshes in background
    /// - Returns: Dictionary of session key -> CodexSession
    static func getActiveSessions() -> [String: CodexSession] {
        let now = Date()

        if let cached = sessionsCache {
            let age = now.timeIntervalSince(cached.timestamp)

            if age < freshTTL {
                // Fresh: return immediately
                return cached.sessions
            }

            if age < staleTTL {
                // Stale: return cached data, trigger background refresh
                triggerBackgroundRefresh()
                return cached.sessions
            }
        }

        // Empty or expired: synchronous fetch (unavoidable on first call)
        let sessions = fetchCodexSessions()
        sessionsCache = (sessions, now)

        if !sessions.isEmpty {
            DebugLog.log("[CodexObserver] Found \(sessions.count) active Codex session(s)")
        }

        return sessions
    }

    /// Check if Codex is running for a specific cwd
    /// - Parameter cwd: The working directory to check
    /// - Returns: true if Codex is running in that directory
    static func isCodexRunning(for cwd: String) -> Bool {
        return getActiveSessions().values.contains { $0.cwd == cwd }
    }

    /// Get Codex session for a specific cwd
    /// - Parameter cwd: The working directory
    /// - Returns: CodexSession if running, nil otherwise
    static func getCodexSession(for cwd: String) -> CodexSession? {
        return getActiveSessions().values
            .filter { $0.cwd == cwd }
            .sorted { $0.pid < $1.pid }
            .first
    }

    /// Get CodexInfo for WebSocket output
    /// - Parameter cwd: The working directory
    /// - Returns: CodexInfo if Codex is running, nil otherwise
    static func getCodexInfo(for cwd: String) -> CodexInfo? {
        guard let session = getCodexSession(for: cwd) else {
            return nil
        }
        return CodexInfo(
            pid: session.pid,
            isActive: true,
            startedAt: session.startedAt,
            sessionId: session.sessionId
        )
    }

    // MARK: - Background Refresh

    /// Trigger a background refresh of Codex sessions (stale-while-revalidate)
    private static func triggerBackgroundRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        DispatchQueue.global(qos: .utility).async {
            let sessions = fetchCodexSessions()
            let now = Date()

            DispatchQueue.main.async {
                sessionsCache = (sessions, now)
                isRefreshing = false
                NotificationCenter.default.post(name: .codexSessionsDidUpdate, object: nil)
                DebugLog.log("[CodexObserver] Background refresh complete (\(sessions.count) sessions)")
            }
        }
    }

    // MARK: - Private

    /// Fetch active Codex sessions from running processes
    private static func fetchCodexSessions() -> [String: CodexSession] {
        var sessions: [String: CodexSession] = [:]

        // Get Codex process PIDs
        // Pattern: /opt/homebrew/lib/node_modules/@openai/codex/vendor...codex
        let pids = getCodexPIDs()

        for pid in pids {
            if let cwd = getCwd(for: pid) {
                var session = CodexSession(pid: pid, cwd: cwd)

                // Try to find session ID from Codex session files
                session.sessionId = findCodexSessionId(for: cwd)

                // Get TTY and tmux info
                if let tty = getTTY(for: pid) {
                    session.tty = tty
                    if let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
                        session.tmuxSession = paneInfo.session
                        session.tmuxWindow = paneInfo.window
                        session.tmuxPane = paneInfo.pane
                        session.tmuxSocketPath = paneInfo.socketPath
                        DebugLog.log("[CodexObserver] Found tmux pane for Codex PID \(pid): \(paneInfo.session):\(paneInfo.window).\(paneInfo.pane)")

                        // Detect terminal app from tmux client
                        if let terminalApp = TmuxHelper.getClientTerminalInfo(for: paneInfo.session) {
                            session.terminalApp = terminalApp
                            DebugLog.log("[CodexObserver] Detected terminal for Codex: \(terminalApp)")
                        }
                    }
                }

                let key = "codex:\(pid)"
                sessions[key] = session
                DebugLog.log("[CodexObserver] Found Codex PID \(pid) in \(session.projectName)")
            }
        }

        return sessions
    }

    /// Get TTY for a process
    /// - Parameter pid: Process ID
    /// - Returns: TTY path (e.g., "/dev/ttys001") or nil
    private static func getTTY(for pid: pid_t) -> String? {
        // ps -p <pid> -o tty=
        let output = runCommand("/bin/ps", ["-p", "\(pid)", "-o", "tty="])
        let tty = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty or "??" means no controlling terminal
        guard !tty.isEmpty, tty != "??" else {
            return nil
        }

        return "/dev/\(tty)"
    }

    /// Get PIDs of running Codex processes
    private static func getCodexPIDs() -> [pid_t] {
        var pidSet = Set<pid_t>()

        // Current Codex CLI typically runs as a direct executable named "codex"
        // (or occasionally "codex-cli"), so prioritize exact process-name matches.
        for processName in ["codex", "codex-cli"] {
            let output = runCommand("/usr/bin/pgrep", ["-x", processName])
            for line in output.split(separator: "\n") {
                if let pid = pid_t(line.trimmingCharacters(in: .whitespaces)) {
                    pidSet.insert(pid)
                }
            }
        }

        // Backward compatibility: legacy Node/vendor launch patterns.
        for pattern in ["codex/vendor.*codex", "@openai/codex"] {
            let output = runCommand("/usr/bin/pgrep", ["-f", pattern])
            for line in output.split(separator: "\n") {
                if let pid = pid_t(line.trimmingCharacters(in: .whitespaces)) {
                    pidSet.insert(pid)
                }
            }
        }

        // Exclude helper/background subcommands that are not interactive Codex CLI sessions.
        // Example: `codex mcp-server` started by Claude Code.
        let filteredPIDs = pidSet.filter { pid in
            let commandLine = getCommandLine(for: pid)
            let shouldTrack = shouldTrackCodexCommandLine(commandLine)
            if !shouldTrack {
                DebugLog.log("[CodexObserver] Skipping non-interactive Codex process PID \(pid): \(commandLine)")
            }
            return shouldTrack
        }

        return Array(filteredPIDs).sorted()
    }

    /// Check whether a Codex command line should be tracked as an active Codex session.
    /// Visible for tests.
    static func shouldTrackCodexCommandLine(_ commandLine: String) -> Bool {
        let normalized = commandLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        // Tokenize and check if "mcp-server" is a standalone argument (subcommand).
        // This avoids false exclusion when "mcp-server" appears in paths or other arguments.
        let tokens = normalized.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if tokens.contains("mcp-server") { return false }

        return true
    }

    /// Get full command line for a process
    private static func getCommandLine(for pid: pid_t) -> String {
        runCommand("/bin/ps", ["-p", "\(pid)", "-o", "command="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get current working directory for a process
    private static func getCwd(for pid: pid_t) -> String? {
        // lsof -p <pid> | grep cwd
        let output = runCommand("/usr/sbin/lsof", ["-p", "\(pid)"])
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            // lsof output: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            // cwd line has FD="cwd" and NAME is the path
            if columns.count >= 9,
               columns[3] == "cwd" {
                // NAME is the last column (may contain spaces)
                let nameStartIndex = columns.index(columns.startIndex, offsetBy: 8)
                let path = columns[nameStartIndex...].joined(separator: " ")
                return path
            }
        }
        return nil
    }

    /// Find Codex session ID from session files
    /// Location: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
    private static func findCodexSessionId(for cwd: String) -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let sessionsDir = homeDir.appendingPathComponent(".codex/sessions")

        // Get today's date components
        let now = Date()
        let calendar = Calendar.current
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)

        let todayDir = sessionsDir
            .appendingPathComponent(String(format: "%04d", year))
            .appendingPathComponent(String(format: "%02d", month))
            .appendingPathComponent(String(format: "%02d", day))

        guard FileManager.default.fileExists(atPath: todayDir.path) else {
            return nil
        }

        // Find rollout files
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: todayDir.path) else {
            return nil
        }

        let rolloutFiles = files
            .filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
            .sorted()
            .reversed()  // Most recent first

        // Check each file for matching cwd
        for filename in rolloutFiles {
            let filePath = todayDir.appendingPathComponent(filename)
            if let sessionId = parseCodexSessionFile(filePath, lookingForCwd: cwd) {
                return sessionId
            }
        }

        return nil
    }

    /// Parse a Codex session file to find session ID for a specific cwd
    static func parseCodexSessionFile(_ url: URL, lookingForCwd cwd: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // First line should be session_meta
        guard let firstLine = content.split(separator: "\n").first,
              let lineData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = json["type"] as? String,
              type == "session_meta",
              let payload = json["payload"] as? [String: Any],
              let fileCwd = payload["cwd"] as? String,
              let sessionId = payload["id"] as? String else {
            return nil
        }

        // Check if cwd matches
        if fileCwd == cwd {
            return sessionId
        }

        return nil
    }

    /// Run a shell command and return output
    private static func runCommand(_ executable: String, _ args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(args)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let codexSessionsDidUpdate = Notification.Name("codexSessionsDidUpdate")
}
