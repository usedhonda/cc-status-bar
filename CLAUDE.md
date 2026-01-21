# CC Status Bar Development Guide

## 作業開始チェックリスト（最初に必ず確認）

### タスク別必読ファイル

| タスク | 必読ファイル |
|--------|-------------|
| リリース作業 | `.local/release.md` |
| 機能追加 | `docs/SPEC.md`, `README.md` |
| バグ修正 | `~/Library/Logs/CCStatusBar/debug.log` |
| 設計判断 | `docs/ask/` (過去のAI議論) |

### 外部API使用時

- **必ずContext7でドキュメント取得**
- 例: Apple Notarization, GitHub API, etc.

---

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

## Specification Document

UI/behavior specifications are documented in `docs/SPEC.md`.
**Before any modification, read the spec. After modification, update the spec if behavior changed.**

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

## Release

Release procedure is documented in `.local/release.md` (local only, not committed).

**Important**: When icons or screenshots are updated, a new release must be created.

## Document Sync

- README.md: User-facing feature descriptions (only implemented features)
- SPEC.md: Implementation specifications (no line numbers, reference by method name)
- Update both when adding/removing/changing features

## Git Commit

### Pre-commit Check (Required)

When committing feature additions, changes, or deletions, verify the following:

1. **README.md verification**
   - Added features are documented
   - Removed features are removed from docs
   - Documentation matches implementation

2. **SPEC.md verification**
   - New specifications are added
   - Changed specifications are updated
   - Removed specifications are deleted

3. **Screenshot/Asset verification**
   - Screenshots updated for UI changes
   - Asset filenames changed when updated (cache busting)

### Document Update Required Before Commit

- New feature → README + SPEC
- UI change → Screenshot + README
- Spec change → SPEC
- Feature removal → Remove from README + SPEC
