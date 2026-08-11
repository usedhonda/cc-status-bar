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

    func testStatuslineRegistrationAddsCommandWhenMissing() throws {
        var settings: [String: Any] = [:]

        let result = SetupManager.applyStatuslineRegistration(
            to: &settings,
            hookPath: "/Users/test/Library/Application Support/CCStatusBar/bin/CCStatusBar"
        )

        XCTAssertEqual(result, .registered)
        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: String])
        XCTAssertEqual(statusLine["type"], "command")
        XCTAssertEqual(
            statusLine["command"],
            "\"/Users/test/Library/Application Support/CCStatusBar/bin/CCStatusBar\" statusline"
        )
    }

    func testStatuslineRegistrationDoesNotOverwriteExistingSetting() throws {
        var settings: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": "/usr/local/bin/custom-statusline"
            ]
        ]

        let result = SetupManager.applyStatuslineRegistration(
            to: &settings,
            hookPath: "/Users/test/Library/Application Support/CCStatusBar/bin/CCStatusBar"
        )

        XCTAssertEqual(result, .skippedExisting)
        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: String])
        XCTAssertEqual(statusLine["command"], "/usr/local/bin/custom-statusline")
    }

    func testMissingHookRegistrationAddsOnlyMissingEvents() throws {
        let hookPath = "/Users/test/Library/Application Support/CCStatusBar/bin/CCStatusBar"
        var settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "hooks": [
                            ["type": "command", "command": "\"\(hookPath)\" hook PreToolUse"]
                        ]
                    ]
                ],
                "PostToolBatch": [
                    [
                        "hooks": [
                            ["type": "command", "command": "/usr/local/bin/other-hook"]
                        ]
                    ]
                ]
            ]
        ]

        let addedEvents = SetupManager.applyMissingHookRegistration(
            to: &settings,
            hookPath: hookPath
        )

        XCTAssertFalse(addedEvents.contains("PreToolUse"))
        XCTAssertTrue(addedEvents.contains("PostToolBatch"))

        let hooks = try XCTUnwrap(settings["hooks"] as? [String: [[String: Any]]])
        let preToolUseHooks = try XCTUnwrap(hooks["PreToolUse"])
        XCTAssertEqual(preToolUseHooks.count, 1)

        let postToolBatchHooks = try XCTUnwrap(hooks["PostToolBatch"])
        XCTAssertEqual(postToolBatchHooks.count, 2)
        let lastEntry = try XCTUnwrap(postToolBatchHooks.last)
        let innerHooks = try XCTUnwrap(lastEntry["hooks"] as? [[String: String]])
        XCTAssertEqual(innerHooks.first?["command"], "\"\(hookPath)\" hook PostToolBatch")
    }
}
