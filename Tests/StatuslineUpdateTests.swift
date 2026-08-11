import XCTest
@testable import CCStatusBarLib

final class StatuslineUpdateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSession(sessionId: String, tty: String? = nil) -> Session {
        Session(
            sessionId: sessionId,
            cwd: "/tmp/\(sessionId)",
            tty: tty,
            status: .running,
            createdAt: now,
            updatedAt: now
        )
    }

    func testStatuslineUpdateDecodesKnownFieldsAndIgnoresUnknownFields() throws {
        let data = """
        {
          "session_id": "abc",
          "model": {"display_name": "Claude"},
          "context_window": {"used_percentage": 62.4, "remaining_percentage": 37.6},
          "cost": {"total_cost_usd": 1.23},
          "rate_limits": {"ignored": true}
        }
        """.data(using: .utf8)!

        let update = try JSONDecoder().decode(StatuslineUpdate.self, from: data)

        XCTAssertEqual(update.sessionId, "abc")
        XCTAssertEqual(update.contextUsedPercentage, 62.4)
        XCTAssertEqual(update.totalCostUSD, 1.23)
    }

    func testStatuslineUpdateRequiresSessionIdOnly() {
        let data = """
        {
          "context_window": {"used_percentage": 62.4},
          "cost": {"total_cost_usd": 1.23}
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(StatuslineUpdate.self, from: data))
    }

    func testApplyStatuslineUpdateMatchesBySessionIdAndUpdatesAllTTYEntries() {
        let first = makeSession(sessionId: "abc", tty: "/dev/ttys001")
        let second = makeSession(sessionId: "abc", tty: "/dev/ttys002")
        let other = makeSession(sessionId: "other", tty: "/dev/ttys003")
        var data = StoreData(sessions: [
            first.id: first,
            second.id: second,
            other.id: other
        ])

        let result = SessionStore.applyStatuslineUpdate(
            to: &data,
            update: StatuslineUpdate(sessionId: "abc", contextUsedPercentage: 62, totalCostUSD: 1.23),
            now: now.addingTimeInterval(10)
        )

        XCTAssertEqual(Set(result.matchedKeys), Set([first.id, second.id]))
        XCTAssertEqual(Set(result.updatedKeys), Set([first.id, second.id]))
        XCTAssertEqual(data.sessions[first.id]?.contextUsedPercentage, 62)
        XCTAssertEqual(data.sessions[second.id]?.totalCostUSD, 1.23)
        XCTAssertNil(data.sessions[other.id]?.contextUsedPercentage)
    }

    func testApplyStatuslineUpdatePreservesExistingValuesWhenFieldsAreMissing() {
        var session = makeSession(sessionId: "abc", tty: "/dev/ttys001")
        session.contextUsedPercentage = 40
        session.totalCostUSD = 0.5
        var data = StoreData(sessions: [session.id: session])

        let result = SessionStore.applyStatuslineUpdate(
            to: &data,
            update: StatuslineUpdate(sessionId: "abc", totalCostUSD: 0.75),
            now: now.addingTimeInterval(10)
        )

        XCTAssertEqual(result.updatedKeys, [session.id])
        XCTAssertEqual(data.sessions[session.id]?.contextUsedPercentage, 40)
        XCTAssertEqual(data.sessions[session.id]?.totalCostUSD, 0.75)
    }

    func testUsageSummaryFormatsCompactly() {
        var session = makeSession(sessionId: "abc")
        session.contextUsedPercentage = 62.4
        session.totalCostUSD = 1.23

        XCTAssertEqual(session.usageSummaryText, "62% · $1.23")
    }
}
