import Foundation

/// Helper for TTY-based terminal title manipulation via OSC escape sequences
enum TtyHelper {
    /// Set terminal title via OSC escape sequence
    /// Works for Ghostty, iTerm2, Terminal.app (non-tmux sessions)
    /// - Parameters:
    ///   - title: The title to set
    ///   - tty: The TTY device path (e.g., "/dev/ttys023")
    /// - Returns: true if successful
    @discardableResult
    static func setTitle(_ title: String, tty: String) -> Bool {
        // OSC 0: Set window title and icon name
        // ESC ] 0 ; <title> BEL
        let seq = "\u{001B}]0;\(title)\u{0007}"

        let fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            DebugLog.log("[TtyHelper] Failed to open \(tty): errno=\(errno)")
            return false
        }
        defer { close(fd) }

        guard let data = seq.data(using: .utf8) else {
            DebugLog.log("[TtyHelper] Failed to encode title")
            return false
        }

        let written = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }

        if written == data.count {
            DebugLog.log("[TtyHelper] Set title '\(title)' for \(tty)")
            return true
        }

        DebugLog.log("[TtyHelper] Partial write: \(written)/\(data.count) bytes")
        return false
    }

    /// Generate CCStatusBar title format
    /// Format: "[CC] projectName • ttysNNN"
    /// - Parameters:
    ///   - project: Project name (directory name)
    ///   - tty: TTY device path (e.g., "/dev/ttys023")
    /// - Returns: Formatted title string
    static func ccTitle(project: String, tty: String) -> String {
        let shortTty = tty.replacingOccurrences(of: "/dev/", with: "")
        return "[CC] \(project) • \(shortTty)"
    }
}
