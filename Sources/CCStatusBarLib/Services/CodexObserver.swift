import Foundation
import Combine
import Darwin

struct CodexSessionSnapshot {
    let sessions: [String: CodexSession]
    let generation: Int
    let cacheAge: TimeInterval?
    let source: String
    let refreshDuration: TimeInterval?
    let discoveredCount: Int
    let excludedCounts: [String: Int]
}

struct CodexPaneIdentity: Equatable {
    let paneID: String
    let panePID: pid_t
    let panePIDStart: String?
    let agentPID: pid_t
    let agentPIDStart: String?
}

struct CodexStableTmuxInfo: Equatable {
    let paneID: String
    let panePID: pid_t
    let panePIDStart: String?
    let agentPID: pid_t
    let agentPIDStart: String?
    let session: String
    let window: String
    let pane: String
    let socketPath: String?
}

private struct CodexScanResult {
    let sessions: [String: CodexSession]
    let paneInfoByPID: [pid_t: CodexStableTmuxInfo]
    let excludedCounts: [String: Int]
    let discoveredCount: Int
}

struct CodexRefreshResult<Value> {
    let generation: Int
    let value: Value?
    let duration: TimeInterval
    let succeeded: Bool
}

/// A bounded, single-flight refresh coordinator used by the live Codex snapshot.
/// It never exposes stale values to callers waiting for an authoritative snapshot.
final class CodexRefreshCoordinator<Value>: @unchecked Sendable {
    struct Snapshot {
        let value: Value?
        let generation: Int
        let cacheAge: TimeInterval?
        let source: String
        let refreshDuration: TimeInterval?
    }

    private let freshTTL: TimeInterval
    private let scan: @Sendable () async throws -> Value
    private let onApplied: (@Sendable (CodexRefreshResult<Value>) -> Void)?
    private let lock = NSLock()
    private var generation = 0
    private var cache: (value: Value, timestamp: Date, generation: Int)?
    private var active: (generation: Int, task: Task<CodexRefreshResult<Value>, Never>)?
    private var appliedGeneration = 0

    init(
        freshTTL: TimeInterval = 5.0,
        scan: @escaping @Sendable () async throws -> Value,
        onApplied: (@Sendable (CodexRefreshResult<Value>) -> Void)? = nil
    ) {
        self.freshTTL = freshTTL
        self.scan = scan
        self.onApplied = onApplied
    }

    func invalidate() {
        lock.lock()
        if let cache {
            self.cache = (cache.value, cache.timestamp.addingTimeInterval(-freshTTL), cache.generation)
        }
        lock.unlock()
    }

    func cachedValue() -> (value: Value, timestamp: Date, generation: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    func snapshot(deadline: TimeInterval) async -> Snapshot {
        let now = Date()
        let prepared = prepareRefresh(now: now)
        if let fresh = prepared.fresh {
            return fresh
        }
        guard let task = prepared.task else {
            fatalError("Refresh preparation returned neither cache nor task")
        }
        let emptyGeneration = prepared.generation
        let staleAge = prepared.staleAge

        let refresh = await withTaskGroup(of: CodexRefreshResult<Value>?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                let nanoseconds = UInt64(max(0, deadline) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let refresh else {
            return Snapshot(
                value: nil,
                generation: emptyGeneration,
                cacheAge: staleAge,
                source: "deadline",
                refreshDuration: nil
            )
        }
        return Snapshot(
            value: refresh.value,
            generation: refresh.generation,
            cacheAge: 0,
            source: refresh.succeeded ? "refresh" : "refresh-failure",
            refreshDuration: refresh.duration
        )
    }

    private func prepareRefresh(now: Date) -> (
        fresh: Snapshot?,
        task: Task<CodexRefreshResult<Value>, Never>?,
        generation: Int,
        staleAge: TimeInterval?
    ) {
        lock.lock()
        if let cache, now.timeIntervalSince(cache.timestamp) < freshTTL {
            let result = Snapshot(
                value: cache.value,
                generation: cache.generation,
                cacheAge: now.timeIntervalSince(cache.timestamp),
                source: "fresh",
                refreshDuration: nil
            )
            lock.unlock()
            return (result, nil, cache.generation, now.timeIntervalSince(cache.timestamp))
        }
        let task = ensureRefreshLocked()
        let emptyGeneration = generation
        let staleAge = cache.map { now.timeIntervalSince($0.timestamp) }
        lock.unlock()
        return (nil, task, emptyGeneration, staleAge)
    }

    @discardableResult
    func beginNewGenerationForTesting() -> Int {
        lock.lock()
        generation += 1
        active = nil
        let current = generation
        lock.unlock()
        return current
    }

    private func ensureRefreshLocked() -> Task<CodexRefreshResult<Value>, Never> {
        if let active {
            return active.task
        }

        generation += 1
        let refreshGeneration = generation
        let scan = self.scan
        let task = Task.detached(priority: .utility) {
            let started = Date()
            do {
                let value = try await scan()
                return CodexRefreshResult(
                    generation: refreshGeneration,
                    value: value,
                    duration: Date().timeIntervalSince(started),
                    succeeded: true
                )
            } catch {
                return CodexRefreshResult(
                    generation: refreshGeneration,
                    value: nil,
                    duration: Date().timeIntervalSince(started),
                    succeeded: false
                )
            }
        }
        active = (refreshGeneration, task)

        Task { [weak self] in
            let result = await task.value
            self?.apply(result)
        }
        return task
    }

    private func apply(_ result: CodexRefreshResult<Value>) {
        var shouldNotify = false
        lock.lock()
        guard result.generation == generation,
              result.generation > appliedGeneration else {
            lock.unlock()
            return
        }
        appliedGeneration = result.generation
        active = nil
        if let value = result.value, result.succeeded {
            cache = (value, Date(), result.generation)
            shouldNotify = true
        }
        lock.unlock()
        if shouldNotify {
            onApplied?(result)
        }
    }
}

/// Observes active Codex CLI sessions by monitoring running processes
/// Matches Codex sessions with Claude Code sessions by cwd
enum CodexObserver {
    // MARK: - Mode

    /// When true, hooks-based session management is active (pgrep polling disabled)
    static var useHooksMode: Bool = false

    // MARK: - Cache

    private static let freshTTL: TimeInterval = 5.0
    private static let subscriberDeadline: TimeInterval = 0.8
    private static let snapshotCoordinator = CodexRefreshCoordinator<CodexScanResult>(
        freshTTL: freshTTL,
        scan: {
            fetchCodexScan()
        },
        onApplied: { result in
            Task { @MainActor in
                guard let scan = result.value else { return }
                publishScan(scan, generation: result.generation, duration: result.duration)
            }
        }
    )
    private static var paneInfoByPID: [pid_t: CodexStableTmuxInfo] = [:]
    private static var lastDiagnostics: CodexRefreshDiagnostics?

    struct CodexRefreshDiagnostics: Equatable {
        let generation: Int
        let cacheAge: TimeInterval?
        let source: String
        let refreshDuration: TimeInterval?
        let discoveredCount: Int
        let includedCount: Int
        let excludedCounts: [String: Int]
        let correctiveBroadcast: Bool
    }

    /// Mark cache as stale and let the existing single-flight scan converge it.
    static func invalidateCache() {
        snapshotCoordinator.invalidate()
        DebugLog.log("[CodexObserver] cache invalidated")
    }

    // MARK: - Public API

    /// Get all active Codex sessions indexed by internal id.
    /// In hooks mode, returns sessions from CodexHooksSessionStore (must be called from MainActor).
    /// In legacy mode, uses stale-while-revalidate cache with pgrep-based discovery.
    @MainActor
    static func getActiveSessions() -> [String: CodexSession] {
        if useHooksMode {
            CodexHooksSessionStore.shared.pruneDeadProcesses()
            return CodexHooksSessionStore.shared.activeSessions
        }
        return getActiveSessionsLegacy()
    }

    /// Legacy implementation: pgrep-based discovery with stale-while-revalidate cache.
    static func getActiveSessionsLegacy() -> [String: CodexSession] {
        let now = Date()
        if let cached = snapshotCoordinator.cachedValue() {
            if now.timeIntervalSince(cached.timestamp) < freshTTL {
                return cached.value.sessions
            }
            triggerBackgroundRefresh()
            return cached.value.sessions
        }

        triggerBackgroundRefresh()
        return [:]
    }

    /// Get an authoritative snapshot for a new WebSocket subscriber.
    /// Stale data is never returned here. A timeout returns an empty Codex set;
    /// the refresh completion publishes one corrective full-list broadcast.
    @MainActor
    static func snapshotForSubscriber() async -> CodexSessionSnapshot {
        if useHooksMode {
            CodexHooksSessionStore.shared.pruneDeadProcesses()
            return CodexSessionSnapshot(
                sessions: CodexHooksSessionStore.shared.activeSessions,
                generation: 0,
                cacheAge: 0,
                source: "hooks",
                refreshDuration: nil,
                discoveredCount: CodexHooksSessionStore.shared.activeSessions.count,
                excludedCounts: [:]
            )
        }

        let snapshot = await snapshotCoordinator.snapshot(deadline: subscriberDeadline)
        let scan = snapshot.value
        let sessions = scan?.sessions ?? [:]
        let discovered = scan?.discoveredCount ?? 0
        let excluded = scan?.excludedCounts ?? [:]
        if let scan {
            paneInfoByPID = scan.paneInfoByPID
        }
        let diagnostics = CodexRefreshDiagnostics(
            generation: snapshot.generation,
            cacheAge: snapshot.cacheAge,
            source: snapshot.source,
            refreshDuration: snapshot.refreshDuration,
            discoveredCount: discovered,
            includedCount: sessions.count,
            excludedCounts: excluded,
            correctiveBroadcast: false
        )
        logDiagnostics(diagnostics)
        return CodexSessionSnapshot(
            sessions: sessions,
            generation: snapshot.generation,
            cacheAge: snapshot.cacheAge,
            source: snapshot.source,
            refreshDuration: snapshot.refreshDuration,
            discoveredCount: discovered,
            excludedCounts: excluded
        )
    }

    @MainActor
    static func stableTmuxInfo(for session: CodexSession) -> CodexStableTmuxInfo? {
        guard let info = paneInfoByPID[session.pid],
              info.agentPID == session.pid,
              info.agentPIDStart == processStartToken(for: session.pid) else {
            return nil
        }
        return info
    }

    @MainActor
    static func logCorrectiveBroadcast() {
        guard let diagnostics = lastDiagnostics else { return }
        logDiagnostics(CodexRefreshDiagnostics(
            generation: diagnostics.generation,
            cacheAge: diagnostics.cacheAge,
            source: diagnostics.source,
            refreshDuration: diagnostics.refreshDuration,
            discoveredCount: diagnostics.discoveredCount,
            includedCount: diagnostics.includedCount,
            excludedCounts: diagnostics.excludedCounts,
            correctiveBroadcast: true
        ))
    }

    @MainActor
    private static func publishScan(_ scan: CodexScanResult, generation: Int, duration: TimeInterval) {
        paneInfoByPID = scan.paneInfoByPID
        let diagnostics = CodexRefreshDiagnostics(
            generation: generation,
            cacheAge: 0,
            source: "refresh",
            refreshDuration: duration,
            discoveredCount: scan.discoveredCount,
            includedCount: scan.sessions.count,
            excludedCounts: scan.excludedCounts,
            correctiveBroadcast: false
        )
        lastDiagnostics = diagnostics
        logDiagnostics(diagnostics)
        NotificationCenter.default.post(name: .codexSessionsDidUpdate, object: nil)
    }

    private static func logDiagnostics(_ diagnostics: CodexRefreshDiagnostics) {
        let cacheAge = diagnostics.cacheAge.map { String(format: "%.0f", $0 * 1000) } ?? "nil"
        let duration = diagnostics.refreshDuration.map { String(format: "%.0f", $0 * 1000) } ?? "nil"
        let exclusions = diagnostics.excludedCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        DebugLog.log(
            "[CodexObserver] snapshot generation=\(diagnostics.generation) cacheAgeMs=\(cacheAge) " +
            "source=\(diagnostics.source) refreshDurationMs=\(duration) " +
            "discovered=\(diagnostics.discoveredCount) included=\(diagnostics.includedCount) " +
            "exclusionReason=\(exclusions.isEmpty ? "none" : exclusions) " +
            "correctiveBroadcast=\(diagnostics.correctiveBroadcast)"
        )
    }

    /// Check if Codex is running for a specific cwd
    @MainActor
    static func isCodexRunning(for cwd: String) -> Bool {
        return getActiveSessions().values.contains { $0.cwd == cwd }
    }

    /// Get Codex session for a specific cwd.
    /// Prefers sessions with a resolved tmux pane (can be captured), falling back to lowest PID.
    @MainActor
    static func getCodexSession(for cwd: String) -> CodexSession? {
        let candidates = getActiveSessions().values.filter { $0.cwd == cwd }
        // Prefer session with tmux pane info (capturePane will work)
        if let withPane = candidates.filter({ $0.tmuxPane != nil }).sorted(by: { $0.pid < $1.pid }).first {
            return withPane
        }
        return candidates.sorted { $0.pid < $1.pid }.first
    }

    /// Get CodexInfo for WebSocket output
    @MainActor
    static func getCodexInfo(for cwd: String) -> CodexInfo? {
        guard let session = getCodexSession(for: cwd) else {
            return nil
        }
        return CodexInfo(
            pid: session.pid,
            isActive: true,
            startedAt: session.startedAt,
            sessionId: session.sessionId,
            tokenUsage: session.tokenUsage,
            cliVersion: session.cliVersion,
            modelProvider: session.modelProvider
        )
    }

    // MARK: - Background Refresh

    private static func triggerBackgroundRefresh() {
        Task.detached(priority: .utility) {
            _ = await snapshotCoordinator.snapshot(deadline: 0)
        }
    }

    // MARK: - Public Wrappers (for CodexHooksSessionStore)

    /// Public wrapper for fetchCodexSessions (used by hooks mode bootstrap)
    static func fetchCodexSessionsPublic() -> [String: CodexSession] {
        fetchCodexScan().sessions
    }

    /// Find PID for a given cwd by scanning running Codex processes
    static func findPidForCwd(_ cwd: String) -> pid_t? {
        let pids = getCodexPIDs()
        for pid in pids {
            if let pidCwd = getCwd(for: pid), pidCwd == cwd {
                return pid
            }
        }
        return nil
    }

    /// Public wrapper for getTTY
    static func getTTYPublic(for pid: pid_t) -> String? {
        getTTY(for: pid)
    }

    /// Public wrapper for findCodexSessionExtended
    static func findExtendedInfoPublic(for cwd: String) -> CodexSessionFileInfo? {
        findCodexSessionExtended(for: cwd)
    }

    // MARK: - Private

    /// Fetch active Codex sessions and stable pane evidence from running processes.
    private static func fetchCodexScan() -> CodexScanResult {
        var sessions: [String: CodexSession] = [:]
        var paneInfoByPID: [pid_t: CodexStableTmuxInfo] = [:]

        let pidScan = getCodexPIDScan()
        let pids = pidScan.pids

        for pid in pids {
            if let cwd = getCwd(for: pid) {
                var session = CodexSession(pid: pid, cwd: cwd)

                // Try to find extended session info from Codex session files
                if let extInfo = findCodexSessionExtended(for: cwd) {
                    session.sessionId = extInfo.sessionId
                    session.cliVersion = extInfo.cliVersion
                    session.modelProvider = extInfo.modelProvider
                    session.originator = extInfo.originator
                    session.tokenUsage = extInfo.tokenUsage
                } else {
                    session.sessionId = findCodexSessionId(for: cwd)
                }

                if let tty = getTTY(for: pid) {
                    session.tty = tty
                    if let stablePane = resolveStablePane(for: pid, tty: tty) {
                        session.tmuxSession = stablePane.session
                        session.tmuxWindow = stablePane.window
                        session.tmuxPane = stablePane.pane
                        session.tmuxSocketPath = stablePane.socketPath
                        paneInfoByPID[pid] = stablePane

                        if let terminalApp = TmuxHelper.getClientTerminalInfo(for: stablePane.session) {
                            session.terminalApp = terminalApp
                        }
                    }
                }

                let key = "codex:\(pid)"
                sessions[key] = session
            }
        }

        return CodexScanResult(
            sessions: sessions,
            paneInfoByPID: paneInfoByPID,
            excludedCounts: pidScan.excludedCounts,
            discoveredCount: pids.count
        )
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

    private static func getCodexPIDs() -> [pid_t] {
        getCodexPIDScan().pids
    }

    private static func getCodexPIDScan() -> (pids: [pid_t], excludedCounts: [String: Int]) {
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

        var excludedCounts: [String: Int] = [:]
        let filteredPIDs = pidSet.filter { pid in
            let commandLine = getCommandLine(for: pid)
            if let reason = codexCommandExclusionReason(commandLine) {
                excludedCounts[reason, default: 0] += 1
                return false
            }
            return true
        }

        return (Array(filteredPIDs).sorted(), excludedCounts)
    }

    /// Check whether a Codex command line should be tracked as an active Codex session.
    /// Visible for tests.
    static func shouldTrackCodexCommandLine(_ commandLine: String) -> Bool {
        codexCommandExclusionReason(commandLine) == nil
    }

    static func codexCommandExclusionReason(_ commandLine: String) -> String? {
        let normalized = commandLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "empty-command" }

        // Tokenize and check if non-interactive subcommands appear as standalone arguments.
        // This avoids false exclusion when the subcommand name appears in paths or other arguments.
        let tokens = normalized.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if tokens.contains("mcp-server") { return "mcp-server" }
        // `codex app-server` is the GUI Codex.app / Computer Use protocol server,
        // not an interactive terminal CLI session. It shares the `codex` executable
        // name (so pgrep -x catches it) and often inherits a CLI session's cwd,
        // producing duplicate entries. Exclude it.
        if tokens.contains("app-server") { return "app-server" }
        if tokens.contains("exec") { return "exec" }
        if tokens.contains("--dangerously-bypass-approvals-and-sandbox") { return "unsafe-mode" }

        return nil
    }

    /// Get full command line for a process
    private static func getCommandLine(for pid: pid_t) -> String {
        runCommand("/bin/ps", ["-p", "\(pid)", "-o", "command="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct LivePaneRow {
        let paneID: String
        let panePID: pid_t
        let tty: String
        let session: String
        let window: String
        let pane: String
    }

    private static func resolveStablePane(for agentPID: pid_t, tty: String) -> CodexStableTmuxInfo? {
        let agentStart = processStartToken(for: agentPID)
        guard !tty.isEmpty else { return nil }

        let paths: [String?] = [nil] + discoverTmuxSocketPaths().map(Optional.some)
        for socketPath in paths {
            let format = "#{pane_id}\\t#{pane_pid}\\t#{pane_tty}\\t#{session_name}\\t#{window_index}\\t#{pane_index}\\t#{window_name}"
            var args: [String] = []
            if let socketPath, !socketPath.isEmpty {
                args += ["-S", socketPath]
            }
            args += ["list-panes", "-a", "-F", format]
            let output = runCommand(tmuxExecutable(), args)
            for line in output.split(separator: "\n") {
                guard let row = parseLivePaneRow(line),
                      TmuxHelper.normalizeTTY(row.tty) == TmuxHelper.normalizeTTY(tty),
                      row.paneID.hasPrefix("%"),
                      row.panePID > 0,
                      isProcessDescendant(agentPID, of: row.panePID) else {
                    continue
                }
                return CodexStableTmuxInfo(
                    paneID: row.paneID,
                    panePID: row.panePID,
                    panePIDStart: processStartToken(for: row.panePID),
                    agentPID: agentPID,
                    agentPIDStart: agentStart,
                    session: row.session,
                    window: row.window,
                    pane: row.pane,
                    socketPath: socketPath
                )
            }
        }
        return nil
    }

    static func stablePaneIdentityMatches(_ expected: CodexStableTmuxInfo, _ current: CodexStableTmuxInfo) -> Bool {
        guard expected.paneID == current.paneID,
              expected.panePID == current.panePID,
              expected.agentPID == current.agentPID else {
            return false
        }
        if let expectedStart = expected.agentPIDStart,
           let currentStart = current.agentPIDStart,
           expectedStart != currentStart {
            return false
        }
        if let expectedPaneStart = expected.panePIDStart,
           let currentPaneStart = current.panePIDStart,
           expectedPaneStart != currentPaneStart {
            return false
        }
        return true
    }

    private static func parseLivePaneRow(_ line: Substring) -> LivePaneRow? {
        let raw = String(line)
        let parts: [String]
        if raw.contains("\\t") {
            parts = raw.components(separatedBy: "\\t")
        } else {
            parts = raw.components(separatedBy: "\t")
        }
        guard parts.count >= 6,
              let panePID = pid_t(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return LivePaneRow(
            paneID: parts[0],
            panePID: panePID,
            tty: parts[2],
            session: parts[3],
            window: parts[4],
            pane: parts[5]
        )
    }

    private static func tmuxExecutable() -> String {
        for path in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "tmux"
    }

    private static func discoverTmuxSocketPaths() -> [String] {
        let uid = Int(getuid())
        let directories = ["/private/tmp/tmux-\(uid)", "/tmp/tmux-\(uid)"]
        var candidates: [String] = []
        if let tmux = ProcessInfo.processInfo.environment["TMUX"],
           let socket = tmux.split(separator: ",", maxSplits: 1).first,
           !socket.isEmpty {
            candidates.append(String(socket))
        }
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            candidates += entries.map { (directory as NSString).appendingPathComponent($0) }
        }
        var seen = Set<String>()
        return candidates.compactMap { path in
            let normalized = (path as NSString).standardizingPath
            guard !normalized.isEmpty,
                  FileManager.default.fileExists(atPath: normalized),
                  seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func isProcessDescendant(_ processPID: pid_t, of ancestorPID: pid_t) -> Bool {
        var current = processPID
        var visited = Set<pid_t>()
        while current > 1, visited.insert(current).inserted {
            if current == ancestorPID { return true }
            guard let parent = processParentPID(for: current), parent != current else { return false }
            current = parent
        }
        return false
    }

    private static func processParentPID(for pid: pid_t) -> pid_t? {
        let output = runCommand("/bin/ps", ["-p", "\(pid)", "-o", "ppid="])
        return pid_t(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func processStartToken(for pid: pid_t) -> String? {
        let output = runCommand("/bin/ps", ["-p", "\(pid)", "-o", "lstart="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
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

    /// Find extended Codex session info from session files.
    /// Searches recent day directories (today -> 14 days back) for matching cwd.
    private static func findCodexSessionExtended(for cwd: String) -> CodexSessionFileInfo? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let sessionsDir = homeDir.appendingPathComponent(".codex/sessions")

        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return nil }

        let calendar = Calendar.current
        let now = Date()

        // Search today and up to 14 days back (most recent first)
        for daysBack in 0..<14 {
            guard let date = calendar.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            let year = calendar.component(.year, from: date)
            let month = calendar.component(.month, from: date)
            let day = calendar.component(.day, from: date)

            let dayDir = sessionsDir
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))

            guard FileManager.default.fileExists(atPath: dayDir.path),
                  let files = try? FileManager.default.contentsOfDirectory(atPath: dayDir.path) else {
                continue
            }

            let rolloutFiles = files
                .filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
                .sorted()
                .reversed()  // Most recent first

            for filename in rolloutFiles {
                let filePath = dayDir.appendingPathComponent(filename)
                if let info = parseCodexSessionFileExtended(filePath, lookingForCwd: cwd) {
                    return info
                }
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

    /// Extended parse result from a Codex session JSONL file
    struct CodexSessionFileInfo {
        let sessionId: String
        let cwd: String
        var cliVersion: String?
        var modelProvider: String?
        var originator: String?
        var tokenUsage: CodexTokenUsage?
    }

    /// Parse a Codex session JSONL file extracting session_meta (head) + token_count (tail).
    /// Reads only the first line and last 8KB to stay fast on large files.
    static func parseCodexSessionFileExtended(_ url: URL, lookingForCwd cwd: String) -> CodexSessionFileInfo? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }

        // --- Head: first line for session_meta ---
        // Codex session_meta includes base_instructions (~15KB), so we need a large read.
        let headChunkSize = 32768
        guard let headData = try? fileHandle.read(upToCount: headChunkSize),
              let headStr = String(data: headData, encoding: .utf8),
              let firstLine = headStr.split(separator: "\n").first,
              let lineData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = json["type"] as? String,
              type == "session_meta",
              let payload = json["payload"] as? [String: Any],
              let fileCwd = payload["cwd"] as? String,
              fileCwd == cwd,
              let sessionId = payload["id"] as? String else {
            return nil
        }

        var info = CodexSessionFileInfo(sessionId: sessionId, cwd: fileCwd)
        info.cliVersion = payload["cli_version"] as? String
        info.modelProvider = payload["model_provider"] as? String
        info.originator = payload["originator"] as? String

        // --- Tail: last 8KB for latest token_count ---
        let tailReadSize: UInt64 = 8192
        let fileSize = fileHandle.seekToEndOfFile()
        let tailOffset = fileSize > tailReadSize ? fileSize - tailReadSize : 0
        fileHandle.seek(toFileOffset: tailOffset)
        if let tailData = try? fileHandle.read(upToCount: Int(min(tailReadSize, fileSize))),
           let tailStr = String(data: tailData, encoding: .utf8) {
            // Walk lines in reverse to find the latest token_count event.
            // Codex JSONL uses nested structure:
            //   {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{...}}}}
            let lines = tailStr.split(separator: "\n")
            for line in lines.reversed() {
                guard let ld = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else {
                    continue
                }
                // Support both flat and nested (event_msg wrapper) formats
                let tokenPayload: [String: Any]?
                if let t = obj["type"] as? String, t == "token_count" {
                    // Flat: {"type":"token_count","payload":{...}}
                    tokenPayload = obj["payload"] as? [String: Any] ?? obj
                } else if let t = obj["type"] as? String, t == "event_msg",
                          let payload = obj["payload"] as? [String: Any],
                          let innerType = payload["type"] as? String,
                          innerType == "token_count" {
                    // Nested: {"type":"event_msg","payload":{"type":"token_count","info":{...}}}
                    tokenPayload = payload
                } else {
                    continue
                }

                guard let tp = tokenPayload else { continue }

                // Extract from "info.total_token_usage" (nested) or direct fields (flat)
                let usageDict: [String: Any]?
                if let infoDict = tp["info"] as? [String: Any],
                   let totalUsage = infoDict["total_token_usage"] as? [String: Any] {
                    usageDict = totalUsage
                } else {
                    usageDict = tp
                }

                guard let ud = usageDict else { continue }
                let input = ud["input_tokens"] as? Int ?? 0
                let output = ud["output_tokens"] as? Int ?? 0
                let total = ud["total_tokens"] as? Int ?? (input + output)
                info.tokenUsage = CodexTokenUsage(inputTokens: input, outputTokens: output, totalTokens: total)
                break
            }
        }

        return info
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
    /// Uses DispatchSemaphore instead of waitUntilExit() to avoid spinning the
    /// CFRunLoop, which can trigger re-entrant SwiftUI layout and crash.
    private static func runCommand(_ executable: String, _ args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(args)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            let semaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in semaphore.signal() }
            try process.run()
            semaphore.wait()
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
