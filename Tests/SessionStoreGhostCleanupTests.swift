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

// MARK: - Live session seeding

extension SessionStoreGhostCleanupTests {
    private func agent(
        sessionId: String,
        cwd: String? = nil,
        kind: String? = "interactive",
        status: String? = "idle"
    ) -> ClaudeAgentRecord {
        ClaudeAgentRecord(
            sessionId: sessionId,
            cwd: cwd ?? "/tmp/\(sessionId)",
            pid: 1,
            kind: kind,
            status: status
        )
    }

    func testLiveSessionMissingFromStoreIsSeeded() {
        var data = StoreData(sessions: [:])
        let seeded = SessionStore.applyClaudeLiveSessionSeeding(
            to: &data,
            liveAgents: [agent(sessionId: "unseen")],
            now: now
        )
        XCTAssertEqual(seeded, ["unseen"])
        XCTAssertEqual(data.sessions["unseen"]?.sessionId, "unseen")
    }

    func testSeedingNeverDuplicatesAKnownSession() {
        // The hook-created entry is keyed with its tty; seeding must not add a second row.
        let known = makeSession(sessionId: "known", updatedAt: now, tty: "/dev/ttys001")
        var data = StoreData(sessions: [known.id: known])
        let seeded = SessionStore.applyClaudeLiveSessionSeeding(
            to: &data,
            liveAgents: [agent(sessionId: "known")],
            now: now
        )
        XCTAssertTrue(seeded.isEmpty)
        XCTAssertEqual(data.sessions.count, 1)
    }

    func testBackgroundAgentsAreNotSeeded() {
        var data = StoreData(sessions: [:])
        let seeded = SessionStore.applyClaudeLiveSessionSeeding(
            to: &data,
            liveAgents: [agent(sessionId: "sub", kind: "background")],
            now: now
        )
        XCTAssertTrue(seeded.isEmpty)
        XCTAssertTrue(data.sessions.isEmpty)
    }

    func testHookEntrySupersedesAnEarlierSeededEntry() {
        let seededEarlier = makeSession(sessionId: "dup", updatedAt: now, tty: nil)
        let fromHook = makeSession(sessionId: "dup", updatedAt: now, tty: "/dev/ttys002")
        var data = StoreData(sessions: [seededEarlier.id: seededEarlier, fromHook.id: fromHook])
        _ = SessionStore.applyClaudeLiveSessionSeeding(to: &data, liveAgents: [], now: now)
        XCTAssertEqual(data.sessions.count, 1)
        XCTAssertNotNil(data.sessions[fromHook.id])
    }

    func testSeededStateFollowsTheCLIVocabulary() {
        XCTAssertEqual(SessionStore.claudeAgentState(from: "busy").0, .running)
        XCTAssertEqual(SessionStore.claudeAgentState(from: "idle").0, .waitingInput)
        XCTAssertEqual(SessionStore.claudeAgentState(from: "idle").1, .idle)
        XCTAssertEqual(SessionStore.claudeAgentState(from: "waiting").0, .waitingInput)
        // GUARD: a seeded session must never be reported as finished — the CLI list cannot
        // tell "done" from "waiting for you", and inventing completion is the bug this
        // whole status surface has been fighting.
        for status in ["busy", "idle", "waiting", "unknown-future-value", nil] {
            XCTAssertNotEqual(SessionStore.claudeAgentState(from: status).0, .stopped)
        }
    }

    func testSeededSessionAdoptsTheResolvedTty() {
        var data = StoreData(sessions: [:])
        let seeded = SessionStore.applyClaudeLiveSessionSeeding(
            to: &data,
            liveAgents: [agent(sessionId: "paned")],
            now: now,
            ttyResolver: { _ in "/dev/ttys006" }
        )
        // Keyed like a hook-created session, so it lands in the tmux section and a later
        // hook for the same pane updates this row instead of adding a second one.
        XCTAssertEqual(seeded, ["paned:/dev/ttys006"])
        XCTAssertEqual(data.sessions["paned:/dev/ttys006"]?.tty, "/dev/ttys006")
    }

    func testSeedingSurvivesAnUnresolvableTty() {
        var data = StoreData(sessions: [:])
        let seeded = SessionStore.applyClaudeLiveSessionSeeding(
            to: &data,
            liveAgents: [agent(sessionId: "detached")],
            now: now,
            ttyResolver: { _ in nil }
        )
        // Better a session with no pane binding than no session at all.
        XCTAssertEqual(seeded, ["detached"])
        XCTAssertNil(data.sessions["detached"]?.tty)
    }

    func testParseClaudeAgentRecordsKeepsKindAndStatus() throws {
        let data = """
        [{"pid": 1, "cwd": "/tmp/a", "sessionId": "a", "kind": "interactive", "status": "busy"}]
        """.data(using: .utf8)!
        let records = try XCTUnwrap(SessionStore.parseClaudeAgentRecords(from: data))
        XCTAssertEqual(records.first?.kind, "interactive")
        XCTAssertEqual(records.first?.status, "busy")
    }
}
