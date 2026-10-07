import XCTest
@testable import CCStatusBarLib

/// Issue #18: substring edits could turn a valid Codex config into invalid
/// TOML or put `notify` inside the last table instead of the root.
final class CodexConfigEditorTests: XCTestCase {
    private let script = "/tmp/fixture/codex-notify.py"

    private func rootNotify(_ content: String) throws -> Int {
        try CodexConfigEditor.scannedLines(content).filter { $0.table == nil && $0.key == "notify" }.count
    }

    func testAnExplicitlyDisabledHooksFlagIsKeptAndNotDuplicated() throws {
        let input = "[features]\ncodex_hooks = false\n"
        let edit = try CodexConfigEditor.ensuringHooksFeatureFlag(in: input)
        XCTAssertEqual(edit.content, input)
        XCTAssertTrue(CodexConfigEditor.isConsistent(edit.content))
    }

    func testADuplicateLeftByTheOldEditIsRepaired() throws {
        let broken = "[features]\ncodex_hooks = true\ncodex_hooks = false\n"
        XCTAssertFalse(CodexConfigEditor.isConsistent(broken))
        let edit = try CodexConfigEditor.ensuringHooksFeatureFlag(in: broken)
        XCTAssertEqual(edit.content, "[features]\ncodex_hooks = false\n")
    }

    func testTheHooksFlagIsAddedToAnExistingOrANewFeaturesTable() throws {
        let existing = try CodexConfigEditor.ensuringHooksFeatureFlag(in: "model = \"x\"\n\n[features]\nother = 1\n")
        XCTAssertEqual(existing.content, "model = \"x\"\n\n[features]\ncodex_hooks = true\nother = 1\n")

        let fresh = try CodexConfigEditor.ensuringHooksFeatureFlag(in: "model = \"x\"\n")
        XCTAssertEqual(fresh.content, "model = \"x\"\n\n[features]\ncodex_hooks = true\n")

        let again = try CodexConfigEditor.ensuringHooksFeatureFlag(in: fresh.content)
        XCTAssertEqual(again.content, fresh.content, "idempotent")
    }

    func testNotifyGoesToTheRootEvenWhenTheFileEndsInATable() throws {
        let input = "[projects.\"/tmp/fixture-project\"]\ntrust_level = \"trusted\"\n"
        let edit = try CodexConfigEditor.ensuringRootNotify(in: input, scriptPath: script)

        XCTAssertEqual(try rootNotify(edit.content), 1)
        XCTAssertTrue(edit.content.hasSuffix(input), "the table and its keys are untouched")
        let again = try CodexConfigEditor.ensuringRootNotify(in: edit.content, scriptPath: script)
        XCTAssertEqual(again.content, edit.content, "idempotent")
    }

    func testNotifyIsPlacedAfterRootKeysAndBeforeTheFirstTable() throws {
        let input = "model = \"x\"  # comment\n\n[mcp_servers.a]\ncommand = \"b\"\nargs = [\n  \"[not-a-table]\",\n]\n"
        let edit = try CodexConfigEditor.ensuringRootNotify(in: input, scriptPath: script)
        XCTAssertEqual(
            edit.content,
            "model = \"x\"  # comment\n\n\(CodexConfigEditor.comment)\nnotify = [\"python3\", \"\(script)\"]\n\n"
                + "[mcp_servers.a]\ncommand = \"b\"\nargs = [\n  \"[not-a-table]\",\n]\n"
        )
    }

    func testAnEmptyConfigGetsJustTheNotifyBlock() throws {
        let edit = try CodexConfigEditor.ensuringRootNotify(in: "", scriptPath: script)
        XCTAssertEqual(edit.content, "\(CodexConfigEditor.comment)\nnotify = [\"python3\", \"\(script)\"]\n")
    }

    func testAThirdPartyNotifyIsPreserved() throws {
        let input = "notify = [\"/usr/local/bin/other-notifier\"]\n\n[features]\ncodex_hooks = true\n"
        let edit = try CodexConfigEditor.ensuringRootNotify(in: input, scriptPath: script)
        XCTAssertEqual(edit.content, input)
        XCTAssertFalse(edit.notes.isEmpty, "says why nothing was installed")
    }

    func testOurNotifyWrittenInsideATableByTheOldEditIsMovedToTheRoot() throws {
        let broken = "[projects.\"/tmp/p\"]\ntrust_level = \"trusted\"\n\n\(CodexConfigEditor.comment)\n"
            + "notify = [\"python3\", \"\(script)\"]\n"
        let edit = try CodexConfigEditor.ensuringRootNotify(in: broken, scriptPath: script)
        XCTAssertEqual(try rootNotify(edit.content), 1)
        let inTable = try CodexConfigEditor.scannedLines(edit.content).filter { $0.table != nil && $0.key == "notify" }
        XCTAssertTrue(inTable.isEmpty)
    }

    func testMultiLineStringsAreRefusedRatherThanGuessedAt() {
        let input = "instructions = \"\"\"\n[looks like a table]\n\"\"\"\n"
        XCTAssertThrowsError(try CodexConfigEditor.ensuringRootNotify(in: input, scriptPath: script)) { error in
            XCTAssertEqual(error as? CodexConfigEditor.EditError, .unsupported("multi-line strings"))
        }
    }
}
