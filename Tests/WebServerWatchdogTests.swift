import XCTest
@testable import CCStatusBarLib

/// The listener once died silently after a failed accept and stayed dead for
/// hours while the app still reported the server as running.
final class WebServerWatchdogTests: XCTestCase {
    func testADeadListenerIsDetectedAndRestarted() throws {
        let server = WebServer.shared
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(server.isListening)

        server.killListenerForTesting()
        XCTAssertTrue(server.isRunning, "the app still believes it is running")
        XCTAssertFalse(server.isListening)

        XCTAssertTrue(server.ensureListening())
        XCTAssertTrue(server.isListening)
        XCTAssertFalse(server.ensureListening(), "a healthy listener is left alone")
    }
    func testFailedRestartRetriesAfterRecoveryAndExplicitStopSuppressesIt() throws {
        enum Failure: Error { case unavailable }
        var attempts = 0
        var failStart = false
        var listening = false
        let server = WebServer(startListener: { _, _ in
            attempts += 1
            if failStart { throw Failure.unavailable }
            listening = true
        }, listenerIsOperating: { _ in listening })
        defer { server.stop() }
        try server.start()
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(server.ensureListening())
        XCTAssertEqual(attempts, 1, "healthy listener is a no-op")

        listening = false
        failStart = true
        XCTAssertTrue(server.ensureListening())
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(attempts, 11, "one bounded ten-port attempt")
        failStart = false
        XCTAssertTrue(server.ensureListening())
        XCTAssertTrue(server.isListening)
        XCTAssertEqual(attempts, 12)

        server.stop()
        listening = false
        XCTAssertFalse(server.ensureListening())
        XCTAssertEqual(attempts, 12, "explicit stop must suppress retries")
    }

}
