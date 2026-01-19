import Foundation

final class SessionStore {
    static let shared = SessionStore()

    private let storeDir: URL
    private let storeFile: URL

    private var timeout: TimeInterval {
        let minutes = AppSettings.sessionTimeoutMinutes
        // 0 means never timeout
        return minutes > 0 ? TimeInterval(minutes * 60) : .infinity
    }

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

        // Remove old sessions on same TTY
        if let tty = ccsbEvent.tty, !tty.isEmpty {
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

        // Capture Ghostty tab index for Bind-on-start on new sessions
        if existing == nil && ccsbEvent.event == .sessionStart && GhosttyHelper.isRunning {
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

        // Clean up timed out sessions
        data.sessions = data.sessions.filter { (_, v) in
            Date().timeIntervalSince(v.updatedAt) <= timeout
        }

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

        // Remove old sessions on same TTY
        if let tty = event.tty, !tty.isEmpty {
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
            existing.status = determineStatus(event: event, current: existing.status)
            existing.updatedAt = now
            // Update termProgram if provided (first value wins)
            if existing.termProgram == nil, let termProgram = event.termProgram {
                existing.termProgram = termProgram
            }
            // Update editorBundleID if provided (first value wins)
            if existing.editorBundleID == nil, let bundleID = event.editorBundleID {
                existing.editorBundleID = bundleID
            }
            session = existing
        } else {
            // New session - capture Ghostty tab index for Bind-on-start
            var tabIndex: Int? = nil
            if event.hookEventName == .sessionStart && GhosttyHelper.isRunning {
                // Only bind tab for non-tmux sessions (tmux uses title search)
                if let tty = event.tty, TmuxHelper.getPaneInfo(for: tty) == nil {
                    tabIndex = GhosttyHelper.getSelectedTabIndex()
                    if let idx = tabIndex {
                        DebugLog.log("[SessionStore] Bind-on-start: captured tab index \(idx) for session \(event.sessionId)")
                    }
                }
            }

            session = Session(
                sessionId: event.sessionId,
                cwd: event.cwd,
                tty: event.tty,
                status: determineStatus(event: event, current: nil),
                createdAt: now,
                updatedAt: now,
                ghosttyTabIndex: tabIndex,
                termProgram: event.termProgram,
                editorBundleID: event.editorBundleID
            )
        }

        data.sessions[key] = session
        data.updatedAt = now

        // Clean up timed out sessions
        data.sessions = data.sessions.filter { (_, v) in
            Date().timeIntervalSince(v.updatedAt) <= timeout
        }

        saveData(data)

        // Note: Notifications are sent from SessionObserver (GUI) to respect user settings
        // CLI process cannot reliably read UserDefaults set by GUI

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

    func clearSessions() {
        saveData(StoreData())
    }

    // MARK: - Private

    private func determineStatus(event: HookEvent, current: SessionStatus?) -> SessionStatus {
        switch event.hookEventName {
        case .sessionEnd:
            return .stopped  // Will be removed anyway
        case .stop:
            return .waitingInput
        case .notification:
            if event.notificationType == "permission_prompt" {
                return .waitingInput
            }
            return current ?? .running
        case .preToolUse, .userPromptSubmit, .sessionStart:
            return .running
        case .postToolUse:
            return current ?? .running
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
