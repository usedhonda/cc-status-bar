import AppKit

/// Manages application icon retrieval with caching
final class IconManager {
    static let shared = IconManager()

    private var cache: [String: NSImage] = [:]

    /// Known terminal bundle IDs
    private let terminalBundleIDs: [String: String] = [
        "ghostty": "com.mitchellh.ghostty",
        "iterm.app": "com.googlecode.iterm2",
        "apple_terminal": "com.apple.Terminal"
    ]

    private init() {}

    // MARK: - Public API

    /// Get icon for a bundle ID
    /// - Parameters:
    ///   - bundleID: Application bundle identifier
    ///   - size: Icon size (default 16x16)
    /// - Returns: Application icon or nil if not found
    func icon(for bundleID: String, size: CGFloat = 16) -> NSImage? {
        if let cached = cache[bundleID] {
            return cached
        }

        guard let icon = fetchIcon(for: bundleID, size: size) else {
            return nil
        }

        cache[bundleID] = icon
        return icon
    }

    /// Get icon for a terminal type
    /// - Parameters:
    ///   - terminal: Terminal identifier (ghostty, iterm.app, apple_terminal)
    ///   - size: Icon size (default 16x16)
    /// - Returns: Terminal icon or nil if not found
    func terminalIcon(for terminal: String, size: CGFloat = 16) -> NSImage? {
        guard let bundleID = terminalBundleIDs[terminal.lowercased()] else {
            return nil
        }
        return icon(for: bundleID, size: size)
    }

    /// Get icon for a FocusEnvironment
    /// - Parameters:
    ///   - env: Focus environment
    ///   - size: Icon size (default 16x16)
    /// - Returns: Application icon or nil
    func icon(for env: FocusEnvironment, size: CGFloat = 16) -> NSImage? {
        switch env {
        case .editor(let bundleID, _, _, _):
            return icon(for: bundleID, size: size)
        case .ghostty:
            return terminalIcon(for: "ghostty", size: size)
        case .iterm2:
            return terminalIcon(for: "iterm.app", size: size)
        case .terminal:
            return terminalIcon(for: "apple_terminal", size: size)
        case .tmuxOnly, .unknown:
            return nil
        }
    }

    // MARK: - Private

    private func fetchIcon(for bundleID: String, size: CGFloat) -> NSImage? {
        // Use LSCopyApplicationURLsForBundleIdentifier to find app path
        var outError: Unmanaged<CFError>?
        guard let appURLs = LSCopyApplicationURLsForBundleIdentifier(
            bundleID as CFString,
            &outError
        )?.takeRetainedValue() as? [URL],
              let appURL = appURLs.first else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}
