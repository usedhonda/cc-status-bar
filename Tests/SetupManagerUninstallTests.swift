import XCTest
@testable import CCStatusBarLib

final class SetupManagerUninstallTests: XCTestCase {
    func testUninstallPreservesOtherHooksInSharedGroup() throws {
        let ownHook = ["type": "command", "command": "\"/tmp/fixture/CCStatusBar\" hook PreToolUse"]
        let otherHook = ["type": "command", "command": "/tmp/fixture/policy-check"]
        let group: [String: Any] = [
            "matcher": "Bash",
            "timeout": 45,
            "hooks": [ownHook, otherHook]
        ]

        let result = SetupManager.removingOwnHooks(from: [group])

        XCTAssertEqual(result.count, 1)
        let remaining = try XCTUnwrap(result.first)
        XCTAssertEqual(remaining["matcher"] as? String, "Bash")
        XCTAssertEqual(remaining["timeout"] as? Int, 45)
        XCTAssertEqual(remaining["hooks"] as? [[String: String]], [otherHook])
    }

    func testUninstallRemovesOwnOnlyGroupsAndPreservesUnrelatedEntries() throws {
        let ownGroup: [String: Any] = [
            "hooks": [["type": "command", "command": "/tmp/fixture/CCStatusBar hook Stop"]]
        ]
        let otherGroup: [String: Any] = [
            "matcher": "*",
            "hooks": [["type": "command", "command": "/tmp/fixture/other-hook"]]
        ]
        let opaqueGroup: [String: Any] = ["matcher": "opaque", "custom": true]
        let result = SetupManager.removingOwnHooks(from: [ownGroup, otherGroup, opaqueGroup])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?["matcher"] as? String, "*")
        XCTAssertEqual(result.last?["custom"] as? Bool, true)
    }
}
