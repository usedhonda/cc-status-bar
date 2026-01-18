import Foundation

enum TmuxHelper {
    struct PaneInfo {
        let session: String
        let window: String
        let pane: String
    }

    /// TTY から tmux ペイン情報を取得
    static func getPaneInfo(for tty: String) -> PaneInfo? {
        let tmux = findTmux()
        let output = runCommand(tmux, ["list-panes", "-a",
            "-F", "#{pane_tty}|#{session_name}|#{window_index}|#{pane_index}"])

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|").map(String.init)
            if parts.count == 4 && parts[0] == tty {
                DebugLog.log("[TmuxHelper] Found pane: \(parts[1]):\(parts[2]).\(parts[3]) for TTY \(tty)")
                return PaneInfo(session: parts[1], window: parts[2], pane: parts[3])
            }
        }
        DebugLog.log("[TmuxHelper] No pane found for TTY \(tty)")
        return nil
    }

    /// ウィンドウとペインを選択（アクティブに）
    static func selectPane(_ info: PaneInfo) -> Bool {
        let tmux = findTmux()
        let windowTarget = "\(info.session):\(info.window)"
        let paneTarget = "\(info.session):\(info.window).\(info.pane)"

        // 1. ウィンドウを選択（タブ切り替え）
        _ = runCommand(tmux, ["select-window", "-t", windowTarget])

        // 2. ペインを選択
        _ = runCommand(tmux, ["select-pane", "-t", paneTarget])

        DebugLog.log("[TmuxHelper] Selected pane: \(paneTarget)")
        return true
    }

    /// tmux の絶対パスを取得
    private static func findTmux() -> String {
        let candidates = [
            "/opt/homebrew/bin/tmux",  // Apple Silicon
            "/usr/local/bin/tmux",     // Intel Mac
            "/usr/bin/tmux"            // System
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "tmux" // Fallback to PATH
    }

    /// Run a tmux command and return output
    static func runTmuxCommand(_ args: String...) -> String {
        let tmux = findTmux()
        return runCommand(tmux, args)
    }

    private static func runCommand(_ executable: String, _ args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(args)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            DebugLog.log("[TmuxHelper] Command failed: \(executable) \(args)")
            return ""
        }
    }
}
