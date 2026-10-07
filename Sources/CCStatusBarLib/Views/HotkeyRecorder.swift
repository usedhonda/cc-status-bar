import AppKit

/// Modal "press the new shortcut" prompt for the global hotkey.
@MainActor
enum HotkeyRecorder {
    private final class Recording {
        var value: (keyCode: UInt32, modifiers: UInt32)?
    }

    /// Returns the combination the user pressed and saved, or nil if cancelled.
    static func run(current: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let alert = NSAlert()
        alert.messageText = "Change Hotkey"
        alert.informativeText = "Press the new shortcut. It must include ⌘, ⌃ or ⌥."
        let saveButton = alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        saveButton.isEnabled = false

        let label = NSTextField(labelWithString: current)
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 0, width: 230, height: 34)
        alert.accessoryView = label

        // A local monitor sees the key before the alert does, so the shortcut
        // is recorded instead of being handled as a key equivalent. Keys
        // without ⌘/⌃/⌥ pass through, which keeps Return and Esc working.
        let recording = Recording()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = HotkeyManager.carbonModifiers(from: event.modifierFlags)
            guard HotkeyManager.isAcceptableHotkey(modifiers: modifiers) else { return event }
            let keyCode = UInt32(event.keyCode)
            recording.value = (keyCode, modifiers)
            label.stringValue = HotkeyManager.describe(keyCode: keyCode, modifiers: modifiers)
            label.textColor = .labelColor
            saveButton.isEnabled = true
            return nil
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return recording.value
    }
}
