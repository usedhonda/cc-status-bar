import XCTest
@testable import CCStatusBarLib

final class SessionObserverCountTests: XCTestCase {

    // MARK: - Helper

    private func makeSession(
        status: SessionStatus = .running,
        waitingReason: WaitingReason? = nil,
        isAcknowledged: Bool? = nil,
        isToolRunning: Bool? = nil
    ) -> Session {
        Session(
            sessionId: UUID().uuidString,
            cwd: "/tmp/test-project",
            tty: "/dev/ttys\(Int.random(in: 100...999))",
            status: status,
            createdAt: Date(),
            updatedAt: Date(),
            waitingReason: waitingReason,
            isToolRunning: isToolRunning,
            isAcknowledged: isAcknowledged
        )
    }

    // MARK: - runningCount

    func testRunningCount() {
        let sessions: [Session] = [
            makeSession(status: .running),
            makeSession(status: .running),
            makeSession(status: .waitingInput, waitingReason: .stop)
        ]
        XCTAssertEqual(sessions.runningCount, 2)
    }

    func testRunningCountEmpty() {
        let sessions: [Session] = []
        XCTAssertEqual(sessions.runningCount, 0)
    }

    // MARK: - waitingCount

    func testWaitingCount() {
        let sessions: [Session] = [
            makeSession(status: .waitingInput, waitingReason: .stop),
            makeSession(status: .waitingInput, waitingReason: .permissionPrompt),
            makeSession(status: .running)
        ]
        XCTAssertEqual(sessions.waitingCount, 2)
    }

    // MARK: - unacknowledgedRedCount

    func testUnacknowledgedRedCount() {
        let sessions: [Session] = [
            makeSession(status: .waitingInput, waitingReason: .permissionPrompt),
            makeSession(status: .waitingInput, waitingReason: .permissionPrompt, isAcknowledged: true),
            makeSession(status: .waitingInput, waitingReason: .stop),
            makeSession(status: .running)
        ]
        XCTAssertEqual(sessions.unacknowledgedRedCount, 1)
    }

    func testUnacknowledgedRedCountAllAcknowledged() {
        let sessions: [Session] = [
            makeSession(status: .waitingInput, waitingReason: .permissionPrompt, isAcknowledged: true)
        ]
        XCTAssertEqual(sessions.unacknowledgedRedCount, 0)
    }

    // MARK: - unacknowledgedYellowCount

    func testUnacknowledgedYellowCount() {
        let sessions: [Session] = [
            makeSession(status: .waitingInput, waitingReason: .stop),
            makeSession(status: .waitingInput, waitingReason: .unknown),
            makeSession(status: .waitingInput, waitingReason: .permissionPrompt),
            makeSession(status: .waitingInput, waitingReason: .stop, isAcknowledged: true)
        ]
        // stop(unack) + unknown(unack) = 2, permissionPrompt is excluded, ack'd stop is excluded
        XCTAssertEqual(sessions.unacknowledgedYellowCount, 2)
    }

    func testUnacknowledgedYellowCountExcludesPermissionPrompt() {
        let sessions: [Session] = [
            makeSession(status: .waitingInput, waitingReason: .permissionPrompt)
        ]
        XCTAssertEqual(sessions.unacknowledgedYellowCount, 0)
    }

    // MARK: - displayedGreenCount

    func testDisplayedGreenCount() {
        let sessions: [Session] = [
            makeSession(status: .running),
            makeSession(status: .running),
            makeSession(status: .waitingInput, waitingReason: .stop, isAcknowledged: true),
            makeSession(status: .waitingInput, waitingReason: .stop)
        ]
        // 2 running + 1 acknowledged waiting = 3
        XCTAssertEqual(sessions.displayedGreenCount, 3)
    }

    func testDisplayedGreenCountNoAcknowledged() {
        let sessions: [Session] = [
            makeSession(status: .running),
            makeSession(status: .waitingInput, waitingReason: .stop)
        ]
        XCTAssertEqual(sessions.displayedGreenCount, 1)
    }

    // MARK: - toolRunningCount

    func testToolRunningCount() {
        let sessions: [Session] = [
            makeSession(status: .running, isToolRunning: true),
            makeSession(status: .running, isToolRunning: false),
            makeSession(status: .running, isToolRunning: true),
            makeSession(status: .running)
        ]
        XCTAssertEqual(sessions.toolRunningCount, 2)
    }

    func testToolRunningCountNilIsNotCounted() {
        let sessions: [Session] = [
            makeSession(status: .running),
            makeSession(status: .running)
        ]
        XCTAssertEqual(sessions.toolRunningCount, 0)
    }

    // MARK: - hasActiveSessions

    func testHasActiveSessionsTrue() {
        let sessions: [Session] = [makeSession()]
        XCTAssertTrue(sessions.hasActiveSessions)
    }

    func testHasActiveSessionsFalse() {
        let sessions: [Session] = []
        XCTAssertFalse(sessions.hasActiveSessions)
    }

    // MARK: - unacknowledgedWaitingCount

    func testUnacknowledgedWaitingCount() {
        let sessions: [Session] = [
            makeSession(status: .waitingInput, waitingReason: .stop),
            makeSession(status: .waitingInput, waitingReason: .permissionPrompt, isAcknowledged: true),
            makeSession(status: .waitingInput, waitingReason: .stop)
        ]
        XCTAssertEqual(sessions.unacknowledgedWaitingCount, 2)
    }
}
