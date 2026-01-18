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

    // MARK: - Write

    func updateSession(event: HookEvent) -> Session? {
        // SessionEnd: remove the session entirely
        if event.hookEventName == .sessionEnd {
            removeSession(sessionId: event.sessionId, tty: event.tty)
            return nil
        }

        var data = loadData()

        // Determine session key
        let key = event.tty.map { "\(event.sessionId):\($0)" } ?? event.sessionId

        // Remove old sessions on same TTY
        if let tty = event.tty {
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
        let oldStatus = data.sessions[key]?.status

        if var existing = data.sessions[key] {
            existing.status = determineStatus(event: event, current: existing.status)
            existing.updatedAt = now
            session = existing
        } else {
            session = Session(
                sessionId: event.sessionId,
                cwd: event.cwd,
                tty: event.tty,
                status: determineStatus(event: event, current: nil),
                createdAt: now,
                updatedAt: now
            )
        }

        data.sessions[key] = session
        data.updatedAt = now

        // Clean up timed out sessions
        data.sessions = data.sessions.filter { (_, v) in
            Date().timeIntervalSince(v.updatedAt) <= timeout
        }

        saveData(data)

        // Send notification if status changed to waitingInput
        if session.status == .waitingInput && oldStatus != .waitingInput {
            NotificationManager.notifyWaitingInput(projectName: session.projectName)
            DebugLog.log("[SessionStore] Notification sent for: \(session.projectName)")
        }

        return session
    }

    func removeSession(sessionId: String, tty: String?) {
        var data = loadData()
        let key = tty.map { "\(sessionId):\($0)" } ?? sessionId
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
