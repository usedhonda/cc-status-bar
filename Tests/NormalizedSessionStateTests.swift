import XCTest
@testable import CCStatusBarLib

@MainActor
final class NormalizedSessionStateTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_769_900_645)
    private let activityAt = Date(timeIntervalSince1970: 1_769_900_600)

    func testClaudeStopNeverNormalizesAsCompleted() {
        let state = normalize(
            producer: .claude,
            status: "waiting_input",
            waitingReason: "stop",
            source: .hook
        )

        XCTAssertEqual(state.lifecycle, .awaitingInput)
        XCTAssertNotEqual(state.lifecycle, .completed)
        XCTAssertEqual(state.confidence, .observed)
    }

    func testCodexWebhookIdleNormalizesAsObservedCompleted() {
        let state = normalize(
            producer: .codex,
            status: "waiting_input",
            waitingReason: "idle",
            source: .webhook
        )

        XCTAssertEqual(state.lifecycle, .completed)
        XCTAssertEqual(state.stateSource, .webhook)
        XCTAssertEqual(state.confidence, .observed)
    }

    func testPaneGuessCannotNormalizeAsPermissionOrCompleted() {
        for reason in ["permission_prompt", "idle", "askUserQuestion"] {
            let state = normalize(
                producer: .codex,
                status: "waiting_input",
                waitingReason: reason,
                source: .paneGuess
            )

            XCTAssertEqual(state.lifecycle, .awaitingInput, "reason=\(reason)")
            XCTAssertEqual(state.stateSource, .paneGuess)
            XCTAssertEqual(state.confidence, .inferred)
        }
    }

    func testSyntheticStoppedNormalizesAsStopped() {
        let state = SessionStateNormalizer.normalize(SessionNormalizationInput(
            producer: .codex,
            status: "waiting_input",
            waitingReason: "idle",
            stateSource: .paneGuess,
            syntheticStopped: true,
            observedAt: observedAt,
            lastActivityAt: nil
        ))

        XCTAssertEqual(state.lifecycle, .stopped)
    }

    func testClaudeLegacyFieldsAndAttentionMappingRemainUnchanged() throws {
        let running = makeClaudePayload(status: .running)
        XCTAssertEqual(running["attention_level"] as? Int, 0)

        let waiting = makeClaudePayload(status: .waitingInput, waitingReason: .stop)
        XCTAssertEqual(waiting["attention_level"] as? Int, 1)

        let permission = makeClaudePayload(status: .waitingInput, waitingReason: .permissionPrompt)
        XCTAssertEqual(permission["attention_level"] as? Int, 2)

        var acknowledged = makeSession(status: .waitingInput, waitingReason: .permissionPrompt)
        acknowledged.isAcknowledged = true
        let acknowledgedPayload = WebSocketManager.makeClaudeSessionPayload(acknowledged, observedAt: observedAt)
        XCTAssertEqual(acknowledgedPayload["attention_level"] as? Int, 0)

        let decoded = try JSONDecoder().decode(LegacyClaudePayload.self, from: JSONSerialization.data(withJSONObject: permission))
        XCTAssertEqual(decoded.type, "claude_code")
        XCTAssertEqual(decoded.status, "waiting_input")
        XCTAssertEqual(decoded.attentionLevel, 2)
        XCTAssertEqual(decoded.sessionId, "claude-test")
    }

    func testLegacyCodexPayloadStillDecodesAndNewTimestampsAreISO8601() throws {
        let cwd = "/tmp/codex-contract"
        let receiver = CodexStatusReceiver.shared
        receiver.clearAll()
        let session = CodexSession(pid: 0, cwd: cwd, sessionId: "codex-test")
        let payload = WebSocketManager.shared.codexSessionToDict(session, observedAt: observedAt)

        let decoded = try JSONDecoder().decode(LegacyCodexPayload.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(decoded.type, "codex")
        XCTAssertEqual(decoded.attentionLevel, 0)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: payload["observed_at"] as? String ?? ""))
        XCTAssertNotNil(payload["confidence"] as? String)
        XCTAssertNotNil(payload["state_source"] as? String)
    }

    func testCodexWebhookIdlePayloadIsCompletedAndKeepsAttentionZero() throws {
        let cwd = "/tmp/codex-idle-contract"
        let receiver = CodexStatusReceiver.shared
        receiver.clearAll()
        let event: [String: Any] = [
            "type": "codex-stop",
            "cwd": cwd,
            "session_id": "codex-idle"
        ]
        receiver.handleEvent(try JSONSerialization.data(withJSONObject: event))

        let payload = WebSocketManager.shared.codexSessionToDict(
            CodexSession(pid: 0, cwd: cwd, sessionId: "codex-idle"),
            observedAt: observedAt
        )

        XCTAssertEqual(payload["lifecycle"] as? String, "completed")
        XCTAssertEqual(payload["state_source"] as? String, "webhook")
        XCTAssertEqual(payload["confidence"] as? String, "observed")
        XCTAssertEqual(payload["attention_level"] as? Int, 0)
        XCTAssertNotNil(payload["updated_at"] as? String)
        XCTAssertNotNil(payload["last_seen_at"] as? String)
    }

    func testPaneDerivedCodexPayloadIsInferred() {
        let cwd = "/tmp/codex-inferred"
        let receiver = CodexStatusReceiver.shared
        receiver.clearAll()
        let base = Date(timeIntervalSince1970: 1_769_900_000)
        receiver.reconcileActiveSessions([CodexSession(pid: 1001, cwd: cwd)], now: base)

        let payload = WebSocketManager.shared.codexSessionToDict(
            CodexSession(pid: 1001, cwd: cwd),
            observedAt: observedAt
        )

        XCTAssertEqual(payload["state_source"] as? String, "pane_guess")
        XCTAssertEqual(payload["confidence"] as? String, "inferred")
    }

    func testFullListAndIncrementalClaudePayloadsShareNormalizedFields() {
        let session = makeSession(status: .waitingInput, waitingReason: .stop)
        let fullListPayload = WebSocketManager.makeClaudeSessionPayload(session, observedAt: observedAt)
        let addedPayload = WebSocketManager.buildAddedSessionDict(session, observedAt: observedAt)
        let updatedPayload = WebSocketManager.buildUpdatedSessionDict(
            current: session,
            previous: makeSession(status: .running),
            observedAt: observedAt
        )

        for payload in [addedPayload, updatedPayload] {
            XCTAssertEqual(payload["lifecycle"] as? String, fullListPayload["lifecycle"] as? String)
            XCTAssertEqual(payload["state_source"] as? String, fullListPayload["state_source"] as? String)
            XCTAssertEqual(payload["confidence"] as? String, fullListPayload["confidence"] as? String)
            XCTAssertEqual(payload["observed_at"] as? String, fullListPayload["observed_at"] as? String)
            XCTAssertEqual(payload["last_activity_at"] as? String, fullListPayload["last_activity_at"] as? String)
        }
    }

    private func normalize(
        producer: SessionProducer,
        status: String,
        waitingReason: String,
        source: SessionStateSource
    ) -> NormalizedSessionState {
        SessionStateNormalizer.normalize(SessionNormalizationInput(
            producer: producer,
            status: status,
            waitingReason: waitingReason,
            stateSource: source,
            syntheticStopped: false,
            observedAt: observedAt,
            lastActivityAt: activityAt
        ))
    }

    private func makeSession(status: SessionStatus, waitingReason: WaitingReason? = nil) -> Session {
        Session(
            sessionId: "claude-test",
            cwd: "/tmp/claude-contract",
            tty: nil,
            status: status,
            createdAt: activityAt,
            updatedAt: activityAt,
            waitingReason: waitingReason
        )
    }

    private func makeClaudePayload(status: SessionStatus, waitingReason: WaitingReason? = nil) -> [String: Any] {
        WebSocketManager.makeClaudeSessionPayload(
            makeSession(status: status, waitingReason: waitingReason),
            observedAt: observedAt
        )
    }
}

private struct LegacyClaudePayload: Decodable {
    let type: String
    let id: String
    let sessionId: String
    let project: String
    let cwd: String
    let status: String
    let updatedAt: String
    let isAcknowledged: Bool
    let attentionLevel: Int
    let terminal: String

    enum CodingKeys: String, CodingKey {
        case type, id, project, cwd, status, updatedAt = "updated_at"
        case sessionId = "session_id"
        case isAcknowledged = "is_acknowledged"
        case attentionLevel = "attention_level"
        case terminal
    }
}

private struct LegacyCodexPayload: Decodable {
    let type: String
    let id: String
    let pid: Int
    let project: String
    let cwd: String
    let status: String
    let startedAt: String
    let attentionLevel: Int
    let terminal: String

    enum CodingKeys: String, CodingKey {
        case type, id, pid, project, cwd, status, terminal
        case startedAt = "started_at"
        case attentionLevel = "attention_level"
    }
}
