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
        get {
            let value = UserDefaults.standard.integer(forKey: keyCodeKey)
            return value > 0 ? UInt32(value) : defaultKeyCode
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: keyCodeKey)
            reregister()
        }
    }

    var savedModifiers: UInt32 {
        get {
            let value = UserDefaults.standard.integer(forKey: modifiersKey)
            return value > 0 ? UInt32(value) : defaultModifiers
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: modifiersKey)
            reregister()
        }
    }

    /// Get human-readable hotkey description
    var hotkeyDescription: String {
        var parts: [String] = []

        let mods = savedModifiers
        if mods & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if mods & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if mods & UInt32(optionKey) != 0 { parts.append("⌥") }
        if mods & UInt32(controlKey) != 0 { parts.append("⌃") }

        // Convert keyCode to character
        let keyCode = savedKeyCode
        let keyChar = keyCodeToCharacter(keyCode)
        parts.append(keyChar)

        return parts.joined()
    }

    private func keyCodeToCharacter(_ keyCode: UInt32) -> String {
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
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        default: return "?"
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
