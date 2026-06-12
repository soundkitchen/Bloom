# 2026-06-12 — MCP サーバ Phase 1(M4 着手)

M4「コアのコマンドを MCP ツールとして公開」に着手。feature ブランチ `feature/mcp-server`。
Phase 1 として**サーバ基盤 + 描画コアツール 8 種**を実装し、Claude Code からキャンバスにライブで描けるようになった。

## 形態の決定: Pencil.app 型のアプリ内蔵ライブキャンバス

最初の分岐は「エージェントがどこに描くか」。ヘッドレス CLI(独立ドキュメント)も検討したが、
**起動中のアプリのキャンバスをエージェントが直接操作し、描く様子・滲み・乾燥をユーザーがライブで見る**
Pencil.app 型に決めた(ユーザー希望)。接続も「Claude がアプリごと spawn」ではなく
「起動済みアプリに接続」を採用。普段使いのウィンドウがそのまま共同作業の場になる。

```
Claude Code ── stdio ── bloom-mcp(ブリッジ)── Unix ソケット ── Bloom.app 内蔵サーバ
```

- **dumb-pipe 方式**: ブリッジは stdin/stdout ⇄ ソケットの素通しポンプ(約 100 行・依存ゼロ)。
  改行区切り JSON-RPC のフレーミングすら解釈しない。MCP のプロトコル処理は 100% アプリ内 →
  SDK のバージョンに依存するのがアプリだけになり、プロトコルの二重実装を避けられる
- **SDK**: 公式 [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) 0.12.1(0.x のため
  `project.yml` で `exactVersion` 固定)。idea.md の懸念「SDK の若さ」は解消 — stdio サーバ・
  image content とも実用水準だった

## やったこと

### 1. BloomCore に 2 つの最小 API(SDK 非依存は維持)

- `makePNGData() throws -> Data` — `renderFrameCGImage()` の PNG Data 化(`savePNG` はこれ経由に)。
  snapshot ツールが base64 で返すのに使う
- `wetFraction: Float` — W バッファ(`storageModeShared`)を CPU 走査して
  「濡れているセル(`W > wetThreshold`)の面積比」を返す。GPU 書き込み中の読みは許容
  (乾燥待ちのヒューリスティック用途には十分)。ユニットテスト 2 件追加(計 45 件)

### 2. アプリ内蔵サーバ(BloomApp/)

- `MCPSocketListener` — `~/Library/Application Support/Bloom/mcp.sock`(0600・`BLOOM_MCP_SOCKET`
  で上書き可)で待ち受け。POSIX ソケット + DispatchSource の accept。残骸ソケットは接続プローブで
  判定(拒否→unlink、応答→別インスタンス生存として MCP 無効化 + ステータスバー表示)
- `MCPServerController`(@MainActor)— 接続ごとに新しい `Server` を作り `waitUntilCompleted` で
  切断まで面倒を見る(再接続可)。同時 2 本目は即 close(単一クライアント)。
  **トランスポートは SDK の `StdioTransport` を接続済みソケット fd に被せて流用** —
  任意の fd ペアで動く改行区切り JSON-RPC なので、当初予定していたカスタム Transport 実装が
  まるごと不要になった
- `MCPTools` — ツール定義(JSON スキーマ)と実装。エンジン操作は全部 @MainActor。
  undo/ブラシ変更は `CanvasView` のラッパー経由(インスペクタ・タイムラインの UI 同期が既存経路で付いてくる)
- 通常起動で常時オン(`--no-mcp` で無効化、`--demo` 系では起動しない)。接続状態はステータスバー右端に表示

### 3. ツール 8 種(Phase 1)

`get_canvas_info` / `set_brush` / `draw_strokes` / `wait_for_dry` / `snapshot` / `clear` / `undo` / `redo`。

- **`draw_strokes` のペーシング**が肝: サンプルを 3 点ずつ投入して 8ms 待つ。
  一括投入だと `maxStampsPerFrame`(1024)超過分が**黙って捨てられる**(`appendStamp` の guard)ため。
  チャンク間の `Task.sleep` は main をブロックしないので MTKView の描画(= シミュレーション進行)は
  止まらず、副産物として「線が生えていく」ライブ感が出る
- ストロークはスタビライザを通さず engine 直(MCP の座標は意図された座標)。1 ストローク = 1 undo 単位
- MCP 描画中は `CanvasView.isExternallyDrawing` でマウス入力をガード(ストローク状態の混線防止)
- `wait_for_dry` は `wetFraction` を 250ms ポーリング。タイムアウトしても isError にせず実測値 +
  ヒント(「ウィンドウが隠れるとシミュレーションが止まる」)を返す — エージェント側で判断できる

### 4. 配線・検証

- `.mcp.json`(プロジェクトスコープ)→ `scripts/bloom-mcp`(sh ラッパー)→ ビルド済みブリッジ。
  DerivedData パスは Makefile が固定しているのでラッパーで足りる(install 工程なし)
- `make mcp-smoke` — Claude 不要の疎通テスト。専用ソケットでアプリを起動し、
  initialize / tools/list / tools/call(get_canvas_info)を流して応答を grep 検証

## 判断・ハマりどころ

- **ブリッジのポインタバグ**: `write(dst, &buf[off], n - off)` は「配列要素 1 個の一時コピー」への
  ポインタになり、2 バイト目以降がスタックのゴミになる(initialize 応答の先頭 `{` だけ正しく、
  残りが化けて発覚)。`buf.withUnsafeBytes { write(dst, raw.baseAddress! + off, n - off) }` が正解
- **`connect` 成功 ≠ accept 済み**: listen の backlog に積まれた接続でも `connect` は成功するので、
  ブリッジの「接続しました」はサーバ稼働の証拠にならない(デバッグ時の教訓)
- **ツール定義の actor 分離**: `BloomMCPTools.all`(ツール一覧)は @MainActor 型の中の不変値だが、
  SDK のハンドラ(非 main)から参照するので `nonisolated static let` にする
- アプリ側ツールロジック(引数パース等)のユニットテストは見送り(BloomApp にテストターゲットが無い)。
  必要になったらパース部を純関数に切り出して BloomAppTests を新設する

## 検証

- `make test` 45 件 pass(既存 43 + MCPSupportTests 2)
- `make mcp-smoke` OK(initialize / tools/list / tools/call すべて応答)
- E2E: ブリッジ経由で「水彩の波線 + 墨の払い(一時ブラシ上書き)を draw_strokes → wait_for_dry →
  snapshot」を実行。返ってきた PNG にエッジダークニング付きの波線とかすれた払いが写っていることを目視確認

## 次(M4 残り)

- ⬜ Phase 2: `manage_layer` / `manage_frame` / `save_document` / `load_document`
- ⬜ Phase 3: `export`(PNG/GIF/MP4/スプライト/連番)・`snapshot(frame:)`・ブリッジの自動起動(opt-in)
- ⬜ 将来: ウィンドウ非表示(occlusion)でもシミュレーションを進めるオフスクリーン tick
