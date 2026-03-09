# VOICEVOX Template Contract

This file defines the project-local speech source-of-truth used by
`scripts/voicevox-alert.sh`.

## File Name

```text
<project-root>/.cc-status-bar.voice.json
```

The helper starts from `CCSB_CWD` and walks upward toward `/`.
The first matching file wins.

## Current Schema (v2)

```json
{
  "version": 2,
  "identity": {
    "project_name": "cc-status-bar",
    "project_reading": "シーシーステータスバー",
    "project_spoken": "シーシーステータスバー",
    "alias_spoken": "シーシーエスビー",
    "callname": "ご主人様"
  },
  "defaults": {
    "speaker": "四国めたん",
    "style": "ノーマル",
    "speed_scale": 1.15,
    "voice_gender": "female",
    "callname": "ご主人様"
  },
  "tool_readings": {
    "claude": "クロード",
    "codex": "コーデックス"
  },
  "events": {
    "default": [
      {
        "id": "wait-01",
        "text": "{project_reading} の {tool_reading} が入力待ちです。",
        "weight": 1
      }
    ],
    "stop": [
      {
        "id": "stop-01",
        "tool": "codex",
        "text": "{project_reading} の {tool_reading} が止まっています。御方、ご確認を。",
        "speaker": "玄野武宏",
        "style": "ノーマル",
        "voice_gender": "male",
        "weight": 1
      }
    ],
    "permission_prompt": [
      {
        "id": "perm-01",
        "text": "{project_reading} の {tool_reading} が許可を待っています。",
        "weight": 1
      }
    ]
  }
}
```

## Fields

- `version`
  - Required.
  - Recommended value is `2`.
- `identity.project_name`
  - Optional.
  - Human-readable project name fallback.
- `identity.project_reading`
  - Optional.
  - Katakana or VOICEVOX-friendly reading for the project name.
  - Prefer a single uninterrupted reading without spaces so VOICEVOX reads it in one flow.
- `identity.project_spoken`
  - Optional but recommended.
  - The spoken source-of-truth for project notifications.
  - This should be a contiguous katakana or hiragana string with no ASCII letters.
- `identity.alias_spoken`
  - Optional.
  - Spoken override for the session/display alias.
  - If present, it wins over project-level spoken names.
- `identity.callname`
  - Optional.
  - Project-local default user callname.
- `defaults.speaker_id`
  - Optional.
  - VOICEVOX style id. If present, it wins.
- `defaults.speaker`
  - Optional.
  - Speaker display name. Used with `defaults.style` to resolve a style id.
- `defaults.style`
  - Optional.
  - Style display name paired with `defaults.speaker`.
- `defaults.speed_scale`
  - Optional.
  - Speech speed passed into `audio_query.speedScale`.
- `defaults.voice_gender`
  - Optional.
  - Metadata for template writing and placeholder expansion.
- `defaults.callname`
  - Optional.
  - Default user callname if a template does not override it.
- `tool_readings.claude` / `tool_readings.codex`
  - Optional.
  - Readings used when `{tool_reading}` is expanded.
- `events.default`
  - Required.
  - Non-empty array of template objects.
- `events.stop`
  - Optional.
  - Used when `CCSB_WAITING_REASON=stop`.
- `events.permission_prompt`
  - Optional.
  - Used when `CCSB_WAITING_REASON=permission_prompt`.

## Template Object

```json
{
  "id": "wait-01",
  "text": "{project_reading} の {tool_reading} が入力待ちです。",
  "tool": "codex",
  "speaker_id": 37,
  "speaker": "四国めたん",
  "style": "ノーマル",
  "speed_scale": 1.12,
  "voice_gender": "female",
  "callname": "ご主人様",
  "weight": 2,
  "enabled": true
}
```

- `id`
  - Required.
  - Stable identifier for debugging and future edits.
- `text`
  - Required.
  - The utterance template.
- `tool`
  - Optional.
  - `claude` or `codex`.
  - If omitted, the template is shared by both.
- `speaker_id`
  - Optional.
  - VOICEVOX style id. Wins over `speaker` + `style`.
- `speaker`
  - Optional.
  - Speaker display name.
- `style`
  - Optional.
  - Style display name paired with `speaker`.
- `voice_gender`
  - Optional.
  - Metadata for template writing and placeholder expansion.
- `speed_scale`
  - Optional.
  - Per-template speech speed override. Falls back to `defaults.speed_scale`.
- `callname`
  - Optional.
  - Overrides the default user callname.
- `weight`
  - Optional.
  - Weighted random selection. Default is `1`.
- `enabled`
  - Optional.
  - If set to `false`, the template is ignored.

## Placeholder Expansion

The helper expands these placeholders in `text`:

- `{project_reading}`
- `{tool_reading}`
- `{voice_gender}`
- `{callname}`
- `{display_name}`
- `{project_name}`

`{project_reading}` is resolved in this order:

1. `identity.alias_spoken`
2. spoken form of `CCSB_DISPLAY_NAME`
3. `identity.project_spoken`
4. `identity.project_reading`
5. spoken form of `identity.project_name`
6. spoken form of `CCSB_PROJECT`

`{display_name}` and `{project_name}` are also expanded to spoken forms, not raw
ASCII env values.

The helper applies a final safety guard before synthesis:

- the final spoken text must not contain any ASCII letters
- remaining ASCII spans are converted to katakana-like spoken forms
- if ASCII still remains after conversion, the helper falls back to Ping instead
  of speaking broken text

`{tool_reading}` is resolved in this order:

1. `tool_readings.<tool>`
2. built-in defaults:
   - `claude -> クロード`
   - `codex -> コーデックス`

## Selection Rules

1. Pick the event pool by `CCSB_WAITING_REASON`.
   - `permission_prompt` -> `events.permission_prompt`
   - `stop` -> `events.stop`
   - otherwise -> `events.default`
2. Filter out templates with `enabled=false`.
3. If `tool` is present, keep only templates matching the normalized
   `CCSB_SOURCE` (`claude`, `codex`).
4. Pick one template by weighted random using `weight`.
5. Resolve `speaker_id`, or resolve `speaker` + `style` through
   `GET /speakers`.
6. If no valid candidate exists, play the Ping fallback sound.

## Legacy Compatibility (v1)

The helper still accepts the older schema:

```json
{
  "version": 1,
  "speaker": 3,
  "templates": {
    "default": ["cc-status-bar is waiting."]
  }
}
```

Legacy `templates.*` entries are treated as literal strings with no placeholder
expansion.

## Notes

- Nearest parent file wins, so nested worktrees can override speech locally.
- Missing file or invalid JSON does not break alerts; the helper falls back to
  `Ping.aiff`.
