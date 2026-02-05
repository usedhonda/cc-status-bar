# CC Status Bar: Chrome拡張ブリッジ設計メモ

目的: Playwright MCP extension2 と同等の仕組みで、ユーザーの日常Chromeにタブ追加しつつ、ローカルのCC Status Barプロセスから制御できる仕組みを作る。

本メモは /Users/usedhonda/projects/public/playwright-mcp/packages/extension2 を調査した結果の要約と、CC Status Bar向けに最小構成で実装する案をまとめたもの。

---

## 1. extension2 の仕組み（要点）

ファイル構成:
- manifest.json (MV3, debugger/tabs/storage権限)
- lib/background.mjs (service worker)
- connect.html / status.html + lib/ui/*.js (UI)

動作フロー（要約）:
1) UIから「MCP relay URL (ws://127.0.0.1:XXXX/...)」へ接続
2) background が WebSocket を開く
3) ユーザーが接続対象タブを選択
4) background が chrome.debugger.attach(tabId, "1.3")
5) MCP relay から来た CDP コマンドを chrome.debugger.sendCommand に転送
6) debuggerイベントを WS で relay に返す

キーポイント:
- chrome.debugger で CDP の Proxy になっている
- relay 側は「WS で CDP 相当のコマンドを受けるサーバ」として実装される
- タブ選択は extension 側 UI から手動
- loopback(127.0.0.1)のみ許可する安全措置あり

---

## 2. CC Status Bar向けに作るべき最小構成

### 2.1 目的の整理
- Playwrightのような「CDP over WebSocket」相当の制御経路を、
  CC Status Barプロセス(ローカル)に向けて張る
- 既存のユーザーChromeに追加タブとして拡張UIを出し、
  そこからタブ選択と接続を行う

### 2.2 最小アーキテクチャ

```
[CC Status Bar] <--WS/CDP--> [Chrome Extension Service Worker] <--chrome.debugger--> [Target Tab]
                                    ^
                                    |
                             [Connect UI Tab]
```

- Extension側: extension2と同様の「TabShare」機構
- CC Status Bar側: WSサーバ（CDP Proxy）
  - 例: ws://127.0.0.1:PORT/cc-bridge
  - 接続後に CDP コマンドを受け、結果を返す

---

## 3. 具体的な実装ステップ（最小）

### 3.1 Extension (MV3)
- extension2 をベースにし、名称/アイコン/説明を変更
- connect.html, status.html を最小構成に整理
- security: 127.0.0.1 以外は拒否

最低限の必要権限:
- debugger
- tabs
- activeTab
- storage (任意)

### 3.2 CC Status Bar側 (ローカルWSサーバ)
- 127.0.0.1 上で WebSocket サーバを起動
- 受け取るメッセージ形式は extension2 と同一でも可
  - method: "attachToTab" / "forwardCDPCommand"
  - response: { id, result | error }
- 受け取った command を "実際の制御系" に変換して実行
  - 例: CDPのネットワーク/DOM操作を最小対応する

### 3.3 通信仕様 (最小)
- Extension -> CC Status Bar
  - attachToTab
  - forwardCDPCommand (method, params, sessionId)
- CC Status Bar -> Extension
  - response (id, result)
  - error (id, error)

---

## 4. 実装時に注意すべき制約

- chrome.debugger はタブごとに1接続のみ
- chrome:// や edge://, devtools:// などは attach 不可
- ユーザーの許可操作が必須
  - 拡張UIから手動選択
- Service Worker は停止する可能性がある
  - WS 接続が切れたら再接続が必要

---

## 5. CC Status Bar向けの現実的な落とし所

### 5.1 コード量を抑えるなら
- extension2 をそのままベースにし、UIだけ簡略化
- CC Status Bar側は「WS で受けた CDP コマンドをログ出力するだけ」の最小実装から始める
- 最低限の CDP コマンド (Page.navigate / Runtime.evaluate など) だけ対応

### 5.2 メニューアプリとの統合
- CC Status Bar の設定画面から「WS URL」を表示
- 拡張UIで URL を入力し接続
- 接続済みタブがある場合はバッジ表示

---

## 6. 次に作るなら

- extension2 からコピーする最小ファイルセットを切り出す
- CC Status Bar側に WS サーバを追加
- まずは "Page.navigate" だけ動くPoCを作る

---

## 付録: extension2 で確認したポイント

- background.mjs が relay/Tab接続/Chrome debugger attach を全部担う
- UI は connect/status の2画面のみ
- ローカル loopback のみ許可するガードが入っている

