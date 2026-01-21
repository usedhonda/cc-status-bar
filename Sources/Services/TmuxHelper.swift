import Foundation

enum TmuxHelper {
    struct PaneInfo {
        let session: String
        let window: String
        let pane: String
    }

    // MARK: - Caching Infrastructure

    /// Static cache for tmux binary path (never changes during app lifetime)
    private static let tmuxPath: String = {
        for path in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "tmux"  // Fallback to PATH
    }()

    /// Cache for pane info by TTY (TTL: 5 seconds)
    private static var paneInfoCache: [String: (info: PaneInfo?, timestamp: Date)] = [:]
    private static let paneCacheTTL: TimeInterval = 5.0

    /// Cache for terminal detection by PID (TTL: 60 seconds)
    private static var terminalCache: [pid_t: (terminal: String?, timestamp: Date)] = [:]
    private static let terminalCacheTTL: TimeInterval = 60.0

    /// Cache for session attach states (TTL: 5 seconds)
    private static var attachStatesCache: (states: [String: Bool], timestamp: Date)?
    private static let attachStatesCacheTTL: TimeInterval = 5.0

    /// Invalidate pane info cache (called when session file changes)
    static func invalidatePaneInfoCache() {
        paneInfoCache.removeAll()
        DebugLog.log("[TmuxHelper] Pane info cache invalidated")
    }

    /// Invalidate all caches
    static func invalidateAllCaches() {
        paneInfoCache.removeAll()
        terminalCache.removeAll()
        attachStatesCache = nil
        DebugLog.log("[TmuxHelper] All caches invalidated")
    }

    /// Invalidate attach states cache only (for menu refresh)
    static func invalidateAttachStatesCache() {
        attachStatesCache = nil
    }

    // MARK: - Pane Info (Cached)

    /// TTY から tmux ペイン情報を取得 (with caching)
    static func getPaneInfo(for tty: String) -> PaneInfo? {
        let now = Date()

        // Check cache
        if let cached = paneInfoCache[tty],
           now.timeIntervalSince(cached.timestamp) < paneCacheTTL {
            DebugLog.log("[TmuxHelper] Cache hit for TTY \(tty)")
            return cached.info
        }

        // Cache miss - fetch from tmux
        let info = fetchPaneInfoFromTmux(tty)
        paneInfoCache[tty] = (info, now)
        return info
    }

    /// Fetch pane info directly from tmux (no cache)
    private static func fetchPaneInfoFromTmux(_ tty: String) -> PaneInfo? {
        let output = runCommand(tmuxPath, ["list-panes", "-a",
            "-F", "#{pane_tty}|#{session_name}|#{window_index}|#{pane_index}"])

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|").map(String.init)
            if parts.count == 4 && parts[0] == tty {
                DebugLog.log("[TmuxHelper] Found pane: \(parts[1]):\(parts[2]).\(parts[3]) for TTY \(tty)")
                return PaneInfo(session: parts[1], window: parts[2], pane: parts[3])
            }
        }
        DebugLog.log("[TmuxHelper] No pane found for TTY \(tty)")
        return nil
    }

    /// ウィンドウとペインを選択（アクティブに）
    static func selectPane(_ info: PaneInfo) -> Bool {
        let windowTarget = "\(info.session):\(info.window)"
        let paneTarget = "\(info.session):\(info.window).\(info.pane)"

        // 1. ウィンドウを選択（タブ切り替え）
        _ = runCommand(tmuxPath, ["select-window", "-t", windowTarget])

        // 2. ペインを選択
        _ = runCommand(tmuxPath, ["select-pane", "-t", paneTarget])

        DebugLog.log("[TmuxHelper] Selected pane: \(paneTarget)")
        return true
    }

    // MARK: - Session Attach States

    /// Get attached status for all tmux sessions
    /// - Returns: Dictionary of session_name -> is_attached
    static func getSessionAttachStates() -> [String: Bool] {
        let now = Date()
        if let cached = attachStatesCache,
           now.timeIntervalSince(cached.timestamp) < attachStatesCacheTTL {
            return cached.states
        }

        let output = runCommand(tmuxPath, ["list-sessions", "-F", "#{session_name}|#{session_attached}"])
        var states: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|").map(String.init)
            if parts.count == 2 {
                states[parts[0]] = (parts[1] == "1")
            }
        }
        attachStatesCache = (states, now)
        DebugLog.log("[TmuxHelper] Fetched attach states: \(states)")
        return states
    }

    /// Check if a specific tmux session is attached
    static func isSessionAttached(_ sessionName: String) -> Bool {
        return getSessionAttachStates()[sessionName] ?? false
    }

    /// Run a tmux command and return output
    static func runTmuxCommand(_ args: String...) -> String {
        return runCommand(tmuxPath, args)
    }

    /// Kill a tmux session by name
    /// - Parameter sessionName: The name of the tmux session to kill
    /// - Returns: true if successful
    @discardableResult
    static func killSession(_ sessionName: String) -> Bool {
        let result = runCommand(tmuxPath, ["kill-session", "-t", sessionName])
        if result.isEmpty || !result.contains("error") {
            DebugLog.log("[TmuxHelper] Killed tmux session '\(sessionName)'")
            invalidateAllCaches()
            return true
        }
        DebugLog.log("[TmuxHelper] Failed to kill tmux session '\(sessionName)'")
        return false
    }

    /// Send keys to a tmux pane
    /// - Parameters:
    ///   - paneInfo: Target pane information
    ///   - keys: Keys to send (e.g., "C-c" for Ctrl+C)
    /// - Returns: true if successful
    @discardableResult
    static func sendKeys(_ paneInfo: PaneInfo, keys: String) -> Bool {
        let target = "\(paneInfo.session):\(paneInfo.window).\(paneInfo.pane)"
        _ = runCommand(tmuxPath, ["send-keys", "-t", target, keys])
        DebugLog.log("[TmuxHelper] Sent keys '\(keys)' to \(target)")
        return true
    }

    /// Detect the parent terminal application for a tmux session (with caching)
    /// - Parameter sessionName: The tmux session name (e.g., "chrome-ai-bridge")
    /// - Returns: Terminal identifier (e.g., "ghostty", "iTerm.app") or nil
    static func getClientTerminalInfo(for sessionName: String) -> String? {
        // Get all clients with their PID and session
        let output = runCommand(tmuxPath, ["list-clients", "-F", "#{client_pid}|#{client_session}"])

        // Find the client attached to this session
        var clientPid: pid_t?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|").map(String.init)
            if parts.count >= 2 && parts[1] == sessionName {
                clientPid = pid_t(parts[0])
                break
            }
        }

        // If no client found for this session, try any client (tmux may share clients)
        if clientPid == nil {
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "|").map(String.init)
                if parts.count >= 1, let pid = pid_t(parts[0]) {
                    clientPid = pid
                    break
                }
            }
        }

        guard let pid = clientPid else {
            DebugLog.log("[TmuxHelper] No client found for session '\(sessionName)'")
            return nil
        }

        // Check terminal cache
        let now = Date()
        if let cached = terminalCache[pid],
           now.timeIntervalSince(cached.timestamp) < terminalCacheTTL {
            DebugLog.log("[TmuxHelper] Terminal cache hit for PID \(pid)")
            return cached.terminal
        }

        // Cache miss - trace parent process chain to find terminal
        let terminalInfo = traceParentToTerminal(pid: pid)
        terminalCache[pid] = (terminalInfo, now)
        DebugLog.log("[TmuxHelper] Session '\(sessionName)' client PID \(pid) -> terminal: \(terminalInfo ?? "unknown")")
        return terminalInfo
    }

    /// Trace parent process chain to find terminal application
    private static func traceParentToTerminal(pid: pid_t) -> String? {
        var currentPid = pid
        var visited = Set<pid_t>()

        while currentPid > 1 && !visited.contains(currentPid) {
            visited.insert(currentPid)

            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-o", "ppid=,comm=", "-p", "\(currentPid)"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                break
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else {
                break
            }

            let parts = output.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count >= 2 else { break }

            let ppid = pid_t(parts[0].trimmingCharacters(in: .whitespaces)) ?? 0
            let comm = parts[1].lowercased()

            // Check for known terminal applications
            if comm.contains("ghostty") {
                return "ghostty"
            } else if comm.contains("iterm") {
                return "iTerm.app"
            } else if comm.contains("terminal") && !comm.contains("iterm") {
                return "Apple_Terminal"
            }

            currentPid = ppid
        }

        return nil
    }

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
            DebugLog.log("[TmuxHelper] Command failed: \(executable) \(args)")
            return ""
        }
    }
}
