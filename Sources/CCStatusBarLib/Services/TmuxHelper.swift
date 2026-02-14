import Foundation
import Darwin

/// Build tmux attach command strings (pure function, extracted for testability)
enum TmuxAttachCommand {
    /// Build tmux attach command string for a session
    static func build(sessionName: String, socketPath: String?) -> String {
        if let socket = socketPath {
            return "tmux -S \(socket) attach -t \(sessionName)"
        }
        return "tmux attach -t \(sessionName)"
    }

    /// Build tmux attach command with full target (session:window.pane)
    static func buildFull(sessionName: String, window: String, pane: String, socketPath: String?) -> String {
        let target = "\(sessionName):\(window).\(pane)"
        if let socket = socketPath {
            return "tmux -S \(socket) attach -t \(target)"
        }
        return "tmux attach -t \(target)"
    }
}

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

    /// Lock to protect all mutable caches from concurrent access
    private static let cacheLock = NSLock()

    /// Cache for pane info by TTY (TTL: 5 seconds)
    private static var paneInfoCache: [String: (info: PaneInfo?, timestamp: Date)] = [:]
    private static let paneCacheTTL: TimeInterval = 5.0

    /// Cache for terminal detection by PID (TTL: 60 seconds)
    private static var terminalCache: [pid_t: (terminal: String?, timestamp: Date)] = [:]
    private static let terminalCacheTTL: TimeInterval = 60.0

    /// Cache for session attach states (TTL: 5 seconds)
    private struct AttachStatesSnapshot {
        let statesBySocket: [String: [String: Bool]]
        let mergedStates: [String: Bool]
        let timestamp: Date
    }
    private static var attachStatesCache: AttachStatesSnapshot?
    private static let attachStatesCacheTTL: TimeInterval = 5.0
    private static let unknownDefaultSocketKey = "__default__"

    /// Cache for discovered tmux socket paths (TTL: 30 seconds)
    private static var socketPathsCache: (paths: [String], timestamp: Date)?
    private static let socketPathsCacheTTL: TimeInterval = 30.0

    /// Invalidate pane info cache (called when session file changes)
    static func invalidatePaneInfoCache() {
        cacheLock.lock()
        paneInfoCache.removeAll()
        cacheLock.unlock()
        DebugLog.log("[TmuxHelper] Pane info cache invalidated")
    }

    /// Invalidate all caches
    static func invalidateAllCaches() {
        cacheLock.lock()
        paneInfoCache.removeAll()
        terminalCache.removeAll()
        attachStatesCache = nil
        socketPathsCache = nil
        cacheLock.unlock()
        DebugLog.log("[TmuxHelper] All caches invalidated")
    }

    /// Invalidate attach states cache only (for menu refresh)
    static func invalidateAttachStatesCache() {
        cacheLock.lock()
        attachStatesCache = nil
        cacheLock.unlock()
    }

    // MARK: - Pane Info (Cached)

    /// TTY から tmux ペイン情報を取得 (with caching)
    static func getPaneInfo(for tty: String) -> PaneInfo? {
        let now = Date()
        let normalizedTTY = normalizeTTY(tty)
        guard !normalizedTTY.isEmpty else { return nil }

        // Check cache (locked)
        cacheLock.lock()
        if let cached = paneInfoCache[normalizedTTY],
           now.timeIntervalSince(cached.timestamp) < paneCacheTTL {
            cacheLock.unlock()
            DebugLog.log("[TmuxHelper] Cache hit for TTY \(normalizedTTY)")
            return cached.info
        }
        cacheLock.unlock()

        // Cache miss - fetch from tmux (outside lock to avoid blocking)
        let info = fetchPaneInfoFromTmux(normalizedTTY)
        // Do not cache misses. Socket paths / tmux servers can change rapidly,
        // and negative caching causes long periods of fallback display.
        cacheLock.lock()
        if let info {
            paneInfoCache[normalizedTTY] = (info, now)
        } else {
            paneInfoCache.removeValue(forKey: normalizedTTY)
        }
        cacheLock.unlock()
        return info
    }

    /// Fetch pane info directly from tmux (no cache)
    private static func fetchPaneInfoFromTmux(_ tty: String) -> PaneInfo? {
        // Use tab separator to handle window names containing "|"
        let format = "#{pane_tty}\t#{session_name}\t#{window_index}\t#{pane_index}\t#{window_name}"
        let commandArgs = ["list-panes", "-a", "-F", format]
        var checkedSocketPaths = Set<String>()
        var diagnostics: [String] = []

        // 1) Try default tmux server (works when TMUX env is available)
        let defaultOutput = runTmuxCommandArgs(commandArgs)
        diagnostics.append("default:\(summarizePaneOutput(defaultOutput))")
        if let info = parsePaneInfo(from: defaultOutput, matchingTTY: tty, socketPath: nil) {
            return info
        }

        // 2) Fallback: search known socket files (works from GUI process without TMUX env)
        let socketPaths = discoverSocketPaths()
        for socketPath in socketPaths {
            checkedSocketPaths.insert(socketPath)
            let output = runTmuxCommandArgs(commandArgs, socketPath: socketPath)
            let name = URL(fileURLWithPath: socketPath).lastPathComponent
            diagnostics.append("socket[\(name)]:\(summarizePaneOutput(output))")
            if let info = parsePaneInfo(from: output, matchingTTY: tty, socketPath: socketPath) {
                return info
            }
        }

        // 3) Socket list might be stale (tmux restarted / socket moved). Refresh once and retry.
        let refreshedSocketPaths = discoverSocketPaths(forceRefresh: true)
        let retryPaths = refreshedSocketPaths.filter { !checkedSocketPaths.contains($0) }
        if !retryPaths.isEmpty {
            DebugLog.log("[TmuxHelper] Retry pane lookup after socket refresh for TTY \(tty)")
            for socketPath in retryPaths {
                let output = runTmuxCommandArgs(commandArgs, socketPath: socketPath)
                let name = URL(fileURLWithPath: socketPath).lastPathComponent
                diagnostics.append("retry[\(name)]:\(summarizePaneOutput(output))")
                if let info = parsePaneInfo(from: output, matchingTTY: tty, socketPath: socketPath) {
                    return info
                }
            }
        }

        let diagText = diagnostics.joined(separator: "; ")
        DebugLog.log("[TmuxHelper] No pane found for TTY \(tty) (checked default + discovered sockets) | \(diagText)")
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
        let socketPath: String?

        /// Generate the tmux attach command for remote access
        var attachCommand: String {
            TmuxAttachCommand.build(sessionName: sessionName, socketPath: socketPath)
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
            paneIndex: paneInfo.pane,
            socketPath: paneInfo.socketPath
        )
    }

    // MARK: - Session Attach States

    /// Get attached status for all tmux sessions
    /// - Returns: Dictionary of session_name -> is_attached
    static func getSessionAttachStates() -> [String: Bool] {
        return getAttachStatesSnapshot().mergedStates
    }

    /// Check if a specific tmux session is attached
    static func isSessionAttached(_ sessionName: String, socketPath: String? = nil) -> Bool {
        let snapshot = getAttachStatesSnapshot()
        let key = socketKey(for: socketPath)

        if let attached = snapshot.statesBySocket[key]?[sessionName] {
            return attached
        }

        // socketPath が不明な場合のみ、デフォルト問い合わせが失敗したケースの
        // フォールバックとして merged を参照する。
        if socketPath == nil {
            return snapshot.mergedStates[sessionName] ?? false
        }

        return false
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

    /// Capture pane output (last N lines)
    static func capturePane(target: String, lines: Int = 50, socketPath: String? = nil) -> String? {
        let args = ["capture-pane", "-p", "-t", target, "-S", "-\(lines)"]
        let output = runTmuxCommandArgs(args, socketPath: socketPath)
        return output.isEmpty ? nil : output
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
        cacheLock.lock()
        if let cached = terminalCache[pid],
           now.timeIntervalSince(cached.timestamp) < terminalCacheTTL {
            cacheLock.unlock()
            DebugLog.log("[TmuxHelper] Terminal cache hit for PID \(pid)")
            return cached.terminal
        }
        cacheLock.unlock()

        // Cache miss - trace parent process chain to find terminal
        let terminalInfo = traceParentToTerminal(pid: pid)
        cacheLock.lock()
        terminalCache[pid] = (terminalInfo, now)
        cacheLock.unlock()
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

    static func normalizeTTY(_ tty: String) -> String {
        let trimmed = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Some legacy/edge outputs can include extra tokens (e.g. "\\t" chunks or
        // underscored compact rows). Use only the first token as tty candidate.
        let firstToken = String(
            trimmed.split(whereSeparator: {
                $0 == "\t" || $0 == " " || $0 == "|" || $0 == "\\" || $0 == "_"
            }).first ?? Substring(trimmed)
        )

        if firstToken.hasPrefix("/dev/") {
            return firstToken
        }
        if firstToken.hasPrefix("dev/") {
            return "/\(firstToken)"
        }
        return "/dev/\(firstToken)"
    }

    /// Split a `tmux list-panes -F ...` row into 5 columns.
    /// Supports multiple delimiter formats to tolerate environment/version differences.
    static func splitPaneColumns(_ line: Substring) -> [String] {
        let raw = String(line)

        // Preferred/current formats
        for delimiter in ["\t", "\\t", "|"] {
            let parts = raw.components(separatedBy: delimiter)
            if parts.count >= 5 {
                // Join tail back into window_name in case it contains delimiter.
                return [
                    parts[0],
                    parts[1],
                    parts[2],
                    parts[3],
                    parts[4...].joined(separator: delimiter)
                ]
            }
        }

        // Legacy fallback: compact underscore-separated rows
        // e.g. /dev/ttys001_default-0_0_0_zsh
        let legacy = raw.split(separator: "_", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        if legacy.count >= 5 {
            return legacy
        }

        return []
    }

    static func parsePaneInfo(from output: String, matchingTTY tty: String, socketPath: String?) -> PaneInfo? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = splitPaneColumns(line)
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

    /// Summarize list-panes output for diagnostics.
    /// Example: "rows=3,ttys=/dev/ttys001,/dev/ttys002,+1"
    private static func summarizePaneOutput(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !lines.isEmpty else { return "rows=0" }

        let ttySamples = lines.prefix(2).map { line -> String in
            let parts = splitPaneColumns(line)
            guard let raw = parts.first else { return "unknown" }
            return normalizeTTY(raw)
        }
        let remaining = lines.count - ttySamples.count
        let suffix = remaining > 0 ? ",+\(remaining)" : ""
        return "rows=\(lines.count),ttys=\(ttySamples.joined(separator: ","))\(suffix)"
    }

    private static func getAttachStatesSnapshot() -> AttachStatesSnapshot {
        let now = Date()
        cacheLock.lock()
        if let cached = attachStatesCache,
           now.timeIntervalSince(cached.timestamp) < attachStatesCacheTTL {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let listSessionsArgs = ["list-sessions", "-F", "#{session_name}|#{session_attached}"]
        var statesBySocket: [String: [String: Bool]] = [:]
        let defaultKey = defaultSocketKey()

        // 1) Default server (or TMUX env-derived server)
        statesBySocket[defaultKey] = parseAttachStates(
            from: runTmuxCommandArgs(listSessionsArgs)
        )

        // 2) Additional sockets for GUI context without TMUX env
        for socketPath in discoverSocketPaths() {
            let key = socketKey(for: socketPath)
            statesBySocket[key] = parseAttachStates(
                from: runTmuxCommandArgs(listSessionsArgs, socketPath: socketPath)
            )
        }

        var merged: [String: Bool] = [:]
        for states in statesBySocket.values {
            for (sessionName, attached) in states {
                merged[sessionName] = (merged[sessionName] ?? false) || attached
            }
        }

        let snapshot = AttachStatesSnapshot(
            statesBySocket: statesBySocket,
            mergedStates: merged,
            timestamp: now
        )
        cacheLock.lock()
        attachStatesCache = snapshot
        cacheLock.unlock()
        DebugLog.log("[TmuxHelper] Fetched attach states by socket: \(statesBySocket)")
        return snapshot
    }

    static func parseAttachStates(from output: String) -> [String: Bool] {
        var states: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|").map(String.init)
            guard parts.count == 2 else { continue }
            states[parts[0]] = (parts[1] == "1")
        }
        return states
    }

    private static func defaultSocketKey() -> String {
        if let tmuxEnv = ProcessInfo.processInfo.environment["TMUX"],
           let rawSocket = tmuxEnv.split(separator: ",", maxSplits: 1).first {
            let socketPath = String(rawSocket)
            if !socketPath.isEmpty {
                return (socketPath as NSString).standardizingPath
            }
        }
        return unknownDefaultSocketKey
    }

    private static func socketKey(for socketPath: String?) -> String {
        if let socketPath = socketPath, !socketPath.isEmpty {
            return (socketPath as NSString).standardizingPath
        }
        return defaultSocketKey()
    }

    private static func discoverSocketPaths(forceRefresh: Bool = false) -> [String] {
        let now = Date()
        cacheLock.lock()
        if !forceRefresh,
           let cached = socketPathsCache,
           now.timeIntervalSince(cached.timestamp) < socketPathsCacheTTL {
            cacheLock.unlock()
            return cached.paths
        }
        cacheLock.unlock()

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

        let uniquePaths = deduplicatePaths(candidates)

        cacheLock.lock()
        socketPathsCache = (uniquePaths, now)
        cacheLock.unlock()
        return uniquePaths
    }

    /// Deduplicate and normalize socket path candidates (extracted for testability)
    static func deduplicatePaths(_ candidates: [String]) -> [String] {
        var uniquePaths: [String] = []
        var seen = Set<String>()
        let fileManager = FileManager.default
        for path in candidates {
            let normalizedPath = (path as NSString).standardizingPath
            guard !normalizedPath.isEmpty else { continue }
            guard !seen.contains(normalizedPath) else { continue }
            guard fileManager.fileExists(atPath: normalizedPath) else { continue }
            seen.insert(normalizedPath)
            uniquePaths.append(normalizedPath)
        }
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

            if process.terminationStatus != 0 {
                if errorOutput.isEmpty {
                    DebugLog.log("[TmuxHelper] Command failed (\(process.terminationStatus)): \(executable) \(args)")
                } else {
                    DebugLog.log("[TmuxHelper] Command failed (\(process.terminationStatus)): \(executable) \(args) | \(errorOutput)")
                }
            }

            return output
        } catch {
            DebugLog.log("[TmuxHelper] Command failed: \(executable) \(args)")
            return ""
        }
    }
}
