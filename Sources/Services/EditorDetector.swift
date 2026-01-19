import Cocoa
import Darwin

/// Information about a detected editor
struct EditorInfo {
    let bundleID: String
    let displayName: String
}

/// Detects VS Code-derived editors via PPID chain inspection
/// Since Cursor, VS Code, Windsurf all set TERM_PROGRAM=vscode,
/// we must inspect the parent process chain to find the .app bundle
final class EditorDetector {
    static let shared = EditorDetector()

    /// Known editor Bundle IDs -> display names
    private let knownEditors: [String: String] = [
        "com.microsoft.VSCode": "VS Code",
        "com.microsoft.VSCodeInsiders": "VS Code",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "co.anysphere.cursor.nightly": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "com.vscodium": "VSCodium",
        "com.positron.positron": "Positron",
        "com.byte.trae": "Trae",
        "dev.zed.Zed": "Zed",
    ]

    private init() {}

    // MARK: - Public API

    /// Get display name for a known bundle ID
    func displayName(for bundleID: String) -> String? {
        knownEditors[bundleID]
    }

    /// Get bundle ID for a display name (reverse lookup)
    func bundleID(for displayName: String) -> String? {
        knownEditors.first { $0.value == displayName }?.key
    }

    /// Check if a bundle ID is a known editor
    func isKnownEditor(_ bundleID: String) -> Bool {
        knownEditors[bundleID] != nil
    }

    /// Detect editor from current process's PPID chain
    func detectFromCurrentProcess() -> EditorInfo? {
        detect(pid: getpid())
    }

    /// Detect editor from a specific PID by walking up the PPID chain
    /// - Parameter pid: Starting process ID
    /// - Returns: EditorInfo if an editor is found in the chain
    func detect(pid: pid_t) -> EditorInfo? {
        var current = pid

        // Walk up the process tree (max 60 levels to prevent infinite loops)
        for _ in 0..<60 {
            guard let ppid = parentPID(of: current), ppid > 1 else { break }
            current = ppid

            // Get executable path and check if it's inside a .app bundle
            if let path = executablePath(of: current),
               let appPath = extractAppPath(from: path),
               let bundle = Bundle(path: appPath),
               let bundleID = bundle.bundleIdentifier {

                // Look up display name: known editors -> bundle info -> bundle ID
                let name = knownEditors[bundleID]
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? bundle.infoDictionary?["CFBundleName"] as? String
                    ?? bundleID

                DebugLog.log("[EditorDetector] Found editor: \(name) (\(bundleID)) at \(appPath)")
                return EditorInfo(bundleID: bundleID, displayName: name)
            }
        }

        return nil
    }

    // MARK: - Private (libproc)

    /// Get parent PID using libproc
    private func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == MemoryLayout<proc_bsdinfo>.size else { return nil }
        let ppid = info.pbi_ppid
        return ppid > 0 ? pid_t(ppid) : nil
    }

    /// Get executable path using libproc
    private func executablePath(of pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN))
        guard result > 0 else { return nil }
        return String(cString: pathBuffer)
    }

    /// Extract .app bundle path from executable path
    /// e.g., "/Applications/Cursor.app/Contents/MacOS/Cursor" -> "/Applications/Cursor.app"
    private func extractAppPath(from execPath: String) -> String? {
        guard let range = execPath.range(of: ".app/") else { return nil }
        return String(execPath[..<range.upperBound].dropLast()) // Remove trailing "/"
    }
}
