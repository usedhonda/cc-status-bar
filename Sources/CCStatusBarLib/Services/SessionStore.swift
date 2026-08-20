import Foundation

struct ClaudeAgentRecord: Decodable {
    let sessionId: String?
    let cwd: String?
    let pid: Int?
    /// "interactive" for a session a human is attached to, "background" for a subagent.
    let kind: String?
    /// The CLI's own view: "busy" while working, "waiting"/"idle" while it needs input.
    let status: String?
}

struct ClaudeGhostCleanupResult: Equatable {
    var markedStopped: [String] = []
    var removed: [String] = []
    var seeded: [String] = []
    var skippedReason: String?

    var changed: Bool {
        !markedStopped.isEmpty || !removed.isEmpty || !seeded.isEmpty
    }
}

final class SessionStore {
    static let shared = SessionStore()
    static let claudeGhostRemovalGrace: TimeInterval = 60 * 60

    private let storeDir: URL
    private let storeFile: URL

    private init() {
        storeDir = SetupManager.appSupportDir
        storeFile = SetupManager.sessionsFile
    }

    // MARK: - Read

    func getSessions() -> [Session] {
        return AgentTeamFilter.filterSubagents(loadData().activeSessions)
    }

    // MARK: - Write (CCSB Protocol)

    /// Update session from CCSB Events Protocol event
    func updateSession(ccsbEvent: CCSBEvent) -> Session? {
        // session.stop: remove the session entirely
        if ccsbEvent.event == .sessionStop {
            removeSession(sessionId: ccsbEvent.sessionId, tty: ccsbEvent.tty)
            return nil
        }

        var data = loadData()

        // Determine session key (handle both nil and empty string TTY)
        let key: String
        if let tty = ccsbEvent.tty, !tty.isEmpty {
            key = "\(ccsbEvent.sessionId):\(tty)"
        } else {
            key = ccsbEvent.sessionId
        }

        // Capture displayOrder from session being replaced on same TTY
        var inheritedDisplayOrder: Int? = nil
        if let tty = ccsbEvent.tty, !tty.isEmpty {
            for (k, v) in data.sessions {
                if v.tty == tty && k != key {
                    inheritedDisplayOrder = v.displayOrder
                    break
                }
            }
            data.sessions = data.sessions.filter { (k, v) in
                if v.tty == tty && k != key {
                    return false
                }
                return true
            }
        }

        // Create or update session
        let existing = data.sessions[key]
        var session = ccsbEvent.toSession(existingSession: existing)

        // Handle displayOrder: inherit from replaced session or assign new
        if existing == nil {
            if let inherited = inheritedDisplayOrder {
                session.displayOrder = inherited
                DebugLog.log("[SessionStore] CCSB: inherited displayOrder \(inherited) from replaced TTY session")
            } else {
                let maxOrder = data.sessions.values.compactMap { $0.displayOrder }.max() ?? 0
                session.displayOrder = maxOrder + 1
                DebugLog.log("[SessionStore] CCSB: assigned new displayOrder \(maxOrder + 1)")
            }
        }

        // Capture Ghostty tab index for Bind-on-start on new sessions
        // Note: CCSB events don't have termProgram, so we check if Ghostty is the only terminal running
        // TODO: Add termProgram to CCSB protocol for accurate detection
        if existing == nil && ccsbEvent.event == .sessionStart && GhosttyHelper.isRunning && !ITerm2Helper.isRunning {
            if let tty = ccsbEvent.tty, TmuxHelper.getPaneInfo(for: tty) == nil {
                session.ghosttyTabIndex = GhosttyHelper.getSelectedTabIndex()
                if let idx = session.ghosttyTabIndex {
                    DebugLog.log("[SessionStore] CCSB Bind-on-start: captured tab index \(idx) for session \(ccsbEvent.sessionId)")
                }
            }
        } else if let existing = existing {
            session.ghosttyTabIndex = existing.ghosttyTabIndex
        }

        data.sessions[key] = session
        data.updatedAt = Date()

        // Check for duplicate project names and mark for disambiguation
        disambiguateIfNeeded(&data)

        saveData(data)

        DebugLog.log("[SessionStore] CCSB event processed: \(ccsbEvent.event.rawValue) for \(ccsbEvent.tool.name)")

        return session
    }

    // MARK: - Write (Legacy Hook Events)

    func updateSession(event: HookEvent) -> Session? {
        // SessionEnd: remove the session entirely
        if event.hookEventName == .sessionEnd {
            removeSession(sessionId: event.sessionId, tty: event.tty)
            return nil
        }

        var data = loadData()

        // Determine session key (handle both nil and empty string TTY)
        let key: String
        if let tty = event.tty, !tty.isEmpty {
            key = "\(event.sessionId):\(tty)"
        } else {
            key = event.sessionId
        }

        // Capture displayOrder from session being replaced on same TTY
        var inheritedDisplayOrder: Int? = nil
        if let tty = event.tty, !tty.isEmpty {
            for (k, v) in data.sessions {
                if v.tty == tty && k != key {
                    inheritedDisplayOrder = v.displayOrder
                    break
                }
            }
            data.sessions = data.sessions.filter { (k, v) in
                if v.tty == tty && k != key {
                    return false
                }
                return true
            }
        }

        // Create or update session
        let now = Date()
        var session: Session

        if var existing = data.sessions[key] {
            let (status, waitingReason, isToolRunning) = Self.determineStatusAndReason(event: event, current: existing.status)
            DebugLog.log("[SessionStore] Update session \(key): \(existing.status) -> \(status), reason: \(String(describing: waitingReason)), toolRunning: \(isToolRunning)")
            existing.status = status
            existing.waitingReason = waitingReason
            if waitingReason == .askUserQuestion {
                existing.questionText = event.question?.text
                existing.questionOptions = event.question?.options.map(\.label)
                existing.questionSelected = event.question?.selectedIndex
            } else if status == .running || status == .stopped {
                existing.questionText = nil
                existing.questionOptions = nil
                existing.questionSelected = nil
            }
            existing.isToolRunning = isToolRunning
            existing.updatedAt = now
            // Update termProgram if provided (first value wins)
            if existing.termProgram == nil, let termProgram = event.termProgram {
                existing.termProgram = termProgram
            }
            // Update actualTermProgram if provided (for tmux sessions)
            if existing.actualTermProgram == nil, let actualTermProgram = event.actualTermProgram {
                existing.actualTermProgram = actualTermProgram
            }
            // Update editorBundleID if provided (first value wins)
            if existing.editorBundleID == nil, let bundleID = event.editorBundleID {
                existing.editorBundleID = bundleID
            }
            // Update editorPID if provided (first value wins)
            if existing.editorPID == nil, let pid = event.editorPID {
                existing.editorPID = pid
            }
            session = existing
        } else {
            // New session - capture Ghostty tab index for Bind-on-start
            var tabIndex: Int? = nil
            let isGhosttySession = event.termProgram?.lowercased() == "ghostty"
            if event.hookEventName == .sessionStart && isGhosttySession && GhosttyHelper.isRunning {
                // Only bind tab for non-tmux Ghostty sessions (tmux uses title search)
                if let tty = event.tty, TmuxHelper.getPaneInfo(for: tty) == nil {
                    tabIndex = GhosttyHelper.getSelectedTabIndex()
                    if let idx = tabIndex {
                        DebugLog.log("[SessionStore] Bind-on-start: captured tab index \(idx) for session \(event.sessionId)")
                    }
                }
            }

            let (status, waitingReason, isToolRunning) = Self.determineStatusAndReason(event: event, current: nil)
            // Assign displayOrder: inherit from replaced session or assign new
            let newDisplayOrder: Int
            if let inherited = inheritedDisplayOrder {
                newDisplayOrder = inherited
                DebugLog.log("[SessionStore] Legacy: inherited displayOrder \(inherited) from replaced TTY session")
            } else {
                let maxOrder = data.sessions.values.compactMap { $0.displayOrder }.max() ?? 0
                newDisplayOrder = maxOrder + 1
                DebugLog.log("[SessionStore] Legacy: assigned new displayOrder \(maxOrder + 1)")
            }

            session = Session(
                sessionId: event.sessionId,
                cwd: event.cwd,
                tty: event.tty,
                status: status,
                createdAt: now,
                updatedAt: now,
                ghosttyTabIndex: tabIndex,
                termProgram: event.termProgram,
                actualTermProgram: event.actualTermProgram,
                editorBundleID: event.editorBundleID,
                editorPID: event.editorPID,
                waitingReason: waitingReason,
                questionText: waitingReason == .askUserQuestion ? event.question?.text : nil,
                questionOptions: waitingReason == .askUserQuestion ? event.question?.options.map(\.label) : nil,
                questionSelected: waitingReason == .askUserQuestion ? event.question?.selectedIndex : nil,
                isToolRunning: isToolRunning,
                displayOrder: newDisplayOrder
            )
        }

        data.sessions[key] = session
        data.updatedAt = now

        // Check for duplicate project names and mark for disambiguation
        disambiguateIfNeeded(&data)

        saveData(data)

        // Note: Notifications are sent from SessionObserver (GUI) to respect user settings
        // CLI process cannot reliably read UserDefaults set by GUI
        // Timeout cleanup is also handled by GUI (SessionObserver) for the same reason

        return session
    }

    func removeSession(sessionId: String, tty: String?) {
        var data = loadData()
        // Handle both nil and empty string TTY
        let key: String
        if let tty = tty, !tty.isEmpty {
            key = "\(sessionId):\(tty)"
        } else {
            key = sessionId
        }
        data.sessions.removeValue(forKey: key)
        data.updatedAt = Date()
        saveData(data)
        DebugLog.log("[SessionStore] Session removed: \(key)")
    }

    /// Mark a session as stopped (for stale session cleanup)
    /// - Parameters:
    ///   - sessionId: The session ID
    ///   - tty: Optional TTY device path
    func markSessionAsStopped(sessionId: String, tty: String?) {
        var data = loadData()
        let key: String
        if let tty = tty, !tty.isEmpty {
            key = "\(sessionId):\(tty)"
        } else {
            key = sessionId
        }

        guard var session = data.sessions[key] else { return }

        session.status = .stopped
        session.waitingReason = nil
        session.isToolRunning = false
        session.updatedAt = Date()

        data.sessions[key] = session
        data.updatedAt = Date()

        saveData(data)
        DebugLog.log("[SessionStore] Session marked as stopped (stale TTY): \(key)")
    }

    /// Update tab index for a session (manual binding)
    /// - Parameters:
    ///   - sessionId: The session ID
    ///   - tty: Optional TTY device path
    ///   - tabIndex: The Ghostty tab index to bind
    func updateTabIndex(sessionId: String, tty: String?, tabIndex: Int) {
        var data = loadData()
        let key: String
        if let tty = tty, !tty.isEmpty {
            key = "\(sessionId):\(tty)"
        } else {
            key = sessionId
        }

        guard var session = data.sessions[key] else { return }

        session.ghosttyTabIndex = tabIndex
        session.updatedAt = Date()

        data.sessions[key] = session
        data.updatedAt = Date()

        saveData(data)
        DebugLog.log("[SessionStore] Tab index updated to \(tabIndex) for session: \(key)")
    }

    /// Mark a session as acknowledged
    func acknowledgeSession(sessionId: String, tty: String?) {
        var data = loadData()
        let key: String
        if let tty = tty, !tty.isEmpty {
            key = "\(sessionId):\(tty)"
        } else {
            key = sessionId
        }

        guard var session = data.sessions[key] else { return }
        guard session.isAcknowledged != true else { return }  // Already acknowledged

        session.isAcknowledged = true
        session.updatedAt = Date()

        data.sessions[key] = session
        data.updatedAt = Date()

        saveData(data)
        DebugLog.log("[SessionStore] Session acknowledged: \(key)")
    }

    /// Clear acknowledged flag for a session (when it returns to running)
    func clearAcknowledged(sessionId: String, tty: String?) {
        var data = loadData()
        let key: String
        if let tty = tty, !tty.isEmpty {
            key = "\(sessionId):\(tty)"
        } else {
            key = sessionId
        }

        guard var session = data.sessions[key] else { return }
        guard session.isAcknowledged == true else { return }  // Not acknowledged

        session.isAcknowledged = nil
        session.updatedAt = Date()

        data.sessions[key] = session
        data.updatedAt = Date()

        saveData(data)
        DebugLog.log("[SessionStore] Acknowledged cleared: \(key)")
    }

    func clearSessions() {
        saveData(StoreData())
    }

    @discardableResult
    func updateStatusline(_ update: StatuslineUpdate, now: Date = Date()) -> StatuslineUpdateResult {
        var data = loadData()
        let result = Self.applyStatuslineUpdate(to: &data, update: update, now: now)
        guard result.changed else { return result }

        data.updatedAt = now
        saveData(data)
        DebugLog.log("[SessionStore] Statusline updated: \(result.updatedKeys.joined(separator: ", "))", level: .debug)
        return result
    }

    static func applyStatuslineUpdate(
        to data: inout StoreData,
        update: StatuslineUpdate,
        now: Date
    ) -> StatuslineUpdateResult {
        var result = StatuslineUpdateResult()

        for (key, session) in data.sessions where session.sessionId == update.sessionId {
            result.matchedKeys.append(key)
            var updated = session
            var changed = false

            if let contextUsedPercentage = update.contextUsedPercentage,
               updated.contextUsedPercentage != contextUsedPercentage {
                updated.contextUsedPercentage = contextUsedPercentage
                changed = true
            }

            if let totalCostUSD = update.totalCostUSD,
               updated.totalCostUSD != totalCostUSD {
                updated.totalCostUSD = totalCostUSD
                changed = true
            }

            guard changed else { continue }

            updated.updatedAt = now
            data.sessions[key] = updated
            result.updatedKeys.append(key)
        }

        return result
    }

    @discardableResult
    func reconcileClaudeGhostSessions(now: Date = Date()) -> ClaudeGhostCleanupResult {
        guard let liveAgents = Self.fetchLiveClaudeAgents() else {
            DebugLog.log("[SessionStore] Claude ghost cleanup skipped: claude agents unavailable")
            return ClaudeGhostCleanupResult(skippedReason: "claude agents unavailable")
        }

        let liveSessionIds = Set(liveAgents.compactMap { record -> String? in
            guard let sessionId = record.sessionId, !sessionId.isEmpty else { return nil }
            return sessionId
        })

        var data = loadData()
        // Seed first: a live session the store has never seen must appear, not be treated
        // as a ghost. Cleanup then runs over the reconciled set.
        let seeded = Self.applyClaudeLiveSessionSeeding(
            to: &data,
            liveAgents: liveAgents,
            now: now,
            ttyResolver: Self.controllingTty(forPid:)
        )
        var result = Self.applyClaudeGhostCleanup(
            to: &data,
            liveSessionIds: liveSessionIds,
            now: now,
            removalGrace: Self.claudeGhostRemovalGrace
        )
        result.seeded = seeded

        guard result.changed else { return result }

        data.updatedAt = now
        saveData(data)
        DebugLog.log(
            "[SessionStore] Claude ghost cleanup: markedStopped=\(result.markedStopped.count), removed=\(result.removed.count), seeded=\(result.seeded.count)"
        )
        return result
    }

    static func applyClaudeGhostCleanup(
        to data: inout StoreData,
        liveSessionIds: Set<String>,
        now: Date,
        removalGrace: TimeInterval
    ) -> ClaudeGhostCleanupResult {
        var result = ClaudeGhostCleanupResult()

        for (key, session) in data.sessions {
            if liveSessionIds.contains(session.sessionId) {
                continue
            }

            let age = now.timeIntervalSince(session.updatedAt)
            if age >= removalGrace {
                data.sessions.removeValue(forKey: key)
                result.removed.append(key)
                continue
            }

            if session.status == .stopped {
                continue
            }

            var stopped = session
            stopped.status = .stopped
            stopped.waitingReason = nil
            stopped.questionText = nil
            stopped.questionOptions = nil
            stopped.questionSelected = nil
            stopped.isToolRunning = false
            stopped.updatedAt = now
            data.sessions[key] = stopped
            result.markedStopped.append(key)
        }

        result.markedStopped.sort()
        result.removed.sort()
        return result
    }

    /// Sessions the Claude CLI reports as alive but that the store has never heard of.
    ///
    /// Hooks are the only way a session normally enters the store, so a session that has
    /// been quiet since the store last lost it (menu bar app restarted, or the 60-minute
    /// ghost grace elapsed) stays invisible until it happens to run a tool or end a turn.
    /// The reconcile pass already knows which sessions are alive; this seeds the missing
    /// ones instead of using that knowledge only to delete.
    ///
    /// A seeded session has no tty yet, so it is keyed by its session id alone. Anything
    /// already tracking the same session id wins — a hook-created entry carries tty, tmux
    /// and reason detail this list cannot provide, and seeding beside it would duplicate
    /// the row. For the same reason a previously seeded, tty-less entry is dropped once a
    /// hook-created entry for that session id appears.
    /// - Parameter ttyResolver: maps an agent pid to its controlling terminal. Injected so
    ///   the seeding rules stay testable without a live process table; the caller supplies
    ///   the real lookup. A seeded session that resolves a tty is keyed and sectioned like
    ///   a hook-created one, so it appears next to its tmux pane instead of as a stray.
    static func applyClaudeLiveSessionSeeding(
        to data: inout StoreData,
        liveAgents: [ClaudeAgentRecord],
        now: Date,
        ttyResolver: (Int) -> String? = { _ in nil }
    ) -> [String] {
        var seeded: [String] = []

        for agent in liveAgents {
            guard agent.kind == nil || agent.kind == "interactive" else { continue }
            guard let sessionId = agent.sessionId, !sessionId.isEmpty else { continue }
            guard let cwd = agent.cwd, !cwd.isEmpty else { continue }
            let (status, reason) = Self.claudeAgentState(from: agent.status)
            let tty = agent.pid.flatMap { ttyResolver($0) }

            if let existingKey = data.sessions.first(where: { $0.value.sessionId == sessionId })?.key {
                // Two ways a row ends up pointing at the wrong terminal: it was seeded
                // before its tty could be read, or the session was restarted into a
                // different pane and the store still holds the tty an old hook reported.
                // Either way the row cannot reach its pane. The process table says where
                // the process is right now, so it wins over a remembered binding.
                guard let tty,
                      let existing = data.sessions[existingKey],
                      existing.tty != tty else { continue }
                var rebound = existing
                rebound.tty = tty
                rebound.updatedAt = now
                data.sessions.removeValue(forKey: existingKey)
                data.sessions[rebound.id] = rebound
                seeded.append(rebound.id)
                continue
            }

            let session = Session(
                sessionId: sessionId,
                cwd: cwd,
                tty: tty,
                status: status,
                createdAt: now,
                updatedAt: now,
                waitingReason: reason
            )
            data.sessions[session.id] = session
            seeded.append(session.id)
        }

        // A hook-created entry supersedes an earlier seeded one for the same session.
        let ttyBackedIds = Set(data.sessions.values.compactMap { $0.tty == nil ? nil : $0.sessionId })
        for (key, session) in data.sessions
        where session.tty == nil && ttyBackedIds.contains(session.sessionId) {
            data.sessions.removeValue(forKey: key)
            seeded.removeAll { $0 == key }
        }

        return seeded
    }

    /// Maps the CLI's own status vocabulary onto the store's. "idle" and "waiting" both
    /// mean the session is not working and needs its human, which is what waiting_input
    /// already means for every hook-driven session; nothing here claims a session finished.
    static func claudeAgentState(from status: String?) -> (SessionStatus, WaitingReason?) {
        switch status {
        case "busy":
            return (.running, nil)
        case "idle":
            return (.waitingInput, .idle)
        case "waiting":
            return (.waitingInput, .unknown)
        default:
            return (.running, nil)
        }
    }

    /// The controlling terminal of a process, as `/dev/ttysNNN`. Inside tmux this is the
    /// pane's tty, which is what the rest of the pipeline keys tmux lookups on.
    static func controllingTty(forPid pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let name = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, name != "??" else { return nil }
        return name.hasPrefix("/dev/") ? name : "/dev/\(name)"
    }

    static func parseClaudeAgentRecords(from data: Data) -> [ClaudeAgentRecord]? {
        try? JSONDecoder().decode([ClaudeAgentRecord].self, from: data)
    }

    static func parseClaudeAgentSessionIds(from data: Data) -> Set<String>? {
        guard let agents = try? JSONDecoder().decode([ClaudeAgentRecord].self, from: data) else {
            return nil
        }
        return Set(agents.compactMap { record in
            guard let sessionId = record.sessionId, !sessionId.isEmpty else { return nil }
            return sessionId
        })
    }

    // MARK: - Private

    private static func fetchLiveClaudeAgents() -> [ClaudeAgentRecord]? {
        let (executable, arguments) = claudeAgentsCommand()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            DebugLog.log("[SessionStore] Failed to run claude agents: \(error.localizedDescription)")
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            DebugLog.log("[SessionStore] claude agents timed out")
            return nil
        }

        guard process.terminationStatus == 0 else {
            let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DebugLog.log("[SessionStore] claude agents failed (\(process.terminationStatus)): \(errorText)")
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let records = parseClaudeAgentRecords(from: data) else {
            DebugLog.log("[SessionStore] Failed to parse claude agents output")
            return nil
        }
        return records
    }

    private static func claudeAgentsCommand() -> (URL, [String]) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return (URL(fileURLWithPath: path), ["agents", "--json"])
        }

        return (URL(fileURLWithPath: "/usr/bin/env"), ["claude", "agents", "--json"])
    }

    /// Detect duplicate project basenames and mark them for disambiguation
    /// Once marked, sessions stay disambiguated even if duplicates are removed (for stability)
    private func disambiguateIfNeeded(_ data: inout StoreData) {
        // Group sessions by basename
        var basenameGroups: [String: [String]] = [:]  // basename -> [session keys]
        for (key, session) in data.sessions {
            let basename = URL(fileURLWithPath: session.cwd).lastPathComponent
            basenameGroups[basename, default: []].append(key)
        }

        // Mark all sessions in duplicate groups as disambiguated
        for (basename, keys) in basenameGroups where keys.count > 1 {
            for key in keys {
                if data.sessions[key]?.isDisambiguated != true {
                    data.sessions[key]?.isDisambiguated = true
                    DebugLog.log("[SessionStore] Disambiguated session '\(basename)' -> '\(data.sessions[key]?.displayName ?? basename)'")
                }
            }
        }
    }

    static func determineStatusAndReason(event: HookEvent, current: SessionStatus?) -> (SessionStatus, WaitingReason?, Bool) {
        switch event.hookEventName {
        case .sessionEnd:
            return (.stopped, nil, false)  // Will be removed anyway
        case .stop:
            return (.waitingInput, .stop, false)  // Yellow - command completion waiting
        case .notification:
            // AskUserQuestion must be checked before permission_prompt fallback.
            if event.isAskUserQuestion {
                return (.waitingInput, .askUserQuestion, false)
            }
            // Use isPermissionPrompt which checks both notification_type and message content
            if event.isPermissionPrompt {
                return (.waitingInput, .permissionPrompt, false)  // Red - permission/choice waiting
            }
            return (current ?? .running, nil, false)
        case .preToolUse:
            return (.running, nil, true)  // Tool is running - show spinner
        case .postToolUse, .postToolBatch:
            return (current ?? .running, nil, false)  // Tool finished
        case .userPromptSubmit, .sessionStart:
            return (.running, nil, false)  // Not running tool yet
        }
    }

    private func loadData() -> StoreData {
        guard FileManager.default.fileExists(atPath: storeFile.path) else {
            return StoreData()
        }

        do {
            let data = try Data(contentsOf: storeFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(StoreData.self, from: data)
        } catch {
            return StoreData()
        }
    }

    private var hasNotifiedWriteError = false

    private func saveData(_ data: StoreData) {
        do {
            // Ensure directory exists
            if !FileManager.default.fileExists(atPath: storeDir.path) {
                try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            // Use file locking
            let jsonData = try encoder.encode(data)
            let fd = open(storeFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else {
                let err = errno
                DebugLog.log("[SessionStore] Failed to open file for writing: errno=\(err) (\(String(cString: strerror(err))))")
                notifyWriteErrorOnce()
                return
            }
            defer { close(fd) }

            flock(fd, LOCK_EX)
            defer { flock(fd, LOCK_UN) }

            let written = jsonData.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress, ptr.count)
            }

            if written != jsonData.count {
                DebugLog.log("[SessionStore] Partial write: \(written)/\(jsonData.count) bytes")
                notifyWriteErrorOnce()
            }
        } catch {
            DebugLog.log("[SessionStore] Write failed: \(error.localizedDescription)")
            notifyWriteErrorOnce()
        }
    }

    private func notifyWriteErrorOnce() {
        guard !hasNotifiedWriteError else { return }
        hasNotifiedWriteError = true
        DebugLog.log("[SessionStore] First write error detected - user should check permissions for: \(storeDir.path)")
    }
}
