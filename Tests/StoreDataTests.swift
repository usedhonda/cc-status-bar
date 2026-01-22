import XCTest
@testable import CCStatusBarLib

final class StoreDataTests: XCTestCase {
    // MARK: - Test Helpers

    private func makeSession(
        sessionId: String,
        status: SessionStatus = .running,
        updatedAt: Date = Date(),
        displayOrder: Int? = nil
    ) -> Session {
        var session = Session(
            sessionId: sessionId,
            cwd: "/Users/test/\(sessionId)",
            tty: "/dev/ttys00\(sessionId.suffix(1))",
            status: status,
            createdAt: Date(),
            updatedAt: updatedAt
        )
        session.displayOrder = displayOrder
        return session
    }

    // MARK: - Initialization Tests

    func testInitWithEmptySessions() {
        let store = StoreData()
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testInitWithSessions() {
        let session = makeSession(sessionId: "test1")
        let store = StoreData(sessions: ["test1:/dev/ttys001": session])
        XCTAssertEqual(store.sessions.count, 1)
    }

    // MARK: - Active Sessions Filter Tests

    func testActiveSessionsExcludesStopped() {
        let running = makeSession(sessionId: "running1", status: .running)
        let stopped = makeSession(sessionId: "stopped1", status: .stopped)
        let waiting = makeSession(sessionId: "waiting1", status: .waitingInput)

        let store = StoreData(sessions: [
            running.id: running,
            stopped.id: stopped,
            waiting.id: waiting
        ])

        let active = store.activeSessions
        XCTAssertEqual(active.count, 2)
        XCTAssertTrue(active.contains { $0.sessionId == "running1" })
        XCTAssertTrue(active.contains { $0.sessionId == "waiting1" })
        XCTAssertFalse(active.contains { $0.sessionId == "stopped1" })
    }

    // MARK: - Display Order Tests

    func testActiveSessionsSortedByDisplayOrder() {
        let session1 = makeSession(sessionId: "s1", displayOrder: 3)
        let session2 = makeSession(sessionId: "s2", displayOrder: 1)
        let session3 = makeSession(sessionId: "s3", displayOrder: 2)

        let store = StoreData(sessions: [
            session1.id: session1,
            session2.id: session2,
            session3.id: session3
        ])

        let active = store.activeSessions
        XCTAssertEqual(active[0].sessionId, "s2") // displayOrder: 1
        XCTAssertEqual(active[1].sessionId, "s3") // displayOrder: 2
        XCTAssertEqual(active[2].sessionId, "s1") // displayOrder: 3
    }

    func testActiveSessionsWithMixedDisplayOrder() {
        // Sessions with displayOrder should come before those without
        let withOrder = makeSession(sessionId: "ordered", displayOrder: 5)
        let withoutOrder = makeSession(sessionId: "unordered", displayOrder: nil)

        let store = StoreData(sessions: [
            withOrder.id: withOrder,
            withoutOrder.id: withoutOrder
        ])

        let active = store.activeSessions
        XCTAssertEqual(active[0].sessionId, "ordered")
        XCTAssertEqual(active[1].sessionId, "unordered")
    }

    // MARK: - JSON Encoding/Decoding Tests

    func testStoreDataJSONRoundTrip() throws {
        let session = makeSession(sessionId: "json-test", displayOrder: 1)
        let store = StoreData(sessions: [session.id: session])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedStore = try decoder.decode(StoreData.self, from: data)

        XCTAssertEqual(decodedStore.sessions.count, 1)
        XCTAssertNotNil(decodedStore.sessions[session.id])
    }
}
