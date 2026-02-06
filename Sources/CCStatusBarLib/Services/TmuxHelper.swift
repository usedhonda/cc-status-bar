import Foundation
import Darwin

enum TmuxHelper {
    struct PaneInfo {
        let session: String
        let window: String
        let pane: String
        let windowName: String  // tmux window name
        let socketPath: String?  // tmux socket path (for non-default servers)

        init(session: String, window: String, pane: String, windowName: String = "", socketPath: String? = nil) {
            self.session = session
            self.window = window
            self.pane = pane
            self.windowName = windowName
            self.socketPath = socketPath
        }
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

    /// Cache for discovered tmux socket paths (TTL: 30 seconds)
    private static var socketPathsCache: (paths: [String], timestamp: Date)?
    private static let socketPathsCacheTTL: TimeInterval = 30.0

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
        socketPathsCache = nil
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
        let normalizedTTY = normalizeTTY(tty)

        // Check cache
        if let cached = paneInfoCache[normalizedTTY],
           now.timeIntervalSince(cached.timestamp) < paneCacheTTL {
            DebugLog.log("[TmuxHelper] Cache hit for TTY \(normalizedTTY)")
            return cached.info
        }

        // Cache miss - fetch from tmux
        let info = fetchPaneInfoFromTmux(normalizedTTY)
        paneInfoCache[normalizedTTY] = (info, now)
        return info
    }

    /// Fetch pane info directly from tmux (no cache)
    private static func fetchPaneInfoFromTmux(_ tty: String) -> PaneInfo? {
        // Use tab separator to handle window names containing "|"
        let format = "#{pane_tty}\t#{session_name}\t#{window_index}\t#{pane_index}\t#{window_name}"
        let commandArgs = ["list-panes", "-a", "-F", format]

        // 1) Try default tmux server (works when TMUX env is available)
        let defaultOutput = runTmuxCommandArgs(commandArgs)
        if let info = parsePaneInfo(from: defaultOutput, matchingTTY: tty, socketPath: nil) {
            return info
        }

        // 2) Fallback: search known socket files (works from GUI process without TMUX env)
        for socketPath in discoverSocketPaths() {
            let output = runTmuxCommandArgs(commandArgs, socketPath: socketPath)
            if let info = parsePaneInfo(from: output, matchingTTY: tty, socketPath: socketPath) {
                return info
            }
        }

        DebugLog.log("[TmuxHelper] No pane found for TTY \(tty) (checked default + discovered sockets)")
        return nil
    }

    /// ウィンドウとペインを選択（アクティブに）
    static func selectPane(_ info: PaneInfo) -> Bool {
        let windowTarget = "\(info.session):\(info.window)"
        let paneTarget = "\(info.session):\(info.window).\(info.pane)"

        // 1. ウィンドウを選択（タブ切り替え）
        _ = runTmuxCommandArgs(["select-window", "-t", windowTarget], socketPath: info.socketPath)

        // 2. ペインを選択
        _ = runTmuxCommandArgs(["select-pane", "-t", paneTarget], socketPath: info.socketPath)

        if let socketPath = info.socketPath {
            DebugLog.log("[TmuxHelper] Selected pane: \(paneTarget) via socket \(socketPath)")
        } else {
            DebugLog.log("[TmuxHelper] Selected pane: \(paneTarget)")
        }
        return true
    }

    // MARK: - Remote Access Support

    /// Information for remote access to a tmux session
    struct RemoteAccessInfo {
        let sessionName: String
        let windowIndex: String
        let paneIndex: String

        /// Generate the tmux attach command for remote access
        var attachCommand: String {
            "tmux attach -t \(sessionName)"
        }

        /// Generate the full target specifier (session:window.pane)
        var targetSpecifier: String {
            "\(sessionName):\(windowIndex).\(paneIndex)"
        }
    }

    /// Get remote access info for a session by TTY
    /// - Parameter tty: The TTY path (e.g., "/dev/ttys001")
    /// - Returns: RemoteAccessInfo if the session is in tmux, nil otherwise
    static func getRemoteAccessInfo(for tty: String) -> RemoteAccessInfo? {
        guard let paneInfo = getPaneInfo(for: tty) else {
            return nil
        }
        return RemoteAccessInfo(
            sessionName: paneInfo.session,
            windowIndex: paneInfo.window,
            paneIndex: paneInfo.pane
        )
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

        var states: [String: Bool] = [:]

        // 1) Default server (or TMUX env-derived server)
        mergeAttachStates(
            from: runTmuxCommandArgs(["list-sessions", "-F", "#{session_name}|#{session_attached}"]),
            into: &states
        )

        // 2) Additional sockets for GUI context without TMUX env
        for socketPath in discoverSocketPaths() {
            mergeAttachStates(
                from: runTmuxCommandArgs(["list-sessions", "-F", "#{session_name}|#{session_attached}"], socketPath: socketPath),
                into: &states
            )
        }

        attachStatesCache = (states, now)
        DebugLog.log("[TmuxHelper] Fetched attach states: \(states)")
        return states
    }

    /// Check if a specific tmux session is attached
    static func isSessionAttached(_ sessionName: String) -> Bool {
        return getSessionAttachStates()[sessionName] ?? false
    }

    /// List all tmux session names
    /// - Returns: Array of session names, or nil if tmux is not running
    static func listSessions() -> [String]? {
        let states = getSessionAttachStates()
        return states.isEmpty ? nil : Array(states.keys).sorted()
    }

    /// Run a tmux command and return output
    static func runTmuxCommand(_ args: String...) -> String {
        return runTmuxCommandArgs(args)
    }

    /// Send keys to a tmux pane
    /// - Parameters:
    ///   - paneInfo: Target pane information
    ///   - keys: Keys to send (e.g., "C-c" for Ctrl+C)
    /// - Returns: true if successful
    @discardableResult
    static func sendKeys(_ paneInfo: PaneInfo, keys: String) -> Bool {
        let target = "\(paneInfo.session):\(paneInfo.window).\(paneInfo.pane)"
        _ = runTmuxCommandArgs(["send-keys", "-t", target, keys], socketPath: paneInfo.socketPath)
        DebugLog.log("[TmuxHelper] Sent keys '\(keys)' to \(target)")
        return true
    }

    /// Detect the parent terminal application for a tmux session (with caching)
    /// - Parameter sessionName: The tmux session name (e.g., "chrome-ai-bridge")
    /// - Returns: Terminal identifier (e.g., "ghostty", "iTerm.app") or nil
    static func getClientTerminalInfo(for sessionName: String) -> String? {
        // Get all clients with their PID and session.
        // Try default server first, then discovered socket files.
        var clientOutputs: [String] = []
        clientOutputs.append(runTmuxCommandArgs(["list-clients", "-F", "#{client_pid}|#{client_session}"]))
        for socketPath in discoverSocketPaths() {
            clientOutputs.append(runTmuxCommandArgs(["list-clients", "-F", "#{client_pid}|#{client_session}"], socketPath: socketPath))
        }

        // Find the client attached to this session
        var clientPid: pid_t?
        for output in clientOutputs {
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "|").map(String.init)
                if parts.count >= 2 && parts[1] == sessionName {
                    clientPid = pid_t(parts[0])
                    break
                }
            }
            if clientPid != nil {
                break
            }
        }

        // If no client found for this session, try any client (tmux may share clients)
        if clientPid == nil {
            for output in clientOutputs {
                for line in output.split(separator: "\n") {
                    let parts = line.split(separator: "|").map(String.init)
                    if parts.count >= 1, let pid = pid_t(parts[0]) {
                        clientPid = pid
                        break
                    }
                }
                if clientPid != nil {
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

    private static func normalizeTTY(_ tty: String) -> String {
        let trimmed = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("/dev/") {
            return trimmed
        }
        if trimmed.hasPrefix("dev/") {
            return "/\(trimmed)"
        }
        return "/dev/\(trimmed)"
    }

    private static func parsePaneInfo(from output: String, matchingTTY tty: String, socketPath: String?) -> PaneInfo? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { continue }
            if normalizeTTY(parts[0]) == tty {
                DebugLog.log("[TmuxHelper] Found pane: \(parts[1]):\(parts[2]).\(parts[3]) (window: \(parts[4])) for TTY \(tty)")
                return PaneInfo(
                    session: parts[1],
                    window: parts[2],
                    pane: parts[3],
                    windowName: parts[4],
                    socketPath: socketPath
                )
            }
        }
        return nil
    }

    private static func mergeAttachStates(from output: String, into states: inout [String: Bool]) {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|").map(String.init)
            guard parts.count == 2 else { continue }
            let attached = (parts[1] == "1")
            // Keep `true` if any socket reports the session as attached
            states[parts[0]] = (states[parts[0]] ?? false) || attached
        }
    }

    private static func discoverSocketPaths() -> [String] {
        let now = Date()
        if let cached = socketPathsCache,
           now.timeIntervalSince(cached.timestamp) < socketPathsCacheTTL {
            return cached.paths
        }

        var candidates: [String] = []

        // If TMUX env exists (CLI context), prioritize that socket.
        if let tmuxEnv = ProcessInfo.processInfo.environment["TMUX"],
           let rawSocket = tmuxEnv.split(separator: ",", maxSplits: 1).first {
            let socketPath = String(rawSocket)
            if !socketPath.isEmpty {
                candidates.append(socketPath)
            }
        }

        let uid = Int(getuid())
        let socketDirs = ["/private/tmp/tmux-\(uid)", "/tmp/tmux-\(uid)"]
        let fileManager = FileManager.default

        for dir in socketDirs {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            if let entries = try? fileManager.contentsOfDirectory(atPath: dir) {
                for entry in entries {
                    let path = (dir as NSString).appendingPathComponent(entry)
                    candidates.append(path)
                }
            }
        }

        // Explicit defaults as final fallback
        candidates.append("/private/tmp/tmux-\(uid)/default")
        candidates.append("/tmp/tmux-\(uid)/default")

        var uniquePaths: [String] = []
        var seen = Set<String>()
        for path in candidates {
            let normalizedPath = (path as NSString).standardizingPath
            guard !normalizedPath.isEmpty else { continue }
            guard !seen.contains(normalizedPath) else { continue }
            guard fileManager.fileExists(atPath: normalizedPath) else { continue }
            seen.insert(normalizedPath)
            uniquePaths.append(normalizedPath)
        }

        socketPathsCache = (uniquePaths, now)
        return uniquePaths
    }

    private static func runTmuxCommandArgs(_ args: [String], socketPath: String? = nil) -> String {
        var fullArgs: [String] = []
        if let socketPath = socketPath, !socketPath.isEmpty {
            fullArgs += ["-S", socketPath]
        }
        fullArgs += args
        return runCommand(tmuxPath, fullArgs)
    }

    private static func runCommand(_ executable: String, _ args: [String]) -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(args)
        } else {
            // Fallback to PATH lookup (important when tmux is not in hardcoded locations)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + Array(args)
        }

        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0, !errorOutput.isEmpty {
                DebugLog.log("[TmuxHelper] Command failed (\(process.terminationStatus)): \(executable) \(args) | \(errorOutput)")
            }

            return output
        } catch {
            DebugLog.log("[TmuxHelper] Command failed: \(executable) \(args)")
            return ""
        }
    }
}
