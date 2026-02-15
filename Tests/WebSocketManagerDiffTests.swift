import XCTest
@testable import CCStatusBarLib

final class WebSocketManagerDiffTests: XCTestCase {
    func testDetectTTYMigrationsReturnsMappingWhenSameTTYSessionIDChanges() {
        let previous = Dictionary(uniqueKeysWithValues: [
            oldSession(id: "old:/dev/ttys031", sessionId: "old", tty: "/dev/ttys031")
        ])
        let current: [Session] = [
            newSession(id: "new:/dev/ttys031", sessionId: "new", tty: "/dev/ttys031")
        ]

        let migrations = WebSocketManager.detectTTYMigrations(previous: previous, current: current)
        XCTAssertEqual(migrations["new:/dev/ttys031"], "old:/dev/ttys031")
    }

    func testDetectTTYMigrationsSkipsWhenOldSessionStillExists() {
        let previous = Dictionary(uniqueKeysWithValues: [
            oldSession(id: "old:/dev/ttys031", sessionId: "old", tty: "/dev/ttys031")
        ])
        let current: [Session] = [
            oldSession(id: "old:/dev/ttys031", sessionId: "old", tty: "/dev/ttys031").1,
            newSession(id: "new:/dev/ttys031", sessionId: "new", tty: "/dev/ttys031")
        ]

        let migrations = WebSocketManager.detectTTYMigrations(previous: previous, current: current)
        XCTAssertTrue(migrations.isEmpty)
    }

    func testDetectTTYMigrationsSkipsWhenTTYDiffers() {
        let previous = Dictionary(uniqueKeysWithValues: [
            oldSession(id: "old:/dev/ttys031", sessionId: "old", tty: "/dev/ttys031")
        ])
        let current: [Session] = [
            newSession(id: "new:/dev/ttys040", sessionId: "new", tty: "/dev/ttys040")
        ]

        let migrations = WebSocketManager.detectTTYMigrations(previous: previous, current: current)
        XCTAssertTrue(migrations.isEmpty)
    }

    func testDetectTTYMigrationsSkipsMissingTTY() {
        let previous = Dictionary(uniqueKeysWithValues: [
            oldSession(id: "old", sessionId: "old", tty: nil)
        ])
        let current: [Session] = [
            newSession(id: "new", sessionId: "new", tty: nil)
        ]

        let migrations = WebSocketManager.detectTTYMigrations(previous: previous, current: current)
        XCTAssertTrue(migrations.isEmpty)
    }

    private func oldSession(id: String, sessionId: String, tty: String?) -> (String, Session) {
        let session = Session(
            sessionId: sessionId,
            cwd: "/Users/usedhonda/projects/claude/tproj",
            tty: tty,
            status: .waitingInput,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            ghosttyTabIndex: nil,
            termProgram: "tmux",
            actualTermProgram: "iTerm.app",
            editorBundleID: nil,
            editorPID: nil,
            waitingReason: .stop,
            isToolRunning: false,
            isAcknowledged: nil,
            displayOrder: 1,
            isDisambiguated: false
        )
        return (id, session)
    }

    private func newSession(id: String, sessionId: String, tty: String?) -> Session {
        Session(
            sessionId: sessionId,
            cwd: "/Users/usedhonda/projects/claude/tproj",
            tty: tty,
            status: .running,
            createdAt: Date(timeIntervalSince1970: 3),
            updatedAt: Date(timeIntervalSince1970: 4),
            ghosttyTabIndex: nil,
            termProgram: "tmux",
            actualTermProgram: "iTerm.app",
            editorBundleID: nil,
            editorPID: nil,
            waitingReason: nil,
            isToolRunning: false,
            isAcknowledged: nil,
            displayOrder: 2,
            isDisambiguated: false
        )
    }
}
