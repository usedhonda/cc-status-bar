# CC Status Bar

A native macOS menu bar app for real-time monitoring of Claude Code sessions.

## Features

### Menu Bar Display
- **Green CC N** = N sessions running
- **Yellow CC N** = N sessions waiting for input (priority display)
- **White CC** = Idle (no active sessions)

### Session List
Click the menu to see session details:
```
● cc-status-bar
   ~/projects/claude/cc-status-bar • Running • 5s ago
```

Click a session to focus the corresponding terminal (iTerm2/Terminal.app).

### Auto Setup
On first launch, the app automatically:
- Creates symlink for Claude Code hooks
- Registers hooks in `~/.claude/settings.json`
- Creates backup of existing settings

## Requirements

- macOS 13.0+
- Claude Code CLI

## Installation

### From Release
1. Download `CCStatusBar.app` from Releases
2. Move to `/Applications` (or any permanent location)
3. Launch the app
4. Follow the setup wizard

### From Source
```bash
# Build
swift build

# Copy to .app bundle
cp .build/debug/CCStatusBar CCStatusBar.app/Contents/MacOS/

# Code sign (ad-hoc)
codesign --force --deep --sign - CCStatusBar.app

# Launch
open CCStatusBar.app
```

## How It Works

The app uses Claude Code hooks to track session status:

1. **Hooks** are registered in `~/.claude/settings.json`
2. **Events** (Notification, Stop, UserPromptSubmit) trigger status updates
3. **Sessions** are stored in `~/Library/Application Support/CCStatusBar/sessions.json`
4. **Menu bar** updates in real-time via file watching

### Session Status
| Status | Description |
|--------|-------------|
| Running | Claude Code is executing tools |
| Waiting | Waiting for permission prompt |
| Stopped | Session ended |

## CLI Commands

```bash
# Manual setup (usually not needed)
CCStatusBar setup

# Force reconfigure
CCStatusBar setup --force

# Uninstall (remove hooks and data)
CCStatusBar setup --uninstall

# List active sessions
CCStatusBar list
```

## Troubleshooting

### Copy Diagnostics
Click the menu bar icon → "Copy Diagnostics" to copy diagnostic info to clipboard.

### Log File
Check `~/Library/Logs/CCStatusBar/debug.log` for detailed logs.

### App Translocation
If you see "Please move CC Status Bar" on launch:
- macOS is running the app from a temporary location
- Move the app to `/Applications` or another permanent folder
- Relaunch the app

## License

MIT
