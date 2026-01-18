import ArgumentParser

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all active sessions"
    )

    func run() {
        let sessions = SessionStore.shared.getSessions()

        if sessions.isEmpty {
            print("No active sessions")
            return
        }

        for session in sessions {
            let symbol = session.status.symbol
            print("\(symbol) \(session.displayPath)")
        }
    }
}
