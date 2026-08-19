## Local Development Deployment

`scripts/dev-deploy.sh` is the only supported local CCStatusBar deployment
entrypoint for every agent and developer.

```bash
# Read-only preflight; no build, copy, signing, restart, or TCC mutation.
./scripts/dev-deploy.sh --check

# Release-config build, staged bundle signing, one bounded restart, and health check.
./scripts/dev-deploy.sh
```

The entrypoint selects signing deterministically:

1. Use `CCSB_DEV_SIGNING_IDENTITY` when that non-secret identity name is
   available.
2. Otherwise preserve the installed app's Developer ID class when its matching
   identity is available.
3. Otherwise use ad-hoc signing so missing Developer ID certificates do not
   block local development.

Ad-hoc signing may cause macOS TCC permissions (Accessibility or Input
Monitoring) not to follow the previous build. The script warns about this and
never changes TCC state. It preserves the bundle identifier and entitlements,
stages and verifies the bundle before stopping the app, and restores the prior
bundle if launch health fails. It never reads release credentials, notarizes,
uploads, or performs release work.

Do not run manual `swift build`, bundle-copy, `codesign`, `pkill`, or `open`
sequences for local deployment. Use `--check` first when diagnosing a machine.

## Mandatory After Runtime Code Changes

After a runtime code change, run the canonical local deployment entrypoint and
include its process/port result in the report:

```bash
./scripts/dev-deploy.sh --check
./scripts/dev-deploy.sh
```

Run focused tests during iteration. The broad test/build gate is:

```bash
swift test -Xswiftc -warnings-as-errors
swift build
```

## Release Boundary

Release and notarization are a separate credential-bearing lane. Do not use
that lane for local development, and do not copy its credentials into this
repository or into agent instructions. Credential cleanup and rotation for
that lane is a separate P0 security task and is out of scope here.
