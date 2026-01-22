import XCTest
@testable import CCStatusBarLib

final class SessionTests: XCTestCase {
    // MARK: - Test Helpers

    private func makeSession(
        sessionId: String = "test-session",
        cwd: String = "/Users/test/projects/my-project",
        tty: String? = "/dev/ttys001",
        status: SessionStatus = .running,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) -> Session {
        return Session(
            sessionId: sessionId,
            cwd: cwd,
            tty: tty,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - ID Tests

    func testIdWithTty() {
        let session = makeSession(sessionId: "abc123", tty: "/dev/ttys001")
        XCTAssertEqual(session.id, "abc123:/dev/ttys001")
    }

    func testIdWithoutTty() {
        let session = makeSession(sessionId: "abc123", tty: nil)
        XCTAssertEqual(session.id, "abc123")
    }

    // MARK: - Project Name Tests

    func testProjectName() {
        let session = makeSession(cwd: "/Users/test/projects/my-project")
        XCTAssertEqual(session.projectName, "my-project")
    }

    func testProjectNameWithNestedPath() {
        let session = makeSession(cwd: "/Users/test/code/apps/frontend/web-app")
        XCTAssertEqual(session.projectName, "web-app")
    }

    func testProjectNameWithRootPath() {
        let session = makeSession(cwd: "/")
        XCTAssertEqual(session.projectName, "/")
    }

    // MARK: - Display Path Tests

    func testDisplayPathWithHomeDirectory() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let session = makeSession(cwd: "\(homeDir)/projects/my-project")
        XCTAssertEqual(session.displayPath, "~/projects/my-project")
    }

    func testDisplayPathWithoutHomeDirectory() {
        let session = makeSession(cwd: "/var/log/myapp")
        XCTAssertEqual(session.displayPath, "/var/log/myapp")
    }

    // MARK: - Waiting Reason Tests

    func testWaitingReasonRawValues() {
        XCTAssertEqual(WaitingReason.permissionPrompt.rawValue, "permission_prompt")
        XCTAssertEqual(WaitingReason.stop.rawValue, "stop")
        XCTAssertEqual(WaitingReason.unknown.rawValue, "unknown")
    }

    // MARK: - JSON Encoding/Decoding Tests

    func testSessionJSONRoundTrip() throws {
        let originalSession = makeSession(
            sessionId: "json-test",
            cwd: "/Users/test/project",
            tty: "/dev/ttys005",
            status: .waitingInput
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(originalSession)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedSession = try decoder.decode(Session.self, from: data)

        XCTAssertEqual(decodedSession.sessionId, originalSession.sessionId)
        XCTAssertEqual(decodedSession.cwd, originalSession.cwd)
        XCTAssertEqual(decodedSession.tty, originalSession.tty)
        XCTAssertEqual(decodedSession.status, originalSession.status)
    }
}
