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

    var runningCount: Int {
        sessions.filter { $0.status == .running }.count
    }

    var waitingCount: Int {
        sessions.filter { $0.status == .waitingInput }.count
    }

    var hasActiveSessions: Bool {
        !sessions.isEmpty
    }

    init() {
        storeFile = SetupManager.sessionsFile

        loadSessions()
        startWatching()
    }

    deinit {
        dispatchSource?.cancel()
    }

    // MARK: - File Reading

    private func loadSessions() {
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
            let loadedSessions = storeData.activeSessions

            // Bind-on-start: Detect new sessions and capture Ghostty tab index
            captureGhosttyTabIndexForNewSessions(loadedSessions, storeData: storeData)

            // Send notifications for sessions that changed to waitingInput
            sendNotificationsForWaitingSessions(loadedSessions)

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
                NotificationManager.shared.notifyWaitingInput(projectName: session.projectName)
            }
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
                self?.loadSessions()
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
