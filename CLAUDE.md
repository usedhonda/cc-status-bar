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

### Mandatory After Every Runtime Code Change

実装後に「指示されなくても」以下を必ず実施する（省略禁止）:

```bash
# A. Build + reload
swift build
pkill -x CCStatusBar; sleep 0.5
cp .build/debug/CCStatusBar CCStatusBar.app/Contents/MacOS/
codesign --force --deep --sign "Developer ID Application: Yuzuru Honda (F588423ZWS)" CCStatusBar.app
open CCStatusBar.app

# B. Process verification
pgrep -lf CCStatusBar | head
```

完了報告には、最低限 `swift test` の pass/fail と起動プロセス確認結果を含めること。

## Release

リリースは `scripts/release.sh` で一発実行。手作業で個別コマンドを叩かない。

```bash
# ビルド＆公証のみ（ローカル確認用）
./scripts/release.sh

# ビルド＆公証＆GitHub Release 作成
./scripts/release.sh --publish
```

スクリプトが自動でやること: テスト → release ビルド → 署名 → DMG → 公証 → staple → Stream Deck plugin → GitHub Release
