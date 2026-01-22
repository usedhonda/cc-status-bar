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
    /// Sorted by displayOrder (if set), fallback to createdAt for legacy sessions
    var activeSessions: [Session] {
        let minutes = AppSettings.sessionTimeoutMinutes
        // 0 means never timeout
        if minutes == 0 {
            // Even with "Never" timeout, exclude stopped sessions
            return sessions.values
                .filter { $0.status != .stopped }
                .sorted { sessionOrder($0) < sessionOrder($1) }
        }
        let timeout: TimeInterval = Double(minutes) * 60
        return sessions.values
            .filter { $0.status != .stopped && Date().timeIntervalSince($0.updatedAt) <= timeout }
            .sorted { sessionOrder($0) < sessionOrder($1) }
    }

    /// Session ordering: displayOrder if set, otherwise use createdAt as fallback
    private func sessionOrder(_ session: Session) -> (Int, Date) {
        (session.displayOrder ?? Int.max, session.createdAt)
    }
}
