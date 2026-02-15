import XCTest
@testable import CCStatusBarLib

final class CodexStatusReceiverTests: XCTestCase {
    @MainActor
    override func setUp() {
        super.setUp()
        CodexStatusReceiver.shared.clearAll()
    }

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
    func testInferWaitingReasonDoesNotUseLooseNestedTokens() {
        let reason = CodexStatusReceiver.inferWaitingReason(from: [
            "type": "agent-turn-complete",
            "payload": [
                "reason": "approval_required"
            ]
        ])
        XCTAssertEqual(reason, .stop)
    }

    @MainActor
    func testInferWaitingReasonDoesNotUseLooseArrayTokens() {
        let reason = CodexStatusReceiver.inferWaitingReason(from: [
            "type": "agent-turn-complete",
            "items": ["something", "permission_prompt", "other"]
        ])
        XCTAssertEqual(reason, .stop)
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

    @MainActor
    func testInferWaitingReasonDetectsHighConfidencePlanPromptFromPaneCapture() {
        let paneCapture = """
        Implement this plan?
        1. Yes, implement this … Switch to Default and start coding.
        2. No, stay in Plan mode … Continue planning with the model.
        """
        let reason = CodexStatusReceiver.inferWaitingReason(
            from: ["type": "agent-turn-complete"],
            paneCapture: paneCapture
        )
        XCTAssertEqual(reason, .permissionPrompt)
    }

    @MainActor
    func testInferWaitingReasonRequiresAllHighConfidencePlanPromptTokens() {
        let paneCapture = """
        Implement this plan?
        1. Yes, implement this … Switch to Default and start coding.
        """
        let reason = CodexStatusReceiver.inferWaitingReason(
            from: ["type": "agent-turn-complete"],
            paneCapture: paneCapture
        )
        XCTAssertEqual(reason, .stop)
    }

    @MainActor
    func testReconcileMarksMissingSessionAsStoppedAfterGrace() {
        let receiver = CodexStatusReceiver.shared
        let cwd = "/tmp/codex-grace"
        let base = Date()
        let active = [CodexSession(pid: 1001, cwd: cwd)]

        receiver.reconcileActiveSessions(active, now: base)
        XCTAssertEqual(receiver.getStatus(for: cwd), .running)

        receiver.reconcileActiveSessions([], now: base.addingTimeInterval(1))
        XCTAssertEqual(receiver.getStatus(for: cwd), .running)

        receiver.reconcileActiveSessions([], now: base.addingTimeInterval(4))
        XCTAssertEqual(receiver.getStatus(for: cwd), .stopped)
    }

    @MainActor
    func testReconcilePrunesStoppedAfterRetention() {
        let receiver = CodexStatusReceiver.shared
        let cwd = "/tmp/codex-retention"
        let base = Date()
        let active = [CodexSession(pid: 1002, cwd: cwd)]

        receiver.reconcileActiveSessions(active, now: base)
        receiver.reconcileActiveSessions([], now: base.addingTimeInterval(4))
        XCTAssertEqual(receiver.getStatus(for: cwd), .stopped)

        receiver.reconcileActiveSessions([], now: base.addingTimeInterval(95))
        XCTAssertEqual(receiver.getStatus(for: cwd), .running)
    }

    @MainActor
    func testWithSyntheticStoppedSessionsAddsPlaceholder() {
        let receiver = CodexStatusReceiver.shared
        let cwd = "/tmp/codex-synthetic"
        let base = Date()
        let active = [CodexSession(pid: 1003, cwd: cwd)]

        receiver.reconcileActiveSessions(active, now: base)
        let sessionsAfterStop = receiver.withSyntheticStoppedSessions(
            activeSessions: [],
            now: base.addingTimeInterval(4)
        )
        let synthetic = sessionsAfterStop.first(where: { $0.cwd == cwd })
        XCTAssertNotNil(synthetic)
        XCTAssertEqual(synthetic?.pid, 0)
        XCTAssertEqual(receiver.getStatus(for: cwd), .stopped)
    }
}
