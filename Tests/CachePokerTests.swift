import XCTest
@testable import CCStatusBarLib

final class CachePokerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func idleSession(
        expiresIn: TimeInterval = 60,
        lastPromptAgo: TimeInterval = 3600,
        status: SessionStatus = .waitingInput,
        reason: WaitingReason? = .stop
    ) -> Session {
        var session = Session(
            sessionId: "s1", cwd: "/tmp/s1", tty: "/dev/ttys012",
            status: status, createdAt: now, updatedAt: now
        )
        session.waitingReason = reason
        session.cacheExpiresAt = now.addingTimeInterval(expiresIn)
        session.lastUserPromptAt = now.addingTimeInterval(-lastPromptAgo)
        return session
    }

    func testAnIdleSessionIsDueJustBeforeItsCacheGoesCold() {
        let due = CachePoker.dueSessions([idleSession()], now: now, hours: 6, alreadyPoked: [:])
        XCTAssertEqual(due.count, 1)
    }

    func testNothingIsDueOutsideTheLeadTimeOrTheWindow() {
        XCTAssertTrue(CachePoker.dueSessions([idleSession(expiresIn: 600)], now: now, hours: 6, alreadyPoked: [:]).isEmpty)
        XCTAssertTrue(CachePoker.dueSessions([idleSession(expiresIn: -5)], now: now, hours: 6, alreadyPoked: [:]).isEmpty)
        XCTAssertTrue(CachePoker.dueSessions([idleSession(lastPromptAgo: 7 * 3600)], now: now, hours: 6, alreadyPoked: [:]).isEmpty)
        XCTAssertTrue(CachePoker.dueSessions([idleSession()], now: now, hours: 0, alreadyPoked: [:]).isEmpty)
    }

    func testAPromptWaitingOnTheUserIsNeverPoked() {
        for session in [
            idleSession(reason: .permissionPrompt),
            idleSession(reason: .askUserQuestion),
            idleSession(status: .running, reason: nil),
        ] {
            XCTAssertNotNil(CachePoker.blockingReason(session))
            XCTAssertTrue(CachePoker.dueSessions([session], now: now, hours: 6, alreadyPoked: [:]).isEmpty)
        }
    }

    func testTheSameExpiryIsPokedOnlyOnce() {
        let session = idleSession()
        let poked = [session.id: session.cacheExpiresAt!]
        XCTAssertTrue(CachePoker.dueSessions([session], now: now, hours: 6, alreadyPoked: poked).isEmpty)
    }

    func testKeepAlivePromptsAreRecognised() {
        XCTAssertTrue(KeepWarm.isKeepAlivePrompt(KeepWarm.text))
        XCTAssertFalse(KeepWarm.isKeepAlivePrompt("fix the keep-alive bug"))
        XCTAssertFalse(KeepWarm.isKeepAlivePrompt(nil))
    }

    func testOnlyAnEmptyComposerIsTypedInto() {
        XCTAssertTrue(CachePoker.composerIsEmpty("output\n───\n❯ \n───\n  [Opus 5.5]\n"))
        XCTAssertFalse(CachePoker.composerIsEmpty("output\n───\n❯ half written\n───\n"))
    }

    func testOnlyLoopbackCallersAreAccepted() {
        XCTAssertTrue(KeepWarmAPI.isLoopback("127.0.0.1"))
        XCTAssertTrue(KeepWarmAPI.isLoopback("::1"))
        XCTAssertFalse(KeepWarmAPI.isLoopback("100.75.113.102"))
        XCTAssertFalse(KeepWarmAPI.isLoopback(nil))
    }

    /// sessions.json goes through Session's explicit CodingKeys; a field left
    /// out of them is silently dropped on save.
    func testCacheStateSurvivesTheSessionStore() throws {
        let session = idleSession()
        let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.cacheExpiresAt, session.cacheExpiresAt)
        XCTAssertEqual(restored.lastUserPromptAt, session.lastUserPromptAt)
    }

    func testStatuslinePromptCacheIsDecoded() throws {
        let warm = try JSONDecoder().decode(StatuslineUpdate.self, from: Data("""
        {"session_id":"s1","prompt_cache":{"warm":true,"expires_at":1800000060,"recache_tokens_if_cold":442184}}
        """.utf8))
        XCTAssertEqual(warm.cacheExpiresAt, Date(timeIntervalSince1970: 1_800_000_060))
        XCTAssertEqual(warm.cacheRecacheTokens, 442184)

        let cold = try JSONDecoder().decode(StatuslineUpdate.self, from: Data("""
        {"session_id":"s1","prompt_cache":{"warm":false,"expires_at":null}}
        """.utf8))
        XCTAssertTrue(cold.hasPromptCache)
        XCTAssertNil(cold.cacheExpiresAt)
    }
}
