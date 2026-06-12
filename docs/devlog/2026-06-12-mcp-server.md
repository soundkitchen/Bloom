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

## 追記: 描画精度の改善(同日)

実機テストで「エージェントの描く絵の精度が低い」というフィードバック。原因は MCP の不具合ではなく
**エージェントが目隠しで生の座標列を打っている**こと(LLM はピクセル座標の空間推論が苦手で、
描いた結果も見ていない)。3 点を同ブランチで追加実装した:

1. **描画結果の自動返却** — `draw_strokes` の結果に描画直後の縮小プレビュー
   (長辺 400px・`makePNGData(maxDimension:)` を新設)を毎回添付。
   「描く → 見る → 外したら undo」のループが強制的に閉じる
2. **スプライン補間 + 入り抜き** — `BloomCore/StrokePath`(Catmull-Rom・uniform)を新設し、
   制御点 5〜10 個 → 約 2.5pt 間隔の点列に補間(`smooth: false` で無効化可)。
   `pressure_profile`(flat/taper/entry/exit)を正規化弧長で筆圧に乗算。
   80 点必要だった波線が制御点 6 個で描けるようになり、形の破綻も減る
3. **画材レシピの注入** — サーバ `instructions` にウォッシュ/精密な線(sumi)/かすれ払い
   (sumi + exit)等のパラメータレシピと、「大きい要素から先に・こまめにプレビュー確認・
   水彩のにじみは仕様」というワークフロー指針を記載

Catmull-Rom の実装では多項式をひとつの式に書くと Swift の型推論が
`unable to type-check this expression in reasonable time` で破綻するため、項ごとに分割 +
明示的な `Float()` で逃した(SIMD2 と整数リテラル混在の演算子チェーンは要注意)。

検証: テスト 51 件 pass(StrokePath 5 + 縮小 PNG 1 を追加)。E2E で「制御点 6 個 + taper の波線、
4 個 + exit の墨の払い」を描き、なめらかな曲線・末端のかすれ・プレビュー自動添付を目視確認。

## 追記 2: 計器セット(2026-06-13)

「ゴッホのひまわり」の実機テストで、改善後もエージェントの自己修正が利かない場面が残った。
診断は「モデルの細かい空間・色知覚(目)が弱い」こと自体で、これは MCP 側では治せない。
代わりに**目測を計測に置き換える計器**を 3 つ追加した:

1. **`dry_now`(ドライヤー)** — `SimulationEngine.evaporationBoost`(蒸発係数の一時倍率)を新設し、
   25 倍で乾き切るまでポーリング(実測 0.2 秒。自然乾燥は 5〜10 秒)。流れの物理はそのままなので
   エッジダークニングは残り、にじみの成長だけがそこで止まる(実際の水彩のドライヤーと同じ)。
   これで「ウェットプレビューに騙されて乾いたら淡すぎた」が根治し、確認の待ち時間も消えた。
   にじみを育てたい層は従来どおり wait_for_dry(自然乾燥)
2. **`sample_colors`** — 指定座標の表示色(sRGB + hex)を実測で返す(`renderFrameCGImage` の
   ピクセル読み)。「狙った色が出ているか」を目視推定から解放
3. **`snapshot {grid: true}`** — 100pt 間隔の座標グリッド + ラベルを焼き込む
   (`BloomCore/SnapshotGrid`・CoreGraphics + CoreText、AppKit 非依存)。
   「ずれている」を「x=350 のはずが 390」と定量化できる

あわせて、描画セッションが試行錯誤で学んだ水彩のセオリー(**明 → 暗の順で全面に積む**・
**乾燥で大幅に薄まるので主役の pigment は 0.5〜0.75**・**層の前に乾かす**)をサーバの
instructions に還元した。次のセッションは最初からこれを知った状態で始まる。

検証: テスト 54 件 pass(evaporationBoost / sampleColors / グリッドの 3 件を追加)。
E2E で draw → dry_now(0.2 秒で乾燥)→ sample_colors(筆跡 #708dbc / 余白 紙色)→
snapshot {grid}(目盛り焼き込み)を確認。

## 次(M4 残り)

- ⬜ Phase 2: `manage_layer` / `manage_frame` / `save_document` / `load_document`
- ⬜ Phase 3: `export`(PNG/GIF/MP4/スプライト/連番)・`snapshot(frame:)`・ブリッジの自動起動(opt-in)
- ⬜ 将来: ウィンドウ非表示(occlusion)でもシミュレーションを進めるオフスクリーン tick
