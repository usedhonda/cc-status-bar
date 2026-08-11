import ArgumentParser
import Foundation

public struct StatuslineCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "statusline",
        abstract: "Receive Claude Code statusline updates"
    )

    public init() {}

    public func run() throws {
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        guard !stdinData.isEmpty else { return }

        do {
            let update = try JSONDecoder().decode(StatuslineUpdate.self, from: stdinData)
            SessionStore.shared.updateStatusline(update)
        } catch {
            DebugLog.log("[StatuslineCommand] Ignored invalid statusline input: \(error.localizedDescription)")
        }
    }
}
