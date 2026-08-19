import Foundation

enum SessionProducer: String, Equatable {
    case claude
    case codex
}

enum SessionStateSource: String, Equatable {
    case hook
    case webhook
    case paneGuess = "pane_guess"
}

enum SessionStateConfidence: String, Equatable {
    case observed
    case inferred
}

enum SessionLifecycle: String, Equatable {
    case working
    case awaitingInput = "awaiting_input"
    case permission
    case question
    case completed
    case stopped
}

struct SessionNormalizationInput {
    let producer: SessionProducer
    let status: String
    let waitingReason: String?
    let stateSource: SessionStateSource
    let syntheticStopped: Bool
    let observedAt: Date
    let lastActivityAt: Date?
}

struct NormalizedSessionState: Equatable {
    let lifecycle: SessionLifecycle
    let stateSource: SessionStateSource
    let confidence: SessionStateConfidence
    let observedAt: Date
    let lastActivityAt: Date?

    var fields: [String: Any] {
        var result: [String: Any] = [
            "lifecycle": lifecycle.rawValue,
            "state_source": stateSource.rawValue,
            "confidence": confidence.rawValue,
            "observed_at": Self.iso8601String(observedAt)
        ]
        if let lastActivityAt {
            result["last_activity_at"] = Self.iso8601String(lastActivityAt)
        }
        return result
    }

    private static func iso8601String(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

enum SessionStateNormalizer {
    /// Normalize producer observations without changing legacy status or attention fields.
    static func normalize(_ input: SessionNormalizationInput) -> NormalizedSessionState {
        let confidence: SessionStateConfidence = input.stateSource == .paneGuess ? .inferred : .observed
        let lifecycle: SessionLifecycle

        if input.syntheticStopped || input.status == "stopped" {
            lifecycle = .stopped
        } else if input.stateSource == .paneGuess {
            lifecycle = input.status == "running" ? .working : .awaitingInput
        } else if input.status == "running" {
            lifecycle = .working
        } else if input.producer == .codex,
                  input.status == "waiting_input",
                  input.waitingReason == "idle",
                  input.stateSource == .webhook {
            lifecycle = .completed
        } else if input.waitingReason == "permission_prompt" {
            lifecycle = .permission
        } else if input.waitingReason == "askUserQuestion" {
            lifecycle = .question
        } else {
            // Claude Stop and unknown factual waiting are both user-action states.
            lifecycle = .awaitingInput
        }

        return NormalizedSessionState(
            lifecycle: lifecycle,
            stateSource: input.stateSource,
            confidence: confidence,
            observedAt: input.observedAt,
            lastActivityAt: input.lastActivityAt
        )
    }
}
