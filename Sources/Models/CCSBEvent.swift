import Foundation

/// CCSB Events Protocol v1
/// A standardized event format for terminal session monitoring.
/// Designed to support multiple CLI tools (Claude Code, aider, etc.)

// MARK: - Protocol Version

enum CCSBProtocolVersion: String, Codable {
    case v1 = "ccsb.v1"
}

// MARK: - Event Types

enum CCSBEventType: String, Codable {
    case sessionStart = "session.start"
    case sessionStop = "session.stop"
    case sessionWaiting = "session.waiting"
    case sessionRunning = "session.running"
    case artifactLink = "artifact.link"
}

// MARK: - Attention Level

enum CCSBAttentionLevel: String, Codable {
    case green   // Running, no action needed
    case yellow  // Waiting for input
    case red     // Error or critical
    case none    // No attention needed (stopped)
}

// MARK: - Tool Info

struct CCSBToolInfo: Codable {
    let name: String
    let version: String?

    init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

// MARK: - Attention Info

struct CCSBAttentionInfo: Codable {
    let level: CCSBAttentionLevel
    let reason: String?

    init(level: CCSBAttentionLevel, reason: String? = nil) {
        self.level = level
        self.reason = reason
    }
}

// MARK: - Artifact Info (for artifact.link events)

struct CCSBArtifactInfo: Codable {
    let type: String      // "file", "url", "pr", etc.
    let path: String?     // File path or URL
    let title: String?    // Display title

    init(type: String, path: String? = nil, title: String? = nil) {
        self.type = type
        self.path = path
        self.title = title
    }
}

// MARK: - CCSB Event

struct CCSBEvent: Codable {
    let proto: CCSBProtocolVersion
    let event: CCSBEventType
    let sessionId: String
    let timestamp: Date

    // Tool information
    let tool: CCSBToolInfo

    // Session context
    let cwd: String?
    let tty: String?

    // Attention level
    let attention: CCSBAttentionInfo

    // Human-readable summary
    let summary: String?

    // Optional artifact (for artifact.link events)
    let artifact: CCSBArtifactInfo?

    enum CodingKeys: String, CodingKey {
        case proto
        case event
        case sessionId = "session_id"
        case timestamp
        case tool
        case cwd
        case tty
        case attention
        case summary
        case artifact
    }

    init(
        event: CCSBEventType,
        sessionId: String,
        tool: CCSBToolInfo,
        cwd: String? = nil,
        tty: String? = nil,
        attention: CCSBAttentionInfo,
        summary: String? = nil,
        artifact: CCSBArtifactInfo? = nil
    ) {
        self.proto = .v1
        self.event = event
        self.sessionId = sessionId
        self.timestamp = Date()
        self.tool = tool
        self.cwd = cwd
        self.tty = tty
        self.attention = attention
        self.summary = summary
        self.artifact = artifact
    }
}

// MARK: - Factory Methods

extension CCSBEvent {
    /// Create event from Claude Code hook event
    static func from(hookEvent: HookEvent) -> CCSBEvent {
        let eventType: CCSBEventType
        let attention: CCSBAttentionInfo
        let summary: String

        switch hookEvent.hookEventName {
        case .sessionStart:
            eventType = .sessionStart
            attention = CCSBAttentionInfo(level: .green, reason: "Session started")
            summary = "Session started"

        case .sessionEnd, .stop:
            eventType = .sessionStop
            attention = CCSBAttentionInfo(level: .none, reason: "Session ended")
            summary = "Session stopped"

        case .notification:
            eventType = .sessionWaiting
            let reason = hookEvent.notificationType ?? "Waiting for input"
            attention = CCSBAttentionInfo(level: .yellow, reason: reason)
            summary = "Waiting for input"

        case .userPromptSubmit:
            eventType = .sessionRunning
            attention = CCSBAttentionInfo(level: .green, reason: "User submitted prompt")
            summary = "Running"

        case .preToolUse, .postToolUse:
            eventType = .sessionRunning
            attention = CCSBAttentionInfo(level: .green, reason: "Tool execution")
            summary = "Running"
        }

        return CCSBEvent(
            event: eventType,
            sessionId: hookEvent.sessionId,
            tool: CCSBToolInfo(name: "claude"),
            cwd: hookEvent.cwd,
            tty: hookEvent.tty,
            attention: attention,
            summary: summary
        )
    }

    /// Convert to internal Session model
    func toSession(existingSession: Session? = nil) -> Session {
        let status: SessionStatus
        switch event {
        case .sessionStart, .sessionRunning:
            status = .running
        case .sessionWaiting:
            status = .waitingInput
        case .sessionStop:
            status = .stopped
        case .artifactLink:
            status = existingSession?.status ?? .running
        }

        return Session(
            sessionId: sessionId,
            cwd: cwd ?? existingSession?.cwd ?? "",
            tty: tty ?? existingSession?.tty,
            status: status,
            createdAt: existingSession?.createdAt ?? timestamp,
            updatedAt: timestamp,
            ghosttyTabIndex: existingSession?.ghosttyTabIndex
        )
    }
}

// MARK: - JSON Encoding

extension CCSBEvent {
    /// Encode to JSON with ISO8601 date format
    func toJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode from JSON
    static func from(json: String) -> CCSBEvent? {
        guard let data = json.data(using: .utf8) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try? decoder.decode(CCSBEvent.self, from: data)
    }

    /// Decode from JSON Data
    static func from(data: Data) -> CCSBEvent? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try? decoder.decode(CCSBEvent.self, from: data)
    }
}
