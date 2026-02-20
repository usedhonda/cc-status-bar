import AppKit
import Foundation

/// Plays alert sounds and sends BEL to tmux clients when sessions need attention.
enum SoundPlayer {
    /// Resolve the file to play for alert sounds.
    /// Returns nil only when no file fallback exists and system beep should be used.
    static func resolveSoundPath(
        setting: String?,
        defaultSoundPath: String = AppSettings.defaultAlertSoundPath,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let normalized = setting?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Custom file selected by user.
        if !normalized.isEmpty, normalized != "beep" {
            if fileExists(normalized) {
                return normalized
            }
            // If custom file vanished, try packaged default before falling back to system beep.
            return fileExists(defaultSoundPath) ? defaultSoundPath : nil
        }

        // "beep" / nil / empty -> prefer default sound file for better device compatibility.
        return fileExists(defaultSoundPath) ? defaultSoundPath : nil
    }

    private static func playSystemBeep(reason: String) {
        NSSound.beep()
        DebugLog.log("[SoundPlayer] Played system beep (\(reason))")
    }

    /// Play alert sound if sound is enabled.
    static func playAlertSound() {
        guard AppSettings.soundEnabled else {
            DebugLog.log("[SoundPlayer] Skipped alert sound (soundEnabled=false)")
            return
        }

        let setting = AppSettings.alertSoundPath
        guard let path = resolveSoundPath(setting: setting) else {
            playSystemBeep(reason: "no playable file (setting=\(setting ?? "nil"))")
            return
        }

        if let sound = NSSound(contentsOfFile: path, byReference: true) {
            sound.play()
            DebugLog.log("[SoundPlayer] Played sound: \(path)")
        } else {
            playSystemBeep(reason: "failed to load sound file: \(path)")
        }
    }

    /// Preview the current alert sound (ignores soundEnabled setting).
    static func previewSound() {
        let setting = AppSettings.alertSoundPath
        guard let path = resolveSoundPath(setting: setting) else {
            playSystemBeep(reason: "preview no playable file (setting=\(setting ?? "nil"))")
            return
        }

        if let sound = NSSound(contentsOfFile: path, byReference: true) {
            sound.play()
            DebugLog.log("[SoundPlayer] Previewed sound: \(path)")
        } else {
            playSystemBeep(reason: "preview failed to load sound file: \(path)")
        }
    }

    /// Send BEL character to the tmux client TTY for a given pane TTY.
    /// This triggers terminal visual/audio bell (e.g. tmux visual-bell, iTerm badge).
    static func sendBell(tty: String) {
        guard AppSettings.soundEnabled else { return }

        // Get pane info to find socket path and session name
        guard let paneInfo = TmuxHelper.getPaneInfo(for: tty) else {
            DebugLog.log("[SoundPlayer] No tmux pane for TTY \(tty), skipping BEL")
            return
        }

        guard let clientTTY = TmuxHelper.getClientTTY(
            for: paneInfo.session,
            socketPath: paneInfo.socketPath
        ) else {
            DebugLog.log("[SoundPlayer] No client TTY for session \(paneInfo.session), skipping BEL")
            return
        }

        // Write BEL (\a = 0x07) to client TTY
        guard let fh = FileHandle(forWritingAtPath: clientTTY) else {
            DebugLog.log("[SoundPlayer] Cannot open client TTY \(clientTTY) for writing")
            return
        }
        defer { fh.closeFile() }

        let bel = Data([0x07])
        fh.write(bel)
        DebugLog.log("[SoundPlayer] Sent BEL to \(clientTTY)")
    }
}
