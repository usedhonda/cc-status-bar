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
}
