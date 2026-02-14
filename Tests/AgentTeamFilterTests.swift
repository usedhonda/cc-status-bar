import XCTest
@testable import CCStatusBarLib

final class AgentTeamFilterTests: XCTestCase {
    func testSelectRepresentativePrefersUnacknowledgedWaiting() {
        let running = makeSession(
            sessionId: "running",
            status: .running,
            createdAt: date("2026-02-12T04:00:00Z"),
            updatedAt: date("2026-02-12T04:00:10Z"),
            isAcknowledged: nil
        )

        let waitingAcked = makeSession(
            sessionId: "waiting-acked",
            status: .waitingInput,
            createdAt: date("2026-02-12T04:01:00Z"),
            updatedAt: date("2026-02-12T04:01:10Z"),
            isAcknowledged: true
        )

        let waitingUnacked = makeSession(
            sessionId: "waiting-unacked",
            status: .waitingInput,
            createdAt: date("2026-02-12T04:02:00Z"),
            updatedAt: date("2026-02-12T04:02:10Z"),
            isAcknowledged: nil
        )

        let selected = AgentTeamFilter.selectRepresentative([running, waitingAcked, waitingUnacked])
        XCTAssertEqual(selected.sessionId, "waiting-unacked")
    }

    func testSelectRepresentativePrefersNewestWaitingWhenAckStateSame() {
        let older = makeSession(
            sessionId: "waiting-older",
            status: .waitingInput,
            createdAt: date("2026-02-12T04:00:00Z"),
            updatedAt: date("2026-02-12T04:00:10Z"),
            isAcknowledged: nil
        )

        let newer = makeSession(
            sessionId: "waiting-newer",
            status: .waitingInput,
            createdAt: date("2026-02-12T04:01:00Z"),
            updatedAt: date("2026-02-12T04:01:20Z"),
            isAcknowledged: nil
        )

        let selected = AgentTeamFilter.selectRepresentative([older, newer])
        XCTAssertEqual(selected.sessionId, "waiting-newer")
    }

    func testSelectRepresentativeKeepsOldestForRunningOnlyGroup() {
        let oldest = makeSession(
            sessionId: "leader",
            status: .running,
            createdAt: date("2026-02-12T04:00:00Z"),
            updatedAt: date("2026-02-12T04:10:00Z"),
            isAcknowledged: nil
        )

        let newer = makeSession(
            sessionId: "subagent",
            status: .running,
            createdAt: date("2026-02-12T04:05:00Z"),
            updatedAt: date("2026-02-12T04:20:00Z"),
            isAcknowledged: nil
        )

        let selected = AgentTeamFilter.selectRepresentative([newer, oldest])
        XCTAssertEqual(selected.sessionId, "leader")
    }

    private func makeSession(
        sessionId: String,
        status: SessionStatus,
        createdAt: Date,
        updatedAt: Date,
        isAcknowledged: Bool?
    ) -> Session {
        Session(
            sessionId: sessionId,
            cwd: "/Users/usedhonda/projects/claude/tproj",
            tty: "/dev/ttys031",
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            ghosttyTabIndex: nil,
            termProgram: "tmux",
            actualTermProgram: "iTerm.app",
            editorBundleID: nil,
            editorPID: nil,
            waitingReason: status == .waitingInput ? .stop : nil,
            isToolRunning: false,
            isAcknowledged: isAcknowledged,
            displayOrder: 1,
            isDisambiguated: false
        )
    }

    private func date(_ iso8601: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso8601) else {
            XCTFail("Invalid date string: \(iso8601)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }
}
