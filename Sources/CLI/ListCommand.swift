import ArgumentParser
import Foundation

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all active sessions"
    )

    @Flag(name: .shortAndLong, help: "Output as JSON for Stream Deck integration")
    var json: Bool = false

    @Option(name: .long, help: "Offset for pagination (0-based)")
    var offset: Int = 0

    @Option(name: .long, help: "Maximum number of sessions to return")
    var limit: Int?

    func run() {
        let allSessions = SessionStore.shared.getSessions()

        if json {
            outputJSON(sessions: allSessions)
        } else {
            outputText(sessions: allSessions)
        }
    }

    private func outputText(sessions: [Session]) {
        if sessions.isEmpty {
            print("No active sessions")
            return
        }

        for session in sessions {
            let symbol = session.status.symbol
            print("\(symbol) \(session.displayPath)")
        }
    }

    private func outputJSON(sessions: [Session]) {
        let total = sessions.count
        let effectiveLimit = limit ?? total
        let startIndex = min(offset, total)
        let endIndex = min(startIndex + effectiveLimit, total)
        let slicedSessions = Array(sessions[startIndex..<endIndex])

        var jsonSessions: [[String: Any]] = []
        for session in slicedSessions {
            var item: [String: Any] = [
                "id": session.id,
                "project": session.projectName,
                "status": session.status.rawValue,
                "path": session.displayPath
            ]
            // Add waiting reason for Stream Deck color distinction
            if session.status == .waitingInput, let reason = session.waitingReason {
                item["waiting_reason"] = reason.rawValue
            }
            // Add acknowledged flag for Stream Deck
            if session.isAcknowledged == true {
                item["is_acknowledged"] = true
            }
            jsonSessions.append(item)
        }

        let output: [String: Any] = [
            "sessions": jsonSessions,
            "offset": offset,
            "total": total
        ]

        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
           let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        }
    }
}
