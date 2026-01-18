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

    /// Active sessions (not timed out)
    var activeSessions: [Session] {
        let timeout: TimeInterval = 30 * 60 // 30 minutes
        return sessions.values
            .filter { Date().timeIntervalSince($0.updatedAt) <= timeout }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
