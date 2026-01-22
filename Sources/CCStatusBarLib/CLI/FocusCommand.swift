import ArgumentParser
import Foundation

public struct FocusCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Focus a terminal session"
    )

    @Option(name: .shortAndLong, help: "Session index (0-based)")
    var index: Int?

    @Option(name: .long, help: "Session ID (e.g., 'abc123:/dev/ttys001')")
    var id: String?

    @Flag(name: .long, help: "Focus the first waiting session (red priority, then yellow)")
    var waiting: Bool = false

    public init() {}

    public func validate() throws {
        let optionCount = [index != nil, id != nil, waiting].filter { $0 }.count
        if optionCount == 0 {
            throw ValidationError("Either --index, --id, or --waiting must be specified")
        }
        if optionCount > 1 {
            throw ValidationError("Cannot specify multiple options")
        }
    }

    public func run() {
        let sessions = SessionStore.shared.getSessions()

        guard !sessions.isEmpty else {
            printError("No active sessions")
            return
        }

        let session: Session?

        if waiting {
            // Focus first waiting session: red (permission_prompt) priority, then yellow
            let waitingSessions = sessions.filter { $0.status == .waitingInput }
            let redSessions = waitingSessions.filter { $0.waitingReason == .permissionPrompt }
            let yellowSessions = waitingSessions.filter { $0.waitingReason != .permissionPrompt }

            session = redSessions.first ?? yellowSessions.first
            if session == nil {
                printError("No waiting sessions")
                return
            }
        } else if let index = index {
            guard index >= 0 && index < sessions.count else {
                printError("Index \(index) out of range (0-\(sessions.count - 1))")
                return
            }
            session = sessions[index]
        } else if let id = id {
            session = sessions.first { $0.id == id }
            if session == nil {
                printError("Session not found: \(id)")
                return
            }
        } else {
            session = nil
        }

        guard let targetSession = session else {
            printError("Failed to find session")
            return
        }

        let result = FocusManager.shared.focus(session: targetSession)

        switch result {
        case .success:
            // Also acknowledge the session (mark as seen)
            SessionStore.shared.acknowledgeSession(sessionId: targetSession.sessionId, tty: targetSession.tty)
            print("Focused: \(targetSession.projectName)")
        case .partialSuccess(let reason):
            // Still acknowledge on partial success
            SessionStore.shared.acknowledgeSession(sessionId: targetSession.sessionId, tty: targetSession.tty)
            print("Partial: \(targetSession.projectName) (\(reason))")
        case .notFound(let hint):
            printError("Not found: \(hint)")
        case .notRunning:
            printError("Terminal is not running")
        }
    }

    private func printError(_ message: String) {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }
}
