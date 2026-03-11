import XCTest
@testable import CCStatusBarLib

final class CodexStatusReceiverTests: XCTestCase {
    private let defaults = AppSettings.userDefaultsStore
    private var originalAlertsEnabled: Bool?
    private var originalAlertCommand: String?

    @MainActor
    override func setUp() {
        super.setUp()
        CodexStatusReceiver.shared.clearAll()
        originalAlertsEnabled = defaults.object(forKey: "alertsEnabled") as? Bool
        originalAlertCommand = defaults.string(forKey: "alertCommand")
        defaults.set(false, forKey: "alertsEnabled")
        defaults.removeObject(forKey: "alertCommand")
    }

    override func tearDown() {
        if let originalAlertsEnabled {
            defaults.set(originalAlertsEnabled, forKey: "alertsEnabled")
        } else {
            defaults.removeObject(forKey: "alertsEnabled")
        }

        if let originalAlertCommand {
            defaults.set(originalAlertCommand, forKey: "alertCommand")
        } else {
            defaults.removeObject(forKey: "alertCommand")
        }

        super.tearDown()
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
    func testInferWaitingReasonDetectsQuestionPromptAsYellow() {
        let paneCapture = """
        Question 1/1 (1 unanswered)
        1. Start now
        2. Later

        tab to add notes
        enter to submit answer
        """
        let reason = CodexStatusReceiver.inferWaitingReason(
            from: ["type": "agent-turn-complete"],
            paneCapture: paneCapture
        )
        XCTAssertEqual(reason, .stop)
        XCTAssertTrue(CodexStatusReceiver.isLikelyWaitingScreen(paneCapture, waitingReason: .stop))
    }

    @MainActor
    func testShouldNotRecoverWhileQuestionPromptIsStillVisible() {
        let previousCapture = """
        Question 1/1 (1 unanswered)
        1. Start now
        2. Later

        enter to submit answer
        """
        let currentCapture = """
        Question 1/1 (1 unanswered)
        > 1. Start now
        2. Later

        tab to add notes
        enter to submit answer
        """

        XCTAssertFalse(
            CodexStatusReceiver.shouldRecoverToRunning(
                previousPaneHash: CodexStatusReceiver.hashPaneTail(previousCapture),
                currentPaneCapture: currentCapture,
                waitingReason: .stop
            )
        )
    }

    @MainActor
    func testShouldRecoverAfterQuestionMarkersDisappear() {
        let previousCapture = """
        Question 1/1 (1 unanswered)
        1. Start now
        2. Later

        enter to submit answer
        """
        let currentCapture = """
        Applied startup migration.
        Continuing with implementation...
        """

        XCTAssertTrue(
            CodexStatusReceiver.shouldRecoverToRunning(
                previousPaneHash: CodexStatusReceiver.hashPaneTail(previousCapture),
                currentPaneCapture: currentCapture,
                waitingReason: .stop
            )
        )
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

    @MainActor
    func testHandleTokenUsageEvent() throws {
        let receiver = CodexStatusReceiver.shared
        let cwd = "/tmp/codex-token"
        let event: [String: Any] = [
            "type": "codex-token-usage",
            "cwd": cwd,
            "token_usage": [
                "input_tokens": 1000,
                "output_tokens": 200,
                "total_tokens": 1200
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: event)
        receiver.handleEvent(data)

        let usage = receiver.getTokenUsage(for: cwd)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.inputTokens, 1000)
        XCTAssertEqual(usage?.outputTokens, 200)
        XCTAssertEqual(usage?.totalTokens, 1200)
        XCTAssertEqual(usage?.formattedTotal, "1.2K tokens")
    }

    @MainActor
    func testHandleSessionStartEvent() throws {
        let receiver = CodexStatusReceiver.shared
        let cwd = "/tmp/codex-start"
        let event: [String: Any] = [
            "type": "codex-session-start",
            "cwd": cwd,
            "thread-id": "thread-start-1"
        ]
        let data = try JSONSerialization.data(withJSONObject: event)
        receiver.handleEvent(data)

        XCTAssertEqual(receiver.getStatus(for: cwd), .running)
        let sessionStatus = receiver.getSessionStatus(for: cwd)
        XCTAssertEqual(sessionStatus?.threadId, "thread-start-1")
    }

    @MainActor
    func testUnknownEventTypeIsIgnored() throws {
        let receiver = CodexStatusReceiver.shared
        let event: [String: Any] = [
            "type": "codex-unknown-event",
            "cwd": "/tmp/unknown"
        ]
        let data = try JSONSerialization.data(withJSONObject: event)
        receiver.handleEvent(data)
        // Should not crash and unknown cwd should have no status entry
        XCTAssertEqual(receiver.getStatus(for: "/tmp/unknown"), .running)  // default
        XCTAssertNil(receiver.getSessionStatus(for: "/tmp/unknown"))
    }

    @MainActor
    func testTokenUsageClearedOnRemoveStatus() throws {
        let receiver = CodexStatusReceiver.shared
        let cwd = "/tmp/codex-token-clear"
        let event: [String: Any] = [
            "type": "codex-token-usage",
            "cwd": cwd,
            "token_usage": ["input_tokens": 500, "output_tokens": 100, "total_tokens": 600]
        ]
        let data = try JSONSerialization.data(withJSONObject: event)
        receiver.handleEvent(data)
        XCTAssertNotNil(receiver.getTokenUsage(for: cwd))

        receiver.removeStatus(for: cwd)
        XCTAssertNil(receiver.getTokenUsage(for: cwd))
    }

    @MainActor
    func testWithSyntheticStoppedSessionsAddsWaitingPlaceholder() throws {
        let receiver = CodexStatusReceiver.shared
        let cwd = "/tmp/codex-waiting-placeholder"
        let event: [String: Any] = [
            "type": "agent-turn-complete",
            "cwd": cwd,
            "thread-id": "thread-123"
        ]
        let data = try JSONSerialization.data(withJSONObject: event)

        receiver.handleEvent(data)

        let sessions = receiver.withSyntheticStoppedSessions(activeSessions: [])
        let synthetic = sessions.first(where: { $0.cwd == cwd })
        XCTAssertNotNil(synthetic)
        XCTAssertEqual(synthetic?.pid, 0)
        XCTAssertEqual(receiver.getStatus(for: cwd), .waitingInput)
        XCTAssertEqual(receiver.getWaitingReason(for: cwd), .stop)
    }
}
