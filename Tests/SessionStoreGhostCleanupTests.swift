import XCTest
@testable import CCStatusBarLib

final class SessionStoreGhostCleanupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSession(
        sessionId: String,
        status: SessionStatus = .running,
        updatedAt: Date,
        tty: String? = nil
    ) -> Session {
        Session(
            sessionId: sessionId,
            cwd: "/tmp/\(sessionId)",
            tty: tty,
            status: status,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    func testParseClaudeAgentSessionIds() throws {
        let data = """
        [
          {"pid": 100, "cwd": "/tmp/live", "sessionId": "live-1", "status": "idle"},
          {"pid": 101, "cwd": "/tmp/live2", "sessionId": "live-2", "status": "running"}
        ]
        """.data(using: .utf8)!

        XCTAssertEqual(SessionStore.parseClaudeAgentSessionIds(from: data), ["live-1", "live-2"])
    }

    func testParseClaudeAgentSessionIdsReturnsNilForInvalidJSON() {
        XCTAssertNil(SessionStore.parseClaudeAgentSessionIds(from: Data("{}".utf8)))
    }

    func testLiveSessionIsKept() {
        let live = makeSession(
            sessionId: "live",
            updatedAt: now.addingTimeInterval(-10_000),
            tty: "/dev/ttys001"
        )
        var data = StoreData(sessions: [live.id: live])

        let result = SessionStore.applyClaudeGhostCleanup(
            to: &data,
            liveSessionIds: ["live"],
            now: now,
            removalGrace: 60
        )

        XCTAssertFalse(result.changed)
        XCTAssertEqual(data.sessions[live.id]?.status, .running)
    }

    func testFreshMissingSessionIsMarkedStopped() {
        let ghost = makeSession(
            sessionId: "ghost",
            status: .waitingInput,
            updatedAt: now.addingTimeInterval(-30),
            tty: "/dev/ttys002"
        )
        var data = StoreData(sessions: [ghost.id: ghost])

        let result = SessionStore.applyClaudeGhostCleanup(
            to: &data,
            liveSessionIds: [],
            now: now,
            removalGrace: 60
        )

        XCTAssertEqual(result.markedStopped, [ghost.id])
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(data.sessions[ghost.id]?.status, .stopped)
        XCTAssertEqual(data.sessions[ghost.id]?.updatedAt, now)
        XCTAssertEqual(data.sessions[ghost.id]?.isToolRunning, false)
    }

    func testOldMissingSessionIsRemoved() {
        let ghost = makeSession(
            sessionId: "ghost",
            updatedAt: now.addingTimeInterval(-61),
            tty: "/dev/ttys003"
        )
        var data = StoreData(sessions: [ghost.id: ghost])

        let result = SessionStore.applyClaudeGhostCleanup(
            to: &data,
            liveSessionIds: [],
            now: now,
            removalGrace: 60
        )

        XCTAssertTrue(result.markedStopped.isEmpty)
        XCTAssertEqual(result.removed, [ghost.id])
        XCTAssertTrue(data.sessions.isEmpty)
    }

    func testFreshStoppedSessionWaitsForGrace() {
        let ghost = makeSession(
            sessionId: "ghost",
            status: .stopped,
            updatedAt: now,
            tty: "/dev/ttys004"
        )
        var data = StoreData(sessions: [ghost.id: ghost])

        let result = SessionStore.applyClaudeGhostCleanup(
            to: &data,
            liveSessionIds: [],
            now: now,
            removalGrace: 60
        )

        XCTAssertFalse(result.changed)
        XCTAssertEqual(data.sessions[ghost.id]?.status, .stopped)
    }

    func testOldStoppedSessionIsRemoved() {
        let ghost = makeSession(
            sessionId: "ghost",
            status: .stopped,
            updatedAt: now.addingTimeInterval(-61),
            tty: "/dev/ttys004"
        )
        var data = StoreData(sessions: [ghost.id: ghost])

        let result = SessionStore.applyClaudeGhostCleanup(
            to: &data,
            liveSessionIds: [],
            now: now,
            removalGrace: 60
        )

        XCTAssertEqual(result.removed, [ghost.id])
        XCTAssertTrue(data.sessions.isEmpty)
    }
}
