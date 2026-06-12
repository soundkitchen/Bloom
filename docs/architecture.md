# Bloom アーキテクチャ

コードの「現在形」を説明する生きたドキュメント。経緯は [devlog](devlog/)、構想は [idea.md](idea.md)、ユーザー向けの使い方は [guide.md](guide.md) を参照。

## 全体構成

```
BloomApp(.app / AppKit + MetalKit)─ 薄い殻
  ├─ AppDelegate       ウィンドウ構成・メニュー・再生タイマー(通常起動 / 検証モードで分岐)
  ├─ CanvasView        MTKView。入力 → コア API、毎フレーム描画
  ├─ InspectorView     右パネル(ブラシ設定 GUI、レイヤーリスト)
  ├─ TimelineView      下帯(フレーム選択・追加/複製/削除・再生・オニオン・fps)
  ├─ MCPServerController / MCPSocketListener / MCPTools
  │                    アプリ内蔵 MCP サーバ(swift-sdk・Unix ソケット待ち受け)→「MCP サーバ」節
  └─ BloomCore(.framework / AppKit 非依存)─ 本体
       ├─ SimulationEngine   滲みシミュレーション + レイヤー/フレーム + 描画(Metal compute)
       ├─ AnimationExport     GIF / スプライトシート / PNG 連番(extension)
       ├─ Simulation.metal    カーネル群(framework の default.metallib にコンパイル)
       ├─ InputSample         入力抽象 + 擬似筆圧
       └─ StrokeStabilizer    手ブレ補正(プルストリング方式)

bloom-mcp(CLI / 依存ゼロ)─ Claude Code が spawn する stdio ブリッジ(BloomMCPBridge/)
```

### アプリの UI 構成

通常起動は **中央キャンバス + 右インスペクタ + 下タイムライン + 最下部ステータスバー**(手動フレームレイアウト、ウィンドウ固定サイズ)。

- `CanvasView` と `InspectorView` はクロージャで疎結合: `canvas.onStatus`/`onBrushChanged`/`onLayersChanged` ↔ `inspector.onSelectBrush`/`onSizeChange`/`onWaterChange`/`onStabilizeChange`/`onColorChange`/`onClear`/`onAddLayer`/`onDeleteLayer`/`onSelectLayer`/`onToggleLayer`。キー操作(`1`/`2`/`[`/`]`)とスライダは双方向に同期する
- インスペクタの中身: ブラシ切替・カラーウェル(任意色)・サイズ/水量スライダ・**手ブレ補正スライダ**(ブラシ非依存のグローバル入力設定)・**レイヤーリスト(NSTableView)**(目アイコンで表示切替、選択でアクティブ化、**行の D&D で並べ替え** → `moveLayer`、＋/🗑 で追加削除)・選択層の不透明スライダ・クリア
- レイヤーリストは `reflectLayers` でエンジン状態を反映。プログラム選択時の `selectionDidChange` ループは `isReflecting` フラグで抑止
- **編集メニュー**: 取り消す(Cmd+Z)/ やり直す(Cmd+Shift+Z)。`validateMenuItem` で `canUndo`/`canRedo` に応じて有効化
- **ファイルメニュー**: 開く(Cmd+O)/ 保存(Cmd+S)/ 別名で保存(Cmd+Shift+S)/ PNG(Cmd+E)/ GIF(Cmd+G)/ スプライトシート(Cmd+Shift+G)/ PNG 連番 を書き出す。NSOpenPanel/NSSavePanel
- **フレームメニュー**: 新規フレーム(Cmd+Shift+N)/ 複製(Cmd+Shift+D)/ 削除 / 前(Cmd+,)/ 次(Cmd+.)/ 再生切替(Cmd+P)
- **タイムライン**(`TimelineView`): フレーム帯(クリックで `goToFrame`)・再生/停止・前後送り・＋複製🗑・オニオン切替・fps。`AppDelegate` が `playTimer`(fps 間隔)で `stepFrameLooping` を回す。再生中は `CanvasView.isPlaying` で描画入力を無効化
- **検証モード**(`--demo` 系)はキャンバス全面の素のウィンドウにして、スナップショットにインスペクタ等が写り込まないようにする
- エンジンのグリッドは生成時のキャンバスサイズで固定(ウィンドウは非リサイズ)

設計原則([idea.md](idea.md) のアーキテクチャ初期方針):

1. **UI とコアの分離** — BloomCore はヘッドレスで動く。アプリは入力イベントをコアの API(`beginStroke` / `addStrokeSample` / `endStroke` / `clear` / `renderFrame`)に変換するだけ。MCP サーバ(下記)もこの同じ API を叩く
2. **入力のデバイス非依存** — タブレット・マウス・プログラム生成(デモ / MCP)すべて `InputSample(position, pressure)` に正規化される

## 滲みシミュレーション

グリッド(キャンバス等倍、セル = pt)上に 4 つの場を持つ:

| 場 | 型 | 意味 | 更新 |
|---|---|---|---|
| `W` | float | 水量 | 毎 substep |
| `P` | float3 | 浮遊顔料(水に乗って動く)。RGB 各チャンネルの吸光度 | 毎 substep |
| `D` | float3 | 沈着顔料(乾いた絵そのもの)。= トラックのフレームごとのセル | 蒸発時に増える |
| `H` | float | 紙の凹凸(2 オクターブ値ノイズ) | 静的 |

顔料は **RGB 吸光度**(float3)。ブラシの色は `K = -ln(color)` で吸光度に変換してスタンプ時に積む。異なる色が重なると吸光度が加算される = **減法混色**。流れ方・乾き方はチャンネル共通の物理に乗る。

毎フレーム `dwell → stamp → (flow → dry) × 3 substeps → render` の順で実行:

- **ドウェル供給(emitDwellStamp)** — 筆を下ろしている間(`activeDab != nil`)、動かさなくても毎フレーム現在位置へ少量の水・顔料を継ぎ足す。止めたまま置くと溜まりが育ち、乾くと縁が濃い輪っか(ブルーム)が出る = 実際の筆の挙動。`beginStroke`〜`endStroke` の間だけ有効。移動中は最新のペン位置へ供給されるので筆跡にも乗る。フレームレート依存(120fps 前提)は将来課題
- **stampKernel** — ブラシスタンプ。筆圧が半径と水・顔料量に効く。四次フォールオフ。`dryness` が高いと被覆が割れて **かすれ**(ドライブラシ)になる: ①紙の凸部(H 高)にだけ乗る粒状の下地 + ②進行方向 `dir` に沿った**毛筋**(直交座標の周期縞・紙で位相を乱す)。`dryness` でこの割れた被覆へ寄せる(floor を残して線が切れすぎないようにする)。実効 `dryness` は筆圧で動く(下の入力節)
- **flowKernel** — 水頭 `W + paperInfluence·H` の隣接差分で水が移動し、顔料を運ぶ。乾いたセル(`W ≤ wetThreshold`)からは流れない = ピン留めで硬いエッジができる。対称な流量制限(`min(f, w·0.2)`)で質量保存。W/P はピンポンバッファ
- **dryKernel** — 蒸発。濡れた隣接セルが少ない「縁」ほど速く乾く(`edgeEvapBoost`)→ エッジダークニングの源。失われた水の割合に応じて P → D へ沈着し、紙の谷(H 低)ほど多く沈着(`granulation`)
- **renderKernel** — 紙を底に、下層 → アクティブ層(`D` + ウェット `P`)→ 上層 のアフィングレーズ変換を順に適用(下の「レイヤー / タイムライン」節)。オニオン有効時は前フレームを薄く重ねる。バイリニア補間で drawable 解像度へ

### ブラシプリセット(SimulationEngine.Brush)

`color` は sRGB の顔料色(インスペクタのカラーウェルで任意に変更可)。`pigment` は量(濃さ)。

| プリセット | radius | water | pigment | color(sRGB) | dryness | キー |
|---|---|---|---|---|---|---|
| `.watercolor` 水彩(藍) | 22 | 0.9 | 0.16 | (0.22, 0.34, 0.60) | 0 | `1` |
| `.sumi` 墨(かすれ) | 14 | 0.10 | 0.55 | (0.10, 0.10, 0.11) | 0.85 | `2` |

`dryness` はプリセット値そのままではなく **実効値**(`effectiveDryness(pressure:)`)で使う。乾いた筆(`dryness > 0`)だけ、**筆圧が抜けるほどかすれを強める**(`+ (1-pressure)·0.30`)/ **水量を上げると埋める**(`- max(0, water-0.15)·0.6`)を clamp。加算幅は dryness 非依存の一定幅にする(`(1-dryness)` で重み付けすると `.sumi`(0.85)で頭打ちになり筆圧が効かないため)。マウスは擬似筆圧が速度→筆圧に変換済みなので「速い払い=かすれる」も筆圧経由で付く。水彩(`dryness 0`)は実効も 0 で従来どおり。

### レイヤー / タイムライン(セル方式)

レイヤーは **トラック(`LayerTrack`)** で、フレームをまたいで存在し、各トラックがフレームごとに **セル(`MTLBuffer?`、= `D` 沈着顔料 float3)** を持つ。

- **セル解決(hold)**: `resolvedCel(t, f)` = フレーム `f` 以下で最後に非 nil のセル。セルが無いフレームは直前を**保持**する → 静止背景はトラックにセル 1 枚を置けば全フレーム共有
- **描画ターゲット**: 現フレームのアクティブトラックのセル。保持(nil)なら `beginStroke`/`clear` で**新セルを自動生成**(保持を切って新原画)
- **合成**: 各可視トラックを現フレームの解決後セルに直してから、下のアフィングレーズ合成にかける(セル方式でも合成本体は不変)
- **フレーム操作**: `addFrame`(空=保持フレームを挿入)/ `duplicateFrame`(現フレームを複製した独立フレーム)/ `deleteFrame` / `goToFrame`。`frameTotal` / `currentFrameIndex`
- **オニオンスキン**: 前フレームの全可視トラックを別アフィン `onionA/onionB` に畳み込み(`rebuildOnion`、フレーム移動時)、`renderKernel` で「現フレームが未描画の所に薄く暖色」でブレンド(`onionFactor`)。書き出し時は無効化
- メモリは frames×cels に比例(Apple Silicon のユニファイドメモリ上)。hold で節約

### 合成(順序が効くアフィングレーズ)

- 各トラックは現フレームの解決後セル `D`(float3)+ `visible` + `opacity` を持つ。ウェットシミュレーション(`W`/`P`)は全トラック共有
- **乾燥沈着はアクティブ層へ**。注意: ウェット顔料は「乾いた時点でアクティブな層」に積まれる(描いた瞬間ではない)。ストロークの乾燥中に層を切り替えると、残りの濡れ顔料は新しいアクティブ層に乗る
- **合成はアフィングレーズ**: 各層は下の色 `r` を `r → a·r + b` に変換する。`a = T·(1-occ)`, `b = T·occ`、`T = exp(-D)`(透過色)、`occ = opacity·(1 - exp(-coverageK·輝度))`。
  - 薄い顔料(`occ≈0`)→ `r→T·r` の純粋な乗算フィルタ = 全力で色を付けつつ下が透ける(水彩らしさ、ほぼ順序非依存)
  - 濃い顔料(`occ≈1`)→ `r→T` で下を自分の色に置き換える(不透明、**順序が効く**)
- アフィン変換は合成できるので、アクティブ層より下/上の可視層を **(A, B) 各 float3 へ畳み込む**(`belowA/belowB` `aboveA/aboveB`)。render は 紙 → 下層変換 → アクティブ層(+ウェット) → 上層変換 の順に適用
- 畳み込みは `compositeLayerKernel` を下→上に逐次 dispatch(同一バッファへ書くので `memoryBarrier` で順序保証)。レイヤー/フレーム操作時のみ再構築(低頻度)
- 操作 API: `addLayer` / `deleteLayer(row:)` / `setActiveLayer(row:)` / `toggleLayerVisible(row:)` / `setLayerOpacity(row:opacity:)` / `moveLayer(fromRow:toRow:)`。UI の行は上が手前(`layerInfos` は内部配列の逆順)。`moveLayer` はアクティブトラックを安定 `id` で追従させる

### 書き出し(`AnimationExport`)

`renderFrameCGImage()`(現フレーム合成 → CGImage)を全フレームに回して書く(書き出し中はオニオン無効・currentFrame は復元):

- `exportGIF(to:fps:loop:)` — ImageIO の `CGImageDestination`(GIF)+ フレーム遅延/ループ
- `exportMP4(to:fps:)` — `AVAssetWriter` で H.264/`.mp4`。各フレームを `CVPixelBuffer`(BGRA)化して append。寸法は偶数へ切り捨て(H.264 要件・右端/下端 1px)。UI からは fps をタイムラインの再生速度に追従させて渡す
- `exportSpriteSheet(to:columns:)` — 格子 1 枚 PNG + メタ `.json`(frameWidth/Height/count/columns)。Unity/Unreal でスライス可能
- `exportPNGSequence(to:)` — `frame_0001.png …`

### Undo / Redo(スナップショット方式)

流体シミュレーションは連続的でコマンド再生が難しいため、**スナップショット方式**を採る。

- 取り消し可能な操作の**直前**に `checkpoint()` で**タイムライン全体**(全トラックの全セル `D` + メタデータ + frameCount/currentFrame/active/counter)を `Data` にコピーして undo スタックへ積む
- 取り消し単位: ストローク(`beginStroke`)・`clear`・レイヤー操作・フレーム操作(add/duplicate/delete)。選択/不透明度/表示切替/フレーム移動は履歴に積まない
- `undo()` は現在状態を redo スタックへ積んでから undo スタックの先頭を復元。`redo()` はその逆
- **復元時にウェット(`W`/`P`/pending)は破棄**(中途半端な濡れを残さない)。redo の「乾き途中ストローク」の曖昧さも回避
- 深さは `maxUndoDepth = 15`(タイムライン全体を持つのでやや浅め)。メモリは概ね `深さ × セル総数 × (グリッド × 16B)`。将来は差分スナップショットで削減可能

### ドキュメント保存/読み込み(`.bloom` v2)

エンジンの実状態(全トラックの全セル `D` + メタデータ)をそのまま保存するラスタ形式。ストローク履歴は持たない(再生はこのシミュレーションでは脆いため)。

- v2 書式(リトルエンディアン): magic `"BLM1"` / version(2) / width / height / **frameCount** / trackCount / active / currentFrame / counter / 各トラック { name, visible, opacity, 各フレーム { hasCel u8, [deposit raw if hasCel] } }
- **v1(単一フレーム)は後方互換で読める**(各レイヤー = 1 セルのトラックとして)
- **保存はウェット(`W`/`P`)を含まない** = 乾いた絵。紙テクスチャは寸法から決定的なので保存しない
- 読み込みは**キャンバス寸法の一致を検証**。不一致・不正 magic・非対応バージョンは `EngineError.documentFormat`
- 読み込み時に undo/redo 履歴とウェットをリセット
- API: `saveDocument(to:)` / `loadDocument(from:)` / 画像は `savePNG(to:)`

### チューニングパラメータ(SimulationEngine.SimParams)

| パラメータ | 現在値 | 効果 |
|---|---|---|
| `flowRate` | 0.18 | 滲みの広がり速度。**2D 拡散の安定限界 0.25 未満に保つこと**(超えるとチェッカーボード状の数値不安定が出る) |
| `evapRate` | 0.0010 | 乾燥の速さ(/substep)。小さいほど水が長生きして広がる |
| `depositRate` | 0.62 | 沈着の勢い(濃淡の残り方) |
| `paperInfluence` | 0.35 | 紙の凹凸が水流に与える影響 |
| `wetThreshold` | 0.02 | 乾湿境界(エッジのピン留め) |
| `edgeEvapBoost` | 3.0 | エッジダークニングの強さ |
| `granulation` | 0.8 | 粒状感 |
| 水の上限(metal `stampKernel`) | 8.0 | 中心に高い水頭の溜まりを作りブルームを外へ押し出す。大きいほど広がるが不安定側 |
| `dwellWaterRate` | 0.08 | ドウェルの水供給(広がりを駆動)。/frame |
| `dwellPigmentRate` | 0.018 | ドウェルの顔料供給(濃さ)。/frame |
| `coverageK` | 0.9 | 顔料量 → 被覆(不透明度)への変換係数。大きいほど薄い顔料でも下を覆う(順序が効きやすい) |

> **チューニングの勘所**: 「広がり」は水(`flowRate` / `evapRate` / 水の上限 / `dwellWaterRate`)、「濃さ」は顔料(`depositRate` / `dwellPigmentRate`)が駆動する。両者は分けて考える。広がりが欲しいときは水を、濃さが欲しいときは顔料を動かす。

### 実装上の注意

- バッファは `storageModeShared` の `MTLBuffer`(float 配列)。テクスチャの read_write Tier 問題を避けるため
- `dryKernel` の隣接セル読みは in-place(他スレッド更新中の値が混ざる近似)。視覚目的には十分
- Swift 側 `SimParams` / `Stamp` 構造体は MSL とレイアウト一致が必須(`Stamp` は `pos`/`dir` の float2 と float3 `pigment` を含み stride 48。`dir` は `dryness` の後ろの padding に収まる。フィールドを足したら両側を同時に更新すること。ずれるとスタンプ位置や色が壊れて即わかる)

## 入力

- **タブレット**: `NSEvent.subtype == .tabletPoint` なら `event.pressure` の実筆圧を使う(XPPEN/Wacom ともドライバが標準 NSEvent に載せてくる)。未実測 — XPPEN Deco での確認は M0a 参照
- **マウス**: `PseudoPressureEstimator` がカーソル速度から擬似筆圧を生成(速い = 軽い)。ローパスで平滑化。ユニットテストあり
- **手ブレ補正**(`StrokeStabilizer`): プルストリング(ラバーバンド)方式で入力点列を平滑化。出力点(anchor)が実カーソルへ向かい、両者の距離が紐長 `L = strength × 48pt` を超えた分だけ追従する(揺れ `< L` は吸収)。**幾何ベースで dt 非依存**なのでサンプルレートが揺れても挙動が安定。**位置のみ**平滑化(筆圧はいじらない)。`CanvasView` の入力経路で適用し、MCP 等が `addStrokeSample` に渡す意図的な座標は補正しない。プル方式は出力が遅れるので `endStroke` 時に `flush` で実終点まで補完して線を届かせる。強度はブラシ非依存の**グローバル設定**(インスペクタの「手ブレ」スライダ)。ユニットテストあり
- ストロークはコア側でスタンプ間隔(`radius × 0.3`)に補間される

## MCP サーバ

AI エージェント(Claude Code 等)が**起動中のアプリのキャンバスをそのまま操作する**。Pencil.app 型の
「アプリ内蔵ライブキャンバス」: エージェントが描くストローク・滲み・乾燥はユーザーがリアルタイムに見える。

```
Claude Code ──(stdio: 改行区切り JSON-RPC)── bloom-mcp(ブリッジ・依存ゼロ)
                                                │ バイトをそのまま双方向ポンプ(フレーミングも解釈しない)
                  ~/Library/Application Support/Bloom/mcp.sock(0600・BLOOM_MCP_SOCKET で上書き可)
                                                │
Bloom.app ── MCPSocketListener(accept)── MCPServerController ── MCPTools ── CanvasView / SimulationEngine
              └ swift-sdk の StdioTransport を接続済みソケット fd に被せて流用(カスタム Transport 不要)
```

- **プロトコル処理は 100% アプリ内**(公式 [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)。0.x のため `project.yml` で exact 固定)。ブリッジ(`BloomMCPBridge/`)は stdin/stdout ⇄ ソケットの素通しポンプで、SDK にも BloomCore にも依存しない。診断は stderr のみ(stdout はプロトコル専用)
- **接続ライフサイクル**: 接続ごとに新しい `Server` を作り `waitUntilCompleted` で切断まで面倒を見る(再接続可)。同時 2 本目は即 close(単一クライアント)。アプリ起動時に残骸ソケットがあれば接続プローブで判定し、拒否されたら unlink、生きていたら(別インスタンス)MCP を無効化してステータスバーに表示
- **並行性**: ツール実装は全部 `@MainActor`(`MCPTools`)。SDK のハンドラから `await` で hop する。`draw_strokes` / `wait_for_dry` は `Task.sleep` を挟むので main はブロックされず、MTKView の描画(= シミュレーション進行)は止まらない
- **UI 同期**: undo/redo・ブラシ変更は `CanvasView` のラッパー(`undo()` / `selectBrush(_:)`)経由で呼び、インスペクタ・タイムラインが既存経路で追従する。ストロークだけ engine 直(`beginStroke`/`addStrokeSample`/`endStroke`、スタビライザは通さない — 入力節参照)。MCP 描画中は `CanvasView.isExternallyDrawing` でユーザーのマウス入力をガード(ストローク状態の混線防止)
- **ペーシング**: `draw_strokes` はサンプルを 3 点ずつ投入して 8ms 待つ。一括投入だと `maxStampsPerFrame`(1024)超過分が黙って捨てられるため。副産物として「線が生えていく」ライブ感が出る
- **エージェントの描画精度のための工夫**(LLM は生の座標列の空間推論が苦手なので、その弱点を吸収する):
  - **スプライン補間**(`BloomCore/StrokePath`・Catmull-Rom): 制御点 5〜10 個で形を指定すれば約 2.5pt 間隔の点列に補間される(`smooth: false` で無効化可)。筆圧は制御点間で線形補間
  - **入り抜きプロファイル**(`pressure_profile`): flat / taper(両端細)/ entry(入り細)/ exit(払い)を正規化弧長で筆圧に乗算
  - **描画結果の自動返却**: `draw_strokes` の結果に描画直後の縮小プレビュー(長辺 400px・`makePNGData(maxDimension:)`)を毎回添付し、「描く → 見る → 外したら undo」のループを強制的に閉じる
  - **計器(目測の置き換え)**: モデルの細かい空間・色知覚は弱いので、`dry_now`(乾燥の早送り → プレビューと仕上がりの乖離を解消)・`sample_colors`(色の実測)・`snapshot {grid}`(座標グリッド・`BloomCore/SnapshotGrid` が CoreText で焼き込み)で「見る」を「測る」に置き換える
  - **画材レシピの注入**: サーバの `instructions` にウォッシュ/精密な線/かすれ払い等のパラメータレシピと、明 → 暗の順で積む・層の前に乾かす等のワークフロー指針を記載
- **乾燥待ち**: `wait_for_dry` は `SimulationEngine.wetFraction`(W バッファの CPU 走査・shared なので安価)を 250ms 間隔でポーリング。**ウィンドウが隠れると MTKView が止まりシミュレーションも進まない**ので、タイムアウト時はその旨のヒントを返す
- **無効化**: `--no-mcp` で起動。`--demo` 系の検証モードではそもそも起動しない

### ツール(Phase 1)

| ツール | 概要 |
|---|---|
| `get_canvas_info` | 寸法(原点左上・y 下向き・pt)・ブラシ・レイヤー・フレーム・wet_fraction・undo 可否を JSON で |
| `set_brush` | preset(watercolor/sumi)+ color/radius/water/pigment/dryness の永続変更(インスペクタ追従) |
| `draw_strokes` | 複数ストローク(points[]{x,y,pressure})。制御点はスプライン補間され、`pressure_profile` で入り抜き。ストローク単位の一時ブラシ上書き可。1 ストローク = 1 undo 単位。結果に縮小プレビュー画像が付く |
| `wait_for_dry` | 自然乾燥を待つ(`timeout_seconds`、既定 15 秒)。にじみが最後まで育つ |
| `dry_now` | ドライヤー: `evaporationBoost` を一時的に上げて数秒で乾かす(にじみの成長はそこで止まる)。終了時に必ず 1 へ復元 |
| `sample_colors` | 指定座標の実際の表示色(sRGB + hex)を返す。色の出方を実測で確認 |
| `snapshot` | 現フレームを base64 PNG(image content)で返す。`grid: true` で 100pt 座標グリッドを焼き込み |
| `clear` / `undo` / `redo` | クリア(undo 可)・取り消し・やり直し |

Phase 2(予定): `manage_layer` / `manage_frame` / `save_document` / `load_document`。
Phase 3(予定): `export`(PNG/GIF/MP4/スプライト/連番)・`snapshot(frame:)`・ブリッジの自動起動(opt-in)。

### 登録と検証

- リポジトリの `.mcp.json`(プロジェクトスコープ)が `scripts/bloom-mcp`(ビルド済みブリッジへの sh ラッパー)を指す。このリポジトリで Claude Code を開けばサーバ「bloom」が自動認識される(要承認・要 `make build` + アプリ起動)
- `make mcp-smoke` で Claude なしの疎通テスト(専用ソケットでアプリを起動 → initialize / tools/list / tools/call を流して応答検証 → 後始末)

## ビルド構成

- **XcodeGen**: `project.yml` が真実。`Bloom.xcodeproj` は生成物(git 管理外)。`make gen` で再生成
- **レイアウト**: Xcode 標準(ターゲット名フォルダがルート直下)。ターゲットは BloomCore(framework)/ BloomApp(app)/ bloom-mcp(CLI ブリッジ)/ BloomCoreTests
- **SwiftPM**: MCP 公式 swift-sdk を `project.yml` の `packages:` で導入(0.x のため `exactVersion` 固定)。依存するのは BloomApp のみ(BloomCore・bloom-mcp は非依存)
- **Makefile**: `make run / test / demo / mcp-smoke`。DerivedData はリポジトリ外(`~/Library/Developer/Xcode/DerivedData/Bloom-cli`)— Dropbox 同期ノイズ回避
- **検証**: `make demo` がデモストロークを自動実行し、wet(直後)/ dry(乾燥後)の PNG を `/tmp/bloom-snap` に出力。描き味チューニングはこのループで回す
  - ドウェル(置きっぱなし)の確認は `BloomApp --demo-dwell --snapshot-dir <dir>` → `pooled.png`(溜まり)/ `dried.png`(乾いた輪っか)
  - レイヤー合成・順序は `--demo-layers`、undo は `--demo-undo`、保存/読み込みは `--demo-saveload`
  - アニメーションは `--demo-anim`(数フレーム→ GIF/スプライト/連番)、オニオンは `--demo-onion`(前フレームのゴースト)
  - 手ブレ補正は `--demo-stabilize`(同じ揺れた入力を補正なし/あり で描き比べ → `stabilize-off.png` / `stabilize-on.png`)
  - 墨のかすれは `--demo-sumi`(墨ブラシで筆圧違いの 3 本 = 高圧/低圧/払い を描く → `sumi.png`)
  - 使い方ガイドの作例は `--demo-guide`(水彩ウォッシュ → 乾燥 → 墨レイヤーで葦のかすれを重ねる → `guide-watercolor.png` / `guide-hero.png`)

### ハマりどころ(再発時のために)

| 症状 | 原因と対処 |
|---|---|
| `cannot execute tool 'metal'` | Xcode 26 から Metal ツールチェーンが別コンポーネント。`xcodebuild -downloadComponent MetalToolchain` |
| framework の codesign が `bundle format unrecognized` | framework に Info.plist がない。`GENERATE_INFOPLIST_FILE: YES`(project.yml 設定済み) |
| SwiftPM CLI で .metal がビルドされない | `swift build` は .metal をコンパイルしない。Xcode ビルドに移行済みのため現在は非該当 |
