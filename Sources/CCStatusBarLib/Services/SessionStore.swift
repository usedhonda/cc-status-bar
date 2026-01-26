import Foundation

final class SessionStore {
    static let shared = SessionStore()

    private let storeDir: URL
    private let storeFile: URL

    private init() {
        storeDir = SetupManager.appSupportDir
        storeFile = SetupManager.sessionsFile
    }

    // MARK: - Read

    func getSessions() -> [Session] {
        return loadData().activeSessions
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
            let (status, waitingReason, isToolRunning) = determineStatusAndReason(event: event, current: existing.status)
            DebugLog.log("[SessionStore] Update session \(key): \(existing.status) -> \(status), reason: \(String(describing: waitingReason)), toolRunning: \(isToolRunning)")
            existing.status = status
            existing.waitingReason = waitingReason
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

            let (status, waitingReason, isToolRunning) = determineStatusAndReason(event: event, current: nil)
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

    // MARK: - Private

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

    private func determineStatusAndReason(event: HookEvent, current: SessionStatus?) -> (SessionStatus, WaitingReason?, Bool) {
        switch event.hookEventName {
        case .sessionEnd:
            return (.stopped, nil, false)  // Will be removed anyway
        case .stop:
            return (.waitingInput, .stop, false)  // Yellow - command completion waiting
        case .notification:
            // Use isPermissionPrompt which checks both notification_type and message content
            if event.isPermissionPrompt {
                return (.waitingInput, .permissionPrompt, false)  // Red - permission/choice waiting
            }
            return (current ?? .running, nil, false)
        case .preToolUse:
            return (.running, nil, true)  // Tool is running - show spinner
        case .postToolUse:
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
