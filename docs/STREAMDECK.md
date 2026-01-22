# Stream Deck Plugin Specification

This document covers the Stream Deck plugin for CC Status Bar, including architecture, actions, build process, and troubleshooting.

For main app specification, see [SPEC.md](./SPEC.md).

---

## 1. Plugin Overview

### 1.1 Architecture

- **Runtime**: Node.js (bundled with Stream Deck)
- **Communication**: WebSocket to Stream Deck software
- **Data Source**: CCStatusBar CLI (`list --json`, `focus --index`)
- **Polling**: 1-second interval for session updates

### 1.2 File Structure

```
StreamDeckPlugin/cc-status-bar.sdPlugin/
├── manifest.json           # Plugin metadata, actions
├── src/
│   └── plugin.ts           # TypeScript source
├── bin/
│   └── plugin.js           # Compiled JavaScript (deployed)
├── images/                 # Action icons
└── property-inspector/     # Settings UI (HTML)
```

### 1.3 CLI Path

```
~/Library/Application Support/CCStatusBar/bin/CCStatusBar
```

---

## 2. Action Specifications

| Action ID | Name | Function |
|-----------|------|----------|
| `com.ccstatusbar.session` | Session | Display session status, click to focus terminal |
| `com.ccstatusbar.scroll-up` | Up Arrow | Send Up Arrow key to frontmost app |
| `com.ccstatusbar.scroll-down` | Down Arrow | Send Down Arrow key to frontmost app |
| `com.ccstatusbar.dictation` | Dictation | Toggle macOS dictation |
| `com.ccstatusbar.enter` | Enter | Send Enter key to frontmost app |
| `com.ccstatusbar.escape` | Escape | Send Escape key to frontmost app |

### 2.1 Session Button

- **Display**: Project name (max 3 lines, 6 chars/line) with status color
- **Colors**:
  - Green (`#34C759`): Running or acknowledged
  - Yellow (`#FFCC00`): Waiting input (stop/unknown)
  - Red (`#FF3B30`): Waiting input (permission_prompt)
  - Gray (`#8E8E93`): Stopped
- **Settings**: Fixed session number (1-10) or "auto" (position-based)

### 2.2 Dictation Action

Calls `CCStatusBar dictation` CLI command, which:
1. Tries `AXStartDictation` accessibility action (primary)
2. Falls back to AppleScript Edit menu click (backup)

### 2.3 Keyboard Key Actions

All keyboard actions send keys via AppleScript to the frontmost application.

| Action | Key | macOS Key Code |
|--------|-----|----------------|
| Up Arrow | ↑ | 126 |
| Down Arrow | ↓ | 125 |
| Enter | ⏎ | 36 |
| Escape | ⎋ | 53 |

**Implementation:**
```applescript
tell application "System Events" to key code <code>
```

**Use Case**: Claude Code vibe coding workflow
- Up/Down Arrow: Select prompts in Claude Code CLI
- Enter: Confirm selection
- Escape: Cancel operation

---

## 3. Build & Deploy

### 3.1 Build Command

```bash
cd StreamDeckPlugin/cc-status-bar.sdPlugin
npx tsc src/plugin.ts --outDir bin --target ES2020 --module CommonJS --esModuleInterop
```

### 3.2 Deploy & Restart

```bash
# Copy to installed plugin location
cp StreamDeckPlugin/cc-status-bar.sdPlugin/bin/plugin.js \
   ~/Library/Application\ Support/com.elgato.StreamDeck/Plugins/cc-status-bar.sdPlugin/bin/

# Force kill old plugin process and restart Stream Deck
pkill -9 -f "cc-status-bar.sdPlugin"
pkill -x "Elgato Stream Deck"
sleep 2
open -a "Elgato Stream Deck"
```

### 3.3 Verify New Code Loaded

```bash
# Check plugin process start time
ps aux | grep "cc-status-bar.sdPlugin" | grep -v grep
```

---

## 4. Troubleshooting

### 4.1 Dictation Not Working (macOS Sequoia 15.x)

**Symptom**: Dictation button press has no effect

**Root Cause**: macOS Sequoia blocks most programmatic dictation triggers for security.

#### Methods Tested

| Method | Result | Reason |
|--------|--------|--------|
| `notifyutil` | ❌ | Sequoia blocks non-privileged process notifications |
| CGEvent (Fn×2) | ❌ | Fn key is `flagsChanged`, not `keyDown` - CGEvent can't simulate |
| AXStartDictation | ⚠️ | Works on most apps, fails on some (e.g., Ghostty) |
| **AppleScript menu click** | ✅ | Reliable fallback for all apps |

#### Current Implementation

`Sources/CLI/DictationCommand.swift`:
1. Primary: `AXUIElementPerformAction(appElement, "AXStartDictation")`
2. Fallback: AppleScript clicks Edit → Start Dictation menu item

#### Related Discussion

- `docs/ask/gemini/9736101c5689c45e/029-*` - CGEvent Fn key analysis
- Gemini recommended AXStartDictation as the "bulletproof" solution

#### Known Limitations

- **Secure Input Fields**: Password boxes block all programmatic dictation (macOS security)
- **App-specific**: Some apps may not support AXStartDictation action

---

### 4.2 Plugin Updates Not Taking Effect

**Symptom**: Code changes don't affect behavior after build

**Root Cause**: Old Node.js process still running

#### Solution

```bash
# Must force kill the plugin process
pkill -9 -f "cc-status-bar.sdPlugin"

# Then restart Stream Deck
pkill -x "Elgato Stream Deck"
sleep 2
open -a "Elgato Stream Deck"
```

**Note**: `pkill -x` alone is not sufficient because the Stream Deck app spawns plugin processes that may survive a graceful kill.

---

### 4.3 Session Buttons Not Updating

**Symptom**: Buttons show stale or empty state

**Possible Causes**:

1. **CCStatusBar CLI not found**
   ```bash
   # Verify CLI exists
   ls -la ~/Library/Application\ Support/CCStatusBar/bin/CCStatusBar
   ```

2. **No active sessions**
   ```bash
   # Check sessions
   ~/Library/Application\ Support/CCStatusBar/bin/CCStatusBar list --json
   ```

3. **Plugin polling stopped**
   - Restart Stream Deck app

---

### 4.4 Button Position Issues on Different Devices

**Symptom**: Session numbers don't match button positions

**Cause**: Different Stream Deck models have different grid sizes

| Device Type | Grid | Columns |
|-------------|------|---------|
| Standard | 3×5 | 5 |
| Mini | 2×3 | 3 |
| XL | 4×8 | 8 |
| Plus | 2×4 | 4 |
| Neo | 2×4 | 4 |

**Solution**: Plugin auto-detects device type via `deviceDidConnect` event and adjusts button index calculation.

---

## 5. Development Notes

### 5.1 Debugging

#### Plugin Debug Log

The plugin writes debug logs to:
```
~/Library/Logs/CCStatusBar/streamdeck-plugin.log
```

Log contents:
- WebSocket connection status
- All incoming events (willAppear, keyDown, etc.)
- Action execution

```bash
# Watch plugin log in real time
tail -f ~/Library/Logs/CCStatusBar/streamdeck-plugin.log
```

#### Stream Deck Console

```bash
# Watch plugin logs (Stream Deck console)
# Open Stream Deck app → Preferences → Plugins → Show Log

# Or check system logs
log stream --predicate 'process == "plugin"' --level debug
```

### 5.2 TypeScript Compilation

The plugin uses CommonJS modules for Node.js compatibility:

```bash
npx tsc src/plugin.ts --outDir bin --target ES2020 --module CommonJS --esModuleInterop
```

### 5.3 Session Data Format

```typescript
interface Session {
    id: string;
    project: string;
    status: 'running' | 'waiting_input' | 'stopped';
    path: string;
    waiting_reason?: 'permission_prompt' | 'stop' | 'unknown';
    is_acknowledged?: boolean;
}
```

---

## 6. Implementation Files

| File | Purpose |
|------|---------|
| `StreamDeckPlugin/cc-status-bar.sdPlugin/src/plugin.ts` | TypeScript source |
| `StreamDeckPlugin/cc-status-bar.sdPlugin/bin/plugin.js` | Compiled plugin |
| `Sources/CLI/DictationCommand.swift` | Dictation CLI handler |
| `Sources/CLI/FocusCommand.swift` | Focus CLI handler |
| `Sources/CLI/ListCommand.swift` | List CLI handler (--json) |
