# ClawGate Hook Requirements for cc-status-bar

Date: 2026-02-14

## Background

ClawGate monitors CC sessions via cc-status-bar's WebSocket broadcast and hook events.
Currently, cc-status-bar reports AskUserQuestion as `waitingReason: "permission_prompt"`,
which makes it impossible for ClawGate to distinguish between real permission prompts
and AskUserQuestion without falling back to pane capture + heuristic detection.

This document describes improvements that would allow ClawGate to handle
AskUserQuestion more reliably across all session modes.

---

## 1. New WaitingReason: `askUserQuestion`

**Current state**: `waitingReason` is either `permission_prompt` or `stop`.
`HookEvent.isPermissionPrompt` checks if the notification message contains "permission",
which also matches AskUserQuestion notifications that happen to mention permissions.

**Request**: Add a new `waitingReason` value: `askUserQuestion`

When CC enters the AskUserQuestion state (tool_name = "AskUserQuestion"),
set `waitingReason = "askUserQuestion"` instead of `"permission_prompt"`.

This allows ClawGate to route events correctly:
- `permission_prompt` -> auto-approve (send "y") in auto/autonomous modes
- `askUserQuestion` -> emit question event for Chi (observe/autonomous) or auto-answer (auto)

## 2. Hook Data Extension for AskUserQuestion

**Current state**: The Notification hook provides `notification_type` and `message` only.
AskUserQuestion data (question text, options) is embedded in the unstructured `message` string.

**Request**: When the notification originates from AskUserQuestion, include structured data:

```json
{
  "notification_type": "...",
  "message": "...",
  "tool_name": "AskUserQuestion",
  "question": {
    "text": "Which library should we use?",
    "options": [
      {"label": "Option A", "description": "..."},
      {"label": "Option B", "description": "..."}
    ],
    "selected_index": 0
  }
}
```

This would eliminate the need for pane capture + regex-based question detection.

## 3. WS Message: Question Data Fields

**Current state**: `claudeSessionToDict` / WS broadcast does not include question-related fields.

**Request**: When a session is in `askUserQuestion` state, include in the WS broadcast:

| Field | Type | Description |
|-------|------|-------------|
| `question_text` | String | The question being asked |
| `question_options` | [String] | Array of option labels |
| `question_selected` | Int | Currently selected option index |

This allows ClawGate to receive structured question data via WebSocket
without needing to capture and parse pane output.

## 4. pane_capture in waitingInput Transitions

**Current state**: `pane_capture` is included only in progress events.

**Request**: Also include `pane_capture` in the WS message when a session transitions
to `waiting_input` state. This provides the pane content at the moment of transition,
allowing ClawGate to detect questions without issuing a separate `capturePane` call.

This is a lower-priority improvement since items 1-3 would make pane capture
unnecessary for question detection.

---

## Priority

1. **High**: Item 1 (new waitingReason) - minimal change, high impact
2. **Medium**: Item 4 (pane_capture on waitingInput) - easy win for all use cases
3. **Low**: Items 2-3 (structured question data) - nice to have, ClawGate can work without them
