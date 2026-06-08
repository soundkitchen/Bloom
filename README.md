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

アプリ内の操作: ドラッグで描く / `1` 水彩(藍) / `2` 墨(かすれ) / `[` `]` ブラシサイズ / `c` クリア / `d` デモストローク

## 構成

- `BloomCore/` — ヘッドレスの描画コア(framework、AppKit 非依存)。滲みシミュレーション(Metal compute)と入力抽象
- `BloomApp/` — macOS アプリ(コアの上の薄い殻)
- `BloomCoreTests/` — コアのユニットテスト
