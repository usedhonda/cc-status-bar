import ArgumentParser
import Foundation

/// CLI command for external tools to emit CCSB Events Protocol events
public struct EmitCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "emit",
        abstract: "Emit a CCSB Events Protocol event",
        discussion: """
        External tools can use this command to integrate with CC Status Bar.

        Example usage:
          CCStatusBar emit --tool aider --event session.start --session-id abc123 --cwd /path/to/project
          CCStatusBar emit --tool terraform --event session.waiting --session-id xyz --summary "Waiting for approval"

        Or pipe a JSON event via stdin:
          echo '{"proto":"ccsb.v1","event":"session.waiting",...}' | CCStatusBar emit --json
        """
    )

    @Option(name: .long, help: "Tool name (e.g., aider, terraform)")
    var tool: String?

    @Option(name: .long, help: "Tool version")
    var toolVersion: String?

    @Option(name: .long, help: "Event type: session.start, session.stop, session.waiting, session.running, artifact.link")
    var event: String?

    @Option(name: .long, help: "Session ID")
    var sessionId: String?

    @Option(name: .long, help: "Current working directory")
    var cwd: String?

    @Option(name: .long, help: "TTY device path")
    var tty: String?

    @Option(name: .long, help: "Attention level: green, yellow, red, none")
    var attention: String?

    @Option(name: .long, help: "Human-readable summary")
    var summary: String?

    @Flag(name: .long, help: "Read JSON event from stdin")
    var json: Bool = false

    public init() {}

    public func run() throws {
        let ccsbEvent: CCSBEvent

        if json {
            // Read JSON from stdin
            let stdinData = FileHandle.standardInput.readDataToEndOfFile()
            guard !stdinData.isEmpty else {
                throw ValidationError("No JSON input received from stdin")
            }

            guard let event = CCSBEvent.from(data: stdinData) else {
                throw ValidationError("Invalid CCSB JSON format")
            }
            ccsbEvent = event
        } else {
            // Build event from options
            guard let toolName = tool else {
                throw ValidationError("--tool is required")
            }
            guard let eventString = event else {
                throw ValidationError("--event is required")
            }
            guard let eventType = CCSBEventType(rawValue: eventString) else {
                throw ValidationError("Invalid event type: \(eventString). Must be one of: session.start, session.stop, session.waiting, session.running, artifact.link")
            }
            guard let sid = sessionId else {
                throw ValidationError("--session-id is required")
            }

            let attentionLevel: CCSBAttentionLevel
            if let attn = attention {
                guard let level = CCSBAttentionLevel(rawValue: attn) else {
                    throw ValidationError("Invalid attention level: \(attn). Must be one of: green, yellow, red, none")
                }
                attentionLevel = level
            } else {
                // Default attention based on event type
                switch eventType {
                case .sessionStart, .sessionRunning:
                    attentionLevel = .green
                case .sessionWaiting:
                    attentionLevel = .yellow
                case .sessionStop:
                    attentionLevel = .none
                case .artifactLink:
                    attentionLevel = .green
                }
            }

            let resolvedTty = tty ?? TtyDetector.getTty()
            let resolvedCwd = cwd ?? FileManager.default.currentDirectoryPath

            ccsbEvent = CCSBEvent(
                event: eventType,
                sessionId: sid,
                tool: CCSBToolInfo(name: toolName, version: toolVersion),
                cwd: resolvedCwd,
                tty: resolvedTty,
                attention: CCSBAttentionInfo(level: attentionLevel, reason: summary),
                summary: summary
            )
        }

        // Process the event
        _ = SessionStore.shared.updateSession(ccsbEvent: ccsbEvent)

        // Output the processed event for debugging
        if let jsonOutput = ccsbEvent.toJSON() {
            DebugLog.log("[EmitCommand] Processed event: \(jsonOutput)")
        }
    }
}
