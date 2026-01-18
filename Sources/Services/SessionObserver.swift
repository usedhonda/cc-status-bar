import Foundation
import Combine

@MainActor
final class SessionObserver: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    private let storeFile: URL
    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?

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
            return
        }

        do {
            let data = try Data(contentsOf: storeFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let storeData = try decoder.decode(StoreData.self, from: data)
            sessions = storeData.activeSessions
        } catch {
            sessions = []
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
