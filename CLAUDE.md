# CC Status Bar Development Guide

## Language Policy

**Development conversation**: Japanese (with Claude)

**All external/user-facing content must be in English:**
- UI text (alerts, menus, dialogs)
- Documentation (README.md)
- Code comments
- Error messages
- Log messages

## Project Structure

```
Sources/
├── main.swift              # Entry point (CLI/GUI switch)
├── App/
│   ├── AppDelegate.swift   # Menu bar UI, session display
│   └── CCStatusBarApp.swift
├── Services/
│   ├── SessionObserver.swift  # File watching (Combine)
│   ├── SessionStore.swift     # Session CRUD
│   ├── TtyDetector.swift      # TTY detection
│   ├── SetupManager.swift     # First-run setup, hooks
│   ├── TerminalAdapter.swift  # Terminal adapter protocol
│   ├── GhosttyHelper.swift    # Ghostty tab control (Accessibility API)
│   ├── ITerm2Helper.swift     # iTerm2 tab control (AppleScript TTY search)
│   ├── TmuxHelper.swift       # tmux pane control
│   └── DebugLog.swift         # Debug logging
├── Models/
│   ├── Session.swift          # Session model
│   ├── SessionStatus.swift    # Status enum
│   ├── StoreData.swift        # JSON store structure
│   └── HookEvent.swift        # Hook event
├── Views/
│   └── SessionListView.swift  # SwiftUI (unused)
└── CLI/
    ├── HookCommand.swift      # `CCStatusBar hook <event>`
    ├── SetupCommand.swift     # `CCStatusBar setup`
    └── ListCommand.swift      # `CCStatusBar list`
```

## Build & Run

```bash
# Build and launch
pkill -f CCStatusBar
swift build
cp .build/debug/CCStatusBar CCStatusBar.app/Contents/MacOS/
codesign --force --deep --sign "CCStatusBar Dev" CCStatusBar.app
open CCStatusBar.app
```

**Note**: Use self-signed certificate "CCStatusBar Dev" to preserve Accessibility permissions across rebuilds.
See `plans/crystalline-humming-stardust.md` for certificate setup and distribution signing requirements.

## Data Source

Monitors `~/Library/Application Support/CCStatusBar/sessions.json`

### Session JSON Structure
```json
{
  "sessions": {
    "session_id:tty": {
      "session_id": "xxx",
      "cwd": "/path/to/project",
      "tty": "/dev/ttys001",
      "status": "running|waiting_input|stopped",
      "created_at": "ISO8601",
      "updated_at": "ISO8601"
    }
  }
}
```

## Key Components

### AppDelegate.swift
- `updateStatusTitle()` - Updates menu bar title (color + count)
- `rebuildMenu()` - Builds session list menu
- `focusTerminal()` - Focuses terminal via AppleScript

### SessionObserver.swift
- `@Published sessions` - Session array
- `runningCount`, `waitingCount` - Status counts
- File watching + 2s polling fallback

### SetupManager.swift
- First-run detection and setup wizard
- Symlink management for hooks
- App move detection and auto-repair
- Settings.json hook registration

## Status Display Logic

```swift
if waitingCount > 0 {
    color = yellow, count = waitingCount
} else if runningCount > 0 {
    color = green, count = runningCount
} else {
    color = white, count = 0
}
```

## Distribution

### App Translocation
- macOS runs quarantined apps from temporary paths
- App detects this and requires user to move it first
- After moving, setup completes automatically

### Paths
- Symlink: `~/Library/Application Support/CCStatusBar/bin/CCStatusBar`
- Sessions: `~/Library/Application Support/CCStatusBar/sessions.json`
- Settings: `~/.claude/settings.json`
- Logs: `~/Library/Logs/CCStatusBar/debug.log`
