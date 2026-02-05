import Foundation
import Combine

/// Observes active Codex CLI sessions by monitoring running processes
/// Matches Codex sessions with Claude Code sessions by cwd
enum CodexObserver {
    // MARK: - Cache

    /// Cache for active Codex sessions (TTL: 5 seconds)
    private static var sessionsCache: (sessions: [String: CodexSession], timestamp: Date)?
    private static let cacheTTL: TimeInterval = 5.0

    /// Invalidate the cache
    static func invalidateCache() {
        sessionsCache = nil
        DebugLog.log("[CodexObserver] Cache invalidated")
    }

    // MARK: - Public API

    /// Get all active Codex sessions indexed by cwd
    /// - Returns: Dictionary of cwd -> CodexSession
    static func getActiveSessions() -> [String: CodexSession] {
        let now = Date()

        // Check cache
        if let cached = sessionsCache,
           now.timeIntervalSince(cached.timestamp) < cacheTTL {
            return cached.sessions
        }

        // Fetch from system
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
        return getActiveSessions()[cwd] != nil
    }

    /// Get Codex session for a specific cwd
    /// - Parameter cwd: The working directory
    /// - Returns: CodexSession if running, nil otherwise
    static func getCodexSession(for cwd: String) -> CodexSession? {
        return getActiveSessions()[cwd]
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
                        DebugLog.log("[CodexObserver] Found tmux pane for Codex PID \(pid): \(paneInfo.session):\(paneInfo.window).\(paneInfo.pane)")

                        // Detect terminal app from tmux client
                        if let terminalApp = TmuxHelper.getClientTerminalInfo(for: paneInfo.session) {
                            session.terminalApp = terminalApp
                            DebugLog.log("[CodexObserver] Detected terminal for Codex: \(terminalApp)")
                        }
                    }
                }

                sessions[cwd] = session
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
        // pgrep for codex vendor processes
        let output = runCommand("/usr/bin/pgrep", ["-f", "codex/vendor.*codex"])
        let pids = output
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        return pids
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
    private static func parseCodexSessionFile(_ url: URL, lookingForCwd cwd: String) -> String? {
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
