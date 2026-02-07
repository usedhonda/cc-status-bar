import XCTest
@testable import CCStatusBarLib

final class CodexStatusReceiverTests: XCTestCase {
    @MainActor
    func testInferWaitingReasonDefaultsToStop() {
        let reason = CodexStatusReceiver.inferWaitingReason(from: [
            "type": "agent-turn-complete",
            "cwd": "/tmp/project"
        ])
        XCTAssertEqual(reason, .stop)
    }

    @MainActor
    func testInferWaitingReasonDetectsPermissionPrompt() {
        let reason = CodexStatusReceiver.inferWaitingReason(from: [
            "type": "agent-turn-complete",
            "notification_type": "permission_prompt"
        ])
        XCTAssertEqual(reason, .permissionPrompt)
    }

    @MainActor
    func testInferWaitingReasonDetectsApprovalTokensInNestedPayload() {
        let reason = CodexStatusReceiver.inferWaitingReason(from: [
            "type": "agent-turn-complete",
            "payload": [
                "reason": "approval_required"
            ]
        ])
        XCTAssertEqual(reason, .permissionPrompt)
    }

    @MainActor
    func testInferWaitingReasonFromArrayPayload() {
        let reason = CodexStatusReceiver.inferWaitingReason(from: [
            "type": "agent-turn-complete",
            "items": ["something", "permission_prompt", "other"]
        ])
        XCTAssertEqual(reason, .permissionPrompt)
    }

    @MainActor
    func testInferWaitingReasonEmptyPayload() {
        let reason = CodexStatusReceiver.inferWaitingReason(from: [:])
        XCTAssertEqual(reason, .stop)
    }

    @MainActor
    func testInferWaitingReasonUnrelatedKeys() {
        let reason = CodexStatusReceiver.inferWaitingReason(from: [
            "type": "agent-turn-complete",
            "thread-id": "abc-123",
            "cwd": "/tmp/project",
            "metadata": ["key": "value"]
        ])
        XCTAssertEqual(reason, .stop)
    }
}
