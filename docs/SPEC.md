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
| running (tmux detached) | - | ● | systemGray |
| waitingInput (unacknowledged) | permissionPrompt | ◐ | systemRed |
| waitingInput (unacknowledged) | stop/unknown/nil | ◐ | systemYellow |
| waitingInput (tmux detached) | - | ◐ | systemGray |
| waitingInput (acknowledged) | - | ● | systemGreen |
| stopped | - | ✓ | systemGray |

**Note**: Detached tmux sessions (where the terminal tab is closed but tmux session persists) are shown in gray regardless of their actual status. The session remains clickable and is included in the count.

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
├── Global Hotkey (toggle) ← shows ⌘⇧C when enabled
├── Web Server (toggle) ← shows port when enabled
├── Color Theme >
│   ├── Vibrant ← default
│   ├── Muted
│   ├── Warm
│   └── Cool
├── ─────────────
├── Permissions >
│   ├── ✓/✗ Accessibility status
│   ├── ─────────────
│   └── Open Accessibility Settings...
└── Reconfigure Hooks...
```

### 5.1 Default Values

| Setting | Default |
|---------|---------|
| Launch at Login | false |
| Notifications | false |
| Session Timeout | 60 minutes |
| Global Hotkey | false |

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
| iTerm2 + tmux | Tab switch by session name + tmux select-pane |
| iTerm2 (no tmux) | Tab switch by TTY lookup |
| Terminal.app + tmux | tmux select-pane only |
| VS Code / Cursor / Windsurf / editors | Activate by PID + window title matching via AX API |

**Supported Editors (EditorDetector):**

| Bundle ID | Display Name |
|-----------|--------------|
| com.microsoft.VSCode | VS Code |
| com.microsoft.VSCodeInsiders | VS Code |
| com.todesktop.230313mzl4w4u92 | Cursor |
| co.anysphere.cursor.nightly | Cursor |
| com.exafunction.windsurf | Windsurf |
| com.vscodium | VSCodium |
| com.positron.positron | Positron |
| com.byte.trae | Trae |
| dev.zed.Zed | Zed |

**Note:** The VS Code Claude extension's Native UI (sidebar chat) does not trigger hooks - CCStatusBar cannot detect these sessions.

**To enable detection:** Set `"claudeCode.useTerminal": true` in VS Code settings, or run `claude` directly in the integrated terminal.

### 9.2 Environment Resolution Priority

`EnvironmentResolver` determines the focus environment with the following priority:

| Priority | Condition | Detection Method | Tab Index Method |
|----------|-----------|------------------|------------------|
| 1 | Editor detected | `editorBundleID` exists | N/A |
| 2 | actualTermProgram | Parent process info inside tmux | tmux: session name, non-tmux: TTY lookup |
| 3 | TERM_PROGRAM | Environment variable | tmux: session name, non-tmux: TTY lookup |
| 4 | Running terminal (tmux) | Tab search by tmux session name | Session name search |
| 5 | Non-tmux fallback | iTerm2 TTY lookup → Ghostty | iTerm2: TTY lookup, Ghostty: stored tabIndex |
| 6 | Default | Terminal.app | N/A |

**Tab Index Detection by Terminal:**

| Terminal | tmux | non-tmux |
|----------|------|----------|
| Ghostty | `getTabIndexByTitle(tmuxSessionName)` | `ghosttyTabIndex` (bind-on-start) |
| iTerm2 | `getTabIndexByName(tmuxSessionName)` | `getTabIndexByTTY(tty)` |

### 9.3 Ghostty Focus Strategy

| Condition | Focus Method | Rationale |
|-----------|--------------|-----------|
| tmux + tabIndex | TabIndex → Title search | tmux panes are stable, tabIndex is reliable |
| non-tmux | CCSB token → CC title → Project name | Bind-on-start tabIndex may be stale, so skip it |

**Why tabIndex is not used for non-tmux:**

Bind-on-start records the "currently selected tab" at session start. However:
1. If user was viewing a different tab before session start, wrong index is recorded
2. Tab switching is frequent in non-tmux sessions
3. CCSB token (`[CCSB:ttysNNN]`) is TTY-based and unique, more reliable

For tmux sessions, the pane-tab relationship is stable, so tabIndex remains effective.

### 9.4 Focus Fallback Order

```
┌─ Ghostty (tmux)
│  1. Switch tab by tabIndex
│  2. Search title by tmuxSessionName
│  3. Search title by projectName
│  4. Activate Ghostty only
│
├─ Ghostty (non-tmux)
│  1. Search title by CCSB token ← Most reliable
│  2. Search title by CC title (legacy)
│  3. Search title by projectName
│  4. Activate Ghostty only
│
├─ iTerm2 (tmux)
│  1. Switch tab by session name
│  2. Select tmux pane
│  3. Activate via AppleScript
│
├─ iTerm2 (non-tmux)
│  1. Switch tab by TTY lookup ← getTabIndexByTTY()
│  2. Activate via AppleScript
│
├─ Terminal.app
│  1. Select tmux pane (if tmux)
│  2. Activate
│
└─ Editor (VS Code, Cursor, Zed, etc.)
   1. Activate by PID (multi-instance support)
   2. bundleID + window title match
   3. bundleID first instance
```

### 9.5 CCSB Token Format

To improve reliability for non-tmux Ghostty sessions, a unique token is set in the tab title.

```
[CC] project-name • ttys023 [CCSB:ttys023]
 │                          └── Search token (unique per TTY)
 └── Display title
```

- `TtyHelper.setTitle()` sends OSC escape sequence
- 150ms wait before Accessibility API title search

### 9.6 Icon Display

`IconManager` provides application icons for session display:

- Caches icons by bundle ID
- Supports terminal icons (Ghostty, iTerm2, Terminal.app)
- Supports editor icons (VS Code, Cursor, etc.)

### 9.7 Implementation

- **File**: `Sources/Services/EnvironmentResolver.swift`
- **File**: `Sources/Services/FocusManager.swift`
- **File**: `Sources/Services/GhosttyController.swift`
- **File**: `Sources/Services/IconManager.swift`
- **File**: `Sources/Services/GhosttyHelper.swift`
- **File**: `Sources/Services/ITerm2Helper.swift`
- **File**: `Sources/Services/TmuxHelper.swift`
- **File**: `Sources/Services/TtyHelper.swift`

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

---

## 12. Global Hotkey

### 12.1 Purpose

Quick keyboard access to focus waiting sessions without using the menu bar.

### 12.2 Default Hotkey

**⌘⇧C** (Cmd+Shift+C) - disabled by default, must be enabled in Settings.

### 12.3 Behavior

1. If waiting sessions exist (red or yellow), focus the highest priority one
2. Priority: Red (permission_prompt) > Yellow (stop/unknown)
3. If no waiting sessions, focus the most recent session
4. If no sessions at all, show the menu

### 12.4 Settings

- Key: `hotkeyEnabled` (UserDefaults)
- Default: `false`

### 12.5 Implementation

- **File**: `Sources/Services/HotkeyManager.swift`
- **File**: `Sources/App/AppDelegate.swift`
- **Method**: `setupHotkey()`, `handleHotkeyPressed()`

---

## 13. Session Quick Actions

### 13.1 Purpose

Quick navigation actions available from session submenu.

### 13.2 Available Actions

| Action | Description | Condition |
|--------|-------------|-----------|
| Copy Attach Command | Copy `tmux attach -t <session>` to clipboard | Only for detached tmux sessions |
| Open in Finder | Open the session directory in Finder | Always |
| Copy Path | Copy the working directory path to clipboard | Always |
| Copy TTY | Copy the TTY device path to clipboard | Only if TTY exists |

### 13.3 Implementation

- **File**: `Sources/App/AppDelegate.swift`
- **Method**: `createSessionActionsMenu(session:isAcknowledged:)`

---

## 14. Notification Cooldown

### 14.1 Purpose

Prevent notification spam for the same session in the same state.

### 14.2 Behavior

- Same session + same status = max 1 notification per 5 minutes
- Status change resets the cooldown
- Session returning to running clears the cooldown

### 14.3 Implementation

- **File**: `Sources/Services/NotificationManager.swift`
- **Property**: `notificationCooldowns`
- **Method**: `clearCooldown(sessionId:)`

---

## 15. Stale Session Cleanup

### 15.1 Purpose

Automatically mark sessions as stopped when their associated process no longer exists.

### 15.2 Detection Methods

| Session Type | Detection Method | Condition |
|--------------|------------------|-----------|
| Terminal (TTY exists) | TTY file existence | `FileManager.fileExists(atPath: tty)` |
| Editor (no TTY) | Editor PID check | `editorBundleID` set AND `editorPID` set |

### 15.3 Behavior

1. On each file watch event, check each non-stopped session
2. **TTY-based detection**: If TTY exists but file doesn't exist → mark as stopped
3. **Editor PID detection**: If no TTY but editorBundleID/PID set, check if editor process is alive
   - Uses `kill(pid, 0)` for quick existence check
   - Verifies bundleID matches to prevent false positives from PID reuse
4. Session timeout handles removal of stopped sessions

### 15.4 Implementation

- **File**: `Sources/Services/SessionObserver.swift`
- **Method**: `loadSessions()` (stale detection loop)
- **Method**: `isEditorAlive(pid:expectedBundleID:)`
- **File**: `Sources/Services/SessionStore.swift`
- **Method**: `markSessionAsStopped(sessionId:tty:)`

---

## 16. Tab Binding

### 16.1 Purpose

Allow users to manually bind a Ghostty tab when automatic detection fails.

### 16.2 Behavior

1. On partial focus success, offer to bind the current tab
2. User confirms with "Bind This Tab" button
3. Tab index is saved for future focus operations

### 16.3 Implementation

- **File**: `Sources/App/AppDelegate.swift`
- **Method**: `offerTabBinding(for:reason:)`, `showBindingAlert(for:tabIndex:)`
- **File**: `Sources/Services/SessionStore.swift`
- **Method**: `updateTabIndex(sessionId:tty:tabIndex:)`

---

## 17. Permission Management

### 17.1 Purpose

Easy access to macOS permission settings when focus operations fail.

### 17.2 Settings Menu

```
Settings > Permissions >
├── ✓/✗ Accessibility status
├── ─────────────
└── Open Accessibility Settings...
```

### 17.3 Diagnostics

Permissions section added to Copy Diagnostics output.

### 17.4 Implementation

- **File**: `Sources/Services/PermissionManager.swift`
- **File**: `Sources/App/AppDelegate.swift`
- **Method**: `createPermissionsMenu()`

---

## 18. Detached tmux Session Display

### 18.1 Purpose

Visually distinguish tmux sessions that are detached (terminal tab closed but tmux session still running) from active sessions.

### 18.2 Detection

A tmux session is considered detached when `tmux list-sessions` shows `session_attached=0` for that session.

### 18.3 Display Behavior

- **Color**: Gray (systemGray) regardless of actual status
- **Clickable**: Yes, clicking will attempt to focus the terminal
- **Count**: Included in session count (Claude is still running)
- **Submenu**: Shows "Copy Attach Command" at the top

### 18.4 Detached Session Actions

For detached tmux sessions, the submenu includes:

| Action | Description |
|--------|-------------|
| Copy Attach Command | Copy `tmux attach -t <session_name>` to clipboard |

### 18.5 Cache

Attach states are cached for 5 seconds to avoid excessive tmux commands.

### 18.6 Implementation

- **File**: `Sources/Services/TmuxHelper.swift`
- **Methods**: `getSessionAttachStates()`, `isSessionAttached(_:)`
- **File**: `Sources/App/AppDelegate.swift`
- **Method**: `createSessionMenuItem(_:)`, `createSessionActionsMenu(session:isAcknowledged:isTmuxDetached:)`, `copyAttachCommand(_:)`

---

## 19. Color Theme

### 19.1 Purpose

Customize menu bar status colors for better visibility and aesthetic preference. Addresses feedback that default yellow is too harsh/bright.

### 19.2 Available Themes

| Theme | Description |
|-------|-------------|
| Vibrant | Original bright system colors (systemRed, systemYellow, systemGreen) |
| Muted | Softer colors, especially yellow → tan |
| Warm | Orange-tinted palette |
| Cool | Cyan/teal palette |

### 19.3 Color Mapping

| Status | Vibrant | Muted | Warm | Cool |
|--------|---------|-------|------|------|
| Red | systemRed | Salmon (#E57373) | Coral (#FF7043) | Pink (#F48FB1) |
| Yellow | systemYellow | Tan (#D4A574) | Orange (#FFB74D) | Cyan (#4DD0E1) |
| Green | systemGreen | Sage (#81C784) | Lime (#AED581) | Teal (#4DB6AC) |
| White | white | Warm gray (#E6DED1) | Soft cream (#FFF2E0) | Soft blue-gray (#D9E6F2) |

### 19.4 Menu Display

Each theme shows 4 color preview dots (●●●●) before the theme name in the Color Theme submenu.

### 19.4 Storage

- Key: `colorTheme`
- Storage: UserDefaults
- Default: `vibrant`

### 19.5 Affected Elements

- Menu bar "CC" text color
- Menu bar count display colors
- Session list symbol colors

### 19.6 Implementation

- **File**: `Sources/Services/ColorTheme.swift`
- **Enum**: `ColorTheme`
- **File**: `Sources/Services/AppSettings.swift`
- **Property**: `colorTheme`
- **File**: `Sources/App/AppDelegate.swift`
- **Methods**: `updateStatusTitle()`, `createSessionMenuItem(_:)`, `createColorThemeMenu()`, `setColorTheme(_:)`
