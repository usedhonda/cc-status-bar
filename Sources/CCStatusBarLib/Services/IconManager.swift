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

    /// Get icon as base64 PNG data for Stream Deck
    /// - Parameters:
    ///   - env: Focus environment
    ///   - size: Icon size (default 40x40)
    /// - Returns: Base64 encoded PNG string or nil
    func iconBase64(for env: FocusEnvironment, size: CGFloat = 40) -> String? {
        guard let image = icon(for: env, size: size) else { return nil }

        // Create a single bitmap at the specified size (avoid multi-resolution TIFF)
        let intSize = Int(size)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: intSize,
            pixelsHigh: intSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData.base64EncodedString()
    }

    /// Get icon with tab number badge for a FocusEnvironment
    /// - Parameters:
    ///   - env: Focus environment
    ///   - size: Icon size (default 16x16)
    /// - Returns: Application icon with badge (for Ghostty tabs) or regular icon
    func iconWithBadge(for env: FocusEnvironment, size: CGFloat = 16) -> NSImage? {
        guard let baseIcon = icon(for: env, size: size) else { return nil }

        // Only add badge for Ghostty or iTerm2 with tab index
        let tabIndex: Int
        switch env {
        case .ghostty(_, let idx?, _):
            tabIndex = idx
        case .iterm2(_, let idx?, _):
            tabIndex = idx
        default:
            return baseIcon
        }

        // 1-based display (tab 0 -> display "⌘1")
        let badgeText = "⌘\(tabIndex + 1)"

        // Create new image with badge
        let newImage = NSImage(size: baseIcon.size)
        newImage.lockFocus()

        // Draw base icon
        baseIcon.draw(at: .zero, from: .zero, operation: .copy, fraction: 1.0)

        // Badge configuration (bottom-right, rounded rectangle)
        let badgeHeight = size * 0.32
        let badgeWidth = badgeHeight * 1.65  // Wider for ⌘ symbol
        let cornerRadius = badgeHeight * 0.35
        // Position at bottom-right
        let badgeRect = NSRect(
            x: size - badgeWidth,
            y: 0,
            width: badgeWidth,
            height: badgeHeight
        )

        // Draw badge background (white rounded rectangle with border)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.white.setFill()
        badgePath.fill()
        NSColor.systemGray.setStroke()
        badgePath.lineWidth = 0.5
        badgePath.stroke()

        // Draw badge text
        let fontSize = badgeHeight * 0.88
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.darkGray
        ]
        let textSize = badgeText.size(withAttributes: textAttrs)
        let textPoint = NSPoint(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2
        )
        badgeText.draw(at: textPoint, withAttributes: textAttrs)

        newImage.unlockFocus()
        return newImage
    }

    // MARK: - Private

    private func fetchIcon(for bundleID: String, size: CGFloat) -> NSImage? {
        // Method 1: NSWorkspace.urlForApplication (preferred, more reliable)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            return resizedIcon(icon, to: size)
        }

        // Method 2: LSCopyApplicationURLsForBundleIdentifier (fallback)
        var outError: Unmanaged<CFError>?
        if let appURLs = LSCopyApplicationURLsForBundleIdentifier(
            bundleID as CFString,
            &outError
        )?.takeRetainedValue() as? [URL],
           let appURL = appURLs.first {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            return resizedIcon(icon, to: size)
        }

        return nil
    }

    /// Resize an image to the specified size (actual pixel resize, not just logical size)
    private func resizedIcon(_ image: NSImage, to size: CGFloat) -> NSImage {
        let newSize = NSSize(width: size, height: size)
        let resizedImage = NSImage(size: newSize)
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        resizedImage.unlockFocus()
        return resizedImage
    }
}
