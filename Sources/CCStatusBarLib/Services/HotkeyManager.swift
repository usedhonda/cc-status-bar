import AppKit
import Carbon
import Combine

/// Manages global hotkeys for quick session access
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    /// Callback when hotkey is pressed
    var onHotkeyPressed: (() -> Void)?

    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var isRegistered = false

    // Default hotkey: Cmd+Ctrl+C
    private let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_C)
    private let defaultModifiers: UInt32 = UInt32(cmdKey | controlKey)

    // UserDefaults keys
    private let keyCodeKey = "hotkeyKeyCode"
    private let modifiersKey = "hotkeyModifiers"
    private let enabledKey = "hotkeyEnabled"

    private init() {}

    // MARK: - Public API

    /// Register the global hotkey
    func register() {
        guard !isRegistered else { return }
        guard isEnabled else {
            DebugLog.log("[HotkeyManager] Hotkey disabled, not registering")
            return
        }

        let keyCode = savedKeyCode
        let modifiers = savedModifiers

        // Install event handler
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyCallback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        guard status == noErr else {
            DebugLog.log("[HotkeyManager] Failed to install event handler: \(status)")
            return
        }

        // Register hotkey
        let hotkeyID = EventHotKeyID(signature: OSType(0x4343), id: 1)  // "CC"

        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        guard regStatus == noErr else {
            DebugLog.log("[HotkeyManager] Failed to register hotkey: \(regStatus)")
            if let eventHandler = eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            return
        }

        isRegistered = true
        DebugLog.log("[HotkeyManager] Registered hotkey: keyCode=\(keyCode), modifiers=\(modifiers)")
    }

    /// Unregister the global hotkey
    func unregister() {
        guard isRegistered else { return }

        if let hotkeyRef = hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }

        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }

        isRegistered = false
        DebugLog.log("[HotkeyManager] Unregistered hotkey")
    }

    /// Re-register with new settings
    func reregister() {
        unregister()
        register()
    }

    // MARK: - Settings

    var isEnabled: Bool {
        get {
            // Default to false - user must explicitly enable
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                register()
            } else {
                unregister()
            }
        }
    }

    var savedKeyCode: UInt32 {
        Self.storedKeyCode(UserDefaults.standard.object(forKey: keyCodeKey), default: defaultKeyCode)
    }

    var savedModifiers: UInt32 {
        let value = UserDefaults.standard.integer(forKey: modifiersKey)
        return value > 0 ? UInt32(value) : defaultModifiers
    }

    /// Key code 0 is a real key (A), so only a missing value means "default".
    static func storedKeyCode(_ stored: Any?, default defaultKeyCode: UInt32) -> UInt32 {
        guard let value = stored as? Int, value >= 0 else { return defaultKeyCode }
        return UInt32(value)
    }

    /// Switch to a new combination and turn the hotkey on.
    /// If macOS refuses it, the previous settings are restored and false is returned.
    @discardableResult
    func update(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let defaults = UserDefaults.standard
        let previous = (keyCode: savedKeyCode, modifiers: savedModifiers, enabled: isEnabled)

        unregister()
        defaults.set(Int(keyCode), forKey: keyCodeKey)
        defaults.set(Int(modifiers), forKey: modifiersKey)
        defaults.set(true, forKey: enabledKey)
        register()
        if isRegistered { return true }

        defaults.set(Int(previous.keyCode), forKey: keyCodeKey)
        defaults.set(Int(previous.modifiers), forKey: modifiersKey)
        defaults.set(previous.enabled, forKey: enabledKey)
        register()
        return false
    }

    /// Carbon modifier mask for an AppKit key event.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    /// A global hotkey needs ⌘, ⌃ or ⌥; a bare key or ⇧ alone is ordinary typing.
    static func isAcceptableHotkey(modifiers: UInt32) -> Bool {
        modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }

    /// Get human-readable hotkey description
    var hotkeyDescription: String {
        Self.describe(keyCode: savedKeyCode, modifiers: savedModifiers)
    }

    static func describe(keyCode: UInt32, modifiers mods: UInt32) -> String {
        var parts: [String] = []

        if mods & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if mods & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if mods & UInt32(optionKey) != 0 { parts.append("⌥") }
        if mods & UInt32(controlKey) != 0 { parts.append("⌃") }

        // Convert keyCode to character
        parts.append(keyCodeToCharacter(keyCode))

        return parts.joined()
    }

    /// The character this key produces on the current keyboard layout.
    private static func layoutCharacter(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(property, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
        return text.isEmpty ? nil : text.uppercased()
    }

    private static func keyCodeToCharacter(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Fwd Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        default: break
        }
        if let character = layoutCharacter(keyCode) { return character }
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        default: return "Key \(keyCode)"
        }
    }

    // MARK: - Hotkey Handler

    fileprivate func handleHotkey() {
        DebugLog.log("[HotkeyManager] Hotkey pressed")
        DispatchQueue.main.async { [weak self] in
            self?.onHotkeyPressed?()
        }
    }
}

// MARK: - Carbon Callback

private func hotkeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = userData else { return OSStatus(eventNotHandledErr) }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleHotkey()

    return noErr
}
