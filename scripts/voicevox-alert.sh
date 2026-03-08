#!/bin/bash
set -euo pipefail

VOICE_FILE_NAME=".cc-status-bar.voice.json"
APP_SUPPORT_DIR="${CCSB_APP_SUPPORT_DIR:-$HOME/Library/Application Support/CCStatusBar}"
RUNTIME_CONFIG="${CCSB_VOICEVOX_RUNTIME_CONFIG:-$APP_SUPPORT_DIR/voicevox-runtime.json}"
DEFAULT_BASE_URL="${CCSB_VOICEVOX_ENGINE_BASE_URL:-http://127.0.0.1:50021}"
FALLBACK_SOUND="${CCSB_VOICEVOX_FALLBACK_SOUND:-/System/Library/Sounds/Ping.aiff}"
DEBUG_LOG="${CCSB_VOICEVOX_DEBUG_LOG:-}"

tmp_dir=""

usage() {
  cat <<'EOF'
Usage: voicevox-alert.sh

Reads CCSB_* alert context, resolves the nearest .cc-status-bar.voice.json from
CCSB_CWD upward, resolves a project-local utterance template, synthesizes
speech with VOICEVOX ENGINE, and falls back to
/System/Library/Sounds/Ping.aiff when speech is unavailable.
EOF
}

cleanup() {
  if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
}

trap cleanup EXIT

debug_log() {
  if [ -n "$DEBUG_LOG" ]; then
    printf '%s\n' "$1" >> "$DEBUG_LOG"
  fi
}

play_fallback_sound() {
  debug_log "fallback=1"
  if command -v afplay >/dev/null 2>&1 && [ -f "$FALLBACK_SOUND" ]; then
    afplay "$FALLBACK_SOUND" >/dev/null 2>&1 || true
    return
  fi

  printf '\a' >&2 || true
}

require_tool() {
  command -v "$1" >/dev/null 2>&1
}

json_value_or_empty() {
  local file_path="$1"
  local filter="$2"
  jq -r "$filter // empty" "$file_path" 2>/dev/null || true
}

normalize_tool_key() {
  local raw="${1:-}"
  case "$raw" in
    claude_code|claude|cc) printf 'claude\n' ;;
    codex|cdx) printf 'codex\n' ;;
    *)
      printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]'
      ;;
  esac
}

find_voice_file() {
  local start_path="$1"
  local current_dir

  if [ -z "$start_path" ]; then
    return 1
  fi

  if [ -d "$start_path" ]; then
    current_dir="$start_path"
  else
    current_dir="$(dirname "$start_path")"
  fi

  while true; do
    if [ -f "$current_dir/$VOICE_FILE_NAME" ]; then
      printf '%s\n' "$current_dir/$VOICE_FILE_NAME"
      return 0
    fi

    if [ "$current_dir" = "/" ]; then
      break
    fi

    current_dir="$(dirname "$current_dir")"
  done

  return 1
}

candidate_pool_json() {
  local voice_file="$1"
  local waiting_reason="$2"
  local tool_key="$3"

  jq -c --arg reason "$waiting_reason" --arg tool "$tool_key" '
    def legacy_candidates:
      if $reason == "permission_prompt"
         and (.templates.permission_prompt? | type == "array")
         and ((.templates.permission_prompt | length) > 0)
      then
        .templates.permission_prompt
      elif $reason == "stop"
         and (.templates.stop? | type == "array")
         and ((.templates.stop | length) > 0)
      then
        .templates.stop
      else
        .templates.default
      end;

    def event_candidates:
      if $reason == "permission_prompt"
         and (.events.permission_prompt? | type == "array")
         and ((.events.permission_prompt | length) > 0)
      then
        .events.permission_prompt
      elif $reason == "stop"
         and (.events.stop? | type == "array")
         and ((.events.stop | length) > 0)
      then
        .events.stop
      else
        .events.default
      end;

    if (.events? | type == "object") and (.events.default? | type == "array") then
      (
        event_candidates
        | map(select((.enabled // true) != false))
        | map(select(((.tool // "") == "") or (.tool == $tool)))
      )
    elif (.templates? | type == "object") and (.templates.default? | type == "array") then
      (
        legacy_candidates
        | map({
            id: ("legacy-" + (. | tostring)),
            text: .,
            weight: 1
          })
      )
    else
      []
    end
  ' "$voice_file" 2>/dev/null || printf '[]\n'
}

candidate_count() {
  local candidates_json="$1"
  jq -r 'length' <<<"$candidates_json" 2>/dev/null || printf '0\n'
}

candidate_total_weight() {
  local candidates_json="$1"
  jq -r '[.[].weight // 1] | add // 0' <<<"$candidates_json" 2>/dev/null || printf '0\n'
}

pick_weighted_index() {
  local candidates_json="$1"
  local total_weight="$2"

  if ! [[ "$total_weight" =~ ^[0-9]+$ ]] || [ "$total_weight" -le 0 ]; then
    printf '0\n'
    return 0
  fi

  local draw=$((RANDOM % total_weight))
  local running=0
  local idx=0
  local weight

  while true; do
    weight="$(jq -r --argjson index "$idx" '.[ $index ].weight // 1' <<<"$candidates_json" 2>/dev/null || printf '1\n')"
    if ! [[ "$weight" =~ ^[0-9]+$ ]] || [ "$weight" -le 0 ]; then
      weight=1
    fi
    running=$((running + weight))
    if [ "$draw" -lt "$running" ]; then
      printf '%s\n' "$idx"
      return 0
    fi
    idx=$((idx + 1))
  done
}

candidate_field_or_empty() {
  local candidates_json="$1"
  local template_index="$2"
  local field="$3"
  jq -r --argjson index "$template_index" --arg field "$field" '.[ $index ][ $field ] // empty' <<<"$candidates_json" 2>/dev/null || true
}

default_field_or_empty() {
  local voice_file="$1"
  local field="$2"
  jq -r --arg field "$field" '.defaults[$field] // empty' "$voice_file" 2>/dev/null || true
}

resolve_project_reading() {
  local voice_file="$1"
  local display_name="$2"
  local project_name="$3"
  local reading=""
  reading="$(json_value_or_empty "$voice_file" '.identity.project_reading')"
  if [ -n "$reading" ]; then
    printf '%s\n' "$reading"
    return 0
  fi
  reading="$(json_value_or_empty "$voice_file" '.identity.project_name')"
  if [ -n "$reading" ]; then
    printf '%s\n' "$reading"
    return 0
  fi
  if [ -n "$display_name" ]; then
    printf '%s\n' "$display_name"
    return 0
  fi
  printf '%s\n' "$project_name"
}

resolve_tool_reading() {
  local voice_file="$1"
  local tool_key="$2"
  local reading=""
  reading="$(jq -r --arg tool "$tool_key" '.tool_readings[$tool] // empty' "$voice_file" 2>/dev/null || true)"
  if [ -n "$reading" ]; then
    printf '%s\n' "$reading"
    return 0
  fi
  case "$tool_key" in
    claude) printf 'クロード\n' ;;
    codex) printf 'コーデックス\n' ;;
    *) printf '%s\n' "$tool_key" ;;
  esac
}

resolve_speaker_id_from_names() {
  local base_url="$1"
  local speaker_name="$2"
  local style_name="$3"

  if [ -z "$speaker_name" ]; then
    return 1
  fi

  if [ -z "$tmp_dir" ] || [ ! -d "$tmp_dir" ]; then
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ccsb-voicevox.XXXXXX")"
  fi

  local speakers_json="$tmp_dir/speakers.json"

  if ! curl --silent --show-error --fail --max-time 15 \
    "$base_url/speakers" \
    --output "$speakers_json"; then
    return 1
  fi

  jq -r --arg speaker "$speaker_name" --arg style "$style_name" '
    [
      .[]
      | select(.name == $speaker)
      | .styles[]
      | select(
          if ($style | length) > 0
          then .name == $style
          else true
          end
        )
      | .id
    ][0] // empty
  ' "$speakers_json" 2>/dev/null || true
}

expand_template_text() {
  local template_text="$1"
  local project_reading="$2"
  local tool_reading="$3"
  local voice_gender="$4"
  local callname="$5"
  local display_name="$6"
  local project_name="$7"

  template_text="${template_text//\{project_reading\}/$project_reading}"
  template_text="${template_text//\{tool_reading\}/$tool_reading}"
  template_text="${template_text//\{voice_gender\}/$voice_gender}"
  template_text="${template_text//\{callname\}/$callname}"
  template_text="${template_text//\{display_name\}/$display_name}"
  template_text="${template_text//\{project_name\}/$project_name}"
  printf '%s\n' "$template_text"
}

run_voicevox() {
  local base_url="$1"
  local speaker="$2"
  local text="$3"
  local speed_scale="${4:-}"

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ccsb-voicevox.XXXXXX")"
  local query_json="$tmp_dir/audio-query.json"
  local output_wav="$tmp_dir/output.wav"

  if ! curl --silent --show-error --fail --max-time 15 \
    --request POST \
    --get \
    --data-urlencode "speaker=$speaker" \
    --data-urlencode "text=$text" \
    "$base_url/audio_query" \
    --output "$query_json"; then
    return 1
  fi

  if [ -n "$speed_scale" ]; then
    local adjusted_query="$tmp_dir/audio-query-adjusted.json"
    if ! jq --argjson speed "$speed_scale" '.speedScale = $speed' "$query_json" > "$adjusted_query"; then
      return 1
    fi
    mv "$adjusted_query" "$query_json"
  fi

  if ! curl --silent --show-error --fail --max-time 30 \
    --request POST \
    --header 'Content-Type: application/json' \
    "$base_url/synthesis?speaker=$speaker" \
    --data-binary "@$query_json" \
    --output "$output_wav"; then
    return 1
  fi

  if command -v afplay >/dev/null 2>&1; then
    afplay "$output_wav" >/dev/null 2>&1
    return $?
  fi

  return 1
}

main() {
  case "${1:-}" in
    "")
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac

  if ! require_tool jq || ! require_tool curl; then
    play_fallback_sound
    exit 0
  fi

  local working_dir="${CCSB_CWD:-$PWD}"
  local waiting_reason="${CCSB_WAITING_REASON:-unknown}"
  local source_name="${CCSB_SOURCE:-}"
  local display_name="${CCSB_DISPLAY_NAME:-}"
  local project_name="${CCSB_PROJECT:-}"
  local tool_key
  tool_key="$(normalize_tool_key "$source_name")"
  local base_url="$DEFAULT_BASE_URL"
  local default_speaker=""

  if [ -f "$RUNTIME_CONFIG" ]; then
    local config_base_url
    config_base_url="$(json_value_or_empty "$RUNTIME_CONFIG" '.engine_base_url')"
    if [ -n "$config_base_url" ]; then
      base_url="$config_base_url"
    fi

    default_speaker="$(json_value_or_empty "$RUNTIME_CONFIG" '.default_speaker')"
  fi

  local voice_file=""
  if ! voice_file="$(find_voice_file "$working_dir")"; then
    debug_log "voice_file="
    play_fallback_sound
    exit 0
  fi

  debug_log "voice_file=$voice_file"
  debug_log "tool_key=$tool_key"

  local candidates_json
  candidates_json="$(candidate_pool_json "$voice_file" "$waiting_reason" "$tool_key")"

  local count
  count="$(candidate_count "$candidates_json")"
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -eq 0 ]; then
    play_fallback_sound
    exit 0
  fi

  local total_weight
  total_weight="$(candidate_total_weight "$candidates_json")"
  local index
  index="$(pick_weighted_index "$candidates_json" "$total_weight")"

  local raw_text
  raw_text="$(candidate_field_or_empty "$candidates_json" "$index" "text")"
  if [ -z "$raw_text" ]; then
    play_fallback_sound
    exit 0
  fi

  local project_reading
  project_reading="$(resolve_project_reading "$voice_file" "$display_name" "$project_name")"
  local tool_reading
  tool_reading="$(resolve_tool_reading "$voice_file" "$tool_key")"
  local voice_gender
  voice_gender="$(candidate_field_or_empty "$candidates_json" "$index" "voice_gender")"
  if [ -z "$voice_gender" ]; then
    voice_gender="$(default_field_or_empty "$voice_file" "voice_gender")"
  fi
  local callname
  callname="$(candidate_field_or_empty "$candidates_json" "$index" "callname")"
  if [ -z "$callname" ]; then
    callname="$(default_field_or_empty "$voice_file" "callname")"
  fi
  if [ -z "$callname" ]; then
    callname="$(json_value_or_empty "$voice_file" '.identity.callname')"
  fi

  local text
  text="$(expand_template_text "$raw_text" "$project_reading" "$tool_reading" "$voice_gender" "$callname" "$display_name" "$project_name")"
  if [ -z "$text" ]; then
    play_fallback_sound
    exit 0
  fi

  local speaker=""
  local speaker_name=""
  local style_name=""
  local speed_scale=""
  speaker="$(candidate_field_or_empty "$candidates_json" "$index" "speaker_id")"
  if [ -z "$speaker" ]; then
    speaker="$(default_field_or_empty "$voice_file" "speaker_id")"
  fi
  if [ -z "$speaker" ]; then
    speaker="$(json_value_or_empty "$voice_file" '.speaker')"
  fi
  if [ -z "$speaker" ]; then
    speaker_name="$(candidate_field_or_empty "$candidates_json" "$index" "speaker")"
    if [ -z "$speaker_name" ]; then
      speaker_name="$(default_field_or_empty "$voice_file" "speaker")"
    fi
    style_name="$(candidate_field_or_empty "$candidates_json" "$index" "style")"
    if [ -z "$style_name" ]; then
      style_name="$(default_field_or_empty "$voice_file" "style")"
    fi
    speaker="$(resolve_speaker_id_from_names "$base_url" "$speaker_name" "$style_name" || true)"
  fi
  if [ -z "$speaker" ]; then
    speaker="$default_speaker"
  fi

  speed_scale="$(candidate_field_or_empty "$candidates_json" "$index" "speed_scale")"
  if [ -z "$speed_scale" ]; then
    speed_scale="$(default_field_or_empty "$voice_file" "speed_scale")"
  fi

  if [ -z "$speaker" ]; then
    play_fallback_sound
    exit 0
  fi

  debug_log "base_url=$base_url"
  debug_log "speaker=$speaker"
  debug_log "speaker_name=$speaker_name"
  debug_log "style_name=$style_name"
  debug_log "project_reading=$project_reading"
  debug_log "tool_reading=$tool_reading"
  debug_log "voice_gender=$voice_gender"
  debug_log "callname=$callname"
  debug_log "speed_scale=$speed_scale"
  debug_log "text=$text"
  debug_log "reason=$waiting_reason"

  if ! run_voicevox "$base_url" "$speaker" "$text" "$speed_scale"; then
    play_fallback_sound
    exit 0
  fi
}

main "$@"
