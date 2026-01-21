import Foundation
import Combine
import AppKit

@MainActor
final class SessionObserver: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    private let storeFile: URL
    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var previousSessionIds: Set<String> = []  // Track known sessions for Bind-on-start
    private var previousSessionStatuses: [String: SessionStatus] = [:]  // Track status for notifications
    private var acknowledgedSessionIds: Set<String> = []  // Sessions user has seen (for yellow->green)
    private var isInitialLoad = true  // Skip notifications on first load to avoid spam at startup

    /// Debounce work item for file watch events
    private var loadDebounceWorkItem: DispatchWorkItem?

    var runningCount: Int {
        sessions.filter { $0.status == .running }.count
    }

    var waitingCount: Int {
        sessions.filter { $0.status == .waitingInput }.count
    }

    /// Waiting sessions that haven't been acknowledged (for menu bar count)
    var unacknowledgedWaitingCount: Int {
        sessions.filter {
            $0.status == .waitingInput && !acknowledgedSessionIds.contains($0.id)
        }.count
    }

    /// Red waiting sessions (permission_prompt) that haven't been acknowledged
    var unacknowledgedRedCount: Int {
        sessions.filter {
            $0.status == .waitingInput &&
            $0.waitingReason == .permissionPrompt &&
            !acknowledgedSessionIds.contains($0.id)
        }.count
    }

    /// Yellow waiting sessions (stop/unknown) that haven't been acknowledged
    var unacknowledgedYellowCount: Int {
        sessions.filter {
            $0.status == .waitingInput &&
            $0.waitingReason != .permissionPrompt &&
            !acknowledgedSessionIds.contains($0.id)
        }.count
    }

    /// Sessions displayed as green (running + acknowledged waiting)
    var displayedGreenCount: Int {
        let running = sessions.filter { $0.status == .running }.count
        let acknowledgedWaiting = sessions.filter {
            $0.status == .waitingInput && acknowledgedSessionIds.contains($0.id)
        }.count
        return running + acknowledgedWaiting
    }

    /// Sessions with tools actively running (for spinner animation)
    var toolRunningCount: Int {
        sessions.filter { $0.isToolRunning == true }.count
    }

    var hasActiveSessions: Bool {
        !sessions.isEmpty
    }

    // MARK: - Acknowledge (for yellow->green on focus)

    /// Mark a session as acknowledged (user has seen it)
    func acknowledge(sessionId: String) {
        acknowledgedSessionIds.insert(sessionId)
        objectWillChange.send()
        DebugLog.log("[SessionObserver] Acknowledged session: \(sessionId)")
    }

    /// Check if a session is acknowledged
    func isAcknowledged(sessionId: String) -> Bool {
        acknowledgedSessionIds.contains(sessionId)
    }

    /// Find session by TTY
    func session(byTTY tty: String) -> Session? {
        sessions.first { $0.tty == tty }
    }

    /// Find session by Ghostty tab index
    func session(byTabIndex index: Int) -> Session? {
        sessions.first { $0.ghosttyTabIndex == index }
    }

    /// Find session by tab title (matches project name or tmux session name)
    func session(byTabTitle title: String) -> Session? {
        // First, try exact project name match
        if let session = sessions.first(where: { title.contains($0.projectName) }) {
            return session
        }
        // Then try tmux session name from TTY
        for session in sessions {
            if let tty = session.tty,
               let paneInfo = TmuxHelper.getPaneInfo(for: tty),
               title.contains(paneInfo.session) {
                return session
            }
        }
        return nil
    }

    init() {
        storeFile = SetupManager.sessionsFile

        loadSessions()
        startWatching()
    }

    deinit {
        dispatchSource?.cancel()
    }

    // MARK: - Debounced Load

    /// Schedule a debounced session load (100ms delay)
    private func scheduleLoadSessions() {
        loadDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.loadSessions()
        }
        loadDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    // MARK: - File Reading

    private func loadSessions() {
        // Invalidate TmuxHelper cache when session file changes
        TmuxHelper.invalidatePaneInfoCache()

        guard FileManager.default.fileExists(atPath: storeFile.path) else {
            sessions = []
            previousSessionIds = []
            return
        }

        do {
            let data = try Data(contentsOf: storeFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let storeData = try decoder.decode(StoreData.self, from: data)
            var loadedSessions = storeData.activeSessions

            // Check for sessions with invalid (stale) TTYs and mark them as stopped
            var sessionsToMarkStopped: [Session] = []
            for session in loadedSessions {
                // Skip already stopped sessions
                guard session.status != .stopped else { continue }

                // Case 1: TTY-based stale detection (terminals)
                if let tty = session.tty, !tty.isEmpty {
                    if !FileManager.default.fileExists(atPath: tty) {
                        sessionsToMarkStopped.append(session)
                    }
                    continue
                }

                // Case 2: Editor PID-based stale detection (VSCode/Cursor without TTY)
                // Only applies when: no TTY AND editorBundleID is set AND editorPID is set
                if session.editorBundleID != nil,
                   let editorPID = session.editorPID, editorPID > 0 {
                    if !isEditorAlive(pid: editorPID, expectedBundleID: session.editorBundleID) {
                        sessionsToMarkStopped.append(session)
                        DebugLog.log("[SessionObserver] Editor process \(editorPID) not running for session \(session.projectName)")
                    }
                }
            }

            // Mark stale sessions as stopped (don't delete - let timeout handle removal)
            if !sessionsToMarkStopped.isEmpty {
                DebugLog.log("[SessionObserver] Marking \(sessionsToMarkStopped.count) session(s) as stopped (stale TTY)")
                for session in sessionsToMarkStopped {
                    SessionStore.shared.markSessionAsStopped(sessionId: session.sessionId, tty: session.tty)
                }
                // Reload to get updated data
                let data = try Data(contentsOf: storeFile)
                let storeData = try decoder.decode(StoreData.self, from: data)
                loadedSessions = storeData.activeSessions
            }

            // Bind-on-start: Detect new sessions and capture Ghostty tab index
            captureGhosttyTabIndexForNewSessions(loadedSessions, storeData: storeData)

            // Send notifications for sessions that changed to waitingInput
            // Skip on initial load to avoid notification spam at startup
            if !isInitialLoad {
                sendNotificationsForWaitingSessions(loadedSessions)
            }
            isInitialLoad = false

            // Clear acknowledged flag for sessions that returned to running
            cleanupAcknowledgedSessions(loadedSessions)

            // Update tracking
            previousSessionIds = Set(loadedSessions.map { $0.id })
            previousSessionStatuses = Dictionary(uniqueKeysWithValues: loadedSessions.map { ($0.id, $0.status) })
            sessions = loadedSessions
        } catch {
            sessions = []
            previousSessionIds = []
            previousSessionStatuses = [:]
        }
    }

    // MARK: - Notifications

    private func sendNotificationsForWaitingSessions(_ loadedSessions: [Session]) {
        for session in loadedSessions {
            // Check if status changed to waitingInput
            let oldStatus = previousSessionStatuses[session.id]
            if session.status == .waitingInput && oldStatus != .waitingInput {
                NotificationManager.shared.notifyWaitingInput(session: session)
            }
        }
    }

    /// Clear acknowledged flag and notification cooldown when sessions return to running
    private func cleanupAcknowledgedSessions(_ loadedSessions: [Session]) {
        let runningIds = Set(loadedSessions.filter { $0.status == .running }.map { $0.id })
        let cleared = acknowledgedSessionIds.intersection(runningIds)
        if !cleared.isEmpty {
            acknowledgedSessionIds.subtract(runningIds)
            DebugLog.log("[SessionObserver] Cleared acknowledged for running sessions: \(cleared)")
        }

        // Clear notification cooldowns for sessions that returned to running
        for sessionId in runningIds {
            NotificationManager.shared.clearCooldown(sessionId: sessionId)
        }
    }

    // MARK: - Bind-on-start: Capture Ghostty Tab Index

    private func captureGhosttyTabIndexForNewSessions(_ loadedSessions: [Session], storeData: StoreData) {
        // Only if Ghostty is running AND no other terminals are running
        // (We can't reliably determine which terminal a session started in)
        guard GhosttyHelper.isRunning else { return }
        guard !isOtherTerminalRunning() else {
            DebugLog.log("[SessionObserver] Bind-on-start: Skipped - other terminal apps running")
            return
        }

        let now = Date()
        let maxAge: TimeInterval = 5.0  // Only capture if session started within last 5 seconds

        // Find new sessions that need tab index
        let newSessions = loadedSessions.filter { session in
            // Must be a new session (not previously known)
            !previousSessionIds.contains(session.id) &&
            // Must not already have a tab index
            session.ghosttyTabIndex == nil &&
            // Must not be a tmux session (tmux uses title search)
            (session.tty == nil || TmuxHelper.getPaneInfo(for: session.tty!) == nil) &&
            // Must be recently created (within maxAge seconds)
            now.timeIntervalSince(session.createdAt) <= maxAge
        }

        guard !newSessions.isEmpty else { return }

        // Capture current tab index
        guard let tabIndex = GhosttyHelper.getSelectedTabIndex() else {
            DebugLog.log("[SessionObserver] Bind-on-start: Could not get Ghostty tab index")
            return
        }

        // Update the first new session with the tab index
        // (Typically only one session starts at a time)
        if let firstNew = newSessions.first {
            DebugLog.log("[SessionObserver] Bind-on-start: Captured tab index \(tabIndex) for session \(firstNew.sessionId)")
            updateSessionTabIndex(sessionId: firstNew.sessionId, tty: firstNew.tty, tabIndex: tabIndex, storeData: storeData)
        }
    }

    private func updateSessionTabIndex(sessionId: String, tty: String?, tabIndex: Int, storeData: StoreData) {
        var updatedData = storeData
        let key = tty.map { "\(sessionId):\($0)" } ?? sessionId

        guard var session = updatedData.sessions[key] else { return }
        session.ghosttyTabIndex = tabIndex
        updatedData.sessions[key] = session

        // Write back to file
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(updatedData)
            try jsonData.write(to: storeFile)
            DebugLog.log("[SessionObserver] Bind-on-start: Updated session file with tab index \(tabIndex)")
        } catch {
            DebugLog.log("[SessionObserver] Bind-on-start: Failed to write tab index: \(error)")
        }
    }

    /// Check if Terminal.app or iTerm2 is running
    private func isOtherTerminalRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        let otherTerminals = ["com.apple.Terminal", "com.googlecode.iterm2"]
        return runningApps.contains { app in
            guard let bundleId = app.bundleIdentifier else { return false }
            return otherTerminals.contains(bundleId)
        }
    }

    /// Check if an editor process is still alive (for VSCode/Cursor stale detection)
    /// Uses bundleID matching to prevent false positives from PID reuse
    private func isEditorAlive(pid: pid_t, expectedBundleID: String?) -> Bool {
        // 1) Quick existence check using kill(pid, 0)
        if kill(pid, 0) != 0 && errno != EPERM { return false }

        // 2) PID reuse protection: verify bundleID matches
        if let expectedBundleID = expectedBundleID,
           let app = NSRunningApplication(processIdentifier: pid),
           let bid = app.bundleIdentifier {
            return bid == expectedBundleID && !app.isTerminated
        }

        // 3) If bundleID can't be retrieved, assume alive (safe fallback)
        return true
    }

    /// Remove sessions with invalid TTYs from the persistent store
    private func cleanupInvalidSessions(validIds: Set<String>) {
        guard FileManager.default.fileExists(atPath: storeFile.path) else { return }

        do {
            let data = try Data(contentsOf: storeFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var storeData = try decoder.decode(StoreData.self, from: data)

            // Remove sessions that are not in the valid set
            let originalCount = storeData.sessions.count
            storeData.sessions = storeData.sessions.filter { validIds.contains($0.key) }

            if storeData.sessions.count < originalCount {
                storeData.updatedAt = Date()

                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(storeData)
                try jsonData.write(to: storeFile)

                DebugLog.log("[SessionObserver] Cleaned up \(originalCount - storeData.sessions.count) invalid session(s)")
            }
        } catch {
            DebugLog.log("[SessionObserver] Failed to cleanup invalid sessions: \(error)")
        }
    }

    // MARK: - File Watching

    private func startWatching() {
        // Ensure directory exists
        let dirPath = storeFile.deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: dirPath) {
            try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }

        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: storeFile.path) {
            try? "{}".write(to: storeFile, atomically: true, encoding: .utf8)
        }

        // Watch the file directly
        fileDescriptor = open(storeFile.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            // Fallback: polling every 2 seconds
            startPolling()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.all],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.scheduleLoadSessions()
            }
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
        }

        source.resume()
        dispatchSource = source
    }

    private func startPolling() {
        // Fallback polling mechanism
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadSessions()
            }
        }
    }
}
