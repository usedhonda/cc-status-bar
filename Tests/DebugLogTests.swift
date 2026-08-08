import XCTest
@testable import CCStatusBarLib

final class DebugLogTests: XCTestCase {
    func testHotPathMessagesAreSuppressedByDefault() {
        XCTAssertFalse(DebugLog.shouldWrite(message: "[TmuxHelper] Cache hit for TTY ttys001", verbose: false))
        XCTAssertFalse(DebugLog.shouldWrite(message: "[TmuxHelper] Found pane: s:1.2 for TTY ttys001", verbose: false))
        XCTAssertFalse(DebugLog.shouldWrite(message: "[GhosttyHelper] Tab titles cache hit", verbose: false))
    }

    func testInfoMessagesAreWrittenByDefault() {
        XCTAssertTrue(DebugLog.shouldWrite(message: "[CodexObserver] Codex hooks mode: enabled", verbose: false))
        XCTAssertTrue(DebugLog.shouldWrite(message: "[CodexObserver] Background refresh complete (4 sessions)", verbose: false))
    }

    func testVerboseModeWritesHotPathMessages() {
        XCTAssertTrue(DebugLog.shouldWrite(message: "[TmuxHelper] Cache hit for TTY ttys001", verbose: true))
    }

    func testRotateLogIfNeededKeepsOneRotatedGeneration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCStatusBarDebugLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let logURL = dir.appendingPathComponent("debug.log")
        let rotatedURL = dir.appendingPathComponent("debug.log.1")
        try Data(repeating: 0x61, count: 32).write(to: logURL)
        try Data(repeating: 0x62, count: 8).write(to: rotatedURL)

        DebugLog.rotateLogIfNeeded(at: logURL, maxBytes: 16)

        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path))
        XCTAssertEqual(try Data(contentsOf: rotatedURL), Data(repeating: 0x61, count: 32))
    }
}
