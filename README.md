# CC Status Bar

A native macOS menu bar app for real-time monitoring of Claude Code sessions.

![Screenshot](assets/screenshot.png?v=2)

## Features

### Menu Bar Display
- **🟢 Green** = Sessions running
- **🔴 Red** = Permission prompt waiting (highest priority)
- **🟡 Yellow** = Command completion waiting
- **⚪ White** = Idle (no active sessions)

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

## Supported Environments

### Fully Supported
| Environment | Features |
|-------------|----------|
| **Ghostty + tmux** | Full tab switching and pane focus |
| **iTerm2** | Full tab switching by TTY (with or without tmux) |

### Ghostty without tmux
By default, Claude Code overrides tab titles to `✳ Claude Code`, making tab switching unreliable.

**Solution:** Disable title changes in Claude Code settings:
```json
// ~/.claude/settings.json
{
  "env": {
    "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"
  }
}
```

This preserves project-based tab titles and enables reliable tab switching.

### Partially Supported
| Environment | Features |
|-------------|----------|
| **Terminal.app + tmux** | Pane focus only |

### Not Supported
- VS Code integrated terminal (limited external API)
- Warp (limited external tab control API)
- Non-tmux environments with multiple tabs (TTY identification difficult)

## Requirements

- macOS 13.0+
- Claude Code CLI
- Accessibility permission (for Ghostty tab switching)

## Installation

### From Release

1. Download `CCStatusBar.dmg` from [Releases](../../releases)
2. Open DMG and drag `CCStatusBar.app` to Applications
3. Launch from Applications
4. Grant Accessibility permission when prompted
5. Follow the setup wizard

> **Note**: The app is notarized by Apple, so it opens without Gatekeeper warnings.

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

## Permissions

- **Accessibility**: Required for terminal tab switching (Ghostty)
  - System Settings → Privacy & Security → Accessibility → CCStatusBar ✓
- **Automation**: Required for iTerm2/Terminal.app control
  - Granted automatically on first use

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

# Emit CCSB protocol event (for external tools)
CCStatusBar emit --tool aider --event session.start --session-id abc123
```

## CCSB Events Protocol

CC Status Bar supports a standardized event protocol for integration with external CLI tools.

### Event Types

| Event | Description |
|-------|-------------|
| `session.start` | Session started |
| `session.stop` | Session ended |
| `session.waiting` | Waiting for user input |
| `session.running` | Running/executing |
| `artifact.link` | Link to artifact (file, URL, PR) |

### Attention Levels

| Level | Color | Description |
|-------|-------|-------------|
| `green` | 🟢 | Running, no action needed |
| `yellow` | 🟡 | Waiting for input |
| `red` | 🔴 | Error or critical |
| `none` | ⚪ | Stopped |

### CLI Usage

```bash
# Start a session
CCStatusBar emit --tool aider --event session.start --session-id my-session-001

# Mark as waiting
CCStatusBar emit --tool terraform --event session.waiting --session-id tf-plan-001 \
  --summary "Waiting for plan approval"

# Stop a session
CCStatusBar emit --tool aider --event session.stop --session-id my-session-001
```

### JSON Format

```json
{
  "proto": "ccsb.v1",
  "event": "session.waiting",
  "session_id": "unique-id",
  "timestamp": "2026-01-19T12:00:00Z",
  "tool": {
    "name": "aider",
    "version": "0.50.0"
  },
  "cwd": "/path/to/project",
  "tty": "/dev/ttys001",
  "attention": {
    "level": "yellow",
    "reason": "Waiting for user input"
  },
  "summary": "Waiting for input"
}
```

Pipe JSON directly:
```bash
echo '{"proto":"ccsb.v1",...}' | CCStatusBar emit --json
```

## Security & Privacy

### Data Collection

CC Status Bar stores the following data **locally on your machine**:

| Data | Location | Purpose |
|------|----------|---------|
| Session info | `~/Library/Application Support/CCStatusBar/sessions.json` | Track active Claude Code sessions |
| Debug logs | `~/Library/Logs/CCStatusBar/debug.log` | Troubleshooting |

**What we store:**
- Project directory paths (for display only)
- TTY identifiers (for terminal switching)
- Session timestamps

**What we DON'T store:**
- Your code or file contents
- Claude Code prompts or responses
- Any personal information

### Network Activity

CC Status Bar makes **zero network requests**. All functionality is local.

### Diagnostics Privacy

When you click "Copy Diagnostics":
- User paths are masked (`/Users/yourname/` → `~/`)
- TTY names are shortened (`/dev/ttys001` → `ttys001`)
- No settings.json content is included

### Why These Permissions?

| Permission | Reason |
|------------|--------|
| **Accessibility** | Required to identify and switch Ghostty tabs via Accessibility API |
| **Automation** | Required to send AppleScript commands to iTerm2/Terminal.app |

These permissions are only used when you click a session to focus its terminal.

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
