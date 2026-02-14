import Foundation

/// Shared filter to remove agent team subagent sessions, keeping only the leader.
/// Used by both SessionObserver (menu bar) and SessionStore (CLI/WebSocket).
enum AgentTeamFilter {
    /// Filter out agent team subagent sessions, keeping only the leader.
    /// Detection heuristic: sessions sharing the same tmux window AND same cwd
    /// are considered an agent team.
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
                // Agent team detected: choose representative session.
                // Prefer waiting sessions so actionable items stay visible.
                result.append(selectRepresentative(groupSessions))
                filteredTotal += groupSessions.count - 1
            } else {
                result.append(contentsOf: groupSessions)
            }
        }

        if filteredTotal > 0 {
            DebugLog.log("[AgentTeamFilter] Filtered \(filteredTotal) agent team subagent session(s)")
        }

        return result
    }

    /// Representative selection for grouped sessions.
    /// Priority:
    /// 1. Unacknowledged waiting_input
    /// 2. Acknowledged waiting_input
    /// 3. Oldest session (leader) for all-running groups
    static func selectRepresentative(_ sessions: [Session]) -> Session {
        precondition(!sessions.isEmpty, "selectRepresentative requires non-empty sessions")

        let waiting = sessions.filter { $0.status == .waitingInput }
        if !waiting.isEmpty {
            return waiting.sorted { lhs, rhs in
                let lhsAck = lhs.isAcknowledged == true
                let rhsAck = rhs.isAcknowledged == true
                if lhsAck != rhsAck {
                    // Unacknowledged waiting first
                    return !lhsAck
                }
                if lhs.updatedAt != rhs.updatedAt {
                    // Most recently updated waiting session first
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.createdAt < rhs.createdAt
            }[0]
        }

        // Keep original behavior for non-waiting groups.
        return sessions.sorted { $0.createdAt < $1.createdAt }[0]
    }
}
