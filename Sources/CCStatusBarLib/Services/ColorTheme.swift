import AppKit

/// Color theme presets for menu bar status display
public enum ColorTheme: String, CaseIterable {
    case vibrant   // Original bright system colors
    case muted     // Softer colors (especially yellow -> tan)
    case warm      // Orange-tinted palette
    case cool      // Cyan/teal palette

    public var displayName: String {
        switch self {
        case .vibrant: return "Vibrant"
        case .muted: return "Muted"
        case .warm: return "Warm"
        case .cool: return "Cool"
        }
    }

    // MARK: - Status Colors

    /// Color for permission_prompt (red) status
    public var redColor: NSColor {
        switch self {
        case .vibrant:
            return .systemRed
        case .muted:
            return NSColor(red: 0.898, green: 0.451, blue: 0.451, alpha: 1.0)  // Salmon #E57373
        case .warm:
            return NSColor(red: 1.0, green: 0.439, blue: 0.263, alpha: 1.0)    // Coral #FF7043
        case .cool:
            return NSColor(red: 0.957, green: 0.561, blue: 0.694, alpha: 1.0)  // Pink #F48FB1
        }
    }

    /// Color for waiting_input (yellow) status
    public var yellowColor: NSColor {
        switch self {
        case .vibrant:
            return .systemYellow
        case .muted:
            return NSColor(red: 0.831, green: 0.647, blue: 0.455, alpha: 1.0)  // Tan #D4A574
        case .warm:
            return NSColor(red: 1.0, green: 0.718, blue: 0.302, alpha: 1.0)    // Orange #FFB74D
        case .cool:
            return NSColor(red: 0.302, green: 0.816, blue: 0.882, alpha: 1.0)  // Cyan #4DD0E1
        }
    }

    /// Color for running (green) status
    public var greenColor: NSColor {
        switch self {
        case .vibrant:
            return .systemGreen
        case .muted:
            return NSColor(red: 0.506, green: 0.780, blue: 0.518, alpha: 1.0)  // Sage #81C784
        case .warm:
            return NSColor(red: 0.682, green: 0.835, blue: 0.506, alpha: 1.0)  // Lime #AED581
        case .cool:
            return NSColor(red: 0.302, green: 0.714, blue: 0.675, alpha: 1.0)  // Teal #4DB6AC
        }
    }

    /// Color for idle/no sessions
    public var whiteColor: NSColor {
        switch self {
        case .vibrant:
            return .white
        case .muted:
            return NSColor(red: 0.90, green: 0.87, blue: 0.82, alpha: 1.0)  // Warm gray #E6DED1
        case .warm:
            return NSColor(red: 1.0, green: 0.95, blue: 0.88, alpha: 1.0)   // Soft cream #FFF2E0
        case .cool:
            return NSColor(red: 0.85, green: 0.90, blue: 0.95, alpha: 1.0)  // Soft blue-gray #D9E6F2
        }
    }
}
