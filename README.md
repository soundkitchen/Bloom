# Bloom

適当な線から水彩画・水墨画のような絵が描ける macOS アプリ。

- コンセプト・ロードマップ: [docs/idea.md](docs/idea.md)
- コード・ビルドの現在形: [docs/architecture.md](docs/architecture.md)
- 開発の記録: [docs/devlog/](docs/devlog/)

## 必要なもの

- Xcode 26+(Metal ツールチェーン込み: 未導入なら `xcodebuild -downloadComponent MetalToolchain`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`)

## 開発

`Bloom.xcodeproj` は XcodeGen の生成物(git 管理外)。`project.yml` を編集したら `make gen`。

```sh
make run    # アプリ起動
make test   # ユニットテスト
make demo   # デモストロークを自動実行し /tmp/bloom-snap に wet/dry PNG を出力
```

## アプリ内の操作

- **描画**: ドラッグで描く(マウスは速度→擬似筆圧、タブレットは実筆圧)
- **ブラシ**(右インスペクタ / キー): `1` 水彩(藍) / `2` 墨(かすれ)、カラーウェルで任意色、サイズ `[` `]`、水量スライダ、`c` クリア、`d` デモストローク
- **レイヤー**(インスペクタの一覧): 目アイコンで表示切替、行の D&D で並べ替え、＋/🗑、不透明スライダ
- **取り消し / やり直し**: Cmd+Z / Cmd+Shift+Z
- **アニメーション**(下のタイムライン): フレーム選択・追加/複製/削除、再生 ▶、前後送り、オニオン(前フレームを薄く表示)、fps。フレームメニュー(新規 Cmd+Shift+N など)
- **保存 / 書き出し**(ファイルメニュー): 開く Cmd+O / 保存 Cmd+S(`.bloom`)/ PNG Cmd+E / GIF Cmd+G / スプライトシート Cmd+Shift+G / PNG 連番

詳細は [docs/architecture.md](docs/architecture.md) を参照。

## 構成

- `BloomCore/` — ヘッドレスの描画コア(framework、AppKit 非依存)。滲みシミュレーション + レイヤー/フレーム(`SimulationEngine`)、Metal カーネル(`Simulation.metal`)、書き出し(`AnimationExport`)、入力抽象(`InputSample`)
- `BloomApp/` — macOS アプリ。`CanvasView` / `InspectorView` / `TimelineView` / `AppDelegate`
- `BloomCoreTests/` — コアのユニットテスト
