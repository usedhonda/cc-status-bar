# VOICEVOX Setup

`cc-status-bar` can speak waiting alerts through VOICEVOX by using the
`Alert Command` helper installed by `scripts/install-voicevox-engine.sh`.

## What Gets Installed

Running `./scripts/install-voicevox-engine.sh` does all of this:

1. Downloads the latest `VOICEVOX ENGINE` macOS arm64 `.vvpp` package from the
   official `VOICEVOX/voicevox_engine` GitHub release.
2. Extracts it into:
   `~/Library/Application Support/CCStatusBar/voicevox-engine/`
3. Creates a LaunchAgent:
   `~/Library/LaunchAgents/com.ccstatusbar.voicevox-engine.plist`
4. Waits for the engine on:
   `http://127.0.0.1:50021`
5. Writes runtime config:
   `~/Library/Application Support/CCStatusBar/voicevox-runtime.json`
6. Copies the alert helper to:
   `~/Library/Application Support/CCStatusBar/bin/voicevox-alert.sh`
7. Enables `Alert Command` in `CCStatusBar` so no manual command entry is needed.

## Install

```bash
./scripts/install-voicevox-engine.sh
```

The installer expects:

- macOS arm64
- `curl`
- `ditto`
- `jq`
- `launchctl`
- `defaults`

## Runtime Paths

- Engine base URL: `http://127.0.0.1:50021`
- Runtime config: `~/Library/Application Support/CCStatusBar/voicevox-runtime.json`
- Helper script: `~/Library/Application Support/CCStatusBar/bin/voicevox-alert.sh`
- LaunchAgent label: `com.ccstatusbar.voicevox-engine`
- Engine logs: `~/Library/Logs/CCStatusBar/voicevox-engine.log`

## Project Speech Files

Project-local speech templates live in:

```text
<project-root>/.cc-status-bar.voice.json
```

The helper starts from `CCSB_CWD` and walks upward until it finds that file.
Nearest match wins.

The exact JSON contract is documented in [VOICEVOX_TEMPLATE_CONTRACT.md](./VOICEVOX_TEMPLATE_CONTRACT.md).

## Recommended Shape

The current preferred contract is `version = 2` with persona-like sections:

- `identity`
  - project name, spoken project name, optional spoken alias, default callname
- `defaults`
  - speaker/style/speed/voice metadata shared by the project
- `tool_readings`
  - `claude` / `codex` readings for spoken notifications
- `events`
  - per-event weighted template pools

This keeps the file close to other project-local character/config files while
remaining easy to read from `shell + jq`.

The helper supports:

- per-event multiple templates
- weighted random selection
- optional tool-specific templates (`claude` / `codex`)
- placeholder expansion:
  - `{project_reading}`
  - `{tool_reading}`
  - `{voice_gender}`
  - `{callname}`
  - `{display_name}`
  - `{project_name}`
- `speaker_id` directly, or `speaker` + `style` name resolution through
  `VOICEVOX ENGINE`
- `speed_scale` to make short notification lines read faster

For spoken names, prefer a single uninterrupted katakana string such as
`シーシーステータスバー` rather than `シーシー ステータス バー` so the line is
spoken in one flow. Do not leave ASCII letters in spoken fields.

The runtime resolves the spoken project name in this order:

1. `identity.alias_spoken`
2. spoken form of `CCSB_DISPLAY_NAME`
3. `identity.project_spoken`
4. `identity.project_reading`
5. spoken form of `identity.project_name`
6. spoken form of `CCSB_PROJECT`

It also applies a final ASCII guard before synthesis, so the final spoken text
must not contain raw English letters.

Legacy `version = 1` files still work, but new project files should use the
`version = 2` contract.

## Example Runtime Config

```json
{
  "engine_base_url": "http://127.0.0.1:50021",
  "default_speaker": 3
}
```

## Alert Command UI

After install, `Alert Command` should already point to:

```bash
'<home>/Library/Application Support/CCStatusBar/bin/voicevox-alert.sh'
```

The `Settings -> Alert Command` editor also shows this path as the suggested
command.

## Troubleshooting

Check that the engine is up:

```bash
curl http://127.0.0.1:50021/version
curl http://127.0.0.1:50021/speakers
```

Restart the LaunchAgent:

```bash
launchctl bootout "gui/$UID" ~/Library/LaunchAgents/com.ccstatusbar.voicevox-engine.plist || true
launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/com.ccstatusbar.voicevox-engine.plist
launchctl kickstart -k "gui/$UID/com.ccstatusbar.voicevox-engine"
```

If speech fails, the helper falls back to:

```text
/System/Library/Sounds/Ping.aiff
```

That fallback also applies when:

- no project speech file exists
- the JSON is invalid
- the file has no usable templates
- the engine is not reachable
- synthesis fails
