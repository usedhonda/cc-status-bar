import Foundation

/// Shared filter to remove agent team subagent sessions, keeping only the leader.
/// Used by both SessionObserver (menu bar) and SessionStore (CLI/WebSocket).
enum AgentTeamFilter {
    /// Filter out agent team subagent sessions, keeping only the leader.
    /// Detection heuristic: sessions sharing the same tmux window AND same cwd
    /// are considered an agent team. The oldest session (by createdAt) is the leader.
    static func filterSubagents(_ sessions: [Session]) -> [Session] {
        // Group key: (tmuxSession, tmuxWindow, cwd)
        struct GroupKey: Hashable {
            let tmuxSession: String
            let tmuxWindow: String
            let cwd: String
        }

        var groups: [GroupKey: [Session]] = [:]
        var ungrouped: [Session] = []

        for session in sessions {
            // Only group sessions that have a TTY and tmux pane info
            guard let tty = session.tty,
                  let paneInfo = TmuxHelper.getPaneInfo(for: tty) else {
                ungrouped.append(session)
                continue
            }

            let key = GroupKey(
                tmuxSession: paneInfo.session,
                tmuxWindow: paneInfo.window,
                cwd: session.cwd
            )
            groups[key, default: []].append(session)
        }

        var result = ungrouped
        var filteredTotal = 0

        for (_, groupSessions) in groups {
            if groupSessions.count >= 2 {
                // Agent team detected: keep the oldest (leader), filter out the rest
                let sorted = groupSessions.sorted { $0.createdAt < $1.createdAt }
                result.append(sorted[0])  // leader
                filteredTotal += sorted.count - 1
            } else {
                result.append(contentsOf: groupSessions)
            }
        }

        if filteredTotal > 0 {
            DebugLog.log("[AgentTeamFilter] Filtered \(filteredTotal) agent team subagent session(s)")
        }

        return result
    }
}
