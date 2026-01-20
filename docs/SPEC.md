# CC Status Bar Specification

This document defines the correct behavior of the app. Any modifications MUST preserve these specifications.

---

## 1. Menu Bar Title

### 1.1 Display Format

| Condition | Display | Example |
|-----------|---------|---------|
| Red exists | `CC {red}/{total}` | `CC 1/5` |
| No red, yellow exists | `CC {yellow}/{total}` | `CC 2/5` |
| Green only | `CC {green}` | `CC 3` |
| No sessions | `CC` | `CC` |

### 1.2 Color Rules (Priority: Red > Yellow > Green > White)

| Element | Red exists | Yellow exists (no red) | Green only | No sessions |
|---------|------------|------------------------|------------|-------------|
| "CC" text | systemRed | systemYellow | systemGreen | white |
| Count | systemRed | systemYellow | white | - |
| "/" and total | white | white | - | - |

### 1.3 Waiting States

| State | Trigger | Color | WaitingReason |
|-------|---------|-------|---------------|
| Permission/choice waiting | `notification + permission_prompt` | Red (systemRed) | `.permissionPrompt` |
| Command completion waiting | `.stop` event | Yellow (systemYellow) | `.stop` |
| Legacy/unknown | waitingInput without reason | Yellow (systemYellow) | `.unknown` / `nil` |

### 1.4 Font Specifications

| Element | Font |
|---------|------|
| "CC" | systemFont, 13pt, bold |
| Numbers | monospacedDigitSystemFont, 13pt, medium |

### 1.5 Count Definitions

- **redCount**: `unacknowledgedRedCount` - Sessions with waitingReason=permissionPrompt that have NOT been acknowledged
- **yellowCount**: `unacknowledgedYellowCount` - Sessions with waitingInput status and waitingReason!=permissionPrompt that have NOT been acknowledged
- **greenCount**: `displayedGreenCount` - Sessions with status=running PLUS acknowledged waitingInput sessions

### 1.6 Implementation

- **File**: `Sources/App/AppDelegate.swift`
- **Method**: `updateStatusTitle()`

---

## 2. Session List (Menu Items)

### 2.1 Layout

```
● project-name
   ~/path/to/project
   Environment • Status • HH:mm:ss
```

### 2.2 Font Sizes

| Element | Size | Weight |
|---------|------|--------|
| Symbol (●/◐/✓) | 14pt | regular |
| Project name | 14pt | bold |
| Path | 12pt | regular |
| Environment/Status/Time | 12pt | regular |

### 2.3 Symbol and Color by Status

| Status | WaitingReason | Symbol | Color |
|--------|---------------|--------|-------|
| running | - | ● | systemGreen |
| waitingInput (unacknowledged) | permissionPrompt | ◐ | systemRed |
| waitingInput (unacknowledged) | stop/unknown/nil | ◐ | systemYellow |
| waitingInput (acknowledged) | - | ● | systemGreen |
| stopped | - | ✓ | systemGray |

### 2.4 Status Labels

| Status | Label |
|--------|-------|
| running | "Running" |
| waitingInput | "Waiting" |
| stopped | "Done" |

### 2.5 Implementation

- **File**: `Sources/App/AppDelegate.swift`
- **Method**: `createSessionMenuItem(_:)`
- **File**: `Sources/Models/SessionStatus.swift`
- **Properties**: `symbol`, `label`

---

## 3. Acknowledge System

### 3.1 Purpose

When user focuses a terminal with a waiting session, mark it as "acknowledged" so it displays as green instead of red/yellow.

### 3.2 Behavior

1. Session starts as unacknowledged
2. User focuses the terminal tab containing the session
3. Session becomes acknowledged (red/yellow → green in display)
4. If session returns to `running` status, acknowledged flag is cleared

### 3.3 Auto-Acknowledge Triggers

- Ghostty: Tab activation (via Accessibility API)
- iTerm2: Tab activation (via AppleScript TTY detection)

### 3.4 Implementation

- **File**: `Sources/Services/SessionObserver.swift`
- **Properties**: `acknowledgedSessionIds`, `unacknowledgedRedCount`, `unacknowledgedYellowCount`, `displayedGreenCount`
- **Methods**: `acknowledge(sessionId:)`, `isAcknowledged(sessionId:)`

---

## 4. Session Timeout

### 4.1 Options

| Label | Value (minutes) |
|-------|-----------------|
| 15 minutes | 15 |
| 30 minutes | 30 |
| 1 hour | 60 |
| 3 hours | 180 |
| 6 hours | 360 |
| Never | 0 |

### 4.2 Default Value

**60 minutes (1 hour)**

### 4.3 Storage

- Key: `sessionTimeoutMinutes`
- Storage: UserDefaults
- Value 0 is valid (means "Never")

### 4.4 Timeout Behavior

- Sessions are filtered by `updatedAt` timestamp
- If `Date() - session.updatedAt > timeout`, session is hidden from list
- If timeout = 0 (Never), no filtering is applied

### 4.5 Critical Implementation Details

```swift
// CORRECT: Distinguishes "not set" from "0 (Never)"
if UserDefaults.standard.object(forKey: key) == nil {
    return 60  // Default
}
return UserDefaults.standard.integer(forKey: key)

// WRONG: Cannot distinguish "not set" from "0"
let value = UserDefaults.standard.integer(forKey: key)
return value > 0 ? value : 60  // This breaks "Never"
```

### 4.6 Implementation

- **File**: `Sources/Services/AppSettings.swift`
- **Property**: `sessionTimeoutMinutes`
- **File**: `Sources/Models/StoreData.swift`
- **Property**: `activeSessions`
- **File**: `Sources/App/AppDelegate.swift`
- **Method**: `createTimeoutMenu()`

---

## 5. Settings Menu Structure

```
Settings >
├── Launch at Login (toggle)
├── Notifications (toggle)
├── Session Timeout >
│   ├── 15 minutes
│   ├── 30 minutes
│   ├── 1 hour ← default
│   ├── 3 hours
│   ├── 6 hours
│   └── Never
├── ─────────────
└── Reconfigure Hooks...
```

### 5.1 Default Values

| Setting | Default |
|---------|---------|
| Launch at Login | false |
| Notifications | true |
| Session Timeout | 60 minutes |

### 5.2 Implementation

- **File**: `Sources/App/AppDelegate.swift`
- **Method**: `createSettingsMenu()`

---

## 6. Session Data Model

### 6.1 Session Properties

| Property | Type | Description |
|----------|------|-------------|
| sessionId | String | Unique session ID from Claude |
| cwd | String | Current working directory |
| tty | String? | TTY device path |
| status | SessionStatus | running/waitingInput/stopped |
| waitingReason | WaitingReason? | permissionPrompt/stop/unknown (for waitingInput) |
| createdAt | Date | Session creation time |
| updatedAt | Date | Last update time |
| ghosttyTabIndex | Int? | Ghostty tab index (bind-on-start) |
| termProgram | String? | TERM_PROGRAM (legacy) |
| editorBundleID | String? | Editor bundle ID |
| editorPID | pid_t? | Editor process ID |
| toolName | String? | External tool name (for CCSB events) |
| toolVersion | String? | External tool version |

### 6.2 Computed Properties

| Property | Derivation |
|----------|------------|
| id | `{sessionId}:{tty}` or `sessionId` if no tty |
| projectName | Last path component of cwd |
| displayPath | cwd with home replaced by ~ |
| environmentLabel | Resolved via EnvironmentResolver |

### 6.3 Implementation

- **File**: `Sources/Models/Session.swift`

---

## 7. CCSB Events Protocol

### 7.1 Purpose

Standardized protocol for external CLI tools to integrate with CC Status Bar.

### 7.2 Event Types

| Event | Description |
|-------|-------------|
| `session.start` | Session started |
| `session.stop` | Session ended |
| `session.waiting` | Waiting for user input |
| `session.running` | Running/executing |
| `artifact.link` | Link to artifact (file, URL, PR) |

### 7.3 Attention Levels

| Level | Color | Description |
|-------|-------|-------------|
| `green` | 🟢 | Running, no action needed |
| `yellow` | 🟡 | Waiting for input |
| `red` | 🔴 | Error or critical |
| `none` | ⚪ | Stopped |

### 7.4 JSON Format

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

### 7.5 Implementation

- **File**: `Sources/Models/CCSBEvent.swift`
- **File**: `Sources/CLI/EmitCommand.swift`
- **File**: `Sources/Services/SessionStore.swift`
- **Method**: `updateSession(ccsbEvent:)`

---

## 8. CLI Commands

### 8.1 Available Commands

| Command | Description |
|---------|-------------|
| `CCStatusBar setup` | Configure hooks and symlink |
| `CCStatusBar setup --force` | Force reconfigure |
| `CCStatusBar setup --uninstall` | Remove hooks and data |
| `CCStatusBar list` | List active sessions |
| `CCStatusBar hook <event>` | Process hook event (internal) |
| `CCStatusBar emit` | Emit CCSB protocol event |

### 8.2 emit Command Options

| Option | Description |
|--------|-------------|
| `--tool` | Tool name (required) |
| `--tool-version` | Tool version |
| `--event` | Event type (required) |
| `--session-id` | Session ID (required) |
| `--cwd` | Working directory |
| `--tty` | TTY device path |
| `--attention` | Attention level |
| `--summary` | Human-readable summary |
| `--json` | Read JSON from stdin |

### 8.3 Implementation

- **File**: `Sources/CLI/SetupCommand.swift`
- **File**: `Sources/CLI/ListCommand.swift`
- **File**: `Sources/CLI/HookCommand.swift`
- **File**: `Sources/CLI/EmitCommand.swift`

---

## 9. Terminal Focus

### 9.1 Supported Environments

| Environment | Focus Method |
|-------------|--------------|
| Ghostty + tmux | Tab switch via Accessibility API + tmux select-pane |
| Ghostty (no tmux) | Tab switch via Accessibility API |
| iTerm2 | AppleScript with TTY search |
| Terminal.app + tmux | tmux select-pane only |

### 9.2 Environment Resolution

`EnvironmentResolver` determines the focus environment for each session:

1. Check for editor (VS Code, Cursor, etc.) by `editorBundleID`
2. Check for Ghostty tab binding
3. Check for iTerm2 via AppleScript
4. Check for tmux session
5. Fall back to unknown

### 9.3 Icon Display

`IconManager` provides application icons for session display:

- Caches icons by bundle ID
- Supports terminal icons (Ghostty, iTerm2, Terminal.app)
- Supports editor icons (VS Code, Cursor, etc.)

### 9.4 Implementation

- **File**: `Sources/Services/EnvironmentResolver.swift`
- **File**: `Sources/Services/FocusManager.swift`
- **File**: `Sources/Services/IconManager.swift`
- **File**: `Sources/Services/GhosttyHelper.swift`
- **File**: `Sources/Services/ITerm2Helper.swift`
- **File**: `Sources/Services/TmuxHelper.swift`

---

## 10. File Paths

| Purpose | Path |
|---------|------|
| Sessions data | ~/Library/Application Support/CCStatusBar/sessions.json |
| Settings | UserDefaults (standard) |
| Debug log | ~/Library/Logs/CCStatusBar/debug.log |
| CLI symlink | ~/Library/Application Support/CCStatusBar/bin/CCStatusBar |

---

## 11. Diagnostics

### 11.1 Privacy

Diagnostics output masks sensitive information:

- User paths: `/Users/username/` → `~/`
- TTY: `/dev/ttys001` → `ttys001`
- settings.json content is NOT included

### 11.2 Implementation

- **File**: `Sources/Services/DebugLog.swift`
- **Method**: `collectDiagnostics()`
- **Private methods**: `maskPath(_:)`, `maskTTY(_:)`
