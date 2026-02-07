import XCTest
@testable import CCStatusBarLib

final class SetupManagerHookCommandTests: XCTestCase {
    func testOwnHookCommandMatchesQuotedPathWithSpaces() {
        let command = "\"/Users/test/Library/Application Support/CCStatusBar/bin/CCStatusBar\" hook Notification"
        XCTAssertTrue(SetupManager.isOwnHookCommand(command))
    }

    func testOwnHookCommandMatchesUnquotedPath() {
        let command = "/usr/local/bin/CCStatusBar hook Stop"
        XCTAssertTrue(SetupManager.isOwnHookCommand(command))
    }

    func testOwnHookCommandRejectsNonHookCommand() {
        let command = "\"/Users/test/Library/Application Support/CCStatusBar/bin/CCStatusBar\" setup"
        XCTAssertFalse(SetupManager.isOwnHookCommand(command))
    }

    func testOwnHookCommandRejectsDevBinaryCommand() {
        let command = "\"/Users/test/Library/Application Support/CCStatusBarDev/bin/CCStatusBarDev\" hook Notification"
        XCTAssertFalse(SetupManager.isOwnHookCommand(command))
    }
}
