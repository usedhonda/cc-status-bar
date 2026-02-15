import ArgumentParser
import Foundation

public struct ListCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all active sessions"
    )

    @Flag(name: .shortAndLong, help: "Output as JSON for Stream Deck integration")
    var json: Bool = false

    @Flag(name: .long, help: "Include tmux attach commands for remote access")
    var withTmux: Bool = false

    @Option(name: .long, help: "Offset for pagination (0-based)")
    var offset: Int = 0

    @Option(name: .long, help: "Maximum number of sessions to return")
    var limit: Int?

    public init() {}

    public func run() {
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
            print("\(symbol) \(session.displayName)")

            if withTmux {
                // Show detailed info for remote access
                print("   Path: \(session.displayPath)")
                print("   Status: \(session.status.label)")

                // Show waiting reason and duration if applicable
                if session.status == .waitingInput {
                    if let reason = session.waitingReason {
                        print("   Reason: \(reason.rawValue)")
                    }
                    let waitingTime = formatWaitingTime(since: session.updatedAt)
                    print("   Waiting: \(waitingTime)")
                }

                // Show tmux info if available
                if let tty = session.tty,
                   let remoteInfo = TmuxHelper.getRemoteAccessInfo(for: tty) {
                    print("   Tmux: \(remoteInfo.targetSpecifier)")
                    print("   Attach: \(remoteInfo.attachCommand)")
                } else {
                    print("   Tmux: N/A (not in tmux)")
                }
                print("")  // Blank line between sessions
            }
        }
    }

    /// Format waiting time as human-readable string
    private func formatWaitingTime(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else {
            return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
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
                "project": session.displayName,
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
            // Add environment label and icon for Stream Deck
            item["environment"] = session.environmentLabel
            let env = EnvironmentResolver.shared.resolve(session: session)
            if let iconBase64 = IconManager.shared.iconBase64(for: env, size: 40) {
                item["icon_base64"] = iconBase64
            }

            // Add tmux info for remote access (when --with-tmux is specified)
            if withTmux {
                if let tty = session.tty,
                   let remoteInfo = TmuxHelper.getRemoteAccessInfo(for: tty) {
                    item["tmux"] = [
                        "session": remoteInfo.sessionName,
                        "target": remoteInfo.targetSpecifier,
                        "attach_command": remoteInfo.attachCommand
                    ]
                }

                // Add waiting time for remote monitoring
                if session.status == .waitingInput {
                    let seconds = Int(Date().timeIntervalSince(session.updatedAt))
                    item["waiting_seconds"] = seconds
                    item["waiting_time"] = formatWaitingTime(since: session.updatedAt)
                }
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
