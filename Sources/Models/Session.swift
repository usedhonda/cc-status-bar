import Foundation

struct Session: Codable, Identifiable {
    let sessionId: String
    let cwd: String
    let tty: String?
    var status: SessionStatus
    let createdAt: Date
    var updatedAt: Date

    var id: String {
        tty.map { "\(sessionId):\($0)" } ?? sessionId
    }

    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var displayPath: String {
        cwd.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case tty
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
