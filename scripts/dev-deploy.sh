#!/usr/bin/env bash
set -Eeuo pipefail

# Canonical local development deployment. This script never performs release,
# notarization, upload, or credential setup work.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="${CCSB_DEV_DEPLOY_APP_PATH:-$ROOT_DIR/CCStatusBar.app}"
ENTITLEMENTS_PATH="$ROOT_DIR/CCStatusBar.entitlements"
PROCESS_NAME="CCStatusBar"
PORT_BASE="${CCSB_DEV_PORT_BASE:-8080}"
PORT_ATTEMPTS="${CCSB_DEV_PORT_ATTEMPTS:-10}"
BACKUP_ROOT=""
ORIGINAL_INSTALLED_APP=""
STAGED_APP=""
SWAP_DONE=0

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

usage() {
    cat <<'EOF'
Usage: scripts/dev-deploy.sh [--check]

Modes:
  --check  Read-only prerequisite, signature, process, and port inspection.
  default  Build, stage, sign, install, launch, and verify the local app.

Optional environment:
  CCSB_DEV_SIGNING_IDENTITY  Non-secret signing identity name to prefer.
  CCSB_DEV_DEPLOY_APP_PATH   App bundle path; defaults to ./CCStatusBar.app.
  CCSB_DEV_PORT_BASE         First port to inspect; defaults to 8080.
  CCSB_DEV_PORT_ATTEMPTS     Number of ports to inspect; defaults to 10.
EOF
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
}

signature_details() {
    local app_path="$1"
    codesign -dvv "$app_path" 2>&1 || true
}

signature_class() {
    local app_path="$1"
    local details

    if [[ ! -d "$app_path" ]]; then
        printf 'not-found'
        return
    fi

    details="$(signature_details "$app_path")"
    if [[ "$details" == *"Authority=Developer ID Application:"* ]]; then
        printf 'developer-id'
    elif [[ "$details" == *"Authority="* ]]; then
        printf 'other-signed'
    elif [[ "$details" == *"Signature=adhoc"* || "$details" == *"adhoc"* ]]; then
        printf 'ad-hoc'
    else
        printf 'unsigned-or-invalid'
    fi
}

developer_identity_from_signature() {
    local app_path="$1"
    signature_details "$app_path" | sed -n 's/^Authority=//p' | grep -F 'Developer ID Application:' | head -n 1
}

available_identity_list() {
    security find-identity -v -p codesigning 2>/dev/null || true
}

identity_available() {
    local identity="$1"
    [[ -n "$identity" ]] || return 1
    available_identity_list | grep -Fq "\"$identity\""
}

available_signing_classes() {
    local identities
    local classes=()

    identities="$(available_identity_list)"
    if [[ "$identities" == *"Developer ID Application:"* ]]; then
        classes+=(developer-id)
    fi
    if [[ "$identities" == *"Apple Development:"* || "$identities" == *"Mac Developer:"* ]]; then
        classes+=(development)
    fi
    classes+=(ad-hoc)
    (IFS=,; printf '%s' "${classes[*]}")
}

bundle_identifier() {
    plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

entitlement_value() {
    local plist_path="$1"
    plutil -extract com.apple.security.app-sandbox raw -o - "$plist_path" 2>/dev/null || true
}

web_server_preference() {
    defaults read com.ccstatusbar.app webServerEnabled 2>/dev/null || true
}

list_listening_ports() {
    local last_port=$((PORT_BASE + PORT_ATTEMPTS - 1))
    { lsof -nP -a -c "$PROCESS_NAME" -iTCP:"$PORT_BASE"-"$last_port" -sTCP:LISTEN 2>/dev/null || true; } \
        | awk 'NR > 1 { print $9 }' \
        | tr '\n' ' ' \
        | sed 's/[[:space:]]*$//'
}

process_count() {
    local pids
    pids="$(pgrep -x "$PROCESS_NAME" 2>/dev/null || true)"
    if [[ -z "$pids" ]]; then
        printf '0'
    else
        printf '%s\n' "$pids" | wc -l | tr -d ' '
    fi
}

print_port_state() {
    local preference
    local ports

    preference="$(web_server_preference)"
    ports="$(list_listening_ports)"

    if [[ "$preference" == "0" ]]; then
        printf 'port_state: disabled (web server setting is off)\n'
    elif [[ -n "$ports" ]]; then
        printf 'port_state: listening (%s)\n' "$ports"
    elif [[ "$preference" == "1" ]]; then
        printf 'port_state: expected-listening-but-missing\n'
    else
        printf 'port_state: not-detected (web server setting unknown)\n'
    fi
}

run_check() {
    local missing=0
    local tool
    local tools=(swift codesign security plutil pgrep pkill lsof defaults open ditto)
    local installed_class
    local available_classes
    local explicit_status="not-set"
    local explicit_identity="${CCSB_DEV_SIGNING_IDENTITY:-}"
    local installed_identity=""
    local bundle_id=""
    local count

    printf 'mode: check (read-only)\n'
    printf 'app_path: %s\n' "$APP_PATH"

    for tool in "${tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf 'prerequisite_%s: available\n' "$tool"
        else
            printf 'prerequisite_%s: missing\n' "$tool"
            missing=1
        fi
    done

    if command -v swift >/dev/null 2>&1; then
        printf 'swift_version: %s\n' "$(swift --version 2>/dev/null | head -n 1 || printf 'unknown')"
    fi

    installed_class="$(signature_class "$APP_PATH")"
    printf 'installed_signature_class: %s\n' "$installed_class"
    available_classes="$(available_signing_classes)"
    printf 'available_signing_classes: %s\n' "$available_classes"

    if [[ -n "$explicit_identity" ]]; then
        if identity_available "$explicit_identity"; then
            explicit_status="available"
        else
            explicit_status="unavailable"
        fi
    fi
    printf 'explicit_identity: %s\n' "$explicit_status"

    if [[ -d "$APP_PATH" ]]; then
        bundle_id="$(bundle_identifier "$APP_PATH")"
        printf 'bundle_identifier: %s\n' "${bundle_id:-unknown}"
        if [[ "$installed_class" == "developer-id" ]]; then
            installed_identity="$(developer_identity_from_signature "$APP_PATH")"
            if identity_available "$installed_identity"; then
                printf 'installed_developer_id_match: available\n'
            else
                printf 'installed_developer_id_match: unavailable\n'
            fi
        else
            printf 'installed_developer_id_match: not-applicable\n'
        fi
    else
        printf 'bundle_identifier: missing-app\n'
        missing=1
    fi

    count="$(process_count)"
    if [[ "$count" == "0" ]]; then
        printf 'process: stopped\n'
    else
        printf 'process: running (%s process(es))\n' "$count"
    fi
    print_port_state

    if (( missing != 0 )); then
        printf 'check_result: FAIL (install missing prerequisites before local deployment)\n'
        return 1
    fi
    printf 'check_result: PASS\n'
}

wait_for_process_absent() {
    local attempt=1
    while (( attempt <= 20 )); do
        if [[ "$(process_count)" == "0" ]]; then
            return 0
        fi
        sleep 0.25
        attempt=$((attempt + 1))
    done
    return 1
}

wait_for_process() {
    local attempt=1
    while (( attempt <= 20 )); do
        if [[ "$(process_count)" != "0" ]]; then
            return 0
        fi
        sleep 0.25
        attempt=$((attempt + 1))
    done
    return 1
}

port_health_is_ok() {
    local preference
    local ports

    preference="$(web_server_preference)"
    ports="$(list_listening_ports)"
    if [[ "$preference" == "0" || -z "$preference" ]]; then
        return 0
    fi
    [[ -n "$ports" ]]
}

cleanup_backup() {
    local temp_root="${TMPDIR:-/tmp}"
    if [[ -n "$BACKUP_ROOT" && "$BACKUP_ROOT" == "$temp_root"/ccstatusbar-dev-deploy.* ]]; then
        rm -rf -- "$BACKUP_ROOT"
    fi
}

rollback_app() {
    if (( SWAP_DONE == 0 )); then
        return
    fi

    if [[ "$(process_count)" != "0" ]]; then
        pkill -x "$PROCESS_NAME" || true
        wait_for_process_absent || true
    fi
    mv "$APP_PATH" "$BACKUP_ROOT/failed.app"
    mv "$ORIGINAL_INSTALLED_APP" "$APP_PATH"
    SWAP_DONE=0
}

choose_signer() {
    local installed_class
    local installed_identity
    local explicit_identity="${CCSB_DEV_SIGNING_IDENTITY:-}"

    SIGNER="-"
    SIGNING_CLASS="ad-hoc"

    if [[ -n "$explicit_identity" ]] && identity_available "$explicit_identity"; then
        SIGNER="$explicit_identity"
        SIGNING_CLASS="explicit"
    else
        if [[ -n "$explicit_identity" ]]; then
            warn "CCSB_DEV_SIGNING_IDENTITY is unavailable; using deterministic fallback."
        fi
        installed_class="$(signature_class "$APP_PATH")"
        if [[ "$installed_class" == "developer-id" ]]; then
            installed_identity="$(developer_identity_from_signature "$APP_PATH")"
            if identity_available "$installed_identity"; then
                SIGNER="$installed_identity"
                SIGNING_CLASS="preserved-developer-id"
            fi
        fi
    fi

    if [[ "$SIGNER" == "-" ]]; then
        warn "Using ad-hoc signing. macOS TCC permissions may not follow this build; this script does not mutate TCC."
    fi
}

deploy() {
    local binary_path
    local bin_dir
    local bundle_id_before
    local bundle_id_after
    local expected_sandbox
    local actual_sandbox
    local signed_entitlements
    local was_running=0

    for tool in swift codesign security plutil pgrep pkill lsof defaults open ditto; do
        require_command "$tool"
    done
    [[ -d "$APP_PATH" ]] || die "app bundle not found: $APP_PATH"
    [[ -f "$APP_PATH/Contents/Info.plist" ]] || die "app Info.plist not found: $APP_PATH"
    [[ -f "$ENTITLEMENTS_PATH" ]] || die "entitlements file not found: $ENTITLEMENTS_PATH"

    printf 'build: swift release\n'
    swift build -c release
    bin_dir="$(swift build -c release --show-bin-path)"
    binary_path="$bin_dir/CCStatusBar"
    [[ -x "$binary_path" ]] || die "release binary not found: $binary_path"

    bundle_id_before="$(bundle_identifier "$APP_PATH")"
    [[ -n "$bundle_id_before" ]] || die "could not read existing bundle identifier"
    choose_signer
    printf 'signing_class: %s\n' "$SIGNING_CLASS"

    BACKUP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccstatusbar-dev-deploy.XXXXXX")"
    trap cleanup_backup EXIT
    ORIGINAL_INSTALLED_APP="$BACKUP_ROOT/original.app"
    STAGED_APP="$BACKUP_ROOT/staged.app"
    ditto "$APP_PATH" "$ORIGINAL_INSTALLED_APP"
    ditto "$APP_PATH" "$STAGED_APP"
    # The tracked bundle carries only Info.plist and Resources; the executable is a
    # build product, and git cannot track the empty Contents/MacOS directory that
    # holds it. Create the directory instead of assuming the staged copy already has
    # one, otherwise a freshly cloned checkout dies here before signing.
    mkdir -p "$STAGED_APP/Contents/MacOS"
    cp "$binary_path" "$STAGED_APP/Contents/MacOS/CCStatusBar"

    codesign --force --deep --entitlements "$ENTITLEMENTS_PATH" --sign "$SIGNER" "$STAGED_APP"
    codesign --verify --deep --strict "$STAGED_APP"

    bundle_id_after="$(bundle_identifier "$STAGED_APP")"
    [[ "$bundle_id_after" == "$bundle_id_before" ]] || die "bundle identifier changed during staging"
    expected_sandbox="$(entitlement_value "$ENTITLEMENTS_PATH")"
    signed_entitlements="$BACKUP_ROOT/signed-entitlements.plist"
    codesign -d --entitlements :- "$STAGED_APP" > "$signed_entitlements" 2>/dev/null
    actual_sandbox="$(entitlement_value "$signed_entitlements")"
    [[ -n "$expected_sandbox" && "$actual_sandbox" == "$expected_sandbox" ]] \
        || die "app sandbox entitlement was not preserved"

    if [[ "$(process_count)" != "0" ]]; then
        was_running=1
        pkill -x "$PROCESS_NAME" || true
        wait_for_process_absent || die "existing process did not stop within bounded wait"
    fi

    mv "$APP_PATH" "$BACKUP_ROOT/old-location.app"
    if ! mv "$STAGED_APP" "$APP_PATH"; then
        mv "$BACKUP_ROOT/old-location.app" "$APP_PATH"
        die "could not install staged app bundle; original bundle restored"
    fi
    ORIGINAL_INSTALLED_APP="$BACKUP_ROOT/old-location.app"
    SWAP_DONE=1

    printf 'launch: one bounded restart (previously_running=%s)\n' "$was_running"
    open "$APP_PATH"
    if wait_for_process && port_health_is_ok; then
        printf 'process_health: PASS\n'
        print_port_state
        SWAP_DONE=0
        printf 'deploy_result: PASS\n'
        return 0
    fi

    warn "launch health failed; restoring the previous app bundle."
    rollback_app
    printf 'deploy_result: FAIL (original app restored; previous process was not relaunched)\n' >&2
    return 1
}

main() {
    case "${1:-}" in
        "") deploy ;;
        --check) [[ "$#" -eq 1 ]] || die "--check does not accept extra arguments"; run_check ;;
        -h|--help) usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"
