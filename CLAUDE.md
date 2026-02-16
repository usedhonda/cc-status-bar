<!-- CDX-PERSONA-AGENTS -->
**Read `.codex/config.toml` in this directory and adopt the persona in its `instructions` field.**
<!-- CDX-PERSONA-AGENTS-END -->

## Dev Build & Reload

**重要: ad-hoc 署名 (`--sign -`) は絶対に使わない。TCC 権限（Accessibility, Input Monitoring）が壊れて CGEventTap 等が機能しなくなる。**

```bash
# 1. ビルド
swift build

# 2. バイナリコピー + Developer ID 署名 + リランチ
pkill -x CCStatusBar; sleep 0.5
cp .build/debug/CCStatusBar CCStatusBar.app/Contents/MacOS/
codesign --force --deep --sign "Developer ID Application: Yuzuru Honda (F588423ZWS)" CCStatusBar.app
open CCStatusBar.app
```

- Developer ID 署名なら TCC 権限がリビルドで壊れない
- release.sh はリリース用（notarize含む）。開発中は上記手順で十分
