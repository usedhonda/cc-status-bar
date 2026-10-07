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
}
