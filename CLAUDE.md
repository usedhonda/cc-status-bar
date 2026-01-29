# CC Status Bar Development Guide

## Pre-Work Checklist

### Required Reading by Task

| Task | Required Files |
|------|----------------|
| Release | `scripts/release.sh` (実行), `.local/release.md` (参照のみ) |
| New Feature | `docs/SPEC.md`, `README.md` |
| Bug Fix | `~/Library/Logs/CCStatusBar/debug.log` |
| Design Decision | `docs/ask/` (past AI discussions) |

### External API Usage

- **Always fetch docs via Context7**
- e.g., Apple Notarization, GitHub API, etc.

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

### Post-Build Checklist (MANDATORY)

Track these as **separate items** in TodoWrite:

1. `swift build` - Build
2. `pkill + cp + codesign + open` - Restart app
3. `tail ~/Library/Logs/CCStatusBar/debug.log` - Check logs

**Build success is not completion. Restart and verify logs before marking done.**

## Stream Deck Plugin Build & Deploy (MANDATORY)

**Full specification**: See [docs/STREAMDECK.md](docs/STREAMDECK.md) for detailed plugin spec, troubleshooting, and development notes.

### Build Command

```bash
cd StreamDeckPlugin/cc-status-bar.sdPlugin
npx tsc src/plugin.ts --outDir bin --target ES2020 --module CommonJS --esModuleInterop
```

### Deploy & Restart (Claude MUST do this)

```bash
# Copy built plugin to installed location
cp StreamDeckPlugin/cc-status-bar.sdPlugin/bin/plugin.js \
   ~/Library/Application\ Support/com.elgato.StreamDeck/Plugins/cc-status-bar.sdPlugin/bin/

# Restart Stream Deck app
pkill -x "Stream Deck" ; sleep 2 ; open -a "Elgato Stream Deck"
```

### Rules

1. **Claude MUST complete full cycle**: Build → Copy → Restart
2. **NEVER ask user** to restart Stream Deck or copy files
3. **NEVER end task** after build only - deploy is part of implementation
4. **Test immediately** after restart if possible

### ⚠️ CRITICAL: Restart Method

**NEVER kill plugin processes directly.** Always use the restart script:

```bash
# ✅ CORRECT: Use the safe restart script
./scripts/restart-streamdeck.sh

# ❌ WRONG: These kill ALL plugins including volume-controller
pkill -f "sdPlugin"
pkill -f "Stream Deck"
pgrep -f "Stream Deck"
kill -9 $(pgrep -f "Stream Deck")
```

The script uses `pkill -x "Stream Deck"` which only kills the app process, not plugins.

Killing plugin processes directly breaks other plugins (volume-controller, etc.) and causes system instability.

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

## Release (MANDATORY)

### ⚠️ CRITICAL: Always use the release script

```bash
# ✅ CORRECT: Use the release script
./scripts/release.sh

# ❌ WRONG: Manual commands (hdiutil, codesign, notarytool, etc.)
```

**Rules:**
1. **ALWAYS use `./scripts/release.sh`** - never execute release commands manually
2. `.local/release.md` is for **reference only** (credentials, troubleshooting)
3. Manual commands lead to permission errors and inconsistent builds
4. The script handles: build, sign, DMG, notarize, staple, Stream Deck plugin

**Important**: When icons or screenshots are updated, a new release must be created.

## Document Sync

- README.md: User-facing feature descriptions (only implemented features)
- SPEC.md: Implementation specifications (no line numbers, reference by method name)
- Update both when adding/removing/changing features

## Pre-commit/Pre-push Check (MANDATORY)

Before commit or push, **always run `/publish-check` skill**.

| Operation | Trigger Words |
|-----------|---------------|
| git commit | コミット, commit |
| git push | プッシュ, push, 上げて, あげて |
| release | リリース, release, deploy, デプロイ |

**Prohibited**: Committing or pushing without running `/publish-check`

---

## Git Commit

### Commit Frequency (MANDATORY)

**Commit frequently, even on feature branches.**

- Commit at every logical checkpoint
- Break large changes into small commits
- Commit immediately when code reaches a working state
- Push can wait, but commit must happen

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
