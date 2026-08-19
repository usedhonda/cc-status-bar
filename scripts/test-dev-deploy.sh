#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/dev-deploy.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccsb-dev-deploy-test.XXXXXX")"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

bash -n "$SCRIPT" || fail "dev-deploy.sh has shell syntax errors"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$SCRIPT" || fail "shellcheck rejected dev-deploy.sh"
fi

# Local instructions must not accidentally pull the credential-bearing lane into dev deploy.
if rg -n 'release\.sh|release\.md' "$ROOT_DIR/AGENTS.md" "$ROOT_DIR/README.md" "$SCRIPT"; then
    fail "local deployment instructions mention a release credential surface"
fi
rg -q 'CCSB_DEV_SIGNING_IDENTITY' "$SCRIPT" || fail "explicit identity selector missing"
rg -q 'SIGNER="-"' "$SCRIPT" || fail "ad-hoc fallback missing"
rg -q 'does not mutate TCC' "$SCRIPT" || fail "TCC warning missing"

APP_PATH="$FIXTURE_ROOT/CCStatusBar.app"
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$APP_PATH/Contents/MacOS" "$FAKE_BIN"
cp "$ROOT_DIR/CCStatusBar.app/Contents/Info.plist" "$APP_PATH/Contents/Info.plist"
: > "$APP_PATH/Contents/MacOS/CCStatusBar"

cat > "$FAKE_BIN/swift" <<'EOF'
#!/bin/sh
printf '%s\n' 'Apple Swift version fixture'
EOF

cat > "$FAKE_BIN/codesign" <<'EOF'
#!/bin/sh
case " $* " in
  *" -dvv "*)
    printf '%s\n' 'Executable=fixture' 'Authority=Developer ID Application: Fixture (TEAM)' 'TeamIdentifier=TEAM'
    ;;
  *)
    exit 0
    ;;
esac
EOF

cat > "$FAKE_BIN/security" <<'EOF'
#!/bin/sh
printf '%s\n' '  1) ABCDEF "Developer ID Application: Fixture (TEAM)"'
EOF

cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/bin/sh
printf '%s\n' '12345'
EOF

cat > "$FAKE_BIN/pkill" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$FAKE_BIN/lsof" <<'EOF'
#!/bin/sh
printf '%s\n' 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME'
printf '%s\n' 'CCStatusBar 12345 user 5u IPv4 0x1 0t0 TCP 127.0.0.1:8080 (LISTEN)'
EOF

cat > "$FAKE_BIN/defaults" <<'EOF'
#!/bin/sh
printf '%s\n' '1'
EOF

cat > "$FAKE_BIN/open" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$FAKE_BIN/ditto" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod +x "$FAKE_BIN"/*

before="$(find "$APP_PATH" -type f -exec shasum -a 256 {} \; | sort)"
output="$(
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    CCSB_DEV_DEPLOY_APP_PATH="$APP_PATH" \
    CCSB_DEV_SIGNING_IDENTITY='Developer ID Application: Fixture (TEAM)' \
    "$SCRIPT" --check
)"
after="$(find "$APP_PATH" -type f -exec shasum -a 256 {} \; | sort)"

printf '%s\n' "$output" | rg -q '^mode: check \(read-only\)$' || fail "check mode was not reported"
printf '%s\n' "$output" | rg -q '^installed_signature_class: developer-id$' || fail "signature class fixture not detected"
printf '%s\n' "$output" | rg -q '^available_signing_classes: developer-id,ad-hoc$' || fail "signing classes not reported"
printf '%s\n' "$output" | rg -q '^explicit_identity: available$' || fail "explicit identity availability not reported"
printf '%s\n' "$output" | rg -q '^installed_developer_id_match: available$' || fail "installed Developer ID match not reported"
printf '%s\n' "$output" | rg -q '^process: running' || fail "process fixture not reported"
printf '%s\n' "$output" | rg -q '^port_state: listening' || fail "port fixture not reported"
printf '%s\n' "$output" | rg -q '^check_result: PASS$' || fail "check fixture did not pass"
[[ "$before" == "$after" ]] || fail "--check changed the fixture"

printf 'PASS: dev-deploy syntax, guard tripwires, and read-only check fixture\n'
