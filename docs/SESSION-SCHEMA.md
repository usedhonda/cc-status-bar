# Session WebSocket Schema

This document defines the additive session fields emitted by `sessions.list`,
`session.added`, and `session.updated`. Existing fields, including
`attention_level`, remain part of the wire contract.

## Normalized Fields

| Field | Values | Meaning |
| --- | --- | --- |
| `lifecycle` | `working`, `awaiting_input`, `permission`, `question`, `completed`, `stopped` | Truthful primary state for the producer observation. |
| `state_source` | `hook`, `webhook`, `pane_guess` | Evidence source used for the normalized state. |
| `confidence` | `observed`, `inferred` | `observed` means a hook or webhook supplied the fact; `inferred` means the producer inferred it from a pane or process observation. |
| `observed_at` | ISO8601 timestamp | When the producer serialized the row. Always present. |
| `last_activity_at` | ISO8601 timestamp, optional | The latest factual activity timestamp known to the producer. It is omitted when the available evidence is only a pane guess. |

Codex rows additionally include `updated_at` from the tracked `lastEventAt`
and `last_seen_at` from the tracked `lastSeenAt` when that internal status is
available. These are additive and do not replace `started_at`.

## Source Rules

- Claude hook observations use `state_source: hook` and `confidence: observed`.
- Factual Codex webhook observations use `state_source: webhook` and
  `confidence: observed`.
- Pane-derived state uses `state_source: pane_guess` and
  `confidence: inferred`. It is never normalized as `permission` or
  `completed`; a waiting pane guess is `awaiting_input`.
- Synthetic Codex stopped rows use `lifecycle: stopped`. They are process
  observations rather than webhook facts and are therefore emitted as
  `pane_guess` / `inferred`.

## Lifecycle Rules

- Claude `Stop` and its `stop` waiting reason are `awaiting_input`, never
  `completed`. Claude `completed` is unreachable until a future factual hook
  exists.
- Factual Codex `codex-stop` / idle webhook state is `completed`, with
  `state_source: webhook` and `confidence: observed`.
- `permission` and `question` are reserved for factual hook/webhook evidence.
  This prevents inferred pane markers from creating high-urgency states.
- Unknown factual waiting is `awaiting_input`.
- Synthetic stopped state is `stopped`.

## Compatibility

`attention_level` is frozen for clawgate and existing consumers:

- `0`: running, acknowledged waiting, idle/completed, or stopped
- `1`: non-permission waiting
- `2`: permission waiting

The normalized fields do not redefine, remove, rename, or change any legacy
field. A consumer that ignores unknown JSON keys continues to decode the old
payload shape.

## Examples

Claude Stop waiting for the next user action:

```json
{
  "type": "claude_code",
  "status": "waiting_input",
  "waiting_reason": "stop",
  "attention_level": 1,
  "lifecycle": "awaiting_input",
  "state_source": "hook",
  "confidence": "observed",
  "observed_at": "2026-08-19T10:00:00Z",
  "last_activity_at": "2026-08-19T09:59:58Z"
}
```

Codex factual idle webhook:

```json
{
  "type": "codex",
  "status": "waiting_input",
  "waiting_reason": "idle",
  "attention_level": 0,
  "lifecycle": "completed",
  "state_source": "webhook",
  "confidence": "observed",
  "observed_at": "2026-08-19T10:00:00Z",
  "last_activity_at": "2026-08-19T09:59:57Z",
  "updated_at": "2026-08-19T09:59:57Z",
  "last_seen_at": "2026-08-19T10:00:00Z"
}
```

Codex pane-derived waiting marker:

```json
{
  "type": "codex",
  "status": "waiting_input",
  "waiting_reason": "permission_prompt",
  "attention_level": 2,
  "lifecycle": "awaiting_input",
  "state_source": "pane_guess",
  "confidence": "inferred",
  "observed_at": "2026-08-19T10:00:00Z"
}
```

The legacy `attention_level: 2` remains untouched for compatibility; the
normalized lifecycle refuses to claim factual permission from this pane guess.
