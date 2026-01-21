import Foundation

struct StoreData: Codable {
    var sessions: [String: Session]
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessions
        case updatedAt = "updated_at"
    }

    init(sessions: [String: Session] = [:], updatedAt: Date = Date()) {
        self.sessions = sessions
        self.updatedAt = updatedAt
    }

    /// Active sessions (not stopped and not timed out)
    var activeSessions: [Session] {
        let minutes = AppSettings.sessionTimeoutMinutes
        // 0 means never timeout
        if minutes == 0 {
            // Even with "Never" timeout, exclude stopped sessions
            return sessions.values
                .filter { $0.status != .stopped }
                .sorted { $0.createdAt < $1.createdAt }
        }
        let timeout: TimeInterval = Double(minutes) * 60
        return sessions.values
            .filter { $0.status != .stopped && Date().timeIntervalSince($0.updatedAt) <= timeout }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
