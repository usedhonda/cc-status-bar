import Foundation

/// Terminal adapter capabilities
struct TerminalCapabilities: OptionSet {
    let rawValue: Int

    /// Can focus a session by name (tab title search)
    static let focusBySession = TerminalCapabilities(rawValue: 1 << 0)

    /// Can focus a session by TTY (for tmux integration)
    static let focusByTTY = TerminalCapabilities(rawValue: 1 << 1)

    /// Can only activate the app (bring to front)
    static let activateOnly = TerminalCapabilities(rawValue: 1 << 2)
}

/// Protocol for terminal adapters
/// Enables support for multiple terminal emulators (Ghostty, iTerm2, etc.)
protocol TerminalAdapter {
    /// Display name of the terminal
    var name: String { get }

    /// Bundle identifier for the terminal app
    var bundleIdentifier: String { get }

    /// Capabilities supported by this terminal
    var capabilities: TerminalCapabilities { get }

    /// Whether the terminal app is currently running
    var isRunning: Bool { get }

    /// Focus a session by name (tab title search)
    /// - Parameter sessionName: The name to search for in tab titles
    /// - Returns: true if successfully focused
    func focusSession(_ sessionName: String) -> Bool

    /// Focus a session by TTY device path
    /// - Parameter tty: The TTY device path (e.g., "/dev/ttys002")
    /// - Returns: true if successfully focused
    func focusByTTY(_ tty: String) -> Bool

    /// Activate the terminal app (bring to front)
    /// - Returns: true if successfully activated
    func activate() -> Bool
}

// MARK: - Default implementations

extension TerminalAdapter {
    /// Default implementation: TTY-based focus not supported
    func focusByTTY(_ tty: String) -> Bool {
        false
    }
}

/// Registry of available terminal adapters
enum TerminalRegistry {
    /// Available adapters in priority order (iTerm2 first for TTY-based search)
    static let adapters: [TerminalAdapter] = [
        ITerm2Adapter(),
        GhosttyAdapter()
        // Future: TerminalAppAdapter()
    ]

    /// Find the first running terminal
    static func findRunningTerminal() -> TerminalAdapter? {
        adapters.first { $0.isRunning }
    }

    /// Find a specific terminal by name
    static func findTerminal(named name: String) -> TerminalAdapter? {
        adapters.first { $0.name.lowercased() == name.lowercased() }
    }
}
