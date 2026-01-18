import Foundation

enum TtyDetector {
    private static let maxAncestorDepth = 5

    static func getTty() -> String? {
        // 1. Try ps-based ancestor lookup
        if let tty = getTtyFromAncestors() {
            return tty
        }
        // 2. Try tmux fallback
        if let tty = getTmuxPaneTty() {
            return tty
        }
        return nil
    }

    private static func getTtyFromAncestors() -> String? {
        var currentPid = getppid()

        for _ in 0..<maxAncestorDepth {
            if let ttyName = runCommand("ps", ["-o", "tty=", "-p", String(currentPid)]) {
                let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != "??" {
                    return "/dev/\(trimmed)"
                }
            }

            guard let ppidStr = runCommand("ps", ["-o", "ppid=", "-p", String(currentPid)]),
                  let ppid = Int32(ppidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ppid > 0 else {
                break
            }
            currentPid = ppid
        }

        return nil
    }

    private static func getTmuxPaneTty() -> String? {
        guard ProcessInfo.processInfo.environment["TMUX"] != nil else {
            return nil
        }

        if let tty = runCommand("tmux", ["display-message", "-p", "#{pane_tty}"]) {
            let trimmed = tty.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("/dev/") {
                return trimmed
            }
        }
        return nil
    }

    private static func runCommand(_ command: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
