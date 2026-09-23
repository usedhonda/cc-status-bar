import ArgumentParser
import Foundation

public struct PokeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "poke",
        abstract: "Keep a session's prompt cache warm with one keep-alive turn",
        discussion: """
        Sends a fixed keep-alive prompt into an idle Claude Code session's tmux pane,
        which reads the prompt cache and resets its TTL. Refuses sessions waiting on a
        permission prompt or question, running a tool, or with text in the prompt.
        Works without the app running.
        """
    )

    @Option(name: .long, help: "Claude Code session id")
    var session: String?

    @Option(name: .long, help: "Terminal of the session, e.g. /dev/ttys012")
    var tty: String?

    @Flag(name: .long, help: "Print each session's cache state as JSON instead of poking")
    var list = false

    @Flag(name: .long, help: "Run every safety check and report whether it would send, without sending")
    var dryRun = false

    public init() {}

    public func run() throws {
        let sessions = SessionStore.shared.getSessions()
        if list {
            print(String(decoding: KeepWarmAPI.json(KeepWarmAPI.statusPayload(sessions)), as: UTF8.self))
            return
        }
        guard session != nil || tty != nil else {
            throw ValidationError("Pass --session <id>, --tty <tty>, or --list")
        }
        if dryRun {
            guard let target = KeepWarmAPI.findSession(sessions, sessionId: session, tty: tty) else {
                print(String(decoding: KeepWarmAPI.json(["result": "skipped", "reason": "session-not-found"]), as: UTF8.self))
                throw ExitCode(1)
            }
            let reason = CachePoker.pokeCheck(target).reason
            var payload: [String: Any] = ["result": reason == nil ? "would-send" : "skipped", "session_id": target.sessionId]
            payload["reason"] = reason
            print(String(decoding: KeepWarmAPI.json(payload), as: UTF8.self))
            return
        }
        var body: [String: Any] = [:]
        body["session_id"] = session
        body["tty"] = tty
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let result = KeepWarmAPI.poke(body: data, sessions: sessions)
        print(String(decoding: KeepWarmAPI.json(result.payload), as: UTF8.self))
        if result.payload["result"] as? String != "sent" {
            throw ExitCode(1)
        }
    }
}
