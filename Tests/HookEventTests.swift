import XCTest
@testable import CCStatusBarLib

final class HookEventTests: XCTestCase {
    func testDecodeAskUserQuestionPayload() throws {
        let json = """
        {
          "session_id": "s1",
          "cwd": "/Users/test/project",
          "tty": "/dev/ttys001",
          "hook_event_name": "Notification",
          "notification_type": "permission_prompt",
          "message": "Question available",
          "tool_name": "AskUserQuestion",
          "question": {
            "text": "Which library should we use?",
            "options": [
              {"label": "Option A", "description": "A"},
              {"label": "Option B", "description": "B"}
            ],
            "selected_index": 1
          }
        }
        """

        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        XCTAssertTrue(event.isAskUserQuestion)
        XCTAssertEqual(event.toolName, "AskUserQuestion")
        XCTAssertEqual(event.question?.text, "Which library should we use?")
        XCTAssertEqual(event.question?.options.map(\.label), ["Option A", "Option B"])
        XCTAssertEqual(event.question?.selectedIndex, 1)
    }

    func testIsAskUserQuestionFalseWhenToolMissing() throws {
        let json = """
        {
          "session_id": "s1",
          "cwd": "/Users/test/project",
          "hook_event_name": "Notification",
          "message": "permission needed"
        }
        """

        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        XCTAssertFalse(event.isAskUserQuestion)
        XCTAssertNil(event.question)
    }

    func testDecodePostToolBatchPayload() throws {
        let json = """
        {
          "session_id": "s1",
          "cwd": "/Users/test/project",
          "hook_event_name": "PostToolBatch",
          "tool_calls": [
            {
              "tool_name": "Bash",
              "tool_input": {"command": "pwd"},
              "tool_use_id": "toolu_123",
              "tool_response": "/Users/test/project"
            }
          ]
        }
        """

        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.hookEventName, .postToolBatch)
        XCTAssertEqual(event.sessionId, "s1")
    }

    func testPostToolBatchClearsToolRunningFlag() throws {
        let json = """
        {
          "session_id": "s1",
          "cwd": "/Users/test/project",
          "hook_event_name": "PostToolBatch",
          "tool_calls": []
        }
        """

        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        let result = SessionStore.determineStatusAndReason(event: event, current: .running)

        XCTAssertEqual(result.0, .running)
        XCTAssertNil(result.1)
        XCTAssertFalse(result.2)
    }
}
