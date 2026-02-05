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
        return imageToBase64(image, size: size)
    }

    /// Get terminal icon as base64 PNG data by terminal name
    /// - Parameters:
    ///   - terminal: Terminal identifier (ghostty, iTerm.app, apple_terminal)
    ///   - size: Icon size (default 40x40)
    /// - Returns: Base64 encoded PNG string or nil
    func terminalIconBase64(for terminal: String, size: CGFloat = 40) -> String? {
        guard let image = terminalIcon(for: terminal, size: size) else { return nil }
        return imageToBase64(image, size: size)
    }

    /// Convert NSImage to base64 PNG string
    private func imageToBase64(_ image: NSImage, size: CGFloat) -> String? {

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

    /// Get icon with badge for a FocusEnvironment
    /// - Parameters:
    ///   - env: Focus environment
    ///   - size: Icon size (default 16x16)
    ///   - badgeText: Custom badge text (e.g., "CC", "Codex"). If nil, falls back to tab number badge.
    /// - Returns: Application icon with badge or regular icon
    func iconWithBadge(for env: FocusEnvironment, size: CGFloat = 16, badgeText: String? = nil) -> NSImage? {
        guard let baseIcon = icon(for: env, size: size) else { return nil }

        // Determine badge text: explicit badgeText > tab number > no badge
        let resolvedBadgeText: String
        if let badgeText = badgeText {
            resolvedBadgeText = badgeText
        } else {
            // Fallback to tab number badge for Ghostty/iTerm2
            switch env {
            case .ghostty(_, let idx?, _):
                resolvedBadgeText = "⌘\(idx + 1)"
            case .iterm2(_, let idx?, _):
                resolvedBadgeText = "⌘\(idx + 1)"
            default:
                return baseIcon
            }
        }

        // Create new image with badge
        let newImage = NSImage(size: baseIcon.size)
        newImage.lockFocus()

        // Draw base icon
        baseIcon.draw(at: .zero, from: .zero, operation: .copy, fraction: 1.0)

        // Badge configuration (bottom-right, capsule)
        let badgeHeight = size * 0.32
        let fontSize = badgeHeight * 0.75
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = resolvedBadgeText.size(withAttributes: textAttrs)
        let horizontalPadding = badgeHeight * 0.4
        let badgeWidth = max(badgeHeight * 1.65, textSize.width + horizontalPadding)
        let cornerRadius = badgeHeight * 0.5
        let badgeRect = NSRect(
            x: size - badgeWidth,
            y: 0,
            width: badgeWidth,
            height: badgeHeight
        )

        // Draw shadow
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2.0
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.4)
        shadow.set()

        // Draw badge background (semi-transparent dark capsule)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(calibratedWhite: 0.15, alpha: 0.85).setFill()
        badgePath.fill()

        // Remove shadow for border and text
        NSShadow().set()

        // Type-specific border color
        let borderColor: NSColor
        if resolvedBadgeText == "CC" {
            borderColor = NSColor(calibratedRed: 0.3, green: 0.6, blue: 0.9, alpha: 0.8)
        } else if resolvedBadgeText == "Cdx" {
            borderColor = NSColor(calibratedRed: 0.7, green: 0.4, blue: 0.9, alpha: 0.8)
        } else {
            borderColor = NSColor(calibratedWhite: 0.5, alpha: 0.6)
        }
        borderColor.setStroke()
        badgePath.lineWidth = 1.0
        badgePath.stroke()

        // Draw badge text (centered)
        let textPoint = NSPoint(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2
        )
        resolvedBadgeText.draw(at: textPoint, withAttributes: textAttrs)

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
