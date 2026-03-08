# VOICEVOX v2 Contract

- Updated `scripts/voicevox-alert.sh` to support richer project-local templates in `.cc-status-bar.voice.json`.
- Added support for:
  - `identity`
  - `defaults`
  - `tool_readings`
  - `events`
  - weighted selection
  - tool-specific templates
  - placeholder expansion
  - `speaker_id` or `speaker` + `style` resolution
- Kept legacy `version = 1` compatibility.
- Updated `docs/VOICEVOX_TEMPLATE_CONTRACT.md` and `docs/VOICEVOX.md` to document the new preferred schema.
- Added regression coverage in `scripts/test-voicevox-alert.sh` for:
  - parent search
  - runtime default speaker fallback
  - v2 placeholder expansion and tool filtering
  - invalid/missing config fallback
